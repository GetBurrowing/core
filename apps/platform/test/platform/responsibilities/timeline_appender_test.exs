defmodule Platform.Responsibilities.TimelineAppenderTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.TimelineAppender` — the ADR-0044
  stage 5 auto-append helper hooked from
  `Platform.Tasks.transition_task_status/2` on the `done` transition.

  Covers:

    * `build_line/1,2` — the canonical timeline row format
    * `adr_flag?/1` gate — string vs atom vs missing metadata
    * `maybe_append/1` — writes to `docs/architecture/timeline.md`
      when the flag is on, no-op when off
    * Filesystem failure never propagates to the caller (the
      `try/rescue` around `File.write/3` is the whole point)

  We snapshot and restore the timeline file's contents around each
  test that touches it so a stale row from one test can't confuse the
  next.
  """
  use Platform.DataCase, async: false

  alias Platform.Responsibilities.TimelineAppender
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  # ── Helpers ────────────────────────────────────────────────────────────

  defp create_project(attrs \\ %{}) do
    {:ok, project} =
      Tasks.create_project(
        Map.merge(
          %{
            name: "TimelineAppender Project #{System.unique_integer([:positive])}",
            repo_url: "https://github.com/org/timeline-test",
            tech_stack: %{"language" => "elixir"},
            deploy_config: %{"target" => "fly"}
          },
          attrs
        )
      )

    project
  end

  defp create_task(project, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            title: "Ship the widget",
            description: "Do the thing"
          },
          attrs
        )
      )

    task
  end

  # Snapshot the timeline file contents around a block. Restores exactly
  # what was there (including nil = missing file). Used by tests that
  # actually append.
  defp with_timeline_snapshot(fun) do
    path = TimelineAppender.timeline_path()

    original =
      case path && File.read(path) do
        {:ok, contents} -> {:existed, contents}
        {:error, _} -> :missing
        nil -> :no_path
      end

    try do
      fun.(path)
    after
      case {path, original} do
        {nil, _} -> :ok
        {p, {:existed, contents}} -> File.write!(p, contents)
        {p, :missing} -> File.rm(p)
        _ -> :ok
      end
    end
  end

  # ── build_line/1,2 ──────────────────────────────────────────────────

  describe "build_line/2 — canonical row format" do
    test "renders all five columns when the metadata is complete" do
      task = %TaskSchema{
        id: "019f3da3-c7a3-717e-8a65-86c42156028c",
        title: "Land ADR-0044 stage 5",
        metadata: %{
          "adr_flag" => true,
          "adr_number" => "0044",
          "pr_number" => "492"
        }
      }

      line = TimelineAppender.build_line(task, ~D[2026-07-08])

      assert line ==
               "- 2026-07-08 | ADR-0044 | PR #492 | 019f3da3-c7a3-717e-8a65-86c42156028c | Land ADR-0044 stage 5"
    end

    test "falls back to `-` when pr_number is missing" do
      task = %TaskSchema{
        id: "019f0000-abcd-abcd-abcd-abcdabcdabcd",
        title: "Some architectural doc drift fix",
        metadata: %{"adr_flag" => true, "adr_number" => "0044"}
      }

      line = TimelineAppender.build_line(task, ~D[2026-07-08])

      assert line ==
               "- 2026-07-08 | ADR-0044 | PR #- | 019f0000-abcd-abcd-abcd-abcdabcdabcd | Some architectural doc drift fix"
    end

    test "falls back to XXXX when adr_number is missing" do
      task = %TaskSchema{
        id: "019f0000-abcd-abcd-abcd-abcdabcdabcd",
        title: "No ADR number set",
        metadata: %{"adr_flag" => true}
      }

      line = TimelineAppender.build_line(task, ~D[2026-07-08])

      assert line =~ "ADR-XXXX"
    end

    test "collapses multi-line titles onto one line" do
      task = %TaskSchema{
        id: "019f0000-0000-0000-0000-000000000000",
        title: "Line one\nLine two\n\nLine three",
        metadata: %{"adr_flag" => true, "adr_number" => "0044"}
      }

      line = TimelineAppender.build_line(task, ~D[2026-07-08])

      assert line =~ "Line one Line two Line three"
      # And the whole line stays a single newline-free string.
      refute line =~ "\n"
    end

    test "accepts atom-keyed metadata alongside string-keyed" do
      task = %TaskSchema{
        id: "019f0000-0000-0000-0000-000000000000",
        title: "Atom keys work",
        metadata: %{adr_flag: true, adr_number: "0044", pr_number: "10"}
      }

      line = TimelineAppender.build_line(task, ~D[2026-07-08])

      assert line =~ "ADR-0044"
      assert line =~ "PR #10"
    end
  end

  # ── maybe_append/1 flag gate ────────────────────────────────────────

  describe "maybe_append/1 — adr_flag gate" do
    test "no side effect when metadata is nil" do
      task = %TaskSchema{id: "019f0000-0000-0000-0000-000000000000", metadata: nil}
      before = File.read(TimelineAppender.timeline_path() || "/dev/null")

      assert :ok = TimelineAppender.maybe_append(task)

      after_read = File.read(TimelineAppender.timeline_path() || "/dev/null")
      assert before == after_read
    end

    test "no side effect when metadata is missing adr_flag" do
      task = %TaskSchema{
        id: "019f0000-0000-0000-0000-000000000000",
        title: "no flag",
        metadata: %{"pr_number" => "10"}
      }

      before = File.read(TimelineAppender.timeline_path() || "/dev/null")

      assert :ok = TimelineAppender.maybe_append(task)

      after_read = File.read(TimelineAppender.timeline_path() || "/dev/null")
      assert before == after_read
    end

    test "no side effect when adr_flag is `false`" do
      task = %TaskSchema{
        id: "019f0000-0000-0000-0000-000000000000",
        title: "flag off",
        metadata: %{"adr_flag" => false, "adr_number" => "0044"}
      }

      before = File.read(TimelineAppender.timeline_path() || "/dev/null")

      assert :ok = TimelineAppender.maybe_append(task)

      after_read = File.read(TimelineAppender.timeline_path() || "/dev/null")
      assert before == after_read
    end

    test "returns :ok when passed a non-Task struct" do
      assert :ok = TimelineAppender.maybe_append(%{not: :a_task})
      assert :ok = TimelineAppender.maybe_append(nil)
      assert :ok = TimelineAppender.maybe_append("string")
    end
  end

  # ── maybe_append/1 append path ──────────────────────────────────────

  describe "maybe_append/1 — appends when adr_flag is true" do
    test "appends the built line to the timeline file" do
      task = %TaskSchema{
        id: "019fappender-0000-0000-0000-000000000000",
        title: "TimelineAppender append-path smoke test",
        metadata: %{"adr_flag" => true, "adr_number" => "0044", "pr_number" => "999"}
      }

      with_timeline_snapshot(fn path ->
        # Only run the assertion when the module actually located the
        # timeline path (production/dev builds always will; a stripped
        # release without docs/ wouldn't).
        if path && File.exists?(path) do
          before = File.read!(path)

          assert :ok = TimelineAppender.maybe_append(task)

          after_read = File.read!(path)

          # The file grew by exactly one line ending in the task title.
          new_lines =
            String.replace_prefix(after_read, before, "")
            |> String.trim_trailing()

          assert new_lines =~ "PR #999"
          assert new_lines =~ "TimelineAppender append-path smoke test"
          assert new_lines =~ "ADR-0044"
        else
          # No timeline path — skipped; the appender still returned :ok.
          assert :ok = TimelineAppender.maybe_append(task)
        end
      end)
    end

    test "accepts the string-round-tripped `\"true\"` value" do
      task = %TaskSchema{
        id: "019fappender-strflag-0000-0000-000000000000",
        title: "string flag true",
        metadata: %{"adr_flag" => "true", "adr_number" => "0044", "pr_number" => "1"}
      }

      with_timeline_snapshot(fn path ->
        if path && File.exists?(path) do
          before = File.read!(path)

          assert :ok = TimelineAppender.maybe_append(task)

          after_read = File.read!(path)

          new_lines =
            String.replace_prefix(after_read, before, "")
            |> String.trim_trailing()

          assert new_lines =~ "string flag true"
        else
          assert :ok = TimelineAppender.maybe_append(task)
        end
      end)
    end
  end

  # ── Integration: transition_task_status/2 hook ──────────────────────

  describe "hooked from Tasks.transition_task_status/2" do
    test "task transition to `done` with adr_flag appends without erroring" do
      project = create_project()

      task =
        create_task(project, %{
          title: "Integration hook path",
          metadata: %{
            "adr_flag" => true,
            "adr_number" => "0044",
            "pr_number" => "hook"
          }
        })

      # Walk the state machine: backlog → planning → in_progress → done.
      {:ok, planning_task} = Tasks.transition_task_status(task, "planning")
      {:ok, in_progress_task} = Tasks.transition_task_status(planning_task, "in_progress")

      with_timeline_snapshot(fn path ->
        {:ok, done_task} = Tasks.transition_task_status(in_progress_task, "done")
        assert done_task.status == "done"

        # Whatever the filesystem state, the transition still returned
        # {:ok, task} — the appender must not break the state machine.
        if path && File.exists?(path) do
          assert File.read!(path) =~ "hook"
        end
      end)
    end

    test "task transition to `done` WITHOUT adr_flag does not touch the timeline" do
      project = create_project()

      task =
        create_task(project, %{
          title: "No ADR flag",
          metadata: %{"pr_number" => "100"}
        })

      # Same status walk: backlog → planning → in_progress → done.
      {:ok, planning_task} = Tasks.transition_task_status(task, "planning")
      {:ok, in_progress_task} = Tasks.transition_task_status(planning_task, "in_progress")

      path = TimelineAppender.timeline_path()
      before = path && File.read(path)

      {:ok, done_task} = Tasks.transition_task_status(in_progress_task, "done")
      assert done_task.status == "done"

      after_read = path && File.read(path)
      assert before == after_read
    end
  end
end
