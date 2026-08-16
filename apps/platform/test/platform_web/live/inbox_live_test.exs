defmodule PlatformWeb.InboxLiveTest do
  @moduledoc """
  Tests for the InboxLive surface (M6 of the Inbox System v1 stack).

  Covers the contract the plan + e2e_behavior validations call out:

    * each section renders its category and auto-hides when empty;
    * a broadcast `{:inbox_item_added, item}` streams a new row in at the top
      (and reveals a previously-hidden section);
    * a dismiss event removes the row and it does not reappear on re-render;
    * a click marks `read_at` and navigates to `item.url`, and the read item
      is gone on the next mount;
    * an empty inbox renders the `EmptyState` `:minimal` copy;
    * Mentions are grouped by space (per-row space label).
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures, only: [fabrikam_org_id: 0]

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Repo

  # ── Helpers ────────────────────────────────────────────────────────────

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      name: "Inbox LV User #{n}",
      email: "inbox_lv_#{n}@example.com",
      oidc_sub: "oidc-inbox-lv-#{n}"
    })
  end

  defp auth(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp emit!(user, overrides) do
    attrs =
      Map.merge(
        %{
          user_id: user.id,
          kind: "chat_mention",
          source_type: "chat_message",
          source_id: Ecto.UUID.generate(),
          title: "You were mentioned",
          body: "Rowan mentioned you",
          url: "/chat/general"
        },
        Map.new(overrides)
      )

    {:ok, item} = Inbox.emit(attrs)
    item
  end

  defp row_selector(%Item{id: id}), do: ~s([data-item-id="#{id}"])

  defp add_user_participant(space_id, %User{} = user, display_name) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  # Rendered space chips, in DOM order. This project has no Floki (LazyHTML is
  # the LiveViewTest backend), and `element/2` raises on multiple matches, so
  # read the chips straight out of the markup. `data-role` is the LAST
  # attribute on the span (components/inbox_item.ex), hence the anchor.
  defp mention_labels(lv) do
    ~r{data-role="inbox-item-space"\s*>\s*([^<]*)</span>}
    |> Regex.scan(render(lv))
    |> Enum.map(fn [_, text] -> text |> String.trim() |> html_unescape() end)
  end

  # The chip on the first mention row, or nil when no row carries one.
  defp mention_label(lv) do
    case mention_labels(lv) do
      [] -> nil
      [first | _] -> first
    end
  end

  defp html_unescape(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&#39;", "'")
    |> String.replace("&quot;", "\"")
  end

  # ── Sections + auto-hide ───────────────────────────────────────────────

  describe "sectioned render" do
    test "renders every populated section with its items; empty sections are absent",
         %{conn: conn} do
      user = insert_user()

      review =
        emit!(user,
          kind: "review_request_pending",
          source_type: "review_request",
          title: "Approve the deploy"
        )

      plan = emit!(user, kind: "task_plan_review", source_type: "task", title: "Plan for M6")
      mention = emit!(user, kind: "chat_mention", title: "@you in #general", url: "/chat/general")

      meeting =
        emit!(user,
          kind: "meeting_starting",
          source_type: "meeting",
          title: "Standup starting",
          url: "/meetings/standup"
        )

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      assert has_element?(lv, ~s([data-section="review"]))
      assert has_element?(lv, ~s([data-section="mentions"]))
      assert has_element?(lv, ~s([data-section="meetings"]))

      for item <- [review, plan, mention, meeting] do
        assert has_element?(lv, row_selector(item))
      end

      # dom ids follow the stream contract exactly.
      assert has_element?(lv, "#inbox-item-#{review.id}")
    end

    test "a task_sponsor_assigned item renders in the review section (not dropped)",
         %{conn: conn} do
      user = insert_user()

      sponsor =
        emit!(user,
          kind: "task_sponsor_assigned",
          source_type: "task",
          title: "You're now sponsoring: Ship the thing",
          url: "/tasks/#{Ecto.UUID.generate()}"
        )

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      # section_for/1 routes the kind to :review, so the row is streamed and
      # rendered rather than grouped under a nil section and vanishing.
      assert has_element?(lv, ~s([data-section="review"]))
      assert has_element?(lv, row_selector(sponsor))
      assert render(lv) =~ "You&#39;re now sponsoring: Ship the thing"
    end

    test "a live-broadcast task_sponsor_assigned row streams into the review section",
         %{conn: conn} do
      user = insert_user()

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      refute has_element?(lv, ~s([data-section="review"]))

      sponsor =
        emit!(user,
          kind: "task_sponsor_assigned",
          source_type: "task",
          title: "You're now sponsoring: Live one",
          url: "/tasks/#{Ecto.UUID.generate()}"
        )

      # The {:inbox_item_added} PubSub path uses the same section_for/1, so the
      # previously-hidden review section appears with the streamed row.
      assert has_element?(lv, ~s([data-section="review"]))
      assert has_element?(lv, row_selector(sponsor))
    end

    test "an unknown/future kind still renders (catch-all routes to review)",
         %{conn: conn} do
      user = insert_user()

      # Bypass the emit changeset's kind allow-list to simulate a kind the
      # server knows about but this LiveView's section_for/1 has no explicit
      # clause for — it must still render, not vanish.
      item =
        Repo.insert!(%Item{
          user_id: user.id,
          kind: "some_future_kind",
          source_type: "task",
          source_id: Ecto.UUID.generate(),
          title: "A brand new kind of notification"
        })

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      assert has_element?(lv, ~s([data-section="review"]))
      assert has_element?(lv, row_selector(item))
    end

    test "a single-category inbox renders only that section", %{conn: conn} do
      user = insert_user()
      emit!(user, kind: "chat_mention", title: "only a mention")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      assert has_element?(lv, ~s([data-section="mentions"]))
      refute has_element?(lv, ~s([data-section="review"]))
      refute has_element?(lv, ~s([data-section="meetings"]))
    end

    test "Mentions in different spaces render their space labels (grouped by space)",
         %{conn: conn} do
      user = insert_user()
      emit!(user, kind: "chat_mention", title: "in general", url: "/chat/general")
      emit!(user, kind: "chat_mention", title: "in random", url: "/chat/random")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      html = render(lv)

      assert html =~ "#general"
      assert html =~ "#random"
    end
  end

  # ── meeting_invited: the typed invite row ──────────────────────────────
  #
  # `section_for/1`'s catch-all deliberately routes unknown kinds to :review, so
  # an invite renders perfectly well WITHOUT the explicit clause — filed under
  # "Awaiting your review" beside plan reviews. Every test below therefore
  # asserts BOTH sides (present in Meetings AND absent from Review); an "it
  # rendered somewhere" assertion passes against the catch-all and proves
  # nothing.

  describe "meeting_invited rows" do
    defp invite!(user, overrides \\ []) do
      emit!(
        user,
        Keyword.merge(
          [
            kind: "meeting_invited",
            source_type: "meeting",
            title: "Rowan invited you to Weekly sync",
            url: "/meetings/weekly-sync"
          ],
          overrides
        )
      )
    end

    # The kind badge text on one row, e.g. "Meeting invite". Scoped to the row
    # and read as text (not a substring match) because the humanizing catch-all
    # renders "Meeting invited" — which CONTAINS "Meeting invite", so a `=~`
    # assertion would stay green with the clause deleted.
    defp kind_label_text(lv, %Item{id: id}) do
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-item-id="#{id}"] [data-role="inbox-item-kind"]))
      |> LazyHTML.text()
      |> String.trim()
    end

    test "renders under Meetings and NOT under Awaiting your review", %{conn: conn} do
      user = insert_user()

      # A genuine review row so the review section really renders. Without it
      # the "absent from review" refute would pass trivially (no such section).
      review =
        emit!(user,
          kind: "review_request_pending",
          source_type: "review_request",
          title: "Approve the deploy"
        )

      invite = invite!(user)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      assert has_element?(lv, ~s([data-section="review"]))
      assert has_element?(lv, ~s([data-section="review"] #{row_selector(review)}))

      # Present in Meetings...
      assert has_element?(lv, ~s([data-section="meetings"] #{row_selector(invite)}))
      # ...and NOWHERE in Review. Both halves detonate when
      # `section_for("meeting_invited")` is removed.
      refute has_element?(lv, ~s([data-section="review"] #{row_selector(invite)}))
    end

    test "sits in Meetings alongside a meeting_starting row", %{conn: conn} do
      user = insert_user()

      starting =
        emit!(user,
          kind: "meeting_starting",
          source_type: "meeting",
          title: "Standup starting",
          url: "/meetings/standup"
        )

      invite = invite!(user)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      assert has_element?(lv, ~s([data-section="meetings"] #{row_selector(starting)}))
      assert has_element?(lv, ~s([data-section="meetings"] #{row_selector(invite)}))
      refute has_element?(lv, ~s([data-section="review"]))
    end

    test "renders the label 'Meeting invite' exactly — not the humanized fallback",
         %{conn: conn} do
      user = insert_user()
      invite = invite!(user)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      # Equality, not `=~`: "Meeting invited" (the Phoenix.Naming.humanize
      # catch-all) contains "Meeting invite" as a prefix.
      assert kind_label_text(lv, invite) == "Meeting invite"
      refute kind_label_text(lv, invite) == "Meeting invited"
    end

    test "carries the envelope icon, not the meeting_starting camera or the bell catch-all",
         %{conn: conn} do
      user = insert_user()
      invite = invite!(user)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      icon_classes =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(#{row_selector(invite)} [data-role="inbox-item-kind"] > span))
        |> LazyHTML.attribute("class")
        |> Enum.join(" ")

      assert icon_classes =~ "hero-envelope"
      refute icon_classes =~ "hero-bell"
      refute icon_classes =~ "hero-video-camera"
    end

    test "a LIVE-broadcast invite streams into Meetings, not Review", %{conn: conn} do
      user = insert_user()

      emit!(user,
        kind: "review_request_pending",
        source_type: "review_request",
        title: "Approve the deploy"
      )

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      refute has_element?(lv, ~s([data-section="meetings"]))

      # The PubSub insert path calls the same section_for/1, so the previously
      # hidden Meetings section must appear carrying the row.
      invite = invite!(user, title: "Rowan invited you to Live one")

      assert has_element?(lv, ~s([data-section="meetings"] #{row_selector(invite)}))
      refute has_element?(lv, ~s([data-section="review"] #{row_selector(invite)}))
    end

    test "dismissing an invite removes it from Meetings and does not resurface in Review",
         %{conn: conn} do
      user = insert_user()
      invite = invite!(user)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      lv
      |> element(~s(#{row_selector(invite)} [data-role="inbox-item-dismiss"]))
      |> render_click()

      # A dismiss routes through `item_sections`, which is built from the same
      # section_for/1 — a mis-routed row would delete from the wrong stream and
      # linger on screen.
      refute has_element?(lv, row_selector(invite))
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, invite.id)
      assert render(lv) =~ "empty-minimal"
    end
  end

  # ── Mention space labels (task 019fabe8 stage 4) ───────────────────────
  #
  # `Chat.space_path_segment/1` now emits a UUID for org-scoped and slug-less
  # spaces, so the row's raw segment is no longer human-readable. The label is
  # resolved to the space's display name; the GROUPING key stays the raw
  # segment so `sort_mentions/1` is untouched.

  describe "mention space labels" do
    test "a DM mention renders the peer's name, not the raw uuid", %{conn: conn} do
      user = insert_user()
      peer = insert_user()

      {:ok, dm} = Chat.create_space(%{kind: "dm", is_direct: true, name: nil})
      assert is_nil(dm.slug)

      add_user_participant(dm.id, user, "Inbox Viewer")
      add_user_participant(dm.id, peer, "Marta Vasquez")

      url = "/chat/#{Chat.space_path_segment(dm)}?message=#{Ecto.UUID.generate()}"
      assert url =~ dm.id

      emit!(user, kind: "chat_mention", title: "@Mention from Marta", url: url)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      label = mention_label(lv)

      assert label == "Marta Vasquez"

      # The pre-fix rendering, asserted as an explicit negative.
      refute label =~ dm.id
      refute String.starts_with?(label, "#")
    end

    test "an org-scoped channel mention renders #<name>, not #<uuid>", %{conn: conn} do
      user = insert_user()

      {:ok, channel} =
        Chat.create_space(%{
          kind: "channel",
          name: "Product Launch",
          slug: "product-launch-#{System.unique_integer([:positive])}",
          org_id: fabrikam_org_id()
        })

      url = "/chat/#{Chat.space_path_segment(channel)}?message=#{Ecto.UUID.generate()}"
      assert url =~ channel.id

      emit!(user, kind: "chat_mention", title: "@you", url: url)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      assert mention_label(lv) == "#Product Launch"
    end

    test "an unresolvable segment still falls back to the raw segment", %{conn: conn} do
      user = insert_user()

      # A stale row pointing at a deleted space, or a legacy row emitted before
      # this shipped. It must still render SOMETHING and still group.
      emit!(user, kind: "chat_mention", title: "@you", url: "/chat/long-gone?message=x")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      assert mention_label(lv) == "#long-gone"
    end

    test "a mention that arrives LIVE resolves its label too", %{conn: conn} do
      user = insert_user()
      peer = insert_user()

      # Mount with an empty inbox, so the initial label map cannot possibly
      # contain this space — the live-insert path has to resolve it.
      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert mention_label(lv) == nil

      {:ok, dm} = Chat.create_space(%{kind: "dm", is_direct: true, name: nil})
      add_user_participant(dm.id, user, "Inbox Viewer")
      add_user_participant(dm.id, peer, "Desmond Cole")

      emit!(user,
        kind: "chat_mention",
        title: "@Mention from Desmond",
        url: "/chat/#{Chat.space_path_segment(dm)}?message=#{Ecto.UUID.generate()}"
      )

      assert mention_label(lv) == "Desmond Cole"
    end

    test "the grouping key is unchanged — same space rows still sit together",
         %{conn: conn} do
      user = insert_user()
      peer = insert_user()

      {:ok, dm} = Chat.create_space(%{kind: "dm", is_direct: true, name: nil})
      add_user_participant(dm.id, user, "Inbox Viewer")
      add_user_participant(dm.id, peer, "Marta Vasquez")

      segment = Chat.space_path_segment(dm)

      for n <- 1..2 do
        emit!(user,
          kind: "chat_mention",
          title: "dm mention #{n}",
          url: "/chat/#{segment}?message=#{Ecto.UUID.generate()}"
        )
      end

      emit!(user, kind: "chat_mention", title: "channel mention", url: "/chat/zzz-other")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      # Both DM rows adjacent, resolved to the peer name; the other space's row
      # is not interleaved between them.
      assert mention_labels(lv) == ["Marta Vasquez", "Marta Vasquez", "#zzz-other"]
    end
  end

  # ── Empty state ────────────────────────────────────────────────────────

  describe "empty inbox" do
    test "renders the EmptyState :minimal copy and no section headers / rows",
         %{conn: conn} do
      user = insert_user()

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      html = render(lv)

      assert html =~ "empty-minimal"
      assert html =~ "You&#39;re all caught up" or html =~ "You're all caught up"
      refute has_element?(lv, ~s([data-role="inbox-section"]))
      refute has_element?(lv, ~s([data-role="inbox-item"]))
    end

    test "a fully-dismissed inbox shows the empty state", %{conn: conn} do
      user = insert_user()
      item = emit!(user, kind: "chat_mention", title: "will be dismissed")
      {:ok, _} = Inbox.mark_dismissed(item.id, user.id)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      refute has_element?(lv, row_selector(item))
      assert render(lv) =~ "empty-minimal"
    end
  end

  # ── Live insert ────────────────────────────────────────────────────────

  describe "live insert via PubSub" do
    test "a broadcast streams a new row at the top of its section", %{conn: conn} do
      user = insert_user()

      emit!(user,
        kind: "review_request_pending",
        source_type: "review_request",
        title: "existing review"
      )

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      fresh =
        emit!(user,
          kind: "review_request_pending",
          source_type: "review_request",
          title: "brand new review"
        )

      assert has_element?(lv, row_selector(fresh))
      assert render(lv) =~ "brand new review"
    end

    test "a broadcast into a previously-hidden section reveals the section", %{conn: conn} do
      user = insert_user()
      emit!(user, kind: "chat_mention", title: "a mention")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      refute has_element?(lv, ~s([data-section="meetings"]))

      meeting =
        emit!(user,
          kind: "meeting_starting",
          source_type: "meeting",
          title: "Standup",
          url: "/meetings/standup"
        )

      assert has_element?(lv, ~s([data-section="meetings"]))
      assert has_element?(lv, row_selector(meeting))
    end

    test "a broadcast for another user's item is ignored", %{conn: conn} do
      user = insert_user()
      other = insert_user()

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      # emit for `other` broadcasts on other's topic, which this LV isn't subscribed to.
      stranger = emit!(other, kind: "chat_mention", title: "not for you")

      refute has_element?(lv, row_selector(stranger))
    end
  end

  # ── Dismiss ────────────────────────────────────────────────────────────

  describe "dismiss" do
    test "removes the row, sets dismissed_at, and it does not reappear", %{conn: conn} do
      user = insert_user()
      keep = emit!(user, kind: "chat_mention", title: "keep me")
      drop = emit!(user, kind: "chat_mention", title: "dismiss me")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert has_element?(lv, row_selector(drop))

      lv
      |> element(~s(#{row_selector(drop)} [data-role="inbox-item-dismiss"]))
      |> render_click()

      refute has_element?(lv, row_selector(drop))
      assert has_element?(lv, row_selector(keep))

      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, drop.id)

      # Re-mount: the dismissed row must not come back.
      {:ok, lv2, _html} = live(auth(conn, user), "/inbox")
      refute has_element?(lv2, row_selector(drop))
      assert has_element?(lv2, row_selector(keep))
    end

    test "dismissing the last row in a section hides the section and shows empty state",
         %{conn: conn} do
      user = insert_user()

      only =
        emit!(user,
          kind: "meeting_starting",
          source_type: "meeting",
          title: "lone meeting",
          url: "/meetings/x"
        )

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert has_element?(lv, ~s([data-section="meetings"]))

      lv
      |> element(~s(#{row_selector(only)} [data-role="inbox-item-dismiss"]))
      |> render_click()

      refute has_element?(lv, ~s([data-section="meetings"]))
      assert render(lv) =~ "empty-minimal"
    end
  end

  # ── Badge / list unification (one unread source of truth) ──────────────

  describe "badge equals streamed rows (unified unread scope)" do
    # The desktop icon-rail badge (rendered by ShellLive into the shell layout)
    # and the /inbox row list must show the SAME number at all times. They used
    # to drift because the badge filtered read/dismissed in SQL while the list
    # applied the read filter in Elixir, and silent mutations (mark_read,
    # dismiss_by_source) never told the badge to recompute. Both now build on
    # `Inbox.unread_scope/1`; these are the three events that drifted.

    defp badge_number(view) do
      text =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="inbox-badge"]))
        |> LazyHTML.text()
        |> String.trim()

      case Integer.parse(text) do
        {n, _} -> n
        # No badge element renders at 0 (it's hidden) → count as 0.
        :error -> 0
      end
    end

    defp streamed_row_count(view) do
      view
      |> render()
      |> String.split(~s(data-role="inbox-item"))
      |> length()
      |> Kernel.-(1)
    end

    test "badge == row count after emit, after mark_read, and after dismiss_by_source",
         %{conn: conn} do
      user = insert_user()
      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      # Empty: both zero.
      assert badge_number(lv) == 0
      assert streamed_row_count(lv) == 0

      # After emit: the added rows show and the badge matches.
      a = emit!(user, kind: "chat_mention", title: "mention a", url: "/chat/general")

      b =
        emit!(user,
          kind: "meeting_starting",
          source_type: "meeting",
          title: "meeting b",
          url: "/meetings/standup"
        )

      assert streamed_row_count(lv) == 2
      assert badge_number(lv) == streamed_row_count(lv)

      # After mark_read (a silent read that broadcasts :inbox_changed): the read
      # row drops from BOTH the list and the badge.
      {:ok, _} = Inbox.mark_read(a.id, user.id)
      assert streamed_row_count(lv) == 1
      assert badge_number(lv) == streamed_row_count(lv)

      # After dismiss_by_source (the rollup dismissal path, broadcasts
      # :inbox_changed): both fall to zero together.
      {:ok, _} = Inbox.dismiss_by_source(user.id, "meeting", b.source_id)
      assert streamed_row_count(lv) == 0
      assert badge_number(lv) == streamed_row_count(lv)
    end
  end

  # ── Open (mark read + navigate) ────────────────────────────────────────

  describe "open" do
    test "marks read_at, navigates to item.url, and the read item is gone on re-mount",
         %{conn: conn} do
      user = insert_user()
      item = emit!(user, kind: "chat_mention", title: "open me", url: "/chat/general")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      assert {:error, {:live_redirect, %{to: "/chat/general"}}} =
               lv
               |> element(~s(#{row_selector(item)} [data-role="inbox-item-open"]))
               |> render_click()

      assert %Item{read_at: %DateTime{}} = Repo.get!(Item, item.id)

      # Read items drop off the inbox on the next load.
      {:ok, lv2, _html} = live(auth(conn, user), "/inbox")
      refute has_element?(lv2, row_selector(item))
    end
  end

  # ── Notification-permission row (task 019ffb7b stage 4) ────────────────
  #
  # The call site for `PlatformWeb.Components.NotificationState`. The
  # component's own DOM contract lives in
  # `test/platform_web/components/notification_state_test.exs`; what these
  # assert is the wiring — that `/inbox` reads ShellLive's `:push_permission`
  # assign, and that the row flips in when the `PushSubscribe` hook reports,
  # rather than only rendering under a hand-made assign.
  describe "notification-permission row" do
    setup %{conn: conn} do
      user = insert_user()
      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      %{lv: lv, user: user}
    end

    test "renders nothing on mount — the client has not reported yet", %{lv: lv} do
      refute has_element?(lv, ~s([data-role="notification-state"]))

      # Positive control: the surface itself rendered.
      assert has_element?(lv, ~s([data-role="inbox-surface"]))
    end

    test "prompt flips the offer row in, with its action", %{lv: lv} do
      render_hook(lv, "push_permission_state", %{"state" => "prompt"})

      assert has_element?(lv, ~s([data-role="notification-state"][data-permission="prompt"]))
      assert has_element?(lv, ~s([data-role="notification-enable"]))
    end

    test "the offer's button reaches the shell handler", %{lv: lv} do
      render_hook(lv, "push_permission_state", %{"state" => "prompt"})

      lv |> element(~s([data-role="notification-enable"])) |> render_click()

      assert_push_event(lv, "request_push_permission", %{})
    end

    test "denied flips in a row with no action at all", %{lv: lv} do
      render_hook(lv, "push_permission_state", %{"state" => "denied"})

      assert has_element?(lv, ~s([data-role="notification-state"][data-permission="denied"]))
      refute has_element?(lv, ~s([data-role="notification-enable"]))
    end

    test "the auto-denied flag reaches the row beside the permission", %{lv: lv} do
      # The wiring the component tests cannot see: the hook sends the flag in
      # the SAME payload as the state, the shell keeps it in its own assign,
      # and `/inbox` hands both to the row. The permission stays "denied";
      # the flag never becomes a sixth value of it.
      render_hook(lv, "push_permission_state", %{"state" => "denied", "auto_denied" => true})

      assert has_element?(
               lv,
               ~s([data-role="notification-state"][data-permission="denied"][data-auto-denied="true"])
             )

      assert render(lv) =~ "Your browser turned notifications down without asking you."

      # And an ordinary denial afterwards clears it rather than sticking.
      render_hook(lv, "push_permission_state", %{"state" => "denied"})

      assert has_element?(lv, ~s([data-role="notification-state"][data-auto-denied="false"]))
      assert render(lv) =~ "Your browser is blocking notifications from Suite."
    end

    test "granted and unsupported leave the page unchanged", %{lv: lv} do
      for state <- ["granted", "unsupported"] do
        render_hook(lv, "push_permission_state", %{"state" => state})

        refute has_element?(lv, ~s([data-role="notification-state"])),
               "expected no notification row for push_permission=#{state}"
      end
    end

    # Task 019ffe52 stage 3. The wiring the component tests cannot see: the
    # shell's `:push_registration_failed` assign reaches `/inbox` and the row
    # reads it, exactly as `:push_auto_denied` does.
    #
    # Driven through the real events rather than a hand-made assign. The user
    # from `insert_user/0` is in no space, so `push_subscribed` genuinely
    # cannot file the device and the shell sets the flag itself; a test that
    # assigned the flag directly would pass even if nothing ever set it.
    test "a registration with nowhere to file shows the no-conversations copy", %{lv: lv} do
      render_hook(lv, "push_permission_state", %{"state" => "granted"})

      # Control: a plain grant still adds nothing to the page.
      refute has_element?(lv, ~s([data-role="notification-state"]))

      render_hook(lv, "push_subscribed", %{
        "endpoint" => "https://push.example.com/inbox-wiring",
        "keys" => %{"p256dh" => "p256dh-key", "auth" => "auth-key"}
      })

      assert has_element?(
               lv,
               ~s([data-role="notification-state"][data-permission="granted"][data-registration-failed="no_participant"])
             )

      html = render(lv)

      assert html =~ "Notifications are on, but you are not in any conversations yet."
      assert html =~ "Start a conversation in Chat and they will switch on."

      # Nothing to press: nobody can act on this from here.
      refute has_element?(lv, ~s([data-role="notification-enable"]))
      refute has_element?(lv, ~s([data-role="notification-state"] button))
    end

    # The other route to the same assign, and the reason it stopped being a
    # boolean: the browser refused the subscribe, so a reload CAN change the
    # outcome and the copy says so. Same wiring assertion, different words.
    test "a client-side subscribe failure shows the reload copy", %{lv: lv} do
      render_hook(lv, "push_permission_state", %{"state" => "granted"})
      refute has_element?(lv, ~s([data-role="notification-state"]))

      render_hook(lv, "push_subscribe_failed", %{
        "name" => "AbortError",
        "message" => "push service error"
      })

      assert has_element?(
               lv,
               ~s([data-role="notification-state"][data-permission="granted"][data-registration-failed="subscribe_failed"])
             )

      html = render(lv)

      assert html =~
               "Your browser allowed notifications, but this device could not be registered."

      assert html =~ "Reload the page to try again."

      # It must NOT borrow the other reason's words, which is the whole point
      # of carrying a reason instead of a flag.
      refute html =~ "Notifications are on, but you are not in any conversations yet."

      # "Reload the page" is instruction text, not a control.
      refute has_element?(lv, ~s([data-role="notification-state"] button))
    end
  end
end
