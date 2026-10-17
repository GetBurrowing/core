defmodule PlatformWeb.SocialZeroDataConnectAcceptanceTest do
  @moduledoc """
  Connect from zero social data, driven through the LiveView alone (task
  01a14801, stage 4).

  Earlier Social acceptance tests seeded rows the UI could not create (e.g.
  writing `provider_profile_ref` through `Social.update_profile/3`), which is
  how "no way to add an account" and "nothing creates the Zernio profile"
  shipped unseen. Here setup creates ONLY a live human user who is an
  internal member of one live org, using core's own schemas and fixtures,
  and asserts there are no social profiles, no social accounts and no
  Zernio key. Everything after that is a LiveView event:

    1. the empty-state create_profile form;
    2. Settings: save_zernio_key with an obvious fake key;
    3. Connections: "+ Add account", then submit linkedin;
    4. the external redirect to the stub's authUrl.

  The `Req.Test` stub records every request; the test asserts POST
  /v1/profiles came before GET /v1/connect/linkedin and that the connect
  used the profile id the stub returned. A source guard below reads this
  file's own setup block and refutes any Social or Vault write, so a later
  edit cannot quietly re-seed.

  No request leaves the BEAM (`config :social, :zernio_req_options`).
  `async: false`: the publisher config and the install-level Vault row are
  global.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Repo
  alias Platform.Social.{Account, Profile, Secrets}
  alias Platform.Social.Publisher.Zernio

  @auth_url "https://vendor.example.test/oauth"
  @vendor_profile_id "zprof_from_stub_1"
  @fake_key "sk_test_obviously_fake_key"

  setup do
    assert Repo.aggregate(from(p in "social_profiles"), :count) == 0
    assert Repo.aggregate(from(a in "social_accounts"), :count) == 0
    assert Secrets.zernio_key_status() == :not_set

    previous = Application.get_env(:social, :publisher)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
    Application.put_env(:social, :publisher, Zernio)

    n = System.unique_integer([:positive])
    org_id = Platform.TenancyFixtures.tenant_org_id("zero-data-org-#{n}")

    user =
      %Platform.Accounts.User{}
      |> Platform.Accounts.User.changeset(%{
        email: "zero-data-#{n}@example.com",
        name: "Zero Data #{n}",
        oidc_sub: "zero-data-#{n}"
      })
      |> Repo.insert!()

    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: "member"
    })
    |> Repo.insert!()

    %{user: user, org_id: org_id}
  end

  # Logs every Zernio request to the test process and answers the two calls
  # this flow makes. The test, not the stub, makes the assertions.
  defp stub_zernio do
    test = self()

    Req.Test.stub(Zernio, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:zernio_request, conn.method, conn.request_path, conn.query_params, raw})

      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/profiles"} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"message" => "created", "profile" => %{"_id" => @vendor_profile_id}})

        {"GET", "/api/v1/connect/" <> _} ->
          Req.Test.json(conn, %{"authUrl" => @auth_url})

        _ ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "unexpected"})
      end
    end)
  end

  defp drain_requests(acc \\ []) do
    receive do
      {:zernio_request, method, path, params, body} ->
        drain_requests([{method, path, params, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp goto(child, tab) do
    child |> element("[data-role='social-tab-button'][data-tab='#{tab}']") |> render_click()
    child
  end

  test "a human with no social data creates a profile, saves the key, adds LinkedIn and reaches Zernio",
       %{conn: conn, user: user} do
    stub_zernio()

    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social")
    child = find_live_child(view, "ext-page-social")
    Req.Test.allow(Zernio, self(), child.pid)

    # (1) The empty state's create form.
    assert has_element?(child, "form#social-create-form[phx-submit='create_profile']")

    child
    |> form("#social-create-form", profile: %{name: "Zero Data Brand", home_url: ""})
    |> render_submit()

    assert [%Profile{provider_profile_ref: nil} = created] = Repo.all(Profile)
    assert created.name == "Zero Data Brand"
    assert drain_requests() == []

    # (2) Settings: save the key through the form.
    child = goto(child, "settings")

    child
    |> form("[data-role='social-zernio-key-form']", zernio_key: %{api_key: @fake_key})
    |> render_submit()

    assert has_element?(child, "[data-role='social-zernio-key'][data-state='set']")
    assert {:set, _} = Secrets.zernio_key_status()
    assert drain_requests() == []

    # (3) Connections: "+ Add account", then linkedin.
    child = goto(child, "connections")
    refute has_element?(child, "[data-role='social-zernio-required']")
    child |> element("[data-role='social-add-account']") |> render_click()

    child
    |> form("#social-add-account-form", platform: "linkedin")
    |> render_submit()

    # The vendor profile was created BEFORE connect, and connect used its id.
    # Checked before the redirect so a skipped profile step fails HERE.
    requests = drain_requests()

    assert [
             {"POST", "/api/v1/profiles", _, profile_body},
             {"GET", "/api/v1/connect/linkedin", connect_params, _}
           ] = requests

    assert %{"name" => "Zero Data Brand", "externalId" => created_id} =
             Jason.decode!(profile_body)

    assert created_id == created.id
    assert connect_params["profileId"] == @vendor_profile_id

    # (4) Off to the stub's authUrl.
    assert_redirect(child, @auth_url)

    assert %Profile{provider_profile_ref: @vendor_profile_id} = Repo.get!(Profile, created.id)

    assert [%Account{platform: "linkedin", status: nil} = account] = Repo.all(Account)
    assert account.profile_id == created.id
  end

  describe "source guard" do
    # Reads THIS file's setup block. A setup that writes social rows or the
    # key directly would make the test above prove nothing about the UI.
    test "setup creates no social rows and writes no secrets" do
      source = File.read!(__ENV__.file)

      [setup_block] =
        Regex.run(~r/^  setup do\n(.*?)^  end\n/ms, source, capture: :all_but_first)

      # Non-vacuity: this really is the setup block above.
      assert setup_block =~ "Secrets.zernio_key_status() == :not_set"
      assert setup_block =~ "OrgMembership"

      for forbidden <- ["Social.create_", "update_profile", "put_zernio_api_key", "Vault.put"] do
        refute setup_block =~ forbidden,
               "setup must not call #{forbidden}: drive the LiveView instead"
      end
    end
  end
end
