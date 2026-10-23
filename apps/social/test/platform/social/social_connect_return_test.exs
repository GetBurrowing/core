defmodule Platform.Social.ConnectReturnTest do
  @moduledoc """
  The OAuth return leg (task 01a14807, stage 2): `complete_connect/4` and
  `reconcile_accounts/3`.

  `async: false`: the publisher config, the Fake's call table and the
  install-level Zernio key are global. Zernio traffic goes to `Req.Test`
  stubs ONLY; every stub counts the requests it saw.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{Account, Profile, Secrets}
  alias Platform.Social.Publisher.{Fake, Zernio}

  @key "zernio-return-test-key-not-real"
  @profile_ref "zprof_return_1"

  setup do
    Fake.reset()
    org_id = org_id!()
    {:ok, profile} = Social.create_profile(org_id, %{name: "Return #{unique()}"})
    approver = make_approver!(org_id, profile, user!())

    {:ok, profile} =
      Profile
      |> Repo.get!(profile.id)
      |> Ecto.Changeset.change(provider_profile_ref: @profile_ref)
      |> Repo.update()

    {:ok, pending} = Social.create_account(org_id, profile, %{platform: "linkedin"})
    %{org_id: org_id, profile: profile, approver: approver, pending: pending}
  end

  defp select_publisher(module) do
    previous = Application.get_env(:social, :publisher)
    Application.put_env(:social, :publisher, module)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
  end

  defp use_zernio(%{approver: approver}) do
    select_publisher(Zernio)
    {:ok, _} = Secrets.put_zernio_api_key(@key, approver)
    :ok
  end

  defp entry(ref, platform, opts \\ []) do
    %{
      "_id" => ref,
      "platform" => platform,
      "profileId" => %{"_id" => Keyword.get(opts, :profile_ref, @profile_ref), "name" => "Brand"},
      "username" => Keyword.get(opts, :username, "user-#{ref}"),
      "isActive" => Keyword.get(opts, :active, true)
    }
  end

  defp stub_accounts(entries) do
    test = self()

    Req.Test.stub(Zernio, fn conn ->
      send(test, {:zernio_request, conn.method, conn.request_path})

      conn
      |> Plug.Conn.put_status(200)
      |> Req.Test.json(%{"accounts" => entries, "hasAnalyticsAccess" => false})
    end)
  end

  defp requests(acc \\ []) do
    receive do
      {:zernio_request, method, path} -> requests([{method, path} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp reload(%Account{id: id}), do: Repo.get!(Account, id)

  defp accounts(profile),
    do: Repo.all(from(a in Account, where: a.profile_id == ^profile.id, order_by: a.inserted_at))

  defp connect(ctx, ref, platform \\ "linkedin", user_id \\ nil) do
    Social.complete_connect(ctx.org_id, ctx.profile, user_id || ctx.approver.id, %{
      account_ref: ref,
      platform: platform
    })
  end

  describe "complete_connect/4 under Zernio" do
    setup :use_zernio

    test "a listed ref connects the pending row (ref, status, handle) with exactly one GET",
         ctx do
      stub_accounts([entry("zacct_li", "linkedin", username: "brand-li")])

      assert {:ok, %Account{id: id}, :connected} = connect(ctx, "zacct_li")
      assert id == ctx.pending.id

      row = reload(ctx.pending)
      assert row.provider_account_ref == "zacct_li"
      assert row.status == "connected"
      assert row.handle == "brand-li"
      assert requests() == [{"GET", "/api/v1/accounts"}]
    end

    test "a present handle is kept", ctx do
      {:ok, _} = Social.update_account(ctx.org_id, ctx.pending, %{handle: "ours"})
      stub_accounts([entry("zacct_li", "linkedin", username: "theirs")])

      assert {:ok, _, :connected} = connect(ctx, "zacct_li")
      assert reload(ctx.pending).handle == "ours"
    end

    test "a second call with the same ref is :already_connected, one row, no write", ctx do
      stub_accounts([entry("zacct_li", "linkedin")])
      assert {:ok, _, :connected} = connect(ctx, "zacct_li")
      before = reload(ctx.pending)
      count = length(accounts(ctx.profile))

      assert {:ok, %Account{id: id}, :already_connected} = connect(ctx, "zacct_li")
      assert id == ctx.pending.id
      assert reload(ctx.pending).updated_at == before.updated_at
      assert length(accounts(ctx.profile)) == count

      assert [_] =
               Repo.all(from(a in Account, where: a.provider_account_ref == "zacct_li"))
    end

    test "a ref the vendor does not list is :not_listed, nothing written, one GET", ctx do
      stub_accounts([entry("zacct_li", "linkedin")])

      assert {:error, :not_listed} = connect(ctx, "zacct_forged")
      assert reload(ctx.pending) == ctx.pending
      assert requests() == [{"GET", "/api/v1/accounts"}]
    end

    test "an entry whose profileId is another profile's is :not_listed", ctx do
      stub_accounts([entry("zacct_li", "linkedin", profile_ref: "zprof_someone_else")])

      assert {:error, :not_listed} = connect(ctx, "zacct_li")
      assert reload(ctx.pending) == ctx.pending
    end

    test "an entry with isActive false is :not_listed", ctx do
      stub_accounts([entry("zacct_li", "linkedin", active: false)])

      assert {:error, :not_listed} = connect(ctx, "zacct_li")
      assert reload(ctx.pending) == ctx.pending
    end

    test "the LISTED platform wins: URL instagram with a listed linkedin ref writes linkedin",
         ctx do
      {:ok, instagram} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "instagram"})
      stub_accounts([entry("zacct_li", "linkedin")])

      assert {:ok, %Account{id: id}, :connected} = connect(ctx, "zacct_li", "instagram")
      assert id == ctx.pending.id
      assert reload(ctx.pending).provider_account_ref == "zacct_li"
      assert reload(instagram) == instagram
    end

    test "no never-connected row on the listed platform is :no_pending_account, none created",
         ctx do
      stub_accounts([entry("zacct_x", "twitter")])
      count = length(accounts(ctx.profile))

      assert {:error, :no_pending_account} = connect(ctx, "zacct_x", "x")
      assert length(accounts(ctx.profile)) == count
    end

    test "a ref held by another profile's row is :ref_in_use and nothing is written", ctx do
      {:ok, other} = Social.create_profile(ctx.org_id, %{name: "Other #{unique()}"})
      {:ok, held} = Social.create_account(ctx.org_id, other, %{platform: "linkedin"})
      {:ok, _} = held |> Ecto.Changeset.change(provider_account_ref: "zacct_li") |> Repo.update()
      stub_accounts([entry("zacct_li", "linkedin")])

      assert {:error, :ref_in_use} = connect(ctx, "zacct_li")
      assert reload(ctx.pending) == ctx.pending
    end
  end

  describe "who may complete a return" do
    setup :use_zernio

    setup ctx do
      stub_accounts([entry("zacct_li", "linkedin")])
      archived = make_approver!(ctx.org_id, ctx.profile, user!())
      {:ok, _} = Platform.Accounts.archive_user(archived)
      outsider = member!(user!(), ctx.org_id)
      %{archived: archived, outsider: outsider, agent: agent!()}
    end

    test "a non-approver, an agent id and an archived approver are refused with ZERO requests",
         ctx do
      for {user_id, reason} <- [
            {ctx.outsider.id, :not_an_approver},
            {ctx.agent.id, :not_a_human},
            {ctx.archived.id, :approver_archived}
          ] do
        assert {:error, ^reason} = connect(ctx, "zacct_li", "linkedin", user_id)

        assert {:error, ^reason} =
                 Social.reconcile_accounts(ctx.org_id, ctx.profile, user_id)

        assert requests() == []
        assert reload(ctx.pending) == ctx.pending
      end
    end

    test "positive control: the approver's identical calls go through", ctx do
      assert {:ok, _, :connected} = connect(ctx, "zacct_li", "linkedin", ctx.approver.id)
      assert requests() == [{"GET", "/api/v1/accounts"}]

      {:ok, _} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "linkedin"})

      assert {:ok, %{connected: [], unmatched: 0}} =
               Social.reconcile_accounts(ctx.org_id, ctx.profile, ctx.approver.id)

      assert requests() == [{"GET", "/api/v1/accounts"}]
    end

    test "another org's org_id is :not_found with zero requests", ctx do
      other_org = org_id!()

      assert {:error, :not_found} =
               Social.complete_connect(other_org, ctx.profile, ctx.approver.id, %{
                 account_ref: "zacct_li",
                 platform: "linkedin"
               })

      assert {:error, :not_found} =
               Social.reconcile_accounts(other_org, ctx.profile.id, ctx.approver.id)

      assert requests() == []
      assert reload(ctx.pending) == ctx.pending
    end

    test "a profile with no vendor ref is :profile_not_linked with zero requests", ctx do
      {:ok, _} = ctx.profile |> Ecto.Changeset.change(provider_profile_ref: nil) |> Repo.update()

      assert {:error, :profile_not_linked} = connect(ctx, "zacct_li")

      assert {:error, :profile_not_linked} =
               Social.reconcile_accounts(ctx.org_id, ctx.profile, ctx.approver.id)

      assert requests() == []
      assert reload(ctx.pending) == ctx.pending
    end
  end

  describe "reconcile_accounts/3 under Zernio" do
    setup :use_zernio

    test "fills two pending rows from a two-entry list and leaves an unlisted platform's row",
         ctx do
      {:ok, x} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "x"})
      {:ok, tiktok} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "tiktok"})

      stub_accounts([
        entry("zacct_li", "linkedin", username: "brand-li"),
        entry("zacct_tw", "twitter", username: "brand_x")
      ])

      assert {:ok, %{connected: connected, unmatched: 0}} =
               Social.reconcile_accounts(ctx.org_id, ctx.profile, ctx.approver.id)

      assert Enum.map(connected, & &1.id) == [ctx.pending.id, x.id]
      assert requests() == [{"GET", "/api/v1/accounts"}]

      assert %{provider_account_ref: "zacct_li", status: "connected", handle: "brand-li"} =
               reload(ctx.pending)

      assert %{provider_account_ref: "zacct_tw", status: "connected", handle: "brand_x"} =
               reload(x)

      assert reload(tiktok) == tiktok
    end

    test "one entry fills one row: two pending rows on a platform with one listed entry", ctx do
      {:ok, second} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "linkedin"})
      stub_accounts([entry("zacct_li", "linkedin"), entry("zacct_li2", "linkedin")])

      assert {:ok, %{connected: [a, b], unmatched: 0}} =
               Social.reconcile_accounts(ctx.org_id, ctx.profile, ctx.approver.id)

      assert {a.id, a.provider_account_ref} == {ctx.pending.id, "zacct_li"}
      assert {b.id, b.provider_account_ref} == {second.id, "zacct_li2"}
    end

    test "entries with no pending row, or held elsewhere, count as unmatched", ctx do
      {:ok, other} = Social.create_profile(ctx.org_id, %{name: "Other #{unique()}"})
      {:ok, held} = Social.create_account(ctx.org_id, other, %{platform: "linkedin"})
      {:ok, _} = held |> Ecto.Changeset.change(provider_account_ref: "zacct_li") |> Repo.update()

      stub_accounts([
        entry("zacct_li", "linkedin"),
        entry("zacct_yt", "youtube"),
        entry("zacct_li_ok", "linkedin")
      ])

      assert {:ok, %{connected: [only], unmatched: 2}} =
               Social.reconcile_accounts(ctx.org_id, ctx.profile, ctx.approver.id)

      assert {only.id, only.provider_account_ref} == {ctx.pending.id, "zacct_li_ok"}
    end

    test "with no never-connected row and no untyped connected row it answers empty and makes ZERO requests",
         ctx do
      stub_accounts([entry("zacct_li", "linkedin")])
      assert {:ok, _, :connected} = connect(ctx, "zacct_li")
      assert [_] = requests()

      # Typed, so the type backfill (task 01a1653a) has nothing to ask about.
      {:ok, _} =
        ctx.pending
        |> reload()
        |> Ecto.Changeset.change(platform_account_type: "business")
        |> Repo.update()

      stub_accounts([entry("zacct_li", "linkedin"), entry("zacct_li2", "linkedin")])

      assert {:ok, %{connected: [], unmatched: 0}} =
               Social.reconcile_accounts(ctx.org_id, ctx.profile, ctx.approver.id)

      assert requests() == []
    end
  end

  describe "under the Fake" do
    setup do
      select_publisher(Fake)
      Req.Test.stub(Zernio, fn _conn -> flunk("a request reached Zernio") end)
      :ok
    end

    test "complete_connect and reconcile record list_accounts, answer [] and touch nothing",
         ctx do
      assert {:error, :not_listed} = connect(ctx, "zacct_li")
      assert [{:list_accounts, [%Profile{id: id}], _}] = Fake.calls(:list_accounts)
      assert id == ctx.profile.id

      assert {:ok, %{connected: [], unmatched: 0}} =
               Social.reconcile_accounts(ctx.org_id, ctx.profile, ctx.approver.id)

      assert length(Fake.calls(:list_accounts)) == 2
      assert reload(ctx.pending) == ctx.pending
    end

    defp fake_entry(ref, platform, account_type) do
      %{
        ref: ref,
        platform: platform,
        profile_ref: @profile_ref,
        username: "user-#{ref}",
        active?: true,
        account_type: account_type
      }
    end

    test "complete_connect stores a reported account type (creator) on the connected row",
         ctx do
      {:ok, ig} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "instagram"})
      Fake.put_next(:list_accounts, {:ok, [fake_entry("zacct_ig", "instagram", "creator")]})

      assert {:ok, %Account{id: id}, :connected} = connect(ctx, "zacct_ig", "instagram")
      assert id == ig.id

      assert %{
               status: "connected",
               provider_account_ref: "zacct_ig",
               platform_account_type: "creator"
             } =
               reload(ig)
    end

    test "complete_connect with no reported type connects and leaves the type nil", ctx do
      {:ok, ig} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "instagram"})
      Fake.put_next(:list_accounts, {:ok, [fake_entry("zacct_ig", "instagram", nil)]})

      assert {:ok, _, :connected} = connect(ctx, "zacct_ig", "instagram")
      assert %{status: "connected", platform_account_type: nil} = reload(ig)
    end

    test "a nil report never overwrites a stored type", ctx do
      {:ok, ig} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "instagram"})
      {:ok, ig} = ig |> Ecto.Changeset.change(platform_account_type: "creator") |> Repo.update()
      Fake.put_next(:list_accounts, {:ok, [fake_entry("zacct_ig", "instagram", nil)]})

      assert {:ok, _, :connected} = connect(ctx, "zacct_ig", "instagram")
      assert %{status: "connected", platform_account_type: "creator"} = reload(ig)
    end

    test "reconcile_accounts fills a pending row with the reported type (business)", ctx do
      {:ok, tiktok} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "tiktok"})
      Fake.put_next(:list_accounts, {:ok, [fake_entry("zacct_tt", "tiktok", "business")]})

      assert {:ok, %{connected: [%Account{id: id}], unmatched: 0}} =
               Social.reconcile_accounts(ctx.org_id, ctx.profile, ctx.approver.id)

      assert id == tiktok.id

      assert %{
               status: "connected",
               provider_account_ref: "zacct_tt",
               platform_account_type: "business"
             } =
               reload(tiktok)
    end

    # ── Type backfill on already-connected rows (task 01a1653a) ──────

    # A live connected row on this profile, as an earlier connect left it.
    defp connected_row(ctx, platform, ref, type) do
      {:ok, account} = Social.create_account(ctx.org_id, ctx.profile, %{platform: platform})

      {:ok, account} =
        account
        |> Ecto.Changeset.change(
          status: "connected",
          provider_account_ref: ref,
          platform_account_type: type
        )
        |> Repo.update()

      account
    end

    # The setup's pending linkedin row, connected and typed: neither pending
    # nor untyped, so only the row under test can make reconcile ask.
    defp settle_setup_row(ctx) do
      {:ok, _} =
        ctx.pending
        |> Ecto.Changeset.change(
          status: "connected",
          provider_account_ref: "zacct_li_settled",
          platform_account_type: "business"
        )
        |> Repo.update()

      :ok
    end

    test "reconcile backfills business on an already-connected row", ctx do
      settle_setup_row(ctx)
      tiktok = connected_row(ctx, "tiktok", "zacct_tt", nil)
      Fake.put_next(:list_accounts, {:ok, [fake_entry("zacct_tt", "tiktok", "business")]})

      assert {:ok, %{connected: [], unmatched: 0, typed: [%Account{id: id}]}} =
               Social.reconcile_accounts(ctx.org_id, ctx.profile, ctx.approver.id)

      assert id == tiktok.id
      assert length(Fake.calls(:list_accounts)) == 1

      assert %{
               status: "connected",
               provider_account_ref: "zacct_tt",
               platform_account_type: "business"
             } =
               reload(tiktok)
    end

    test "a nil report keeps a stored creator on a connected row", ctx do
      settle_setup_row(ctx)
      ig = connected_row(ctx, "instagram", "zacct_ig", "creator")
      # An untyped row so reconcile asks at all.
      _tt = connected_row(ctx, "tiktok", "zacct_tt", nil)

      Fake.put_next(
        :list_accounts,
        {:ok, [fake_entry("zacct_ig", "instagram", nil), fake_entry("zacct_tt", "tiktok", nil)]}
      )

      assert {:ok, %{connected: [], unmatched: 0, typed: []}} =
               Social.reconcile_accounts(ctx.org_id, ctx.profile, ctx.approver.id)

      assert length(Fake.calls(:list_accounts)) == 1
      assert reload(ig) == ig
    end

    test "no pending row and no untyped connected row: ZERO list_accounts calls", ctx do
      settle_setup_row(ctx)
      _ig = connected_row(ctx, "instagram", "zacct_ig", "creator")

      assert {:ok, %{connected: [], unmatched: 0, typed: []}} =
               Social.reconcile_accounts(ctx.org_id, ctx.profile, ctx.approver.id)

      assert Fake.calls(:list_accounts) == []
    end

    test "an Instagram row Zernio cannot type stays nil and still allows a Reel", ctx do
      settle_setup_row(ctx)
      ig = connected_row(ctx, "instagram", "zacct_ig", nil)
      Fake.put_next(:list_accounts, {:ok, [fake_entry("zacct_ig", "instagram", nil)]})

      assert {:ok, %{connected: [], unmatched: 0, typed: []}} =
               Social.reconcile_accounts(ctx.org_id, ctx.profile, ctx.approver.id)

      assert length(Fake.calls(:list_accounts)) == 1
      ig = reload(ig)
      assert %{status: "connected", platform_account_type: nil} = ig

      assert :ok =
               Platform.Social.MediaRules.check("instagram", ig, [
                 %{content_type: "video/mp4", duration_s: 30, byte_size: 10_000_000}
               ])
    end

    test "complete_connect's already-connected answer backfills the reported type", ctx do
      ig = connected_row(ctx, "instagram", "zacct_ig", nil)
      Fake.put_next(:list_accounts, {:ok, [fake_entry("zacct_ig", "instagram", "creator")]})

      assert {:ok, %Account{id: id, platform_account_type: "creator"}, :already_connected} =
               connect(ctx, "zacct_ig", "instagram")

      assert id == ig.id
      assert %{platform_account_type: "creator", status: "connected"} = reload(ig)
    end

    test "complete_connect's already-connected answer never writes nil over a type", ctx do
      ig = connected_row(ctx, "instagram", "zacct_ig", "business")
      Fake.put_next(:list_accounts, {:ok, [fake_entry("zacct_ig", "instagram", nil)]})

      assert {:ok, _, :already_connected} = connect(ctx, "zacct_ig", "instagram")
      assert reload(ig) == ig
    end
  end
end
