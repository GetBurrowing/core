defmodule PlatformWeb.SocialZeroDataReturnAcceptanceTest do
  @moduledoc """
  The OAuth return and the Connections pickup from zero social data, driven
  through the LiveView alone (task 01a14807, stage 5).

  Same discipline as `social_zero_data_connect_acceptance_test.exs`: setup
  creates ONLY a live human user who is an internal member of one live org,
  using core's own schemas and fixtures, and asserts there are no social
  profiles, no social accounts and no Zernio key. Everything after that is a
  LiveView event or a `live/2` mount of a URL:

    1. the empty-state create_profile form;
    2. Settings: save_zernio_key with an obvious fake key;
    3. Connections: "+ Add account", then a platform, and the external
       redirect (whose `redirect_url` must point back at `/m/social`);
    4. either the vendor's return URL (`?connected=...&accountId=...`) or a
       plain `/m/social` mount followed by opening Connections.

  The `Req.Test` stub records every request (method, path, query, body and
  whether Authorization was sent) and answers `GET /api/v1/accounts` from a
  list the test controls through an Agent. A source guard below reads this
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
  @vendor_profile_id "zprof_zero_1"
  @fake_key "zk_test_9f3a"

  setup do
    assert Repo.aggregate(from(p in "social_profiles"), :count) == 0
    assert Repo.aggregate(from(a in "social_accounts"), :count) == 0
    assert Secrets.zernio_key_status() == :not_set

    previous = Application.get_env(:social, :publisher)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
    Application.put_env(:social, :publisher, Zernio)

    n = System.unique_integer([:positive])
    org_id = Platform.TenancyFixtures.tenant_org_id("zero-return-org-#{n}")

    user =
      %Platform.Accounts.User{}
      |> Platform.Accounts.User.changeset(%{
        email: "zero-return-#{n}@example.com",
        name: "Zero Return #{n}",
        oidc_sub: "zero-return-#{n}"
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

  # Logs every Zernio request to the test process and answers the three
  # calls these flows make. The account list comes from `listed`, an Agent
  # the test edits between steps. The test, not the stub, asserts.
  defp stub_zernio do
    test = self()
    listed = start_supervised!({Agent, fn -> [] end})

    Req.Test.stub(Zernio, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      auth? = Plug.Conn.get_req_header(conn, "authorization") != []

      send(
        test,
        {:zernio_request, conn.method, conn.request_path, conn.query_params, raw, auth?}
      )

      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/profiles"} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"message" => "created", "profile" => %{"_id" => @vendor_profile_id}})

        {"GET", "/api/v1/connect/" <> _} ->
          Req.Test.json(conn, %{"authUrl" => @auth_url})

        {"GET", "/api/v1/accounts"} ->
          entries =
            listed
            |> Agent.get(& &1)
            |> Enum.filter(&(get_in(&1, ["profileId", "_id"]) == conn.query_params["profileId"]))

          Req.Test.json(conn, %{"accounts" => entries, "hasAnalyticsAccess" => false})

        _ ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "unexpected"})
      end
    end)

    listed
  end

  defp list!(listed, entry), do: Agent.update(listed, &(&1 ++ [entry]))

  defp drain_requests(acc \\ []) do
    receive do
      {:zernio_request, method, path, params, body, auth?} ->
        drain_requests([{method, path, params, body, auth?} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp land(user, url) do
    conn = Plug.Test.init_test_session(build_conn(), current_user_id: user.id)
    {:ok, view, _html} = live(conn, url)
    child = find_live_child(view, "ext-page-social")
    Req.Test.allow(Zernio, self(), child.pid)
    child
  end

  defp goto(child, tab) do
    child |> element("[data-role='social-tab-button'][data-tab='#{tab}']") |> render_click()
    child
  end

  defp row(%Account{id: id}), do: "#accounts-#{id}"
  defp notice?(child, text), do: has_element?(child, "[data-role='social-notice']", text)

  # Steps 1-3, UI only: create the profile from the empty state, save the
  # key in Settings, then "+ Add account" for `platform` up to the redirect.
  # Returns the created profile and the GET /v1/connect params.
  defp create_profile_save_key(user) do
    child = land(user, "/m/social")

    assert has_element?(child, "form#social-create-form[phx-submit='create_profile']")

    child
    |> form("#social-create-form", profile: %{name: "Zero Show", home_url: ""})
    |> render_submit()

    assert [%Profile{provider_profile_ref: nil} = created] = Repo.all(Profile)
    assert drain_requests() == []

    child = goto(child, "settings")

    child
    |> form("[data-role='social-zernio-key-form']", zernio_key: %{api_key: @fake_key})
    |> render_submit()

    assert has_element?(child, "[data-role='social-zernio-key'][data-state='set']")
    assert {:set, _} = Secrets.zernio_key_status()
    assert drain_requests() == []

    {child, created}
  end

  defp add_account(child, platform) do
    child = goto(child, "connections")
    refute has_element?(child, "[data-role='social-zernio-required']")
    child |> element("[data-role='social-add-account']") |> render_click()

    child
    |> form("#social-add-account-form", platform: platform)
    |> render_submit()

    requests = drain_requests()
    assert_redirect(child, @auth_url)
    requests
  end

  test "zero data to connected: the vendor's return URL marks the LinkedIn row connected",
       %{user: user} do
    listed = stub_zernio()
    {child, created} = create_profile_save_key(user)

    # (3) "+ Add account", linkedin: profile created first, then connect,
    # and the return address Zernio is handed points back at /m/social.
    assert [
             {"POST", "/api/v1/profiles", _, _, true},
             {"GET", "/api/v1/connect/linkedin", connect_params, _, true}
           ] = add_account(child, "linkedin")

    assert connect_params["profileId"] == @vendor_profile_id
    assert String.ends_with?(connect_params["redirect_url"], "/m/social")

    assert %Profile{provider_profile_ref: @vendor_profile_id} = Repo.get!(Profile, created.id)

    assert [%Account{platform: "linkedin", status: nil, provider_account_ref: nil} = pending] =
             Repo.all(Account)

    # (4) Zernio now lists the account, and the browser comes back.
    list!(listed, %{
      "_id" => "zacc_li_1",
      "platform" => "linkedin",
      "profileId" => %{"_id" => @vendor_profile_id},
      "username" => "zeroshow",
      "isActive" => true
    })

    return_url =
      "/m/social?connected=linkedin&profileId=#{@vendor_profile_id}" <>
        "&accountId=zacc_li_1&username=zeroshow"

    child = land(user, return_url)

    assert [{"GET", "/api/v1/accounts", %{"profileId" => @vendor_profile_id}, _, true}] =
             drain_requests()

    assert has_element?(child, row(pending) <> " [data-state='connected']")
    assert has_element?(child, row(pending) <> " [data-role='social-account-handle']", "zeroshow")
    refute has_element?(child, row(pending) <> " [data-role='social-account-connect']")
    assert notice?(child, "LinkedIn connected as zeroshow.")

    connected = Repo.get!(Account, pending.id)
    assert connected.provider_account_ref == "zacc_li_1"
    assert connected.status == "connected"
    assert connected.handle == "zeroshow"

    # (5) The SAME URL again: already connected, one row, no write.
    child = land(user, return_url)

    assert notice?(child, "LinkedIn is already connected.")
    assert has_element?(child, row(pending) <> " [data-state='connected']")
    assert [%Account{id: only_id} = only] = Repo.all(Account)
    assert only_id == pending.id
    assert only.updated_at == connected.updated_at
    assert only.provider_account_ref == "zacc_li_1"

    assert [{"GET", "/api/v1/accounts", %{"profileId" => @vendor_profile_id}, _, true}] =
             drain_requests()
  end

  test "zero data to connected without a return: opening Connections picks up X from Zernio",
       %{user: user} do
    listed = stub_zernio()
    {child, _created} = create_profile_save_key(user)

    assert [
             {"POST", "/api/v1/profiles", _, _, true},
             {"GET", "/api/v1/connect/twitter", connect_params, _, true}
           ] = add_account(child, "x")

    assert connect_params["profileId"] == @vendor_profile_id

    assert [%Account{platform: "x", status: nil, provider_account_ref: nil} = pending] =
             Repo.all(Account)

    # Connected at Zernio, but the browser never came back to us.
    list!(listed, %{
      "_id" => "zacc_x_1",
      "platform" => "twitter",
      "profileId" => %{"_id" => @vendor_profile_id},
      "username" => "zerox",
      "isActive" => true
    })

    # A plain mount: no return parameters, and nothing asked of Zernio yet.
    child = land(user, "/m/social")
    assert drain_requests() == []
    refute has_element?(child, row(pending) <> " [data-state='connected']")

    child = goto(child, "connections")

    assert [{"GET", "/api/v1/accounts", %{"profileId" => @vendor_profile_id}, _, true}] =
             drain_requests()

    assert has_element?(child, row(pending) <> " [data-state='connected']")
    assert has_element?(child, row(pending) <> " [data-role='social-account-handle']", "zerox")
    assert notice?(child, "Picked up 1 connected")

    picked = Repo.get!(Account, pending.id)
    assert picked.provider_account_ref == "zacc_x_1"
    assert picked.status == "connected"
    assert [_only] = Repo.all(Account)
  end

  describe "source guard" do
    # Reads THIS file's setup block. A setup that writes social rows or the
    # key directly would make the tests above prove nothing about the UI.
    test "setup creates no social rows and writes no secrets" do
      source = File.read!(__ENV__.file)

      [setup_block] =
        Regex.run(~r/^  setup do\n(.*?)^  end\n/ms, source, capture: :all_but_first)

      # Non-vacuity: this really is the setup block above.
      assert setup_block =~ "Secrets.zernio_key_status() == :not_set"
      assert setup_block =~ "OrgMembership"

      for forbidden <- [
            "Social.",
            "update_profile",
            "put_zernio_api_key",
            "Vault.put",
            "provider_account_ref",
            "provider_profile_ref",
            "SocialFixtures"
          ] do
        refute setup_block =~ forbidden,
               "setup must not use #{forbidden}: drive the LiveView instead"
      end

      # Repo inserts only for core's user and membership, never a social table.
      refute setup_block =~ ~r/insert(_all)?!?\(\s*"social_/
      refute setup_block =~ ~r/%(Profile|Account|Post)\{/
    end
  end
end
