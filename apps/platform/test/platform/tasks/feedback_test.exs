defmodule Platform.Tasks.FeedbackTest do
  @moduledoc "Tests for Platform.Tasks.Feedback — feedback channel into run context."
  use ExUnit.Case, async: false

  alias Platform.Execution
  alias Platform.Tasks.Feedback

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp start_run(opts \\ []) do
    task_id = "task-fb-#{System.unique_integer([:positive, :monotonic])}"
    project_id = Keyword.get(opts, :project_id, "proj-fb-#{System.unique_integer([:positive])}")

    {:ok, run} =
      Execution.start_run(task_id,
        project_id: project_id,
        epic_id: Keyword.get(opts, :epic_id)
      )

    run
  end

  # ── Tests ────────────────────────────────────────────────────────────────

  describe "push/2" do
    test "pushes feedback into the run's context session" do
      run = start_run()

      assert {:ok, version} =
               Feedback.push(run.id, %{
                 source: :chat,
                 author: "user:rowan",
                 content: "Use postgres instead of sqlite",
                 timestamp: DateTime.utc_now()
               })

      assert version > 0

      # Verify it appears in feedback list
      feedback = Feedback.list_feedback(run.id)
      assert length(feedback) == 1

      [fb] = feedback
      assert fb["source"] == "chat"
      assert fb["author"] == "user:rowan"
      assert fb["content"] == "Use postgres instead of sqlite"
    end

    test "multiple feedback items accumulate" do
      run = start_run()

      ts1 = DateTime.utc_now()
      ts2 = DateTime.add(ts1, 1, :second)
      ts3 = DateTime.add(ts1, 2, :second)

      {:ok, _} =
        Feedback.push(run.id, %{source: :chat, author: "user:a", content: "First", timestamp: ts1})

      {:ok, _} =
        Feedback.push(run.id, %{
          source: :review,
          author: "user:b",
          content: "Second",
          timestamp: ts2
        })

      {:ok, v3} =
        Feedback.push(run.id, %{source: :ui, author: "user:c", content: "Third", timestamp: ts3})

      assert v3 > 0

      feedback = Feedback.list_feedback(run.id)
      assert length(feedback) == 3

      # Verify sorted by timestamp
      contents = Enum.map(feedback, & &1["content"])
      assert contents == ["First", "Second", "Third"]
    end

    test "feedback with different sources" do
      run = start_run()
      now = DateTime.utc_now()

      [:chat, :review, :ui]
      |> Enum.with_index()
      |> Enum.each(fn {source, i} ->
        {:ok, _} =
          Feedback.push(run.id, %{
            source: source,
            author: "user:test",
            content: "Feedback from #{source}",
            timestamp: DateTime.add(now, i, :second)
          })
      end)

      feedback = Feedback.list_feedback(run.id)
      sources = Enum.map(feedback, & &1["source"])
      assert sources == ["chat", "review", "ui"]
    end

    test "returns error for invalid run_id" do
      assert {:error, _reason} =
               Feedback.push("nonexistent-run", %{
                 source: :chat,
                 author: "user:test",
                 content: "This should fail"
               })
    end
  end

  describe "list_feedback/1" do
    test "returns empty list for run with no feedback" do
      run = start_run()
      assert Feedback.list_feedback(run.id) == []
    end

    test "returns empty list for invalid run_id" do
      assert Feedback.list_feedback("nonexistent-run") == []
    end
  end

  describe "telemetry" do
    test "emits [:platform, :tasks, :feedback_pushed] event" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :tasks, :feedback_pushed]
        ])

      run = start_run()

      {:ok, _} =
        Feedback.push(run.id, %{
          source: :chat,
          author: "user:test",
          content: "Telemetry test"
        })

      assert_received {[:platform, :tasks, :feedback_pushed], ^ref, _measurements, metadata}
      assert metadata.run_id == run.id
      assert String.starts_with?(metadata.key, "feedback.")
    end
  end
end
