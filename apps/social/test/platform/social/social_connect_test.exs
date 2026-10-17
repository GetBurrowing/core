defmodule Platform.Social.ConnectTest do
  @moduledoc """
  The add-account path (task 01a14801, stage 2): `connectable_platforms/0`,
  `ensure_provider_profile/2` and `add_account/4`.

  `async: false`: the Fake's call table is global, and some tests select the
  Zernio adapter through app env. Zernio traffic goes to `Req.Test` stubs
  ONLY; a stub that must not be reached flunks the test if it is.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{Account, Profile}
  alias Platform.Social.Publisher.{Fake, Zernio}

  @key "zernio-connect-test-key-not-real"

  setup do
    Fake.reset()
    org_id = org_id!()
    {:ok, profile} = Social.create_profile(org_id, %{name: "Connect #{unique()}"})
    approver = make_approver!(org_id, profile, user!())
    profile = Repo.get!(Profile, profile.id)
    %{org_id: org_id, profile: profile, approver: approver}
  end

  defp select_publisher(module) do
    previous = Application.get_env(:social, :publisher)
    Application.put_env(:social, :publisher, module)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
  end

  defp put_key! do
    {:ok, _} =
      Platform.Vault.put("social:zernio:api_key", :api_key, @key,
        scope: {:integration, nil},
        provider: "social"
      )

    :ok
  end

  defp refuse_any_request do
    Req.Test.stub(Zernio, fn _conn -> flunk("a request reached Zernio") end)
  end

  defp stub_profiles(status, response) do
    test = self()

    Req.Test.stub(Zernio, fn conn ->
      send(test, {:zernio, conn.method, conn.request_path})
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)
    end)
  end

  defp accounts(profile), do: Repo.all(from(a in Account, where: a.profile_id == ^profile.id))
  defp ref(profile), do: Repo.get!(Profile, profile.id).provider_profile_ref

  describe "connectable_platforms/0" do
    test "is Account.platforms/0 filtered to the publisher's platforms" do
      assert Social.connectable_platforms() == Account.platforms()
      select_publisher(Zernio)
      assert Social.connectable_platforms() == Zernio.platforms()
    end

    test "is [] when no publisher is configured" do
      select_publisher(nil)
      assert Social.connectable_platforms() == []
    end
  end

  describe "ensure_provider_profile/2 under the Fake" do
    test "leaves the ref nil and sends nothing to Zernio", ctx do
      refuse_any_request()

      assert {:ok, %Profile{provider_profile_ref: nil}} =
               Social.ensure_provider_profile(ctx.org_id, ctx.profile)

      assert [{:ensure_profile, _, _}] = Fake.calls()
      assert ref(ctx.profile) == nil
    end

    test "a present ref answers the profile with NO publisher call", ctx do
      {:ok, _} =
        ctx.profile |> Ecto.Changeset.change(provider_profile_ref: "zprof_had") |> Repo.update()

      Fake.put_next(:ensure_profile, {:ok, "zprof_other"})

      assert {:ok, %Profile{provider_profile_ref: "zprof_had"}} =
               Social.ensure_provider_profile(ctx.org_id, ctx.profile.id)

      assert Fake.calls(:ensure_profile) == []
      assert ref(ctx.profile) == "zprof_had"
    end

    test "{:ok, ref} writes only the ref", ctx do
      Fake.put_next(:ensure_profile, {:ok, "zprof_new"})
      assert {:ok, updated} = Social.ensure_provider_profile(ctx.org_id, ctx.profile)
      assert updated.provider_profile_ref == "zprof_new"

      assert Map.drop(Map.from_struct(Repo.get!(Profile, ctx.profile.id)), [
               :provider_profile_ref,
               :updated_at
             ]) ==
               Map.drop(Map.from_struct(ctx.profile), [:provider_profile_ref, :updated_at])
    end

    test "another org's profile is :not_found and nothing is called", ctx do
      assert {:error, :not_found} = Social.ensure_provider_profile(org_id!(), ctx.profile)
      assert Fake.calls() == []
    end

    test "create_profile/2 never calls the publisher" do
      refuse_any_request()
      assert {:ok, profile} = Social.create_profile(org_id!(), %{name: "Fresh #{unique()}"})
      assert profile.provider_profile_ref == nil
      assert Fake.calls() == []
    end
  end

  describe "ensure_provider_profile/2 under Zernio" do
    setup do
      select_publisher(Zernio)
      put_key!()
    end

    test "the first call POSTs and stores the ref; the second makes no request", ctx do
      stub_profiles(201, %{"message" => "created", "profile" => %{"_id" => "zprof_z1"}})

      assert {:ok, %Profile{provider_profile_ref: "zprof_z1"}} =
               Social.ensure_provider_profile(ctx.org_id, ctx.profile)

      assert_received {:zernio, "POST", "/api/v1/profiles"}
      assert ref(ctx.profile) == "zprof_z1"

      refuse_any_request()

      assert {:ok, %Profile{provider_profile_ref: "zprof_z1"}} =
               Social.ensure_provider_profile(ctx.org_id, ctx.profile)

      refute_received {:zernio, _, _}
    end

    test "create_profile/2 sends nothing to Zernio" do
      refuse_any_request()

      assert {:ok, %Profile{provider_profile_ref: nil}} =
               Social.create_profile(org_id!(), %{name: "Fresh #{unique()}"})
    end

    test "a vendor error stores no ref and add_account writes no row", ctx do
      stub_profiles(500, %{"error" => "down"})

      assert {:error, _} = Social.ensure_provider_profile(ctx.org_id, ctx.profile)
      assert ref(ctx.profile) == nil

      assert {:error, _} =
               Social.add_account(ctx.org_id, ctx.profile, ctx.approver.id, "linkedin")

      assert ref(ctx.profile) == nil
      assert accounts(ctx.profile) == []
    end

    test "add_account stores the ref and creates the row", ctx do
      stub_profiles(201, %{"message" => "created", "profile" => %{"_id" => "zprof_z2"}})

      assert {:ok, %Account{platform: "x"} = account, %Profile{provider_profile_ref: "zprof_z2"}} =
               Social.add_account(ctx.org_id, ctx.profile, ctx.approver.id, "x")

      assert [%Account{id: id}] = accounts(ctx.profile)
      assert id == account.id
    end
  end

  describe "add_account/4" do
    test "creates a never-connected row, ensuring the profile first", ctx do
      assert {:ok, account, %Profile{}} =
               Social.add_account(ctx.org_id, ctx.profile, ctx.approver.id, "linkedin")

      assert %Account{platform: "linkedin", status: nil, provider_account_ref: nil} = account
      assert account.approval_mode == "approve_first"
      assert [{:ensure_profile, _, _}] = Fake.calls()
      assert Fake.calls(:connect_url) == []
    end

    test "a vendor failure leaves no account row", ctx do
      Fake.fail_next(:ensure_profile, :vendor_down)

      assert {:error, :vendor_down} =
               Social.add_account(ctx.org_id, ctx.profile, ctx.approver.id, "linkedin")

      assert accounts(ctx.profile) == []
      assert ref(ctx.profile) == nil
    end

    test "reuses the never-connected row: adding twice makes no duplicate", ctx do
      {:ok, first, _} = Social.add_account(ctx.org_id, ctx.profile, ctx.approver.id, "tiktok")
      {:ok, second, _} = Social.add_account(ctx.org_id, ctx.profile, ctx.approver.id, "tiktok")

      assert second.id == first.id
      assert [%Account{id: id}] = accounts(ctx.profile)
      assert id == first.id
    end

    test "a connected row, an archived row or another platform's row is not reused", ctx do
      {:ok, connected} =
        Social.create_account(ctx.org_id, ctx.profile, %{
          platform: "instagram",
          status: "connected",
          provider_account_ref: "zacct_1"
        })

      {:ok, archived} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "instagram"})
      {:ok, _} = Social.archive_account(ctx.org_id, archived)
      {:ok, other} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "youtube"})

      assert {:ok, added, _} =
               Social.add_account(ctx.org_id, ctx.profile, ctx.approver.id, "instagram")

      refute added.id in [connected.id, archived.id, other.id]
      assert length(accounts(ctx.profile)) == 4
    end

    test "an unsupported platform is refused with no row and no publisher call", ctx do
      assert {:error, :unsupported_platform} =
               Social.add_account(ctx.org_id, ctx.profile, ctx.approver.id, "myspace")

      select_publisher(nil)

      assert {:error, :unsupported_platform} =
               Social.add_account(ctx.org_id, ctx.profile, ctx.approver.id, "linkedin")

      assert accounts(ctx.profile) == []
      assert Fake.calls() == []
    end

    test "another org cannot add to the profile", ctx do
      assert {:error, :not_found} =
               Social.add_account(org_id!(), ctx.profile, ctx.approver.id, "linkedin")

      assert accounts(ctx.profile) == []
    end
  end

  describe "add_account/4 refuses anyone but a live human approver" do
    test "a non-approver human: :not_an_approver, no row; the approver then succeeds", ctx do
      outsider = member!(user!(), ctx.org_id)

      assert {:error, :not_an_approver} =
               Social.add_account(ctx.org_id, ctx.profile, outsider.id, "linkedin")

      assert accounts(ctx.profile) == []
      assert Fake.calls() == []

      assert {:ok, _, _} =
               Social.add_account(ctx.org_id, ctx.profile, ctx.approver.id, "linkedin")
    end

    test "an agent id: :not_a_human, no row; the approver then succeeds", ctx do
      agent = agent!()

      assert {:error, :not_a_human} =
               Social.add_account(ctx.org_id, ctx.profile, agent.id, "linkedin")

      assert accounts(ctx.profile) == []
      assert Fake.calls() == []

      assert {:ok, _, _} =
               Social.add_account(ctx.org_id, ctx.profile, ctx.approver.id, "linkedin")
    end

    test "an archived approver: :approver_archived, no row; a live approver then succeeds",
         ctx do
      archived = make_approver!(ctx.org_id, ctx.profile, user!())
      {:ok, _} = Platform.Accounts.archive_user(archived)

      assert {:error, :approver_archived} =
               Social.add_account(ctx.org_id, ctx.profile, archived.id, "linkedin")

      assert accounts(ctx.profile) == []
      assert Fake.calls() == []

      assert {:ok, _, _} =
               Social.add_account(ctx.org_id, ctx.profile, ctx.approver.id, "linkedin")
    end
  end
end
