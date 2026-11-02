defmodule PlatformWeb.Plugs.FirstRunGateTest do
  @moduledoc """
  `PlatformWeb.Plugs.FirstRunGate` (task 01a19943-c0b4 stage 1): a pending
  member's bare `GET /chat`, the installed PWA's `start_url`, goes to
  `/start`; nothing else does.

  `async: false` because tests swap `conn.host`, mirroring
  `chat_live_external_host_mount_test.exs`, and one writes the global
  `:host_surface_enforcement` env.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  defp member!(prefs) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "first-run-gate-#{n}@example.com",
        name: "First Run Gate #{n}",
        oidc_sub: "oidc-first-run-gate-#{n}",
        preferences: prefs
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  defp external_user! do
    org = Platform.Tenancy.get_org_by_slug!("globex")
    ext = Platform.ExternalUserFixtures.external_user!(org)
    refute Map.has_key?(Platform.Accounts.get_user_preferences(ext.id), "first_run_goal")
    ext
  end

  # Same override pattern as `router_host_isolation_test.exs`. Global env,
  # which is why this module is `async: false`.
  defp with_enforcement(value) do
    previous = Application.get_env(:platform, :host_surface_enforcement, :off)
    Application.put_env(:platform, :host_surface_enforcement, value)
    on_exit(fn -> Application.put_env(:platform, :host_surface_enforcement, previous) end)
    :ok
  end

  defp authed(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp channel_with!(user) do
    slug = "first-run-gate-#{System.unique_integer([:positive])}"
    {:ok, space} = Chat.create_space(%{name: slug, slug: slug, kind: "channel"})

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    space
  end

  # Chat's dead render either answers 200 or, when the member has a space,
  # redirects into a deep link `/chat/<slug>`. Either is "chat rendered";
  # what must never happen is a hop to /start.
  defp assert_chat_rendered(conn) do
    case conn.status do
      200 ->
        assert html_response(conn, 200) =~ "chat"

      302 ->
        to = redirected_to(conn)
        assert String.starts_with?(to, "/chat/"), "expected chat, redirected to #{to}"
    end
  end

  test "pending member GET /chat redirects to /start", %{conn: conn} do
    user = member!(%{})

    conn = conn |> authed(user) |> get("/chat")

    assert redirected_to(conn) == "/start"
    assert conn.halted
    refute Phoenix.Flash.get(conn.assigns.flash, :info)
    refute Phoenix.Flash.get(conn.assigns.flash, :error)

    # The trailing-slash and query-string forms are the same bare /chat.
    assert conn |> recycle() |> authed(user) |> get("/chat/") |> redirected_to() == "/start"
    assert conn |> recycle() |> authed(user) |> get("/chat?x=1") |> redirected_to() == "/start"
  end

  test "existing member GET /chat renders chat", %{conn: conn} do
    user = member!(%{"first_run_goal" => "existing"})

    conn |> authed(user) |> get("/chat") |> assert_chat_rendered()
    assert {:ok, _view, _html} = live(authed(build_conn(), user), "/chat")
  end

  test "skipped member GET /chat renders chat", %{conn: conn} do
    user = member!(%{"first_run_goal" => "skipped", "theme" => %{"preset" => "default"}})

    conn |> authed(user) |> get("/chat") |> assert_chat_rendered()
  end

  test "submitted member GET /chat renders chat", %{conn: conn} do
    user = member!(%{"first_run_goal" => "submitted"})

    conn |> authed(user) |> get("/chat") |> assert_chat_rendered()
  end

  test "external user GET /chat is not sent to /start", %{conn: conn} do
    ext = external_user!()

    conn = conn |> authed(ext) |> get("/chat")

    if conn.status in 300..399, do: refute(redirected_to(conn) == "/start")
  end

  test "pending member deep link /chat/<slug> renders", %{conn: conn} do
    user = member!(%{})
    space = channel_with!(user)

    conn = conn |> authed(user) |> get("/chat/#{space.slug}")

    assert html_response(conn, 200)
    assert {:ok, _view, _html} = live(authed(build_conn(), user), "/chat/#{space.slug}")
  end

  test "chat. host GET /chat is not sent to /start", %{conn: conn} do
    # The chat host's `/chat` resolves in the `chat.` host scope, whose
    # pipeline has no `:first_run_gate`. Same user setup as
    # `chat_live_external_host_mount_test.exs`, which is pending (no
    # first_run_goal key), and an external user too.
    pending = member!(%{})
    ext = external_user!()

    for user <- [pending, ext] do
      conn =
        %{recycle(conn) | host: "chat.example.com"}
        |> authed(user)
        |> get("/chat")

      if conn.status in 300..399, do: refute(redirected_to(conn) == "/start")
    end
  end

  test "meet. host GET /chat is not sent to /start while the host fence is off", %{conn: conn} do
    # `/chat` has no `meet.` route, so on a `meet.` host it falls through to
    # the default scope. With `:host_surface_enforcement` `:off`, HostSurface
    # lets it pass and only the gate's own `router_surface/1 == :app` check
    # keeps a pending member off /start. (The `chat.` host test above cannot
    # pin that check: the `chat.` scope never pipes through the gate.)
    with_enforcement(:off)
    pending = member!(%{})

    conn =
      %{conn | host: "meet.example.com"}
      |> authed(pending)
      |> get("/chat")

    if conn.status in 300..399, do: refute(redirected_to(conn) == "/start")
  end

  test "no loop: pending member /start renders, and non-pending /start goes to /chat",
       %{conn: conn} do
    pending = member!(%{})
    assert {:ok, _view, _html} = live(authed(conn, pending), "/start")

    done = member!(%{"first_run_goal" => "submitted"})

    assert {:error, {:live_redirect, %{to: "/chat"}}} =
             live(authed(build_conn(), done), "/start")

    # ... and that /chat lets them through rather than bouncing back.
    build_conn() |> authed(done) |> get("/chat") |> assert_chat_rendered()
  end
end
