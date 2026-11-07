defmodule PlatformWeb.SupportAccessFlowTest do
  @moduledoc """
  Vendor support access over HTTP and LiveView (task 01a1b362 stage 1, ADR
  0059): the grant endpoint's statuses, sign-in through `/auth/support`, the
  admin page, and expiry bouncing both a fresh request and a LiveView that
  stayed connected.
  """
  # Not async: the support access config is global application env.
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.SupportAccessFixtures

  alias Platform.Accounts.User
  alias Platform.Audit.Event
  alias Platform.Repo
  alias Platform.SupportAccess
  alias Platform.SupportAccess.Session
  alias Platform.Tenancy

  @grants "/api/support-access/v1/grants"

  setup ctx do
    ctx = setup_support_access(ctx)
    set_enabled!(true)
    ctx
  end

  defp post_grant(conn, raw, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> post(@grants, raw)
  end

  defp grant(conn, ctx, overrides \\ %{}, opts \\ []) do
    {raw, headers} = sign(grant_body(overrides), ctx, opts)
    post_grant(conn, raw, headers)
  end

  defp code_of(url), do: url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("code")

  defp expire!(session_id) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)
    from(s in Session, where: s.id == ^session_id) |> Repo.update_all(set: [not_after: past])
  end

  describe "POST /api/support-access/v1/grants" do
    test "each refusal has its own status", %{conn: conn} = ctx do
      {_pub, other} = :crypto.generate_key(:eddsa, :ed25519)
      now = System.os_time(:second)

      assert json_response(grant(conn, ctx, %{}, key: other), 401) == %{"error" => "bad_signature"}

      assert json_response(
               grant(conn, ctx, %{"install_id" => "99999999-2222-4333-8444-555555555555"}),
               421
             ) == %{"error" => "wrong_install"}

      assert json_response(grant(conn, ctx, %{"expires_at" => now - 1}), 410) == %{
               "error" => "grant_expired"
             }

      assert json_response(grant(conn, ctx, %{"duration_s" => 99_999}), 422) == %{
               "error" => "duration_too_long"
             }

      {raw, headers} = sign(grant_body(%{"kind" => "repair"}), ctx)
      assert %{"principal" => _} = json_response(post_grant(conn, raw, headers), 201)
      assert json_response(post_grant(conn, raw, headers), 409) == %{"error" => "replayed_nonce"}

      set_enabled!(false)

      assert json_response(grant(conn, ctx), 403) == %{"error" => "support_access_off"}
    end

    test "with no vendor key configured the route is absent", %{conn: conn} = ctx do
      Application.put_env(
        :platform,
        :support_access,
        Keyword.put(Application.get_env(:platform, :support_access), :vendor_keys, %{})
      )

      assert conn |> grant(ctx) |> response(404)
    end

    test "unsigned junk is rate limited and never audited", %{conn: conn} = ctx do
      Application.put_env(
        :platform,
        :support_access,
        Keyword.put(Application.get_env(:platform, :support_access), :junk_rate_per_hour, 2)
      )

      for _ <- 1..2 do
        assert conn |> put_req_header("content-type", "application/json") |> post(@grants, "{}") |> response(401)
      end

      assert json_response(grant(conn, ctx), 429) == %{"error" => "rate_limited"}
      assert Repo.all(from(e in Event, where: like(e.event_type, "support.%"))) == []
    end
  end

  describe "admin grant to sign-in to admin page to expiry" do
    test "expiry archives the user, disconnects the socket and bounces the next request",
         %{conn: conn} = ctx do
      body = json_response(grant(conn, ctx, %{"duration_s" => 3600}), 201)
      assert %{"session_id" => sid, "sign_in_url" => url, "not_after" => _} = body

      signed_in = get(build_conn(), "/auth/support", %{"code" => code_of(url)})
      assert redirected_to(signed_in) == "/"
      assert get_session(signed_in, :support_session_id) == sid
      assert get_session(signed_in, :live_socket_id) == "support_session:" <> sid

      # The code is single use; every refusal looks the same.
      again = get(build_conn(), "/auth/support", %{"code" => code_of(url)})
      bogus = get(build_conn(), "/auth/support", %{"code" => "bogus"})
      assert response(again, 401) == response(bogus, 401)

      conn = recycle(signed_in)
      {:ok, view, html} = live(conn, ~p"/admin/link-unfurls")
      assert html =~ "Show link previews"

      user = Repo.get_by!(User, email: "pat.operator@support.test")
      assert Tenancy.root_admin?(user)

      PlatformWeb.Endpoint.subscribe(SupportAccess.live_socket_id(sid))

      # Time passes: the session is past not_after, the sweeper has not run.
      expire!(sid)

      # The LiveView that stayed connected is bounced on its next event...
      assert {:error, {:redirect, %{to: "/auth/login"}}} =
               view |> element("#admin-link-unfurls-form") |> render_change(%{})

      # ...a fresh mount is refused...
      assert {:error, {:redirect, %{to: "/auth/login"}}} = live(recycle(signed_in), ~p"/admin/link-unfurls")

      # ...and so is the next HTTP request, which also drops the session.
      bounced = get(recycle(signed_in), ~p"/chat")
      assert redirected_to(bounced) == "/auth/login"

      # The sweep ends it: archived, admin revoked, socket disconnected.
      [ended] = SupportAccess.end_expired()
      assert ended.id == sid
      assert ended.end_reason == "expired"
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: "support_session:" <> ^sid}

      user = Repo.get!(User, user.id)
      assert user.archived_at
      assert user.archived_reason == "support_session_ended"
      refute Tenancy.root_admin?(user)

      assert [_] = Repo.all(from(e in Event, where: e.event_type == "support.session_ended"))
    end

    test "a LiveView's timer bounces it at not_after with no event", %{conn: conn} = ctx do
      body = json_response(grant(conn, ctx), 201)
      signed_in = get(build_conn(), "/auth/support", %{"code" => code_of(body["sign_in_url"])})
      {:ok, view, _html} = live(recycle(signed_in), ~p"/admin/link-unfurls")

      expire!(body["session_id"])
      send(view.pid, :support_session_check)
      assert_redirect(view, "/auth/login")
    end

    test "support.action rows for HTTP and LiveView carry a params hash, never values",
         %{conn: conn} = ctx do
      body = json_response(grant(conn, ctx), 201)
      signed_in = get(build_conn(), "/auth/support", %{"code" => code_of(body["sign_in_url"])})

      # HTTP: a non-GET on a :require_auth_api route.
      recycle(signed_in)
      |> put_req_header("content-type", "application/json")
      |> patch("/api/messages/#{Ecto.UUID.generate()}", %{"content" => "secret-http-value"})

      # LiveView: one handle_event.
      {:ok, view, _html} = live(recycle(signed_in), ~p"/admin/link-unfurls")

      view
      |> element("#admin-link-unfurls-form")
      |> render_change(%{"settings" => %{"enabled" => "true"}, "note" => "secret-live-value"})

      actions = Repo.all(from(e in Event, where: e.event_type == "support.action", order_by: e.id))
      assert [http, live_event | _] = actions
      assert http.metadata["method"] == "PATCH"
      assert http.metadata["route"] =~ "/api/messages/"
      assert live_event.metadata["kind"] == "live_event"
      assert live_event.metadata["view"] =~ "AdminLinkUnfurlsLive"
      assert is_binary(live_event.metadata["event"])

      for a <- actions do
        assert byte_size(a.metadata["params_sha256"]) == 64
        assert a.metadata["support_session_id"] == body["session_id"]
        dumped = Jason.encode!(a.metadata)
        refute dumped =~ "secret-http-value"
        refute dumped =~ "secret-live-value"
      end
    end

    test "a non-support user is unaffected and writes no support.action", %{conn: conn} do
      admin = Platform.TenancyFixtures.root_admin!()
      conn = init_test_session(conn, %{"current_user_id" => admin.id})
      {:ok, view, _} = live(conn, ~p"/admin/link-unfurls")
      view |> element("#admin-link-unfurls-form") |> render_change(%{})
      assert Repo.all(from(e in Event, where: e.event_type == "support.action")) == []
    end
  end
end
