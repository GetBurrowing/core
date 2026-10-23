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

  # Records `fan_out_to_user/3` as `{:notif, user_id, payload}`, injected via
  # `:notifications_module` the way `Platform.InboxPushTest` observes push
  # (the real `fan_out_to_user/3` short-circuits in :test env).
  defmodule RelistPushRecorder do
    @moduledoc false
    def install(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def fan_out_to_user(user_id, payload, _opts \\ []) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, {:notif, user_id, payload})
      end

      :ok
    end
  end

  # ── The daily briefing (task 01a15ee1 stage 4) ─────────────────────────

  describe "the daily briefing row, chips and detail pane" do
    alias Platform.Memory.Briefing
    alias Platform.Memory.Insights.BriefingCard
    alias Platform.Memory.Insights.Briefings
    alias PlatformWeb.Components.BriefingRow

    # The America/Chicago date the disseminator writes `digest_date` in, which
    # is also the row's fallback "today" when no viewer zone is connected.
    defp briefing_today, do: BriefingRow.today(nil)

    # A delivered briefing: the `memory_briefings` row plus its ONE Inbox row,
    # made through the same `Inbox.upsert_briefing_item/2` the disseminator
    # calls. `questions` need a call; `fyis` are reversible briefing lines.
    defp briefing!(user, opts) do
      questions =
        for _ <- 1..Keyword.get(opts, :questions, 0)//1,
            do: Platform.InsightFixtures.insight!(addressee: user, action_type: "question")

      fyis =
        for _ <- 1..Keyword.get(opts, :fyis, 0)//1,
            do: Platform.InsightFixtures.insight!(addressee: user)

      insights = questions ++ fyis

      briefing =
        Repo.insert!(%Briefing{
          user_id: user.id,
          digest_date: Keyword.get(opts, :date, briefing_today()),
          items: Map.new(insights, &{BriefingCard.node_key(&1.id), &1.id})
        })

      {:ok, item, :created} =
        Inbox.upsert_briefing_item(briefing, %{
          total: length(insights),
          calls: length(questions)
        })

      %{briefing: briefing, item: item, questions: questions, fyis: fyis}
    end

    defp row_text(lv, role),
      do:
        lv
        |> element(~s([data-role="inbox-briefing-row"] [data-role="#{role}"]))
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.text()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

    test "the row's receipt line for 0, 1 and 3 calls", %{conn: conn} do
      for {questions, fyis, line, pill} <- [
            {0, 2, "2 items · FYI only", nil},
            {1, 1, "2 items · 1 needs your call", "1 needs your call"},
            {3, 2, "5 items · 3 need your call", "3 need your call"}
          ] do
        user = Platform.InsightFixtures.person!()
        briefing!(user, questions: questions, fyis: fyis)

        {:ok, lv, _html} = live(auth(conn, user), "/inbox")

        assert row_text(lv, "inbox-briefing-title") == "Today's briefing"
        assert row_text(lv, "inbox-briefing-kind") == "Briefing"
        assert row_text(lv, "inbox-briefing-summary") == line

        if pill do
          assert row_text(lv, "inbox-briefing-calls") == pill
        else
          refute has_element?(lv, ~s([data-role="inbox-briefing-calls"]))
        end

        # Unread until opened; and it is not filed under a section.
        assert has_element?(lv, ~s([data-role="inbox-briefing-unread-dot"]))
        refute has_element?(lv, ~s([data-role="inbox-item"][data-item-kind="briefing"]))
      end
    end

    test "an earlier day's row is titled with its date", %{conn: conn} do
      user = Platform.InsightFixtures.person!()
      date = Date.add(briefing_today(), -1)
      briefing!(user, fyis: 1, date: date)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      assert row_text(lv, "inbox-briefing-title") ==
               "Briefing · " <> Calendar.strftime(date, "%a, %b %-d")
    end

    test "the receipt line follows the briefing live", %{conn: conn} do
      user = Platform.InsightFixtures.person!()
      %{briefing: briefing, questions: [q]} = briefing!(user, questions: 1, fyis: 1)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert row_text(lv, "inbox-briefing-summary") == "2 items · 1 needs your call"

      scope = Platform.Access.Scope.for_user(Platform.Accounts.get_user(user.id))

      assert {:ok, _} =
               Briefings.handle(briefing, BriefingCard.node_key(q.id), "dismiss", scope, %{})

      # handle/5 broadcasts {:inbox_changed, user_id}; the LV re-derives.
      assert row_text(lv, "inbox-briefing-summary") == "2 items · FYI only"
    end

    # Task 01a15ee1 stage 6: the row stays listed through the day once
    # everything is handled ("All done · nothing waiting"), and an undo that
    # reopens an item finds it there with the open count.
    defp handle_all!(user, briefing, [q], [fyi]) do
      scope = Platform.Access.Scope.for_user(Platform.Accounts.get_user(user.id))
      q_key = BriefingCard.node_key(q.id)

      assert {:ok, _} =
               Briefings.handle(briefing, q_key, "answer", scope, %{"answer" => "host-b"})

      assert {:ok, _} =
               Briefings.handle(briefing, BriefingCard.node_key(fyi.id), "got_it", scope, %{})

      {scope, q_key}
    end

    test "every item handled: a fresh /inbox still lists the row, All done", %{conn: conn} do
      user = Platform.InsightFixtures.person!()
      %{briefing: b, item: item, questions: qs, fyis: fs} = briefing!(user, questions: 1, fyis: 1)
      handle_all!(user, b, qs, fs)

      for path <- ["/inbox", "/inbox?f=briefing"] do
        {:ok, lv, _html} = live(auth(conn, user), path)

        assert has_element?(
                 lv,
                 ~s([data-role="inbox-briefing-row"][data-item-id="#{item.id}"])
               )

        assert row_text(lv, "inbox-briefing-summary") == "All done · nothing waiting"
        refute has_element?(lv, ~s([data-role="inbox-briefing-calls"]))
      end

      assert %Item{dismissed_at: nil} = Repo.get!(Item, item.id)
    end

    test "undo after everything is handled: the row is listed with the open count",
         %{conn: conn} do
      user = Platform.InsightFixtures.person!()
      %{briefing: b, item: item, questions: qs, fyis: fs} = briefing!(user, questions: 1, fyis: 1)
      {scope, q_key} = handle_all!(user, b, qs, fs)

      {:ok, _lv, _html} = live(auth(conn, user), "/inbox")
      assert {:ok, _} = Briefings.undo(b, q_key, scope)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert has_element?(lv, ~s([data-role="inbox-briefing-row"][data-item-id="#{item.id}"]))
      assert row_text(lv, "inbox-briefing-summary") == "2 items · 1 needs your call"
    end

    test "undo re-lists a row that was dismissed while everything was handled",
         %{conn: conn} do
      user = Platform.InsightFixtures.person!()
      %{briefing: b, item: item, questions: qs, fyis: fs} = briefing!(user, questions: 1, fyis: 1)
      {scope, q_key} = handle_all!(user, b, qs, fs)

      # As the pre-stage-6 reconciler rule (or a hand dismissal) left it.
      {:ok, _} = Inbox.mark_dismissed(item.id, user.id)
      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      refute has_element?(lv, ~s([data-role="inbox-briefing-row"]))

      assert {:ok, _} = Briefings.undo(b, q_key, scope)
      assert %Item{dismissed_at: nil} = Repo.get!(Item, item.id)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert has_element?(lv, ~s([data-role="inbox-briefing-row"][data-item-id="#{item.id}"]))
      assert row_text(lv, "inbox-briefing-summary") == "2 items · 1 needs your call"
    end

    test "an undo relist keeps the row's place in the list and its read state, and sends no push",
         %{conn: conn} do
      Application.put_env(:platform, :notifications_module, RelistPushRecorder)
      RelistPushRecorder.install(self())

      on_exit(fn ->
        Application.delete_env(:platform, :notifications_module)
        :persistent_term.erase({RelistPushRecorder, :owner})
      end)

      user = Platform.InsightFixtures.person!()

      %{briefing: old, item: old_item, questions: qs, fyis: fs} =
        briefing!(user, questions: 1, fyis: 1, date: Date.add(briefing_today(), -1))

      %{item: new_item} = briefing!(user, fyis: 1)

      # Yesterday's row was delivered an hour before today's, so the list
      # (newest `inserted_at` first) reads today, then yesterday.
      earlier = DateTime.add(new_item.inserted_at, -3600, :second)

      Repo.update_all(from(i in Item, where: i.id == ^old_item.id),
        set: [inserted_at: earlier]
      )

      {scope, q_key} = handle_all!(user, old, qs, fs)
      {:ok, _} = Inbox.mark_read(old_item.id, user.id)
      {:ok, _} = Inbox.mark_dismissed(old_item.id, user.id)
      before = Repo.get!(Item, old_item.id)
      assert %DateTime{} = before.read_at

      assert {:ok, _} = Briefings.undo(old, q_key, scope)

      relisted = Repo.get!(Item, old_item.id)
      assert relisted.dismissed_at == nil
      # (a) its place: `inserted_at` is untouched.
      assert relisted.inserted_at == before.inserted_at
      # (b) still read, `read_at` unchanged.
      assert relisted.read_at == before.read_at
      # (c) no push.
      refute_received {:notif, _, _}

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      ids =
        lv
        |> render()
        |> Floki.parse_document!()
        |> Floki.find(~s([data-role="inbox-briefing-row"]))
        |> Floki.attribute("data-item-id")

      assert ids == [new_item.id, old_item.id]

      refute has_element?(
               lv,
               ~s([data-role="inbox-briefing-row"][data-item-id="#{old_item.id}"] ) <>
                 ~s([data-role="inbox-briefing-unread-dot"])
             )
    end

    test "the Briefing chip shows only briefing rows, in the URL as ?f=", %{conn: conn} do
      user = Platform.InsightFixtures.person!()
      briefing!(user, questions: 1)
      mention = emit!(user, kind: "chat_mention")
      review = emit!(user, kind: "task_plan_review", source_type: "task", url: "/tasks/x")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert has_element?(lv, row_selector(mention))
      assert has_element?(lv, row_selector(review))
      assert has_element?(lv, ~s([data-role="inbox-briefing-row"]))

      lv
      |> element(~s([data-role="inbox-filter-chip"][data-filter="briefing"]))
      |> render_click()

      assert_patch(lv, "/inbox?f=briefing")
      assert has_element?(lv, ~s([data-role="inbox-briefing-row"]))
      refute has_element?(lv, row_selector(mention))
      refute has_element?(lv, row_selector(review))

      assert has_element?(
               lv,
               ~s([data-role="inbox-filter-chip"][data-filter="briefing"][aria-current="true"])
             )

      # Mentions and Tasks map onto their sections; All brings everything back.
      {:ok, lv, _html} = live(auth(conn, user), "/inbox?f=mentions")
      assert has_element?(lv, row_selector(mention))
      refute has_element?(lv, row_selector(review))
      refute has_element?(lv, ~s([data-role="inbox-briefing-row"]))

      {:ok, lv, _html} = live(auth(conn, user), "/inbox?f=tasks")
      assert has_element?(lv, row_selector(review))
      refute has_element?(lv, row_selector(mention))

      lv |> element(~s([data-role="inbox-filter-chip"][data-filter="all"])) |> render_click()
      assert_patch(lv, "/inbox")
      assert has_element?(lv, row_selector(mention))
      assert has_element?(lv, ~s([data-role="inbox-briefing-row"]))
    end

    test "a filter with nothing to show says so", %{conn: conn} do
      user = Platform.InsightFixtures.person!()
      emit!(user, kind: "chat_mention")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox?f=briefing")
      assert has_element?(lv, ~s([data-role="inbox-filter-empty"]), "Nothing here.")
    end

    test "clicking the row patches to /inbox/briefing/<date>; the row stays listed, read",
         %{conn: conn} do
      user = Platform.InsightFixtures.person!()
      %{item: item} = briefing!(user, questions: 3, fyis: 2)
      iso = Date.to_iso8601(briefing_today())

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert has_element?(lv, ~s([data-role="inbox-detail-empty"]), "Select an item")

      lv |> element(~s([data-role="inbox-briefing-open"])) |> render_click()
      assert_patch(lv, "/inbox/briefing/" <> iso)

      # Still listed, now read, and selected in the two-pane list.
      assert has_element?(lv, ~s([data-role="inbox-briefing-row"][data-selected="true"]))
      refute has_element?(lv, ~s([data-role="inbox-briefing-unread-dot"]))
      assert %Item{read_at: %DateTime{}, dismissed_at: nil} = Repo.get!(Item, item.id)

      # The detail pane holds the briefing, with the phone's back link.
      assert has_element?(lv, ~s([data-role="inbox-briefing-detail"][data-date="#{iso}"]))
      assert has_element?(lv, ~s([data-role="inbox-detail-back"][href="/inbox"]), "‹ Inbox")
      refute has_element?(lv, ~s([data-role="inbox-detail-empty"]))

      # A fresh visit still lists it.
      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert has_element?(lv, ~s([data-role="inbox-briefing-row"][data-item-id="#{item.id}"]))
    end

    test "the row keeps the chip filter when it opens the detail", %{conn: conn} do
      user = Platform.InsightFixtures.person!()
      briefing!(user, fyis: 1)
      iso = Date.to_iso8601(briefing_today())

      {:ok, lv, _html} = live(auth(conn, user), "/inbox?f=briefing")
      lv |> element(~s([data-role="inbox-briefing-open"])) |> render_click()
      assert_patch(lv, "/inbox/briefing/#{iso}?f=briefing")
      assert has_element?(lv, ~s([data-role="inbox-detail-back"][href="/inbox?f=briefing"]))
    end

    test "a GET of the detail route marks the row read", %{conn: conn} do
      user = Platform.InsightFixtures.person!()
      %{item: item} = briefing!(user, fyis: 1)

      {:ok, lv, _html} =
        live(auth(conn, user), "/inbox/briefing/" <> Date.to_iso8601(briefing_today()))

      assert has_element?(lv, ~s([data-role="inbox-briefing-detail"]))
      assert %Item{read_at: %DateTime{}, dismissed_at: nil} = Repo.get!(Item, item.id)
    end

    test "a second user never sees the row or the briefing", %{conn: conn} do
      owner = Platform.InsightFixtures.person!()
      %{questions: [q]} = briefing!(owner, questions: 1, fyis: 1)
      other = Platform.InsightFixtures.person!()
      iso = Date.to_iso8601(briefing_today())

      {:ok, lv, html} = live(auth(conn, other), "/inbox")
      refute has_element?(lv, ~s([data-role="inbox-briefing-row"]))
      refute html =~ "Today&#39;s briefing"

      {:ok, lv, html} = live(auth(conn, other), "/inbox/briefing/" <> iso)
      assert has_element?(lv, ~s([data-role="inbox-briefing-not-found"]))
      refute has_element?(lv, ~s([data-role="inbox-briefing-detail"]))
      refute html =~ q.body
      refute html =~ "need your call"
    end

    test "a malformed date is not found, not a crash", %{conn: conn} do
      user = Platform.InsightFixtures.person!()
      {:ok, lv, _html} = live(auth(conn, user), "/inbox/briefing/not-a-date")
      assert has_element?(lv, ~s([data-role="inbox-briefing-not-found"]))
    end

    test "Clear all counts and clears the briefing row too", %{conn: conn} do
      user = Platform.InsightFixtures.person!()
      %{item: item} = briefing!(user, fyis: 1)
      emit!(user, kind: "chat_mention")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert has_element?(lv, ~s([data-role="clear-all"]), "Clear all (2)")

      clear_all(lv)
      refute has_element?(lv, ~s([data-role="inbox-briefing-row"]))
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, item.id)
    end

    test "the row's X dismisses only that row", %{conn: conn} do
      user = Platform.InsightFixtures.person!()
      %{item: item} = briefing!(user, fyis: 1)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      lv |> element(~s([data-role="inbox-briefing-dismiss"])) |> render_click()

      refute has_element?(lv, ~s([data-role="inbox-briefing-row"]))
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, item.id)
    end
  end

  # ── The meeting briefing (task 01a1694a stage 4) ───────────────────────

  describe "the meeting briefing row and detail" do
    alias Platform.Access.Scope
    alias Platform.Meetings
    alias Platform.Meetings.Candidates
    alias Platform.Meetings.Meeting
    alias Platform.Meetings.MeetingBriefings
    alias Platform.Meetings.Participant
    alias Platform.Meetings.Room
    alias Platform.Tasks.Task, as: TaskRecord
    alias Platform.Tenancy.OrgMembership

    defp member! do
      user = insert_user()

      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "member"})
      |> Repo.insert!()

      user
    end

    defp graduate_task!(%Meeting{} = meeting, quote) do
      {:ok, candidate} =
        Candidates.create(%{
          meeting_id: meeting.id,
          evidence_quote: quote,
          state: :heard,
          outcome_kind: :task,
          acts_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      {:ok, graduated} = Candidates.graduate(candidate)
      Repo.get!(TaskRecord, graduated.task_id)
    end

    # A meeting A and B attended, with two backlog tasks, concluded through
    # `end_meeting/1` so each has the real Inbox row and briefing.
    defp concluded_meeting! do
      n = System.unique_integer([:positive])

      {:ok, project} =
        Platform.Tasks.create_project(%{name: "MB LV #{n}", org_id: acme_org_id()})

      {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "MB sync #{n}"})

      {:ok, live} =
        meeting
        |> Meeting.status_changeset("live", %{
          started_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })
        |> Repo.update()

      room =
        %Room{}
        |> Room.changeset(%{
          space_id: live.chat_space_id,
          livekit_room_name: "space-#{live.chat_space_id}"
        })
        |> Repo.insert!()

      a = member!()
      b = member!()

      for user <- [a, b] do
        %Participant{}
        |> Participant.changeset(%{
          room_id: room.id,
          user_id: user.id,
          display_name: user.name,
          joined_at: DateTime.add(DateTime.utc_now(), -3000, :second)
        })
        |> Repo.insert!()
      end

      t1 = graduate_task!(live, "somebody should rotate the S3 keys")
      t2 = graduate_task!(live, "somebody should renew the TLS certs")
      {:ok, ended} = Meetings.end_meeting(live)

      %{meeting: ended, a: a, b: b, t1: t1, t2: t2}
    end

    defp mb_key(%TaskRecord{id: id}), do: MeetingBriefings.node_key("task:" <> id)

    defp detail_path(%Meeting{id: id}), do: "/inbox/meeting/" <> id

    test "an attendee's row shows the meeting and its receipt line", %{conn: conn} do
      ctx = concluded_meeting!()
      {:ok, lv, _html} = live(auth(conn, ctx.a), "/inbox?f=briefing")

      row = ~s([data-role="inbox-meeting-briefing-row"][data-meeting-id="#{ctx.meeting.id}"])
      assert has_element?(lv, row)

      assert lv |> element(row <> ~s( [data-role="inbox-meeting-briefing-title"])) |> render() =~
               ctx.meeting.name

      assert lv |> element(row <> ~s( [data-role="inbox-meeting-briefing-kind"])) |> render() =~
               "Meeting"

      assert lv |> element(row <> ~s( [data-role="inbox-meeting-briefing-summary"])) |> render() =~
               "2 items · 2 open"

      # Not streamed into a section as a generic item.
      refute has_element?(lv, ~s([data-role="inbox-item"][data-item-kind="meeting_briefing"]))
    end

    test "a non-attendee sees no row, and the real id, a random uuid and a malformed id render the same not-found",
         %{conn: conn} do
      ctx = concluded_meeting!()
      outsider = member!()

      {:ok, lv, _html} = live(auth(conn, outsider), "/inbox")
      refute has_element?(lv, ~s([data-role="inbox-meeting-briefing-row"]))

      texts =
        for path <- [
              detail_path(ctx.meeting),
              "/inbox/meeting/" <> Ecto.UUID.generate(),
              "/inbox/meeting/not-a-uuid"
            ] do
          {:ok, lv, _html} = live(auth(conn, outsider), path)
          refute has_element?(lv, ~s([data-role="meeting-briefing-detail"]))
          lv |> element(~s([data-role="meeting-briefing-not-found"])) |> render() |> strip_tags()
        end

      assert Enum.uniq(texts) == ["There's no briefing here."]

      # Positive control: the attendee DOES see the detail on the real id.
      {:ok, lv, _html} = live(auth(conn, ctx.a), detail_path(ctx.meeting))
      assert has_element?(lv, ~s([data-role="meeting-briefing-detail"]))
    end

    test "A reverts and B's open briefing shows Reverted by A live, with no buttons",
         %{conn: conn} do
      ctx = concluded_meeting!()
      k = mb_key(ctx.t1)
      card = ~s([data-key="#{k}"])

      {:ok, lv, _html} = live(auth(conn, ctx.b), detail_path(ctx.meeting))
      assert has_element?(lv, ~s([data-role="meeting-briefing-card"]#{card}))

      assert has_element?(
               lv,
               ~s([data-role="meeting-briefing-card"]#{card} [data-action="revert"])
             )

      briefing = MeetingBriefings.get_for_attendee(ctx.meeting.id, ctx.a.id)

      assert {:ok, _} =
               MeetingBriefings.act(
                 briefing,
                 k,
                 :revert,
                 Scope.for_user(Repo.get!(User, ctx.a.id)),
                 %{}
               )

      # The broadcast lands as `{:inbox_changed, _}`, whose handler
      # `send_update`s the component; the second render is after that update.
      _ = render(lv)
      _ = render(lv)

      assert has_element?(lv, ~s([data-role="meeting-briefing-resolved-card"]#{card}))
      refute has_element?(lv, ~s([data-role="meeting-briefing-card"]#{card}))

      assert lv
             |> element(
               ~s([data-role="meeting-briefing-resolved-card"]#{card} [data-role="meeting-briefing-receipt-lead"])
             )
             |> render()
             |> strip_tags() == "Reverted by " <> ctx.a.name

      refute has_element?(lv, ~s(#{card} [data-role="meeting-briefing-action"]))
    end

    test "B's stale click renders Already handled and changes no task", %{conn: conn} do
      ctx = concluded_meeting!()
      k = mb_key(ctx.t1)
      card = ~s([data-key="#{k}"])

      {:ok, lv, _html} = live(auth(conn, ctx.b), detail_path(ctx.meeting))

      briefing = MeetingBriefings.get_for_attendee(ctx.meeting.id, ctx.a.id)

      assert {:ok, _} =
               MeetingBriefings.act(
                 briefing,
                 k,
                 :revert,
                 Scope.for_user(Repo.get!(User, ctx.a.id)),
                 %{}
               )

      deleted_at = Repo.get!(TaskRecord, ctx.t1.id).deleted_at
      assert %DateTime{} = deleted_at

      # B's page still holds the stale Revert button: the click reaches the
      # server before the reload it is about to get.
      lv
      |> element(~s([data-role="meeting-briefing-card"]#{card} [data-action="revert"]))
      |> render_click()

      assert lv |> element(~s([data-role="meeting-briefing-notice"])) |> render() |> strip_tags() ==
               "Already handled by " <> ctx.a.name

      assert Repo.get!(TaskRecord, ctx.t1.id).deleted_at == deleted_at
    end

    test "a blank Ask shows the hint and posts nothing", %{conn: conn} do
      ctx = concluded_meeting!()
      k = mb_key(ctx.t2)
      card = ~s([data-role="meeting-briefing-card"][data-key="#{k}"])

      {:ok, lv, _html} = live(auth(conn, ctx.b), detail_path(ctx.meeting))

      lv |> element(card <> ~s( [data-action="ask"])) |> render_click()
      assert has_element?(lv, card <> ~s( [data-role="meeting-briefing-ask-form"]))

      lv
      |> form(card <> ~s( [data-role="meeting-briefing-ask-form"]), %{"question" => "  "})
      |> render_submit()

      assert has_element?(lv, card <> ~s( [data-role="meeting-briefing-blank-hint"]))
      assert has_element?(lv, card <> ~s( [data-action="ask"]))

      assert Repo.aggregate(
               from(m in Platform.Chat.Message, where: m.space_id == ^ctx.meeting.chat_space_id),
               :count
             ) == 0
    end

    # Review case 7003: every phone control is at least 44px tall. The
    # resolved card's "See the question" link was the one that measured 16px.
    test "the asked receipt's link, and every link and button in the detail, has the 44px phone target",
         %{conn: conn} do
      ctx = concluded_meeting!()
      k = mb_key(ctx.t1)
      briefing = MeetingBriefings.get_for_attendee(ctx.meeting.id, ctx.a.id)

      assert {:ok, _} =
               MeetingBriefings.act(
                 briefing,
                 k,
                 :ask,
                 Scope.for_user(Repo.get!(User, ctx.a.id)),
                 %{"question" => "Who owns this?"}
               )

      {:ok, lv, _html} = live(auth(conn, ctx.b), detail_path(ctx.meeting))

      assert has_element?(
               lv,
               ~s([data-role="meeting-briefing-resolved-card"][data-key="#{k}"] ) <>
                 ~s(a.min-h-11[data-role="meeting-briefing-receipt-link"])
             )

      detail = lv |> element(~s([data-role="meeting-briefing-detail"])) |> render()
      controls = Regex.scan(~r/<(?:a|button)\b[^>]*>/, detail) |> Enum.map(&hd/1)

      # The detail renders open-card buttons, the transcript link and the
      # receipt link, so this cannot pass on an empty list.
      assert length(controls) >= 3

      for tag <- controls do
        assert tag =~ "min-h-11", "phone control under 44px: " <> tag
      end
    end

    test "opening the row marks it read and it stays listed", %{conn: conn} do
      ctx = concluded_meeting!()

      [item] =
        Repo.all(from(i in Item, where: i.user_id == ^ctx.a.id and i.kind == "meeting_briefing"))

      assert is_nil(item.read_at)

      {:ok, _lv, _html} = live(auth(conn, ctx.a), detail_path(ctx.meeting))

      reread = Repo.get!(Item, item.id)
      assert %DateTime{} = reread.read_at
      assert is_nil(reread.dismissed_at)
    end

    defp strip_tags(html),
      do:
        html
        |> String.replace(~r/<[^>]*>/, "")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> html_unescape()
  end
end
