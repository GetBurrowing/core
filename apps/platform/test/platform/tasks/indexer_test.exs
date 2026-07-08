defmodule Platform.Tasks.IndexerTest do
  @moduledoc """
  Unit tests for `Platform.Tasks.Indexer` — the pure payload shaper.
  No Repo: every input is a constructed struct so the test is fast and
  side-effect-free. Mirrors the shape of
  `Platform.Org.Wiki.Indexer.Payload`'s test suite.
  """
  use ExUnit.Case, async: true

  alias Platform.Tasks.Indexer
  alias Platform.Tasks.Task

  describe "build_entry/1" do
    test "shapes a minimal task with default metadata" do
      task = %Task{
        id: "019f0000-0000-7000-8000-000000000001",
        project_id: "019f0000-0000-7000-8000-0000000000ff",
        title: "Fix a thing",
        description: "some body",
        status: "backlog",
        priority: "medium",
        metadata: %{},
        inserted_at: ~U[2026-06-01 12:00:00.000000Z],
        updated_at: ~U[2026-06-02 12:00:00.000000Z]
      }

      entry = Indexer.build_entry(task)

      assert entry.id == task.id
      assert entry.memory_type == "task"
      assert entry.memory_type == Indexer.task_memory_type()
      assert entry.project_id == task.project_id
      assert entry.date == "2026-06-01"

      assert entry.metadata["status"] == "backlog"
      assert entry.metadata["priority"] == "medium"
      assert entry.metadata["project_id"] == task.project_id
      assert entry.metadata["epic_id"] == nil
      assert entry.metadata["feature_area"] == ""
      assert entry.metadata["updated_at"] == "2026-06-02T12:00:00.000000Z"
    end

    test "content joins title, description, and feature_area with em-dash" do
      task = %Task{
        id: "019f0000-0000-7000-8000-000000000002",
        project_id: nil,
        title: "Investigate summarizer leak",
        description: "20MB per meeting bleed",
        status: "backlog",
        priority: "high",
        metadata: %{"feature_area" => "meetings"},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      entry = Indexer.build_entry(task)

      assert entry.content ==
               "Investigate summarizer leak — 20MB per meeting bleed — meetings"

      assert entry.metadata["feature_area"] == "meetings"
    end

    test "collapses nil title/description/feature_area to empty strings" do
      task = %Task{
        id: "019f0000-0000-7000-8000-000000000003",
        project_id: nil,
        title: nil,
        description: nil,
        status: "backlog",
        priority: "medium",
        metadata: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      entry = Indexer.build_entry(task)

      # No stray "nil" literal in the embedded corpus — three empty
      # segments joined by " — " is fine.
      assert entry.content == " —  — "
      assert entry.metadata["feature_area"] == ""
    end

    test "epic_id and project_id propagate as strings when present" do
      task = %Task{
        id: "019f0000-0000-7000-8000-000000000004",
        project_id: "019f0000-0000-7000-8000-0000000000fe",
        epic_id: "019f0000-0000-7000-8000-0000000000fd",
        title: "t",
        description: "d",
        status: "in_progress",
        priority: "critical",
        metadata: %{"feature_area" => "auth"},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      entry = Indexer.build_entry(task)

      assert entry.metadata["project_id"] == task.project_id
      assert entry.metadata["epic_id"] == task.epic_id
      assert entry.metadata["status"] == "in_progress"
      assert entry.metadata["priority"] == "critical"
    end

    test "always stamps memory_type=\"task\"" do
      task = %Task{
        id: "x",
        title: "t",
        description: "d",
        status: "backlog",
        priority: "medium",
        metadata: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert Indexer.build_entry(task).memory_type == "task"
      assert Indexer.task_memory_type() == "task"
    end
  end
end
