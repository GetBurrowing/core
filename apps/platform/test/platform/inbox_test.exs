defmodule Platform.InboxTest do
  use Platform.DataCase, async: true

  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Repo

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "User #{n}",
      email: "user-#{n}@example.com",
      oidc_sub: "sub-#{n}"
    })
  end

  defp valid_attrs(user, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: user.id,
        kind: "chat_mention",
        source_type: "chat_message",
        source_id: Ecto.UUID.generate(),
        title: "You were mentioned",
        body: "Rowan mentioned you",
        url: "/chat/123"
      },
      overrides
    )
  end

  describe "emit/1" do
    test "inserts exactly one row and returns {:ok, item}" do
      user = insert_user()

      assert {:ok, %Item{} = item} = Inbox.emit(valid_attrs(user))
      assert item.user_id == user.id
      assert item.kind == "chat_mention"
      assert is_nil(item.dismissed_at)
      assert is_nil(item.read_at)

      assert Repo.aggregate(from(i in Item, where: i.user_id == ^user.id), :count) == 1
    end

    test "broadcasts {:inbox_item_added, item} on the user's inbox topic" do
      user = insert_user()
      :ok = Inbox.subscribe(user.id)

      assert {:ok, %Item{id: id}} = Inbox.emit(valid_attrs(user))
      assert_receive {:inbox_item_added, %Item{id: ^id}}
    end

    test "rejects a kind outside the enum and inserts no row" do
      user = insert_user()

      assert {:error, changeset} = Inbox.emit(valid_attrs(user, %{kind: "not_a_real_kind"}))
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :kind)
      assert Repo.aggregate(from(i in Item, where: i.user_id == ^user.id), :count) == 0
    end
  end

  describe "list_unread_for_user/2" do
    test "excludes dismissed, includes read-but-not-dismissed, honors :kind and desc order" do
      user = insert_user()

      # 1ms spacing guarantees distinct microsecond inserted_at so the
      # desc-inserted_at ordering assertions are deterministic.
      {:ok, a} = Inbox.emit(valid_attrs(user, %{kind: "chat_mention", title: "A"}))
      Process.sleep(1)
      {:ok, b} = Inbox.emit(valid_attrs(user, %{kind: "chat_mention", title: "B"}))
      Process.sleep(1)
      {:ok, c} = Inbox.emit(valid_attrs(user, %{kind: "meeting_starting", title: "C"}))
      Process.sleep(1)
      {:ok, d} = Inbox.emit(valid_attrs(user, %{kind: "chat_mention", title: "D"}))

      {:ok, _} = Inbox.mark_read(b.id, user.id)
      {:ok, _} = Inbox.mark_dismissed(d.id, user.id)

      # Unfiltered: A, B, C present (D dismissed excluded), read B still included,
      # newest first.
      ids = Inbox.list_unread_for_user(user.id) |> Enum.map(& &1.id)
      assert ids == [c.id, b.id, a.id]

      # kind-filtered: only chat_mention, not dismissed -> A and B, desc order.
      kind_ids = Inbox.list_unread_for_user(user.id, kind: "chat_mention") |> Enum.map(& &1.id)
      assert kind_ids == [b.id, a.id]
    end
  end

  describe "unread_count/1" do
    test "counts non-dismissed rows and excludes dismissed ones" do
      user = insert_user()

      assert Inbox.unread_count(user.id) == 0

      {:ok, a} = Inbox.emit(valid_attrs(user, %{title: "A"}))
      {:ok, _b} = Inbox.emit(valid_attrs(user, %{title: "B"}))
      {:ok, c} = Inbox.emit(valid_attrs(user, %{title: "C"}))

      assert Inbox.unread_count(user.id) == 3

      # Read does NOT decrement (orthogonal to dismissal); dismiss does.
      {:ok, _} = Inbox.mark_read(a.id, user.id)
      assert Inbox.unread_count(user.id) == 3

      {:ok, _} = Inbox.mark_dismissed(c.id, user.id)
      assert Inbox.unread_count(user.id) == 2
    end

    test "is scoped per user — a second user's rows do not leak into the count" do
      u1 = insert_user()
      u2 = insert_user()

      {:ok, _} = Inbox.emit(valid_attrs(u1))
      {:ok, _} = Inbox.emit(valid_attrs(u1))
      {:ok, _} = Inbox.emit(valid_attrs(u2))

      assert Inbox.unread_count(u1.id) == 2
      assert Inbox.unread_count(u2.id) == 1
    end
  end

  describe "mark_read/2 and mark_dismissed/2" do
    test "set the corresponding timestamps and return {:ok, item}" do
      user = insert_user()
      {:ok, item} = Inbox.emit(valid_attrs(user))

      assert {:ok, read} = Inbox.mark_read(item.id, user.id)
      assert %DateTime{} = read.read_at

      assert {:ok, dismissed} = Inbox.mark_dismissed(item.id, user.id)
      assert %DateTime{} = dismissed.dismissed_at
    end

    test "cross-user guard: wrong user_id is a no-op returning {:error, :not_found}" do
      u1 = insert_user()
      u2 = insert_user()
      {:ok, item} = Inbox.emit(valid_attrs(u1))

      assert {:error, :not_found} = Inbox.mark_read(item.id, u2.id)
      assert {:error, :not_found} = Inbox.mark_dismissed(item.id, u2.id)

      reloaded = Repo.get!(Item, item.id)
      assert is_nil(reloaded.read_at)
      assert is_nil(reloaded.dismissed_at)

      # Correct owner still works.
      assert {:ok, read} = Inbox.mark_read(item.id, u1.id)
      assert %DateTime{} = read.read_at
    end

    test "mark_dismissed broadcasts {:inbox_item_dismissed, item} on the user's topic" do
      user = insert_user()
      {:ok, %Item{id: id} = item} = Inbox.emit(valid_attrs(user))

      :ok = Inbox.subscribe(user.id)

      assert {:ok, %Item{id: ^id}} = Inbox.mark_dismissed(item.id, user.id)
      assert_receive {:inbox_item_dismissed, %Item{id: ^id}}
    end

    test "a cross-user dismiss miss broadcasts nothing" do
      u1 = insert_user()
      u2 = insert_user()
      {:ok, item} = Inbox.emit(valid_attrs(u1))

      :ok = Inbox.subscribe(u1.id)

      assert {:error, :not_found} = Inbox.mark_dismissed(item.id, u2.id)
      refute_receive {:inbox_item_dismissed, _}
    end
  end

  describe "dismiss = gone; @mention = back" do
    test "re-emitting the same source triple after dismissal yields a NEW row" do
      user = insert_user()
      source_id = Ecto.UUID.generate()

      attrs =
        valid_attrs(user, %{kind: "task_plan_review", source_type: "task", source_id: source_id})

      {:ok, first} = Inbox.emit(attrs)
      {:ok, _} = Inbox.mark_dismissed(first.id, user.id)

      assert Inbox.list_unread_for_user(user.id) == []

      {:ok, second} = Inbox.emit(attrs)
      assert second.id != first.id
      assert is_nil(second.dismissed_at)

      ids = Inbox.list_unread_for_user(user.id) |> Enum.map(& &1.id)
      assert ids == [second.id]
      refute first.id in ids
    end
  end
end
