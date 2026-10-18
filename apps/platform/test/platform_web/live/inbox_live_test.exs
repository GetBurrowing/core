defmodule PlatformWeb.InboxLiveTest do
  @moduledoc """
  Tests for the InboxLive surface (M6 of the Inbox System v1 stack).

  Covers the contract the plan + e2e_behavior validations call out:

    * each section renders its category and auto-hides when empty;
    * a broadcast `{:inbox_item_added, item}` streams a new row in at the top
      (and reveals a previously-hidden section);
    * a dismiss event removes the row and it does not reappear on re-render;
    * a click navigates to `item.url` through `Inbox.open_item/2`: a
      non-action row is gone on the next mount, an action row stays listed and
      leaves the badge (task `01a11703`);
    * an empty inbox renders the `EmptyState` `:minimal` copy;
    * Mentions are grouped by space (per-row space label).
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures, only: [acme_org_id: 0]

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
          body: "Alex mentioned you",
          url: "/chat/general"
        },
        Map.new(overrides)
      )

    {:ok, item} = Inbox.emit(attrs)
    item
  end

  defp row_selector(%Item{id: id}), do: ~s([data-item-id="#{id}"])

  # Toggle one row's select checkbox.
  defp tick(lv, %Item{} = item) do
    lv
    |> element(~s(#{row_selector(item)} [data-role="inbox-item-select"]))
    |> render_click()
  end

  defp clear_selected(lv) do
    lv |> element(~s([data-role="clear-selected"])) |> render_click()
  end

  defp clear_all(lv) do
    lv |> element(~s([data-role="clear-all"])) |> render_click()
  end

  defp undo(lv) do
    lv |> element(~s([data-role="toast-undo"])) |> render_click()
  end

  # The nonce the LiveView minted for the toast currently on screen. Read off
  # the socket because it is deliberately NOT rendered — the guard is server
  # state, and a test that asserted on a DOM copy of it would be asserting on
  # markup added for the test rather than on the mechanism.
  defp toast_nonce(lv), do: :sys.get_state(lv.pid).socket.assigns.toast.nonce

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
            title: "Alex invited you to Weekly sync",
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
      invite = invite!(user, title: "Alex invited you to Live one")

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
          org_id: acme_org_id()
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
      assert html =~ "Nothing waiting on you."

      assert html =~
               "Plans to review, mentions and meetings about to start will show up here."

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

  # ── Bulk selection (task 01a00108 stage 2) ─────────────────────────────
  #
  # Sam's report was "I have to click each and every message to clear it
  # out". Clicking a row IS today's clear mechanism (open → mark_read → the row
  # leaves `unread_scope/1`), so the fix is not to the badge but to the batch:
  # tick rows, clear them together.

  describe "bulk selection" do
    test "ticking a row reveals the bar, and the count tracks the selection",
         %{conn: conn} do
      user = insert_user()
      a = emit!(user, kind: "chat_mention", title: "first")
      b = emit!(user, kind: "chat_mention", title: "second")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      # Nothing ticked: no bar at all.
      refute has_element?(lv, ~s([data-role="selection-bar"]))

      tick(lv, a)
      assert has_element?(lv, ~s([data-role="selection-bar"]))
      assert render(lv) =~ "1 selected"

      tick(lv, b)
      assert render(lv) =~ "2 selected"
      refute render(lv) =~ "1 selected"
    end

    test "unticking back to zero unmounts the bar", %{conn: conn} do
      user = insert_user()
      only = emit!(user, kind: "chat_mention", title: "lone row")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      tick(lv, only)
      assert has_element?(lv, ~s([data-role="selection-bar"]))

      tick(lv, only)
      refute has_element?(lv, ~s([data-role="selection-bar"]))

      # Unticking is not dismissing.
      assert %Item{dismissed_at: nil} = Repo.get!(Item, only.id)
    end

    test "Clear selected dismisses exactly the ticked rows and leaves the rest",
         %{conn: conn} do
      user = insert_user()
      drop_a = emit!(user, kind: "chat_mention", title: "clear me")
      drop_b = emit!(user, kind: "chat_mention", title: "clear me too")
      keep = emit!(user, kind: "chat_mention", title: "leave me alone")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      tick(lv, drop_a)
      tick(lv, drop_b)
      assert render(lv) =~ "2 selected"

      clear_selected(lv)

      refute has_element?(lv, row_selector(drop_a))
      refute has_element?(lv, row_selector(drop_b))
      assert has_element?(lv, row_selector(keep))

      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, drop_a.id)
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, drop_b.id)
      assert %Item{dismissed_at: nil} = Repo.get!(Item, keep.id)

      # The sweep also empties the selection, so the bar goes with it.
      refute has_element?(lv, ~s([data-role="selection-bar"]))

      # Re-mount: the cleared rows must not come back.
      {:ok, lv2, _html} = live(auth(conn, user), "/inbox")
      refute has_element?(lv2, row_selector(drop_a))
      assert has_element?(lv2, row_selector(keep))
    end

    test "clearing every row in a section hides the section header too", %{conn: conn} do
      user = insert_user()

      one =
        emit!(user,
          kind: "meeting_starting",
          source_type: "meeting",
          title: "standup",
          url: "/meetings/a"
        )

      two =
        emit!(user,
          kind: "meeting_starting",
          source_type: "meeting",
          title: "retro",
          url: "/meetings/b"
        )

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert has_element?(lv, ~s([data-section="meetings"]))

      tick(lv, one)
      tick(lv, two)
      clear_selected(lv)

      # Section visibility is driven by the count assign, not the stream — a
      # stream_delete that forgot to decrement would leave this header behind.
      refute has_element?(lv, ~s([data-section="meetings"]))
      assert render(lv) =~ "empty-minimal"
    end

    test "Cancel drops the selection without dismissing anything", %{conn: conn} do
      user = insert_user()
      item = emit!(user, kind: "chat_mention", title: "spared")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      tick(lv, item)
      lv |> element(~s([data-role="cancel-selection"])) |> render_click()

      refute has_element?(lv, ~s([data-role="selection-bar"]))
      assert has_element?(lv, row_selector(item))
      assert %Item{dismissed_at: nil} = Repo.get!(Item, item.id)
    end

    test "a selection survives an unrelated live insert", %{conn: conn} do
      user = insert_user()
      held = emit!(user, kind: "chat_mention", title: "held")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      tick(lv, held)
      assert render(lv) =~ "1 selected"

      # A brand-new row arrives while the bar is open. `:inbox_item_added`
      # patches one row in and touches no other, so the selection is untouched.
      fresh = emit!(user, kind: "chat_mention", title: "just landed")

      assert has_element?(lv, row_selector(fresh))
      assert render(lv) =~ "1 selected"
      assert has_element?(lv, ~s([data-role="selection-bar"]))
    end

    # ANTI-VACUITY TARGET. Deleting the `prune_selection/1` call at the end of
    # `init_sections/2` must turn this red.
    #
    # The vanish mechanism changed with task `01a00108` stage 4 and the probe
    # had to be re-rigged. It used to be `mark_read` on another tab: that left
    # `dismissed_at` nil, so a final `dismissed_at: nil` assertion proved the
    # sweep had not reached for an off-screen row. Reading no longer removes
    # anything, so the row now vanishes by being DISMISSED elsewhere — which
    # means `dismissed_at` is already set and its mere presence proves nothing.
    #
    # The probe is preserved by pinning the TIMESTAMP instead: if the sweep
    # wrongly reached the pruned row it would rewrite `dismissed_at` to its own
    # `now()`. Asserting the value is byte-identical to the earlier dismissal
    # keeps this a behavioural check and not a count check.
    test "a stale selection drops rows that vanished, and the sweep never touches them",
         %{conn: conn} do
      user = insert_user()
      vanishes = emit!(user, kind: "chat_mention", title: "cleared on another tab")
      stays = emit!(user, kind: "chat_mention", title: "still here")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      tick(lv, vanishes)
      tick(lv, stays)
      assert render(lv) =~ "2 selected"

      # Another tab clears the first row.
      {:ok, _} = Inbox.mark_dismissed(vanishes.id, user.id)
      dismissed_at = Repo.get!(Item, vanishes.id).dismissed_at
      assert %DateTime{} = dismissed_at

      send(lv.pid, {:inbox_changed, user.id})

      refute has_element?(lv, row_selector(vanishes))
      assert render(lv) =~ "1 selected"

      clear_selected(lv)

      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, stays.id)

      # Untouched: the sweep did not re-dismiss the row it could no longer see.
      assert Repo.get!(Item, vanishes.id).dismissed_at == dismissed_at
    end
  end

  # ── Clear all, and the undo behind it (task 01a00108 stage 3) ──────────

  describe "clear all" do
    test "clears every unread row, not just the ticked ones, and names the count",
         %{conn: conn} do
      user = insert_user()
      review = emit!(user, kind: "task_plan_review", source_type: "task", title: "plan")
      mention = emit!(user, kind: "chat_mention", title: "mentioned")

      meeting =
        emit!(user,
          kind: "meeting_starting",
          source_type: "meeting",
          title: "standup",
          url: "/meetings/a"
        )

      {:ok, lv, html} = live(auth(conn, user), "/inbox")

      # The button names what it will clear, before it is pressed.
      assert html =~ "Clear all (3)"

      # Tick exactly one row: "Clear all" must ignore the selection entirely.
      tick(lv, mention)
      assert render(lv) =~ "1 selected"

      clear_all(lv)

      for item <- [review, mention, meeting] do
        assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, item.id)
        refute has_element?(lv, row_selector(item))
      end

      # Every section is gone, so is the bar, so is the button that did it.
      assert render(lv) =~ "empty-minimal"
      refute has_element?(lv, ~s([data-role="selection-bar"]))
      refute has_element?(lv, ~s([data-role="clear-all"]))

      # And they do not come back on a fresh mount.
      {:ok, lv2, _html} = live(auth(conn, user), "/inbox")
      refute has_element?(lv2, row_selector(review))
    end

    test "the sweep reaches a row that is unread but was never rendered as selectable",
         %{conn: conn} do
      # Guards the "acts on every unread row, not on what is drawn" contract from
      # the other side: a row that arrives AFTER the page was rendered is still
      # swept, because the scope is evaluated by Postgres inside the write.
      user = insert_user()
      old = emit!(user, kind: "chat_mention", title: "was here at load")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      late = emit!(user, kind: "chat_mention", title: "landed after load")

      clear_all(lv)

      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, old.id)
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, late.id)
    end

    test "the toast reports the count and offers an Undo", %{conn: conn} do
      user = insert_user()
      emit!(user, kind: "chat_mention", title: "one")
      emit!(user, kind: "chat_mention", title: "two")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      refute has_element?(lv, ~s([data-role="inbox-toast"]))

      clear_all(lv)

      assert has_element?(lv, ~s([data-role="inbox-toast"]))
      assert has_element?(lv, ~s([data-role="toast-undo"]))
      assert render(lv) =~ "2 notifications cleared"

      # Act-then-confirm: the toast is the confirmation, so there is no
      # pre-action modal in front of the button.
      refute has_element?(lv, ~s([data-role="clear-all-confirm"]))
    end

    test "a one-row sweep says notification, not notifications", %{conn: conn} do
      user = insert_user()
      emit!(user, kind: "chat_mention", title: "lonely")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      clear_all(lv)

      assert render(lv) =~ "1 notification cleared"
      refute render(lv) =~ "1 notifications cleared"
    end

    test "undo restores exactly the swept rows and never a row dismissed earlier",
         %{conn: conn} do
      user = insert_user()
      earlier = emit!(user, kind: "chat_mention", title: "I dealt with this yesterday")
      a = emit!(user, kind: "chat_mention", title: "swept a")
      b = emit!(user, kind: "task_plan_review", source_type: "task", title: "swept b")

      # The user dismissed this one deliberately, BEFORE the clear-all. Undo must
      # not resurrect it — `dismiss_all_unread/1`'s scope excludes it, so it is
      # absent from the id list the toast carries.
      {:ok, _} = Inbox.mark_dismissed(earlier.id, user.id)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      clear_all(lv)

      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, a.id)
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, b.id)

      undo(lv)

      assert %Item{dismissed_at: nil} = Repo.get!(Item, a.id)
      assert %Item{dismissed_at: nil} = Repo.get!(Item, b.id)
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, earlier.id)

      # The rows are back on the surface and the toast has retired with its undo.
      assert has_element?(lv, row_selector(a))
      assert has_element?(lv, row_selector(b))
      refute has_element?(lv, row_selector(earlier))
      refute has_element?(lv, ~s([data-role="inbox-toast"]))

      # Restored means restored: a fresh mount agrees.
      {:ok, lv2, _html} = live(auth(conn, user), "/inbox")
      assert has_element?(lv2, row_selector(a))
      assert has_element?(lv2, row_selector(b))
    end

    test "undo re-broadcasts, so the rail/Dock/title badge repaints", %{conn: conn} do
      user = insert_user()
      emit!(user, kind: "chat_mention", title: "counts toward the badge")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      :ok = Inbox.subscribe(user.id)

      clear_all(lv)
      assert_receive {:inbox_changed, changed_user}, 1_000
      assert changed_user == user.id

      # The one that matters: an undo that skipped this leaves the Dock icon and
      # the document-title prefix showing a count the DB no longer agrees with.
      undo(lv)
      assert_receive {:inbox_changed, undone_user}, 1_000
      assert undone_user == user.id

      assert Inbox.unread_count(user.id) == 1
    end

    # ANTI-VACUITY TARGET. Removing the `%{nonce: ^nonce}` match from the
    # `{:clear_toast, nonce}` handler — so ANY timer clears ANY toast — must turn
    # this red.
    #
    # The scenario is two clears inside `@toast_ttl_ms`: the first sweep's timer
    # is still in flight when the second toast is on screen, and unguarded it
    # would fire into it and cut the undo window short with no trace. The second
    # half of the test sends the CURRENT nonce and asserts the toast does go, so
    # the first assertion cannot pass merely because `:clear_toast` never works.
    test "an older sweep's timer cannot clear a newer sweep's toast", %{conn: conn} do
      user = insert_user()
      emit!(user, kind: "chat_mention", title: "first batch")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      clear_all(lv)
      first_nonce = toast_nonce(lv)

      # A second batch lands and is cleared well inside the TTL, so the first
      # sweep's `Process.send_after/3` is still pending.
      emit!(user, kind: "chat_mention", title: "second batch")
      clear_all(lv)
      second_nonce = toast_nonce(lv)

      refute first_nonce == second_nonce
      assert render(lv) =~ "1 notification cleared"

      # The stale timer fires.
      send(lv.pid, {:clear_toast, first_nonce})

      assert has_element?(lv, ~s([data-role="inbox-toast"])),
             "an older sweep's timer cleared the current toast — the undo window " <>
               "was truncated silently"

      assert has_element?(lv, ~s([data-role="toast-undo"]))

      # ...and the CURRENT timer still retires it, so the guard is a guard and
      # not a permanently-stuck toast.
      send(lv.pid, {:clear_toast, second_nonce})
      refute has_element?(lv, ~s([data-role="inbox-toast"]))
    end

    test "undo after the toast expires is simply unavailable, and nothing is resurrected",
         %{conn: conn} do
      user = insert_user()
      item = emit!(user, kind: "chat_mention", title: "gone for good")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      clear_all(lv)
      send(lv.pid, {:clear_toast, toast_nonce(lv)})

      refute has_element?(lv, ~s([data-role="inbox-toast"]))
      refute has_element?(lv, ~s([data-role="toast-undo"]))
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, item.id)
    end

    test "an empty inbox offers no Clear all", %{conn: conn} do
      user = insert_user()

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      refute has_element?(lv, ~s([data-role="clear-all"]))
    end

    test "Clear selected raises the same toast, and its undo brings those rows back",
         %{conn: conn} do
      # Stage 2 stashed the ids `dismiss_many/2` reported changing with the note
      # that stage 3 turns them into undo. This is that.
      user = insert_user()
      swept = emit!(user, kind: "chat_mention", title: "ticked")
      kept = emit!(user, kind: "chat_mention", title: "untouched")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      tick(lv, swept)
      clear_selected(lv)

      assert render(lv) =~ "1 notification cleared"
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, swept.id)

      undo(lv)

      assert %Item{dismissed_at: nil} = Repo.get!(Item, swept.id)
      assert %Item{dismissed_at: nil} = Repo.get!(Item, kept.id)
      assert has_element?(lv, row_selector(swept))
    end
  end

  # ── Badge / list unification (one unread source of truth) ──────────────

  describe "badge equals streamed UNREAD rows (badge scope composed on the list scope)" do
    # The desktop icon-rail badge (rendered by ShellLive into the shell layout)
    # and the /inbox row list used to drift because the badge filtered
    # read/dismissed in SQL while the list applied the read filter in Elixir,
    # and silent mutations (mark_read, dismiss_by_source) never told the badge
    # to recompute. Both now build on `Inbox.unread_scope/1`.
    #
    # Since task `01a11703` the badge counts `Inbox.badge_scope/1` — the
    # list's rows with `read_at` nil — so the invariant is "badge == listed rows
    # nobody has opened", and it must hold live after each of these events.

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

    test "badge == unread row count after emit, after mark_read, and after dismiss_by_source",
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

      # After mark_read: the read row stays on the list (dismissal is the only
      # list clear) and leaves the badge (task `01a11703`: the badge counts
      # unopened rows). The badge moving here is also the proof that
      # `mark_read/2`'s broadcast reaches the shell.
      {:ok, _} = Inbox.mark_read(a.id, user.id)
      assert streamed_row_count(lv) == 2
      assert badge_number(lv) == 1

      # Dismissing the row that was read takes it off the list; the badge,
      # which no longer counted it, does not move.
      {:ok, _} = Inbox.mark_dismissed(a.id, user.id)
      assert streamed_row_count(lv) == 1
      assert badge_number(lv) == streamed_row_count(lv)

      # After dismiss_by_source (the rollup dismissal path, broadcasts
      # :inbox_changed): both fall to zero together.
      {:ok, _} = Inbox.dismiss_by_source(user.id, "meeting", b.source_id)
      assert streamed_row_count(lv) == 0
      assert badge_number(lv) == streamed_row_count(lv)
    end
  end

  # ── Open (acknowledge on open + navigate) ──────────────────────────────
  #
  # REWRITTEN by task `01a11703` stage 1. The test here used to pin #811's rule
  # that opening only marks read and the row stays listed. Opening now goes
  # through `Inbox.open_item/2`: every kind outside `Inbox.action_kinds/0` is
  # dismissed in the same write that marks it read; an action kind is only
  # marked read, stays listed, and leaves the badge. Its own resolution path
  # (plan approve/reject, review resolution) still dismisses it.

  describe "open" do
    defp open_row(lv, %Item{} = item) do
      lv
      |> element(~s(#{row_selector(item)} [data-role="inbox-item-open"]))
      |> render_click()
    end

    # A task whose sponsor is stamped by a direct update, so the
    # `task_sponsor_assigned` producer in `Tasks.create_task/1` never adds a
    # second row to the sponsor's badge. Mirrors
    # `review_request_inbox_test.exs`'s `setup_task/2`.
    defp sponsored_task!(sponsor) do
      {:ok, project} =
        Platform.Tasks.create_project(%{
          name: "Open ack #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/open-ack"
        })

      {:ok, task} = Platform.Tasks.create_task(%{project_id: project.id, title: "Sponsored"})

      task
      |> Ecto.Changeset.change(sponsor_user_id: sponsor.id)
      |> Repo.update!()
    end

    # Test A. M1 (reverting the handler to `Inbox.mark_read/2`) turns the
    # `dismissed_at` and row-absent assertions red. The badge assertion does NOT
    # go red under M1, because `mark_read/2` also sets `read_at`.
    test "a non-action row (meeting_invited) is dismissed on open, with read_at == dismissed_at",
         %{conn: conn} do
      user = insert_user()

      item =
        emit!(user,
          kind: "meeting_invited",
          source_type: "meeting",
          title: "Design sync",
          url: "/meetings"
        )

      assert Inbox.reachable_unread_count(user.id) == 1

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      assert {:error, {:live_redirect, %{to: "/meetings"}}} = open_row(lv, item)

      assert %Item{dismissed_at: %DateTime{} = dismissed_at, read_at: %DateTime{} = read_at} =
               Repo.get!(Item, item.id)

      assert dismissed_at == read_at
      assert Inbox.reachable_unread_count(user.id) == 0

      {:ok, lv2, _html} = live(auth(conn, user), "/inbox")
      refute has_element?(lv2, row_selector(item))
      # Positive control: the surface rendered.
      assert has_element?(lv2, ~s([data-role="inbox-surface"]))
    end

    # Test B. M2 (open_item dismisses every kind) turns `dismissed_at == nil`
    # red. M3 (badge_scope without `is_nil(read_at)`) turns the `0` badge red.
    test "an action row (task_plan_review) is marked read, stays listed, leaves the badge, " <>
           "and is dismissed when the plan is approved",
         %{conn: conn} do
      sponsor = insert_user()
      task = sponsored_task!(sponsor)

      plan =
        %Platform.Tasks.Plan{}
        |> Platform.Tasks.Plan.changeset(%{
          task_id: task.id,
          version: 1,
          status: "pending_review"
        })
        |> Repo.insert!()

      item =
        emit!(sponsor,
          kind: "task_plan_review",
          source_type: "task",
          source_id: task.id,
          title: "Plan ready for review: Sponsored",
          url: "/tasks/#{task.id}"
        )

      assert Inbox.reachable_unread_count(sponsor.id) == 1

      {:ok, lv, _html} = live(auth(conn, sponsor), "/inbox")
      assert {:error, {:live_redirect, %{to: to}}} = open_row(lv, item)
      assert to == "/tasks/#{task.id}"

      assert %Item{dismissed_at: nil, read_at: %DateTime{}} = Repo.get!(Item, item.id)
      assert Inbox.reachable_unread_count(sponsor.id) == 0

      {:ok, lv2, _html} = live(auth(conn, sponsor), "/inbox")
      assert has_element?(lv2, row_selector(item))

      # The resolution path still clears it.
      assert {:ok, _} = Platform.Tasks.approve_plan(plan, sponsor.id)
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, item.id)
    end

    # Test C.
    test "an action row (review_request_pending) is marked read, stays listed, leaves the " <>
           "badge, and is dismissed when the review resolves",
         %{conn: conn} do
      sponsor = insert_user()
      task = sponsored_task!(sponsor)

      {:ok, plan} = Platform.Tasks.create_plan(%{task_id: task.id})

      {:ok, stage} =
        Platform.Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Stage 1"})

      {:ok, _} = Platform.Tasks.PlanEngine.start_stage(stage.id)

      {:ok, validation} =
        Platform.Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      {:ok, request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: validation.id,
          task_id: task.id,
          submitted_by: "some-agent",
          items: [%{label: "Desktop"}]
        })

      [item] =
        Repo.all(
          from(i in Item, where: i.user_id == ^sponsor.id and i.kind == "review_request_pending")
        )

      assert Inbox.reachable_unread_count(sponsor.id) == 1

      {:ok, lv, _html} = live(auth(conn, sponsor), "/inbox")
      assert {:error, {:live_redirect, _}} = open_row(lv, item)

      assert %Item{dismissed_at: nil, read_at: %DateTime{}} = Repo.get!(Item, item.id)
      assert Inbox.reachable_unread_count(sponsor.id) == 0

      {:ok, lv2, _html} = live(auth(conn, sponsor), "/inbox")
      assert has_element?(lv2, row_selector(item))

      for it <- request.items do
        {:ok, _} = Platform.Tasks.ReviewRequests.approve_item(it.id, sponsor.id)
      end

      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, item.id)
    end

    # Test D. `open_item/2` is scoped by id AND user_id.
    test "another user's item id changes nothing" do
      owner = insert_user()
      other = insert_user()
      item = emit!(owner, kind: "meeting_invited", source_type: "meeting", title: "Not yours")

      :ok = Inbox.subscribe(owner.id)

      assert {:error, :not_found} = Inbox.open_item(item.id, other.id)
      assert %Item{read_at: nil, dismissed_at: nil} = Repo.get!(Item, item.id)
      refute_receive {:inbox_item_dismissed, _}, 100
      refute_receive {:inbox_changed, _}, 50
    end
  end

  # ── Open-undo toast (task 01a11703 stage 3) ───────────────────────────
  #
  # Opening a non-action row dismisses it and navigates away, so the undo is
  # derived from the DB on the next /inbox mount (`Inbox.last_dismissed_on_open/2`).
  describe "open-undo toast" do
    defp open_and_leave(conn, user, %Item{} = item) do
      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      assert {:error, {:live_redirect, _}} =
               lv
               |> element(~s(#{row_selector(item)} [data-role="inbox-item-open"]))
               |> render_click()
    end

    defp toast_text(lv) do
      lv
      |> element(~s([data-role="toast-message"]))
      |> render()
      |> String.replace(~r/<[^>]*>/, "")
      |> String.trim()
      |> html_unescape()
    end

    # Stamp the open shape (`dismissed_at == read_at`, one value) at a chosen
    # age, so the window is tested without sleeping.
    defp stamp_opened!(%Item{} = item, age_seconds) do
      at = DateTime.add(DateTime.utc_now(), -age_seconds, :second)
      item |> Ecto.Changeset.change(read_at: at, dismissed_at: at) |> Repo.update!()
    end

    test "opening a meeting_invited row and remounting shows the single toast", %{conn: conn} do
      user = insert_user()

      item =
        emit!(user,
          kind: "meeting_invited",
          source_type: "meeting",
          title: "Design sync",
          url: "/meetings"
        )

      open_and_leave(conn, user, item)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert toast_text(lv) == ~s(Removed "Design sync")
      assert has_element?(lv, ~s([data-role="inbox-toast"][data-variant="single"]))
      # One line, no X: the toast times out.
      refute has_element?(lv, ~s([data-role="inbox-toast"] button[phx-click="dismiss_toast"]))
    end

    test "Undo brings the row back read: dismissed_at nil, read_at kept, badge 0",
         %{conn: conn} do
      user = insert_user()

      item =
        emit!(user,
          kind: "meeting_invited",
          source_type: "meeting",
          title: "Design sync",
          url: "/meetings"
        )

      open_and_leave(conn, user, item)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      refute has_element?(lv, row_selector(item))

      undo(lv)

      assert has_element?(lv, row_selector(item))
      refute has_element?(lv, ~s([data-role="inbox-toast"]))
      assert %Item{dismissed_at: nil, read_at: %DateTime{}} = Repo.get!(Item, item.id)
      assert Inbox.reachable_unread_count(user.id) == 0

      # Restored, so the next mount derives no toast from it.
      {:ok, lv2, _html} = live(auth(conn, user), "/inbox")
      refute has_element?(lv2, ~s([data-role="inbox-toast"]))
    end

    test "opening a task_plan_review row and remounting shows no toast", %{conn: conn} do
      user = insert_user()
      task = sponsored_task!(user)

      %Platform.Tasks.Plan{}
      |> Platform.Tasks.Plan.changeset(%{task_id: task.id, version: 1, status: "pending_review"})
      |> Repo.insert!()

      item =
        emit!(user,
          kind: "task_plan_review",
          source_type: "task",
          source_id: task.id,
          title: "Plan ready for review",
          url: "/tasks/#{task.id}"
        )

      open_and_leave(conn, user, item)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert has_element?(lv, row_selector(item))
      refute has_element?(lv, ~s([data-role="inbox-toast"]))
    end

    test "an open dismissal 301s old shows no toast; the same row 60s old does",
         %{conn: conn} do
      user = insert_user()

      item =
        emit!(user, kind: "meeting_invited", source_type: "meeting", title: "Old sync")

      stamp_opened!(item, 301)
      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      refute has_element?(lv, ~s([data-role="inbox-toast"]))

      # Positive control: inside the window the same row does raise it, so the
      # refute above is the window talking, not a toast that never renders.
      stamp_opened!(item, 60)
      {:ok, lv2, _html} = live(auth(conn, user), "/inbox")
      assert toast_text(lv2) == ~s(Removed "Old sync")
    end

    # Kills the mutation that drops `dismissed_at == read_at`: a row dismissed
    # by the X (or any sweep) has `read_at` nil or a different instant, and is
    # not an open. None of the four tests above can see that clause — the
    # plan-review row is never dismissed and the 301s row fails the window.
    test "a row dismissed WITHOUT opening it shows no toast", %{conn: conn} do
      user = insert_user()

      item =
        emit!(user, kind: "meeting_invited", source_type: "meeting", title: "Just dismissed")

      assert {:ok, _} = Inbox.mark_dismissed(item.id, user.id)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      refute has_element?(lv, ~s([data-role="inbox-toast"]))
    end

    test "only the most recent open is offered" do
      user = insert_user()
      older = emit!(user, kind: "meeting_invited", source_type: "meeting", title: "First")
      newer = emit!(user, kind: "meeting_invited", source_type: "meeting", title: "Second")

      stamp_opened!(older, 30)
      stamp_opened!(newer, 10)

      assert %Item{id: id} = Inbox.last_dismissed_on_open(user.id)
      assert id == newer.id
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
      assert render(lv) =~ "Your browser is blocking notifications from Burrow."
    end

    # Task 01a10d8e stage 6: the wiring the component tests cannot see. The
    # hook names the native shell beside the state, the shell keeps it, and
    # `/inbox` hands it to the row, whose button reaches the same handler.
    test "inside Burrow Android, denied offers the re-ask and it reaches the hook", %{lv: lv} do
      render_hook(lv, "push_permission_state", %{
        "state" => "denied",
        "native_platform" => "android"
      })

      assert has_element?(
               lv,
               ~s([data-role="notification-state"][data-permission="denied"][data-native="android"])
             )

      refute render(lv) =~ "address bar"

      lv |> element(~s([data-role="notification-enable"])) |> render_click()
      assert_push_event(lv, "request_push_permission", %{})

      # A browser report afterwards (no shell named) goes back to the browser row.
      render_hook(lv, "push_permission_state", %{"state" => "denied"})
      refute has_element?(lv, ~s([data-role="notification-enable"]))
    end

    test "an unknown native_platform is treated as a browser", %{lv: lv} do
      render_hook(lv, "push_permission_state", %{"state" => "denied", "native_platform" => "x"})

      assert has_element?(lv, ~s([data-role="notification-state"][data-permission="denied"]))
      refute has_element?(lv, ~s([data-role="notification-enable"]))
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
