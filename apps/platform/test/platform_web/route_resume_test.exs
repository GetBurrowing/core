defmodule PlatformWeb.RouteResumeTest.RouteStaleProbeLive do
  @moduledoc false
  # Minimal LiveView that exercises `handle_route_stale/2` via a hook event.
  # Deliberately does NOT alias or import PlatformWeb.RouteResume — the
  # `use PlatformWeb, :live_view` macro is expected to have wired it in
  # (task 019f3e9a stage 2). Defined BEFORE the test module so `mix test`'s
  # compile order makes the module available when the test cases mount it.
  use PlatformWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="probe">route-stale probe</div>
    """
  end

  @impl true
  def handle_event("stale", %{"module" => module}, socket) do
    {:noreply, handle_route_stale(socket, module)}
  end
end

defmodule PlatformWeb.RouteResumeTest do
  @moduledoc """
  Tests for `PlatformWeb.RouteResume.handle_route_stale/2` — the helper
  imported into every `use PlatformWeb, :live_view` (task 019f3e9a stage 2).

  A minimal isolated LiveView
  (`PlatformWeb.RouteResumeTest.RouteStaleProbeLive`, defined above) is
  used to exercise the helper through Phoenix's LiveView lifecycle, so
  `assert_push_event/3` sees the real socket. We assert:

    * `handle_route_stale/2` emits a `route_resume_stale` event with the
      given `module` string in the detail payload
    * Multiple calls in a row queue multiple events (the LV socket
      accumulates push_events across the same reduce)
    * The helper is available via `use PlatformWeb, :live_view` alone,
      i.e. no explicit `alias`/`import` at the call site.
  """

  use PlatformWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias PlatformWeb.RouteResumeTest.RouteStaleProbeLive

  describe "handle_route_stale/2" do
    test "pushes a route_resume_stale event with the given module id" do
      {:ok, view, _html} = live_isolated(build_conn(), RouteStaleProbeLive)

      render_hook(view, "stale", %{"module" => "chat"})

      assert_push_event(view, "route_resume_stale", %{module: "chat"})
    end

    test "pushes distinct events for successive modules" do
      {:ok, view, _html} = live_isolated(build_conn(), RouteStaleProbeLive)

      render_hook(view, "stale", %{"module" => "tasks"})
      assert_push_event(view, "route_resume_stale", %{module: "tasks"})

      render_hook(view, "stale", %{"module" => "meetings"})
      assert_push_event(view, "route_resume_stale", %{module: "meetings"})
    end

    test "the helper is available without an explicit import at the call site" do
      # RouteStaleProbeLive calls `handle_route_stale(socket, module)` on
      # a bare `use PlatformWeb, :live_view` — if the macro's `import
      # PlatformWeb.RouteResume` were missing, compilation would have
      # failed and this test module wouldn't have loaded. Reaching this
      # assertion at all is the affirmative evidence.
      assert function_exported?(PlatformWeb.RouteResume, :handle_route_stale, 2)
    end
  end
end
