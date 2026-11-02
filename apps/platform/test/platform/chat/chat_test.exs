defmodule Platform.ChatTest do
  @moduledoc """
  Integration tests for `Platform.Chat` context — threads, reactions, pins,
  and the batch `list_reactions_for_messages/1` helper added in T6.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: unique_slug(), kind: "channel"}

    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp create_participant(space_id, attrs \\ %{}) do
    default = %{
      participant_type: "user",
      participant_id: Ecto.UUID.generate(),
      joined_at: DateTime.utc_now()
    }

    {:ok, p} = Chat.add_participant(space_id, Map.merge(default, attrs))
    p
  end

  defp create_message(space_id, participant_id, attrs \\ %{}) do
    default = %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: "hello"
    }

    {:ok, msg} = Chat.post_message(Map.merge(default, attrs))
    msg
  end

  defp unique_slug do
    "test-#{System.unique_integer([:positive])}"
  end

  # ── human_content/1 (task 01a199c7 stage 1) ──────────────────────────────────

  describe "human_content/1" do
    alias Platform.Federation.Peers.Ingest
    alias Platform.Federation.Peers.Peer
    alias Platform.Mail.Account
    alias Platform.Mail.Inbound
    alias Platform.Mail.InboundMessage
    alias Platform.Security.ExternalContent

    defp federated_content(body) do
      Ingest.render_content(%Peer{display_name: "Red Star"}, %{content: body, author_name: "Pat"})
    end

    defp stored_message(content, metadata) do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id, %{content: content, metadata: metadata})
      Platform.Repo.get!(Platform.Chat.Message, msg.id)
    end

    defp email_content(body) do
      Inbound.render_content(
        %Account{name: "Ops", username: "ops@example.test", senders: []},
        %InboundMessage{
          from_address: "Recruiter <recruiter@corp.test>",
          to_addresses: ["ops@example.test"],
          subject: "Hello",
          message_id_header: "<abc@corp.test>",
          received_at: ~U[2026-11-01 12:00:00.000000Z]
        },
        %{text: body}
      )
    end

    test "a federation_inbound message shows only the peer's body" do
      content = federated_content("Hello from Red Star\n\nsecond paragraph")
      msg = stored_message(content, %{"source" => "federation_inbound"})

      # the stored (agent) form is untouched
      assert msg.content == content
      assert msg.content =~ ExternalContent.warning()

      assert Chat.human_content(msg) == "Hello from Red Star\n\nsecond paragraph"
    end

    test "inbound email passes through byte-identical" do
      content = email_content("Dear team,\n\nplease call me.")
      assert content =~ ExternalContent.warning()

      msg = stored_message(content, %{"source" => "email_inbound"})
      assert Chat.human_content(msg) === content
    end

    test "only the federation_inbound source unwraps, even for federation-shaped content" do
      content = federated_content("pasted")

      # positive control: the same content does unwrap under the federation source
      assert Chat.human_content(%{
               content: content,
               metadata: %{"source" => "federation_inbound"}
             }) ==
               "pasted"

      for metadata <- [%{"source" => "email_inbound"}, %{}, %{"source" => nil}, nil, "x"] do
        assert Chat.human_content(%{content: content, metadata: metadata}) === content,
               inspect(metadata)
      end

      email_msg = stored_message(content, %{"source" => "email_inbound"})
      assert Chat.human_content(email_msg) === content
    end

    test "nil content stays nil" do
      assert Chat.human_content(%{content: nil, metadata: %{"source" => "federation_inbound"}}) ==
               nil

      assert Chat.human_content(%{content: nil, metadata: %{}}) == nil
    end
  end

  # ── Threads ───────────────────────────────────────────────────────────────────

  describe "create_thread/2 and get_thread_for_message/1" do
    test "creates a thread anchored to a parent message" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      {:ok, thread} =
        Chat.create_thread(space.id, %{parent_message_id: msg.id, title: "Discussion"})

      assert thread.space_id == space.id
      assert thread.parent_message_id == msg.id
      assert thread.title == "Discussion"
    end

    test "get_thread_for_message/1 returns the thread by parent message" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      {:ok, thread} = Chat.create_thread(space.id, %{parent_message_id: msg.id})

      found = Chat.get_thread_for_message(msg.id)
      assert found.id == thread.id
    end

    test "get_thread_for_message/1 returns nil when no thread exists" do
      assert Chat.get_thread_for_message(Ecto.UUID.generate()) == nil
    end

    test "thread messages are posted with thread_id" do
      space = create_space()
      p = create_participant(space.id)
      parent_msg = create_message(space.id, p.id)

      {:ok, thread} = Chat.create_thread(space.id, %{parent_message_id: parent_msg.id})

      {:ok, reply} =
        Chat.post_message(%{
          space_id: space.id,
          thread_id: thread.id,
          participant_id: p.id,
          content_type: "text",
          content: "a reply"
        })

      assert reply.thread_id == thread.id

      thread_msgs = Chat.list_messages(space.id, thread_id: thread.id)
      assert length(thread_msgs) == 1
      assert hd(thread_msgs).id == reply.id
    end

    test "list_messages/2 with top_level_only excludes thread replies" do
      space = create_space()
      participant = create_participant(space.id)
      top_level = create_message(space.id, participant.id, %{content: "top-level"})

      {:ok, thread} = Chat.create_thread(space.id, %{parent_message_id: top_level.id})

      {:ok, _reply} =
        Chat.post_message(%{
          space_id: space.id,
          thread_id: thread.id,
          participant_id: participant.id,
          content_type: "text",
          content: "thread-only"
        })

      channel_messages = Chat.list_messages(space.id, top_level_only: true)

      assert Enum.map(channel_messages, & &1.id) == [top_level.id]
      assert Enum.all?(channel_messages, &is_nil(&1.thread_id))
    end
  end

  # ── Batch message fetch ──────────────────────────────────────────────────────

  describe "get_messages_by_ids/1" do
    test "returns matching messages, drops missing ids, ignores deleted" do
      space = create_space()
      other_space = create_space()
      p = create_participant(space.id)
      p_other = create_participant(other_space.id)

      m1 = create_message(space.id, p.id, %{content: "one"})
      m2 = create_message(space.id, p.id, %{content: "two"})
      m_other = create_message(other_space.id, p_other.id, %{content: "elsewhere"})

      # Soft-delete m2 to confirm it's filtered out
      {:ok, _} =
        m2
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Platform.Repo.update()

      missing_id = Ecto.UUID.generate()

      result = Chat.get_messages_by_ids([m1.id, m2.id, m_other.id, missing_id])
      result_ids = MapSet.new(result, & &1.id)

      # m1 included; m2 excluded (deleted); m_other included (cross-space OK);
      # missing_id silently dropped
      assert MapSet.member?(result_ids, m1.id)
      refute MapSet.member?(result_ids, m2.id)
      assert MapSet.member?(result_ids, m_other.id)
      refute MapSet.member?(result_ids, missing_id)
      assert length(result) == 2
    end

    test "returns [] for empty input without a DB query" do
      assert Chat.get_messages_by_ids([]) == []
    end
  end

  describe "list_messages/2 :order" do
    setup do
      space = create_space()
      p = create_participant(space.id)

      messages =
        for i <- 1..40 do
          create_message(space.id, p.id, %{content: "m-#{i}"})
        end

      %{space: space, messages: messages}
    end

    test "defaults to newest-first and, with :after_id, jumps to the live tail", ctx do
      cursor = Enum.at(ctx.messages, 4)

      got = Chat.list_messages(ctx.space.id, after_id: cursor.id, limit: 5)

      # DESC orders BEFORE the limit, so this is the newest 5 in the whole
      # space — deliberately NOT contiguous with the cursor. That's the
      # right shape for "catch me up to the live tail" and the reason the
      # anchored window needs the option below.
      assert Enum.map(got, & &1.id) ==
               ctx.messages |> Enum.take(-5) |> Enum.reverse() |> Enum.map(& &1.id)
    end

    test "order: :asc with :after_id returns the messages contiguous with the cursor", ctx do
      cursor = Enum.at(ctx.messages, 4)

      got = Chat.list_messages(ctx.space.id, after_id: cursor.id, limit: 5, order: :asc)

      assert Enum.map(got, & &1.id) ==
               ctx.messages |> Enum.slice(5, 5) |> Enum.map(& &1.id)
    end

    test "an unrecognised :order value falls back to :desc rather than crashing", ctx do
      got = Chat.list_messages(ctx.space.id, limit: 3, order: :sideways)

      assert Enum.map(got, & &1.id) ==
               ctx.messages |> Enum.take(-3) |> Enum.reverse() |> Enum.map(& &1.id)
    end
  end

  # ── Space lookup (org-scoped slug) ──────────────────────────────────────────

  describe "get_space_by_slug/2 with :org_id" do
    # The lookup contract: when `:org_id` is passed, the partial unique index
    # `chat_spaces_unique_org_slug` guarantees a single deterministic match.
    # When `:org_id` is absent the legacy oldest-row behavior is preserved so
    # every pre-existing caller keeps working unchanged.
    #
    # All four assertions below are needed because each exercises a distinct
    # code branch in the new arity-2 function — drop one and we lose the
    # ability to catch a regression in that branch.

    test "scopes the match to the supplied org_id" do
      org_a = insert_org()
      org_b = insert_org()

      {:ok, space_a} =
        Chat.create_space(%{name: "General", slug: "general", kind: "channel", org_id: org_a.id})

      {:ok, space_b} =
        Chat.create_space(%{name: "General", slug: "general", kind: "channel", org_id: org_b.id})

      assert %Platform.Chat.Space{id: id_a} =
               Chat.get_space_by_slug("general", org_id: org_a.id)

      assert id_a == space_a.id

      assert %Platform.Chat.Space{id: id_b} =
               Chat.get_space_by_slug("general", org_id: org_b.id)

      assert id_b == space_b.id
    end

    test "preserves the legacy oldest-row behavior when :org_id is absent" do
      # Three rows sharing slug "general": two scoped to different orgs, one
      # unowned (org_id NULL, the DM / legacy shape). The no-opt call should
      # return the oldest row by inserted_at regardless of org_id — that's
      # the back-compat contract every existing caller depends on.
      org_a = insert_org()
      org_b = insert_org()

      {:ok, oldest} =
        Chat.create_space(%{name: "General", slug: "general", kind: "channel", org_id: org_a.id})

      # Force a later inserted_at to make ordering deterministic.
      Process.sleep(5)

      {:ok, _middle} =
        Chat.create_space(%{name: "General", slug: "general", kind: "channel", org_id: org_b.id})

      Process.sleep(5)

      {:ok, _newest} =
        Chat.create_space(%{name: "General", slug: "general", kind: "channel"})

      assert %Platform.Chat.Space{id: id} = Chat.get_space_by_slug("general")
      assert id == oldest.id
    end

    test "returns nil for an org_id that owns no row with that slug" do
      org_a = insert_org()
      org_b = insert_org()

      {:ok, _space} =
        Chat.create_space(%{name: "General", slug: "general", kind: "channel", org_id: org_a.id})

      assert Chat.get_space_by_slug("general", org_id: org_b.id) == nil
    end

    test "the partial unique index rejects a second (org_id, slug) collision" do
      org = insert_org()

      {:ok, _first} =
        Chat.create_space(%{name: "General", slug: "general", kind: "channel", org_id: org.id})

      # `Chat.Space.changeset/2` now declares
      # `unique_constraint(:slug, name: :chat_spaces_unique_org_slug)`
      # alongside the DB-layer partial unique index, so the second insert
      # surfaces as a clean `{:error, %Changeset{}}` instead of a raw
      # `Ecto.ConstraintError`. The constraint is doing its job either
      # way; the changeset shape is the one callers can pattern-match
      # against.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Chat.create_space(%{
                 name: "General Duplicate",
                 slug: "general",
                 kind: "channel",
                 org_id: org.id
               })

      assert {"has already been taken", _} = changeset.errors[:slug]
    end
  end

  # Inline org helper — the chat suite doesn't otherwise touch tenancy, and
  # pulling in a fixtures module to seed two rows wouldn't earn its keep.
  # Parents every test org under the seeded Acme root to satisfy the
  # `orgs_single_root` partial unique index (a second `parent_org_id IS NULL`
  # would be rejected at the DB layer).
  defp insert_org do
    n = System.unique_integer([:positive])
    acme = Platform.Tenancy.get_org_by_slug!("acme")

    Platform.Repo.insert!(%Platform.Tenancy.Org{
      name: "Org #{n}",
      slug: "org-#{n}",
      parent_org_id: acme.id
    })
  end

  # ── Reactions ─────────────────────────────────────────────────────────────────

  describe "add_reaction/1 and remove_reaction/3" do
    test "adds a reaction to a message" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      {:ok, reaction} =
        Chat.add_reaction(%{
          message_id: msg.id,
          participant_id: p.id,
          emoji: "👍"
        })

      assert reaction.message_id == msg.id
      assert reaction.emoji == "👍"
    end

    test "removes a reaction" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      {:ok, _} = Chat.add_reaction(%{message_id: msg.id, participant_id: p.id, emoji: "❤️"})

      assert {:ok, _} = Chat.remove_reaction(msg.id, p.id, "❤️")
      assert Chat.list_reactions(msg.id) == []
    end

    test "remove_reaction returns :not_found for absent reaction" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      assert {:error, :not_found} = Chat.remove_reaction(msg.id, p.id, "🎉")
    end
  end

  describe "list_reactions_for_messages/1" do
    test "returns empty map for empty list" do
      assert Chat.list_reactions_for_messages([]) == %{}
    end

    test "returns reactions grouped by message_id" do
      space = create_space()
      p1 = create_participant(space.id)
      p2 = create_participant(space.id)
      msg1 = create_message(space.id, p1.id)
      msg2 = create_message(space.id, p1.id)

      {:ok, _} = Chat.add_reaction(%{message_id: msg1.id, participant_id: p1.id, emoji: "👍"})
      {:ok, _} = Chat.add_reaction(%{message_id: msg1.id, participant_id: p2.id, emoji: "👍"})
      {:ok, _} = Chat.add_reaction(%{message_id: msg1.id, participant_id: p1.id, emoji: "❤️"})
      {:ok, _} = Chat.add_reaction(%{message_id: msg2.id, participant_id: p2.id, emoji: "😂"})

      result = Chat.list_reactions_for_messages([msg1.id, msg2.id])

      msg1_reactions = result[msg1.id]
      msg2_reactions = result[msg2.id]

      assert length(msg1_reactions) == 3
      assert length(msg2_reactions) == 1
      assert hd(msg2_reactions).emoji == "😂"
    end

    test "omits message IDs with no reactions" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      result = Chat.list_reactions_for_messages([msg.id])
      refute Map.has_key?(result, msg.id)
    end
  end

  # ── Search ────────────────────────────────────────────────────────────────────

  describe "search_messages/3" do
    test "returns ranked matches with highlighted excerpts" do
      space = create_space()
      other_space = create_space()
      participant = create_participant(space.id)
      other_participant = create_participant(other_space.id)

      repeated =
        create_message(space.id, participant.id, %{
          content: "Phoenix search makes Phoenix chat search feel instant"
        })

      single =
        create_message(space.id, participant.id, %{
          content: "Phoenix presence keeps the room feeling live"
        })

      _non_match =
        create_message(space.id, participant.id, %{content: "Completely unrelated note"})

      _other_space_match =
        create_message(other_space.id, other_participant.id, %{content: "Phoenix only elsewhere"})

      results = Chat.search_messages(space.id, "phoenix", limit: 10)

      assert Enum.map(results, & &1.id) == [repeated.id, single.id]
      assert Enum.all?(results, &is_float(&1.search_rank))
      assert Enum.all?(results, &(&1.search_rank > 0.0))
      assert results |> hd() |> Map.fetch!(:search_headline) =~ "<mark>Phoenix</mark>"
    end

    test "returns an empty list for blank queries" do
      space = create_space()
      assert Chat.search_messages(space.id, "   ") == []
    end
  end

  # ── Attachments ───────────────────────────────────────────────────────────────

  describe "post_message_with_attachments/2" do
    test "creates the message and attachments in one transaction" do
      space = create_space()
      participant = create_participant(space.id)

      {:ok, message, attachments} =
        Chat.post_message_with_attachments(
          %{
            space_id: space.id,
            participant_id: participant.id,
            content_type: "text",
            content: "see attached"
          },
          [
            %{
              filename: "notes.txt",
              content_type: "text/plain",
              byte_size: 12,
              storage_key: "chat/test/notes.txt"
            }
          ]
        )

      assert message.content == "see attached"
      assert length(attachments) == 1
      assert hd(attachments).message_id == message.id
      assert hd(attachments).filename == "notes.txt"
    end
  end

  describe "create_attachment/1 (ADR 0039)" do
    test "accepts a space_id-only payload (no message_id)" do
      space = create_space()

      assert {:ok, attachment} =
               Chat.create_attachment(%{
                 space_id: space.id,
                 filename: "orphan.txt",
                 content_type: "text/plain",
                 byte_size: 3,
                 storage_key: "chat/test/orphan.txt"
               })

      assert attachment.space_id == space.id
      assert is_nil(attachment.message_id)
      assert attachment.state == "ready"
    end
  end

  describe "get_visible_attachment/1 (ADR 0039)" do
    test "returns an attachment with message_id: nil when space-scoped" do
      space = create_space()

      {:ok, attachment} =
        Chat.create_attachment(%{
          space_id: space.id,
          filename: "canvas-only.png",
          content_type: "image/png",
          byte_size: 42,
          storage_key: "chat/test/canvas-only.png"
        })

      assert %{id: id, message_id: nil} = attachment
      assert %{id: ^id} = Chat.get_visible_attachment(id)
    end

    test "still hides attachments whose owning message is soft-deleted" do
      space = create_space()
      participant = create_participant(space.id)
      message = create_message(space.id, participant.id)

      {:ok, attachment} =
        Chat.create_attachment(%{
          message_id: message.id,
          space_id: space.id,
          filename: "deleted.txt",
          content_type: "text/plain",
          byte_size: 3,
          storage_key: "chat/test/deleted.txt"
        })

      {:ok, _} = Chat.delete_message(message)

      assert Chat.get_visible_attachment(attachment.id) == nil
    end
  end

  describe "list_attachments_for_messages/1" do
    test "returns attachments grouped by message_id" do
      space = create_space()
      participant = create_participant(space.id)
      message_one = create_message(space.id, participant.id)
      message_two = create_message(space.id, participant.id)

      {:ok, _} =
        Chat.create_attachment(%{
          message_id: message_one.id,
          filename: "one.txt",
          content_type: "text/plain",
          byte_size: 3,
          storage_key: "chat/test/one.txt"
        })

      {:ok, _} =
        Chat.create_attachment(%{
          message_id: message_one.id,
          filename: "two.txt",
          content_type: "text/plain",
          byte_size: 3,
          storage_key: "chat/test/two.txt"
        })

      {:ok, _} =
        Chat.create_attachment(%{
          message_id: message_two.id,
          filename: "three.txt",
          content_type: "text/plain",
          byte_size: 5,
          storage_key: "chat/test/three.txt"
        })

      result = Chat.list_attachments_for_messages([message_one.id, message_two.id])

      assert Enum.map(result[message_one.id], & &1.filename) == ["one.txt", "two.txt"]
      assert Enum.map(result[message_two.id], & &1.filename) == ["three.txt"]
    end
  end

  # ── Pins ──────────────────────────────────────────────────────────────────────

  describe "message_read_by_user?/2" do
    # ONE fixture, TWO messages of distinct UUIDv7 ids with the watermark on the
    # first. A one-message fixture cannot tell a correct predicate from one that
    # returns a constant — the pair is the whole point.
    test "reads true at or below the watermark and false above it" do
      space = create_space()
      user = create_participant(space.id)
      other = create_participant(space.id)

      earlier = create_message(space.id, other.id)
      later = create_message(space.id, other.id)
      assert earlier.id < later.id

      Chat.mark_space_read(user.id, earlier.id)

      assert Chat.message_read_by_user?(earlier.id, user.participant_id)
      refute Chat.message_read_by_user?(later.id, user.participant_id)
    end

    test "false when the watermark is nil (never read anything)" do
      space = create_space()
      user = create_participant(space.id)
      other = create_participant(space.id)
      msg = create_message(space.id, other.id)

      refute Chat.message_read_by_user?(msg.id, user.participant_id)
    end

    test "false when the user has no participant row in the message's space" do
      space = create_space()
      other = create_participant(space.id)
      msg = create_message(space.id, other.id)

      refute Chat.message_read_by_user?(msg.id, Ecto.UUID.generate())
    end

    test "false when the message is missing, or either id is unresolvable" do
      space = create_space()
      user = create_participant(space.id)

      refute Chat.message_read_by_user?(Ecto.UUID.generate(), user.participant_id)
      refute Chat.message_read_by_user?("not-a-uuid", user.participant_id)
      refute Chat.message_read_by_user?(Ecto.UUID.generate(), "not-a-uuid")
      refute Chat.message_read_by_user?(nil, user.participant_id)
    end
  end

  describe "unread_counts_for_user/1" do
    test "counts messages from other participants after last_read" do
      space = create_space()
      user = create_participant(space.id)
      other = create_participant(space.id)

      # Post a message from the other user, then mark it as read
      msg1 = create_message(space.id, other.id)
      Chat.mark_space_read(user.id, msg1.id)

      # Post another message from the other user (unread)
      _msg2 = create_message(space.id, other.id)

      counts = Chat.unread_counts_for_user(user.participant_id)
      assert Map.get(counts, space.id, 0) == 1
    end

    test "does not count own messages as unread" do
      space = create_space()
      user = create_participant(space.id)
      other = create_participant(space.id)

      # Post a message from the other user, mark as read
      msg1 = create_message(space.id, other.id)
      Chat.mark_space_read(user.id, msg1.id)

      # Now user posts their own message — should NOT be counted as unread
      _own_msg = create_message(space.id, user.id)

      counts = Chat.unread_counts_for_user(user.participant_id)
      assert Map.get(counts, space.id, 0) == 0
    end

    test "counts only non-own messages when mixed" do
      space = create_space()
      user = create_participant(space.id)
      other = create_participant(space.id)

      # Mark a starting point
      seed = create_message(space.id, other.id)
      Chat.mark_space_read(user.id, seed.id)

      # User sends 2 own messages, other user sends 1
      _own1 = create_message(space.id, user.id)
      _own2 = create_message(space.id, user.id)
      _theirs = create_message(space.id, other.id)

      counts = Chat.unread_counts_for_user(user.participant_id)
      assert Map.get(counts, space.id, 0) == 1
    end
  end

  describe "pin_message/2 and unpin_message/3" do
    test "pins a message in a space" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      {:ok, pin} =
        Chat.pin_message({:user, p.participant_id}, %{space_id: space.id, message_id: msg.id})

      assert pin.space_id == space.id
      assert pin.message_id == msg.id
      assert pin.pinned_by == p.id
    end

    test "unpins a message" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      {:ok, _} =
        Chat.pin_message({:user, p.participant_id}, %{space_id: space.id, message_id: msg.id})

      assert {:ok, _} = Chat.unpin_message({:user, p.participant_id}, space.id, msg.id)
      assert Chat.list_pins(space.id) == []
    end

    test "unpin_message returns :not_found when not pinned" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      assert {:error, :not_found} =
               Chat.unpin_message({:user, p.participant_id}, space.id, msg.id)
    end

    test "list_pins returns all pinned messages for a space" do
      space = create_space()
      p = create_participant(space.id)
      msg1 = create_message(space.id, p.id)
      msg2 = create_message(space.id, p.id)

      {:ok, _} =
        Chat.pin_message({:user, p.participant_id}, %{space_id: space.id, message_id: msg1.id})

      {:ok, _} =
        Chat.pin_message({:user, p.participant_id}, %{space_id: space.id, message_id: msg2.id})

      pins = Chat.list_pins(space.id)
      assert length(pins) == 2
    end
  end

  describe "assign_space_org/2 (chat sidebar v2, Stage 1)" do
    alias Platform.Tenancy

    test "assigns a channel to an org via the org_id FK" do
      space = create_space()
      acme = Tenancy.get_org_by_slug!("acme")

      assert {:ok, updated} = Chat.assign_space_org(space, acme.id)
      assert updated.org_id == acme.id
      assert Chat.get_space(space.id).org_id == acme.id
    end

    test "nil clears an existing org assignment" do
      acme = Tenancy.get_org_by_slug!("acme")
      space = create_space()
      {:ok, space} = Chat.assign_space_org(space, acme.id)

      assert {:ok, cleared} = Chat.assign_space_org(space, nil)
      assert is_nil(cleared.org_id)
    end

    test "rejects a non-existent org id via the FK constraint" do
      space = create_space()

      assert {:error, %Ecto.Changeset{} = cs} =
               Chat.assign_space_org(space, Ecto.UUID.generate())

      assert Keyword.has_key?(cs.errors, :org_id)
    end
  end

  describe "create_space/1 historian auto-join" do
    alias Platform.Agents.Agent
    alias Platform.Repo
    alias Platform.Roles

    import ExUnit.CaptureLog

    # Seed a historian-role agent and pin it via the role_assignments
    # table so `Platform.Roles.agent_id_for_role("historian")` resolves
    # to this agent's id. Matches stage-1's resolver contract.
    #
    # `system_events: ["daily_summary"]` is set for parity with the
    # legacy SystemEventScheduler query even though the resolver now
    # keys off role_assignments — belt-and-suspenders in case any
    # sibling code path still consults the agents table directly.
    defp create_historian_agent(overrides \\ %{}) do
      suffix = System.unique_integer([:positive])

      attrs =
        Map.merge(
          %{
            slug: "historian-#{suffix}",
            name: "Historian #{suffix}",
            status: "active",
            kind: "native",
            metadata: %{"system_events" => ["daily_summary"]}
          },
          overrides
        )

      agent =
        %Agent{}
        |> Agent.changeset(attrs)
        |> Repo.insert!()

      {:ok, _} = Roles.assign_role("historian", agent.id)
      agent
    end

    test "channel with active historian → historian joined as heartbeat participant" do
      historian = create_historian_agent()
      space = create_space()

      participants = Chat.list_participants(space.id, participant_type: "agent")

      assert [p] = participants
      assert p.participant_id == historian.id
      assert p.participant_type == "agent"
      assert p.attention_mode == "heartbeat"
    end

    test "DM does not auto-join historian" do
      _historian = create_historian_agent()

      # `created_by` is FK-enforced against users; omit it and let the
      # kind: "dm" clause of the changeset accept a slug-less space.
      {:ok, dm} = Chat.create_space(%{kind: "dm", is_direct: true})

      assert Chat.list_participants(dm.id, participant_type: "agent") == []
    end

    test "space with slug beginning system- does not auto-join historian" do
      _historian = create_historian_agent()

      {:ok, space} =
        Chat.create_space(%{
          name: "System Higgins",
          slug: "system-higgins-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      assert Chat.list_participants(space.id, participant_type: "agent") == []
    end

    test "no historian pinned → create_space succeeds with no agent participant" do
      # No historian seeded — resolver returns nil, hook silently skips.
      space = create_space()

      assert Chat.list_participants(space.id, participant_type: "agent") == []
    end

    test "idempotent when historian already a participant" do
      historian = create_historian_agent()
      space = create_space()

      # First create_space already attached the historian via the hook.
      # Simulate a second attach attempt (as maybe_add_historian would
      # via its dedupe path) — should return {:ok, existing} without
      # creating a duplicate row.
      assert {:ok, _existing} =
               Chat.add_agent_participant(space.id, historian.id, attention_mode: "heartbeat")

      participants = Chat.list_participants(space.id, participant_type: "agent")
      assert length(participants) == 1
      assert hd(participants).participant_id == historian.id
    end

    test "add_agent_participant failure does not crash create_space" do
      # Reproduce the failure branch by pointing role_assignments at a
      # non-existent agent id. `add_agent_participant(space.id, id)`
      # will call `Repo.get(Agent, id)`, get nil, and return
      # {:error, :not_found} — exactly the failure the hook must
      # swallow without breaking space creation.
      #
      # The role_assignments FK to agents is DB-enforced, so we
      # temporarily disable session replication to insert a row that
      # references a bogus id. This is contained within the sandbox
      # transaction — no leak between tests.
      bogus_id = Ecto.UUID.generate()

      # `SET LOCAL` is transaction-scoped, so it evaporates when the
      # sandbox rolls back — no leak to sibling tests reusing the
      # connection. Requires the test DB user to be superuser (which
      # `PGUSER=postgres` in config/test.exs satisfies).
      Repo.query!("SET LOCAL session_replication_role = 'replica'")

      Repo.query!(
        "INSERT INTO role_assignments (id, role_key, agent_id, inserted_at, updated_at) " <>
          "VALUES ($1, 'historian', $2, NOW(), NOW())",
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(bogus_id)
        ]
      )

      Repo.query!("SET LOCAL session_replication_role = 'origin'")

      # Sanity: resolver returns the bogus id.
      assert Roles.agent_id_for_role("historian") == bogus_id

      log =
        capture_log(fn ->
          assert {:ok, %Platform.Chat.Space{} = space} =
                   Chat.create_space(%{
                     name: "Resilient",
                     slug: unique_slug(),
                     kind: "channel"
                   })

          # No participant was inserted because add_agent_participant
          # returned {:error, :not_found} before touching participants.
          assert Chat.list_participants(space.id, participant_type: "agent") == []
        end)

      assert log =~ "[Chat.create_space] historian attach failed"
      assert log =~ "not_found"
    end
  end

  # ── Pin-propagation on sponsor @-mention (task 019f62a1 stage 3) ──────────
  #
  # A sponsor @-mentioning a user or agent in the task's execution space
  # adds a `task_chat_pins` row for the mentioned participant via
  # `Platform.Tasks.ChatPins.pin/3`. Non-sponsor mentions do NOT propagate,
  # and channels/DMs are exempt — the exec-space guard is the only gate.
  # `pin/3`'s idempotency short-circuit means the second occurrence of the
  # same token in one message doesn't re-broadcast; `refute_receive` locks
  # that contract in.
  describe "sponsor @-mention pin propagation (task 019f62a1 stage 3)" do
    alias Platform.Chat.PubSub, as: ChatPubSub
    alias Platform.Orchestration.ExecutionSpace
    alias Platform.Tasks
    alias Platform.Tasks.{ChatPin, ChatPins}

    import Ecto.Query

    setup do
      {:ok, project} =
        Tasks.create_project(%{name: "PinProp #{System.unique_integer([:positive])}"})

      sponsor = insert_user(email: "sponsor-#{System.unique_integer([:positive])}@example.com")
      alice = insert_user(email: "alice-#{System.unique_integer([:positive])}@example.com")
      bob = insert_user(email: "bob-#{System.unique_integer([:positive])}@example.com")

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsored task",
          sponsor_user_id: sponsor.id
        })

      # Subscribe BEFORE the setup pin so the drain-broadcast below has
      # something to hit — subscribing after the pin lets the initial
      # broadcast escape into the void and every test's first
      # `assert_receive` picks up the phantom row instead.
      :ok = ChatPubSub.subscribe_spaces()
      on_exit(fn -> ChatPubSub.unsubscribe_spaces() end)

      # Materialise the exec space via the same lazy path production uses;
      # this also seeds the sponsor's own pin row (unrelated to what the
      # tests below assert about mention propagation).
      {:ok, %{space: exec_space}} =
        ChatPins.pin(task.id, %{kind: "user", id: sponsor.email}, sponsor.email)

      # Drain the sponsor's own :task_pin_added broadcast from the setup
      # pin so each test starts from a clean mailbox.
      assert_receive {:task_pin_added, _}

      %{
        project: project,
        task: task,
        sponsor: sponsor,
        alice: alice,
        bob: bob,
        exec_space: exec_space
      }
    end

    defp insert_user(opts) do
      n = System.unique_integer([:positive])

      Platform.Repo.insert!(%Platform.Accounts.User{
        name: Keyword.get(opts, :name, "User #{n}"),
        email: Keyword.fetch!(opts, :email),
        oidc_sub: "sub-#{n}"
      })
    end

    defp participant_for_user(space_id, %Platform.Accounts.User{} = user) do
      {:ok, p} =
        Chat.add_participant(space_id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })

      p
    end

    defp count_pins_for(task_id, kind, id) do
      Platform.Repo.aggregate(
        from(p in ChatPin,
          where:
            p.task_id == ^task_id and p.participant_kind == ^kind and
              p.participant_id == ^id
        ),
        :count
      )
    end

    test "sponsor mentioning @[alice] in the exec space pins alice", %{
      task: task,
      sponsor: sponsor,
      alice: alice,
      exec_space: exec_space
    } do
      sponsor_p = participant_for_user(exec_space.id, sponsor)

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: exec_space.id,
          participant_id: sponsor_p.id,
          content_type: "text",
          content: "hey @[#{alice.email}] take a look"
        })

      assert count_pins_for(task.id, "user", alice.email) == 1

      assert_receive {:task_pin_added,
                      %{
                        task_id: broadcast_task_id,
                        participant_kind: "user",
                        participant_id: alice_email_broadcast
                      }}

      assert broadcast_task_id == task.id
      assert alice_email_broadcast == alice.email
    end

    test "same @[alice] mentioned twice in one message does NOT re-broadcast", %{
      task: task,
      sponsor: sponsor,
      alice: alice,
      exec_space: exec_space
    } do
      sponsor_p = participant_for_user(exec_space.id, sponsor)

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: exec_space.id,
          participant_id: sponsor_p.id,
          content_type: "text",
          content: "@[#{alice.email}] again @[#{alice.email}] please"
        })

      # Exactly one row inserted.
      assert count_pins_for(task.id, "user", alice.email) == 1

      # Exactly one broadcast — the context-layer short-circuit fires on
      # the second call.
      assert_receive {:task_pin_added, %{participant_id: alice_broadcast}}
      assert alice_broadcast == alice.email
      refute_receive {:task_pin_added, %{participant_id: ^alice_broadcast}}, 100
    end

    test "non-sponsor mentioning @[bob] in the exec space does NOT pin bob", %{
      task: task,
      alice: alice,
      bob: bob,
      exec_space: exec_space
    } do
      # Alice is not the sponsor. Her mention must reinvite agents (a
      # separate contract) but must NOT propagate a pin.
      alice_p = participant_for_user(exec_space.id, alice)

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: exec_space.id,
          participant_id: alice_p.id,
          content_type: "text",
          content: "@[#{bob.email}] fyi"
        })

      assert count_pins_for(task.id, "user", bob.email) == 0

      bob_email = bob.email
      refute_receive {:task_pin_added, %{participant_id: ^bob_email}}, 100
    end

    test "sponsor mention in a channel space (not execution) does NOT pin", %{
      sponsor: sponsor,
      alice: alice
    } do
      # Plain channel — pin-propagation is execution-space-only. Even the
      # sponsor's mention must be a no-op for pins here.
      channel = create_space()
      sponsor_p = participant_for_user(channel.id, sponsor)

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: channel.id,
          participant_id: sponsor_p.id,
          content_type: "text",
          content: "@[#{alice.email}] in the channel"
        })

      # No pins for alice at all — the channel isn't tied to a task.
      assert Platform.Repo.aggregate(
               from(p in ChatPin, where: p.participant_id == ^alice.email),
               :count
             ) == 0

      refute_receive {:task_pin_added, _}, 100
    end

    test "unknown @[token] in the exec space is silently skipped", %{
      task: task,
      sponsor: sponsor,
      exec_space: exec_space
    } do
      sponsor_p = participant_for_user(exec_space.id, sponsor)

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: exec_space.id,
          participant_id: sponsor_p.id,
          content_type: "text",
          content: "hey @[ghost@example.com] where are you"
        })

      # Sponsor's own pin from setup persists; no new row for the ghost.
      assert Platform.Repo.aggregate(
               from(p in ChatPin, where: p.task_id == ^task.id),
               :count
             ) == 1

      refute_receive {:task_pin_added, _}, 100
    end

    test "sponsor mentioning an agent by slug pins the agent", %{
      task: task,
      sponsor: sponsor,
      exec_space: exec_space
    } do
      n = System.unique_integer([:positive])

      agent =
        Platform.Repo.insert!(%Platform.Agents.Agent{
          name: "Higgins #{n}",
          slug: "higgins-#{n}",
          status: "active"
        })

      sponsor_p = participant_for_user(exec_space.id, sponsor)

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: exec_space.id,
          participant_id: sponsor_p.id,
          content_type: "text",
          content: "@[#{agent.slug}] handle this"
        })

      assert count_pins_for(task.id, "agent", agent.slug) == 1

      assert_receive {:task_pin_added,
                      %{
                        participant_kind: "agent",
                        participant_id: broadcast_slug
                      }}

      assert broadcast_slug == agent.slug

      # Guard: `ExecutionSpace.find_or_create/1` idempotency held — no
      # duplicate exec space materialised on the second pin call.
      assert ExecutionSpace.find_by_task_id(task.id).id == exec_space.id
    end
  end

  describe "participant?/2" do
    test "true for a seeded user participant of the space" do
      space = create_space()
      user_id = Ecto.UUID.generate()
      create_participant(space.id, %{participant_id: user_id})

      assert Chat.participant?(space.id, user_id)
    end

    test "false for a user who is not a participant" do
      space = create_space()
      create_participant(space.id, %{participant_id: Ecto.UUID.generate()})

      refute Chat.participant?(space.id, Ecto.UUID.generate())
    end

    test "false for an agent-type row sharing the same id (user-only match)" do
      space = create_space()
      shared_id = Ecto.UUID.generate()
      create_participant(space.id, %{participant_type: "agent", participant_id: shared_id})

      refute Chat.participant?(space.id, shared_id)
    end

    test "false for non-binary args" do
      refute Chat.participant?(nil, nil)
    end
  end

  describe "get_space_participant/2 (task 01a0cbe0)" do
    test "returns the participant row when it belongs to the space" do
      space = create_space()
      p = create_participant(space.id)

      assert %Chat.Participant{id: id, space_id: space_id} =
               Chat.get_space_participant(space.id, p.id)

      assert id == p.id
      assert space_id == space.id
    end

    test "returns nil for a participant of ANOTHER space" do
      good = create_space()
      foreign = create_space()
      p = create_participant(good.id)

      assert Chat.get_space_participant(foreign.id, p.id) == nil
    end

    test "returns nil for an unknown participant id" do
      space = create_space()
      assert Chat.get_space_participant(space.id, Ecto.UUID.generate()) == nil
    end
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  #
  # THE LOAD-BEARING INPUT IS THE 16-CHARACTER ONE. Do not prune these as
  # duplicates and do not "simplify" them down to `"higgins"` plus a valid
  # UUID — that pair is FULLY GREEN against the bug these guards fix.
  # `Ecto.UUID.cast/1` rejects `"higgins"` on its own, so a suite built from
  # it passes against a bare cast. Only a 16-byte binary discriminates:
  #
  #     Ecto.UUID.cast("higginshigginsxx") == {:ok, "68696767-...-67696e737878"}
  #     Ecto.UUID.dump("higginshigginsxx") == :error
  #
  # i.e. the value clears a cast-only guard and then raises inside Repo.
  describe "UUID boundary: Chat getters are total over their input" do
    @slug_16 "higginshigginsxx"

    test "get_space/1 returns nil for a channel slug rather than raising" do
      # The PR #613 site. `space_id` arrives verbatim from every suite_reply /
      # canvas_list MCP call and from the /chat/:slug URL path segment.
      assert Chat.get_space("higgins") == nil
      assert Chat.get_space(@slug_16) == nil
      assert Chat.get_space("") == nil
      assert Chat.get_space(Ecto.UUID.generate()) == nil
    end

    test "get_space/1 still resolves a real space" do
      space = create_space()
      assert %{id: id} = Chat.get_space(space.id)
      assert id == space.id
    end

    test "get_message/1, get_thread/1, get_canvas/1, get_attachment/1 return nil" do
      for id <- ["higgins", @slug_16, ""] do
        assert Chat.get_message(id) == nil
        assert Chat.get_thread(id) == nil
        assert Chat.get_canvas(id) == nil
        assert Chat.get_canvas_with_deleted(id) == nil
        assert Chat.get_attachment(id) == nil
      end
    end

    test "get_agent_participant/2 returns nil when either id is malformed" do
      space = create_space()
      # participants.space_id and .participant_id are both :binary_id, so
      # EITHER being malformed raises. Assert both positions.
      assert Chat.get_agent_participant(space.id, @slug_16) == nil
      assert Chat.get_agent_participant(@slug_16, Ecto.UUID.generate()) == nil
    end

    test "get_space_participant/2 returns nil when either id is malformed" do
      space = create_space()
      p = create_participant(space.id)

      # Both columns are :binary_id: assert both positions, with the
      # 16-character input that clears a cast-only guard (see above).
      for bad <- ["higgins", @slug_16, ""] do
        assert Chat.get_space_participant(space.id, bad) == nil
        assert Chat.get_space_participant(bad, p.id) == nil
      end
    end

    test "unpin_message/3 reports :not_found for a malformed message id" do
      space = create_space()
      p = create_participant(space.id)

      assert {:error, :not_found} =
               Chat.unpin_message({:user, p.participant_id}, space.id, @slug_16)
    end

    test "add_agent_participant/3 resolves an agent by SLUG, not just by uuid" do
      # The slug fallback matters as much as the guard: `add_participant`'s
      # MCP argument is an agent slug at least as often as a uuid, so
      # returning nil here would turn a working lookup into a silent miss.
      space = create_space()
      agent = create_boundary_agent(%{slug: @slug_16, name: "Higgins"})

      assert {:ok, participant} = Chat.add_agent_participant(space.id, @slug_16)
      assert participant.participant_id == agent.id
    end

    test "add_agent_participant/3 returns :not_found for an unknown slug" do
      space = create_space()
      assert {:error, :not_found} = Chat.add_agent_participant(space.id, "no-such-agent")
    end

    test "add_agent_participant/3 returns :not_found for a malformed space id" do
      agent = create_boundary_agent(%{slug: "boundary-space", name: "Higgins"})
      assert {:error, :not_found} = Chat.add_agent_participant(@slug_16, agent)
    end
  end

  defp create_boundary_agent(attrs) do
    defaults = %{
      name: "Zip",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    {:ok, agent} =
      %Platform.Agents.Agent{}
      |> Platform.Agents.Agent.changeset(Map.merge(defaults, attrs))
      |> Platform.Repo.insert()

    agent
  end
end
