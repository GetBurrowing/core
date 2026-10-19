defmodule PlatformWeb.RouterHostIsolationTest do
  @moduledoc """
  THE BEHAVIOUR CHANGE (task 019fcf22 stage 4): with
  `:host_surface_enforcement` at `:on`, a request for an app route arriving on
  a `chat.` or `meet.` prefixed host gets a 404 instead of the whole
  application.

  ## Why this file is shaped as pairs

  A test asserting "the chat-scoped route answers on the chat host" passes on
  unmodified main and proves nothing. The assertion that bites is the NEGATIVE
  one — and a file of nothing but denials is just as worthless, because a
  change that broke a host ENTIRELY would pass every one of them. So every
  denial has a POSITIVE CONTROL on the SAME HOST in the SAME run, and the app
  host is the global positive control: if it goes red, the fence is over-broad.

  ## Two instruments, because they can disagree in both directions

    * `Phoenix.Router.route_info/4` — where a route is DECLARED, and which
      pipelines are compiled onto it.
    * a real `conn` through `PlatformWeb.Endpoint` — what a user actually GETS.

  A route can be correctly placed and still 404 from a plug (that is exactly
  what this stage ships), and a route can 404 for reasons unrelated to
  placement. Neither claim substitutes for the other, so both are asserted.

  ## Every denial runs as an INTERNAL user

  Internal users are the population this change affects. External users are
  already fenced by `PlatformWeb.Plugs.ExternalUserScope`, so an
  external-user denial test passes on unmodified main and is vacuous here.

  ## Enforcement is set explicitly per describe block

  No test in this file depends on ambient config, in either direction. The
  `:off` block is what proves the flag is the mechanism: the SAME requests
  that 404 under `:on` return the app under `:off`. `async: false` because
  those blocks mutate application env with an `on_exit` restore; a future
  `async: true` sibling touching `:host_surface_enforcement` would race it.

  Wiring and the host-agnostic inventory are pinned separately in
  `router_app_surface_wiring_test.exs` — this file does not duplicate them.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Router

  @app_host "example.com"
  @chat_host "chat.example.com"
  @meet_host "meet.example.com"

  # Paths in the fenced default scope. `/meetings` and `/chat` are here on
  # purpose: each ALSO exists inside a host scope, so they are the paths where
  # a fence built on the wrong predicate would misfire.
  @app_paths ["/tasks", "/meetings", "/admin", "/files", "/control"]

  defp with_enforcement(value) do
    previous = Application.get_env(:platform, :host_surface_enforcement, :off)
    Application.put_env(:platform, :host_surface_enforcement, value)
    on_exit(fn -> Application.put_env(:platform, :host_surface_enforcement, previous) end)
    :ok
  end

  defp internal_user! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "host-isolation-#{n}@example.com",
        name: "HostIsolation #{n}",
        oidc_sub: "oidc-host-isolation-#{n}"
      })
      |> Repo.insert!()

    # Seeded tenant org — its slug atom is pre-registered, which TasksLive's
    # scope rail requires (`String.to_existing_atom` over active tenants).
    org = Tenancy.get_org_by_slug!("globex")

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()

    user
  end

  defp signed_in_conn(conn) do
    init_test_session(conn, current_user_id: internal_user!().id)
  end

  defp on_host(conn, host), do: %{conn | host: host}

  defp status(conn, host, path), do: conn |> on_host(host) |> get(path) |> Map.fetch!(:status)

  defp live_target(method, path, host) do
    case Phoenix.Router.route_info(Router, method, path, host) do
      %{phoenix_live_view: {view, _action, _opts, %{name: name}}} -> {view, name}
      other -> other
    end
  end

  # In the signed-in user's org (globex): that user is a sub-org-only member,
  # fenced to their orgs (ticket 01a14721), so an org-less channel would be
  # refused for an access reason and this file asserts host routing only.
  defp create_space! do
    slug = "host-iso-#{System.unique_integer([:positive])}"
    org_id = Tenancy.get_org_by_slug!("globex").id

    {:ok, space} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel",
        org_id: org_id
      })

    space
  end

  describe "the shipped default" do
    test "config/config.exs ships :host_surface_enforcement at :on" do
      # Every other test in this file forces the flag, deliberately, so that
      # none of them depends on ambient config. The consequence is that none
      # of them can see the SHIPPED value — which is the entire user-visible
      # deliverable of this stage. This test is the one that can, and it is
      # what a rollback (`:off` in config.exs) turns red.
      #
      # `config/test.exs` sets no value for this key, so the compiled test
      # config is config.exs's. If a future test.exs override appears, this
      # assertion starts reporting that override instead and should be
      # replaced with a read of the config file, not deleted.
      assert Application.fetch_env!(:platform, :host_surface_enforcement) == :on
    end
  end

  describe "enforcement :on — chat host" do
    setup %{conn: conn} do
      :ok = with_enforcement(:on)
      %{conn: signed_in_conn(conn), space: create_space!()}
    end

    test "DENY: every app path 404s for a signed-in internal user", %{conn: conn} do
      for path <- @app_paths do
        assert status(conn, @chat_host, path) == 404,
               "#{path} did not 404 on the chat host — the app is still navigable from there"
      end
    end

    test "DENY is the FENCE, not a missing route: the paths are declared on this host",
         %{conn: conn} do
      # Placement and status are different claims. Each of these paths
      # RESOLVES on the chat host (the default scope is match-any-host) and is
      # nonetheless refused, which is precisely the shape this stage ships. If
      # a later change made them stop resolving, the 404s above would still
      # pass while the mechanism had silently become something else.
      for path <- @app_paths do
        info = Phoenix.Router.route_info(Router, "GET", path, @chat_host)

        assert is_map(info), "#{path} no longer resolves at all on the chat host"

        assert :require_app_surface in info.pipe_through,
               "#{path} 404s on the chat host for some reason OTHER than the fence"

        assert status(conn, @chat_host, path) == 404
      end
    end

    test "ALLOW: /chat and /chat/:slug still reach ChatLive in :external_chat", %{
      conn: conn,
      space: space
    } do
      assert live_target("GET", "/chat", @chat_host) ==
               {PlatformWeb.ChatLive, :external_chat}

      assert live_target("GET", "/chat/#{space.slug}", @chat_host) ==
               {PlatformWeb.ChatLive, :external_chat}

      # And they are actually SERVED, not merely declared. `/chat` redirects
      # to the first space when one exists, so 302 is a pass there; the
      # space URL must render.
      assert status(conn, @chat_host, "/chat") in [200, 302]
      assert status(conn, @chat_host, "/chat/#{space.slug}") == 200
    end
  end

  describe "enforcement :on — meet host" do
    setup %{conn: conn} do
      :ok = with_enforcement(:on)
      %{conn: signed_in_conn(conn)}
    end

    test "DENY: app paths 404 on the meet host", %{conn: conn} do
      # `/chat` is in this list and NOT in the chat-host list: it is fenced
      # here and allowed there, which is the per-host asymmetry the fence is
      # supposed to produce.
      for path <- ["/tasks", "/chat", "/admin"] do
        assert status(conn, @meet_host, path) == 404,
               "#{path} did not 404 on the meet host"
      end
    end

    test "ALLOW: the member and guest meeting surfaces survive", %{conn: conn} do
      assert live_target("GET", "/meetings/some-slug", @meet_host) ==
               {PlatformWeb.MeetingLive, :meet_member}

      assert live_target("GET", "/some-slug/some-token", @meet_host) ==
               {PlatformWeb.MeetingLive, :guest_meeting}

      # Status, separately. These slugs name no real meeting, so the surface
      # answers with its own not-found handling rather than a 200 — the claim
      # asserted is the one this stage can break: the FENCE must not be what
      # answers. A fence that swallowed the meet host would make both of these
      # 404 with `:require_app_surface` in the pipeline, so the pipeline check
      # is what distinguishes the two causes.
      for path <- ["/meetings/some-slug", "/some-slug/some-token"] do
        info = Phoenix.Router.route_info(Router, "GET", path, @meet_host)

        refute :require_app_surface in info.pipe_through,
               "#{path} on the meet host was routed into the FENCED scope"

        refute status(conn, @meet_host, path) == 404,
               "#{path} on the meet host 404d — the meet surface was swallowed"
      end
    end
  end

  describe "enforcement :on — app host is the global positive control" do
    setup %{conn: conn} do
      :ok = with_enforcement(:on)
      %{conn: signed_in_conn(conn)}
    end

    test "a signed-in internal user still gets 200 on /tasks, /meetings, /chat", %{conn: conn} do
      for path <- ["/tasks", "/meetings", "/chat"] do
        assert status(conn, @app_host, path) == 200,
               "#{path} broke on the APP host — the fence is over-broad"
      end
    end

    test "/admin on the app host is refused by the ADMIN gate, not by the fence", %{conn: conn} do
      # This user is a member, not an admin, so `:ensure_admin` redirects.
      # The claim is only that the answer is not the fence's 404 — which it
      # would be if `router_surface/1` misclassified the app host.
      assert status(conn, @app_host, "/admin") != 404
    end

    test "PROOF the :on setup took effect (this block is otherwise all-allow)", %{conn: conn} do
      # Without this, every assertion in this describe block would pass with
      # enforcement stuck at `:off` and the block would measure nothing.
      assert status(conn, @chat_host, "/tasks") == 404
    end
  end

  describe "enforcement :off — the flag is the mechanism" do
    setup %{conn: conn} do
      :ok = with_enforcement(:off)
      %{conn: signed_in_conn(conn)}
    end

    test "the same chat-host requests that 404 under :on return the app under :off", %{conn: conn} do
      # The rollback contract, stated as a test: flipping one config line
      # restores the pre-stage-4 world. It is also what proves the `:on`
      # blocks above are measuring the flag and not some unrelated 404.
      assert status(conn, @chat_host, "/tasks") == 200
      assert status(conn, @meet_host, "/tasks") == 200
    end
  end
end
