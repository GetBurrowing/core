defmodule Platform.Chat.SpaceLifecycleTest do
  @moduledoc """
  Task 019e95ea stage 1: authorization on archive/unarchive and the
  interaction freeze on archived spaces.

  Two invariants under test:

    1. `archive_space/2` / `unarchive_space/2` allow only Fabrikam admins and
       the space's creator — enforced in the context layer, not the UI.
    2. Every public write path returns `{:error, :space_archived}` against
       an archived space, for humans and agents alike. Execution spaces are
       exempt (orchestration owns their lifecycle and archives them at task
       completion).
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── Helpers ────────────────────────────────────────────────────────────

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "lifecycle-test-#{n}@example.com",
          name: "Lifecycle Test #{n}",
          oidc_sub: "oidc-lifecycle-#{n}"
        },
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp membership!(user, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("fabrikam").id,
      role: role
    })
    |> Repo.insert!()
  end

  defp admin_user! do
    user = create_user!()
    membership!(user, "admin")
    user
  end

  defp member_user! do
    user = create_user!()
    membership!(user, "member")
    user
  end

  defp channel!(attrs \\ %{}) do
    default = %{
      name: "Lifecycle",
      slug: "lifecycle-#{System.unique_integer([:positive, :monotonic])}",
      kind: "channel"
    }

    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp archived_channel!(attrs \\ %{}) do
    space = channel!(attrs)
    {:ok, archived} = Chat.archive_space(space)
    archived
  end

  defp participant!(space_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp message!(space_id, participant_id) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: "pre-archive message"
      })

    msg
  end

  # Live space with a participant + message, then archived — the fixture for
  # freeze tests that need pre-existing content.
  defp archived_with_content! do
    space = channel!()
    participant = participant!(space.id)
    message = message!(space.id, participant.id)
    {:ok, archived} = Chat.archive_space(space)
    {archived, participant, message}
  end

  # ── archive_space/2 + unarchive_space/2 authorization ──────────────────

  describe "archive_space/2 authorization" do
    test "fabrikam admin can archive any channel" do
      admin = admin_user!()
      space = channel!()

      assert {:ok, archived} = Chat.archive_space(admin, space)
      assert %DateTime{} = archived.archived_at
    end

    test "creator can archive their own channel" do
      creator = member_user!()
      space = channel!(%{created_by: creator.id})

      assert {:ok, archived} = Chat.archive_space(creator, space)
      assert %DateTime{} = archived.archived_at
    end

    test "plain member who is not the creator is rejected" do
      member = member_user!()
      space = channel!(%{created_by: create_user!().id})

      assert {:error, :unauthorized} = Chat.archive_space(member, space)
      assert Repo.reload!(space).archived_at == nil
    end

    test "user with no org membership is rejected" do
      stranger = create_user!()
      space = channel!()

      assert {:error, :unauthorized} = Chat.archive_space(stranger, space)
    end

    test "emits the audit telemetry event with the actor" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :chat, :space_archived]
        ])

      admin = admin_user!()
      space = channel!()
      {:ok, _} = Chat.archive_space(admin, space)

      assert_receive {[:platform, :chat, :space_archived], ^ref, _measurements, meta}
      assert meta.actor_id == admin.id
      assert meta.actor_type == "user"
      assert meta.resource_id == space.id
      assert meta.resource_type == "chat_space"
    end
  end

  describe "unarchive_space/2" do
    test "admin can unarchive; archived_at is cleared" do
      admin = admin_user!()
      space = archived_channel!()

      assert {:ok, restored} = Chat.unarchive_space(admin, space)
      assert restored.archived_at == nil
      assert Chat.space_writable?(restored.id)
    end

    test "creator can unarchive their own channel" do
      creator = member_user!()
      space = archived_channel!(%{created_by: creator.id})

      assert {:ok, restored} = Chat.unarchive_space(creator, space)
      assert restored.archived_at == nil
    end

    test "plain non-creator member is rejected" do
      member = member_user!()
      space = archived_channel!(%{created_by: create_user!().id})

      assert {:error, :unauthorized} = Chat.unarchive_space(member, space)
      assert %DateTime{} = Repo.reload!(space).archived_at
    end

    test "emits the audit telemetry event" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :chat, :space_unarchived]
        ])

      admin = admin_user!()
      space = archived_channel!()
      {:ok, _} = Chat.unarchive_space(admin, space)

      assert_receive {[:platform, :chat, :space_unarchived], ^ref, _m, meta}
      assert meta.actor_id == admin.id
    end

    test "clears a cascade child's provenance marker and its own deletion clock" do
      admin = admin_user!()

      # A space hidden by an org cascade carries both the provenance marker
      # (archived_cascade_org_id) and its own deletion clock. Restoring the
      # single child directly must clear BOTH — a live space that keeps a
      # stale marker would be wrongly re-matched on a later org restore.
      cascade_org_id = Tenancy.get_org_by_slug!("fabrikam").id
      now = DateTime.utc_now()

      space =
        channel!()
        |> Ecto.Changeset.change(
          archived_at: now,
          deletion_scheduled_at: now,
          archived_cascade_org_id: cascade_org_id
        )
        |> Repo.update!()

      assert space.archived_cascade_org_id == cascade_org_id

      assert {:ok, restored} = Chat.unarchive_space(admin, space)
      assert is_nil(restored.archived_at)
      assert is_nil(restored.deletion_scheduled_at)
      assert is_nil(restored.archived_cascade_org_id)
    end
  end

  describe "archive_space/1 (system path)" do
    test "still archives without an actor — orchestration relies on this" do
      space = channel!()
      assert {:ok, archived} = Chat.archive_space(space)
      assert %DateTime{} = archived.archived_at
    end

    test "emits audit telemetry with actor_type system" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :chat, :space_archived]
        ])

      space = channel!()
      {:ok, _} = Chat.archive_space(space)

      assert_receive {[:platform, :chat, :space_archived], ^ref, _m, meta}
      assert meta.actor_id == nil
      assert meta.actor_type == "system"
    end
  end

  # ── space_writable?/1 ──────────────────────────────────────────────────

  describe "space_writable?/1" do
    test "true for an active channel" do
      assert Chat.space_writable?(channel!().id)
    end

    test "false for an archived channel" do
      refute Chat.space_writable?(archived_channel!().id)
    end

    test "true for an archived execution space (orchestration exemption)" do
      {:ok, space} =
        Chat.create_space(%{
          name: "exec",
          slug: "exec-#{System.unique_integer([:positive])}",
          kind: "execution"
        })

      {:ok, archived} = Chat.archive_space(space)
      assert Chat.space_writable?(archived.id)
    end

    test "true for an unknown id — the write path surfaces its own error" do
      assert Chat.space_writable?(Ecto.UUID.generate())
    end
  end

  # ── Frozen write paths ─────────────────────────────────────────────────

  describe "writes into an archived channel are frozen" do
    test "post_message/2" do
      {space, participant, _msg} = archived_with_content!()

      assert {:error, :space_archived} =
               Chat.post_message(%{
                 space_id: space.id,
                 participant_id: participant.id,
                 content_type: "text",
                 content: "should not land"
               })
    end

    test "post_message_with_attachments/3" do
      {space, participant, _msg} = archived_with_content!()

      assert {:error, :space_archived} =
               Chat.post_message_with_attachments(
                 %{
                   space_id: space.id,
                   participant_id: participant.id,
                   content_type: "text",
                   content: "with attachment"
                 },
                 [
                   %{
                     filename: "f.txt",
                     content_type: "text/plain",
                     byte_size: 1,
                     storage_key: "k"
                   }
                 ]
               )
    end

    test "edit_message/2, delete_message/1, restore_message/1" do
      {_space, _participant, message} = archived_with_content!()

      assert {:error, :space_archived} = Chat.edit_message(message, "edited")
      assert {:error, :space_archived} = Chat.delete_message(message)
      assert {:error, :space_archived} = Chat.restore_message(message)
    end

    test "add_reaction/1, toggle_reaction/3, remove_reaction/3" do
      {_space, participant, message} = archived_with_content!()

      attrs = %{message_id: message.id, participant_id: participant.id, emoji: "👍"}
      assert {:error, :space_archived} = Chat.add_reaction(attrs)

      assert {:error, :space_archived} =
               Chat.toggle_reaction(message.id, participant.id, "👍")

      assert {:error, :space_archived} =
               Chat.remove_reaction(message.id, participant.id, "👍")
    end

    test "pin_message/1 and unpin_message/2" do
      {space, participant, message} = archived_with_content!()

      assert {:error, :space_archived} =
               Chat.pin_message(%{
                 space_id: space.id,
                 message_id: message.id,
                 pinned_by: participant.id
               })

      assert {:error, :space_archived} = Chat.unpin_message(space.id, message.id)
    end

    test "create_canvas/1 and create_canvas_with_message/3" do
      {space, participant, _msg} = archived_with_content!()

      assert {:error, :space_archived} =
               Chat.create_canvas(%{space_id: space.id, created_by: participant.id})

      assert {:error, :space_archived} =
               Chat.create_canvas_with_message(space.id, participant.id, %{
                 "title" => "frozen"
               })
    end

    test "update_canvas/3 and patch_canvas/3 on a canvas created before archive" do
      space = channel!()
      participant = participant!(space.id)

      {:ok, canvas} =
        Chat.create_canvas(%{space_id: space.id, created_by: participant.id})

      {:ok, _} = Chat.archive_space(space)

      # `:system` so the archive rejection is provably the check that fired —
      # a denial here would otherwise be ambiguous with the stage-2 authz gate.
      assert {:error, :space_archived} =
               Chat.update_canvas(:system, canvas, %{"title" => "nope"})

      assert {:error, :space_archived} = Chat.patch_canvas(:system, canvas, [])
    end

    test "create_attachment/1 — space-anchored and message-anchored" do
      {space, _participant, message} = archived_with_content!()

      base = %{filename: "f.txt", content_type: "text/plain", byte_size: 1, storage_key: "k"}

      assert {:error, :space_archived} =
               Chat.create_attachment(Map.put(base, :space_id, space.id))

      assert {:error, :space_archived} =
               Chat.create_attachment(Map.put(base, :message_id, message.id))
    end

    test "add_participant/2 and add_agent_participant/3" do
      {space, _participant, _msg} = archived_with_content!()

      assert {:error, :space_archived} =
               Chat.add_participant(space.id, %{
                 participant_type: "user",
                 participant_id: Ecto.UUID.generate(),
                 joined_at: DateTime.utc_now()
               })

      agent = %Agent{id: Ecto.UUID.generate(), name: "Frozen Agent"}
      assert {:error, :space_archived} = Chat.add_agent_participant(space.id, agent)
    end

    test "reply_to_thread/3 (delegates through post_message)" do
      space = channel!()
      participant = participant!(space.id)
      message = message!(space.id, participant.id)

      {:ok, thread} = Chat.create_thread_for_message(space.id, message.id)
      {:ok, _} = Chat.archive_space(space)

      assert {:error, :space_archived} =
               Chat.reply_to_thread(thread.id, participant.id, %{content: "frozen reply"})
    end
  end

  describe "writes into archived execution spaces still work" do
    test "post_message lands in an archived execution space" do
      {:ok, space} =
        Chat.create_space(%{
          name: "exec",
          slug: "exec-#{System.unique_integer([:positive])}",
          kind: "execution"
        })

      participant = participant!(space.id)
      {:ok, _} = Chat.archive_space(space)

      assert {:ok, _msg} =
               Chat.post_message(%{
                 space_id: space.id,
                 participant_id: participant.id,
                 content_type: "text",
                 content: "post-archive execution log line"
               })
    end
  end

  describe "unarchive restores interaction" do
    test "post_message works again after unarchive" do
      admin = admin_user!()
      {space, participant, _msg} = archived_with_content!()

      {:ok, restored} = Chat.unarchive_space(admin, space)

      assert {:ok, _msg} =
               Chat.post_message(%{
                 space_id: restored.id,
                 participant_id: participant.id,
                 content_type: "text",
                 content: "we're back"
               })
    end
  end

  # ── Searchable history (task 019e95ea stage 2) ──────────────────────────

  describe "list_messages_since/2 vs archived channels" do
    test "archived-channel messages are excluded by default" do
      window_start = DateTime.add(DateTime.utc_now(), -60, :second)

      {_archived_space, _participant, archived_msg} = archived_with_content!()

      active_space = channel!()
      active_participant = participant!(active_space.id)
      active_msg = message!(active_space.id, active_participant.id)

      ids = window_start |> Chat.list_messages_since() |> Enum.map(& &1.id)

      assert active_msg.id in ids
      refute archived_msg.id in ids
    end

    test "include_archived: true opts archived history back in" do
      window_start = DateTime.add(DateTime.utc_now(), -60, :second)

      {_archived_space, _participant, archived_msg} = archived_with_content!()

      ids =
        window_start
        |> Chat.list_messages_since(include_archived: true)
        |> Enum.map(& &1.id)

      assert archived_msg.id in ids
    end
  end
end
