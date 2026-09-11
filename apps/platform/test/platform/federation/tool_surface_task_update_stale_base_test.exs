defmodule Platform.Federation.ToolSurfaceTaskUpdateStaleBaseTest do
  @moduledoc """
  The `base_updated_at` compare-and-set token on the MCP `task_update` surface
  (task 01a08a80 stage 2).

  Stage 1 added `Tasks.update_task_if_unmodified/4`. These cases pin the WIRE
  contract: that an agent passing a base it composed against is refused rather
  than silently clobbering a concurrent writer, and — the load-bearing half —
  that an agent passing NO base behaves exactly as it does on main.

  No `Process.sleep` anywhere in this file. Every concurrency case is composed
  against ONE captured `updated_at`, so no wall-clock gap is needed and a sleep
  would only measure itself.
  """
  use Platform.DataCase, async: false

  alias Platform.Federation.TaskAttrs
  alias Platform.Federation.ToolSurface
  alias Platform.Tasks

  defp create_project(attrs \\ %{}) do
    default = %{name: "Stale Base Project #{System.unique_integer([:positive])}"}
    {:ok, project} = Tasks.create_project(Map.merge(default, attrs))
    project
  end

  defp create_task(attrs \\ %{}) do
    project = create_project()

    {:ok, task} =
      Tasks.create_task(
        Map.merge(%{project_id: project.id, title: "Base", description: "original"}, attrs)
      )

    task
  end

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  describe "task_update base_updated_at — refusal" do
    test "a second write composed against the SAME captured base is refused, not applied" do
      task = create_task()
      base = iso(task.updated_at)

      # Writer A composes against `base` and wins.
      {:ok, a} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "description" => "A", "base_updated_at" => base},
          %{}
        )

      assert a.description == "A"

      # Writer B composed against the SAME base — it never re-read. On main
      # this silently overwrites "A" with "B"; that is the lost write this
      # whole ticket is about.
      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "description" => "B", "base_updated_at" => base},
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ "stale_base"
      # Names the CURRENT updated_at (what writer A produced) so the caller
      # can tell how far behind it was...
      assert error.error =~ iso(a.updated_at)
      # ...and the base it actually supplied.
      assert error.error =~ base
      assert error.suggestion =~ "task_get"

      # The refusal is a refusal: B did not land.
      assert Tasks.get_task_record(task.id).description == "A"
    end

    test "the guard is on the BASE in the args, not on the struct execute/3 just loaded" do
      # The mutation this kills, carried down from stage 1: seeding the CAS
      # filter from the loaded struct instead of the caller's base. Inside
      # `execute("task_update", ...)` the struct is reloaded and is therefore
      # CURRENT by construction, so a filter seeded from it always matches and
      # the guard is a silent no-op. Here the row has genuinely advanced since
      # the caller read it, so the two values diverge and only the caller's
      # base can produce a refusal.
      task = create_task()
      stale_base = iso(task.updated_at)

      # Someone else advances the row. The caller does not know.
      {:ok, advanced} = Tasks.update_task(task, %{description: "someone else"})
      assert advanced.updated_at != task.updated_at

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "description" => "mine", "base_updated_at" => stale_base},
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ iso(advanced.updated_at)
      assert Tasks.get_task_record(task.id).description == "someone else"
    end
  end

  describe "task_update base_updated_at — positive control" do
    test "a base equal to the current updated_at succeeds and applies" do
      # Required as a pair with the refusal cases: without it, an
      # implementation that refuses EVERY call carrying a base passes them all.
      task = create_task()

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{
            "task_id" => task.id,
            "description" => "applied",
            "base_updated_at" => iso(task.updated_at)
          },
          %{}
        )

      assert result.description == "applied"
      assert Tasks.get_task_record(task.id).description == "applied"
    end

    test "the if_unmodified_since alias resolves identically to base_updated_at" do
      task = create_task()
      base = iso(task.updated_at)

      # Fresh base → succeeds.
      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "description" => "via alias", "if_unmodified_since" => base},
          %{}
        )

      assert result.description == "via alias"

      # Same alias, now-stale base → refused, exactly as base_updated_at would be.
      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "description" => "second", "if_unmodified_since" => base},
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ "stale_base"
      assert Tasks.get_task_record(task.id).description == "via alias"
    end
  end

  describe "task_update back-compat — the parameter is never mandatory" do
    test "a call with NO base succeeds against a row that has advanced since the caller read it" do
      # THE load-bearing case. Every existing agent caller omits this
      # parameter; if omitting it ever started failing, every agent on the
      # board would wedge mid-flight. Nil base must behave EXACTLY as on main:
      # last write wins.
      task = create_task()

      {:ok, _advanced} = Tasks.update_task(task, %{description: "moved under them"})

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "description" => "base-less write"},
          %{}
        )

      assert result.description == "base-less write"
      assert Tasks.get_task_record(task.id).description == "base-less write"
    end

    test "a base-less status transition still works" do
      task = create_task(%{status: "in_progress"})

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "status" => "cancelled"},
          %{}
        )

      assert result.status == "cancelled"
    end

    test "base_updated_at is not advertised as a required parameter" do
      tools = ToolSurface.tool_definitions()
      task_update = Enum.find(tools, &(&1.name == "task_update"))

      assert %{required: false} = task_update.parameters.base_updated_at
      assert "if_unmodified_since" in task_update.parameters.base_updated_at.aliases
    end
  end

  describe "task_update base_updated_at — rejection before any write" do
    test "an unparseable base is rejected and the row is UNCHANGED" do
      task = create_task()
      before = Tasks.get_task_record(task.id)

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{
            "task_id" => task.id,
            "description" => "should never land",
            "base_updated_at" => "not-a-timestamp"
          },
          %{}
        )

      assert error.recoverable == true
      assert error.error =~ "base_updated_at"

      after_row = Tasks.get_task_record(task.id)
      assert after_row.description == before.description
      # `updated_at` not moving is the check that proves NO WRITE HAPPENED,
      # rather than that a write happened and was harmless.
      assert after_row.updated_at == before.updated_at
    end

    test "an unparseable if_unmodified_since is rejected the same way" do
      task = create_task()
      before = Tasks.get_task_record(task.id)

      {:error, error} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "title" => "nope", "if_unmodified_since" => "12345"},
          %{}
        )

      assert error.recoverable == true
      assert Tasks.get_task_record(task.id).updated_at == before.updated_at
    end
  end

  describe "task_update discloses the updated_at it displaced" do
    test "the success envelope carries previous_updated_at, strictly different from updated_at" do
      # Stage 3. The mitigation for callers who do NOT pass a base: the write
      # still lands last-write-wins, but the response now says which revision
      # it overwrote, so the displacement is reconstructable after the fact.
      task = create_task()
      before = Tasks.get_task_record(task.id)

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "title" => "disclosure check"},
          %{}
        )

      # The structural pin: it is the PRE-update stamp, not some other value.
      assert result.previous_updated_at == before.updated_at

      # The spec's pin, and the one that cannot pass vacuously. If the fixture
      # ever produced two coinciding timestamps, `previous_updated_at` would
      # still equal `before.updated_at` above and that assertion alone would be
      # satisfied while proving nothing — so the strict inequality is what
      # turns a coincidence into a RED rather than a silent green. (The pair is
      # genuinely distinct without any sleep: `tasks.updated_at` is
      # `:utc_datetime_usec` and these are two separate round-tripped writes.)
      assert result.previous_updated_at != result.updated_at

      assert DateTime.compare(result.previous_updated_at, result.updated_at) == :lt
      assert result.updated_at == Tasks.get_task_record(task.id).updated_at
    end

    test "previous_updated_at is disclosed on a write that displaced a CONCURRENT writer" do
      # The case the field exists for. The caller read the task, someone else
      # wrote, and the caller's base-less write clobbered it. `previous_updated_at`
      # comes back NEWER than the stamp the caller was holding — which is
      # exactly how it learns it displaced somebody.
      task = create_task()
      caller_last_saw = task.updated_at

      {:ok, other} = Tasks.update_task(task, %{description: "the other writer"})

      {:ok, result} =
        ToolSurface.execute(
          "task_update",
          %{"task_id" => task.id, "description" => "clobbered them"},
          %{}
        )

      assert result.previous_updated_at == other.updated_at
      assert DateTime.compare(result.previous_updated_at, caller_last_saw) == :gt
    end
  end

  describe "serialize_task/1 was NOT widened" do
    test "task_get does not carry previous_updated_at" do
      # Load-bearing: this is the only thing standing between a scoped change
      # to the task_update envelope and a global one. A read displaces nothing,
      # so the key would be meaningless noise on every task in every list.
      task = create_task()

      {:ok, result} = ToolSurface.execute("task_get", %{"task_id" => task.id}, %{})

      refute Map.has_key?(result, :previous_updated_at)
      # Positive control for the refutation: prove we are looking at a real
      # serialized task and not an envelope shape where every key is absent.
      assert result.id == task.id
      assert Map.has_key?(result, :updated_at)
    end

    test "task_list rows do not carry previous_updated_at" do
      task = create_task()

      {:ok, %{tasks: rows}} =
        ToolSurface.execute("task_list", %{"project_id" => task.project_id}, %{})

      row = Enum.find(rows, &(&1.id == task.id))

      assert row, "the task under test was not returned by task_list"
      refute Map.has_key?(row, :previous_updated_at)
      assert Map.has_key?(row, :updated_at)
    end

    test "task_get on a task that was just updated still does not carry the key" do
      # Guards the likelier regression shape: not "serialize_task grew a key"
      # but "the key leaked onto reads of a row that happens to have been
      # written through task_update".
      task = create_task()

      {:ok, updated} =
        ToolSurface.execute("task_update", %{"task_id" => task.id, "title" => "x"}, %{})

      assert Map.has_key?(updated, :previous_updated_at)

      {:ok, read_back} = ToolSurface.execute("task_get", %{"task_id" => task.id}, %{})

      refute Map.has_key?(read_back, :previous_updated_at)
    end
  end

  describe "TaskAttrs does not leak base_updated_at into the changeset" do
    test "the builder silently drops base_updated_at and if_unmodified_since" do
      # `TaskAttrs.build_task_attrs/3` documents that unknown keys are silently
      # dropped, which is why no allow-list entry was added. Pinned here
      # because a silent drop that stops being silent later would put an
      # unknown field into `Task.changeset/2` and turn every CAS call into a
      # changeset error.
      {:ok, flat, _phase} =
        TaskAttrs.build_task_attrs(
          %{
            "task_id" => Ecto.UUID.generate(),
            "description" => "d",
            "base_updated_at" => "2026-01-01T00:00:00.000000Z",
            "if_unmodified_since" => "2026-01-01T00:00:00.000000Z"
          },
          :update
        )

      refute Map.has_key?(flat, :base_updated_at)
      refute Map.has_key?(flat, :if_unmodified_since)
      assert flat.description == "d"
    end
  end
end
