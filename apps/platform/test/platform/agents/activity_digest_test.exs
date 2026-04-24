defmodule Platform.Agents.ActivityDigestTest do
  use Platform.DataCase

  alias Platform.Agents.ActivityDigest
  alias Platform.Chat.{Message, Participant, Space}
  alias Platform.Meetings.Transcript
  alias Platform.Tasks.{Project, Task}

  @window_end ~U[2026-04-22 12:00:00.000000Z]
  @window_start ~U[2026-04-21 12:00:00.000000Z]

  describe "build/2" do
    test "returns empty fallback when no activity exists in the window" do
      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "## Activity since 2026-04-21 12:00:00"
      assert result =~ "_No activity in this window._"
    end

    test "includes messages from channels within the window" do
      space = insert_space(%{name: "Strategy", slug: "strategy", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Alice"})

      insert_message(space.id, participant.id, %{
        content: "Kicked off Q2 planning today",
        inserted_at: within_window()
      })

      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "### Chat"
      assert result =~ "#Strategy"
      assert result =~ "@Alice"
      assert result =~ "Kicked off Q2 planning today"
    end

    test "excludes DM messages" do
      space = insert_space(%{name: "DM", slug: "dm-1", kind: "dm"})
      participant = insert_participant(space.id, %{display_name: "Alice"})

      insert_message(space.id, participant.id, %{
        content: "private chat",
        inserted_at: within_window()
      })

      result = ActivityDigest.build(@window_start, @window_end)

      refute result =~ "private chat"
      assert result =~ "_No activity in this window._"
    end

    test "excludes log_only messages" do
      space = insert_space()
      participant = insert_participant(space.id)

      insert_message(space.id, participant.id, %{
        content: "internal log tick",
        log_only: true,
        inserted_at: within_window()
      })

      result = ActivityDigest.build(@window_start, @window_end)

      refute result =~ "internal log tick"
    end

    test "excludes deleted messages" do
      space = insert_space()
      participant = insert_participant(space.id)

      insert_message(space.id, participant.id, %{
        content: "retracted",
        deleted_at: within_window(),
        inserted_at: within_window()
      })

      result = ActivityDigest.build(@window_start, @window_end)

      refute result =~ "retracted"
    end

    test "excludes messages outside the window" do
      space = insert_space()
      participant = insert_participant(space.id)

      insert_message(space.id, participant.id, %{
        content: "too old",
        inserted_at: ~U[2026-04-20 12:00:00.000000Z]
      })

      insert_message(space.id, participant.id, %{
        content: "too new",
        inserted_at: ~U[2026-04-22 13:00:00.000000Z]
      })

      result = ActivityDigest.build(@window_start, @window_end)

      refute result =~ "too old"
      refute result =~ "too new"
    end

    test "applies per-space message cap with overflow marker" do
      space = insert_space(%{name: "Busy", slug: "busy"})
      participant = insert_participant(space.id, %{display_name: "Loud"})

      for i <- 1..45 do
        insert_message(space.id, participant.id, %{
          content: "message-#{i}",
          inserted_at: within_window()
        })
      end

      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "message-1"
      assert result =~ "more messages — truncated"
    end

    test "truncates message content to preview length" do
      space = insert_space()
      participant = insert_participant(space.id, %{display_name: "Verbose"})
      long = String.duplicate("abc ", 200)

      insert_message(space.id, participant.id, %{
        content: long,
        inserted_at: within_window()
      })

      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "…"
    end

    test "includes completed meeting transcripts in the window" do
      space = insert_space(%{name: "Board Room", slug: "board", kind: "channel"})

      insert_transcript(%{
        space_id: space.id,
        status: "complete",
        started_at: ~U[2026-04-22 10:00:00.000000Z],
        completed_at: ~U[2026-04-22 10:45:00.000000Z],
        summary: "Reviewed Q2 priorities and agreed on focus."
      })

      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "### Meetings"
      assert result =~ "\"Board Room\""
      assert result =~ "Reviewed Q2 priorities"
      assert result =~ "45 min"
    end

    test "excludes in-progress and failed transcripts" do
      space = insert_space()

      insert_transcript(%{
        space_id: space.id,
        status: "recording",
        started_at: ~U[2026-04-22 10:00:00.000000Z],
        completed_at: ~U[2026-04-22 10:45:00.000000Z],
        summary: "should not appear"
      })

      insert_transcript(%{
        space_id: space.id,
        status: "failed",
        started_at: ~U[2026-04-22 10:00:00.000000Z],
        completed_at: ~U[2026-04-22 10:45:00.000000Z],
        summary: "also hidden"
      })

      result = ActivityDigest.build(@window_start, @window_end)

      refute result =~ "should not appear"
      refute result =~ "also hidden"
    end

    test "includes tasks updated in the window" do
      project = insert_project()
      insert_task(project.id, %{title: "Ship release", status: "in_progress"})

      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "### Tasks"
      assert result =~ "\"Ship release\""
      assert result =~ "→ in_progress"
    end

    test "excludes deleted tasks" do
      project = insert_project()
      insert_task(project.id, %{title: "Deleted task", deleted_at: within_window()})

      result = ActivityDigest.build(@window_start, @window_end)

      refute result =~ "Deleted task"
    end

    test "applies task event cap" do
      project = insert_project()

      for i <- 1..55 do
        insert_task(project.id, %{title: "task-#{i}"})
      end

      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "more tasks — truncated"
    end

    test "composes chat, meetings, and tasks sections together" do
      project = insert_project()
      space = insert_space(%{name: "Mixed", slug: "mixed"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      insert_message(space.id, participant.id, %{
        content: "chat line",
        inserted_at: within_window()
      })

      insert_transcript(%{
        space_id: space.id,
        status: "complete",
        started_at: ~U[2026-04-22 09:00:00.000000Z],
        completed_at: ~U[2026-04-22 09:30:00.000000Z],
        summary: "meeting summary here"
      })

      insert_task(project.id, %{title: "Mixed task"})

      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "### Chat"
      assert result =~ "chat line"
      assert result =~ "### Meetings"
      assert result =~ "meeting summary here"
      assert result =~ "### Tasks"
      assert result =~ "Mixed task"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp within_window, do: ~U[2026-04-22 06:00:00.000000Z]

  defp insert_space(attrs \\ %{}) do
    defaults = %{
      name: "Test Space",
      slug: "space-#{System.unique_integer([:positive])}",
      kind: "channel"
    }

    %Space{}
    |> Space.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_participant(space_id, attrs \\ %{}) do
    defaults = %{
      space_id: space_id,
      participant_type: "user",
      participant_id: Ecto.UUID.generate(),
      display_name: "User",
      joined_at: DateTime.utc_now()
    }

    %Participant{}
    |> Participant.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_message(space_id, participant_id, attrs) do
    participant = Repo.get!(Participant, participant_id)

    defaults = %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: "hello",
      author_display_name: participant.display_name || "User"
    }

    params = Map.merge(defaults, Map.drop(attrs, [:inserted_at, :deleted_at]))
    changeset = Message.changeset(%Message{}, params)

    changeset =
      changeset
      |> maybe_put_change(:inserted_at, Map.get(attrs, :inserted_at))
      |> maybe_put_change(:deleted_at, Map.get(attrs, :deleted_at))

    Repo.insert!(changeset)
  end

  defp insert_transcript(attrs) do
    defaults = %{
      room_id: "room-#{System.unique_integer([:positive])}",
      status: "complete"
    }

    %Transcript{}
    |> Transcript.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_project(attrs \\ %{}) do
    defaults = %{
      name: "Test Project",
      description: "tests"
    }

    %Project{}
    |> Project.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_task(project_id, attrs) do
    defaults = %{
      project_id: project_id,
      title: "Task",
      status: "in_progress"
    }

    params = Map.merge(defaults, Map.drop(attrs, [:deleted_at, :updated_at]))
    changeset = Task.changeset(%Task{}, params)

    updated_at = Map.get(attrs, :updated_at, within_window())

    changeset =
      changeset
      |> maybe_put_change(:deleted_at, Map.get(attrs, :deleted_at))
      |> Ecto.Changeset.put_change(:updated_at, updated_at)
      |> Ecto.Changeset.put_change(:inserted_at, updated_at)

    Repo.insert!(changeset)
  end

  defp maybe_put_change(changeset, _key, nil), do: changeset

  defp maybe_put_change(changeset, key, value),
    do: Ecto.Changeset.put_change(changeset, key, value)
end
