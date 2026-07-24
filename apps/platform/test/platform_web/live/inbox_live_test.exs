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

  alias Platform.Accounts.User
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
end
