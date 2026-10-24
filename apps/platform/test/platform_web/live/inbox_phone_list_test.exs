defmodule PlatformWeb.InboxPhoneListTest do
  @moduledoc """
  The phone Inbox list (`PlatformWeb.Inbox.InboxList`, redesign rung 14, task
  01a1557a-ad2d stage 2): one row shape for every kind (Saru, canvas 01a15ec4
  rev 2), patch-link rows with no `phx-click`, the Clear all / Undo header
  swap, the empty states, and the desktop pieces hidden below `lg`.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Repo
  alias PlatformWeb.Inbox.InboxList

  defp insert_user(name \\ nil) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      name: name || "Phone list user #{n}",
      email: "inbox_phone_list_#{n}@example.com",
      oidc_sub: "oidc-inbox-phone-list-#{n}"
    })
  end

  defp auth(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp channel!(name) do
    {:ok, space} =
      Chat.create_space(%{
        name: name,
        slug: "#{name}-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp participant!(space, type, id, name) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: type,
        participant_id: id,
        display_name: name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  # A real mention: a message by `author` in `space`, and the viewer's row
  # pointing at it with the url the producer writes (chat.ex mention emit).
  defp mention!(viewer, space, author, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: author.id,
        content_type: "text",
        content: content
      })

    {:ok, item} =
      Inbox.emit(%{
        user_id: viewer.id,
        kind: "chat_mention",
        source_type: "chat_message",
        source_id: msg.id,
        title: "Mentioned in ##{space.name}",
        body: content,
        url: "/chat/#{space.slug}?message=#{msg.id}"
      })

    item
  end

  defp emit!(user, attrs) do
    {:ok, item} =
      Inbox.emit(
        Map.merge(
          %{
            user_id: user.id,
            source_type: "task",
            source_id: Ecto.UUID.generate(),
            title: "Something",
            url: "/tasks"
          },
          Map.new(attrs)
        )
      )

    item
  end

  defp task!(title) do
    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Phone inbox #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/phone-inbox"
      })

    {:ok, task} = Platform.Tasks.create_task(%{project_id: project.id, title: title})
    task
  end

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp phone(lv), do: lv |> render() |> doc() |> LazyHTML.query("#inbox-phone")
  defp q(node, selector), do: LazyHTML.query(node, selector)
  defp text(node), do: node |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp classes_in_phone(html),
    do: html |> doc() |> q("#inbox-phone, #inbox-phone [class]") |> LazyHTML.attribute("class")

  defp row_ids(lv),
    do: lv |> phone() |> q("[data-role=inbox-row]") |> LazyHTML.attribute("data-item-id")

  defp row(lv, %Item{id: id}),
    do: lv |> phone() |> q(~s([data-role=inbox-row][data-item-id="#{id}"]))

  # Two unread mentions (a person in #general, an agent in #design), one read
  # mention, and one plan review on a task titled "Plan me". Emitted oldest
  # first, so the list order is the reverse.
  defp seed!(_ctx) do
    viewer = insert_user()
    general = channel!("general")
    design = channel!("design")

    for space <- [general, design], do: participant!(space, "user", viewer.id, "Viewer")

    bea = participant!(general, "user", Ecto.UUID.generate(), "Bea Person")
    pixel = participant!(design, "agent", Ecto.UUID.generate(), "Pixel")

    read = mention!(viewer, general, bea, "an older note, already read")
    {:ok, read} = Inbox.mark_read(read.id, viewer.id)

    # `Inbox.reconcile_for_user/1` dismisses a plan-review row at load unless
    # its task has a plan pending review.
    plan_me = task!("Plan me")

    {:ok, _plan} =
      %Platform.Tasks.Plan{}
      |> Platform.Tasks.Plan.changeset(%{
        task_id: plan_me.id,
        version: 1,
        status: "pending_review"
      })
      |> Repo.insert()

    review =
      emit!(viewer,
        kind: "task_plan_review",
        source_id: plan_me.id,
        title: "Plan ready for review: Plan me",
        body: "Three stages, one deploy"
      )

    from_agent = mention!(viewer, design, pixel, "three variants are up, pick one?")
    from_person = mention!(viewer, general, bea, String.duplicate("long excerpt ", 16))

    %{
      viewer: viewer,
      read: read,
      review: review,
      from_agent: from_agent,
      from_person: from_person
    }
  end

  describe "rows" do
    setup :seed!

    test "one row shape for every kind, newest first, with the unread dot on unread rows only",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live(auth(conn, ctx.viewer), "/inbox")

      assert row_ids(lv) ==
               Enum.map([ctx.from_person, ctx.from_agent, ctx.review, ctx.read], & &1.id)

      person = row(lv, ctx.from_person)
      assert text(q(person, "[data-role=inbox-row-author]")) == "Bea Person · #general"
      assert text(q(person, "[data-role=inbox-row-kind]")) == "Mention"
      assert text(q(person, "[data-role=inbox-row-body]")) =~ "long excerpt long excerpt"
      assert LazyHTML.attribute(q(person, "time"), "datetime") |> hd() =~ ~r/^\d{4}-\d\d-\d\dT/

      assert LazyHTML.attribute(q(person, "[data-role=inbox-row-avatar]"), "data-avatar") == [
               "person"
             ]

      agent = row(lv, ctx.from_agent)
      assert text(q(agent, "[data-role=inbox-row-author]")) == "Pixel · #design"

      assert LazyHTML.attribute(q(agent, "[data-role=inbox-row-avatar]"), "data-avatar") == [
               "agent"
             ]

      review = row(lv, ctx.review)
      assert text(q(review, "[data-role=inbox-row-author]")) == "Plan me"
      assert text(q(review, "[data-role=inbox-row-kind]")) == "Plan review"
      assert text(q(review, "[data-role=inbox-row-body]")) == "Three stages, one deploy"

      assert LazyHTML.attribute(q(review, "[data-role=inbox-row-avatar]"), "data-avatar") == [
               "kind"
             ]

      # Unread excerpt in body text, the read one in subtle.
      assert [person_class] = LazyHTML.attribute(q(person, "[data-role=inbox-row-body]"), "class")
      assert person_class =~ "text-base-content"
      read = row(lv, ctx.read)
      assert [read_class] = LazyHTML.attribute(q(read, "[data-role=inbox-row-body]"), "class")
      assert read_class =~ "text-subtle"
      refute read_class =~ "text-base-content"

      # Dots: present on the three unread rows (positive control), absent on the read one.
      for item <- [ctx.from_person, ctx.from_agent, ctx.review] do
        assert Enum.count(q(row(lv, item), "[data-role=inbox-row-unread-dot]")) == 1
      end

      assert Enum.count(q(read, "[data-role=inbox-row-unread-dot]")) == 0
    end

    test "every row is a patch link to /inbox?open=<id>, and no live link carries phx-click",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live(auth(conn, ctx.viewer), "/inbox")
      node = phone(lv)

      rows = q(node, "[data-role=inbox-row]")
      ids = LazyHTML.attribute(rows, "data-item-id")
      assert length(ids) == 4

      assert rows |> LazyHTML.tag() |> Enum.uniq() == ["a"]
      assert Enum.uniq(LazyHTML.attribute(rows, "data-phx-link")) == ["patch"]
      assert LazyHTML.attribute(rows, "href") == Enum.map(ids, &"/inbox?open=#{&1}")

      links = q(node, "[data-phx-link]")
      # Positive control: the query sees every row link.
      assert Enum.count(links) == length(ids)
      assert LazyHTML.attribute(links, "phx-click") == []
    end

    test "Clear all swaps to Undo and 'Inbox cleared.'; Undo brings the rows back in order",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live(auth(conn, ctx.viewer), "/inbox")
      before = row_ids(lv)

      assert has_element?(lv, "#inbox-phone [data-role=inbox-header-clear-all]")
      refute has_element?(lv, "#inbox-phone [data-role=inbox-header-undo]")

      lv |> element("#inbox-phone [data-role=inbox-header-clear-all]") |> render_click()

      assert row_ids(lv) == []
      assert has_element?(lv, "#inbox-phone [data-role=inbox-phone-cleared]", "Inbox cleared.")
      assert has_element?(lv, "#inbox-phone [data-role=inbox-header-undo]", "Undo")
      refute has_element?(lv, "#inbox-phone [data-role=inbox-header-clear-all]")
      assert text(phone(lv) |> q("[data-role=inbox-status]")) == "4 notifications cleared"

      lv |> element("#inbox-phone [data-role=inbox-header-undo]") |> render_click()

      assert row_ids(lv) == before
      assert Enum.count(phone(lv) |> q("[data-role=inbox-row-unread-dot]")) == 3
      assert has_element?(lv, "#inbox-phone [data-role=inbox-header-clear-all]")
      refute has_element?(lv, "#inbox-phone [data-role=inbox-header-undo]")
      refute has_element?(lv, "#inbox-phone [data-role=inbox-phone-cleared]")
      assert text(phone(lv) |> q("[data-role=inbox-status]")) == ""
    end

    test "a live insert after Clear all keeps Undo and replaces 'Inbox cleared.'",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live(auth(conn, ctx.viewer), "/inbox")
      lv |> element("#inbox-phone [data-role=inbox-header-clear-all]") |> render_click()
      assert has_element?(lv, "#inbox-phone [data-role=inbox-phone-cleared]")

      new = emit!(ctx.viewer, kind: "meeting_invited", source_type: "meeting", title: "Sync")
      _ = render(lv)

      assert row_ids(lv) == [new.id]
      assert has_element?(lv, "#inbox-phone [data-role=inbox-header-undo]")
      refute has_element?(lv, "#inbox-phone [data-role=inbox-header-clear-all]")
      refute has_element?(lv, "#inbox-phone [data-role=inbox-phone-cleared]")
    end

    test "nothing in the phone list uses hover:, a base-content alpha or text under 12px",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live(auth(conn, ctx.viewer), "/inbox")
      populated = classes_in_phone(render(lv))
      render_click(lv, "clear_all", %{})
      cleared = classes_in_phone(render(lv))
      classes = populated ++ cleared

      # Positive controls: the scan reads the root, the rows and the Undo chip.
      assert Enum.any?(classes, &(&1 =~ "lg:hidden"))
      assert Enum.any?(classes, &(&1 =~ "active:bg-base-100"))
      assert Enum.any?(classes, &(&1 =~ "text-[17px]"))
      assert Enum.any?(cleared, &(&1 =~ "border-edge"))

      for class <- classes do
        refute class =~ "hover:", class
        refute class =~ "text-base-content/", class

        for [n] <- Regex.scan(~r/text-\[(\d+)px\]/, class, capture: :all_but_first) do
          assert String.to_integer(n) >= 12, class
        end
      end
    end

    test "the desktop scroller and toast carry max-lg:hidden", %{conn: conn} = ctx do
      {:ok, lv, _html} = live(auth(conn, ctx.viewer), "/inbox")
      render_click(lv, "clear_all", %{})
      d = lv |> render() |> doc()

      for selector <- ["[data-role=inbox-surface]", "[data-role=inbox-toast]"] do
        node = q(d, selector)
        assert Enum.count(node) == 1, selector
        assert [class] = LazyHTML.attribute(node, "class")
        assert class =~ "max-lg:hidden", selector
      end

      [root] = d |> q("#inbox-phone") |> LazyHTML.attribute("class")
      assert root =~ "lg:hidden"
      refute root =~ "max-lg:hidden"
    end
  end

  describe "the selection bar and the single toast" do
    test "carries max-lg:hidden while it is shown", %{conn: conn} do
      user = insert_user()
      item = emit!(user, kind: "meeting_invited", source_type: "meeting", title: "Sync")
      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      render_click(lv, "toggle_select", %{"id" => item.id})

      [class] =
        lv |> render() |> doc() |> q("[data-role=selection-bar]") |> LazyHTML.attribute("class")

      assert class =~ "max-lg:hidden"
    end

    test "the open-undo toast carries max-lg:hidden", %{conn: conn} do
      user = insert_user()
      item = emit!(user, kind: "meeting_invited", source_type: "meeting", title: "Sync")
      {:ok, _} = Inbox.open_item(item.id, user.id)
      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      [class] =
        lv
        |> render()
        |> doc()
        |> q(~s([data-role=inbox-toast][data-variant=single]))
        |> LazyHTML.attribute("class")

      assert class =~ "max-lg:hidden"
    end
  end

  describe "header and empty states" do
    test "a user with no rows sees the never-empty copy and no header action", %{conn: conn} do
      {:ok, lv, _html} = live(auth(conn, insert_user()), "/inbox")

      assert has_element?(
               lv,
               "#inbox-phone [data-role=inbox-phone-empty]",
               "No mentions or replies yet."
             )

      refute has_element?(lv, "#inbox-phone [data-role=inbox-header-clear-all]")
      refute has_element?(lv, "#inbox-phone [data-role=inbox-header-undo]")
      # Positive control: the header itself rendered.
      assert has_element?(lv, "#inbox-phone h1", "Inbox")
    end

    test "the back chevron opens the More sheet", %{conn: conn} do
      {:ok, lv, _html} = live(auth(conn, insert_user()), "/inbox")

      assert [back] =
               lv |> phone() |> q("[data-role=inbox-back]") |> Enum.to_list()

      assert LazyHTML.attribute(back, "phx-click") == ["open_more_sheet"]
      assert LazyHTML.attribute(back, "aria-label") == ["Back to More"]

      lv |> element("#inbox-phone [data-role=inbox-back]") |> render_click()
      assert :sys.get_state(lv.pid).socket.assigns.more_sheet_open == true
    end

    test "the notification-state row never renders inside the phone list", %{conn: conn} do
      {:ok, lv, _html} = live(auth(conn, insert_user()), "/inbox")
      render_hook(lv, "push_permission_state", %{"state" => "denied"})

      # Positive control: the row renders, in the desktop region.
      assert has_element?(
               lv,
               ~s([data-role="inbox-surface"] [data-role="notification-state"][data-permission="denied"])
             )

      assert Enum.count(phone(lv) |> q("[data-role=notification-state]")) == 0
    end
  end

  describe "row sheet (stage 3)" do
    setup :seed!

    defp sheet(lv), do: lv |> render() |> doc() |> q("#inbox-row-sheet")

    defp sheet_items(lv),
      do: sheet(lv) |> q("[data-role^=inbox-sheet-]") |> Enum.map(&text/1)

    test "open_row_sheet opens the sheet with exactly Dismiss then Open, and no Select",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live(auth(conn, ctx.viewer), "/inbox")
      assert sheet_items(lv) == []

      render_hook(lv, "open_row_sheet", %{"id" => ctx.from_agent.id})

      node = sheet(lv)
      assert LazyHTML.attribute(node, "data-open") == ["true"]
      # Positive control: the sheet subtree renders a known label.
      assert text(node) =~ "Notification"
      assert sheet_items(lv) == ["Dismiss", "Open"]
      refute text(node) =~ "Select"
      assert [class] = LazyHTML.attribute(node, "class")
      assert class =~ "lg:hidden"
    end

    test "Dismiss from the sheet removes the row, closes the sheet and shows Undo",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live(auth(conn, ctx.viewer), "/inbox")
      render_hook(lv, "open_row_sheet", %{"id" => ctx.from_agent.id})

      lv |> element("#inbox-row-sheet [data-role=inbox-sheet-dismiss]") |> render_click()

      refute ctx.from_agent.id in row_ids(lv)
      assert LazyHTML.attribute(sheet(lv), "data-open") == ["false"]
      assert sheet_items(lv) == []
      assert has_element?(lv, "#inbox-phone [data-role=inbox-header-undo]")

      lv |> element("#inbox-phone [data-role=inbox-header-undo]") |> render_click()
      assert ctx.from_agent.id in row_ids(lv)
    end

    test "Open is a patch link with no phx-click that opens the row", %{conn: conn} = ctx do
      {:ok, lv, _html} = live(auth(conn, ctx.viewer), "/inbox")
      render_hook(lv, "open_row_sheet", %{"id" => ctx.from_agent.id})

      open = sheet(lv) |> q("[data-role=inbox-sheet-open]")
      assert LazyHTML.tag(open) == ["a"]
      assert LazyHTML.attribute(open, "data-phx-link") == ["patch"]
      assert LazyHTML.attribute(open, "href") == ["/inbox?open=#{ctx.from_agent.id}"]
      assert LazyHTML.attribute(open, "phx-click") == []

      url = ctx.from_agent.url

      assert {:error, {:live_redirect, %{to: ^url}}} =
               lv |> element("#inbox-row-sheet [data-role=inbox-sheet-open]") |> render_click()

      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, ctx.from_agent.id)
    end

    test "with the sheet open, no live link in #inbox-phone carries phx-click",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live(auth(conn, ctx.viewer), "/inbox")
      render_hook(lv, "open_row_sheet", %{"id" => ctx.review.id})

      links = phone(lv) |> q("[data-phx-link]")
      # Positive control: every row link plus the sheet's Open link.
      assert Enum.count(links) == 4 + 1
      assert LazyHTML.attribute(links, "phx-click") == []
    end

    test "every row link carries the RowLongPress hook, its event and its id",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live(auth(conn, ctx.viewer), "/inbox")
      rows = phone(lv) |> q("[data-role=inbox-row]")
      ids = LazyHTML.attribute(rows, "data-item-id")
      assert length(ids) == 4

      assert Enum.uniq(LazyHTML.attribute(rows, "phx-hook")) == ["RowLongPress"]
      assert Enum.uniq(LazyHTML.attribute(rows, "data-long-press-event")) == ["open_row_sheet"]
      assert LazyHTML.attribute(rows, "data-long-press-id") == ids
      assert LazyHTML.attribute(rows, "id") == Enum.map(ids, &"inbox-row-link-#{&1}")

      for class <- LazyHTML.attribute(rows, "class") do
        assert class =~ "select-none"
        assert class =~ "[-webkit-touch-callout:none]"
      end
    end

    test "each Actions button sits beside its row link, never inside it, and names the source",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live(auth(conn, ctx.viewer), "/inbox")
      node = phone(lv)

      buttons = q(node, "[data-role=inbox-row-actions]")
      # Positive control: one per row.
      assert Enum.count(buttons) == 4
      assert Enum.count(q(node, "[data-phx-link] [data-role=inbox-row-actions]")) == 0
      assert Enum.count(q(node, "li > [data-role=inbox-row-actions]")) == 4
      assert Enum.uniq(LazyHTML.attribute(buttons, "phx-click")) == ["open_row_sheet"]

      [agent_label] =
        node
        |> q(~s(li > [data-role=inbox-row-actions][phx-value-id="#{ctx.from_agent.id}"]))
        |> LazyHTML.attribute("aria-label")

      assert agent_label == "Actions for Pixel's message"

      [review_label] =
        node
        |> q(~s(li > [data-role=inbox-row-actions][phx-value-id="#{ctx.review.id}"]))
        |> LazyHTML.attribute("aria-label")

      assert review_label == "Actions for Plan review"

      render_click(lv, "open_row_sheet", %{"id" => ctx.review.id})
      assert sheet_items(lv) == ["Dismiss", "Open"]
    end
  end

  describe "author slot" do
    test "a DM mention reads '{author} · DM', not the peer's name twice" do
      item = %Item{kind: "chat_mention", title: "t"}
      assert InboxList.author_slot(item, %{name: "Bea"}, "Bea", nil) == "Bea · DM"
      assert InboxList.author_slot(item, %{name: "Bea"}, "#general", nil) == "Bea · #general"
      assert InboxList.author_slot(item, nil, "#general", nil) == "#general"
      review = %Item{kind: "task_plan_review", title: "t"}
      assert InboxList.author_slot(review, nil, nil, "Plan me") == "Plan me"
      assert InboxList.author_slot(review, nil, nil, nil) == "t"
    end
  end

  describe "kind words" do
    test "every kind in Inbox.Item.kinds/0 maps to a non-blank word" do
      kinds = Item.kinds()
      # Positive control: core's seven kinds are all in the list being checked.
      assert Enum.all?(Item.core_kinds(), &(&1 in kinds))
      assert length(kinds) >= 7

      for kind <- kinds do
        word = InboxList.kind_word(kind)
        assert String.trim(word) != "", kind
      end

      assert InboxList.kind_word("lifecycle_step_failed") == "Step failed"
      assert InboxList.kind_word("chat_mention") == "Mention"
    end

    test "'Step failed' is the only kind with the error dot" do
      dotted = for kind <- Item.kinds(), InboxList.kind_dot?(kind), do: kind
      assert dotted == ["lifecycle_step_failed"]
    end

    test "a step-failed row has a subtle kind word with an error dot, and the task title as author",
         %{conn: conn} do
      user = insert_user()
      task = task!("Deploy the thing")

      failed =
        emit!(user,
          kind: "lifecycle_step_failed",
          source_id: task.id,
          title: "Lifecycle step failed: notify",
          body: "Edge done — timeout"
        )

      invite = emit!(user, kind: "meeting_invited", source_type: "meeting", title: "Sync")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      kind = row(lv, failed) |> q("[data-role=inbox-row-kind]")
      assert text(kind) == "Step failed"
      assert [class] = LazyHTML.attribute(kind, "class")
      assert class =~ "text-subtle"
      refute class =~ "text-error"
      assert text(row(lv, failed) |> q("[data-role=inbox-row-author]")) == "Deploy the thing"

      dot = q(kind, "[data-role=inbox-row-kind-dot]")
      assert LazyHTML.attribute(dot, "aria-hidden") == ["true"]
      assert [dot_class] = LazyHTML.attribute(dot, "class")
      assert dot_class =~ "bg-error"

      # Positive control: another kind's word has no dot, and the same colour.
      other = row(lv, invite) |> q("[data-role=inbox-row-kind]")
      assert LazyHTML.attribute(other, "class") == [class]
      assert Enum.count(q(other, "[data-role=inbox-row-kind-dot]")) == 0
    end
  end
end
