defmodule Platform.Tasks.OperatorCorrectionTest do
  @moduledoc """
  Task 01a049be — `cancelled` is absorbing, so a wrongly-closed task can
  never be corrected.

  Two halves, and both are load-bearing:

    * The **premise** describes, as executable assertions, the trap that
      produced 13 shipped-but-`cancelled` tasks: `done` is unreachable from
      `backlog`, `cancelled` is reachable from `backlog`, and `cancelled`
      has no way out. Those assertions must STAY GREEN — the fix does not
      widen `@valid_task_transitions`, and if someone later widens it these
      go red and make them confront the decision rather than inherit it.

    * The **corrections** cover the two new admin-gated repair paths.

  The anti-vacuity guard is explicit: a change that let everything reach
  everything would satisfy the ticket's headline and destroy the state
  machine, so "still refused" is asserted as loudly as "now allowed", and
  every negative assertion is paired with a positive control of the same
  shape so a broken fixture cannot masquerade as a passing refusal.
  """
  use Platform.DataCase, async: true

  import Platform.TenancyFixtures, only: [fabrikam_org_id: 0]

  alias Platform.Accounts.User
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.PhaseTransition
  alias Platform.Tasks.Task
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Correction Project"})
    %{project: project}
  end

  # ── fixtures ──────────────────────────────────────────────────────────

  defp user!(role) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        # Deliberately NOT an @example.com address: `Platform.Accounts`
        # DERIVES `:admin` from that domain, so a kobo-ai email would make
        # the `:not_authorized` tests pass for a reason unrelated to the
        # membership row under test.
        email: "correction-#{n}@example.com",
        name: "Correction #{n}",
        oidc_sub: "oidc-correction-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: fabrikam_org_id(), role: role})
    |> Repo.insert!()

    user
  end

  defp admin! do
    admin = user!("admin")
    # Guard the fixture itself: every `:not_authorized` assertion below is
    # only meaningful if this really is an admin.
    assert Tenancy.fabrikam_admin?(admin)
    admin
  end

  defp member! do
    member = user!("member")
    refute Tenancy.fabrikam_admin?(member)
    member
  end

  # Places a task in `status` by writing the changeset directly. Setup
  # only — it deliberately bypasses the transition table, because several
  # of the statuses under test are not reachable from `backlog` at all,
  # which is the whole subject of this module.
  #
  # `deploy_target` is set so that `require_deploy_target_for/2` cannot
  # answer before the transition table does: without it, a probe of
  # `x -> deploying` returns `:no_deploy_target_resolved` and a test that
  # expected `:invalid_transition` would fail for the wrong reason.
  defp task!(project, status, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            title: "Task #{System.unique_integer([:positive])}",
            deploy_target: "production"
          },
          attrs
        )
      )

    {:ok, task} = task |> Task.changeset(%{status: status}) |> Repo.update()
    assert task.status == status
    task
  end

  defp reload(task), do: Tasks.get_task_record(task.id)

  # ── premise: the trap, as executable assertions ───────────────────────

  describe "the trap (premise — these must stay green)" do
    test "`done` is unreachable from `backlog`, but reachable from `in_progress`",
         %{project: project} do
      backlog = task!(project, "backlog")

      assert {:error, :invalid_transition} = Tasks.transition_task_status(backlog, "done")
      assert reload(backlog).status == "backlog"

      # POSITIVE CONTROL. Same call, same helper, same fixture shape — and
      # it succeeds. So the refusal above is the transition table
      # answering, not a broken setup or a guard tripping earlier.
      running = task!(project, "in_progress")
      assert {:ok, %Task{status: "done"}} = Tasks.transition_task_status(running, "done")
    end

    test "`cancelled` has no outbound edge to ANY status, while the door in stays open",
         %{project: project} do
      cancelled = task!(project, "cancelled")

      for target <- Task.statuses() -- ["cancelled"] do
        case target do
          # `stack_pending` on a stackless task is refused by the stack guard
          # (01a05393 stage 6) BEFORE the table is consulted; the door is
          # still shut, only the refusal's name differs.
          "stack_pending" ->
            assert {:error, :stack_pending_requires_stack, %{}} =
                     Tasks.transition_task_status(cancelled, target),
                   "expected `cancelled -> #{target}` to be refused ahead of the transition table"

          _ ->
            assert {:error, :invalid_transition} =
                     Tasks.transition_task_status(cancelled, target),
                   "expected `cancelled -> #{target}` to be refused by the transition table"
        end
      end

      assert reload(cancelled).status == "cancelled"

      # POSITIVE CONTROL, and it is the point of the ticket: the door INTO
      # `cancelled` is wide open from the very status that cannot reach
      # `done`. An empty outbound list plus a reachable inbound edge is
      # what makes the state absorbing rather than merely narrow.
      backlog = task!(project, "backlog")

      assert {:ok, %Task{status: "cancelled"}} =
               Tasks.transition_task_status(backlog, "cancelled")
    end

    test "`task_complete` refuses a backlog task and no longer routes it to `cancelled`",
         %{project: project} do
      backlog = task!(project, "backlog")

      assert {:error, envelope} =
               ToolSurface.execute("task_complete", %{"task_id" => backlog.id}, %{})

      assert envelope.error =~ "Cannot transition task from 'backlog' to 'done'"
      assert reload(backlog).status == "backlog"

      # The exact sentence that manufactured the corruption. An agent that
      # read it did the wrong thing and could not undo it.
      refute envelope.suggestion =~
               "If you want to retire a non-started task instead, use task_update with status='cancelled'"

      # POSITIVE CONTROL for the `refute` above: the suggestion is a
      # populated string that names the real route, so the refutation is
      # reading real guidance rather than an empty or missing field.
      assert envelope.suggestion =~ "close_as_delivered"
      assert envelope.suggestion =~ "in_review"

      # POSITIVE CONTROL on the tool itself: `task_complete` still works
      # where it always did, so the envelope above is a genuine refusal
      # and not the tool being broken outright.
      running = task!(project, "in_progress")

      assert {:ok, %{status: "done"}} =
               ToolSurface.execute("task_complete", %{"task_id" => running.id}, %{})
    end

    test "`task_update`'s invalid-transition envelope no longer sells `cancelled` as the exit",
         %{project: project} do
      backlog = task!(project, "backlog")

      assert {:error, envelope} =
               ToolSurface.execute(
                 "task_update",
                 %{"task_id" => backlog.id, "status" => "done"},
                 %{}
               )

      assert envelope.error =~ "Invalid status transition from 'backlog' to 'done'"
      assert reload(backlog).status == "backlog"

      refute envelope.suggestion =~
               "To retire a non-started task without walking it through in_progress, transition to 'cancelled'"

      assert envelope.suggestion =~ "reinstate_cancelled_task"
      assert envelope.suggestion =~ "TERMINAL"
    end
  end

  # ── anti-vacuity: what must STILL be refused ──────────────────────────

  describe "the transition table is not widened" do
    test "`cancelled` still has zero outbound edges in the pipeline table" do
      assert Tasks.valid_task_transitions()["cancelled"] == []
    end

    test "`done` is still absent from every status `close_as_delivered/3` accepts" do
      table = Tasks.valid_task_transitions()

      for status <- Tasks.undeliverable_statuses() do
        refute "done" in Map.fetch!(table, status),
               "`#{status} -> done` must stay closed to the automated pipeline; " <>
                 "the correction path is admin-gated on purpose"
      end

      # POSITIVE CONTROL: the table genuinely carries `done` edges, so the
      # refutations above are reading a populated table rather than an
      # empty map that would make any `refute … in …` trivially pass.
      assert "done" in Map.fetch!(table, "in_progress")
      assert "done" in Map.fetch!(table, "in_review")
      assert "done" in Map.fetch!(table, "deploying")
    end

    test "the agent-reachable surface gains no route to `done` or out of `cancelled`",
         %{project: project} do
      backlog = task!(project, "backlog")
      cancelled = task!(project, "cancelled")

      # `task_complete` and `task_update` are the two agent-reachable
      # status writers. Neither moves after this change.
      assert {:error, _} = ToolSurface.execute("task_complete", %{"task_id" => backlog.id}, %{})

      assert {:error, _} =
               ToolSurface.execute("task_complete", %{"task_id" => cancelled.id}, %{})

      for target <- ~w(backlog in_progress done) do
        assert {:error, _} =
                 ToolSurface.execute(
                   "task_update",
                   %{"task_id" => cancelled.id, "status" => target},
                   %{}
                 )
      end

      assert reload(backlog).status == "backlog"
      assert reload(cancelled).status == "cancelled"
    end
  end

  # ── reinstate_cancelled_task/3 ────────────────────────────────────────

  describe "reinstate_cancelled_task/3" do
    test "an admin returns a cancelled task to backlog, stamped and attributed",
         %{project: project} do
      admin = admin!()
      cancelled = task!(project, "cancelled")
      :ok = Tasks.subscribe_board(task: cancelled.id)

      assert {:ok, reinstated} =
               Tasks.reinstate_cancelled_task(
                 cancelled.id,
                 "shipped as fe85bcf1, not abandoned",
                 admin
               )

      assert reinstated.status == "backlog"
      assert reload(cancelled).status == "backlog"

      stamp = reinstated.metadata["reinstated_from_cancelled"]
      assert stamp["reason"] == "shipped as fe85bcf1, not abandoned"
      assert stamp["by_user_id"] == admin.id
      assert {:ok, _, _} = DateTime.from_iso8601(stamp["at"])

      # The repair is attributed as HUMAN time, not engine time — the
      # whole reason `TransitionActor` exists.
      row =
        PhaseTransition
        |> where([t], t.task_id == ^cancelled.id and t.to_status == "backlog")
        |> Repo.one!()

      assert row.actor_kind == "user"
      assert row.actor_id == admin.id

      task_id = cancelled.id
      assert_receive {:task_updated, %{id: ^task_id, status: "backlog"}}
    end

    test "an existing metadata key survives the correction stamp", %{project: project} do
      admin = admin!()
      cancelled = task!(project, "cancelled", %{metadata: %{"keep_me" => "yes"}})

      assert {:ok, reinstated} = Tasks.reinstate_cancelled_task(cancelled.id, "wrong call", admin)

      assert reinstated.metadata["keep_me"] == "yes"
      assert reinstated.metadata["reinstated_from_cancelled"]["reason"] == "wrong call"
    end

    test "a blank reason is refused and the task does not move", %{project: project} do
      admin = admin!()
      cancelled = task!(project, "cancelled")

      for reason <- [nil, "", "   ", "\t\n  "] do
        assert {:error, :reason_required} =
                 Tasks.reinstate_cancelled_task(cancelled.id, reason, admin)
      end

      assert reload(cancelled).status == "cancelled"

      # POSITIVE CONTROL: same admin, same task, a real reason — it moves.
      assert {:ok, _} = Tasks.reinstate_cancelled_task(cancelled.id, "a real reason", admin)
    end

    test "a task that is not cancelled is refused", %{project: project} do
      admin = admin!()

      for status <-
            ~w(backlog planning in_progress in_review deploying done blocked stack_pending) do
        task = task!(project, status)

        assert {:error, :not_cancelled} =
                 Tasks.reinstate_cancelled_task(task.id, "reason", admin),
               "expected reinstate to refuse a task in `#{status}`"

        assert reload(task).status == status
      end

      # POSITIVE CONTROL: the identical call on a cancelled task succeeds.
      cancelled = task!(project, "cancelled")

      assert {:ok, %Task{status: "backlog"}} =
               Tasks.reinstate_cancelled_task(cancelled.id, "reason", admin)
    end

    test "a non-admin cannot use the correction path", %{project: project} do
      cancelled = task!(project, "cancelled")

      for actor <- [member!(), :system, {:agent, Ecto.UUID.generate()}, nil, "not-a-user"] do
        assert {:error, :not_authorized} =
                 Tasks.reinstate_cancelled_task(cancelled.id, "reason", actor),
               "expected #{inspect(actor)} to be refused"
      end

      assert reload(cancelled).status == "cancelled"

      # POSITIVE CONTROL: the refusals above are the admin gate, not a
      # blanket failure — an actual admin gets through.
      assert {:ok, %Task{status: "backlog"}} =
               Tasks.reinstate_cancelled_task(cancelled.id, "reason", admin!())
    end

    test "authorization is answered before status, so a non-admin cannot probe", %{
      project: project
    } do
      done = task!(project, "done")

      # A non-admin asking about a task that is not cancelled learns only
      # that they are not authorized — never `:not_cancelled`.
      assert {:error, :not_authorized} =
               Tasks.reinstate_cancelled_task(done.id, "reason", member!())

      # POSITIVE CONTROL: an admin asking the same question DOES get the
      # status-specific answer, so the ordering above is real.
      assert {:error, :not_cancelled} =
               Tasks.reinstate_cancelled_task(done.id, "reason", admin!())
    end

    test "a missing task is reported as :not_found to an admin" do
      assert {:error, :not_found} =
               Tasks.reinstate_cancelled_task(Ecto.UUID.generate(), "reason", admin!())
    end
  end

  # ── close_as_delivered/3 ──────────────────────────────────────────────

  describe "close_as_delivered/3" do
    test "an admin records delivered work as done, with the reference persisted",
         %{project: project} do
      admin = admin!()
      backlog = task!(project, "backlog")
      :ok = Tasks.subscribe_board(task: backlog.id)

      assert {:ok, closed} = Tasks.close_as_delivered(backlog.id, "fe85bcf1 (#841)", admin)

      assert closed.status == "done"
      assert reload(backlog).status == "done"

      stamp = closed.metadata["closed_as_delivered"]
      assert stamp["reference"] == "fe85bcf1 (#841)"
      assert stamp["by_user_id"] == admin.id
      # `from_status` is what makes the 13 historical rows re-derivable
      # later without guessing.
      assert stamp["from_status"] == "backlog"
      assert {:ok, _, _} = DateTime.from_iso8601(stamp["at"])

      row =
        PhaseTransition
        |> where([t], t.task_id == ^backlog.id and t.to_status == "done")
        |> Repo.one!()

      assert row.actor_kind == "user"
      assert row.actor_id == admin.id

      task_id = backlog.id
      assert_receive {:task_updated, %{id: ^task_id, status: "done"}}
    end

    test "every status from which `done` is otherwise unreachable is accepted",
         %{project: project} do
      admin = admin!()

      for status <- Tasks.undeliverable_statuses() do
        task = task!(project, status)

        assert {:ok, %Task{status: "done"} = closed} =
                 Tasks.close_as_delivered(task.id, "sha-#{status}", admin),
               "expected close_as_delivered to accept a task in `#{status}`"

        assert closed.metadata["closed_as_delivered"]["from_status"] == status
      end
    end

    test "a blank delivery reference is refused and the task does not move",
         %{project: project} do
      admin = admin!()
      backlog = task!(project, "backlog")

      for ref <- [nil, "", "   ", "\t\n  "] do
        assert {:error, :delivery_reference_required} =
                 Tasks.close_as_delivered(backlog.id, ref, admin)
      end

      assert reload(backlog).status == "backlog"

      # POSITIVE CONTROL.
      assert {:ok, _} = Tasks.close_as_delivered(backlog.id, "abc1234", admin)
    end

    test "statuses that already have a legitimate route to `done` are refused",
         %{project: project} do
      admin = admin!()

      # `in_progress` / `in_review` / `deploying` can reach `done` through
      # the pipeline. Offering a second, gate-free route would turn a
      # bookkeeping repair into a way to skip review — exactly the
      # widening the ticket forbids.
      for status <- ~w(in_progress in_review deploying done cancelled) do
        task = task!(project, status)

        assert {:error, :not_correctable} =
                 Tasks.close_as_delivered(task.id, "sha", admin),
               "expected close_as_delivered to refuse a task in `#{status}`"

        assert reload(task).status == status
      end

      # POSITIVE CONTROL: the refusals above are the status guard, not a
      # broken function — a backlog task goes through.
      backlog = task!(project, "backlog")
      assert {:ok, %Task{status: "done"}} = Tasks.close_as_delivered(backlog.id, "sha", admin)
    end

    test "a cancelled task must be reinstated first — the repair leaves two auditable steps",
         %{project: project} do
      admin = admin!()
      cancelled = task!(project, "cancelled")

      assert {:error, :not_correctable} = Tasks.close_as_delivered(cancelled.id, "sha", admin)

      assert {:ok, _} =
               Tasks.reinstate_cancelled_task(cancelled.id, "shipped, not abandoned", admin)

      assert {:ok, %Task{} = closed} = Tasks.close_as_delivered(cancelled.id, "fe85bcf1", admin)

      assert closed.status == "done"
      # Both steps are on the record, in order.
      assert closed.metadata["reinstated_from_cancelled"]["reason"] == "shipped, not abandoned"
      assert closed.metadata["closed_as_delivered"]["reference"] == "fe85bcf1"
      assert closed.metadata["closed_as_delivered"]["from_status"] == "backlog"
    end

    test "a non-admin cannot record work as delivered", %{project: project} do
      backlog = task!(project, "backlog")

      for actor <- [member!(), :system, {:agent, Ecto.UUID.generate()}, nil, "not-a-user"] do
        assert {:error, :not_authorized} =
                 Tasks.close_as_delivered(backlog.id, "sha", actor),
               "expected #{inspect(actor)} to be refused"
      end

      assert reload(backlog).status == "backlog"

      # POSITIVE CONTROL.
      assert {:ok, %Task{status: "done"}} = Tasks.close_as_delivered(backlog.id, "sha", admin!())
    end

    test "a missing task is reported as :not_found to an admin" do
      assert {:error, :not_found} =
               Tasks.close_as_delivered(Ecto.UUID.generate(), "sha", admin!())
    end
  end

  # ── operator-console ergonomics ───────────────────────────────────────

  describe "a malformed task id" do
    test "is reported as :not_found, not a cast error" do
      admin = admin!()

      # These are operator-console entry points: the id is typed or pasted,
      # so a truncated uuid is the realistic failure. Unguarded, `Repo.get/2`
      # raises `Ecto.Query.CastError` and the operator gets a stacktrace
      # instead of an answer.
      for bad <- ["", "not-a-uuid", "01a049be", String.duplicate("z", 36)] do
        assert {:error, :not_found} = Tasks.reinstate_cancelled_task(bad, "reason", admin),
               "expected a malformed id #{inspect(bad)} to be refused, not to raise"

        assert {:error, :not_found} = Tasks.close_as_delivered(bad, "sha", admin)
      end

      # POSITIVE CONTROL: a well-formed id for a task that does not exist
      # takes the SAME exit, so the guard above is rejecting the shape and
      # not swallowing every call.
      assert {:error, :not_found} =
               Tasks.reinstate_cancelled_task(Ecto.UUID.generate(), "reason", admin)
    end
  end
end
