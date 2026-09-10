defmodule Platform.Tasks.ArchitectureRejectionStreakTest do
  @moduledoc """
  ADR-0046 member 6 stage 1 — the derived rejection streak, its bound, and
  the accumulated disagreement.

  ## Every test here is a GUARD, and that is not a hedge

  With ONE exception, added later and labelled at its own call site: "two
  stages at one position render in a total order" is a DETECTOR for ticket
  01a089e6, and it reds on unfixed `main`. Everything else here is a guard.

  `Platform.Tasks.ArchitectureRejection` is entirely new code in this
  stage. There is no defect on unfixed `main` for any of it to detonate
  against — nothing calls it yet, and nothing behaves differently because
  it exists. Labelling one of these a DETECTOR would be a relabelling, not
  a discovery. The mandatory fix detectors for this task live in stages 3
  and 4, where the walk is wired into `resolve_architecture_gate/3` and the
  bound actually stops a loop.

  What these guards ARE load-bearing against is a future edit to the walk,
  which is why several of them are PAIRED: an absence assertion whose
  positive control runs in the same test against the same mechanism. An
  absence that no positive half accompanies passes against a function that
  returns a constant, and this stage's whole surface is small enough that
  such a function would be easy to write by accident.

  ## VACUITY CONTROLS, MEASURED (8/8 detected, at commit 18417aa0)

  Each control changes exactly one thing in
  `Platform.Tasks.ArchitectureRejection` and nothing in this file.

    1. WALK BY `inserted_at`: replaced `Enum.reverse/1` with
       `Enum.sort_by(& &1.inserted_at, {:desc, DateTime})`. 2 failures —
       both ordering guards, in both directions. Detected.
    2. CONSTANT STREAK: `streak/1` returns the literal `1`. 10 failures.
       Detected — and it is the control that found the vacuity fixed
       below.
    3. READ `plans.status`: `architecture_rejected?/1` matched on
       `%Plan{status: "rejected"}` instead of the verdict. 11 failures,
       including the supersession guard. Detected — this is the one that
       proves the walk reads `architecture_verdict` and not the status
       column that supersession actually rewrites.
    4. NO RUN BOUNDARY: `Enum.take_while/2` -> `Enum.filter/2`, counting
       every rejection in the task's history rather than the consecutive
       run. 4 failures. Detected.
    5. UNORDERED STAGES: `objection_history/1`'s preload ordered
       `desc: position`. 1 failure. Detected.
    6. CONSTANT `escalation_due?/1`: always `false`. 3 failures.
       Detected — this is the half the paired positive control exists
       for.
    7. TWO WALKS: `objection_history/1` walked `Tasks.list_plans/1`
       itself with no truncation, leaving `streak/1` correct. 2 failures.
       Detected — the one-walk property is load-bearing.
    8. FINDINGS NOT VERBATIM: dropped `"stage_id"` from each finding on
       the way out. 1 failure. Detected.

  ### The vacuity control 2 found, and the fix

  Control 2 left "truncates at the same boundary as streak/1" PASSING:
  that test's fixture has a streak of 1, so `length(history) == streak(t)`
  is also satisfied by a `streak/1` that ignores its argument and returns
  the constant 1. The one-walk assertion was therefore vacuous in the only
  place it was made. It is now additionally asserted at a streak of 2 in
  the test above it, where a constant cannot satisfy both.

  ### Two assertions that pass trivially, declared rather than counted

    * `assert "passed" in breaking_states` and its three siblings restate
      member 5's `Plan.architecture_gate_states/0`. NO change to this
      module can make them fail — they are a tripwire against a state
      being REMOVED upstream, and nothing more. The derived `for`
      comprehension underneath them is the part that carries weight.
    * "the limit is a positive integer exposed through an accessor" is a
      type assertion. It passes for any positive integer and cannot
      detect a wrong bound. The bound's actual value is exercised only
      relatively, through `reject_limit/0`, which is deliberate — a test
      asserting `== 2` would be the hardcoded second copy the accessor
      exists to prevent.

  Not `async: true`: the supersession guard drives the real
  `Tasks.approve_plan/3`, which broadcasts on `tasks:board` and wakes the
  singleton `TaskRouterWatcher` (`019fa003-091a`).
  """
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.ArchitectureRejection
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stage

  defp u, do: System.unique_integer([:positive])

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Arch Streak Project #{u()}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Arch streak task #{u()}",
        status: "planning"
      })

    %{project: project, task: task}
  end

  # Plans are built directly rather than through `Tasks.create_plan/1` so
  # the version is explicit — the ordering guard below depends on being
  # able to insert v2 before v1, which the auto-versioning path forbids by
  # construction.
  defp insert_plan(task, version, opts) do
    {:ok, plan} =
      %Plan{}
      |> Plan.changeset(%{
        task_id: task.id,
        version: version,
        status: Keyword.get(opts, :status, "pending_review")
      })
      |> Repo.insert()

    plan
    |> put_verdict(Keyword.get(opts, :verdict, nil), Keyword.get(opts, :findings, nil))
    |> add_stages(Keyword.get(opts, :stages, []))
  end

  # Written through member 5's sanctioned write surface — the one
  # changeset that may cast `:architecture_verdict` — so a verdict this
  # test can build is a verdict the production writers could also have
  # built. Hand-poking the column with `Repo.update_all` would let these
  # guards pass against payloads the schema refuses.
  defp put_verdict(plan, nil, _findings), do: plan

  defp put_verdict(plan, state, findings) when is_binary(state) do
    verdict =
      %{
        "state" => state,
        "summary" => "summary for v#{plan.version}",
        "resolved_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
      |> then(fn v -> if findings, do: Map.put(v, "findings", findings), else: v end)

    {:ok, updated} =
      plan
      |> Plan.architecture_verdict_changeset(%{architecture_verdict: verdict})
      |> Repo.update()

    updated
  end

  defp add_stages(plan, []), do: plan

  defp add_stages(plan, names) do
    # Inserted in REVERSE position order so `objection_history/1`'s
    # `order_by: position` is doing real work rather than agreeing with
    # insertion order by luck.
    names
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.each(fn {name, position} ->
      Repo.insert!(%Stage{plan_id: plan.id, position: position, name: name})
    end)

    plan
  end

  # The constraint vocabulary is READ from member 5's accessor, never
  # retyped. A local copy of those literals anywhere in this task is a
  # defect (stage 3 asserts that about the lib file); this test file holds
  # to the same rule.
  defp a_constraint, do: Plan.architecture_constraints() |> hd()
  defp another_constraint, do: Plan.architecture_constraints() |> Enum.at(1)

  defp finding(stage_name, constraint, detail) do
    %{
      "stage_id" => Ecto.UUID.generate(),
      "stage_name" => stage_name,
      "constraint" => constraint,
      "detail" => detail
    }
  end

  # ── the arithmetic ────────────────────────────────────────────────────

  describe "streak/1" do
    test "a task with no plans has no streak", %{task: task} do
      assert ArchitectureRejection.streak(task.id) == 0
    end

    test "a version whose gate never opened does not count", %{task: task} do
      insert_plan(task, 1, verdict: nil)

      assert Repo.get_by!(Plan, task_id: task.id).architecture_verdict == nil
      assert ArchitectureRejection.streak(task.id) == 0
    end

    test "a passed version does not count", %{task: task} do
      insert_plan(task, 1, verdict: "passed")

      assert ArchitectureRejection.streak(task.id) == 0
    end

    test "one rejection counts once", %{task: task} do
      insert_plan(task, 1, verdict: "rejected")

      assert ArchitectureRejection.streak(task.id) == 1
    end

    test "two consecutive rejections count twice", %{task: task} do
      insert_plan(task, 1, verdict: "rejected")
      insert_plan(task, 2, verdict: "rejected")

      assert ArchitectureRejection.streak(task.id) == 2
    end
  end

  # ── the requirement: the count survives v2 supersession ───────────────

  describe "streak/1 across a real supersession" do
    test "counts both versions after approve_plan/3 has rewritten v1's status", %{task: task} do
      # v1 is architecture-rejected and then approved anyway (the gate is
      # RESOLVED, so `architecture_gate_admission/2` is inert). That is a
      # real reachable sequence, and it is what makes v1 an `approved`
      # sibling — the only status supersession actually rewrites.
      v1 = insert_plan(task, 1, verdict: "rejected")
      {:ok, v1} = Tasks.approve_plan(v1, "system:auto")
      assert v1.status == "approved"

      v2 = insert_plan(task, 2, verdict: "rejected")
      {:ok, v2} = Tasks.approve_plan(v2, "system:auto")

      # The supersession path has now run for real. Both rows' `status`
      # fields have been rewritten by it.
      v1 = Repo.get!(Plan, v1.id)
      assert v1.status == "rejected"
      assert v1.superseded_by_plan_id == v2.id
      assert v1.rejection_reason =~ "Superseded by plan v2"
      assert Repo.get!(Plan, v2.id).status == "approved"

      # ...and the streak is unmoved, because the walk reads
      # `architecture_verdict` and not `plans.status`. If it read `status`
      # this would be 1 (only v1 is "rejected") or 0.
      assert v1.architecture_verdict["state"] == "rejected"
      assert Repo.get!(Plan, v2.id).architecture_verdict["state"] == "rejected"
      assert ArchitectureRejection.streak(task.id) == 2
    end
  end

  # ── the third edge case, PAIRED ───────────────────────────────────────

  describe "a non-rejection breaks the streak" do
    test "v1 rejected, v2 passed, v3 rejected is a streak of 1 — and the paired positive control",
         %{task: task} do
      insert_plan(task, 1, verdict: "rejected")
      v2 = insert_plan(task, 2, verdict: "passed")
      insert_plan(task, 3, verdict: "rejected")

      # The pass ended the disagreement; v3's objection is a fresh one.
      assert ArchitectureRejection.streak(task.id) == 1
      refute ArchitectureRejection.escalation_due?(task.id)

      # PAIRED POSITIVE CONTROL. Flip the single value the assertion above
      # is supposed to depend on and nothing else. Without this half, the
      # assertion above passes against a `streak/1` that always returns 1
      # and an `escalation_due?/1` that always returns false.
      put_verdict(v2, "rejected", nil)

      assert ArchitectureRejection.streak(task.id) == 3
      assert ArchitectureRejection.escalation_due?(task.id)
    end

    test "every non-rejected gate state breaks the streak, derived from the accessor" do
      breaking_states = Plan.architecture_gate_states() -- ["rejected"]

      # If member 5 ever adds a seventh state, it lands here automatically
      # and this test fails loudly rather than silently counting it as a
      # break nobody thought about.
      assert "passed" in breaking_states
      assert "human_override" in breaking_states
      assert "expired" in breaking_states
      assert "dispatch_failed" in breaking_states

      for state <- breaking_states ++ [nil] do
        {:ok, project} = Tasks.create_project(%{name: "Break #{u()}"})

        {:ok, scoped} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "break #{inspect(state)} #{u()}",
            status: "planning"
          })

        insert_plan(scoped, 1, verdict: "rejected")
        insert_plan(scoped, 2, verdict: state)
        insert_plan(scoped, 3, verdict: "rejected")

        assert ArchitectureRejection.streak(scoped.id) == 1,
               "#{inspect(state)} at v2 should have broken the streak"
      end
    end
  end

  # ── ordering ──────────────────────────────────────────────────────────

  describe "streak/1 orders by version, not insertion time" do
    test "a rejected v2 inserted BEFORE a passed v1 still counts", %{task: task} do
      insert_plan(task, 2, verdict: "rejected")
      insert_plan(task, 1, verdict: "passed")

      # By `inserted_at` descending the newest row is v1 (passed) and the
      # walk would stop immediately at 0.
      assert ArchitectureRejection.streak(task.id) == 1
    end

    test "a rejected v1 inserted AFTER a passed v2 does not count", %{task: task} do
      insert_plan(task, 2, verdict: "passed")
      insert_plan(task, 1, verdict: "rejected")

      # The opposite discriminator: by `inserted_at` descending this would
      # be 1. By `version` descending the newest version passed, so 0.
      assert ArchitectureRejection.streak(task.id) == 0
    end
  end

  # ── the bound ─────────────────────────────────────────────────────────

  describe "reject_limit/0 and escalation_due?/1" do
    test "the limit is a positive integer exposed through an accessor" do
      assert is_integer(ArchitectureRejection.reject_limit())
      assert ArchitectureRejection.reject_limit() > 0
    end

    test "escalation is due exactly at the limit, never before", %{task: task} do
      limit = ArchitectureRejection.reject_limit()

      for version <- 1..(limit - 1) do
        insert_plan(task, version, verdict: "rejected")

        assert ArchitectureRejection.streak(task.id) == version

        refute ArchitectureRejection.escalation_due?(task.id),
               "escalated at #{version} of #{limit}"
      end

      insert_plan(task, limit, verdict: "rejected")

      assert ArchitectureRejection.streak(task.id) == limit
      assert ArchitectureRejection.escalation_due?(task.id)
    end

    test "escalation stays due past the limit", %{task: task} do
      limit = ArchitectureRejection.reject_limit()

      for version <- 1..(limit + 1), do: insert_plan(task, version, verdict: "rejected")

      assert ArchitectureRejection.escalation_due?(task.id)
    end

    test "a task with no rejections is never due", %{task: task} do
      refute ArchitectureRejection.escalation_due?(task.id)
    end
  end

  # ── the accumulated disagreement ──────────────────────────────────────

  describe "objection_history/1" do
    test "returns exactly the streak's versions, newest first, findings verbatim", %{task: task} do
      v1_findings = [finding("Alpha", a_constraint(), "v1 detail")]

      v2_findings = [
        finding("Gamma", another_constraint(), "v2 first detail"),
        finding(nil, a_constraint(), "v2 second detail")
      ]

      insert_plan(task, 1,
        verdict: "rejected",
        findings: v1_findings,
        stages: ["Alpha", "Beta"]
      )

      insert_plan(task, 2,
        verdict: "rejected",
        findings: v2_findings,
        stages: ["Gamma", "Delta", "Epsilon"]
      )

      assert [newest, oldest] = ArchitectureRejection.objection_history(task.id)

      assert newest.version == 2
      assert oldest.version == 1

      # Findings verbatim — the same maps, not a reshaped copy.
      assert newest.findings == v2_findings
      assert oldest.findings == v1_findings

      # Stage names in POSITION order (they were inserted in reverse).
      assert newest.stage_names == ["Gamma", "Delta", "Epsilon"]
      assert oldest.stage_names == ["Alpha", "Beta"]

      assert newest.summary == "summary for v2"
      assert is_binary(newest.resolved_at)
      assert is_binary(newest.plan_id)

      # THE ONE-WALK PROPERTY at a streak of 2. Asserted here as well as in
      # the truncation test below because that one's fixture has a streak
      # of 1, where `length(history) == streak(t)` is also satisfied by a
      # `streak/1` that ignores its argument and returns the constant 1 —
      # measured, not assumed (vacuity control 2).
      assert length(ArchitectureRejection.objection_history(task.id)) ==
               ArchitectureRejection.streak(task.id)

      assert ArchitectureRejection.streak(task.id) == 2
    end

    test "truncates at the same boundary as streak/1 and never disagrees with it", %{task: task} do
      insert_plan(task, 1, verdict: "rejected", stages: ["Alpha"])
      insert_plan(task, 2, verdict: "passed", stages: ["Beta"])
      insert_plan(task, 3, verdict: "rejected", stages: ["Gamma"])

      history = ArchitectureRejection.objection_history(task.id)

      # THE ONE-WALK PROPERTY, asserted directly. The count and the
      # evidence come from the same private walk, so they cannot drift.
      assert length(history) == ArchitectureRejection.streak(task.id)
      assert Enum.map(history, & &1.version) == [3]
    end

    test "is empty when there is no disagreement", %{task: task} do
      insert_plan(task, 1, verdict: "passed")

      assert ArchitectureRejection.objection_history(task.id) == []
      assert ArchitectureRejection.streak(task.id) == 0
    end

    test "a rejection with no findings still yields an entry", %{task: task} do
      insert_plan(task, 1, verdict: "rejected", stages: ["Alpha"])

      assert [entry] = ArchitectureRejection.objection_history(task.id)
      assert entry.findings == []
      assert entry.stage_names == ["Alpha"]
    end

    # Ticket 01a089e6, and the one DETECTOR in this file: unlike the guards
    # above, there is a defect on unfixed `main` for this to detonate against.
    # Vacuity control: reverting `objection_history/1`'s preload to
    # `order_by: [asc: s.position]` — 1 failure, this test. Detected.
    #
    # `objection_history/1` uses a QUERY-LEVEL preload, which REPLACES
    # `Plan.has_many(:stages)`'s `preload_order` rather than merging with it,
    # so the association's tiebreak does not reach it. And `asc: :position`
    # alone is not a total order: `position` is not unique — `stages` carries
    # one index and it is `index(:stages, [:plan_id])`, plan_id alone and
    # plain, `Stage.changeset/2` validates `position` as required and nothing
    # more, and "Stages must have unique positions" lives only in prose in
    # `plan_create`'s tool description. `:stage_names` is the positional list a
    # human reads beside the architect's finding, so a nondeterministic order
    # means the same rejection history renders differently on two refreshes.
    #
    # THIS FIXTURE INSERTS THE TIED PAIR WITH IDS IT CHOSE, HIGHEST FIRST,
    # rather than going through `add_stages/2`. Two conditions have to hold at
    # once or the test passes with or without the tiebreak:
    #
    #   1. Two stages must SHARE a `position` — otherwise the tiebreak is
    #      never consulted, which is why `add_stages/2` (distinct positions,
    #      reverse insertion) cannot build it.
    #   2. Their PHYSICAL order must disagree with their `id` order —
    #      otherwise a bare `ORDER BY position` returns id order by accident.
    #      Letting the id autogenerate on insert cannot produce this: the id
    #      is minted as the row is written, so the two always agree.
    test "two stages at one position render in a total order, not an arbitrary one", %{task: task} do
      plan = insert_plan(task, 1, verdict: "rejected", stages: [])

      # Sorted rather than assumed-ordered — the claim is about id order, so
      # the ids have to be known to ascend however they were minted.
      [low, high] =
        Enum.sort([Platform.Types.UUIDv7.generate(), Platform.Types.UUIDv7.generate()])

      # HIGHEST ID FIRST: heap order becomes the reverse of id order.
      Repo.insert!(%Stage{id: high, plan_id: plan.id, position: 1, name: "Later"})
      Repo.insert!(%Stage{id: low, plan_id: plan.id, position: 1, name: "Earlier"})
      Repo.insert!(%Stage{plan_id: plan.id, position: 2, name: "Third"})

      # The tie is asserted, not assumed — and doubles as the standing proof
      # that the schema accepts two stages at one position.
      assert 2 ==
               Repo.aggregate(
                 from(s in Stage, where: s.plan_id == ^plan.id and s.position == 1),
                 :count
               )

      # Read three times, asserting the ORDER each time rather than that the
      # reads agree with each other: one lucky scan satisfies "they agree".
      for _ <- 1..3 do
        assert [entry] = ArchitectureRejection.objection_history(task.id)
        assert entry.stage_names == ["Earlier", "Later", "Third"]
      end
    end
  end
end
