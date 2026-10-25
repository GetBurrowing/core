defmodule PlatformWeb.ChatLiveExternalRailTest do
  @moduledoc """
  rbac-external-users M5 stage 2 — the chrome-less external space rail.

  On the `chat.` host M4's `:external_chat` live_session merges
  `chat_mode: "external"` into the connect session; ChatLive then renders the
  external branch: a single flat allowlisted-space list (scoped by M7's
  `ExternalScope`) with the Acme branding + identity chip + logout, and NONE of
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
  alias Platform.Chat.ExternalScope
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.ExternalGrants
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.ChatLive

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
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
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

    # Burrow redesign 22 stage 2 deleted the external rail; the external
    # user's desktop list is now the Chat list (`#chat-list`) at lg.
    test "list lists ONLY the allowlisted channel and none of the discovery chrome",
         %{conn: conn, ext: ext, allowed: allowed, off_limits: off_limits} do
      {:ok, view, html} =
        conn
        |> with_chat_host()
        |> authed(ext)
        |> live("/chat/#{allowed.slug}")

      # The external Chat list rendered, listing the allowlisted channel only.
      assert has_element?(
               view,
               ~s(#chat-list a[data-role="chat-list-row"][data-space-id="#{allowed.id}"])
             )

      refute has_element?(view, ~s(#chat-list a[data-space-id="#{off_limits.id}"]))
      assert html =~ allowed.name
      refute html =~ off_limits.name

      # Identity chip + logout are KEPT at the foot of the list (M4's
      # :external layout is chrome-less, so ChatLive renders them). The
      # desktop brand chip went with the external rail (Burrow redesign 22
      # stage 2); no org name may stand in for it.
      refute html =~
               ~r/alt="#{Platform.Regression.InstallIdentityScanner.published_org_token()}"/i

      assert has_element?(view, ~s(#chat-list [data-role="external-identity"]))
      assert html =~ ext.name
      assert has_element?(view, ~s(#chat-list [data-role="external-logout"][href="/auth/logout"]))

      # NONE of the internal discovery chrome leaks: no Agents row, no
      # Options, and the New popover offers a conversation but no channel.
      refute html =~ "channel-section-header"
      refute html =~ "Edit my layout"
      refute html =~ "Edit company default"
      refute html =~ "chat-header-scope-pill"
      refute has_element?(view, ~s(#chat-list a[data-row-kind="agents"]))
      refute has_element?(view, "#list-more")
      assert has_element?(view, "#list-new")

      view |> element("#list-new") |> render_click()
      assert has_element?(view, ~s([data-role="chat-list-pop-new-conversation"]))
      refute has_element?(view, ~s([data-role="chat-list-pop-new-channel"]))
      refute render(view) =~ ~s(phx-click="new_channel_open")
    end

    test "empty allowlist renders the calm empty state, no crash and no leak", %{conn: conn} do
      org = tenant_org!()
      zero = external_user!(org)

      {:ok, view, html} =
        conn
        |> with_chat_host()
        |> authed(zero)
        |> live("/chat")

      # The desktop list shows its empty state; the phone switcher its own.
      assert has_element?(view, ~s(#chat-list [data-role="chat-list-empty"]))
      assert html =~ "Nothing here yet"
      refute has_element?(view, ~s(#chat-list a[data-role="chat-list-row"]))
      # Never the internal brand-new-user "browse channels" discovery hint.
      refute has_element?(view, ~s([data-role="chat-list-empty-new-channel"]))
      refute html =~ "channel-section-header"
    end
  end

  describe "internal control (default host)" do
    test "the internal rail is fully unchanged — no external branch leaks", %{conn: conn} do
      internal = create_user!("Ivan Internal")
      channel = channel!("General Chat")
      join!(channel, internal)

      {:ok, view, html} =
        conn
        |> authed(internal)
        |> live("/chat/#{channel.slug}")

      # Full internal list: the channel row, Options, and New channel in the
      # New popover.
      assert has_element?(view, ~s(#chat-list a[data-space-id="#{channel.id}"]))
      assert has_element?(view, "#list-more")
      view |> element("#list-new") |> render_click()
      assert has_element?(view, ~s([data-role="chat-list-pop-new-channel"]))
      # The external branch is fully dormant on the default host.
      refute html =~ ~s(data-role="external-identity")
      refute html =~ ~s(data-role="external-logout")
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
  # wide (the reporter, granted only Atlas, saw the Acme-internal General).
  # Stage 1 derives the scope from IDENTITY, so the leak cannot happen on ANY
  # host / live_session. These cases pin that: NO `chat_mode`, NO `chat.` host.
  describe "suite-host identity-derived scope (no chat_mode leak — task 019f9257)" do
    setup %{conn: conn} do
      org = tenant_org!()
      ext = external_user!(org)

      # The external user is a participant of exactly ONE channel (their grant).
      granted = channel!("Atlas", org_id: org.id) |> join!(ext)
      # An Acme-internal channel the external user has NO participant row for.
      off_limits = channel!("General")

      %{conn: conn, ext: ext, granted: granted, off_limits: off_limits}
    end

    test "external user on the SUITE host WITHOUT chat_mode sees ONLY their granted channel",
         %{conn: conn, ext: ext, granted: granted, off_limits: off_limits} do
      # Default host (no with_chat_host), no chat_mode session — exactly the
      # internal `:authenticated` path the leak lived on.
      {:ok, view, html} =
        conn
        |> authed(ext)
        |> live("/chat/#{granted.slug}")

      # Scope is derived from identity → the list holds ONLY the granted space.
      assert has_element?(view, ~s(#chat-list a[data-space-id="#{granted.id}"]))
      refute has_element?(view, ~s(#chat-list a[data-space-id="#{off_limits.id}"]))
      assert html =~ granted.name
      refute html =~ off_limits.name

      # And because the identity is external, the external list renders even
      # here — the discovery chrome that would enumerate all channels is off.
      assert has_element?(view, ~s(#chat-list [data-role="external-identity"]))
      refute has_element?(view, "#list-more")
      refute html =~ ~s(phx-click="new_channel_open")
    end

    test "the /chat index on the suite host is likewise scoped, no all-channels leak",
         %{conn: conn, ext: ext, granted: granted, off_limits: off_limits} do
      {:ok, view, html} =
        conn
        |> authed(ext)
        |> live_settled("/chat")

      assert html =~ granted.name
      refute html =~ off_limits.name
      assert has_element?(view, ~s(#chat-list a[data-space-id="#{granted.id}"]))
      refute has_element?(view, ~s(#chat-list a[data-space-id="#{off_limits.id}"]))
      assert has_element?(view, ~s(#chat-list [data-role="external-identity"]))
    end

    test "an INTERNAL user on the suite host is completely unaffected (sees General)",
         %{conn: conn, off_limits: off_limits} do
      internal = create_user!("Ingrid Internal")
      join!(off_limits, internal)

      {:ok, view, html} =
        conn
        |> authed(internal)
        |> live("/chat/#{off_limits.slug}")

      # Identity-derived scope is a no-op for internal users: full internal
      # list, General visible, external branch dormant.
      assert html =~ off_limits.name
      assert has_element?(view, ~s(#chat-list a[data-space-id="#{off_limits.id}"]))
      assert has_element?(view, "#list-more")
      refute html =~ ~s(data-role="external-identity")
    end
  end

  # ── task 019f9257-a83e: mobile-responsive external surface ──────────────────
  #
  # The external rail was `flex` with no responsive gate, so at 375px it ate
  # ~288px beside the message pane and the conversation collapsed to a sliver;
  # every internal mobile affordance was `!@external?`-gated, so external users
  # had NO mobile channel switcher. These cases pin the fix: the rail is now
  # `hidden lg:flex` (desktop-only), and a FLAT `#external-mobile-switcher`
  # lists the external user's granted channels WITHOUT the org-tree /
  # new-channel / scope-pill discovery chrome. Since task 01a1557a-8562 it is
  # the external user's /chat landing on the phone.
  describe "mobile-responsive external surface (task 019f9257-a83e)" do
    setup %{conn: conn} do
      org = tenant_org!()
      ext = external_user!(org)
      chan_a = channel!("Design Review", org_id: org.id) |> join!(ext)
      chan_b = channel!("General Room", org_id: org.id) |> join!(ext)
      off_limits = channel!("Secret Ops")

      %{conn: conn, ext: ext, chan_a: chan_a, chan_b: chan_b, off_limits: off_limits}
    end

    test "external list carries the hidden lg:flex gate so it collapses on mobile",
         %{conn: conn, ext: ext, chan_a: chan_a} do
      for path <- ["/chat/#{chan_a.slug}", "/chat"] do
        {:ok, view, _html} =
          conn |> with_chat_host() |> authed(ext) |> live(path)

        list = view |> element("#chat-list") |> render()
        # Desktop-only on both routes, hidden < lg (the phone has the switcher).
        assert list =~ ~r/<section[^>]*class="hidden lg:flex/
      end
    end

    # Task 01a1557a-8562 stage 5 deleted the pills strip and the search button
    # that opened this switcher over an open conversation. The phone route to
    # it is now the conversation's back chevron: an external user's /chat has
    # no active space, so the switcher IS the landing.
    test "the back chevron lands on the FLAT external switcher — brand/identity kept, no discovery chrome",
         %{conn: conn, ext: ext, chan_a: chan_a, chan_b: chan_b, off_limits: off_limits} do
      {:ok, view, html} =
        conn |> with_chat_host() |> authed(ext) |> live("/chat/#{chan_a.slug}")

      # Not rendered while a space is active.
      refute html =~ ~s(data-role="external-mobile-switcher")
      assert html =~ ~s(data-role="chat-back")

      view
      |> element(~s(a[data-role="chat-back"]))
      |> render_click()

      assert_patch(view, "/chat")
      assert has_element?(view, "#external-mobile-switcher")

      overlay = view |> element(~s([data-role="external-mobile-switcher"])) |> render()

      # Flat allowlisted list — both granted channels, nothing off-limits.
      assert overlay =~ chan_a.name
      assert overlay =~ chan_b.name
      refute overlay =~ off_limits.name

      # Brand + identity + logout move into the overlay header (chrome-less layout).
      assert overlay =~ ~s(alt="#{Platform.Branding.app_name()}")

      refute overlay =~
               ~r/alt="#{Platform.Regression.InstallIdentityScanner.published_org_token()}"/i

      assert overlay =~ ext.name
      assert overlay =~ ~p"/auth/logout"
      assert overlay =~ "New conversation"

      # NONE of the internal discovery chrome, and no close control: the
      # switcher is a landing, not an overlay over a conversation.
      refute overlay =~ "channel-section-header"
      refute overlay =~ "New channel"
      refute overlay =~ ~s(aria-label="Close")
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

      # The internal back chevron lands on the INTERNAL Chat list, never the
      # external switcher.
      view
      |> element(~s(a[data-role="chat-back"]))
      |> render_click()

      assert has_element?(view, "#chat-list")
      refute render(view) =~ ~s(data-role="external-mobile-switcher")
    end
  end

  # ── task 019ffebf-4745: `:sidebar_changed` re-broadens the external rail ────
  #
  # The invariant, quoted from the comment above `rail_channels/1` in
  # `chat_live.ex`: "every reload of `:channels` after mount (nav,
  # `:space_created` broadcast, org-archive refresh, unarchive) must re-apply
  # `@external_scope` or a workspace-wide `list_spaces` would re-broaden an
  # external user's rail past their allowlist."
  #
  # `handle_info(:sidebar_changed, socket)` reloads `:channels` via
  # `Chat.list_spaces(kind: "channel")` with no `scope:`, and three lines later
  # `recompute_pinned/1` rebuilds `@channel_sections` off that widened list. The
  # leak therefore reaches the rendered rail as well as the raw assign.
  #
  # TWO SESSIONS, deliberately. `chat:sidebar:<user_id>` is per-user and
  # `broadcast_sidebar_changed_from/2` excludes the acting pid, so the acting
  # tab never runs this arm. A one-session test can only reach the handler by
  # calling it directly, which proves nothing about the path a user walks.
  describe "sidebar invalidation keeps the external allowlist (task 019ffebf-4745)" do
    setup %{conn: conn} do
      org = tenant_org!()
      ext = external_user!(org)

      allowed = channel!("Client Room", org_id: org.id) |> join!(ext)
      off_limits = channel!("Acme Internal Ops")

      %{conn: conn, ext: ext, org: org, allowed: allowed, off_limits: off_limits}
    end

    test "a sidebar change in one tab does not re-broaden the OTHER tab's rail",
         %{conn: conn, ext: ext, allowed: allowed, off_limits: off_limits} do
      # Tab A: the acting session. Tab B: the one that receives the broadcast.
      {:ok, view_a, _} =
        conn |> with_chat_host() |> authed(ext) |> live("/chat/#{allowed.slug}")

      {:ok, view_b, _} =
        conn |> with_chat_host() |> authed(ext) |> live("/chat/#{allowed.slug}")

      # Anti-vacuity precondition: the allowlist genuinely EXCLUDES a
      # non-archived channel at mount. If mount already leaked, every assertion
      # below would be measuring the wrong defect.
      assert allowed.id in channel_ids(view_b)

      refute off_limits.id in channel_ids(view_b),
             "mount already leaked, so this case is measuring the wrong defect"

      # The cheapest real sidebar write. It broadcasts
      # `:sidebar_changed` from tab A's pid, so ONLY tab B receives it.
      render_click(view_a, "toggle_pinned", %{"space_id" => allowed.id, "pinned" => "true"})

      # Sync tab B so the cast has been drained before reading its assigns.
      _ = render(view_b)

      after_ids = channel_ids(view_b)

      # THE LEAK. Tab B reloaded `:channels` workspace-wide.
      refute off_limits.id in after_ids,
             "#{off_limits.name} re-entered the external user's rail after a " <>
               ":sidebar_changed broadcast. The reload dropped @external_scope."

      # POSITIVE CONTROL, same test: the allowlisted channel survives. A rail
      # that merely emptied would satisfy the refute above and prove nothing.
      assert allowed.id in after_ids,
             "the allowlisted channel vanished, so the rail emptied instead of staying scoped"

      # The leak reaches the RENDER too, not only the assign.
      refute render(view_b) =~ off_limits.name
    end

    test "an INTERNAL user's rail is byte-identical across the same broadcast", %{conn: conn} do
      internal = create_user!("Ingo Internal")
      home = channel!("Internal General") |> join!(internal)
      _elsewhere = channel!("Another Internal Room")

      {:ok, view_a, _} = conn |> authed(internal) |> live("/chat/#{home.slug}")
      {:ok, view_b, _} = conn |> authed(internal) |> live("/chat/#{home.slug}")

      before_channels = :sys.get_state(view_b.pid).socket.assigns.channels

      # Vacuity guard: an internal rail with nothing in it would pass the
      # equality below no matter what the handler did.
      assert length(before_channels) >= 2,
             "the internal control is vacuous with fewer than two channels in the rail"

      render_click(view_a, "toggle_pinned", %{"space_id" => home.id, "pinned" => "true"})
      _ = render(view_b)

      after_assigns = :sys.get_state(view_b.pid).socket.assigns

      # Delivery proof. Without it the equality below passes just as well on a
      # broadcast that never arrived, which is the vacuous version of this case.
      assert home.id in after_assigns.pinned_space_ids,
             "tab B never ran the :sidebar_changed handler, so the control proves nothing"

      assert after_assigns.channels == before_channels,
             "the internal rail changed across a sidebar broadcast. The fix must be a no-op here."
    end

    # A fence on a LATENT defect, so it gets no red-first step, unlike the two
    # cases above. `:archived_channels` was read unscoped in three handlers, and
    # it leaked nothing because both renderings of the archived group sit behind
    # `!@external?` gates in `chat_live.html.heex` and `@external?` is assigned
    # once in `do_mount/3`. `rail_archived_channels/1` routes those reads through
    # one place so that deleting a template gate cannot quietly make the unscoped
    # read visible.
    #
    # Asserted on the ASSIGN, not the markup: for an external user this section
    # never renders, so there is no HTML to match on. Same mechanism the rest of
    # the `chat_live*` suite uses for assign-level facts.
    test "archived channels stay empty for an external user and populated for an internal one",
         %{conn: conn, ext: ext, allowed: allowed} do
      {:ok, archived} = Chat.archive_space(channel!("Retired Internal Room"))

      {:ok, ext_a, _} = conn |> with_chat_host() |> authed(ext) |> live("/chat/#{allowed.slug}")
      {:ok, ext_b, _} = conn |> with_chat_host() |> authed(ext) |> live("/chat/#{allowed.slug}")

      assert archived_channels(ext_b) == []

      render_click(ext_a, "toggle_pinned", %{"space_id" => allowed.id, "pinned" => "true"})
      _ = render(ext_b)

      assert archived_channels(ext_b) == [],
             "an archived channel entered the external user's :archived_channels after a " <>
               ":sidebar_changed broadcast"

      # POSITIVE CONTROL: the same archived channel IS delivered to an internal
      # user across the same broadcast. Without it the empty list above would
      # pass on a build where nobody gets archived channels at all.
      internal = create_user!("Ida Internal")
      home = channel!("Internal Landing") |> join!(internal)

      {:ok, int_a, _} = conn |> authed(internal) |> live("/chat/#{home.slug}")
      {:ok, int_b, _} = conn |> authed(internal) |> live("/chat/#{home.slug}")

      assert archived.id in Enum.map(archived_channels(int_b), & &1.id)

      render_click(int_a, "toggle_pinned", %{"space_id" => home.id, "pinned" => "true"})
      _ = render(int_b)

      assert archived.id in Enum.map(archived_channels(int_b), & &1.id),
             "the internal user lost the archived channel, so the helper is emptying too widely"
    end
  end

  # ── task 019ffca8 stage 4: nothing from an internal space can ENTER an
  #    external user's assigns ────────────────────────────────────────────────
  #
  # The assertion is about what can enter the assigns, NOT about what renders.
  # A LiveView can only render what its own socket holds, so a case that asserts
  # only "the external session does not render internal content" leaves the LOAD
  # path unexamined and stays green while internal content sits in the assigns
  # one render bug away from view. Every case below reads the hook's own state.
  #
  # ANTI-VACUITY, applied without exception. "No internal content reached the
  # external session" passes trivially against a build that delivered nothing at
  # all, so every refute is paired IN THE SAME TEST with a positive control
  # proving the legitimate load or delivery happened. The model is core#676
  # (`b4fa8d82`): assert the foreign event was really on the wire, then refute
  # the scoped receive.

  # An off-limits internal space, seeded with the three things an external
  # session must never hold: a message, a canvas, and an insider roster row.
  defp internal_space_with_content!(opts \\ []) do
    insider = create_user!("Ingrid Insider")
    space = channel!(Keyword.get(opts, :name, "Internal Ops Room"), opts)
    insider_participant = join!(space, insider) |> participant_for(insider)

    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: insider_participant.id,
        content_type: "text",
        content: "internal-only-message-body"
      })

    {:ok, canvas} = canvas!(space, insider_participant, "Internal Roadmap")

    %{space: space, insider: insider, message: message, canvas: canvas}
  end

  defp participant_for(space, user) do
    space.id
    |> Chat.list_participants(participant_type: "user")
    |> Enum.find(&(&1.participant_id == user.id))
  end

  defp canvas!(space, participant, title) do
    Chat.create_canvas(%{
      "space_id" => space.id,
      "created_by" => participant.id,
      "title" => title,
      "created_by_display_name" => "Ingrid Insider",
      "created_by_participant_type" => "user",
      "document" => %{
        "version" => 1,
        "revision" => 1,
        "root" => %{"id" => "root", "type" => "stack", "children" => []}
      }
    })
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp held_message_ids(view), do: assigns(view).rendered_message_ids

  defp held_canvas_ids(view), do: assigns(view).canvases_by_id |> Map.keys() |> MapSet.new()

  defp held_roster_ids(view) do
    assigns(view).space_participants |> MapSet.new(& &1.participant_id)
  end

  describe "path 1: the mount load path never loads an off-limits space" do
    setup %{conn: conn} do
      org = tenant_org!()
      ext = external_user!(org)
      allowed = channel!("Client Workspace", org_id: org.id) |> join!(ext)
      ext_participant = participant_for(allowed, ext)

      {:ok, own_message} =
        Chat.post_message(%{
          space_id: allowed.id,
          participant_id: ext_participant.id,
          content_type: "text",
          content: "allowlisted-message-body"
        })

      {:ok, own_canvas} = canvas!(allowed, ext_participant, "Client Brief")

      %{conn: conn, ext: ext, allowed: allowed, own_message: own_message, own_canvas: own_canvas}
    end

    test "the mounted session holds its own space's content and none of the internal space's",
         ctx do
      internal = internal_space_with_content!()

      {:ok, view, _html} =
        ctx.conn |> with_chat_host() |> authed(ctx.ext) |> live("/chat/#{ctx.allowed.slug}")

      # POSITIVE CONTROL FIRST. Each refute below is meaningless unless the
      # legitimate load actually populated the same assign.
      assert MapSet.member?(held_message_ids(view), ctx.own_message.id),
             "the allowlisted space's own message never loaded, so the refutes below are vacuous"

      assert MapSet.member?(held_canvas_ids(view), ctx.own_canvas.id),
             "the allowlisted space's own canvas never loaded, so the refutes below are vacuous"

      assert MapSet.member?(held_roster_ids(view), ctx.ext.id),
             "the allowlisted space's roster never loaded, so the refutes below are vacuous"

      refute MapSet.member?(held_message_ids(view), internal.message.id)
      refute MapSet.member?(held_canvas_ids(view), internal.canvas.id)
      refute MapSet.member?(held_roster_ids(view), internal.insider.id)
      refute internal.space.id in channel_ids(view)
      refute internal.space.id in Enum.map(assigns(view).spaces, & &1.id)
    end

    test "the three loaders themselves return nothing outside the allowlist", ctx do
      internal = internal_space_with_content!()

      external_scope = ExternalScope.for_user(ctx.ext.id)
      internal_scope = ExternalScope.for_user(create_user!("Ivan Internal").id)

      assert external_scope.external?, "the fixture user is not external, so nothing is narrowed"

      refute internal_scope.external?,
             "the control user is external too, so the pair proves nothing"

      # POSITIVE CONTROL: the same three calls under an INTERNAL scope DO return
      # the internal space's rows. Without this pair, an empty result would read
      # as a security pass on a build where the loaders were simply broken.
      assert internal.space.id in space_ids(
               Chat.list_spaces(kind: "channel", scope: internal_scope)
             )

      assert Chat.list_messages(internal.space.id, scope: internal_scope) != []
      assert Chat.list_canvases(internal.space.id, scope: internal_scope) != []

      refute internal.space.id in space_ids(
               Chat.list_spaces(kind: "channel", scope: external_scope)
             )

      assert Chat.list_messages(internal.space.id, scope: external_scope) == []
      assert Chat.list_canvases(internal.space.id, scope: external_scope) == []

      # And the allowlisted space still resolves under the external scope, so the
      # narrowing is a filter rather than a blanket refusal.
      assert ctx.allowed.id in space_ids(Chat.list_spaces(kind: "channel", scope: external_scope))
      assert Chat.list_messages(ctx.allowed.id, scope: external_scope) != []
    end

    # THE MUTANT, carried in the suite rather than run once by hand. Everything
    # above is also satisfied by a scope that returns nothing whenever the user
    # is external, which is the wrong rule and would hide the day membership
    # stops being consulted. So: a SECOND external user, one who IS a
    # participant of the very same internal space, must see all three row kinds.
    # What narrows is membership; externality only decides whether the narrowing
    # applies at all.
    test "an external user who IS a member of that space sees it, so membership is what narrows",
         ctx do
      internal = internal_space_with_content!()

      guest = external_user!(tenant_org!())
      join!(internal.space, guest)
      guest_scope = ExternalScope.for_user(guest.id)

      assert guest_scope.external?, "the guest is not external, so this proves the wrong thing"

      assert internal.space.id in space_ids(Chat.list_spaces(kind: "channel", scope: guest_scope))
      assert Chat.list_messages(internal.space.id, scope: guest_scope) != []
      assert Chat.list_canvases(internal.space.id, scope: guest_scope) != []

      # Same space, same instant, the non-member external user: still nothing.
      other = ExternalScope.for_user(ctx.ext.id)
      refute internal.space.id in space_ids(Chat.list_spaces(kind: "channel", scope: other))
      assert Chat.list_messages(internal.space.id, scope: other) == []
      assert Chat.list_canvases(internal.space.id, scope: other) == []
    end
  end

  describe "path 2: the subscribe set excludes off-limits space topics" do
    setup %{conn: conn} do
      org = tenant_org!()
      ext = external_user!(org)
      active = channel!("Client Workspace", org_id: org.id) |> join!(ext)
      background = channel!("Client Archive", org_id: org.id) |> join!(ext)

      %{conn: conn, ext: ext, org: org, active: active, background: background}
    end

    test "presence_subscribe_space_ids/2 intersects to the allowlist, and is identity internally",
         ctx do
      internal = internal_space_with_content!()
      all = [ctx.active, ctx.background, internal.space]

      external_set = ChatLive.presence_subscribe_space_ids(all, ctx.ext.id)

      # POSITIVE CONTROL: the SAME list, for an internal user, keeps every id.
      # A helper that returned [] for everyone would satisfy the refute alone.
      internal_user = create_user!("Ivan Internal")
      internal_set = ChatLive.presence_subscribe_space_ids(all, internal_user.id)

      assert Enum.sort(internal_set) == Enum.sort(Enum.map(all, & &1.id)),
             "the internal subscribe set was narrowed, so the helper is not identity internally"

      assert ctx.active.id in external_set
      assert ctx.background.id in external_set
      refute internal.space.id in external_set

      # THE MUTANT. The three assertions above are equally satisfied by a helper
      # that drops any space an external user did not create, or any space in
      # another org, or simply the last id in the list. Give the SAME internal
      # space to an external user who is a member of it: it must stay in the set.
      guest = external_user!(tenant_org!())
      join!(internal.space, guest)

      assert internal.space.id in ChatLive.presence_subscribe_space_ids(all, guest.id),
             "an external MEMBER lost their own space's topic, so the intersect is not membership"
    end

    test "a message posted into an off-limits space reaches the external session by no path",
         ctx do
      internal = internal_space_with_content!()
      insider_participant = participant_for(internal.space, internal.insider)

      {:ok, view, _html} =
        ctx.conn |> with_chat_host() |> authed(ctx.ext) |> live("/chat/#{ctx.active.slug}")

      before_unread = assigns(view).unread_counts

      # The foreign event, really on the wire: `Chat.post_message/1` broadcasts
      # `{:new_message, msg}` on the space topic exactly as production does.
      {:ok, foreign} =
        Chat.post_message(%{
          space_id: internal.space.id,
          participant_id: insider_participant.id,
          content_type: "text",
          content: "internal-only-broadcast-body"
        })

      # POSITIVE CONTROL, same test and same mechanism: a message in an
      # ALLOWLISTED background space DOES reach this session and moves its unread
      # count. That proves the per-space subscribe + `{:new_message}` path is live,
      # so the refutes below are measuring scope rather than a dead broadcast.
      background_author = create_user!("Bea Background")
      join!(ctx.background, background_author)
      background_participant = participant_for(ctx.background, background_author)

      {:ok, _allowed_msg} =
        Chat.post_message(%{
          space_id: ctx.background.id,
          participant_id: background_participant.id,
          content_type: "text",
          content: "allowlisted-background-body"
        })

      html = render(view)
      after_unread = assigns(view).unread_counts

      assert Map.get(after_unread, ctx.background.id, 0) >
               Map.get(before_unread, ctx.background.id, 0),
             "the allowlisted background space never delivered, so this case proves nothing"

      assert Map.get(after_unread, internal.space.id, 0) ==
               Map.get(before_unread, internal.space.id, 0),
             "an off-limits space's message reached the external session's unread counts"

      refute MapSet.member?(held_message_ids(view), foreign.id)
      refute html =~ "internal-only-broadcast-body"
    end
  end

  describe "path 3: the global chat:spaces topic" do
    # `chat:spaces` is joined by EVERY connected chat session, external ones
    # included (`ChatLive.do_mount/3`), so `{:space_created, space}` for an
    # internal channel does arrive here. What matters is what the handler then
    # puts into the assigns.
    #
    # SCOPE OF THIS CASE, stated so a green result is not over-read: it covers
    # the ASSIGNS only. The same clause also calls `ChatPubSub.subscribe/1` on
    # the new space; that decision is now guarded by
    # `presence_subscribe_space_ids/2` (task 01a011d4) and is asserted by the
    # sibling case below, which measures the SUBSCRIPTION rather than the rail.
    test "an internal channel created after mount enters nothing in the external assigns",
         %{conn: conn} do
      org = tenant_org!()
      ext = external_user!(org)
      allowed = channel!("Client Workspace", org_id: org.id) |> join!(ext)

      internal_user = create_user!("Ivan Internal")
      internal_home = channel!("Internal Landing") |> join!(internal_user)

      {:ok, ext_view, _} =
        conn |> with_chat_host() |> authed(ext) |> live("/chat/#{allowed.slug}")

      {:ok, int_view, _} = conn |> authed(internal_user) |> live("/chat/#{internal_home.slug}")

      # Created AFTER both sessions mounted, so it can only arrive by broadcast.
      fresh = channel!("Internal Skunkworks")

      _ = render(ext_view)
      _ = render(int_view)

      # POSITIVE CONTROL: the internal session DID receive the broadcast and put
      # the channel on its rail. Without it, a broadcast that never fired would
      # read exactly like a correctly scoped one.
      assert fresh.id in channel_ids(int_view),
             "the internal session never received {:space_created, _}, so the refutes are vacuous"

      ext_assigns = assigns(ext_view)

      refute fresh.id in channel_ids(ext_view)
      refute fresh.id in Enum.map(ext_assigns.spaces, & &1.id)
      refute section_space_ids(ext_assigns.channel_sections) |> Enum.member?(fresh.id)
      refute sidebar_section_space_ids(ext_assigns.sidebar_sections) |> Enum.member?(fresh.id)
      refute render(ext_view) =~ fresh.name

      # THE MUTANT, and the one that matters most here. Every refute above also
      # passes on a session that never joined `chat:spaces` at all, or whose
      # handler crashed, or that stopped processing broadcasts after mount, none
      # of which is the property being claimed. Make the SAME external session
      # entitled to the SAME channel and replay the SAME event: it must land.
      join!(fresh, ext)
      ChatPubSub.broadcast_space_event({:space_created, fresh})
      _ = render(ext_view)

      assert fresh.id in channel_ids(ext_view),
             "the external session did not act on {:space_created, _} even when entitled, " <>
               "so the refutes above were passing for the wrong reason"
    end

    # Task 01a011d4. The case above asserts the ASSIGNS, and it passed before
    # this guard existed, because `rail_channels/1` already re-scoped the rail.
    # What the unguarded clause still did was call `ChatPubSub.subscribe/1` on
    # the new space, so the session held that topic's subscription with nothing
    # rendering from it. A render assertion cannot see that. `unread_counts`
    # can: `MessagesHooks.handle_info({:new_message, _})` increments it for any
    # background message the process receives, with no membership or scope
    # check of its own, so the count moves if and only if this session holds
    # the space's subscription.
    test "an internal channel created after mount never enters the external subscribe set",
         %{conn: conn} do
      org = tenant_org!()
      ext = external_user!(org)
      allowed = channel!("Client Workspace", org_id: org.id) |> join!(ext)

      {:ok, view, _} =
        conn |> with_chat_host() |> authed(ext) |> live("/chat/#{allowed.slug}")

      before_unread = assigns(view).unread_counts

      # NEGATIVE HALF. Created AFTER the mount, so `{:space_created, _}` is the
      # only route by which its topic can reach this session. `render/1` is a
      # synchronous call to the view, so it flushes that broadcast before the
      # message below is posted.
      insider = create_user!("Ivan Internal")
      internal = channel!("Internal Skunkworks") |> join!(insider)
      insider_participant = participant_for(internal, insider)
      _ = render(view)

      {:ok, _foreign} =
        Chat.post_message(%{
          space_id: internal.id,
          participant_id: insider_participant.id,
          content_type: "text",
          content: "internal-only-after-mount-body"
        })

      # POSITIVE CONTROL, same session and same mechanism, on a channel this
      # external user IS entitled to. Without it, a broadcast that never fired,
      # a crashed handler, or a session that stopped processing broadcasts all
      # read as a pass. `channel!/2` broadcast `:space_created` before `join!/2`
      # landed, so replay the event after the join.
      entitled = channel!("Client Archive", org_id: org.id) |> join!(ext)
      ChatPubSub.broadcast_space_event({:space_created, entitled})
      _ = render(view)

      entitled_author = create_user!("Bea Background")
      join!(entitled, entitled_author)
      entitled_participant = participant_for(entitled, entitled_author)

      {:ok, _entitled_msg} =
        Chat.post_message(%{
          space_id: entitled.id,
          participant_id: entitled_participant.id,
          content_type: "text",
          content: "entitled-after-mount-body"
        })

      _ = render(view)
      after_unread = assigns(view).unread_counts

      assert Map.get(after_unread, entitled.id, 0) > Map.get(before_unread, entitled.id, 0),
             "an entitled channel created after mount never delivered its message, so the " <>
               "refute below is measuring a dead path rather than the subscribe scope"

      assert Map.get(after_unread, internal.id, 0) ==
               Map.get(before_unread, internal.id, 0),
             "the external session holds a subscription to an internal-only channel created " <>
               "after it mounted, so {:space_created, _} is subscribing outside its scope"
    end
  end

  # Task 01a017a3. `{:space_created, _}` above evaluates the subscribe decision
  # ONCE, at creation time. A session granted access to a channel that already
  # existed therefore held no subscription for it, and its unread badge stayed
  # dead until the next reload. The fix reconciles the subscribe set on the
  # per-user `:sidebar_changed` invalidation that the grant choke points now
  # emit, so the observable here is the SUBSCRIPTION, not the render:
  # `MessagesHooks.handle_info({:new_message, msg}, _)` increments the count
  # with no membership or scope check of its own, so `@unread_counts` moves if
  # and only if this session holds that space's topic.
  describe "path 5: a channel granted AFTER the session mounted" do
    setup %{conn: conn} do
      org = tenant_org!()
      ext = external_user!(org)
      landing = channel!("Client Workspace", org_id: org.id) |> join!(ext)

      %{conn: conn, org: org, ext: ext, landing: landing}
    end

    # THE ORDER OF THESE STEPS IS THE TEST. The grant happens AFTER the mount.
    # A version that grants first passes against this defect, because the
    # mount-time subscribe set already covers it. Do not re-order them.
    test "the admin-hub grant path subscribes the session and moves its unread badge", ctx do
      # Mounting on a channel the viewer already has keeps `@active_space`
      # non-nil. With no accessible channel it is nil, and `MessagesHooks` then
      # treats every arriving message as a background DM, which changes what the
      # assertions below measure.
      {:ok, view, _html} =
        ctx.conn |> with_chat_host() |> authed(ctx.ext) |> live("/chat/#{ctx.landing.slug}")

      before_unread = assigns(view).unread_counts

      # The ACTIVE space's registration count is captured, not asserted to be 1.
      # `PlatformWeb.ShellLive.on_mount/4` attaches a `:roster_updates`
      # `handle_info` hook INTO this LiveView's own process, and its
      # `{:roster_resolved, sid}` clause calls `ChatPubSub.subscribe/1` for the
      # active space outside ChatLive's accounting, so a freshly mounted session
      # already holds two registrations for whatever space it landed on. That is
      # pre-existing (reproduced on an unmodified checkout of this file's lib
      # sources) and belongs to whoever reconciles ShellLive's subscriptions.
      # What this task must not do is ADD to it, which is what the re-assertions
      # below measure.
      landing_registrations = registrations(view, ctx.landing)

      # Created WITHOUT the viewer, so the `{:space_created, _}` guard correctly
      # declines to subscribe. This is the channel the grant below confers.
      granted = channel!("Client Handover", org_id: ctx.org.id)

      # NEGATIVE CONTROL: same shape, never granted to this viewer. Without it,
      # a fix that went back to subscribing to everything passes every other
      # assertion in this test.
      never = channel!("Client Escrow", org_id: ctx.org.id)
      never_author = create_user!("Nadia Never")
      join!(never, never_author)
      never_participant = participant_for(never, never_author)

      _ = render(view)

      # The path the admin hub actually takes (`external_recovery_live.ex` calls
      # exactly this), NOT `Chat.add_participant/2`. The reported scenario never
      # reaches `Chat.do_add_participant/2`, so a test built on `join!/2` alone
      # would pass against a fix that cannot work on the reported path.
      :ok =
        ExternalGrants.add_space_participants(ctx.ext, [
          %{"space_id" => granted.id, "role" => "member"}
        ])

      # `Phoenix.PubSub.broadcast` resolves its subscribers by `Registry.lookup`
      # in the CALLING process at broadcast time, and this LiveView only appears
      # in that registry once it has PROCESSED the invalidation. `render/1` is a
      # synchronous call and therefore a mailbox barrier; posting without one
      # races the registration and flakes.
      _ = render(view)

      # The author must not be the viewer: `increment_unread/2` skips a message
      # whose participant is the current one.
      stranger = create_user!("Sam Stranger")
      join!(granted, stranger)
      stranger_participant = participant_for(granted, stranger)

      {:ok, _} =
        Chat.post_message(%{
          space_id: granted.id,
          participant_id: stranger_participant.id,
          content_type: "text",
          content: "granted-after-mount-body"
        })

      {:ok, _} =
        Chat.post_message(%{
          space_id: never.id,
          participant_id: never_participant.id,
          content_type: "text",
          content: "never-granted-body"
        })

      _ = render(view)
      after_unread = assigns(view).unread_counts

      assert Map.get(after_unread, granted.id, 0) > Map.get(before_unread, granted.id, 0),
             "the badge stayed dead for a channel this session was granted after it mounted"

      assert Map.get(after_unread, never.id, 0) == Map.get(before_unread, never.id, 0),
             "a channel this session was never granted moved its unread count, so the " <>
               "reconcile is subscribing outside the allowlist"

      # The rail half, read before any navigation.
      assert granted.id in channel_ids(view),
             "the granted channel never appeared in the rail"

      refute never.id in channel_ids(view)

      # `Phoenix.PubSub`'s registry runs `keys: :duplicate`: two registrations
      # deliver every broadcast twice and STILL satisfy the unread assertion
      # above. This is the only check that catches a `@subscribed_space_ids`
      # assign that has drifted from the real registry.
      assert registrations(view, granted) == 1
      assert registrations(view, ctx.landing) == landing_registrations

      # IDEMPOTENCE. `:sidebar_changed` already fires from nine other sites, so
      # the reconcile runs repeatedly in a normal session. A single-shot test
      # cannot see a double subscribe.
      ChatPubSub.broadcast_sidebar_changed(ctx.ext.id)
      _ = render(view)

      assert registrations(view, granted) == 1
      assert registrations(view, ctx.landing) == landing_registrations

      assert assigns(view).unread_counts == after_unread,
             "a second :sidebar_changed moved the unread counts on its own, which is the " <>
               "double-delivery signature"
    end

    test "the in-chat add_participant path subscribes the session too", ctx do
      {:ok, view, _html} =
        ctx.conn |> with_chat_host() |> authed(ctx.ext) |> live("/chat/#{ctx.landing.slug}")

      before_unread = assigns(view).unread_counts
      granted = channel!("Client Retainer", org_id: ctx.org.id)
      _ = render(view)

      # `Chat.add_participant/2`, the in-chat add_participant path and a
      # different choke point from the one the test above exercises.
      join!(granted, ctx.ext)
      _ = render(view)

      stranger = create_user!("Sam Stranger")
      join!(granted, stranger)
      stranger_participant = participant_for(granted, stranger)

      {:ok, _} =
        Chat.post_message(%{
          space_id: granted.id,
          participant_id: stranger_participant.id,
          content_type: "text",
          content: "sheet-granted-body"
        })

      _ = render(view)

      assert Map.get(assigns(view).unread_counts, granted.id, 0) >
               Map.get(before_unread, granted.id, 0),
             "the in-chat add_participant path left the badge dead"

      assert registrations(view, granted) == 1
    end

    # Task 01a011e9's fix lives on the leave/enter path, and routing all eight
    # subscribe / unsubscribe sites through the tracking helpers is the most
    # likely thing to break it.
    test "navigating away and back leaves exactly one registration per rail space", ctx do
      other = channel!("Client Archive", org_id: ctx.org.id) |> join!(ctx.ext)

      {:ok, view, _html} =
        ctx.conn |> with_chat_host() |> authed(ctx.ext) |> live("/chat/#{ctx.landing.slug}")

      render_patch(view, ~p"/chat/#{other.slug}")
      assert assigns(view).active_space.id == other.id

      render_patch(view, ~p"/chat/#{ctx.landing.slug}")
      assert assigns(view).active_space.id == ctx.landing.id

      assert registrations(view, ctx.landing) == 1
      assert registrations(view, other) == 1
    end
  end

  describe "path 6: a channel REVOKED after the session mounted" do
    setup %{conn: conn} do
      org = tenant_org!()
      ext = external_user!(org)

      %{conn: conn, org: org, ext: ext}
    end

    # THE ORDER OF THESE STEPS IS THE TEST. The revoke happens AFTER the mount.
    # A version that revokes first passes against this defect, because the
    # mount-time subscribe set never covered the space. Do not re-order them.
    test "revoking a channel releases its subscription and stops its badge", ctx do
      # `landing` keeps `@active_space` non-nil. Mounting with no accessible
      # channel leaves it nil, and `MessagesHooks` then treats EVERY arriving
      # message as background, which changes what the assertions below measure.
      landing = channel!("Client Workspace", org_id: ctx.org.id) |> join!(ctx.ext)

      # POSITIVE CONTROL: a background channel the viewer keeps throughout.
      kept = channel!("Client Retainer", org_id: ctx.org.id) |> join!(ctx.ext)

      # The case: a background channel whose participant row is deleted below.
      revoked = channel!("Client Handover", org_id: ctx.org.id) |> join!(ctx.ext)

      {:ok, view, _html} =
        ctx.conn |> with_chat_host() |> authed(ctx.ext) |> live("/chat/#{landing.slug}")

      before_unread = assigns(view).unread_counts

      # Captured, never asserted to be a literal. See the note on the next
      # assertion for why the count is not ChatLive's to predict.
      kept_registrations = registrations(view, kept)

      # `> 0`, not `== 1`, and measured rather than predicted. ShellLive's
      # `:roster_updates` hook subscribes the WHOLE presence set from inside
      # this LiveView process (`{:presence_spaces_resolved, ids}`), so every
      # space already in the rail at mount carries two registrations: ChatLive's
      # and ShellLive's. That is pre-existing and is why the post-revoke
      # assertion below is 0 rather than a decrement — `Registry.unregister/2`
      # drops both at once. What this assertion is for is refusing to measure a
      # session that held nothing to begin with.
      assert registrations(view, revoked) > 0,
             "the session did not hold a subscription for the background channel before the " <>
               "revoke, so nothing below this line is measuring the defect"

      # `Phoenix.PubSub.broadcast` resolves subscribers by `Registry.lookup` in
      # the CALLING process at broadcast time, and this LiveView only reflects
      # the release once it has PROCESSED the event. `render/1` is a
      # synchronous call and therefore a mailbox barrier; without one this
      # flakes.
      _ = render(view)

      {:ok, _} = Chat.remove_participant(participant_for(revoked, ctx.ext))

      _ = render(view)

      # The author must not be the viewer: `increment_unread/2` skips a message
      # whose participant is the current one.
      revoked_author = create_user!("Sam Stranger")
      join!(revoked, revoked_author)
      revoked_participant = participant_for(revoked, revoked_author)

      kept_author = create_user!("Nadia Neighbour")
      join!(kept, kept_author)
      kept_participant = participant_for(kept, kept_author)

      {:ok, _} =
        Chat.post_message(%{
          space_id: revoked.id,
          participant_id: revoked_participant.id,
          content_type: "text",
          content: "revoked-after-mount-body"
        })

      {:ok, _} =
        Chat.post_message(%{
          space_id: kept.id,
          participant_id: kept_participant.id,
          content_type: "text",
          content: "still-a-member-body"
        })

      _ = render(view)
      after_unread = assigns(view).unread_counts

      assert Map.get(after_unread, revoked.id, 0) == Map.get(before_unread, revoked.id, 0),
             "a channel this session was removed from still moved its unread count"

      assert registrations(view, revoked) == 0,
             "the session still holds a PubSub registration for a channel it was removed from"

      assert Map.get(after_unread, kept.id, 0) > Map.get(before_unread, kept.id, 0),
             "the badge went dead for a channel the viewer still belongs to, so the release " <>
               "is over-unsubscribing (task 01a011e9)"

      assert registrations(view, kept) == kept_registrations,
             "the release changed the registration count for a channel the viewer still " <>
               "belongs to"
    end

    # The guard on the predicate. An internal user's rail is `Chat.list_spaces`
    # with no membership filter, so they see every workspace channel whether or
    # not a participant row exists. Releasing on "my participant row was
    # deleted" instead of on "this space left my subscribe scope" would kill
    # live chat for every internal user ever removed from a channel.
    test "an internal user removed from a channel keeps receiving it", %{conn: conn} do
      internal = create_user!("Ivan Internal")
      landing = channel!("Internal Landing") |> join!(internal)
      background = channel!("Internal Background") |> join!(internal)

      {:ok, view, _html} =
        conn |> authed(internal) |> live("/chat/#{Chat.space_path_segment(landing)}")

      before_unread = assigns(view).unread_counts
      background_registrations = registrations(view, background)

      assert background_registrations > 0,
             "the internal session held no subscription for the background channel at mount, " <>
               "so the re-assertion below cannot detect an over-release"

      _ = render(view)

      {:ok, _} = Chat.remove_participant(participant_for(background, internal))

      _ = render(view)

      author = create_user!("Nadia Neighbour")
      join!(background, author)
      author_participant = participant_for(background, author)

      {:ok, _} =
        Chat.post_message(%{
          space_id: background.id,
          participant_id: author_participant.id,
          content_type: "text",
          content: "internal-still-subscribed-body"
        })

      _ = render(view)

      assert Map.get(assigns(view).unread_counts, background.id, 0) >
               Map.get(before_unread, background.id, 0),
             "an internal user's badge went dead after their participant row was deleted, so " <>
               "the release is keying on identity instead of on loss of access"

      assert registrations(view, background) == background_registrations,
             "the release dropped an internal session's subscription to a channel it can " <>
               "still open"
    end
  end

  describe "path 4: navigation between allowlisted spaces leaves nothing behind" do
    test "after moving space to space, the session holds no off-limits message, canvas or roster row",
         %{conn: conn} do
      org = tenant_org!()
      ext = external_user!(org)

      space_a = channel!("Client Workspace", org_id: org.id) |> join!(ext)
      space_b = channel!("Client Archive", org_id: org.id) |> join!(ext)
      participant_a = participant_for(space_a, ext)
      participant_b = participant_for(space_b, ext)

      {:ok, canvas_a} = canvas!(space_a, participant_a, "Brief A")
      {:ok, canvas_b} = canvas!(space_b, participant_b, "Brief B")

      internal = internal_space_with_content!()

      {:ok, view, _} = conn |> with_chat_host() |> authed(ext) |> live("/chat/#{space_a.slug}")

      assert MapSet.member?(held_canvas_ids(view), canvas_a.id),
             "space A's canvas never loaded, so the navigation below starts from nothing"

      render_patch(view, ~p"/chat/#{space_b.slug}")

      # POSITIVE CONTROL: the move actually happened and actually reloaded.
      assert assigns(view).active_space.id == space_b.id

      assert MapSet.member?(held_canvas_ids(view), canvas_b.id),
             "space B's canvas never loaded, so the refutes below ride on an empty map"

      # The canvas map is REPLACED on a space switch, not merged. This is the
      # assertion that keeps the off-limits refute honest: a map that only ever
      # grew would hide a stale entry behind a passing `refute Map.has_key?`.
      refute MapSet.member?(held_canvas_ids(view), canvas_a.id),
             "space A's canvas survived the move to space B, so @canvases_by_id accumulates"

      refute MapSet.member?(held_message_ids(view), internal.message.id)
      refute MapSet.member?(held_canvas_ids(view), internal.canvas.id)
      refute MapSet.member?(held_roster_ids(view), internal.insider.id)

      # And back again, because a return trip re-runs the loaders a second time.
      render_patch(view, ~p"/chat/#{space_a.slug}")

      assert assigns(view).active_space.id == space_a.id
      assert MapSet.member?(held_canvas_ids(view), canvas_a.id)
      refute MapSet.member?(held_canvas_ids(view), canvas_b.id)
      refute MapSet.member?(held_message_ids(view), internal.message.id)
      refute MapSet.member?(held_canvas_ids(view), internal.canvas.id)
      refute MapSet.member?(held_roster_ids(view), internal.insider.id)
      refute render(view) =~ "internal-only-message-body"
    end
  end

  # ── REPRODUCTION for task 01a011ed-9ce1-7c8b-90d3-3d1b7527656d ─────────────
  #
  # THE DEFECT. `PlatformWeb.Plugs.ExternalUserScope` was the only gate deciding
  # which space an external user may open, and plugs run on HTTP requests only.
  # `ChatLive.handle_params/3` re-resolved and loaded a space with no external
  # scope check, and the socket accepts a client-sent `live_patch` frame that
  # reaches it without passing any plug. `Phoenix.LiveViewTest.render_patch/2`
  # pushes that exact frame, so this is the browser's own capability rather than
  # a test-only affordance.
  #
  # The read was not the worst of it. `ensure_participant/2` inserts a
  # `chat_participants` row on entry with no authorization check, so the bypass
  # converted itself into permanent membership: the space joined the rail, a
  # cold HTTP mount at the same URL returned 200 instead of 403, and the
  # external user could post into it. `refute Chat.participant?/2` is what pins
  # that, and it is in every case below for that reason.
  #
  # WHY THE COMMITTED ASSERTIONS COULD NOT STAY VERBATIM, and why the
  # replacement is not a weakening. As committed, this case read `assigns(view)`
  # after the patch. The shipped gate denies by `push_navigate(to: ~p"/chat")`,
  # which STOPS the LiveView process — so a post-patch `assigns(view)` exits
  # with `no process` rather than returning state to refute, on a build where
  # the gate works perfectly. Those refutes are replaced by `assert_redirect/2`,
  # which is strictly stronger: a redirected process holds no assigns at all, so
  # there is nothing left for internal content to leak into. The two assertions
  # that read the DATABASE rather than the view — the HTTP 403 control and
  # `refute Chat.participant?/2` — are unchanged, because the dead process does
  # not touch them.
  #
  # THREE RESOLVER BRANCHES reach an off-limits space from `handle_params/3`,
  # and each gets its own case, because they are three different lookups: a gate
  # placed inside any one of them would leave the other two open.
  #
  #   1. `system_prefix_fallback/1` — a reserved `task-exec-` slug, resolved
  #      with no org scoping at all. This is the branch the committed
  #      reproduction walked.
  #   2. `bootstrap_space/2`'s ADOPT branch — an ORG-LESS channel slug, which
  #      the org-scoped lookup structurally cannot see.
  #   3. `Chat.get_space/1` — a bare space UUID.
  #
  # ANTI-VACUITY, applied without exception. A gate that denied EVERYTHING would
  # pass every refute here, so each case pairs its refutes IN THE SAME TEST with
  # a positive control. The control always runs FIRST, and has to: after the
  # deny there is no process left to assert anything against.
  describe "path 3: a client-sent live_patch cannot open an off-limits space" do
    setup %{conn: conn} do
      org = tenant_org!()
      ext = external_user!(org)

      allowed = channel!("Client Workspace", org_id: org.id) |> join!(ext)
      landing = channel!("Client Intake", org_id: org.id) |> join!(ext)
      landing_message = message_in!(landing, ext, "landing-message-body")

      %{
        conn: conn,
        org: org,
        ext: ext,
        allowed: allowed,
        landing: landing,
        landing_message: landing_message
      }
    end

    # BRANCH 1 — `system_prefix_fallback/1`. The committed reproduction.
    test "an external user cannot open an off-limits space over the live socket", ctx do
      internal =
        internal_space_with_content!(
          name: "Internal Execution Space",
          slug: "task-exec-#{System.unique_integer([:positive])}"
        )

      # The branch is the one this case claims to walk: a reserved prefix, so
      # the unscoped fallback answers where the org-scoped lookup cannot.
      assert Chat.reserved_slug_prefix?(internal.space.slug)
      refute Chat.get_space_by_slug(internal.space.slug, org_id: ctx.org.id)

      # CONTROL: the plug refuses the same space over HTTP. Without this the
      # case could not tell a missing gate from a space that does not resolve.
      assert ctx.conn
             |> with_chat_host()
             |> authed(ctx.ext)
             |> get(~p"/chat/#{internal.space.slug}")
             |> Map.get(:status) == 403

      {:ok, view, _} = live(external_conn(ctx.conn, ctx.ext), ~p"/chat/#{ctx.allowed.slug}")

      # POSITIVE CONTROL: patching to a space this user IS a member of lands
      # and LOADS — the message is in the assigns, not merely the URL changed.
      render_patch(view, ~p"/chat/#{ctx.landing.slug}")
      assert assigns(view).active_space.id == ctx.landing.id
      assert MapSet.member?(held_message_ids(view), ctx.landing_message.id)

      render_patch(view, ~p"/chat/#{internal.space.slug}")

      assert_redirect(view, "/chat")

      refute Chat.participant?(internal.space.id, ctx.ext.id),
             "entering the space minted a chat_participants row, making the bypass permanent"
    end

    # BRANCH 2 — `bootstrap_space/2`'s adopt branch. An org-less channel row is
    # invisible to the org-scoped slug lookup, so resolution falls all the way
    # through to the branch that ADOPTS it (task 01a00910 stage 5 added that
    # branch to stop a duplicate channel being minted; it also opened a second
    # way into an off-limits space).
    test "an external user cannot open an off-limits ORG-LESS channel slug over the live socket",
         ctx do
      internal = internal_space_with_content!(name: "Internal Ops Room")

      # Pin the branch identity. If a later change gives this row an org, the
      # case silently becomes a duplicate of branch 3 and stops covering the
      # adopt path — these two lines fail instead.
      refute Chat.reserved_slug_prefix?(internal.space.slug)
      refute Chat.get_space_by_slug(internal.space.slug, org_id: ctx.org.id)
      assert Chat.get_orgless_space_by_slug(internal.space.slug).id == internal.space.id

      assert ctx.conn
             |> with_chat_host()
             |> authed(ctx.ext)
             |> get(~p"/chat/#{internal.space.slug}")
             |> Map.get(:status) == 403

      {:ok, view, _} = live(external_conn(ctx.conn, ctx.ext), ~p"/chat/#{ctx.allowed.slug}")

      render_patch(view, ~p"/chat/#{ctx.landing.slug}")
      assert assigns(view).active_space.id == ctx.landing.id
      assert MapSet.member?(held_message_ids(view), ctx.landing_message.id)

      render_patch(view, ~p"/chat/#{internal.space.slug}")

      assert_redirect(view, "/chat")

      refute Chat.participant?(internal.space.id, ctx.ext.id),
             "the adopt branch minted a chat_participants row for an off-limits channel"
    end

    # BRANCH 3 — a bare space UUID. `Chat.get_space/1` is unscoped by design,
    # so this branch reaches EVERY space in the deployment, org-less or not.
    test "an external user cannot open an off-limits space by bare UUID over the live socket",
         ctx do
      internal = internal_space_with_content!(name: "Internal Strategy Room")

      assert ctx.conn
             |> with_chat_host()
             |> authed(ctx.ext)
             |> get(~p"/chat/#{internal.space.id}")
             |> Map.get(:status) == 403

      {:ok, view, _} = live(external_conn(ctx.conn, ctx.ext), ~p"/chat/#{ctx.allowed.slug}")

      render_patch(view, ~p"/chat/#{ctx.landing.slug}")
      assert assigns(view).active_space.id == ctx.landing.id
      assert MapSet.member?(held_message_ids(view), ctx.landing_message.id)

      render_patch(view, ~p"/chat/#{internal.space.id}")

      assert_redirect(view, "/chat")

      refute Chat.participant?(internal.space.id, ctx.ext.id),
             "a bare-UUID patch minted a chat_participants row for an off-limits space"
    end

    # THE CONTROL A MEMBERSHIP-ONLY GATE FAILS. Admission is wider than the read
    # scope: an external user may open a DM with a counterpart on their per-org
    # allowlist even with no participant row of their own. Swap
    # `authorized_space?/2` for `visible_space_id?/2` and this case goes red
    # while every refute above stays green.
    test "an allowlisted DM still opens over the socket, and one off the allowlist does not",
         ctx do
      allowlisted = dm_with_counterpart!(ctx.org)
      off_allowlist = dm_with_counterpart!(tenant_org!())

      # Membership cannot be what admits either DM — there is none.
      refute Chat.participant?(allowlisted.id, ctx.ext.id)
      refute Chat.participant?(off_allowlist.id, ctx.ext.id)

      {:ok, view, _} = live(external_conn(ctx.conn, ctx.ext), ~p"/chat/#{ctx.allowed.slug}")

      # POSITIVE CONTROL: the allowlist alone opens it, and the entry is real —
      # `ensure_participant/2` ran, which is what a landed load does.
      render_patch(view, ~p"/chat/#{allowlisted.slug}")
      assert assigns(view).active_space.id == allowlisted.id
      assert Chat.participant?(allowlisted.id, ctx.ext.id)

      render_patch(view, ~p"/chat/#{off_allowlist.slug}")

      assert_redirect(view, "/chat")
      refute Chat.participant?(off_allowlist.id, ctx.ext.id)
    end

    # The other half of "the gate does not deny everything": internal users are
    # a complete no-op. `external_session?/1` keys on IDENTITY, so an internal
    # user's reach is exactly what it was before the gate shipped — including
    # into spaces they have not joined, which is today's behaviour and not this
    # ticket's to change.
    test "an internal user patching between two spaces is unaffected", %{conn: conn} do
      insider = create_user!("Ivor Insider")
      org = tenant_org!()
      plain_membership!(insider, org)

      # In the insider's own org: a sub-org-only member is fenced to their
      # orgs (ticket 01a14721), so an org-less channel is no longer theirs to
      # open, and this test is about the external gate, not the fence.
      first = channel!("Ops Intake", org_id: org.id)
      second = channel!("Ops Handover", org_id: org.id)

      refute Chat.participant?(first.id, insider.id)
      refute Chat.participant?(second.id, insider.id)

      {:ok, view, _} = live(authed(conn, insider), ~p"/chat/#{first.slug}")
      assert assigns(view).active_space.id == first.id

      render_patch(view, ~p"/chat/#{second.slug}")
      assert assigns(view).active_space.id == second.id
      assert Chat.participant?(second.id, insider.id)
    end
  end

  # ── The embedded half of the same gate ─────────────────────────────────────
  #
  # `bootstrap_embedded_space/2` is the meeting chat pane's resolver. It has no
  # `handle_params/3` (Phoenix forbids one on a nested LiveView), so there is
  # nothing to patch: the whole resolution happens once, at mount, from the
  # session slug MeetingLive hands down. It therefore needed its own gate and
  # gets its own case.
  describe "path 4: the embedded meeting pane never bootstraps an off-limits space" do
    setup %{conn: conn} do
      org = tenant_org!()
      ext = external_user!(org)
      allowed = channel!("Client Workspace", org_id: org.id) |> join!(ext)

      internal =
        internal_space_with_content!(
          name: "Internal Execution Space",
          slug: "task-exec-#{System.unique_integer([:positive])}"
        )

      %{conn: conn, org: org, ext: ext, allowed: allowed, internal: internal}
    end

    test "refuses an off-limits space for an external session and still renders an entitled one",
         ctx do
      # POSITIVE CONTROL: the pane paints the space this user IS entitled to.
      {:ok, allowed_view, _} = embedded_pane(ctx.conn, ctx.ext, ctx.allowed.slug)
      assert assigns(allowed_view).active_space.id == ctx.allowed.id

      # `@external?` is FALSE on this session even though the user IS external:
      # `do_mount/3` hard-codes a nil external scope for every embedded mount,
      # because that assign is a RENDER decision (the pane must paint no
      # external chrome). The gate cannot key off it here, which is why
      # `external_session?/1` carries a second clause asking
      # `Tenancy.external_user?/1` directly. Pinned so a "simplification" back
      # to the assign fails loudly instead of silently disarming this gate.
      refute assigns(allowed_view).external?
      assert Tenancy.external_user?(%{id: ctx.ext.id})

      {:ok, denied_view, denied_html} = embedded_pane(ctx.conn, ctx.ext, ctx.internal.space.slug)

      # Denial here is SILENT AND LOCAL — the pane collapses to no active space
      # rather than redirecting, because a push_navigate would move the PARENT
      # meeting surface out of the meeting.
      refute assigns(denied_view).active_space
      refute denied_html =~ "internal-only-message-body"
      refute render(denied_view) =~ "internal-only-message-body"
      refute MapSet.member?(held_message_ids(denied_view), ctx.internal.message.id)
      refute MapSet.member?(held_canvas_ids(denied_view), ctx.internal.canvas.id)
      refute MapSet.member?(held_roster_ids(denied_view), ctx.internal.insider.id)

      refute Chat.participant?(ctx.internal.space.id, ctx.ext.id)

      # POSITIVE CONTROL for the nil above: it came from the GATE, not from a
      # slug that fails to resolve on this path. The same slug, mounted by an
      # internal user, paints the space.
      {:ok, insider_view, _} =
        embedded_pane(ctx.conn, ctx.internal.insider, ctx.internal.space.slug)

      assert assigns(insider_view).active_space.id == ctx.internal.space.id
    end
  end

  defp external_conn(conn, ext), do: conn |> with_chat_host() |> authed(ext)

  defp plain_membership!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp message_in!(space, user, body) do
    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant_for(space, user).id,
        content_type: "text",
        content: body
      })

    message
  end

  # A DM the external user holds NO participant row in, whose only other
  # participant belongs to `org`. Whether it opens is then a pure function of
  # whether `org` is on the caller's DM allowlist.
  defp dm_with_counterpart!(org) do
    counterpart = create_user!("Cyrus Counterpart")
    plain_membership!(counterpart, org)

    {:ok, dm} =
      Chat.create_space(%{
        name: "Direct message",
        slug: "dm-#{System.unique_integer([:positive])}",
        kind: "dm"
      })

    join!(dm, counterpart)
    dm
  end

  # Mount the meeting chat pane in isolation. `ChatLive.Embedded` is the module
  # MeetingLive `live_render`s, and it seeds its space from the session because
  # URL params do not flow to child LiveViews.
  defp embedded_pane(conn, user, slug) do
    live_isolated(conn, PlatformWeb.ChatLive.Embedded,
      session: %{"current_user_id" => user.id, "chat_space_slug" => slug}
    )
  end

  defp space_ids(spaces), do: Enum.map(spaces, & &1.id)

  # `channel_sections/5` returns `%{pinned:, dms:, sub_orgs: %{bucket => [space]},
  # hidden_sub_orgs: %{bucket => [space]}}`. Every bucket is walked, the hidden
  # ones included: a channel parked in `hidden_sub_orgs` is still IN the assign,
  # and the whole point of this stage is what the assign holds.
  defp section_space_ids(%{
         pinned: pinned,
         dms: dms,
         sub_orgs: sub_orgs,
         hidden_sub_orgs: hidden_sub_orgs
       }) do
    bucket_spaces = fn buckets -> Enum.flat_map(buckets, fn {_bucket, spaces} -> spaces end) end

    (pinned ++ dms ++ bucket_spaces.(sub_orgs) ++ bucket_spaces.(hidden_sub_orgs))
    |> Enum.map(& &1.id)
  end

  defp sidebar_section_space_ids(sidebar_sections) do
    sidebar_sections |> Sidebar.flatten_sections() |> Enum.map(& &1.id)
  end

  defp archived_channels(view) do
    :sys.get_state(view.pid).socket.assigns.archived_channels
  end

  defp channel_ids(view) do
    :sys.get_state(view.pid).socket.assigns.channels |> Enum.map(& &1.id)
  end

  # How many PubSub registrations the LiveView process holds for a space's
  # topic. `Phoenix.PubSub.subscribe/2` is `Registry.register/3` on a
  # `keys: :duplicate` registry, so this counts entries rather than answering a
  # yes/no, which is the whole point: two entries fire `handle_info` twice.
  # Copied from `chat_live_unread_after_leaving_test.exs` (task 01a011e9).
  defp registrations(view, space) do
    Platform.PubSub
    |> Registry.lookup(ChatPubSub.space_topic(space.id))
    |> Enum.count(fn {pid, _meta} -> pid == view.pid end)
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
