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
  # Parents every test org under the seeded Fabrikam root to satisfy the
  # `orgs_single_root` partial unique index (a second `parent_org_id IS NULL`
  # would be rejected at the DB layer).
  defp insert_org do
    n = System.unique_integer([:positive])
    fabrikam = Platform.Tenancy.get_org_by_slug!("fabrikam")

    Platform.Repo.insert!(%Platform.Tenancy.Org{
      name: "Org #{n}",
      slug: "org-#{n}",
      parent_org_id: fabrikam.id
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

  describe "pin_message/1 and unpin_message/2" do
    test "pins a message in a space" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      {:ok, pin} =
        Chat.pin_message(%{
          space_id: space.id,
          message_id: msg.id,
          pinned_by: p.id
        })

      assert pin.space_id == space.id
      assert pin.message_id == msg.id
    end

    test "unpins a message" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      {:ok, _} = Chat.pin_message(%{space_id: space.id, message_id: msg.id, pinned_by: p.id})

      assert {:ok, _} = Chat.unpin_message(space.id, msg.id)
      assert Chat.list_pins(space.id) == []
    end

    test "unpin_message returns :not_found when not pinned" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      assert {:error, :not_found} = Chat.unpin_message(space.id, msg.id)
    end

    test "list_pins returns all pinned messages for a space" do
      space = create_space()
      p = create_participant(space.id)
      msg1 = create_message(space.id, p.id)
      msg2 = create_message(space.id, p.id)

      {:ok, _} = Chat.pin_message(%{space_id: space.id, message_id: msg1.id, pinned_by: p.id})
      {:ok, _} = Chat.pin_message(%{space_id: space.id, message_id: msg2.id, pinned_by: p.id})

      pins = Chat.list_pins(space.id)
      assert length(pins) == 2
    end
  end

  describe "assign_space_org/2 (chat sidebar v2, Stage 1)" do
    alias Platform.Tenancy

    test "assigns a channel to an org via the org_id FK" do
      space = create_space()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")

      assert {:ok, updated} = Chat.assign_space_org(space, fabrikam.id)
      assert updated.org_id == fabrikam.id
      assert Chat.get_space(space.id).org_id == fabrikam.id
    end

    test "nil clears an existing org assignment" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      space = create_space()
      {:ok, space} = Chat.assign_space_org(space, fabrikam.id)

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
end
