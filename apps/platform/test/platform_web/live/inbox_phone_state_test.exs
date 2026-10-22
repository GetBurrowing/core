defmodule PlatformWeb.InboxPhoneStateTest do
  @moduledoc """
  The state InboxLive keeps for the phone Inbox (redesign rung 14, task
  01a1557a-ad2d, stage 1): open-by-params through `handle_params/3`, the
  `@undo` lifecycle, and `@row_sheet`. Stage 1 renders nothing new, so the
  assigns are read off the LiveView process (`:sys.get_state/1`), and the one
  stream-membership check reads the desktop section rows as its proxy (named
  where it is used).
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Repo

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      name: "Inbox phone user #{n}",
      email: "inbox_phone_#{n}@example.com",
      oidc_sub: "oidc-inbox-phone-#{n}"
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
          url: "/chat/general?message=#{Ecto.UUID.generate()}"
        },
        Map.new(overrides)
      )

    {:ok, item} = Inbox.emit(attrs)
    item
  end

  defp assigns(lv), do: :sys.get_state(lv.pid).socket.assigns

  # A navigation away from /inbox, as LiveViewTest reports it for both a dead
  # render (`live/2`) and a connected patch (`render_patch/2`).
  defp navigated_to({:error, {kind, %{to: to}}}) when kind in [:live_redirect, :redirect],
    do: to

  defp listed_ids(user_id) do
    user_id |> Inbox.unread_scope() |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  end

  describe "open by params" do
    test "a direct /inbox?open=<mention> opens it and navigates to its stored url",
         %{conn: conn} do
      user = insert_user()
      item = emit!(user, kind: "chat_mention")

      assert navigated_to(live(auth(conn, user), "/inbox?open=#{item.id}")) == item.url

      assert %Item{read_at: %DateTime{} = read_at, dismissed_at: %DateTime{} = dismissed_at} =
               Repo.get!(Item, item.id)

      assert read_at == dismissed_at
    end

    test "a patch from a mounted /inbox opens the mention and navigates", %{conn: conn} do
      user = insert_user()
      item = emit!(user, kind: "chat_mention")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      url = item.url

      # `kind: :push` (task review, e2e 7007). The client never records the
      # `?open=` patch (the server answers it with this redirect), so a
      # REPLACE overwrote the /inbox entry and Back skipped the Inbox. A push
      # keeps /inbox under the destination.
      assert {:error, {:live_redirect, %{to: ^url, kind: :push}}} =
               render_patch(lv, "/inbox?open=#{item.id}")

      assert %Item{read_at: %DateTime{}, dismissed_at: %DateTime{}} = Repo.get!(Item, item.id)
    end

    test "an action row is marked read and stays listed", %{conn: conn} do
      user = insert_user()

      item =
        emit!(user,
          kind: "task_plan_review",
          source_type: "task",
          title: "Plan ready for review",
          url: "/tasks/#{Ecto.UUID.generate()}"
        )

      assert navigated_to(live(auth(conn, user), "/inbox?open=#{item.id}")) == item.url
      assert %Item{read_at: %DateTime{}, dismissed_at: nil} = Repo.get!(Item, item.id)
      assert item.id in listed_ids(user.id)
    end

    test "another user's id writes nothing and lands on /inbox", %{conn: conn} do
      owner = insert_user()
      other = insert_user()
      item = emit!(owner, kind: "chat_mention")

      {:ok, lv, _html} = live(auth(conn, other), "/inbox")
      render_patch(lv, "/inbox?open=#{item.id}")

      assert_patched(lv, "/inbox")
      assert %Item{read_at: nil, dismissed_at: nil} = Repo.get!(Item, item.id)

      # The same through a dead render.
      assert navigated_to(live(auth(conn, other), "/inbox?open=#{item.id}")) == "/inbox"
      assert %Item{read_at: nil, dismissed_at: nil} = Repo.get!(Item, item.id)
    end

    test "a malformed id lands on /inbox", %{conn: conn} do
      user = insert_user()
      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      render_patch(lv, "/inbox?open=not-a-uuid")
      assert_patched(lv, "/inbox")
    end

    test "a row with no url is opened and lands on /inbox", %{conn: conn} do
      user = insert_user()
      item = emit!(user, kind: "meeting_invited", source_type: "meeting", url: nil)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      render_patch(lv, "/inbox?open=#{item.id}")

      assert_patched(lv, "/inbox")
      assert %Item{read_at: %DateTime{}, dismissed_at: %DateTime{}} = Repo.get!(Item, item.id)
    end

    test "a url query param is ignored: the destination is the stored url", %{conn: conn} do
      user = insert_user()
      item = emit!(user, kind: "chat_mention")

      assert navigated_to(live(auth(conn, user), "/inbox?open=#{item.id}&url=/evil")) ==
               item.url

      item2 = emit!(user, kind: "chat_mention")
      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      assert navigated_to(render_patch(lv, "/inbox?open=#{item2.id}&url=/evil")) == item2.url
    end

    test "@row_sheet is nil after any patch", %{conn: conn} do
      user = insert_user()
      item = emit!(user, kind: "chat_mention")
      other = emit!(user, kind: "chat_mention")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      render_hook(lv, "open_row_sheet", %{"id" => item.id})
      assert assigns(lv).row_sheet == item.id

      render_patch(lv, "/inbox")
      assert assigns(lv).row_sheet == nil

      render_hook(lv, "open_row_sheet", %{"id" => item.id})
      assert assigns(lv).row_sheet == item.id

      # A failed open patches back to /inbox and still resets the sheet.
      render_patch(lv, "/inbox?open=#{Ecto.UUID.generate()}")
      assert_patched(lv, "/inbox")
      assert assigns(lv).row_sheet == nil

      # A successful open navigates away; the sheet is reset on the way.
      render_hook(lv, "open_row_sheet", %{"id" => other.id})
      assert assigns(lv).row_sheet == other.id
      assert navigated_to(render_patch(lv, "/inbox?open=#{other.id}")) == other.url
    end

    test "open_row_sheet ignores an id that is not on screen; close_row_sheet clears it",
         %{conn: conn} do
      user = insert_user()
      item = emit!(user, kind: "chat_mention")
      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      render_hook(lv, "open_row_sheet", %{"id" => Ecto.UUID.generate()})
      assert assigns(lv).row_sheet == nil

      render_hook(lv, "open_row_sheet", %{"id" => item.id})
      assert assigns(lv).row_sheet == item.id

      render_hook(lv, "close_row_sheet", %{})
      assert assigns(lv).row_sheet == nil
    end
  end

  describe "Back from an opened row lands on /inbox (task review, e2e 7007)" do
    # Every row kind that opens to a url must PUSH the destination: a replace
    # overwrites the /inbox history entry, because the `?open=` patch itself
    # is never recorded by the client.
    test "a mention and an action row both open with a push redirect", %{conn: conn} do
      user = insert_user()
      mention = emit!(user, kind: "chat_mention")

      review =
        emit!(user,
          kind: "task_plan_review",
          source_type: "task",
          title: "Plan ready for review",
          url: "/tasks/#{Ecto.UUID.generate()}"
        )

      for item <- [mention, review] do
        {:ok, lv, _html} = live(auth(conn, user), "/inbox")
        url = item.url

        assert {:error, {:live_redirect, %{to: ^url, kind: kind}}} =
                 render_patch(lv, "/inbox?open=#{item.id}")

        assert kind == :push, "#{item.kind} opened with #{inspect(kind)}"
      end
    end

    test "a failed open still patches back to /inbox in place", %{conn: conn} do
      user = insert_user()
      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      render_patch(lv, "/inbox?open=#{Ecto.UUID.generate()}")
      assert_patched(lv, "/inbox")
    end
  end

  describe "@undo" do
    test "clear_all sets @undo.ids to exactly the swept set; an earlier dismissal stays dismissed",
         %{conn: conn} do
      user = insert_user()
      a = emit!(user, kind: "chat_mention", title: "a")
      b = emit!(user, kind: "task_plan_review", source_type: "task", title: "b")
      earlier = emit!(user, kind: "chat_mention", title: "earlier")
      {:ok, _} = Inbox.mark_dismissed(earlier.id, user.id)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert assigns(lv).undo == nil

      render_click(lv, "clear_all", %{})

      assert %{ids: ids, message: "2 notifications cleared"} = assigns(lv).undo
      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
      refute earlier.id in ids

      render_click(lv, "undo_last", %{})

      assert assigns(lv).undo == nil
      assert %Item{dismissed_at: nil} = Repo.get!(Item, a.id)
      assert %Item{dismissed_at: nil} = Repo.get!(Item, b.id)
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, earlier.id)
    end

    test "a live insert after clear_all keeps @undo; undo restores the swept rows once, read_at unchanged",
         %{conn: conn} do
      user = insert_user()
      read_row = emit!(user, kind: "chat_mention", title: "read one")
      {:ok, read_row} = Inbox.mark_read(read_row.id, user.id)
      unread_row = emit!(user, kind: "chat_mention", title: "unread one")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      render_click(lv, "clear_all", %{})
      undo = assigns(lv).undo
      assert %{ids: [_, _]} = undo

      new = emit!(user, kind: "chat_mention", title: "arrived after the sweep")
      # `emit/1` broadcasts to this LV already; send it again on purpose, as a
      # duplicate delivery, to show the reload after undo cannot double a row.
      send(lv.pid, {:inbox_item_added, new})
      _ = render(lv)
      assert assigns(lv).undo == undo

      # `:inbox_changed` does not clear it either.
      send(lv.pid, {:inbox_changed, user.id})
      _ = render(lv)
      assert assigns(lv).undo == undo

      render_click(lv, "undo_last", %{})
      html = render(lv)

      # PROXY: stage 1 renders no phone list, so the desktop section rows (reset
      # by the same `init_sections/2` that resets `:inbox_rows`) are counted.
      for row <- [new, read_row, unread_row] do
        assert length(Regex.scan(~r/id="inbox-item-#{row.id}"/, html)) == 1
      end

      assert %Item{dismissed_at: nil, read_at: read_at} = Repo.get!(Item, read_row.id)
      assert read_at == read_row.read_at
      assert %Item{dismissed_at: nil, read_at: nil} = Repo.get!(Item, unread_row.id)
      assert Enum.sort([new.id, read_row.id, unread_row.id]) == listed_ids(user.id)
    end

    test "a single dismiss sets @undo; undo_last restores that row", %{conn: conn} do
      user = insert_user()
      keep = emit!(user, kind: "chat_mention", title: "keep")
      drop = emit!(user, kind: "chat_mention", title: "drop")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      render_click(lv, "dismiss", %{"id" => drop.id})

      assert assigns(lv).undo == %{ids: [drop.id], message: "Notification dismissed"}
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, drop.id)

      render_click(lv, "undo_last", %{})
      assert assigns(lv).undo == nil
      assert %Item{dismissed_at: nil} = Repo.get!(Item, drop.id)
      assert %Item{dismissed_at: nil} = Repo.get!(Item, keep.id)
    end

    test "a single dismiss broadcasts {:inbox_changed, user_id}", %{conn: conn} do
      user = insert_user()
      drop = emit!(user, kind: "chat_mention", title: "drop")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      :ok = Inbox.subscribe(user.id)
      render_click(lv, "dismiss", %{"id" => drop.id})

      user_id = user.id
      assert_receive {:inbox_changed, ^user_id}, 1_000
      refute_receive {:inbox_item_dismissed, _}, 100
    end

    test "dismissing a row another tab already dismissed leaves @undo unchanged",
         %{conn: conn} do
      user = insert_user()
      first = emit!(user, kind: "chat_mention", title: "first")
      raced = emit!(user, kind: "chat_mention", title: "raced")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      render_click(lv, "dismiss", %{"id" => first.id})
      before = assigns(lv).undo
      assert before == %{ids: [first.id], message: "Notification dismissed"}

      # Another tab: a direct DB write with no broadcast, so this LV still
      # renders the row.
      {1, _} =
        Repo.update_all(from(i in Item, where: i.id == ^raced.id),
          set: [dismissed_at: DateTime.utc_now()]
        )

      render_click(lv, "dismiss", %{"id" => raced.id})
      assert assigns(lv).undo == before
    end

    test "a sweep that changes nothing leaves @undo as it was", %{conn: conn} do
      user = insert_user()
      only = emit!(user, kind: "chat_mention", title: "only")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      render_click(lv, "dismiss", %{"id" => only.id})
      before = assigns(lv).undo

      render_click(lv, "clear_all", %{})
      assert assigns(lv).undo == before
    end

    test "dismiss_selected sets @undo from dismiss_many's return", %{conn: conn} do
      user = insert_user()
      a = emit!(user, kind: "chat_mention", title: "a")
      b = emit!(user, kind: "chat_mention", title: "b")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      render_click(lv, "toggle_select", %{"id" => a.id})
      render_click(lv, "toggle_select", %{"id" => b.id})
      render_click(lv, "dismiss_selected", %{})

      assert %{ids: ids, message: "2 notifications cleared"} = assigns(lv).undo
      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
    end

    test "the desktop toast's Undo also clears @undo", %{conn: conn} do
      user = insert_user()
      _a = emit!(user, kind: "chat_mention", title: "a")

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      render_click(lv, "clear_all", %{})
      assert %{ids: [_]} = assigns(lv).undo

      render_click(lv, "undo_clear", %{})
      assert assigns(lv).undo == nil
    end

    test "undo_last without @undo is a no-op", %{conn: conn} do
      user = insert_user()
      item = emit!(user, kind: "chat_mention", title: "a")
      {:ok, _} = Inbox.mark_dismissed(item.id, user.id)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      render_click(lv, "undo_last", %{})

      assert assigns(lv).undo == nil
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, item.id)
    end

    test "a mount with a recent open-dismissed row shows the desktop toast, not @undo",
         %{conn: conn} do
      user = insert_user()
      item = emit!(user, kind: "meeting_invited", source_type: "meeting", title: "Design sync")
      {:ok, _} = Inbox.open_item(item.id, user.id)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      assert %{variant: :single, undo_ids: [id]} = assigns(lv).toast
      assert id == item.id
      assert has_element?(lv, ~s([data-role="inbox-toast"][data-variant="single"]))
      assert assigns(lv).undo == nil
    end
  end

  describe "author slot assigns" do
    test "a live insert merges its source title", %{conn: conn} do
      user = insert_user()

      {:ok, project} =
        Platform.Tasks.create_project(%{
          name: "Phone inbox #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/phone-inbox"
        })

      {:ok, task} = Platform.Tasks.create_task(%{project_id: project.id, title: "Ship it"})

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")
      assert assigns(lv).source_titles == %{}

      row =
        emit!(user,
          kind: "task_plan_review",
          source_type: "task",
          source_id: task.id,
          title: "Plan ready for review: Ship it"
        )

      _ = render(lv)
      assert assigns(lv).source_titles == %{row.id => "Ship it"}
    end
  end
end
