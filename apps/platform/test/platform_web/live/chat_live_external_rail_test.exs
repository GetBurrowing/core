defmodule PlatformWeb.ChatLiveExternalRailTest do
  @moduledoc """
  rbac-external-users M5 stage 2 — the chrome-less external space rail.

  On the `chat.` host M4's `:external_chat` live_session merges
  `chat_mode: "external"` into the connect session; ChatLive then renders the
  external branch: a single flat allowlisted-space list (scoped by M7's
  `ExternalScope`) with the Fabrikam branding + identity chip + logout, and NONE of
  the internal discovery chrome (sub-org section headers, admin entry,
  new-channel, scope-pills, archived / pinned-task sections).

  `async: false` — mirrors `chat_live_external_host_mount_test.exs` /
  `meeting_live_guest_mount_test.exs`; keeps the host-swapped conn cases off the
  shared async pool.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  defp with_chat_host(conn, host \\ "chat.localhost") do
    %{conn | host: host}
  end

  defp create_user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "rail-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-rail-#{n}"
    })
    |> Repo.insert!()
  end

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_rail_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  defp external_user!(org) do
    user = create_user!("Xena External")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
    Tenancy.allow_dm(user, org)
    user
  end

  defp channel!(name, opts \\ []) do
    n = System.unique_integer([:positive])

    attrs =
      %{name: name, slug: "rail-ch-#{n}", kind: "channel"}
      |> Map.merge(Map.new(opts))

    {:ok, ch} = Chat.create_space(attrs)
    ch
  end

  defp join!(channel, user) do
    {:ok, _} =
      Chat.add_participant(channel.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    channel
  end

  defp authed(conn, user), do: init_test_session(conn, current_user_id: user.id)

  describe "external path (chat. host)" do
    setup %{conn: conn} do
      org_a = tenant_org!()
      ext = external_user!(org_a)

      allowed = channel!("Allowed Channel", org_id: org_a.id) |> join!(ext)
      off_limits = channel!("Secret Ops Room")

      %{conn: conn, ext: ext, allowed: allowed, off_limits: off_limits}
    end

    test "rail lists ONLY the allowlisted channel and none of the discovery chrome",
         %{conn: conn, ext: ext, allowed: allowed, off_limits: off_limits} do
      {:ok, _view, html} =
        conn
        |> with_chat_host()
        |> authed(ext)
        |> live("/chat/#{allowed.slug}")

      # The external rail rendered, listing the allowlisted channel only.
      assert html =~ ~s(data-role="external-rail")
      assert html =~ allowed.name
      refute html =~ off_limits.name

      # Branding + identity chip + logout are KEPT (M4's :external layout is
      # chrome-less, so ChatLive renders them).
      assert html =~ "Fabrikam"
      assert html =~ ~s(data-role="external-identity")
      assert html =~ ext.name
      assert html =~ ~p"/auth/logout"

      # NONE of the internal discovery chrome leaks.
      refute html =~ ~s(id="chat-sidebar")
      refute html =~ "channel-section-header"
      refute html =~ "Edit my layout"
      refute html =~ "Edit company default"
      refute html =~ "New channel"
      refute html =~ "chat-header-scope-pill"
    end

    test "empty allowlist renders the calm empty state, no crash and no leak", %{conn: conn} do
      org = tenant_org!()
      zero = external_user!(org)

      {:ok, _view, html} =
        conn
        |> with_chat_host()
        |> authed(zero)
        |> live("/chat")

      assert html =~ ~s(data-role="external-rail")
      assert html =~ ~s(data-role="external-empty")
      assert html =~ "Nothing here yet"
      # Never the internal brand-new-user "browse channels" discovery hint.
      refute html =~ "id=\"chat-sidebar\""
      refute html =~ "channel-section-header"
    end
  end

  describe "internal control (default host)" do
    test "the internal rail is fully unchanged — no external branch leaks", %{conn: conn} do
      internal = create_user!("Ivan Internal")
      channel = channel!("General Chat")
      join!(channel, internal)

      {:ok, _view, html} =
        conn
        |> authed(internal)
        |> live("/chat/#{channel.slug}")

      # Full internal rail: the resizable sidebar aside + new-channel affordance.
      assert html =~ ~s(id="chat-sidebar")
      assert html =~ "New channel"
      # The external branch is fully dormant on the default host.
      refute html =~ ~s(data-role="external-rail")
      refute html =~ ~s(data-role="external-empty")
    end
  end

  # ── task 019fb955-f8b1 stage 5: the composer's "Meet" button ────────────────
  #
  # COSMETICS OVER A SERVER REFUSAL, not a gate. `MeetingHooks.do_join/1` has
  # refused an uninvited external user since stage 4, and the LiveKit room is
  # keyed off the SPACE — so this button was offering an external user seated
  # in a meeting's bound chat space a join the server already declines. The
  # button is removed because a control that does nothing when clicked is quiet
  # degradation, not because the template is what stops them.
  #
  # BOTH SIDES, in one block. The absence on its own passes on a build where
  # the button never renders for anyone — which is exactly what an unset
  # LiveKit config produces, and why `meetings_enabled` is forced true here.
  describe "the Meet button is hidden from external users (task 019fb955-f8b1)" do
    setup do
      original = Application.get_env(:platform, :livekit, [])

      Application.put_env(:platform, :livekit,
        api_key: "test-livekit-key",
        api_secret: "test-livekit-secret-0123456789abcdef",
        url: "wss://livekit.test"
      )

      on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

      org = tenant_org!()
      ext = external_user!(org)
      internal = create_user!("Ivan Internal")

      shared = channel!("Shared Room", org_id: org.id) |> join!(ext) |> join!(internal)

      %{ext: ext, internal: internal, shared: shared}
    end

    test "absent for an external user and present for an internal user in the SAME space",
         %{conn: conn, ext: ext, internal: internal, shared: shared} do
      assert Platform.Meetings.enabled?(),
             "the internal side of this test is vacuous unless meetings are enabled"

      {:ok, ext_view, _} =
        conn
        |> with_chat_host()
        |> authed(ext)
        |> live("/chat/#{shared.slug}")

      refute has_element?(ext_view, "button[phx-click=meeting_join]")

      {:ok, int_view, _} =
        conn
        |> authed(internal)
        |> live("/chat/#{shared.slug}")

      assert has_element?(int_view, "button[phx-click=meeting_join]")
    end

    test "also absent for an external user on the SUITE host, where scope is identity-derived",
         %{conn: conn, ext: ext, shared: shared} do
      # `@external?` comes from the user's identity, not from the host or the
      # `chat_mode` session key (task 019f9257 stage 1) — so the button must
      # be gone on the default host too. Without this case the hiding could be
      # a side effect of the `chat.` host's external branch.
      {:ok, view, _} =
        conn
        |> authed(ext)
        |> live("/chat/#{shared.slug}")

      refute has_element?(view, "button[phx-click=meeting_join]")
    end
  end

  # ── task 019f9257: the suite-host cross-tenant leak regression ──────────────
  #
  # The reported defect: an external user served on the SUITE (default) host
  # under the internal `:authenticated` live_session — which carries NO
  # `chat_mode` session key — was scoped `nil` and saw EVERY channel workspace-
  # wide (the reporter, granted only Orion, saw the Fabrikam-internal General).
  # Stage 1 derives the scope from IDENTITY, so the leak cannot happen on ANY
  # host / live_session. These cases pin that: NO `chat_mode`, NO `chat.` host.
  describe "suite-host identity-derived scope (no chat_mode leak — task 019f9257)" do
    setup %{conn: conn} do
      org = tenant_org!()
      ext = external_user!(org)

      # The external user is a participant of exactly ONE channel (their grant).
      granted = channel!("Orion", org_id: org.id) |> join!(ext)
      # A Fabrikam-internal channel the external user has NO participant row for.
      off_limits = channel!("General")

      %{conn: conn, ext: ext, granted: granted, off_limits: off_limits}
    end

    test "external user on the SUITE host WITHOUT chat_mode sees ONLY their granted channel",
         %{conn: conn, ext: ext, granted: granted, off_limits: off_limits} do
      # Default host (no with_chat_host), no chat_mode session — exactly the
      # internal `:authenticated` path the leak lived on.
      {:ok, _view, html} =
        conn
        |> authed(ext)
        |> live("/chat/#{granted.slug}")

      # Scope is derived from identity → the rail lists ONLY the granted space.
      assert html =~ granted.name
      refute html =~ off_limits.name

      # And because the identity is external, the chrome-less rail renders even
      # here — the discovery chrome that would enumerate all channels is off.
      assert html =~ ~s(data-role="external-rail")
      refute html =~ "New channel"
    end

    test "the /chat index on the suite host is likewise scoped, no all-channels leak",
         %{conn: conn, ext: ext, granted: granted, off_limits: off_limits} do
      {:ok, _view, html} =
        conn
        |> authed(ext)
        |> live_settled("/chat")

      assert html =~ granted.name
      refute html =~ off_limits.name
      assert html =~ ~s(data-role="external-rail")
    end

    test "an INTERNAL user on the suite host is completely unaffected (sees General)",
         %{conn: conn, off_limits: off_limits} do
      internal = create_user!("Ingrid Internal")
      join!(off_limits, internal)

      {:ok, _view, html} =
        conn
        |> authed(internal)
        |> live("/chat/#{off_limits.slug}")

      # Identity-derived scope is a no-op for internal users: full internal rail,
      # General visible, external branch dormant.
      assert html =~ off_limits.name
      assert html =~ ~s(id="chat-sidebar")
      refute html =~ ~s(data-role="external-rail")
    end
  end

  # ── task 019f9257-a83e: mobile-responsive external surface ──────────────────
  #
  # The external rail was `flex` with no responsive gate, so at 375px it ate
  # ~288px beside the message pane and the conversation collapsed to a sliver;
  # every internal mobile affordance was `!@external?`-gated, so external users
  # had NO mobile channel switcher. These cases pin the fix: the rail is now
  # `hidden lg:flex` (desktop-only), the `lg:hidden` pills strip is fed the
  # external user's granted `@channels` (not the empty `@sidebar_sections`), and
  # a FLAT `#external-mobile-switcher` overlay mirrors the internal drawer shell
  # WITHOUT its org-tree / new-channel / scope-pill discovery chrome.
  describe "mobile-responsive external surface (task 019f9257-a83e)" do
    setup %{conn: conn} do
      org = tenant_org!()
      ext = external_user!(org)
      chan_a = channel!("Design Review", org_id: org.id) |> join!(ext)
      chan_b = channel!("General Room", org_id: org.id) |> join!(ext)
      off_limits = channel!("Secret Ops")

      %{conn: conn, ext: ext, chan_a: chan_a, chan_b: chan_b, off_limits: off_limits}
    end

    test "external rail carries the hidden lg:flex gate so it collapses on mobile",
         %{conn: conn, ext: ext, chan_a: chan_a} do
      {:ok, view, _html} =
        conn |> with_chat_host() |> authed(ext) |> live("/chat/#{chan_a.slug}")

      rail = view |> element(~s([data-role="external-rail"])) |> render()
      # Mirrors the internal #chat-sidebar gate: desktop-only, hidden < lg.
      assert rail =~ "hidden lg:flex"
    end

    test "mobile pills strip enumerates ONLY the external user's granted channels",
         %{conn: conn, ext: ext, chan_a: chan_a, chan_b: chan_b, off_limits: off_limits} do
      {:ok, view, _html} =
        conn |> with_chat_host() |> authed(ext) |> live("/chat/#{chan_a.slug}")

      pills = view |> element(~s(nav[aria-label="Channel switcher"])) |> render()
      # Fed by @channels (not the empty external @sidebar_sections) — before the
      # fix external channels never appeared in the pills at all.
      assert pills =~ chan_a.name
      assert pills =~ chan_b.name
      refute pills =~ off_limits.name
    end

    test "search button opens the FLAT external switcher — brand/identity kept, no discovery chrome",
         %{conn: conn, ext: ext, chan_a: chan_a, chan_b: chan_b, off_limits: off_limits} do
      {:ok, view, html} =
        conn |> with_chat_host() |> authed(ext) |> live("/chat/#{chan_a.slug}")

      # Closed by default while a space is active.
      refute html =~ ~s(data-role="external-mobile-switcher")

      view
      |> element(~s(button[aria-label="Search channels and direct messages"]))
      |> render_click()

      overlay = view |> element(~s([data-role="external-mobile-switcher"])) |> render()

      # Flat allowlisted list — both granted channels, nothing off-limits.
      assert overlay =~ chan_a.name
      assert overlay =~ chan_b.name
      refute overlay =~ off_limits.name

      # Brand + identity + logout move into the overlay header (chrome-less layout).
      assert overlay =~ "Fabrikam"
      assert overlay =~ ext.name
      assert overlay =~ ~p"/auth/logout"
      assert overlay =~ "New conversation"

      # NONE of the internal drawer's discovery chrome.
      refute overlay =~ ~s(id="mobile-channel-browser")
      refute overlay =~ "channel-section-header"
      refute overlay =~ "New channel"
    end

    test "no-space landing shows the switcher by default — the list IS the landing",
         %{conn: conn} do
      org = tenant_org!()
      zero = external_user!(org)

      {:ok, _view, html} =
        conn |> with_chat_host() |> authed(zero) |> live("/chat")

      # With no active space, the mobile switcher renders as the landing surface.
      assert html =~ ~s(data-role="external-mobile-switcher")
      assert html =~ "Nothing here yet"
    end

    test "the external mobile switcher never renders for an internal user", %{conn: conn} do
      internal = create_user!("Iris Internal")
      channel = channel!("Internal General") |> join!(internal)

      {:ok, view, html} =
        conn |> authed(internal) |> live("/chat/#{channel.slug}")

      refute html =~ ~s(data-role="external-mobile-switcher")

      # The internal search button opens the INTERNAL browser, never the external one.
      view
      |> element(~s(button[aria-label="Search channels and direct messages"]))
      |> render_click()

      assert render(view) =~ ~s(id="mobile-channel-browser")
      refute render(view) =~ ~s(data-role="external-mobile-switcher")
    end
  end

  # `live/2` follows the `/chat` → first-space redirect so the index cases can
  # assert against the landed rail (same live_session, unchanged layout).
  defp live_settled(conn, path) do
    case live(conn, path) do
      {:error, {kind, %{to: to}}} when kind in [:live_redirect, :redirect] -> live(conn, to)
      ok -> ok
    end
  end
end
