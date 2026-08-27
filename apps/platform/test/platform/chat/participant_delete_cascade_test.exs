defmodule Platform.Chat.ParticipantDeleteCascadeTest do
  @moduledoc """
  Task 01a04516 defect 1 — CHARACTERISATION, not a guard.

  `chat_messages.participant_id` carries `ON DELETE SET NULL` to
  `chat_participants(id)` (migration `20260418220000_drop_left_at_hard_delete`,
  ADR 0038 Phase 4). `Chat.remove_participant/1` — the roster-removal API —
  hard-deletes the row, so removing a participant NULLs the authorship link
  on every message they ever wrote.

  This file PINS THE CURRENT BEHAVIOUR so that whichever remediation is
  chosen (RESTRICT / soft-delete / loud-and-recoverable), the change shows
  up here as a deliberate edit rather than passing silently. It deliberately
  does NOT assert that the behaviour is correct — it is not.

  Note what the sibling file `freeze_nil_participant_test.exs` does NOT do:
  it inserts an already-orphaned message directly via `Ecto.Changeset.change/2`.
  That proves the freeze path tolerates a nulled row, but it never exercises
  the FK, so nothing in the suite demonstrates that the cascade is real.
  This does.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Repo

  defp unique_int, do: System.unique_integer([:positive, :monotonic])

  defp create_space! do
    {:ok, space} =
      Chat.create_space(%{
        name: "Cascade Characterisation",
        slug: "cascade-char-#{unique_int()}",
        kind: "channel"
      })

    space
  end

  defp create_participant!(space_id, display_name) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    p
  end

  describe "Chat.remove_participant/1 and message authorship" do
    test "removing a participant NULLs participant_id on every message they wrote" do
      space = create_space!()
      author = create_participant!(space.id, "Doomed Agent")
      bystander = create_participant!(space.id, "Surviving Agent")

      {:ok, m1} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "first"
        })

      {:ok, m2} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "second"
        })

      {:ok, other} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: bystander.id,
          content_type: "text",
          content: "not mine to lose"
        })

      # Precondition: the links are real before the removal. Without this
      # the assertions below would also hold if post_message had never
      # written participant_id at all.
      assert Repo.get!(Message, m1.id).participant_id == author.id
      assert Repo.get!(Message, m2.id).participant_id == author.id

      assert {:ok, _} = Chat.remove_participant(author)

      # THE DEFECT. A roster removal silently rewrote the authorship of
      # everything this participant ever said. This is a characterisation
      # assertion: when the cascade is remediated, THIS is the line that
      # must change.
      assert is_nil(Repo.get!(Message, m1.id).participant_id)
      assert is_nil(Repo.get!(Message, m2.id).participant_id)

      # Scoped to the deleted participant — the FK is not nulling the whole
      # table, which would be a different (and louder) bug.
      assert Repo.get!(Message, other.id).participant_id == bystander.id
    end

    test "the denormalised author columns keep rendering, which is why it is silent" do
      space = create_space!()
      author = create_participant!(space.id, "Doomed Agent")

      {:ok, msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "still looks attributed"
        })

      assert {:ok, _} = Chat.remove_participant(author)

      reloaded = Repo.get!(Message, msg.id)

      # The link is gone...
      assert is_nil(reloaded.participant_id)

      # ...but the snapshot columns are untouched, so every read surface
      # still shows a correctly-attributed message. Nothing in the UI, and
      # nothing in the audit log, marks these rows as damaged. That
      # combination is what let 143k rows go unnoticed in production.
      assert reloaded.author_display_name == "Doomed Agent"
    end

    test "re-adding the same principal does NOT restore the link" do
      space = create_space!()
      principal_id = Ecto.UUID.generate()

      {:ok, author} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: principal_id,
          joined_at: DateTime.utc_now(),
          display_name: "Rejoining Agent"
        })

      {:ok, msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "written before the removal"
        })

      assert {:ok, _} = Chat.remove_participant(author)

      {:ok, rejoined} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: principal_id,
          joined_at: DateTime.utc_now(),
          display_name: "Rejoining Agent"
        })

      # A NEW row with a NEW id. The old references were already erased, so
      # the removal is not reversible by re-inviting the agent — the reason
      # "just add them back" is not a remedy.
      refute rejoined.id == author.id
      assert is_nil(Repo.get!(Message, msg.id).participant_id)
    end
  end
end
