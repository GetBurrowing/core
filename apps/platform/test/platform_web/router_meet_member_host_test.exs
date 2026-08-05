defmodule PlatformWeb.RouterMeetMemberHostTest do
  @moduledoc """
  Routing contract for the `:meet_member` scope (task 019fb955-f8b1 stage 5).

  Pure router assertion — no implementation code, no DB. Everything resolves
  through `Phoenix.Router.route_info/4`, mirroring `resolve/3` in
  `router_external_chat_host_test.exs`.

  ## What was true BEFORE this scope existed

  Characterized on the unmodified router before a line was changed:
  `/meetings/some-slug` resolved to `MeetingLive` in the `:authenticated`
  live_session on EVERY host tried — `localhost`, `meet.localhost` and
  `meet.example.com` alike. The default `scope "/"` declares
  `/meetings/:slug` with a match-any-host pattern, Phoenix emits one
  `__match_route__/3` clause per route in DEFINITION ORDER, and the first
  match wins. A `meet.`-hosted copy appended next to the guest scope at the
  bottom of the router would therefore have been unreachable dead code.
  That is why the new scope sits above the default scope, and this module
  is what stops a later reordering from silently reverting it.

  ## The shared-host case, which is the one that matters

  The guest route (`/:slug/:token`) and the member route
  (`/meetings/:slug`) are BOTH two segments, and in the deployment this
  stage was written for the guest host and the meet host are the SAME
  hostname. So the two patterns genuinely compete on one host, and
  first-declared decides which surface exists.

  A test that gives the guest route one fixture host and the member route
  another CANNOT SEE THAT. Both assertions pass while the member surface is
  entirely swallowed. So the `shared host` block below asserts both
  resolutions against ONE host string. Its failure mode if the scopes were
  ever reordered is the honest one: every member URL resolves to
  `:guest_meeting` with `slug: "meetings"`.

  `async: false` — mirrors the host-swapped cases in
  `router_external_chat_host_test.exs`.
  """
  use PlatformWeb.ConnCase, async: false

  @router PlatformWeb.Router

  # The one host string that stands in for the shared-host production
  # topology: the guest surface and the member surface on the SAME name.
  @shared_host "meet.example.com"

  defp resolve(method, path, host) do
    case Phoenix.Router.route_info(@router, method, path, host) do
      :error -> :error
      %{phoenix_live_view: {view, _action, _opts, %{name: name}}} -> {:live, view, name}
      %{plug: plug} -> {:controller, plug}
      other -> other
    end
  end

  describe "the member route on the meet host" do
    test "/meetings/:slug resolves to the :meet_member live_session" do
      assert {:live, PlatformWeb.MeetingLive, :meet_member} =
               resolve("GET", "/meetings/some-slug", @shared_host)
    end

    test "the `meet.` PREFIX is what routes here, not the configured meet host" do
      # (c) in the router's scope comment: this scope matches Phoenix's
      # `"meet."` prefix and decides which live_session renders, while
      # `ExternalSurface` matches the CONFIGURED `:meet_host` exactly and
      # decides whether an external user is ADMITTED. No `:meet_host` is
      # configured in this test and the route still resolves — which is the
      # whole point: routing here is not admission. A `meet.`-prefixed host
      # that is not the configured meet host routes here and is then denied
      # by `ExternalUserScope`, fail-closed.
      refute Application.get_env(:platform, :meet_host)

      assert {:live, PlatformWeb.MeetingLive, :meet_member} =
               resolve("GET", "/meetings/some-slug", "meet.some-other.example.com")
    end

    test "a host that merely CONTAINS `meet.` does not route here" do
      # Phoenix's host option is a prefix match, so this is the boundary
      # the prefix rule actually draws. Without it, `:meet_member` looks
      # like it matches any host with "meet." anywhere in it.
      assert {:live, PlatformWeb.MeetingLive, :authenticated} =
               resolve("GET", "/meetings/some-slug", "notmeet.example.com")
    end
  end

  describe "shared host — the guest route and the member route on ONE hostname" do
    # Production points the guest host and the meet host at the same name.
    # These two assertions are deliberately against the SAME host string;
    # split across two fixture hosts they could not detect the collision.
    test "the member route wins /meetings/:slug on the shared host" do
      assert {:live, PlatformWeb.MeetingLive, :meet_member} =
               resolve("GET", "/meetings/abc", @shared_host)
    end

    test "the guest route still wins /:slug/:token on that same host" do
      assert {:live, PlatformWeb.MeetingLive, :guest_meeting} =
               resolve("GET", "/some-slug/some-token", @shared_host)
    end

    test "both hold simultaneously, which is the property a two-host test cannot see" do
      member = resolve("GET", "/meetings/abc", @shared_host)
      guest = resolve("GET", "/some-slug/some-token", @shared_host)

      assert {:live, PlatformWeb.MeetingLive, :meet_member} = member
      assert {:live, PlatformWeb.MeetingLive, :guest_meeting} = guest

      # And they are genuinely different live_sessions, not one name
      # matched twice — the assertion that fails first if the scopes are
      # ever reordered.
      assert {:live, _, member_session} = member
      assert {:live, _, guest_session} = guest
      refute member_session == guest_session
    end

    test "a meeting whose slug is literally `meetings` loses its guest link — documented, not fixed" do
      # `/meetings/<token>` is what that meeting's guest links look like,
      # and it resolves to the MEMBER route, not the guest route. This is
      # NOT a regression from this stage: before it, the same path resolved
      # to the default scope's `/meetings/:slug` in `:authenticated`, so the
      # guest route never saw it either. Pinned so the next person reads the
      # edge case here instead of rediscovering it in production. The fix,
      # if it is ever needed, is a prefix on the guest route — never a
      # reordering, which would delete the member surface entirely.
      assert {:live, PlatformWeb.MeetingLive, :meet_member} =
               resolve("GET", "/meetings/some-guest-token", @shared_host)
    end
  end

  describe "non-shadowing — the default host is untouched" do
    test "/meetings/:slug on the default host still resolves to :authenticated" do
      assert {:live, PlatformWeb.MeetingLive, :authenticated} =
               resolve("GET", "/meetings/some-slug", "localhost")
    end

    test "/tasks, /admin, /chat, /org_memory on the default host are unchanged" do
      assert {:live, PlatformWeb.TasksLive, :authenticated} =
               resolve("GET", "/tasks", "localhost")

      assert {:live, PlatformWeb.AdminLive, :admin} = resolve("GET", "/admin", "localhost")
      assert {:live, PlatformWeb.ChatLive, :authenticated} = resolve("GET", "/chat", "localhost")

      assert {:live, PlatformWeb.OrgMemoryLive, :authenticated} =
               resolve("GET", "/org_memory", "localhost")

      assert {:controller, PlatformWeb.PageController} = resolve("GET", "/", "localhost")
    end

    test "the meetings INDEX is not captured by the new scope on either host" do
      # The new scope declares exactly one route. `/meetings` still falls
      # through to the default scope even on the meet host — where
      # `ExternalUserScope` then denies it for an external user. Route
      # omission is not surface limitation; the plug is.
      assert {:live, PlatformWeb.MeetingLive, :authenticated} =
               resolve("GET", "/meetings", "localhost")

      assert {:live, PlatformWeb.MeetingLive, :authenticated} =
               resolve("GET", "/meetings", @shared_host)
    end

    test "the chat host scope is unaffected by the new scope's placement" do
      assert {:live, PlatformWeb.ChatLive, :external_chat} =
               resolve("GET", "/chat", "chat.example.com")

      assert {:live, PlatformWeb.ChatLive, :external_chat} =
               resolve("GET", "/chat/some-space", "chat.example.com")
    end
  end
end
