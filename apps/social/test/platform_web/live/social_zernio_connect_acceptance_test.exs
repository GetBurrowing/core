defmodule PlatformWeb.SocialZernioConnectAcceptanceTest do
  @moduledoc """
  The end-to-end Connect flow under the Zernio publisher (task 01a14722,
  stage 4). Zernio is selected the way prod selects it,
  `Platform.Social.RuntimeConfig.apply/1` with `SOCIAL_PUBLISHER=zernio`,
  never a direct put_env of the module; on_exit puts the Fake back.

  A human approver saves a test key through the Settings form (not
  `Vault.put`), opens Connections and clicks Connect. The `Req.Test` stub
  records what the LiveView sent; the TEST asserts the method, path,
  `authorization: Bearer <that key>` and the profileId / redirect_url
  params, so a stub that ignored auth could not make it pass. The stub
  answers `authUrl` and the LiveView must redirect there.

  No request leaves the BEAM: `config :social, :zernio_req_options` routes
  every Zernio call to `Req.Test`. Keys here are obvious fakes.

  `async: false`: the publisher config and the install-level Vault row are
  global.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialApprovalFixtures

  alias Platform.Social
  alias Platform.Social.Publisher.{Fake, Zernio}
  alias Platform.Social.RuntimeConfig

  @auth_url "https://vendor.example.test/oauth"
  @connect "[data-role='social-account-connect']"

  setup do
    Fake.reset()
    previous = Application.get_env(:social, :publisher)
    assert previous == Fake
    on_exit(fn -> Application.put_env(:social, :publisher, Fake) end)

    :ok = RuntimeConfig.apply(%{"SOCIAL_PUBLISHER" => "zernio"})
    assert Application.get_env(:social, :publisher) == Zernio

    fx = approval_fixture()

    {:ok, account} =
      Social.update_account(fx.org_id, fx.a, %{provider_account_ref: "zacct_test_1"})

    {:ok, profile} =
      Social.update_profile(fx.org_id, fx.profile, %{provider_profile_ref: "zprof_test_1"})

    Map.merge(fx, %{account: account, profile: profile, key: "sk_test_not_a_real_key"})
  end

  # Every Zernio request the LiveView sends is reported to the test process,
  # which makes the assertions; the stub itself checks nothing.
  defp record_requests(answer) do
    test = self()

    Req.Test.stub(Zernio, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      send(
        test,
        {:zernio_request, conn.method, conn.request_path, conn.query_params, conn.req_headers}
      )

      answer.(conn)
    end)
  end

  defp open(conn, user, tab) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social")
    child = find_live_child(view, "ext-page-social")
    Req.Test.allow(Zernio, self(), child.pid)
    goto(child, tab)
  end

  defp goto(child, tab) do
    child |> element("[data-role='social-tab-button'][data-tab='#{tab}']") |> render_click()
    child
  end

  defp save_key(child, value) do
    child
    |> form("[data-role='social-zernio-key-form']", zernio_key: %{api_key: value})
    |> render_submit()

    assert has_element?(child, "[data-role='social-zernio-key'][data-state='set']")
    child
  end

  defp connect_button(account), do: @connect <> "[phx-value-id='#{account.id}']"

  test "a human approver saves the key in Settings, clicks Connect, and is sent to Zernio's authUrl",
       %{conn: conn} = ctx do
    record_requests(fn
      %{request_path: "/api/v1/accounts"} = conn -> Req.Test.json(conn, %{"accounts" => []})
      conn -> Req.Test.json(conn, %{"authUrl" => @auth_url})
    end)

    child = conn |> open(ctx.h1, "settings") |> save_key(ctx.key) |> goto("connections")

    refute has_element?(child, "[data-role='social-zernio-required']")

    # Opening Connections with a never-connected row (the fixture's `d`)
    # asks the vendor's account list once (task 01a14807); nothing is listed.
    assert_receive {:zernio_request, "GET", "/api/v1/accounts", %{"profileId" => "zprof_test_1"},
                    _headers}

    child |> element(connect_button(ctx.account)) |> render_click()

    assert_receive {:zernio_request, "GET", path, params, headers}
    assert path == "/api/v1/connect/linkedin"
    assert {"authorization", "Bearer " <> ctx.key} in headers

    assert params == %{
             "profileId" => "zprof_test_1",
             "redirect_url" => PlatformWeb.Endpoint.url() <> "/m/social"
           }

    assert_redirect(child, @auth_url)
    refute_received {:zernio_request, _, _, _, _}
  end

  test "before a key is saved: Connect is hidden, the notice shows, and a forged connect sends nothing",
       %{conn: conn} = ctx do
    record_requests(&Req.Test.json(&1, %{"authUrl" => @auth_url}))

    child = open(conn, ctx.h1, "connections")

    assert has_element?(
             child,
             "[data-role='social-zernio-required']",
             "Add the Zernio API key in Settings before connecting accounts."
           )

    refute has_element?(child, @connect)

    render_hook(child, "connect_account", %{"id" => ctx.account.id})

    assert Process.alive?(child.pid)
    refute_received {:zernio_request, _, _, _, _}

    assert has_element?(
             child,
             "[data-role='social-notice']",
             "Add the Zernio API key in Settings first."
           )

    # Positive control: the same page, once the key is saved, does send.
    child |> goto("settings") |> save_key(ctx.key) |> goto("connections")
    child |> element(connect_button(ctx.account)) |> render_click()
    assert_receive {:zernio_request, "GET", "/api/v1/connect/linkedin", _, _}
    assert_redirect(child, @auth_url)
  end

  test "with the key saved but the publisher unset, Connect says publishing isn't configured",
       %{conn: conn} = ctx do
    record_requests(&Req.Test.json(&1, %{"authUrl" => @auth_url}))

    child = conn |> open(ctx.h1, "settings") |> save_key(ctx.key)

    Application.delete_env(:social, :publisher)
    :ok = RuntimeConfig.apply(%{})
    assert Application.get_env(:social, :publisher) == nil

    goto(child, "connections")
    child |> element(connect_button(ctx.account)) |> render_click()

    assert Process.alive?(child.pid)
    refute_received {:zernio_request, _, _, _, _}

    assert has_element?(
             child,
             "[data-role='social-notice']",
             "Publishing isn't configured on this install."
           )
  end
end
