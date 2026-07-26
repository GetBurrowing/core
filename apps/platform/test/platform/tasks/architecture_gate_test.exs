defmodule Platform.Tasks.ArchitectureGateTest do
  @moduledoc """
  ADR-0046 member 5, stage 1 — `plans.architecture_verdict` and the
  gate-state API.

  Every test here is a GUARD, not a fix detector. This stage is entirely
  new code: the column, the narrow changeset and the four context
  functions do not exist on `main`, so none of these tests could
  detonate against unfixed `main` — there is nothing there to fail
  against. The mandatory fix detectors for this task live in stages 2
  and 3, where the plan lifecycle actually changes.

  Guards still have to earn their keep, so each absence assertion is
  paired with a positive control that fails if the validator merely
  rejects everything, and the vacuity controls were run by deliberately
  weakening the implementation. The results are recorded on each guard.
  """
  # `async: true` is safe here: nothing in this module writes through
  # `Tasks.update_task/3` or otherwise broadcasts on `tasks:board`, so
  # the singleton `TaskRouterWatcher` never wakes up holding a
  # connection it does not own. Fixtures go through `Repo.insert!`
  # rather than `Tasks.create_task/1` for the same reason (see
  # `019fa003-091a`).
  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Task

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Architecture Gate Project #{u()}"})

    task =
      Repo.insert!(%Task{project_id: project.id, title: "Gate subject", status: "planning"})

    plan = Repo.insert!(%Plan{task_id: task.id, version: 1, status: "draft"})

    %{project: project, task: task, plan: plan}
  end

  defp u, do: System.unique_integer([:positive])

  defp stored(plan), do: Repo.get(Plan, plan.id).architecture_verdict

  defp pending_verdict(opts \\ []) do
    now = DateTime.utc_now()
    offset_s = Keyword.get(opts, :deadline_offset_s, 900)

    %{
      "state" => "pending",
      "opened_at" => DateTime.to_iso8601(now),
      "deadline_at" =>
        now
        |> DateTime.add(offset_s, :second)
        |> DateTime.to_iso8601()
        |> then(&Keyword.get(opts, :deadline_at, &1)),
      "resolved_at" => nil,
      "resolved_by" => nil,
      "architect_agent_id" => nil,
      "source" => nil,
      "summary" => nil,
      "findings" => []
    }
  end

  defp put_verdict!(plan, verdict) do
    plan
    |> Plan.architecture_verdict_changeset(%{architecture_verdict: verdict})
    |> Repo.update!()
  end

  # `Platform.DataCase` does not define `errors_on/1`; every module in
  # this suite carries its own copy (`planning_step_test.exs:41`,
  # `project_test.exs:138`, ~20 others). Following the local convention
  # rather than hoisting it, which would be a suite-wide change this
  # stage has no mandate for.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "Plan.architecture_verdict_changeset/2 — the narrow write surface" do
    # GUARD, WITH ITS PAIRED POSITIVE CONTROL. The first assertion alone
    # would pass vacuously against a changeset that casts nothing at
    # all; the second half proves the same attrs DO move `:status` when
    # routed through the wide changeset, so the absence in the first
    # half is the narrow cast list doing work.
    #
    # VACUITY CONTROL RUN: replaced the cast list with `cast(attrs, [])`.
    # The first assertion still passed (no `:status` change — trivially),
    # and this test failed on
    # `assert {:ok, verdict} = fetch_change(narrow, :architecture_verdict)`.
    # The control is therefore load-bearing.
    test "casts :architecture_verdict and refuses to smuggle a :status change", %{plan: plan} do
      attrs = %{status: "approved", architecture_verdict: pending_verdict()}

      narrow = Plan.architecture_verdict_changeset(plan, attrs)

      assert narrow.valid?

      assert {:ok, %{"state" => "pending"}} =
               Ecto.Changeset.fetch_change(narrow, :architecture_verdict)

      assert :error == Ecto.Changeset.fetch_change(narrow, :status)

      # The other direction of the same property: `changeset/2` really
      # does write `:status`, which is why verdict writes must not go
      # through it.
      wide = Plan.changeset(plan, attrs)

      assert {:ok, "approved"} = Ecto.Changeset.fetch_change(wide, :status)
      assert :error == Ecto.Changeset.fetch_change(wide, :architecture_verdict)
    end

    # GUARD — closed state vocabulary, with the positive control that
    # the validator can distinguish rather than rejecting everything.
    #
    # VACUITY CONTROL RUN: deleted the `state in @architecture_gate_states`
    # branch (accept any binary state). This test failed on the
    # `refute skipped.valid?` assertion. With the branch restored but
    # `@architecture_gate_states` reduced to `~w(pending)`, it failed on
    # `assert expired.valid?` instead — so both halves bite.
    test "rejects an unknown state and accepts a known one in the same position", %{plan: plan} do
      skipped =
        Plan.architecture_verdict_changeset(plan, %{
          architecture_verdict: %{pending_verdict() | "state" => "skipped"}
        })

      refute skipped.valid?
      assert %{architecture_verdict: [msg]} = errors_on(skipped)
      assert msg =~ ~s(invalid state "skipped")

      expired =
        Plan.architecture_verdict_changeset(plan, %{
          architecture_verdict: %{pending_verdict() | "state" => "expired"}
        })

      assert expired.valid?
    end

    test "requires a string \"state\" key", %{plan: plan} do
      changeset =
        Plan.architecture_verdict_changeset(plan, %{
          architecture_verdict: Map.delete(pending_verdict(), "state")
        })

      refute changeset.valid?
      assert %{architecture_verdict: [msg]} = errors_on(changeset)
      assert msg =~ ~s(must include a string "state" key)
    end

    test "rejects atom keys, because the column round-trips through JSONB", %{plan: plan} do
      changeset =
        Plan.architecture_verdict_changeset(plan, %{architecture_verdict: %{state: "passed"}})

      refute changeset.valid?
      assert %{architecture_verdict: msgs} = errors_on(changeset)
      assert Enum.any?(msgs, &(&1 =~ "must use string keys"))
    end

    # GUARD — ADR-0046:95's closed rejection vocabulary asserted at the
    # schema layer. "Naming" is the canonical thing the ADR says an
    # architect must NOT reject for, and here it has no representable
    # value. Stage 4 asserts the same property again at the MCP tool
    # boundary.
    #
    # VACUITY CONTROL RUN: removed the `constraint in
    # @architecture_constraints` check. This test failed on
    # `refute naming.valid?`. Separately, replacing
    # `@architecture_constraints` with `~w(naming)` made it fail on
    # `assert boundary.valid?`.
    test "a finding may not cite \"naming\"; the same finding citing \"module_boundary\" is valid",
         %{plan: plan} do
      finding = fn constraint ->
        %{
          pending_verdict()
          | "state" => "rejected",
            "findings" => [
              %{
                "stage_id" => nil,
                "stage_name" => "Add the gate",
                "constraint" => constraint,
                "detail" => "Puts a Tasks concern inside Platform.Design."
              }
            ]
        }
      end

      naming =
        Plan.architecture_verdict_changeset(plan, %{architecture_verdict: finding.("naming")})

      refute naming.valid?
      assert %{architecture_verdict: [msg]} = errors_on(naming)
      assert msg =~ ~s(invalid constraint "naming")
      assert msg =~ "ADR-0046:95"

      boundary =
        Plan.architecture_verdict_changeset(plan, %{
          architecture_verdict: finding.("module_boundary")
        })

      assert boundary.valid?
    end

    # GUARD — an objection with no substance is not an objection. A
    # rejection the planner cannot act on is indistinguishable from
    # noise, and member 6 accumulates these across versions.
    #
    # VACUITY CONTROL RUN: removed the `String.trim(detail) == ""`
    # branch; this test failed on `refute changeset.valid?` for the
    # empty-string case. Note the whitespace case is the one that
    # distinguishes `String.trim/1` from a bare `""` comparison.
    test "a finding with an empty or whitespace-only detail is invalid", %{plan: plan} do
      for detail <- ["", "   "] do
        changeset =
          Plan.architecture_verdict_changeset(plan, %{
            architecture_verdict: %{
              pending_verdict()
              | "state" => "rejected",
                "findings" => [%{"constraint" => "data_model", "detail" => detail}]
            }
          })

        refute changeset.valid?, "detail #{inspect(detail)} should be rejected"
        assert %{architecture_verdict: [msg]} = errors_on(changeset)
        assert msg =~ "non-empty string"
      end
    end

    test "findings must be a list of maps carrying both keys", %{plan: plan} do
      not_a_list =
        Plan.architecture_verdict_changeset(plan, %{
          architecture_verdict: %{pending_verdict() | "findings" => "module_boundary"}
        })

      refute not_a_list.valid?
      assert %{architecture_verdict: [msg]} = errors_on(not_a_list)
      assert msg =~ ~s("findings" must be a list)

      missing_detail =
        Plan.architecture_verdict_changeset(plan, %{
          architecture_verdict: %{
            pending_verdict()
            | "findings" => [%{"constraint" => "duplicated_logic"}]
          }
        })

      refute missing_detail.valid?
    end

    test "the exported vocabularies are the ones the validator enforces" do
      assert Plan.architecture_gate_states() ==
               ~w(pending passed rejected expired dispatch_failed human_override)

      assert Plan.architecture_constraints() ==
               ~w(module_boundary data_model cross_context_coupling duplicated_logic)
    end
  end

  describe "Tasks.open_architecture_gate/2" do
    test "writes the full pending shape and a deadline derived from the timeout", %{plan: plan} do
      before = DateTime.utc_now()

      assert {:ok, opened} = Tasks.open_architecture_gate(plan, "agent-moore")

      verdict = opened.architecture_verdict
      assert verdict["state"] == "pending"
      assert verdict["architect_agent_id"] == "agent-moore"
      assert verdict["resolved_at"] == nil
      assert verdict["findings"] == []

      assert {:ok, opened_at, 0} = DateTime.from_iso8601(verdict["opened_at"])
      assert {:ok, deadline_at, 0} = DateTime.from_iso8601(verdict["deadline_at"])
      assert DateTime.compare(opened_at, before) != :lt

      expected = Tasks.architecture_gate_timeout_ms()
      actual = DateTime.diff(deadline_at, opened_at, :millisecond)
      assert_in_delta actual, expected, 50

      assert stored(plan)["state"] == "pending"
    end

    test "cannot move the plan's status", %{plan: plan} do
      assert {:ok, _} = Tasks.open_architecture_gate(plan, nil)
      assert Repo.get(Plan, plan.id).status == "draft"
    end

    test "architecture_gate_timeout_ms/0 is overridable and defaults to 15 minutes" do
      assert Tasks.architecture_gate_timeout_ms() == 15 * 60 * 1_000

      Application.put_env(:platform, :architecture_gate_timeout_ms, 42)
      on_exit(fn -> Application.delete_env(:platform, :architecture_gate_timeout_ms) end)

      assert Tasks.architecture_gate_timeout_ms() == 42
    end
  end

  describe "Tasks.architecture_gate/1 — level-triggered, and it does not write" do
    test "returns :none when the gate never opened for this version", %{plan: plan} do
      assert stored(plan) == nil
      assert Tasks.architecture_gate(plan) == :none
      assert Tasks.architecture_gate(plan.id) == :none
      refute Tasks.architecture_gate_open?(plan)
    end

    test "returns {:open, verdict} while the deadline is in the future", %{plan: plan} do
      put_verdict!(plan, pending_verdict(deadline_offset_s: 900))

      assert {:open, %{"state" => "pending"}} = Tasks.architecture_gate(plan)
      assert Tasks.architecture_gate_open?(plan.id)
    end

    # GUARD — the correctness core of this stage. Both halves are the
    # contract: the projection says expired, and the ROW IS UNCHANGED.
    # Reads decide; writes are someone else's job (stage 5's timer).
    #
    # VACUITY CONTROL RUN: made `classify_architecture_verdict/1` return
    # `{:open, verdict}` unconditionally for `"pending"` — this test
    # failed on the `{:resolved, ...}` match. Separately, made
    # `architecture_gate/1` persist the expired projection before
    # returning it: the return-value half still passed and this test
    # failed on `assert stored(plan)["state"] == "pending"`. Both
    # assertions are independently load-bearing.
    test "reports an overdue pending gate as expired WITHOUT writing", %{plan: plan} do
      put_verdict!(plan, pending_verdict(deadline_offset_s: -1))

      row_before = stored(plan)
      updated_before = Repo.get(Plan, plan.id).updated_at

      assert {:resolved, projected} = Tasks.architecture_gate(plan)
      assert projected["state"] == "expired"
      assert projected["source"] == "deadline"
      refute Tasks.architecture_gate_open?(plan)

      row_after = Repo.get(Plan, plan.id)
      assert row_after.architecture_verdict == row_before
      assert row_after.architecture_verdict["state"] == "pending"
      assert row_after.updated_at == updated_before
    end

    # A pending gate whose deadline cannot be read has no falsifiable
    # end. Reporting it as expired is the deliberate choice documented
    # on `architecture_gate/1`: fail toward "not blocked" (today's
    # behaviour) rather than toward a stranded task.
    test "a pending gate with a missing or unparseable deadline reads as expired", %{plan: plan} do
      for deadline <- [nil, "not-a-timestamp"] do
        verdict = pending_verdict() |> Map.put("deadline_at", deadline)
        put_verdict!(plan, verdict)

        assert {:resolved, %{"state" => "expired"}} = Tasks.architecture_gate(plan),
               "deadline #{inspect(deadline)} should not block forever"

        assert stored(plan)["state"] == "pending"
      end
    end

    test "returns {:resolved, verdict} verbatim for a terminal state", %{plan: plan} do
      resolved = %{pending_verdict() | "state" => "passed", "resolved_by" => "moore"}
      put_verdict!(plan, resolved)

      assert {:resolved, ^resolved} = Tasks.architecture_gate(plan)
      refute Tasks.architecture_gate_open?(plan)
    end

    # The handed-down finding from member 4's review: `AutoMerger`
    # reads its gate state off a struct loaded in the request handler
    # and consulted later in an async Task, so the guard falls open on
    # anything written in between. This gate re-reads.
    test "answers from the row, not from a stale in-memory struct", %{plan: plan} do
      stale = Repo.get(Plan, plan.id)
      assert stale.architecture_verdict == nil

      put_verdict!(plan, pending_verdict(deadline_offset_s: 900))

      assert {:open, _} = Tasks.architecture_gate(stale)
      assert Tasks.architecture_gate_open?(stale)
    end
  end

  describe "Tasks.record_architecture_verdict/3 — one-shot" do
    setup %{plan: plan} do
      {:ok, opened} = Tasks.open_architecture_gate(plan, "agent-moore")
      %{opened: opened}
    end

    test "writes a terminal state, stamps resolved_at, and preserves the open fields", %{
      opened: opened
    } do
      assert {:ok, resolved} =
               Tasks.record_architecture_verdict(
                 opened,
                 %{"state" => "passed", "summary" => "Boundaries hold."},
                 resolved_by: "agent-moore",
                 source: "mcp"
               )

      verdict = resolved.architecture_verdict
      assert verdict["state"] == "passed"
      assert verdict["summary"] == "Boundaries hold."
      assert verdict["resolved_by"] == "agent-moore"
      assert verdict["source"] == "mcp"
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(verdict["resolved_at"])

      # Merged, not replaced.
      assert verdict["opened_at"] == opened.architecture_verdict["opened_at"]
      assert verdict["deadline_at"] == opened.architecture_verdict["deadline_at"]
      assert verdict["architect_agent_id"] == "agent-moore"

      assert {:resolved, ^verdict} = Tasks.architecture_gate(opened)
      refute Tasks.architecture_gate_open?(opened)
    end

    # GUARD (one-shot). A duplicate MCP call must be harmless, and it is
    # only harmless if the second call is BOTH refused and inert.
    #
    # VACUITY CONTROL RUN: dropped the `state = 'pending'` predicate
    # from the guarded UPDATE and let the second write through — this
    # test failed on `assert {:error, :gate_already_resolved}`. With the
    # error returned but the write still performed (predicate dropped,
    # error faked off the pre-read), it failed on the byte-identity
    # assertion instead.
    test "a second call is refused and changes nothing", %{opened: opened} do
      assert {:ok, first} =
               Tasks.record_architecture_verdict(opened, %{"state" => "passed"}, source: "mcp")

      after_first = stored(opened)

      assert {:error, :gate_already_resolved} =
               Tasks.record_architecture_verdict(
                 opened,
                 %{"state" => "rejected", "summary" => "second opinion"},
                 source: "human"
               )

      assert stored(opened) == after_first
      assert after_first["state"] == "passed"
      assert after_first["resolved_at"] == first.architecture_verdict["resolved_at"]
      assert after_first["summary"] == nil
    end

    test "refuses a gate that never opened", %{task: task} do
      never_opened = Repo.insert!(%Plan{task_id: task.id, version: 2, status: "draft"})

      assert {:error, :gate_not_open} =
               Tasks.record_architecture_verdict(never_opened, %{"state" => "passed"})
    end

    test "refuses to re-open through the verdict writer", %{opened: opened} do
      assert {:error, :verdict_state_not_terminal} =
               Tasks.record_architecture_verdict(opened, %{"state" => "pending"})

      assert stored(opened)["state"] == "pending"
    end

    test "refuses an unknown plan id", %{plan: plan} do
      assert {:error, :plan_not_found} =
               Tasks.record_architecture_verdict(Ecto.UUID.generate(), %{"state" => "passed"})

      assert stored(plan)["state"] == "pending"
    end

    test "returns a changeset error for an invalid verdict and writes nothing", %{opened: opened} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Tasks.record_architecture_verdict(opened, %{
                 "state" => "rejected",
                 "findings" => [%{"constraint" => "style", "detail" => "ugly"}]
               })

      assert %{architecture_verdict: [msg]} = errors_on(changeset)
      assert msg =~ ~s(invalid constraint "style")
      assert stored(opened)["state"] == "pending"
    end

    # An overdue-but-unwritten gate still reads `"pending"` in the row,
    # so an architect whose answer beats stage 5's timer to the write
    # genuinely wins. This is the one place the level projection is
    # deliberately NOT consulted — see the @doc.
    test "a late verdict beating the deadline sweep to the write still wins", %{
      plan: plan,
      opened: opened
    } do
      put_verdict!(plan, %{opened.architecture_verdict | "deadline_at" => iso_ago(60)})

      assert {:resolved, %{"state" => "expired"}} = Tasks.architecture_gate(plan)

      assert {:ok, resolved} =
               Tasks.record_architecture_verdict(plan, %{"state" => "rejected"}, source: "mcp")

      assert resolved.architecture_verdict["state"] == "rejected"
      assert {:resolved, %{"state" => "rejected"}} = Tasks.architecture_gate(plan)
    end

    test "cannot move the plan's status", %{opened: opened} do
      assert {:ok, _} = Tasks.record_architecture_verdict(opened, %{"state" => "passed"})
      assert Repo.get(Plan, opened.id).status == "draft"
    end
  end

  defp iso_ago(seconds) do
    DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()
  end
end
