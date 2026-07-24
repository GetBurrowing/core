defmodule Platform.Chat.MentionInboxTest do
  @moduledoc """
  Tests the chat @mention -> Inbox producer (task 019f904c-904d — M2).

  `Platform.Chat.emit_inbox_for_mentions/1` is a private post-commit
  side-effect exercised here through the PUBLIC `Platform.Chat.post_message/2`
  (and `post_message_with_attachments/3`) seam — the same seam production code
  posts through. It resolves the @mentioned USER participants of a space,
  excludes the author at the USER level, dedups by user, gates each through
  `inbox_emit_allowed?/2`, and calls `Platform.Inbox.emit/1` once per surviving
  user (M1: inserts one `inbox_items` row + broadcasts
  `{:inbox_item_added, item}` on `inbox:<user_id>`).

  Because the producer hooks ONLY the create seam, no-backfill-on-edit and
  no-retro-delete-on-delete are structural — the edit/delete paths never touch
  inbox rows.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Repo

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp create_user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "mention-inbox-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-mention-inbox-#{n}"
    })
    |> Repo.insert!()
  end

  defp create_space(kind, attrs \\ %{}) do
    default = %{
      name: "Space #{System.unique_integer([:positive])}",
      slug: unique_slug(),
      kind: kind
    }

    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  # A USER participant whose `participant_id` IS the user's id (the identity the
  # producer maps straight onto `Inbox.emit/1`'s `:user_id`).
  defp add_user(space_id, %User{} = user, display_name) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp add_agent(space_id, display_name) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp inbox_rows(user_id) do
    Item |> where(user_id: ^user_id) |> Repo.all()
  end

  defp unique_slug, do: "mention-inbox-#{System.unique_integer([:positive])}"

  # ── Channel mention (happy path) ────────────────────────────────────────────

  describe "channel @mention" do
    test "inserts exactly one inbox row with the expected fields and broadcasts it" do
      alice = create_user!("Alice")
      bob = create_user!("Bob")

      space = create_space("channel", %{name: "General"})
      alice_p = add_user(space.id, alice, "Alice")
      _bob_p = add_user(space.id, bob, "Bob")

      :ok = Inbox.subscribe(bob.id)

      {:ok, msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: alice_p.id,
          content_type: "text",
          content: "@[Bob] please review"
        })

      rows = inbox_rows(bob.id)
      assert length(rows) == 1
      [row] = rows

      assert row.user_id == bob.id
      assert row.kind == "chat_mention"
      assert row.source_type == "chat_message"
      assert row.source_id == msg.id
      assert row.title == "@Mention from Alice in #General"
      assert row.body == "@[Bob] please review"
      assert row.url == "/chat/#{space.slug}?message=#{msg.id}"

      assert_receive {:inbox_item_added, %Item{id: id, user_id: user_id}}
      assert id == row.id
      assert user_id == bob.id

      # Author gets nothing.
      assert inbox_rows(alice.id) == []
    end

    test "body is sliced to the first 200 characters" do
      alice = create_user!("Alice")
      bob = create_user!("Bob")

      space = create_space("channel")
      alice_p = add_user(space.id, alice, "Alice")
      _bob_p = add_user(space.id, bob, "Bob")

      long = "@[Bob] " <> String.duplicate("x", 500)

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: alice_p.id,
          content_type: "text",
          content: long
        })

      [row] = inbox_rows(bob.id)
      assert row.body == String.slice(long, 0, 200)
      assert String.length(row.body) == 200
    end

    test "reaches the producer through post_message_with_attachments/3 as well" do
      alice = create_user!("Alice")
      bob = create_user!("Bob")

      space = create_space("channel")
      alice_p = add_user(space.id, alice, "Alice")
      _bob_p = add_user(space.id, bob, "Bob")

      {:ok, _msg, _attachments} =
        Chat.post_message_with_attachments(
          %{
            space_id: space.id,
            participant_id: alice_p.id,
            content_type: "text",
            content: "@[Bob] see attached"
          },
          [
            %{
              filename: "a.txt",
              content_type: "text/plain",
              byte_size: 3,
              storage_key: "k/#{System.unique_integer([:positive])}"
            }
          ]
        )

      assert length(inbox_rows(bob.id)) == 1
    end
  end

  # ── Author self-mention excluded at USER level ──────────────────────────────

  describe "author exclusion" do
    test "an author who @mentions themselves gets no row, even holding rows in multiple spaces" do
      alice = create_user!("Alice")

      channel = create_space("channel")
      group = create_space("group")

      alice_channel_p = add_user(channel.id, alice, "Alice")
      _alice_group_p = add_user(group.id, alice, "Alice")

      :ok = Inbox.subscribe(alice.id)

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: channel.id,
          participant_id: alice_channel_p.id,
          content_type: "text",
          content: "note to self @[Alice]"
        })

      assert inbox_rows(alice.id) == []
      refute_receive {:inbox_item_added, _}, 200
    end
  end

  # ── No back-fill on edit ────────────────────────────────────────────────────

  describe "no back-fill on edit" do
    test "editing to swap mentions creates no new row and revokes none" do
      alice = create_user!("Alice")
      bob = create_user!("Bob")
      eve = create_user!("Eve")

      space = create_space("channel")
      alice_p = add_user(space.id, alice, "Alice")
      _bob_p = add_user(space.id, bob, "Bob")
      _eve_p = add_user(space.id, eve, "Eve")

      {:ok, msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: alice_p.id,
          content_type: "text",
          content: "@[Bob] hi"
        })

      assert length(inbox_rows(bob.id)) == 1
      assert inbox_rows(eve.id) == []

      {:ok, _edited} = Chat.edit_message(msg, "@[Eve] only")

      # Eve was mentioned only on edit → no row. Bob's original row survives.
      assert inbox_rows(eve.id) == []
      assert length(inbox_rows(bob.id)) == 1
    end
  end

  # ── No retro-delete on message delete ───────────────────────────────────────

  describe "no retro-delete on delete" do
    test "deleting the message leaves the inbox row intact" do
      alice = create_user!("Alice")
      bob = create_user!("Bob")

      space = create_space("channel")
      alice_p = add_user(space.id, alice, "Alice")
      _bob_p = add_user(space.id, bob, "Bob")

      {:ok, msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: alice_p.id,
          content_type: "text",
          content: "@[Bob] hi"
        })

      assert length(inbox_rows(bob.id)) == 1

      {:ok, _deleted} = Chat.delete_message(msg)

      assert length(inbox_rows(bob.id)) == 1
    end
  end

  # ── DM peer-name title ──────────────────────────────────────────────────────

  describe "DM mention" do
    test "emits with a title using the DM peer (author) name" do
      carol = create_user!("Carol")
      dave = create_user!("Dave")

      dm = create_space("dm", %{name: nil})
      carol_p = add_user(dm.id, carol, "Carol")
      _dave_p = add_user(dm.id, dave, "Dave")

      :ok = Inbox.subscribe(dave.id)

      {:ok, msg} =
        Chat.post_message(%{
          space_id: dm.id,
          participant_id: carol_p.id,
          content_type: "text",
          content: "@[Dave] ping"
        })

      [row] = inbox_rows(dave.id)
      assert row.title == "@Mention from Carol in #Carol"
      assert row.source_id == msg.id
      assert_receive {:inbox_item_added, %Item{user_id: user_id}}
      assert user_id == dave.id
    end
  end

  # ── Bot / system-authored messages still emit ───────────────────────────────

  describe "bot/system author" do
    test "an agent-authored message mentioning a user emits normally" do
      bob = create_user!("Bob")

      space = create_space("channel")
      bot_p = add_agent(space.id, "Botty")
      _bob_p = add_user(space.id, bob, "Bob")

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: bot_p.id,
          content_type: "text",
          content: "@[Bob] heads up"
        })

      [row] = inbox_rows(bob.id)
      assert row.kind == "chat_mention"
      assert row.title == "@Mention from Botty in #" <> space.name
    end
  end

  # ── External-scope gate (currently: space participation) ────────────────────

  describe "external-scope gate" do
    test "a mention of a user who is not a participant of the space produces no row" do
      # Until the RBAC M6/M7 predicate lands, `inbox_emit_allowed?/2` reduces to
      # space participation: a non-participant user never appears in
      # `list_participants/1`, so the producer never even considers Xavier.
      alice = create_user!("Alice")
      bob = create_user!("Bob")
      xavier = create_user!("Xavier")

      space = create_space("channel")
      alice_p = add_user(space.id, alice, "Alice")
      _bob_p = add_user(space.id, bob, "Bob")
      # Xavier is intentionally NOT added to the space.

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: alice_p.id,
          content_type: "text",
          content: "@[Xavier] and @[Bob]"
        })

      assert inbox_rows(xavier.id) == []
      assert length(inbox_rows(bob.id)) == 1
    end
  end
end
