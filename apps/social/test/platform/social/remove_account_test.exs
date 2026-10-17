defmodule Platform.Social.RemoveAccountTest do
  @moduledoc """
  Removing an account (task 01a14ac6, stage 2): `removal_preview/3` and
  `remove_account/4`. Approver-checked archive, post cancel, best-effort
  vendor disconnect.

  `async: false`: the publisher config, the Fake's call table and the
  install-level Zernio key are global. Zernio traffic goes to `Req.Test`
  stubs ONLY.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{Account, Post, Profile, Secrets}
  alias Platform.Social.Publisher.{Fake, Zernio}

  @ref "zacct_remove_1"
  @profile_ref "zprof_remove_1"
  @removed "cancelled: account removed"

  setup do
    Fake.reset()
    org_id = org_id!()

    {profile, account} =
      social_account!(org_id, "linkedin", %{provider_account_ref: @ref, status: "connected"})

    {:ok, profile} =
      Profile
      |> Repo.get!(profile.id)
      |> Ecto.Changeset.change(provider_profile_ref: @profile_ref)
      |> Repo.update()

    approver = make_approver!(org_id, profile, user!())
    profile = Repo.get!(Profile, profile.id)
    %{org_id: org_id, profile: profile, account: account, approver: approver}
  end

  defp select_publisher(module) do
    previous = Application.get_env(:social, :publisher)
    Application.put_env(:social, :publisher, module)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
  end

  defp scheduled!(ctx, account, external_id, attrs \\ %{}) do
    post = approved_post!(ctx.org_id, account, attrs, ctx.approver)

    post
    |> Ecto.Changeset.change(status: "scheduled", external_id: external_id)
    |> Repo.update!()
  end

  defp post!(ctx, account, status) do
    {:ok, post} = Social.create_post(ctx.org_id, account, %{body: "b", status: status})
    post
  end

  defp published!(ctx, account) do
    ctx
    |> scheduled!(account, "ext_pub_#{unique()}")
    |> Ecto.Changeset.change(status: "published")
    |> Repo.update!()
  end

  defp other_account!(ctx) do
    {:ok, other} =
      Social.create_account(ctx.org_id, ctx.profile, %{
        platform: "x",
        provider_account_ref: "zacct_other_#{unique()}",
        status: "connected"
      })

    other
  end

  defp posts_of(%Account{id: id}),
    do: Repo.all(from(p in Post, where: p.account_id == ^id, order_by: [p.inserted_at, p.id]))

  defp remove(ctx, user_id \\ nil),
    do: Social.remove_account(ctx.org_id, ctx.profile, user_id || ctx.approver.id, ctx.account.id)

  # Scheduled x2, needs_approval x1 (single); scheduled x1 shared with a post
  # on another account; plus a draft and a published post that stay put.
  defp world!(ctx) do
    task = task!(ctx.org_id)
    other = other_account!(ctx)

    s1 = scheduled!(ctx, ctx.account, "ext_s1")
    s2 = scheduled!(ctx, ctx.account, "ext_s2")
    na = post!(ctx, ctx.account, "needs_approval")
    shared = scheduled!(ctx, ctx.account, "ext_shared", %{task_id: task.id})
    sibling = scheduled!(ctx, other, "ext_sibling", %{task_id: task.id})
    draft = post!(ctx, ctx.account, "draft")
    published = published!(ctx, ctx.account)

    Fake.reset()

    %{
      other: other,
      cancellable: [s1, s2, na, shared],
      sibling: Repo.get!(Post, sibling.id),
      draft: Repo.get!(Post, draft.id),
      published: Repo.get!(Post, published.id)
    }
  end

  describe "refusals" do
    test "a non-approver, an agent id and an archived user are refused with no write and no vendor call",
         ctx do
      world!(ctx)
      before = posts_of(ctx.account)

      assert {:error, :not_an_approver} = remove(ctx, user!().id)
      assert {:error, :not_a_human} = remove(ctx, agent!().id)

      {:ok, _} = Platform.Accounts.archive_user(ctx.approver)
      assert {:error, :approver_archived} = remove(ctx)

      assert Repo.get!(Account, ctx.account.id).archived_at == nil
      assert posts_of(ctx.account) == before
      assert Fake.calls() == []
    end

    test "an account of another profile, or another org, is :not_found", ctx do
      {_p2, foreign} = social_account!(ctx.org_id, "linkedin")

      assert {:error, :not_found} =
               Social.remove_account(ctx.org_id, ctx.profile, ctx.approver.id, foreign.id)

      assert {:error, :not_found} =
               Social.remove_account(org_id!(), ctx.profile, ctx.approver.id, ctx.account.id)

      assert {:error, :not_found} = Social.removal_preview(org_id!(), ctx.profile, ctx.account.id)
      assert Fake.calls() == []
    end
  end

  describe "an approver removes a connected account (Fake)" do
    test "preview counts, then cancels exactly the cancellable posts and archives the row", ctx do
      w = world!(ctx)

      assert {:ok, %{account: %Account{id: id}, cancelled: 3, shared: 1}} =
               Social.removal_preview(ctx.org_id, ctx.profile, ctx.account.id)

      assert id == ctx.account.id
      # preview is read-only
      assert Enum.map(posts_of(ctx.account), & &1.status) |> Enum.count(&(&1 == "failed")) == 0

      assert {:ok, %Account{} = archived, %{cancelled: 3, shared: 1, vendor: :disconnected}} =
               remove(ctx)

      assert archived.id == ctx.account.id

      for post <- w.cancellable do
        row = Repo.get!(Post, post.id)
        assert {row.status, row.error} == {"failed", @removed}
      end

      assert Repo.get!(Post, w.draft.id) == w.draft
      assert Repo.get!(Post, w.published.id) == w.published
      assert Repo.get!(Post, w.sibling.id) == w.sibling

      row = Repo.get(Account, ctx.account.id)
      assert %Account{archived_at: %DateTime{}} = row
      assert length(posts_of(ctx.account)) == 6
      refute ctx.account.id in Enum.map(Social.list_accounts(ctx.org_id), & &1.id)
      assert w.other.id in Enum.map(Social.list_accounts(ctx.org_id), & &1.id)
    end

    test "deletes the scheduled posts at the vendor and disconnects the account once", ctx do
      world!(ctx)
      assert {:ok, _, %{vendor: :disconnected}} = remove(ctx)

      deleted = Fake.calls(:delete) |> Enum.map(fn {:delete, [_acc, ext], _} -> ext end)
      assert Enum.sort(deleted) == Enum.sort(["ext_s1", "ext_s2", "ext_shared"])

      assert [{:disconnect_account, [%Account{id: id, provider_account_ref: @ref}], _}] =
               Fake.calls(:disconnect_account)

      assert id == ctx.account.id
    end

    test "a never-connected row is archived with zero vendor calls", ctx do
      {:ok, pending} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "x"})
      Fake.reset()

      assert {:ok, %Account{archived_at: %DateTime{}},
              %{cancelled: 0, shared: 0, vendor: :not_connected}} =
               Social.remove_account(ctx.org_id, ctx.profile, ctx.approver.id, pending.id)

      assert %Account{archived_at: %DateTime{}} = Repo.get!(Account, pending.id)
      assert Fake.calls() == []
    end

    test "a disconnect failure is :unconfirmed and the archive and cancels stand", ctx do
      w = world!(ctx)
      Fake.fail_next(:disconnect_account, :unavailable)

      assert {:ok, _, %{cancelled: 3, shared: 1, vendor: {:unconfirmed, :unavailable}}} =
               remove(ctx)

      assert %Account{archived_at: %DateTime{}} = Repo.get!(Account, ctx.account.id)
      assert Enum.all?(w.cancellable, &(Repo.get!(Post, &1.id).status == "failed"))
    end

    test "a post-delete failure is :unconfirmed and disconnect is still attempted", ctx do
      world!(ctx)
      Fake.fail_next(:delete, :unavailable)

      assert {:ok, _, %{vendor: {:unconfirmed, :unavailable}}} = remove(ctx)
      assert [_] = Fake.calls(:disconnect_account)
      assert %Account{archived_at: %DateTime{}} = Repo.get!(Account, ctx.account.id)
    end

    test "no configured publisher is :unconfirmed and the archive stands", ctx do
      select_publisher(nil)

      assert {:ok, _, %{vendor: {:unconfirmed, :publisher_not_configured}}} = remove(ctx)
      assert %Account{archived_at: %DateTime{}} = Repo.get!(Account, ctx.account.id)
    end

    test "removing twice: the second is :not_found with no vendor call", ctx do
      assert {:ok, _, _} = remove(ctx)
      Fake.reset()

      assert {:error, :not_found} = remove(ctx)

      assert {:error, :not_found} =
               Social.removal_preview(ctx.org_id, ctx.profile, ctx.account.id)

      assert Fake.calls() == []
    end
  end

  describe "reconnecting after removal" do
    test "the same ref connects a NEW row; both rows exist, only the new one is live", ctx do
      assert {:ok, _, _} = remove(ctx)

      assert {:ok, %Account{id: new_id}, _profile} =
               Social.add_account(ctx.org_id, ctx.profile, ctx.approver.id, "linkedin")

      refute new_id == ctx.account.id

      Fake.put_next(
        :list_accounts,
        {:ok,
         [
           %{
             ref: @ref,
             platform: "linkedin",
             profile_ref: @profile_ref,
             username: "brand",
             active?: true
           }
         ]}
      )

      assert {:ok, %Account{id: ^new_id, provider_account_ref: @ref}, :connected} =
               Social.complete_connect(ctx.org_id, ctx.profile, ctx.approver.id, %{
                 account_ref: @ref
               })

      rows = Repo.all(from(a in Account, where: a.provider_account_ref == ^@ref))
      assert length(rows) == 2
      assert [%Account{id: ^new_id}] = Enum.filter(rows, &is_nil(&1.archived_at))
    end
  end

  describe "under Zernio (Req.Test)" do
    test "a 503 on disconnect is :unconfirmed and the row IS archived", ctx do
      select_publisher(Zernio)
      {:ok, _} = Secrets.put_zernio_api_key("zk_remove_test_not_real", ctx.approver)
      test = self()

      Req.Test.stub(Zernio, fn conn ->
        send(test, {:zernio, conn.method, conn.request_path})
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
      end)

      assert {:ok, _, %{vendor: {:unconfirmed, _}}} = remove(ctx)
      assert %Account{archived_at: %DateTime{}} = Repo.get!(Account, ctx.account.id)
      assert_received {:zernio, "DELETE", "/api/v1/accounts/" <> @ref}
    end

    test "no Vault key is :unconfirmed, sends nothing, and the row IS archived", ctx do
      select_publisher(Zernio)
      test = self()

      Req.Test.stub(Zernio, fn conn ->
        send(test, {:zernio, conn.method, conn.request_path})
        conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})
      end)

      assert {:ok, _, %{vendor: {:unconfirmed, :credentials_unavailable}}} = remove(ctx)
      assert %Account{archived_at: %DateTime{}} = Repo.get!(Account, ctx.account.id)
      refute_received {:zernio, _, _}
    end
  end
end
