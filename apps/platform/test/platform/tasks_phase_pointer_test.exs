defmodule Platform.TasksPhasePointerTest do
  @moduledoc """
  Pins the single-write status + phase-pointer fold (task 019fb977 stage 4).

  ## What was wrong

  `Tasks.transition_task_status/2` committed `status` with one `Repo.update`
  and only THEN re-derived the flat `assignee_id` / `assignee_type` pointer
  with a SECOND `Repo.update` (plus a `Repo.get` reload) inside
  `maybe_apply_phase_assignee_and_reload/1`. Between the two commits the row
  read `status: "in_progress"` with `assignee_id` still at the planning
  agent. `TaskRouterWatcher.list_should_run_tasks/0` and
  `redispatch_for_runtime/1` both query exactly that pair, so the window was
  observable by the component whose whole job is to act on it.

  ## What this file asserts

    * `one UPDATE` — the direct structural claim, and the ONLY red-then-green
      assertion here. Verbatim red on the pre-fold code:

          status and the phase pointer must land in ONE write; saw 2
          UPDATE(s) against tasks for this row:
            * UPDATE "tasks" SET "status" = $1, "updated_at" = $2 WHERE "id" = $3
            * UPDATE "tasks" SET "assignee_id" = $1, "updated_at" = $2 WHERE "id" = $3

    * `first board broadcast` — a `tasks:board` subscriber's FIRST
      `{:task_updated, t}` for this task carries BOTH the new status and the
      new pointer. Captured off the mailbox by draining, NOT by
      `assert_receive`-ing a matching payload: a pattern-matching receive
      would skip a stale first payload and match the second.

      CORRECTION to the stage-4 brief, measured rather than assumed: this
      case was already GREEN before the fold. The pre-fold second write
      broadcast the struct it had just corrected, so the payload a
      subscriber saw was never stale — the window was DB-visible only
      (`Repo.get` between the two commits), which is why the UPDATE count
      above is the honest pin. What this case actually guards is the
      REGRESSION the fold creates: deleting the pointer write also deletes
      `maybe_apply_phase_assignee/1`'s broadcast, so without the re-emission
      in `transition_task_status/2` it fails with "no {:task_updated, ...}
      reached the tasks:board subscriber". Do not read it as evidence that
      subscribers used to observe a stale pointer. They did not; readers
      querying the row did.
    * `preloads` — the re-emitted broadcast carries
      `[:project, :epic, :sponsor, plans: :stages]` LOADED, matching the
      payload shape `maybe_apply_phase_assignee/1` used to send
      (`tasks.ex:4978`). A `{:task_updated, ...}` with a different
      association set is a silent break for every other subscriber.
    * `no-entry arms` — a transition with no matching `phase_assignees`
      entry leaves the flat pointer ALONE (falling back to the task owner)
      rather than nilling it.

  ## Why the `tasks:board` drains filter on task id

  `"tasks:board"` is a single global topic that does not respect the Ecto
  sandbox, and 13+ `async: true` files broadcast onto it (see
  `test_quarantine.ex`, entry dated 2026-07-26). "The first message in my
  mailbox" is therefore not a stable observable; "the first message ABOUT MY
  TASK" is. The filter is on the task id only — never on status or assignee —
  so a stale payload is still captured and still fails the assertion.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  # Bounded OBSERVATION window for a board broadcast. Every drain in this
  # file is looking for a message that has already been sent by the time the
  # transition call returns (`broadcast_board/1` is synchronous from the
  # caller's side), so this is a ceiling on scheduler latency, not a
  # synchronisation sleep.
  @board_window_ms 1_000

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Phase Pointer Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/phase-pointer"
      })

    %{
      project: project,
      planner: create_agent("planner"),
      implementer: create_agent("implementer"),
      reviewer: create_agent("reviewer")
    }
  end

  describe "transition_task_status/2 commits status and phase pointer in one write" do
    test "planning -> in_progress: the FIRST board payload already carries both", %{
      project: project,
      planner: planner,
      implementer: implementer
    } do
      task =
        task_with_phases(project, "planning", planner, %{
          "planning" => phase_entry(planner),
          "execution" => phase_entry(implementer)
        })

      Tasks.subscribe_board()

      {:ok, updated} = Tasks.transition_task_status(task, "in_progress")

      assert updated.status == "in_progress"
      assert updated.assignee_id == implementer.id
      assert updated.assignee_type == "agent"

      first = first_board_update!(task.id)

      assert first.status == "in_progress",
             "the first board payload for this task did not carry the new status"

      assert first.assignee_id == implementer.id,
             "the FIRST {:task_updated, ...} a subscriber sees still carries the planning " <>
               "agent (#{inspect(first.assignee_id)}); a reader acting on it dispatches to " <>
               "the wrong runtime"

      # And the row itself, not just the broadcast payload.
      reloaded = Repo.get!(TaskSchema, task.id)
      assert reloaded.status == "in_progress"
      assert reloaded.assignee_id == implementer.id
    end

    test "planning -> in_progress issues exactly ONE UPDATE against tasks", %{
      project: project,
      planner: planner,
      implementer: implementer
    } do
      task =
        task_with_phases(project, "planning", planner, %{
          "planning" => phase_entry(planner),
          "execution" => phase_entry(implementer)
        })

      queries =
        capture_task_queries(task.id, fn ->
          {:ok, _} = Tasks.transition_task_status(task, "in_progress")
        end)

      updates = Enum.filter(queries, &String.starts_with?(&1, "UPDATE \"tasks\""))

      assert length(updates) == 1,
             "status and the phase pointer must land in ONE write; saw " <>
               "#{length(updates)} UPDATE(s) against tasks for this row:\n" <>
               Enum.map_join(updates, "\n", &("  * " <> &1))
    end

    test "in_progress -> in_review hands the pointer to the REVIEW agent", %{
      project: project,
      implementer: implementer,
      reviewer: reviewer
    } do
      task =
        task_with_phases(project, "in_progress", implementer, %{
          "execution" => phase_entry(implementer),
          "review" => phase_entry(reviewer)
        })

      Tasks.subscribe_board()

      {:ok, updated} = Tasks.transition_task_status(task, "in_review")

      assert updated.assignee_id == reviewer.id

      first = first_board_update!(task.id)

      assert first.status == "in_review"

      assert first.assignee_id == reviewer.id,
             "the first payload for the execution -> review handoff still names the " <>
               "implementer (#{inspect(first.assignee_id)})"
    end

    test "the re-emitted broadcast carries the same preloads as the old one", %{
      project: project,
      planner: planner,
      implementer: implementer
    } do
      {:ok, epic} =
        Tasks.create_epic(%{
          project_id: project.id,
          name: "Phase Pointer Epic #{System.unique_integer([:positive])}"
        })

      task =
        project
        |> task_with_phases("planning", planner, %{
          "planning" => phase_entry(planner),
          "execution" => phase_entry(implementer)
        })
        |> put_task_fields(%{epic_id: epic.id})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

      {:ok, _stage} =
        Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "coding", description: "Code"})

      Tasks.subscribe_board()

      {:ok, _updated} = Tasks.transition_task_status(task, "in_progress")

      first = first_board_update!(task.id)

      # Named individually rather than through a helper: the failure message
      # has to say WHICH association regressed.
      refute match?(%Ecto.Association.NotLoaded{}, first.project),
             "project came through as %Ecto.Association.NotLoaded{}"

      refute match?(%Ecto.Association.NotLoaded{}, first.epic),
             "epic came through as %Ecto.Association.NotLoaded{}"

      refute match?(%Ecto.Association.NotLoaded{}, first.sponsor),
             "sponsor came through as %Ecto.Association.NotLoaded{}"

      refute match?(%Ecto.Association.NotLoaded{}, first.plans),
             "plans came through as %Ecto.Association.NotLoaded{}"

      assert first.project.id == project.id
      assert first.epic.id == epic.id
      assert is_nil(first.sponsor), "this fixture has no sponsor; nil is loaded-and-empty"

      assert [%{id: plan_id} = loaded_plan] = first.plans
      assert plan_id == plan.id

      refute match?(%Ecto.Association.NotLoaded{}, loaded_plan.stages),
             "plans: :stages came through as %Ecto.Association.NotLoaded{} — the nested " <>
               "preload is part of the payload contract, not decoration"

      assert [%{name: "coding"}] = loaded_plan.stages
    end
  end

  describe "the pointer is left alone when the new phase resolves to no one new" do
    test "no execution entry falls back to the task owner instead of nilling the pointer", %{
      project: project,
      planner: planner
    } do
      task =
        task_with_phases(project, "planning", planner, %{"planning" => phase_entry(planner)})

      {:ok, updated} = Tasks.transition_task_status(task, "in_progress")

      assert updated.status == "in_progress"

      assert updated.assignee_id == planner.id,
             "with no execution entry, `assignee_for_phase/2` falls back to the top-level " <>
               "owner — the pointer must survive the transition, not be nilled"

      assert updated.assignee_type == "agent"
    end

    test "no phase entry AND no owner leaves the pointer nil and broadcasts nothing extra", %{
      project: project,
      planner: planner
    } do
      task =
        project
        |> task_with_phases("planning", planner, %{"planning" => phase_entry(planner)})
        |> put_task_fields(%{assignee_id: nil, assignee_type: nil})

      Tasks.subscribe_board()

      {:ok, updated} = Tasks.transition_task_status(task, "in_progress")

      assert is_nil(updated.assignee_id)
      assert is_nil(updated.assignee_type)

      # `is_nil(phase_id)` arm: nothing to write, so no pointer-move
      # broadcast. `transition_task_status/2` is not otherwise a board
      # publisher, so a payload here would mean the guard leaked.
      assert board_updates(task.id) == [],
             "the is_nil(phase_id) arm must not broadcast a pointer move"
    end

    test "a malformed phase assignee id does not block the status transition", %{
      project: project,
      planner: planner
    } do
      # `Task.validate_phase_assignees/1` (`tasks/task.ex:348`) validates the
      # phase KEYS only, so an MCP `task_update` can persist a non-UUID
      # assignee id. RED on the pre-fold code with a raise, not a soft
      # failure — verbatim:
      #
      #   ** (Ecto.ChangeError) value `"higgins"` for
      #   `Platform.Tasks.Task.assignee_id` in `update` does not match type
      #   :binary_id
      #
      # i.e. the old second write did NOT fall into
      # `maybe_apply_phase_assignee/1`'s `_error -> :ok` arm (`:binary_id` is
      # a dump-time error, which raises rather than invalidating the
      # changeset), so a malformed phase payload took the whole transition
      # down. The `Platform.UUID.valid?/1` guard in `phase_pointer_attrs/2`
      # is what makes this green.
      task =
        project
        |> task_with_phases("planning", planner, %{
          "planning" => phase_entry(planner),
          "execution" => %{"assignee_id" => "higgins", "assignee_type" => "agent"}
        })

      assert {:ok, updated} = Tasks.transition_task_status(task, "in_progress")
      assert updated.status == "in_progress"
      assert updated.assignee_id == planner.id
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp task_with_phases(project, status, owner, phase_assignees) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Phase Pointer Task #{System.unique_integer([:positive])}",
        deploy_target: "production"
      })

    put_task_fields(task, %{
      status: status,
      assignee_id: owner.id,
      assignee_type: "agent",
      phase_assignees: phase_assignees
    })
  end

  # Bypasses `Tasks.update_task/2` on purpose: the fixture has to be the
  # exact DB state, not whatever the writers would normalise it into.
  defp put_task_fields(%TaskSchema{} = task, fields) do
    task
    |> Ecto.Changeset.change(fields)
    |> Repo.update!()
  end

  defp phase_entry(%Agent{} = agent) do
    %{"assignee_id" => agent.id, "assignee_type" => "agent"}
  end

  defp create_agent(label) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "pointer-#{label}-#{System.unique_integer([:positive])}",
        name: "Phase Pointer #{label}",
        status: "active"
      })
      |> Repo.insert()

    agent
  end

  # ── Observation ─────────────────────────────────────────────────────────

  defp first_board_update!(task_id) do
    case board_updates(task_id) do
      [first | _] ->
        first

      [] ->
        flunk(
          "no {:task_updated, %Task{id: #{task_id}}} reached the tasks:board subscriber; " <>
            "the pointer-move broadcast that `maybe_apply_phase_assignee/1` used to emit " <>
            "is gone and nothing replaced it"
        )
    end
  end

  # Drains the mailbox for the whole window and returns EVERY board update
  # about this task, in arrival order. Deliberately not `assert_receive`: a
  # pattern-matching receive would skip a stale first payload and match the
  # second, which is the exact bug under test.
  defp board_updates(task_id, window_ms \\ @board_window_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    drain_board(task_id, deadline, [])
  end

  defp drain_board(task_id, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {:task_updated, %TaskSchema{id: ^task_id} = task} ->
          drain_board(task_id, deadline, [task | acc])

        {:task_updated, %TaskSchema{}} ->
          # Another test's task on the same global topic. Dropped WITHOUT
          # inspecting status or assignee, so this filter can never hide a
          # stale payload of our own.
          drain_board(task_id, deadline, acc)
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  # Every SQL statement Ecto ran against `tasks` for THIS row while `fun`
  # executed. Filtering on the params is what makes the count safe under a
  # concurrent suite: `[:platform, :repo, :query]` handlers are global, so
  # sibling `async: true` files fire this handler too.
  defp capture_task_queries(task_id, fun) do
    test_pid = self()
    handler_id = "phase-pointer-queries-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :repo, :query],
        fn _event, _measurements, meta, _config ->
          params = Map.get(meta, :params) || []

          if Enum.any?(params, &same_uuid?(&1, task_id)) do
            send(test_pid, {:repo_query, handler_id, Map.get(meta, :query)})
          end
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect_queries(handler_id, [])
  end

  defp collect_queries(handler_id, acc) do
    receive do
      {:repo_query, ^handler_id, query} -> collect_queries(handler_id, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Query params arrive as raw 16-byte binaries, not the hyphenated string.
  defp same_uuid?(param, task_id) when is_binary(param) do
    param == task_id or Ecto.UUID.cast(param) == {:ok, task_id}
  end

  defp same_uuid?(_param, _task_id), do: false
end
