defmodule PlatformWeb.ChatLiveExternalHostMountTest do
  @moduledoc """
  Mount coverage for the INERT `chat.` host scope's `:external_chat`
  live_session (rbac-external-users M4 stage 2, task 019f8837).

  Proves the dark scaffold's positive path: with an authenticated session,
  hitting `/chat` under the `chat.` host resolves ChatLive under the
  `:external_chat` live_session with the shell-less `:external` layout, and
  ChatLive MOUNTS AND RENDERS WITHOUT CRASHING while inert (M4 reuses the
  authenticated on_mount chain so the current ChatLive template's assigns
  are all present — M5 branches the mount, M6/M7 add scope auth).

  The adversarial / dormancy-contract counterpart (surface limitation,
  non-shadowing, host disambiguation of the overlapping `/chat`, and
  dormancy-by-config) lives in `router_external_chat_host_test.exs`.

  `async: false` — mirrors `meeting_live_guest_mount_test.exs`; keeps the
  host-swapped conn cases off the shared async pool.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  # A `chat.`-prefixed host makes the `:external_chat` scope win the match;
  # the default `localhost`/`www.example.com` host falls through to
  # `:authenticated`. Mirrors meet_mount's `with_meet_host/1`.
  defp with_chat_host(conn, host \\ "chat.localhost") do
    %{conn | host: host}
  end

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "external_host_mount_#{System.unique_integer([:positive])}@example.com",
        name: "External Host Mount User",
        oidc_sub: "oidc-external-host-mount-#{System.unique_integer([:positive])}",
        avatar_url: nil
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_channel do
    slug = "ext-host-#{System.unique_integer([:positive])}"

    {:ok, ch} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel"
      })

    ch
  end

  # `GET /chat` redirects to the first space when one exists (ChatLive
  # handle_params catch-all `push_navigate/2`). Follow one hop and hand
  # back the landed view/HTML — the landing target `/chat/:space_slug` is
  # in the SAME live_session, so the layout/session under test is unchanged.
  defp live_settled(conn, path) do
    case live(conn, path) do
      {:error, {redirect_kind, %{to: to}}} when redirect_kind in [:live_redirect, :redirect] ->
        live(conn, to)

      ok ->
        ok
    end
  end

  defp live_session_for(method, path, host) do
    case Phoenix.Router.route_info(PlatformWeb.Router, method, path, host) do
      %{phoenix_live_view: {_view, _action, _opts, %{name: name}}} -> name
      other -> other
    end
  end

  describe "route resolution (host disambiguation of the overlapping /chat)" do
    test "the SAME /chat path resolves to :external_chat under the chat host and :authenticated under the default host" do
      assert live_session_for("GET", "/chat", "chat.localhost") == :external_chat
      assert live_session_for("GET", "/chat", "localhost") == :authenticated

      # And the parameterized show route disambiguates identically.
      assert live_session_for("GET", "/chat/anything", "chat.localhost") == :external_chat
      assert live_session_for("GET", "/chat/anything", "localhost") == :authenticated
    end
  end

  describe "external chat mount (chat_mode: external) — inert scaffold" do
    setup %{conn: conn} do
      %{conn: authenticated_conn(conn), space: create_channel()}
    end

    test "GET /chat on chat.localhost mounts ChatLive under the shell-less :external layout without crashing",
         %{conn: conn} do
      {:ok, _view, html} =
        conn
        |> with_chat_host()
        |> live_settled("/chat")

      # Shell-less :external app layout wrapper (see Layouts.external/1).
      assert html =~ ~s(class="h-dvh bg-base-100 text-base-content")

      # NONE of the `:shell` layout chrome (desktop sidebar /
      # route-resume singleton hook) leaked onto the external surface.
      refute html =~ ~s(id="sidebar")
      refute html =~ ~s(id="sidebar")
      refute html =~ ~s(id="route-resume")
    end

    test "GET /chat/:space_slug on chat.localhost mounts ChatLive :show under :external without crashing",
         %{conn: conn, space: space} do
      {:ok, _view, html} =
        conn
        |> with_chat_host()
        |> live_settled("/chat/#{space.slug}")

      assert html =~ ~s(class="h-dvh bg-base-100 text-base-content")
      refute html =~ ~s(id="sidebar")
    end

    test "CONTROL: GET /chat on the default host still mounts under :authenticated with full shell chrome",
         %{conn: conn} do
      {:ok, _view, html} = live_settled(conn, "/chat")

      # Default host keeps the `:shell` layout — desktop sidebar
      # render exactly as before this change (the chat. scope does not
      # shadow default-host routing).
      assert html =~ ~s(id="sidebar")
      assert html =~ ~s(id="sidebar")
      # And it is NOT wrapped in the shell-less external <main>.
      refute html =~ ~s(class="h-dvh bg-base-100 text-base-content")
    end
  end
end
