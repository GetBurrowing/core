defmodule Platform.Architecture.StageAuditCoverageTest do
  @moduledoc """
  `Platform.Architecture.StageAudit.coverage/1` (task `019fa61c` stage 5).

  ## What is being verified, and what would pass without it

  The function under test reports six numbers and one boolean. Five of
  the numbers are bucket counts, the sixth is their claimed total, and
  the boolean says the two agree. **A boolean that cannot go false is not
  an invariant**, and `balanced?` is exactly the shape that passes
  vacuously: an all-zero coverage of an empty project satisfies
  `0 == 0 + 0 + 0 + 0 + 0` against a `coverage/1` that counts nothing at
  all, or that dropped a bucket from its sum, or that dropped a bucket
  from its query.

  So the mixed fixture below uses DISTINCT, NON-ZERO sizes — 5 pending,
  3 noted, 1 expired, 2 skipped, 4 failed — and the file carries two
  independent detonations plus a control on the control:

    * **DETONATION 1 (arithmetic)** — `"every bucket is load-bearing in
      the sum"` recomputes the invariant five times, each time omitting
      one bucket, and requires all five recomputations to be FALSE. That
      is the mutation a careless refactor actually makes: dropping a term
      from the `Enum.sum`. Its own CONTROL is the sixth recomputation,
      which omits nothing and must be TRUE — without it, a
      `balanced_dropping?/2` helper that returned `false`
      unconditionally would pass the first five assertions and prove
      nothing.
    * **DETONATION 2 (real data)** — `"a row written past the changeset
      breaks the invariant out loud"` puts an unbucketable audit into the
      table with `update_all`, which is precisely how a row would arrive
      past `Stage.architecture_audit_changeset/2` in production, and
      requires `balanced?` to go FALSE while `dispatched` still counts
      the row. Arithmetic alone would not catch a `coverage/1` that
      silently excluded rows it could not classify from BOTH sides of the
      equality; this does.

  Equal-sized buckets are avoided deliberately: a fixture of 3/3/3/3/3
  passes identically against a `coverage/1` that puts every row in the
  wrong bucket, and substitution mutations of that family cost three
  stages this cycle.

  ## The expiry pairing

  Per the counterfactual rule in `org/page/testing-patterns.md`, a bare
  refutation ("an overdue row is not counted as pending") passes
  identically against a detector that never fires at all — a `coverage/1`
  whose `pending` bucket is hardcoded to 0 satisfies it. So the deadline
  case asserts BOTH directions ON ONE FIXTURE and in ONE `coverage/1`
  call: an overdue row lands in `expired` AND a live one lands in
  `pending`, from the same query, at the same instant.

  It also asserts that NEITHER row persists `"expired"`. That is the
  claim stage 1 encoded in the schema and stage 2 in `read/1`; if
  `coverage/1` ever counted a persisted `"expired"` the pairing above
  would still pass, so the projection is pinned separately.

  Not `async: true` — the fixture drives the module-level
  `:architecture_audit_timeout_ms` app env to build overdue rows through
  the real writer rather than hand-crafting them.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Architecture.StageAudit
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Stage

  # Distinct and non-zero, every one of them. See the moduledoc.
  @pending 5
  @noted 3
  @expired 1
  @skipped 2
  @failed 4
  @dispatched @pending + @noted + @expired + @skipped + @failed

  @buckets [:pending, :noted, :expired, :skipped, :failed]

  setup do
    previous = Application.get_env(:platform, :architecture_audit_timeout_ms)

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, :architecture_audit_timeout_ms, previous)
      else
        Application.delete_env(:platform, :architecture_audit_timeout_ms)
      end
    end)

    :ok
  end

  # ── fixtures ─────────────────────────────────────────────────────────

  defp unique, do: System.unique_integer([:positive])

  defp project!(label) do
    {:ok, project} = Tasks.create_project(%{name: "#{label} #{unique()}"})
    project
  end

  defp plan!(project, title) do
    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: title, status: "in_progress"})

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    {task, plan}
  end

  defp stage!(plan, position) do
    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: position,
        name: "Coverage fixture stage #{position}",
        description: "Edit only apps/platform/lib/platform/architecture/stage_audit.ex."
      })

    stage
  end

  defp audit(stage), do: Repo.get!(Stage, stage.id).architecture_audit

  # An OVERDUE row built through the real writer, not hand-stamped: the
  # deadline knob exists for exactly this and stage 2's docstring says
  # so. The sleep is what makes it deterministic rather than a race
  # against a 1ms deadline — `DateTime.utc_now/0` is guaranteed to have
  # moved past it once real time has elapsed.
  defp open_overdue!(stage) do
    Application.put_env(:platform, :architecture_audit_timeout_ms, 1)
    {:ok, _} = StageAudit.open_from_fire(stage, {:ok, :dispatched})
    Process.sleep(5)
    Application.put_env(:platform, :architecture_audit_timeout_ms, 60_000)
    stage
  end

  defp open_pending!(stage) do
    Application.put_env(:platform, :architecture_audit_timeout_ms, 60_000)
    {:ok, _} = StageAudit.open_from_fire(stage, {:ok, :dispatched})
    stage
  end

  # `record_note/3` lands the row and the annotation or neither, so a
  # `"noted"` fixture needs a real execution space. Building one through
  # `find_or_create/1` is safe here because this file creates at most a
  # handful of tasks per test.
  defp note!(stage, task) do
    {:ok, _space} = ExecutionSpace.find_or_create(task.id)
    open_pending!(stage)

    {:ok, _} =
      StageAudit.record_note(
        stage,
        %{summary: "coverage fixture note", findings: []},
        source: "mcp"
      )

    stage
  end

  # 5 pending / 3 noted / 1 expired / 2 skipped / 4 failed, all in one
  # project, all through the real writer.
  defp mixed_fixture! do
    project = project!("Coverage Project")
    {task, plan} = plan!(project, "Coverage task")
    {:ok, _space} = ExecutionSpace.find_or_create(task.id)

    counter = :counters.new(1, [])

    next_stage = fn ->
      :counters.add(counter, 1, 1)
      stage!(plan, :counters.get(counter, 1))
    end

    pending = for _ <- 1..@pending, do: open_pending!(next_stage.())
    noted = for _ <- 1..@noted, do: note!(next_stage.(), task)
    expired = for _ <- 1..@expired, do: open_overdue!(next_stage.())

    skipped =
      for _ <- 1..@skipped do
        stage = next_stage.()
        {:ok, _} = StageAudit.open_from_fire(stage, {:ok, :unfilled})
        stage
      end

    failed =
      for _ <- 1..@failed do
        stage = next_stage.()
        {:ok, _} = StageAudit.open_from_fire(stage, {:error, :dispatch_exploded})
        stage
      end

    %{
      project: project,
      task: task,
      plan: plan,
      pending: pending,
      noted: noted,
      expired: expired,
      skipped: skipped,
      failed: failed
    }
  end

  defp coverage(project, since \\ nil) do
    StageAudit.coverage(%{project_id: project.id, since: since})
  end

  # Recomputes the invariant with one bucket omitted from the sum — the
  # mutation a careless refactor makes. `drop: nil` omits nothing and is
  # the control that this helper can return `true` at all.
  defp balanced_dropping?(cov, drop) do
    sum =
      @buckets
      |> Enum.reject(&(&1 == drop))
      |> Enum.map(&Map.fetch!(cov, &1))
      |> Enum.sum()

    cov.dispatched == sum
  end

  # ── the mixed fixture ────────────────────────────────────────────────

  describe "coverage/1 over a mixed fixture" do
    test "every fire lands in exactly one bucket and the invariant holds" do
      ctx = mixed_fixture!()

      cov = coverage(ctx.project)

      # Exact counts, not "greater than zero". A bucket asserted only to
      # be non-empty cannot notice rows landing in the wrong one.
      assert cov.pending == @pending
      assert cov.noted == @noted
      assert cov.expired == @expired
      assert cov.skipped == @skipped
      assert cov.failed == @failed
      assert cov.dispatched == @dispatched
      assert cov.balanced?
    end

    # DETONATION 1, with its own control. See the moduledoc.
    test "every bucket is load-bearing in the sum" do
      ctx = mixed_fixture!()
      cov = coverage(ctx.project)

      # The control FIRST: if this is false the five assertions below are
      # meaningless, and a helper that always returned false would sail
      # through them.
      assert balanced_dropping?(cov, nil),
             "the mutation control cannot reproduce a balanced sum — the rest of this test proves nothing"

      for bucket <- @buckets do
        refute balanced_dropping?(cov, bucket),
               "dropping #{bucket} from the sum left the invariant TRUE, so a refactor that " <>
                 "deleted that term would pass this suite. The fixture bucket is empty or " <>
                 "duplicated by another."
      end
    end

    test "the bucket sizes are distinct, so a substitution mutation cannot hide" do
      ctx = mixed_fixture!()
      cov = coverage(ctx.project)

      sizes = Enum.map(@buckets, &Map.fetch!(cov, &1))

      # A guard on the FIXTURE, not on the module: two equal buckets make
      # every swap between them invisible, which is how three stages were
      # lost this cycle.
      assert length(Enum.uniq(sizes)) == length(sizes),
             "coverage buckets are not pairwise distinct (#{inspect(sizes)}) — swapping two of " <>
               "them would be undetectable"
    end

    # DETONATION 2. Arithmetic cannot catch a `coverage/1` that excludes
    # rows it cannot classify from BOTH sides of the equality.
    test "a row written past the changeset breaks the invariant out loud" do
      ctx = mixed_fixture!()
      [victim | _] = ctx.pending

      # `update_all` bypasses `Stage.architecture_audit_changeset/2`
      # exactly as an errant writer would. The stamp stays valid: what is
      # being tested is an unbucketable STATE, not an unplaceable time.
      corrupt = Map.put(audit(victim), "state", "acknowledged")

      {1, _} =
        Stage
        |> where([s], s.id == ^victim.id)
        |> Repo.update_all(set: [architecture_audit: corrupt])

      log = capture_log(fn -> send(self(), {:cov, coverage(ctx.project)}) end)
      assert_received {:cov, cov}

      # Still counted as dispatched — the fire genuinely happened, and a
      # coverage read that dropped the row from both sides would report a
      # tidy `balanced?: true` over a project that had lost a row.
      assert cov.dispatched == @dispatched
      refute cov.balanced?

      # And it is the corrupted row that went missing, not a bucket that
      # collapsed: pending is down exactly one, everything else is intact.
      assert cov.pending == @pending - 1
      assert cov.noted == @noted
      assert cov.expired == @expired
      assert cov.skipped == @skipped
      assert cov.failed == @failed

      # An operator who sees `balanced?: false` needs to know WHICH row.
      assert log =~ "coverage invariant broken"
      assert log =~ victim.id
    end
  end

  # ── the expiry projection ────────────────────────────────────────────

  describe "coverage/1 and the deadline" do
    # PAIRED on one fixture, in one call. A bare "the overdue row is not
    # pending" passes against a detector that never fires.
    test "an overdue fire counts as expired and a live one counts as pending, together" do
      project = project!("Deadline Project")
      {_task, plan} = plan!(project, "Deadline task")

      overdue = open_overdue!(stage!(plan, 1))
      live = open_pending!(stage!(plan, 2))

      cov = coverage(project)

      assert cov.expired == 1
      assert cov.pending == 1
      assert cov.dispatched == 2
      assert cov.balanced?

      # The projection, pinned separately: NEITHER row persists
      # `"expired"`, and the schema has no value for it. If `coverage/1`
      # ever started reading a persisted `"expired"` the pairing above
      # would still pass.
      assert audit(overdue)["state"] == "pending"
      assert audit(live)["state"] == "pending"
      refute "expired" in Stage.architecture_audit_states()

      # And the projection agrees with the function every other module
      # asks the question through — one rule, not two.
      assert {:resolved, %{"state" => "expired"}} = StageAudit.read(overdue)
      assert {:open, %{"state" => "pending"}} = StageAudit.read(live)
    end

    test "a noted row stays noted after its deadline elapses" do
      project = project!("Late Note Project")
      {task, plan} = plan!(project, "Late note task")

      stage = stage!(plan, 1)
      open_overdue!(stage)

      {:ok, _space} = ExecutionSpace.find_or_create(task.id)

      {:ok, _} =
        StageAudit.record_note(
          stage,
          %{summary: "late but real", findings: []},
          source: "mcp"
        )

      cov = coverage(project)

      # An architect who engaged late still engaged: the answer counts as
      # an answer, not as the silence it arrived after. The elapsed
      # deadline survives in the row, which is what keeps the two facts
      # separable for anyone reading behind the number.
      assert cov.noted == 1
      assert cov.expired == 0
      assert cov.balanced?
      assert audit(stage)["noted_after_deadline"] == true
    end
  end

  # ── the two filters ──────────────────────────────────────────────────

  describe "coverage/1 scoping" do
    test "another project's fires are not counted, and its own are" do
      ctx = mixed_fixture!()

      other = project!("Other Project")
      {_task, other_plan} = plan!(other, "Other task")
      open_pending!(stage!(other_plan, 1))

      # Both directions. Asserting only that the first project is
      # unchanged passes against a query that returns nothing for
      # anybody.
      assert coverage(ctx.project).dispatched == @dispatched
      assert coverage(other).dispatched == 1
      assert coverage(other).pending == 1
    end

    test "the since window bounds the count in both directions" do
      ctx = mixed_fixture!()

      before_all = DateTime.add(DateTime.utc_now(), -3600, :second)
      after_all = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert coverage(ctx.project, before_all).dispatched == @dispatched
      assert coverage(ctx.project, before_all).balanced?

      # The counterfactual: a window that starts after every fire counts
      # none of them. Without this, a `since` that was parsed and thrown
      # away would be indistinguishable from one that was honoured.
      assert coverage(ctx.project, after_all).dispatched == 0
      assert coverage(ctx.project, after_all).pending == 0
    end

    test "a stage with no recorded fire is not counted as dispatched" do
      project = project!("Unfired Project")
      {_task, plan} = plan!(project, "Unfired task")

      # NULL means no fire was ever recorded, which is a different fact
      # from a fire that produced nothing. Counting it would inflate
      # `dispatched` and break the invariant for a reason that is not a
      # bug.
      stage!(plan, 1)
      fired = open_pending!(stage!(plan, 2))

      cov = coverage(project)

      assert cov.dispatched == 1
      assert cov.pending == 1
      assert cov.balanced?
      assert audit(fired)["state"] == "pending"
    end

    test "an unknown project reads as an empty, balanced coverage" do
      cov = StageAudit.coverage(%{project_id: Ecto.UUID.generate(), since: nil})

      assert cov.dispatched == 0
      assert cov.balanced?

      # Explicitly NOT the assertion that carries this file. An all-zero
      # coverage satisfies the invariant against a function that counts
      # nothing at all; the mixed fixture above is what makes it mean
      # something.
      for bucket <- @buckets, do: assert(Map.fetch!(cov, bucket) == 0)
    end

    test "a malformed project id does not raise" do
      # `coverage/1` is an operator-loop read. Raising on a fat-fingered
      # id would send whoever is chasing a silent responsibility off after
      # a second bug.
      assert %{dispatched: 0, balanced?: true} =
               StageAudit.coverage(%{project_id: "not-a-uuid", since: nil})
    end
  end
end
