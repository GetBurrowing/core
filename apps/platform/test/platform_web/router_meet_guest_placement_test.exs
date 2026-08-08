defmodule PlatformWeb.RouterMeetGuestPlacementTest do
  @moduledoc """
  Pins the declaration-order placement of the `meet.` GUEST scope
  (`/:slug/:token`) relative to (a) the `meet.` MEMBER scope
  (`/meetings/:slug`) above it and (b) the match-any-host default scope
  below it.

  These are ROUTER TOPOLOGY assertions, driven through
  `Phoenix.Router.route_info/4`, and that instrument is chosen
  deliberately: a route can be DEFINED in the router and still be
  unreachable, because Phoenix emits one `__match_route__/3` clause per
  route in definition order and the first match wins. A test that merely
  asserted "the guest route exists" would have passed on the broken
  arrangement too, and proved nothing.

  ## Characterization of the UNMODIFIED router (measured, not assumed)

  Before this change the guest scope sat at the bottom of the router,
  below the default `scope "/"`. Running
  `Phoenix.Router.route_info(PlatformWeb.Router, "GET", path,
  "meet.example.com")` against that tree answered, verbatim:

      /tasks/sometoken      -> route "/tasks/:task_id"      %{"task_id" => "sometoken"}
      /chat/sometoken       -> route "/chat/:space_slug"    %{"space_slug" => "sometoken"}
      /files/sometoken      -> route "/files/:project_id"   %{"project_id" => "sometoken"}
      /skills/sometoken     -> route "/skills/:slug"        %{"slug" => "sometoken"}
      /meetings/some-slug   -> route "/meetings/:slug"      %{"slug" => "some-slug"}
      /control/sometoken    -> route "/control/:agent_slug" %{"agent_slug" => "sometoken"}
      /canvases/sometoken   -> route "/canvases/:id"        %{"id" => "sometoken"}
      /admin/recovery       -> route "/admin/recovery"
      /admin/users          -> route "/admin/users"
      /admin/prompts        -> route "/admin/prompts"
      /admin/federation     -> route "/admin/federation"
      /memory/proposals     -> route "/memory/proposals"
      /org_memory/sometoken -> route "/org_memory/*file_key"
      /nocollide/sometoken  -> route "/:slug/:token"        (the guest route)

  Every one of those is `Phoenix.LiveView.Plug`, i.e. a real match, not a
  fallthrough. So the full shadow set claimed by the ticket was accurate
  and complete as measured — nothing extra was shadowed, nothing on the
  list turned out to be already-unreachable. Only a path whose first
  segment collided with NOTHING (`/nocollide/...`) reached the guest
  route. Guest invite URLs are minted absolute, stored, and emailed, so
  those were live dead links.

  Note `/org_memory/*file_key` is a GLOB: it shadows a `org_memory`-slugged
  meeting at any token depth, not just two segments.
  """

  use ExUnit.Case, async: true

  @meet_host "meet.example.com"
  @app_host "example.com"

  defp info(path, host) do
    Phoenix.Router.route_info(PlatformWeb.Router, "GET", path, host)
  end

  defp live_view_and_session(path, host) do
    case info(path, host) do
      %{phoenix_live_view: {view, _action, _opts, %{name: session}}} -> {view, session}
      other -> flunk("expected a LiveView route for #{host}#{path}, got: #{inspect(other)}")
    end
  end

  describe "guest scope sits above the default scope" do
    test "a guest link whose slug collides with an app route reaches the guest surface" do
      # This is the case that was BROKEN: /tasks/:task_id shadowed it.
      assert {PlatformWeb.MeetingLive, :guest_meeting} =
               live_view_and_session("/tasks/sometoken", @meet_host)

      assert %{route: "/:slug/:token", path_params: %{"slug" => "tasks", "token" => "sometoken"}} =
               info("/tasks/sometoken", @meet_host)
    end

    test "every first segment in the measured shadow set now reaches the guest route" do
      # Each of these resolved to an app route before the hoist (see the
      # moduledoc characterization). Asserting the whole set, not one
      # sample, because a one-sample test cannot see a partial hoist.
      for {path, slug, token} <- [
            {"/chat/sometoken", "chat", "sometoken"},
            {"/files/sometoken", "files", "sometoken"},
            {"/skills/sometoken", "skills", "sometoken"},
            {"/control/sometoken", "control", "sometoken"},
            {"/canvases/sometoken", "canvases", "sometoken"},
            {"/admin/recovery", "admin", "recovery"},
            {"/admin/users", "admin", "users"},
            {"/admin/prompts", "admin", "prompts"},
            {"/admin/federation", "admin", "federation"},
            {"/memory/proposals", "memory", "proposals"},
            {"/org_memory/sometoken", "org_memory", "sometoken"}
          ] do
        assert %{
                 route: "/:slug/:token",
                 path_params: %{"slug" => ^slug, "token" => ^token}
               } = info(path, @meet_host),
               "expected #{path} on #{@meet_host} to reach the guest route, got: " <>
                 inspect(info(path, @meet_host))

        assert {PlatformWeb.MeetingLive, :guest_meeting} =
                 live_view_and_session(path, @meet_host)
      end
    end
  end

  describe "guest scope sits BELOW the meet. member scope" do
    test "/meetings/:slug still resolves to the member scope, not the guest route" do
      # THE REGRESSION ASSERTION. `/meetings/:slug` and `/:slug/:token`
      # are both two segments on the same host, so whichever is declared
      # first wins outright. If the guest scope were hoisted one block
      # higher this would resolve to the guest route with
      # `slug: "meetings"` and the entire member surface would vanish
      # silently.
      assert {PlatformWeb.MeetingLive, :meet_member} =
               live_view_and_session("/meetings/some-slug", @meet_host)

      assert %{route: "/meetings/:slug", path_params: %{"slug" => "some-slug"}} =
               info("/meetings/some-slug", @meet_host)
    end
  end

  describe "positive control on the app host" do
    test "/tasks/:task_id on the app host is untouched by the hoist" do
      # Without this, a change that made the guest scope match-any-host
      # would satisfy both of the assertions above while breaking the
      # entire application.
      assert {PlatformWeb.TasksLive, :authenticated} =
               live_view_and_session("/tasks/sometoken", @app_host)
    end

    test "the guest route is not reachable on the app host at all" do
      assert %{route: "/tasks/:task_id"} = info("/tasks/sometoken", @app_host)

      # A path that matches nothing in the app surface must 404 on the app
      # host rather than falling through to `/:slug/:token`.
      assert :error = info("/nocollide/sometoken", @app_host)
    end
  end
end
