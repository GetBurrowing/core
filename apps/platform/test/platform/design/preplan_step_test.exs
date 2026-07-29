defmodule Platform.Design.PreplanStepTest do
  @moduledoc """
  The pre-plan design step (ADR-0046 stack member 7, task `019f9b29-5ecd`
  stage 4).

  ## Verification labels

  **DETECTOR** — "the three terminal situations are distinguishable". This is
  the mandatory detector for this task. It puts three tasks through `start/1`
  and requires that a non-UI skip, a fired-but-unfilled skip and a fired-and-
  crashed dispatch land as three DIFFERENT records — the reasons pairwise
  distinct, and the outcomes of the last two written as a direct inequality.
  Detonations are recorded in the stage evidence; each is named below with the
  assertion that fired.

  Everything else is a GUARD.

  ## Vacuity disclosure

  Two assertions in this file pass trivially and are pins, not detectors, and
  saying so is more useful than padding a table:

    * **`reasons/0` returns the shipped strings** — a restatement of the module
      under test. It detects nothing today. It earns its keep the first time
      someone renames a reason without meaning to change the contract member 8
      renders.
    * **`responsibility_key/0` is `"design.task_direction"`** — same shape, same
      justification. It is a pin on the seam between this module and stage 3.

  The load-bearing controls, by contrast:

    * **"a successful fire records nothing"** is an ABSENCE assertion, and an
      absence assertion passes against a module that never writes at all. Its
      positive control lives in the SAME test: a fire that FAILS, in the same
      setup, over the same task shape, must write the key. Without that control
      a `record_planning_step/3` that had been deleted outright would pass.
    * **"settle/2 on a `not_applicable` entry does nothing"** is likewise paired
      with the `"designing"` positive control, so a `settle/2` stubbed to
      `{:ok, :noop}` cannot pass.
    * **"the audit is silent on a `complete` entry"** is paired with the
      contradiction case, so an `audit_ui_prediction/2` that never emits
      telemetry at all cannot pass.

  ## Where the stage description met the code and was wrong

  The stage brief specified BOTH that `preplan_step.ex` hand
  `record(task, :design, {:ok, :unfilled})` to the writer for the no-UI skip and
  `{:ok, :dispatched}` for the settle, AND a guard that the file "contains no
  `:dispatched`, no `:unfilled`". Those cannot both hold: constructing a value
  requires naming it. Resolved by splitting the guard along what it was
  protecting — the HARD RULE's own words, "if you find yourself writing a `case`
  over fire-result shapes, stop". The guard now asserts the file contains no
  `Responsibilities.outcome`, no `:unknown_responsibility` at all, and that no
  fire-result tuple appears in a PATTERN position (a `case`/`fn` clause head or
  a function head). Constructing one and handing it to member 4's writer is the
  mandated design; matching on one is the prohibited second mapping.

  The brief also specified, in the same paragraph, that the module "hands the
  fire result to `record_planning_step/3` and then READS BACK the persisted
  outcome" AND that "a SUCCESSFUL fire records NOTHING". Reconciled in
  `record_terminal_only/2` by handing every fire result over inside a
  transaction and rolling back when the value read back is `:complete` — so the
  read-back is real, the mapping stays single-sourced, and nothing is ever
  committed for an open step. Asserted below.

  Not `async: true`: the fire-seam counter and the raising-settler stub are
  module-level `Application` env, which is global.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Design.PreplanStep
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.DesignTaskDirection
  alias Platform.Roles
  alias Platform.Roles.{Role, RoleResponsibility}
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tasks.Task, as: TaskSchema

  @key "design.task_direction"
  @module_path "lib/platform/design/preplan_step.ex"

  # Titles chosen so the classifier's verdict is not in doubt either way.
  # "Add an epic-create FAB above the board" is stage 1's own doctest example.
  @ui_title "Add an epic-create FAB above the board"
  @non_ui_title "Add Providers.Architecture shim"

  # ── stubs ─────────────────────────────────────────────────────────────────

  defmodule NoopDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: :ok
  end

  defmodule CountingDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal) do
      case Application.get_env(:platform, :preplan_test_pid) do
        pid when is_pid(pid) -> send(pid, :design_fired)
        _ -> :ok
      end

      :ok
    end
  end

  defmodule RaisingDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: raise("designer exploded")
  end

  defmodule RaisingSettler do
    @moduledoc false
    def settle(_task_id, _attachment), do: raise("settler exploded")
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  setup do
    Logger.put_module_level(Platform.Responsibilities.Router, :info)
    on_exit(fn -> Logger.delete_module_level(Platform.Responsibilities.Router) end)

    # The Registry's boot walk is disabled in the test env
    # (`:start_responsibilities_registry` = false), so the row stage 3
    # registers has to be installed explicitly per sandbox.
    [spec] = DesignTaskDirection.register()
    {:ok, _row} = Responsibilities.upsert_by_key(spec)

    {:ok, project} = Tasks.create_project(%{name: "Preplan Project #{unique()}"})

    %{project: project}
  end

  defp unique, do: System.unique_integer([:positive])

  defp task!(project, title, attrs \\ %{}) do
    now = DateTime.utc_now()

    %TaskSchema{}
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          project_id: project.id,
          title: title,
          status: "planning",
          inserted_at: now,
          updated_at: now
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp reload(%TaskSchema{id: id}), do: Repo.get!(TaskSchema, id)

  defp design_entry(task), do: (reload(task).planning_step_outcomes || %{})["design"]

  defp cursor(task), do: reload(task).planning_step

  # Hand-built rather than `ExecutionSpace.find_or_create/1` for the reason
  # `Platform.Design.BrandTest` documents: that helper derives its slug from the
  # task UUID's millisecond field, so two tasks created inside one millisecond
  # collide on `chat_spaces_unique_org_slug`.
  defp execution_space!(task) do
    n = unique()

    {:ok, space} =
      Chat.create_space(%{
        name: "preplan-exec-#{n}",
        slug: "preplan-exec-#{n}",
        kind: "execution",
        metadata: %{"task_id" => task.id}
      })

    space
  end

  # Reuse `historian` as the carrier role, the same substitution the architect
  # hook test uses: it keeps this off the seeded `designer` bundle that the
  # closed-roster coverage suite already exercises.
  defp wire_designer! do
    role_key = "historian"

    Repo.insert!(
      %Role{key: role_key, name: "Historian", description: "test", icon: "hero-star"},
      on_conflict: :nothing,
      conflict_target: :key
    )

    %RoleResponsibility{}
    |> RoleResponsibility.changeset(%{role_key: role_key, responsibility_key: @key})
    |> Repo.insert!()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "designer-native-#{unique()}",
        name: "Fixture Designer",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert()

    {:ok, _} = Roles.assign_role(role_key, agent.id)

    agent
  end

  # Same carrier-role substitution as `wire_designer!/0`, but the role owner is
  # a FEDERATED agent with a live runtime rather than a native one — the only
  # shape `AgentResponder.dispatch_system_event/2` will actually broadcast for.
  # Returns `{agent, runtime}`; the caller subscribes to `runtime:<token>`.
  defp wire_federated_designer! do
    role_key = "historian"

    Repo.insert!(
      %Role{key: role_key, name: "Historian", description: "test", icon: "hero-star"},
      on_conflict: :nothing,
      conflict_target: :key
    )

    %RoleResponsibility{}
    |> RoleResponsibility.changeset(%{role_key: role_key, responsibility_key: @key})
    |> Repo.insert!()

    presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), presence)

    owner =
      Repo.insert!(%User{
        email: "preplan-designer-#{unique()}@example.com",
        name: "Preplan Designer Owner",
        oidc_sub: "oidc-preplan-designer-#{unique()}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-designer-#{unique()}",
        display_name: "designer-runtime"
      })

    RuntimePresence.track(runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "designer-federated-#{unique()}",
        name: "Fixture Federated Designer",
        status: "active",
        kind: "native",
        runtime_type: "external",
        runtime_id: runtime.id,
        workspace_id: nil
      })
      |> Repo.insert()

    {:ok, _} = Roles.assign_role(role_key, agent.id)

    {agent, runtime}
  end

  # The real production native dispatcher is
  # `Platform.Chat.AgentResponder.maybe_dispatch/1` (the default when the seam
  # is unset). Every other test in this file overrides it; the end-to-end
  # control below must NOT, so clear any leakage explicitly rather than
  # trusting `async: false` ordering.
  defp use_real_dispatcher! do
    previous_seam = Application.get_env(:platform, :responsibility_router_native_dispatcher)
    Application.delete_env(:platform, :responsibility_router_native_dispatcher)

    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    on_exit(fn ->
      if previous_seam do
        Application.put_env(:platform, :responsibility_router_native_dispatcher, previous_seam)
      end

      if previous_mode do
        Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode)
      else
        Application.delete_env(:platform, :chat_agent_dispatch_mode)
      end
    end)
  end

  defp override_dispatcher(module) do
    previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {module, :maybe_dispatch}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, :responsibility_router_native_dispatcher, previous)
      else
        Application.delete_env(:platform, :responsibility_router_native_dispatcher)
      end
    end)
  end

  defp override_settler(module) do
    previous = Application.get_env(:platform, :design_preplan_settler)
    Application.put_env(:platform, :design_preplan_settler, {module, :settle})

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, :design_preplan_settler, previous)
      else
        Application.delete_env(:platform, :design_preplan_settler)
      end
    end)
  end

  defp attach_telemetry(event) do
    id = "preplan-#{unique()}"
    pid = self()

    :telemetry.attach(
      id,
      event,
      fn e, m, meta, target -> send(target, {:telemetry, e, m, meta}) end,
      pid
    )

    on_exit(fn -> :telemetry.detach(id) end)
    id
  end

  defp canvas! do
    n = unique()
    {:ok, space} = Chat.create_space(%{name: "canvas-#{n}", slug: "canvas-#{n}", kind: "channel"})

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Attacher",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => "Direction #{n}"
      })

    {canvas, participant}
  end

  defp quietly(fun), do: capture_log([level: :debug], fun)

  # ── DETECTOR ──────────────────────────────────────────────────────────────

  describe "DETECTOR — the three terminal situations are distinguishable" do
    test "no UI surface, no designer, and a crashed dispatch record differently", %{
      project: project
    } do
      # (a) not a UI task at all — nothing is fired.
      a = task!(project, @non_ui_title)
      quietly(fn -> assert {:ok, :not_applicable} = PreplanStep.start(a) end)

      # (b) a UI task, the responsibility row exists, nobody holds it.
      b = task!(project, @ui_title)
      _ = execution_space!(b)
      quietly(fn -> assert {:ok, :not_applicable} = PreplanStep.start(b) end)

      # (c) a UI task with a designer whose dispatch blows up.
      override_dispatcher(RaisingDispatcher)
      _agent = wire_designer!()
      c = task!(project, @ui_title)
      _ = execution_space!(c)
      quietly(fn -> assert {:ok, :failed} = PreplanStep.start(c) end)

      entry_a = design_entry(a)
      entry_b = design_entry(b)
      entry_c = design_entry(c)

      assert entry_a["reason"] == "no_ui_surface"
      assert entry_b["reason"] == "no_designer"

      # Pairwise distinct reasons. `entry_c` carries no `reason`: a fire that
      # found somebody and failed says WHY in member 4's `detail`, and reusing
      # `"no_designer"` there would be a third conflation.
      assert entry_a["reason"] != entry_b["reason"]
      assert entry_a["reason"] != entry_c["reason"]
      assert entry_b["reason"] != entry_c["reason"]

      # The inequality this whole stack exists for, written directly.
      assert entry_b["outcome"] != entry_c["outcome"]
      assert entry_b["outcome"] == "not_applicable"
      assert entry_c["outcome"] == "failed"

      # And the failure says what failed, so a merge-time reader can act.
      assert is_binary(entry_c["detail"])
      assert entry_c["detail"] =~ "native_dispatch_raised"

      # `not_applicable` never reaches the merge gate; `failed` always does.
      refute Tasks.planning_gate_failed?(reload(a))
      refute Tasks.planning_gate_failed?(reload(b))
      assert Tasks.planning_gate_failed?(reload(c))
    end

    test "the start/1 return value is the value that was persisted, not a parallel derivation",
         %{project: project} do
      task = task!(project, @non_ui_title)

      quietly(fn ->
        assert {:ok, outcome} = PreplanStep.start(task)
        assert to_string(outcome) == design_entry(task)["outcome"]
      end)
    end
  end

  # ── idempotence ───────────────────────────────────────────────────────────

  describe "GUARD — start/1 is safe on every dispatch tick" do
    test "two calls in a row fire exactly once", %{project: project} do
      override_dispatcher(CountingDispatcher)
      Application.put_env(:platform, :preplan_test_pid, self())
      on_exit(fn -> Application.delete_env(:platform, :preplan_test_pid) end)

      _agent = wire_designer!()
      task = task!(project, @ui_title)
      _ = execution_space!(task)

      quietly(fn ->
        assert {:ok, :open} = PreplanStep.start(task)
        assert {:ok, :already_open} = PreplanStep.start(task)
      end)

      assert_receive :design_fired, 500
      refute_receive :design_fired, 200
    end

    test "a settled step is never re-fired", %{project: project} do
      override_dispatcher(CountingDispatcher)
      Application.put_env(:platform, :preplan_test_pid, self())
      on_exit(fn -> Application.delete_env(:platform, :preplan_test_pid) end)

      task = task!(project, @non_ui_title)

      quietly(fn ->
        assert {:ok, :not_applicable} = PreplanStep.start(task)
        assert {:ok, :already_settled} = PreplanStep.start(task)
      end)

      refute_receive :design_fired, 200
    end

    test "an unknown task id degrades rather than raising" do
      assert {:error, :task_not_found} = PreplanStep.start(Ecto.UUID.generate())
    end
  end

  # ── the open step ─────────────────────────────────────────────────────────

  describe "GUARD — a successful fire leaves the step OPEN" do
    test "records nothing and holds the cursor, while a failed fire in the same setup records",
         %{project: project} do
      _agent = wire_designer!()

      # Positive control FIRST, so an assertion that the absence case passes
      # cannot be satisfied by a module that never writes at all.
      override_dispatcher(RaisingDispatcher)
      failing = task!(project, @ui_title)
      _ = execution_space!(failing)
      quietly(fn -> assert {:ok, :failed} = PreplanStep.start(failing) end)

      assert %{"outcome" => "failed"} = design_entry(failing)
      assert cursor(failing) == "planning"

      # The absence assertion.
      Application.put_env(
        :platform,
        :responsibility_router_native_dispatcher,
        {NoopDispatcher, :maybe_dispatch}
      )

      succeeding = task!(project, @ui_title)
      _ = execution_space!(succeeding)
      quietly(fn -> assert {:ok, :open} = PreplanStep.start(succeeding) end)

      refute Map.has_key?(reload(succeeding).planning_step_outcomes || %{}, "design")
      assert cursor(succeeding) == "designing"

      # `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`
      # — an open step must not be reportable as a gate failure,
      # and must not be reportable as a success either.
      refute Tasks.planning_gate_failed?(reload(succeeding))
      assert PreplanStep.persisted_outcome(reload(succeeding)) == nil
    end
  end

  # ── the fire-terminal records ─────────────────────────────────────────────

  # Why these are not folded into the `settle/2` block below: the ONLY assertion
  # on `layer`/`matched` in this file before now was in that block (the
  # membership check further down), and `do_settle/2` is the one path that pipes
  # the whole verdict into `evidence_annotations/1`. Every FIRE-terminal record
  # went through `fire_designer/2`, which destructured the verdict and passed the
  # inner map, so the tuple clause never matched and the catch-all returned `%{}`.
  # A test added under `settle/2` passes identically before and after that fix
  # and proves nothing; these must fail without it.
  #
  # Exact-value pins, not membership: `@ui_title` is `ui_surface.ex`'s own
  # doctest subject, which fixes the verdict at
  # `{true, %{layer: :strong_prose, matched: ["fab"]}}`. Pinning the values also
  # proves the tuple was threaded through unmutated, which a membership check
  # cannot.
  describe "GUARD — the fire-terminal records carry stage 1's evidence" do
    test "a no_designer skip records the layer and the matched tokens", %{project: project} do
      task = task!(project, @ui_title)
      _ = execution_space!(task)

      quietly(fn -> assert {:ok, :not_applicable} = PreplanStep.start(task) end)

      entry = design_entry(task)

      # Proves `annotate/3` ran at all, so a missing `layer` below cannot be
      # blamed on the annotate call having been skipped entirely.
      assert entry["reason"] == "no_designer"

      assert entry["layer"] == "strong_prose"
      assert entry["matched"] == ["fab"]
    end

    test "a failed fire records the evidence WITHOUT resurrecting the no_designer reason", %{
      project: project
    } do
      override_dispatcher(RaisingDispatcher)
      _agent = wire_designer!()

      task = task!(project, @ui_title)
      _ = execution_space!(task)

      quietly(fn -> assert {:ok, :failed} = PreplanStep.start(task) end)

      entry = design_entry(task)
      assert entry["outcome"] == "failed"
      assert entry["layer"] == "strong_prose"
      assert entry["matched"] == ["fab"]

      # Load-bearing in the other direction. `annotations_for/2` deletes ONLY
      # `"reason"` for a non-`not_applicable` outcome, so carrying `layer` and
      # `matched` through must not drag `"no_designer"` along onto a fire that
      # found somebody.
      assert entry["reason"] == nil
    end

    # A SEPARATE defect, and it has its own mutation check. `expire/2` never
    # called `evidence_annotations/1` at all — it passed a literal map — so the
    # shape mismatch above was structurally unable to reach it and fixing the
    # call site does not fix this. The task description's claim that one bug
    # drops evidence on "every fire-terminal path — no_designer, failed, and the
    # timeout" is wrong on the third.
    test "a timeout records the evidence too, though for a different reason", %{project: project} do
      task = task!(project, @ui_title, %{planning_step: "designing"})

      quietly(fn -> assert {:ok, :failed} = PreplanStep.expire(task, 1_800_000) end)

      entry = design_entry(task)
      assert entry["reason"] == "design_timeout"
      assert entry["layer"] == "strong_prose"
      assert entry["matched"] == ["fab"]
    end
  end

  # ── settle ────────────────────────────────────────────────────────────────

  describe "GUARD — settle/2" do
    test "closes a designing step as complete with the canvas id", %{project: project} do
      task = task!(project, @ui_title, %{planning_step: "designing"})
      {canvas, _participant} = canvas!()

      quietly(fn -> assert {:ok, :complete} = PreplanStep.settle(task.id, canvas.id) end)

      entry = design_entry(task)
      assert entry["outcome"] == "complete"
      assert entry["reason"] == "canvas_attached"
      assert entry["canvas_id"] == canvas.id
      assert cursor(task) == "planning"

      # Stage 1's evidence is carried through, so a reader can tell WHY the
      # step was thought to apply.
      assert entry["layer"] in ["path_token", "strong_prose", "weak_prose"]
      assert is_list(entry["matched"]) and entry["matched"] != []
    end

    test "upgrades a failed entry to complete when the work lands late", %{project: project} do
      task = task!(project, @ui_title)
      {:ok, _} = Tasks.record_planning_step(task, :design, {:error, {:design_timeout, 1000}})

      assert design_entry(task)["outcome"] == "failed"
      assert Tasks.planning_gate_failed?(reload(task))

      {canvas, _participant} = canvas!()
      quietly(fn -> assert {:ok, :complete} = PreplanStep.settle(task.id, canvas.id) end)

      assert design_entry(task)["outcome"] == "complete"
      # The whole point of the upgrade: the merge-time warning clears.
      refute Tasks.planning_gate_failed?(reload(task))
    end

    test "is a no-op on a not_applicable entry, but not on a designing one", %{project: project} do
      # Absence case.
      skipped = task!(project, @non_ui_title)
      quietly(fn -> assert {:ok, :not_applicable} = PreplanStep.start(skipped) end)
      before = design_entry(skipped)

      {canvas, _participant} = canvas!()
      quietly(fn -> assert {:ok, :noop} = PreplanStep.settle(skipped.id, canvas.id) end)

      assert design_entry(skipped) == before
      assert design_entry(skipped)["outcome"] == "not_applicable"

      # Paired positive control, same call, same canvas: proves `settle/2` is
      # capable of writing at all.
      open = task!(project, @ui_title, %{planning_step: "designing"})
      quietly(fn -> assert {:ok, :complete} = PreplanStep.settle(open.id, canvas.id) end)
      assert design_entry(open)["outcome"] == "complete"
    end

    test "accepts a %CanvasAttachment{} as well as a bare canvas id", %{project: project} do
      task = task!(project, @ui_title, %{planning_step: "designing"})
      {canvas, participant} = canvas!()

      {:ok, attachment} =
        CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
          note: "direction",
          attached_by: %{kind: "user", id: participant.id}
        )

      # The attach itself already settled the step through the hook; assert the
      # direct call is idempotent on the recorded value.
      quietly(fn -> PreplanStep.settle(task.id, attachment) end)

      assert design_entry(task)["canvas_id"] == canvas.id
    end

    test "an unknown task id is a no-op rather than an error" do
      assert {:ok, :noop} = PreplanStep.settle(Ecto.UUID.generate(), Ecto.UUID.generate())
    end
  end

  # ── the attach hook ───────────────────────────────────────────────────────

  describe "GUARD — the attach_canvas/4 hook" do
    test "attaching a canvas settles an open design step", %{project: project} do
      task = task!(project, @ui_title, %{planning_step: "designing"})
      {canvas, participant} = canvas!()

      quietly(fn ->
        assert {:ok, %Platform.Tasks.CanvasAttachment{}} =
                 CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
                   attached_by: %{kind: "user", id: participant.id}
                 )
      end)

      assert design_entry(task)["outcome"] == "complete"
      assert design_entry(task)["canvas_id"] == canvas.id
      assert cursor(task) == "planning"
    end

    test "a settler that raises cannot change the return value or crash the attach", %{
      project: project
    } do
      override_settler(RaisingSettler)

      task = task!(project, @ui_title, %{planning_step: "designing"})
      {canvas, participant} = canvas!()

      log =
        capture_log(fn ->
          assert {:ok, %Platform.Tasks.CanvasAttachment{canvas_id: attached}} =
                   CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
                     note: "still returns",
                     attached_by: %{kind: "user", id: participant.id}
                   )

          assert attached == canvas.id
        end)

      assert log =~ "design settle hook raised"

      # And nothing was recorded — the raise was contained, not swallowed into
      # a half-written entry.
      assert design_entry(task) == nil
    end

    test "attaching to a task with no design step is inert", %{project: project} do
      task = task!(project, @non_ui_title)
      {canvas, participant} = canvas!()

      quietly(fn ->
        assert {:ok, _} =
                 CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
                   attached_by: %{kind: "user", id: participant.id}
                 )
      end)

      assert design_entry(task) == nil
      assert cursor(task) == "planning"
    end
  end

  # ── expire ────────────────────────────────────────────────────────────────

  describe "GUARD — expire/2" do
    test "records failed and returns the cursor so planning proceeds", %{project: project} do
      task = task!(project, @ui_title, %{planning_step: "designing"})

      quietly(fn -> assert {:ok, :failed} = PreplanStep.expire(task, 1_800_000) end)

      entry = design_entry(task)
      assert entry["outcome"] == "failed"
      assert entry["reason"] == "design_timeout"
      assert entry["detail"] =~ "design_timeout"
      assert cursor(task) == "planning"
      assert Tasks.planning_gate_failed?(reload(task))
    end

    test "a late timer cannot re-open a settled step", %{project: project} do
      task = task!(project, @ui_title, %{planning_step: "designing"})
      {canvas, _participant} = canvas!()

      quietly(fn -> assert {:ok, :complete} = PreplanStep.settle(task.id, canvas.id) end)
      quietly(fn -> assert {:ok, :noop} = PreplanStep.expire(task, 1_800_000) end)

      assert design_entry(task)["outcome"] == "complete"
      refute Tasks.planning_gate_failed?(reload(task))
    end
  end

  # ── decline (task 019fa504 stage 1) ───────────────────────────────────────

  describe "GUARD — decline/2" do
    test "closes an open step as not_applicable with the designer's reason, while a timeout on the same shape still records failed",
         %{project: project} do
      declined = task!(project, @ui_title, %{planning_step: "designing"})

      quietly(fn ->
        assert {:ok, :not_applicable} =
                 PreplanStep.decline(declined.id, "The change is not visual.")
      end)

      entry = design_entry(declined)

      # PIN THE POSITIVE FIRST. Every refutation below passes trivially on a
      # task whose design step never ran, so the entry has to be asserted to
      # EXIST with the decline's own reason before any absence is claimed.
      assert entry["outcome"] == "not_applicable"
      assert entry["reason"] == PreplanStep.reasons().declined
      assert entry["decline_note"] == "The change is not visual."
      assert cursor(declined) == "planning"

      # The classifier's evidence rides along, exactly as it does on the other
      # terminal records, so an analyst reading the decline can see what the
      # designer was declining.
      assert entry["layer"] == "strong_prose"
      assert entry["matched"] == ["fab"]

      # Not a timeout: the record must not carry the timeout's marker, and the
      # step must not reach the merge gate.
      refute entry["outcome"] == "failed"
      refute Map.has_key?(entry, "declined_after_timeout")
      refute Tasks.planning_gate_failed?(reload(declined))
      assert Tasks.failed_planning_steps(reload(declined)) == []

      # PAIRED DISTINGUISHABILITY CONTROL — same fixture shape, same title,
      # same open cursor; only the closing call differs. Without it the block
      # above cannot tell "a decline records not_applicable" from "the design
      # step stopped recording failures at all".
      expired = task!(project, @ui_title, %{planning_step: "designing"})
      quietly(fn -> assert {:ok, :failed} = PreplanStep.expire(expired, 1_800_000) end)

      control = design_entry(expired)
      assert control["outcome"] == "failed"
      assert control["reason"] == PreplanStep.reasons().timeout
      assert Tasks.planning_gate_failed?(reload(expired))

      # The inequality this exit exists for, written directly.
      assert entry["outcome"] != control["outcome"]
      assert entry["reason"] != control["reason"]
    end

    test "a step that is neither open nor failed is untouched, byte for byte", %{project: project} do
      settled = task!(project, @non_ui_title)
      quietly(fn -> assert {:ok, :not_applicable} = PreplanStep.start(settled) end)
      before = design_entry(settled)

      quietly(fn ->
        assert {:ok, :noop} = PreplanStep.decline(settled.id, "changed my mind")
      end)

      assert design_entry(settled) == before
      assert design_entry(settled)["reason"] == PreplanStep.reasons().no_ui_surface

      # A never-fired task has no entry to overwrite either.
      untouched = task!(project, @ui_title)
      quietly(fn -> assert {:ok, :noop} = PreplanStep.decline(untouched.id, "nothing here") end)
      assert design_entry(untouched) == nil

      # PAIRED POSITIVE CONTROL, same call, same note: `decline/2` is capable
      # of writing at all, so the two no-ops above are a property of the step's
      # state and not of a function stubbed to `{:ok, :noop}`.
      open = task!(project, @ui_title, %{planning_step: "designing"})

      quietly(fn ->
        assert {:ok, :not_applicable} = PreplanStep.decline(open.id, "not visual")
      end)

      assert design_entry(open)["reason"] == PreplanStep.reasons().declined
    end

    test "a late decline upgrades a timed-out step, and the timeout stays visible in the record",
         %{project: project} do
      task = task!(project, @ui_title, %{planning_step: "designing"})
      quietly(fn -> assert {:ok, :failed} = PreplanStep.expire(task, 1_800_000) end)

      # Both sides of the upgrade are asserted: it IS listed before.
      assert design_entry(task)["outcome"] == "failed"
      assert [%{step: "design"}] = Tasks.failed_planning_steps(reload(task))

      quietly(fn ->
        assert {:ok, :not_applicable} = PreplanStep.decline(task.id, "no direction needed")
      end)

      entry = design_entry(task)
      assert entry["outcome"] == "not_applicable"
      assert entry["reason"] == PreplanStep.reasons().declined
      assert entry["decline_note"] == "no direction needed"

      # THE ANTI-COLLAPSE GUARANTEE UNDER AN UPGRADE. `record_planning_step/3`
      # replaces the entry wholesale, so the timeout's own `reason` and
      # `detail` are gone; without this marker the upgrade would erase the very
      # distinction it exists to preserve, and a reader could not tell a clean
      # decline from one that arrived after 30 minutes of silence.
      assert entry["declined_after_timeout"] == true

      # …and the merge-time warning clears, which is what the upgrade is for.
      refute Tasks.planning_gate_failed?(reload(task))
      assert Tasks.failed_planning_steps(reload(task)) == []
    end

    test "a decline emits the false-positive counterpart; a timeout does not", %{project: project} do
      attach_telemetry(PreplanStep.false_positive_event())

      task = task!(project, @ui_title, %{planning_step: "designing"})

      quietly(fn ->
        assert {:ok, :not_applicable} = PreplanStep.decline(task.id, "not visual")
      end)

      assert_receive {:telemetry, [:platform, :design, :ui_heuristic, :false_positive], _,
                      %{task_id: task_id, matched: matched, note: note}}

      assert task_id == task.id
      assert matched != []
      assert note == "not visual"

      # PAIRED CONTROL — the same fixture closed by the deadline instead. A
      # non-response is not an observation about the classifier, and an event
      # that fired on every close would tell an analyst nothing.
      expired = task!(project, @ui_title, %{planning_step: "designing"})
      quietly(fn -> assert {:ok, :failed} = PreplanStep.expire(expired, 1_800_000) end)

      refute_receive {:telemetry, [:platform, :design, :ui_heuristic, :false_positive], _, _}, 200
    end

    test "an unknown task id and a non-binary note degrade rather than raising" do
      assert {:ok, :noop} = PreplanStep.decline(Ecto.UUID.generate(), "gone")
      assert {:error, :invalid_note} = PreplanStep.decline(Ecto.UUID.generate(), nil)
    end
  end

  # ── annotate ──────────────────────────────────────────────────────────────

  describe "GUARD — annotate/3 cannot set an outcome" do
    test "an explicit outcome key is dropped and the recorded failure stands", %{
      project: project
    } do
      task = task!(project, @ui_title)
      {:ok, _} = Tasks.record_planning_step(task, :design, {:error, :boom})
      assert design_entry(task)["outcome"] == "failed"

      assert {:ok, _} =
               PreplanStep.annotate(task.id, :design, %{
                 "outcome" => "complete",
                 "reason" => "nice try"
               })

      assert design_entry(task)["outcome"] == "failed"
      assert design_entry(task)["reason"] == "nice try"

      # Atom keys take the same route.
      assert {:ok, _} = PreplanStep.annotate(task.id, :design, %{outcome: "complete", note: "x"})
      assert design_entry(task)["outcome"] == "failed"
      assert design_entry(task)["note"] == "x"
    end

    test "annotating a step with no entry is an error, not a fabricated entry", %{
      project: project
    } do
      task = task!(project, @ui_title)

      assert {:error, :no_such_step} = PreplanStep.annotate(task.id, :design, %{"reason" => "x"})
      assert design_entry(task) == nil
    end
  end

  # ── the false-negative audit ──────────────────────────────────────────────

  describe "GUARD — audit_ui_prediction/2" do
    @heex_stage %{
      name: "Render the design column",
      description: "Edit lib/platform_web/live/tasks_live.html.heex to add the column."
    }
    @backend_stage %{
      name: "Add the context function",
      description: "Add Platform.Tasks.record_thing/2 and its test."
    }

    test "contradicts a no_ui_surface verdict, without flipping the outcome", %{project: project} do
      attach_telemetry(PreplanStep.false_negative_event())

      task = task!(project, @non_ui_title)
      quietly(fn -> assert {:ok, :not_applicable} = PreplanStep.start(task) end)
      assert design_entry(task)["reason"] == "no_ui_surface"

      quietly(fn ->
        assert {:ok, :contradicted} =
                 PreplanStep.audit_ui_prediction(task.id, [@backend_stage, @heex_stage])
      end)

      assert_receive {:telemetry, [:platform, :design, :ui_heuristic, :false_negative], _,
                      %{task_id: task_id, stages: stages}}

      assert task_id == task.id
      assert stages == ["Render the design column"]

      entry = design_entry(task)
      assert entry["reason"] == "no_ui_surface_contradicted"
      assert entry["contradicted_by"] == ["Render the design column"]

      # The load-bearing half: the annotation is visible, the gate is clean.
      assert entry["outcome"] == "not_applicable"
      refute Tasks.planning_gate_failed?(reload(task))
    end

    test "is silent when the plan agrees with the verdict", %{project: project} do
      attach_telemetry(PreplanStep.false_negative_event())

      task = task!(project, @non_ui_title)
      quietly(fn -> assert {:ok, :not_applicable} = PreplanStep.start(task) end)

      assert {:ok, :consistent} = PreplanStep.audit_ui_prediction(task.id, [@backend_stage])

      refute_receive {:telemetry, [:platform, :design, :ui_heuristic, :false_negative], _, _}, 100
      assert design_entry(task)["reason"] == "no_ui_surface"
    end

    # Positive control for the two absence assertions below: the SAME UI-naming
    # plan over a task whose design step is `complete` must stay silent, so the
    # audit's silence is a property of the recorded reason and not of an audit
    # that never fires.
    test "is silent on a completed design step even when the plan names UI files", %{
      project: project
    } do
      attach_telemetry(PreplanStep.false_negative_event())

      task = task!(project, @ui_title, %{planning_step: "designing"})
      {canvas, _participant} = canvas!()
      quietly(fn -> assert {:ok, :complete} = PreplanStep.settle(task.id, canvas.id) end)

      assert {:ok, :noop} = PreplanStep.audit_ui_prediction(task.id, [@heex_stage])

      refute_receive {:telemetry, [:platform, :design, :ui_heuristic, :false_negative], _, _}, 100
      assert design_entry(task)["reason"] == "canvas_attached"
    end

    test "is silent on a no_designer skip", %{project: project} do
      attach_telemetry(PreplanStep.false_negative_event())

      task = task!(project, @ui_title)
      _ = execution_space!(task)
      quietly(fn -> assert {:ok, :not_applicable} = PreplanStep.start(task) end)
      assert design_entry(task)["reason"] == "no_designer"

      assert {:ok, :noop} = PreplanStep.audit_ui_prediction(task.id, [@heex_stage])
      refute_receive {:telemetry, [:platform, :design, :ui_heuristic, :false_negative], _, _}, 100
    end

    test "tolerates %Stage{} structs and string-keyed maps alike", %{project: project} do
      task = task!(project, @non_ui_title)
      quietly(fn -> assert {:ok, :not_applicable} = PreplanStep.start(task) end)

      string_keyed = %{
        "name" => "String keyed",
        "description" => "touches assets/js/app.js and lib/platform_web/components/thing.ex"
      }

      quietly(fn ->
        assert {:ok, :contradicted} = PreplanStep.audit_ui_prediction(task.id, [string_keyed])
      end)

      assert design_entry(task)["contradicted_by"] == ["String keyed"]
    end

    test "a non-list, an unknown task, and an unrecorded step are all no-ops", %{
      project: project
    } do
      assert {:ok, :noop} = PreplanStep.audit_ui_prediction(Ecto.UUID.generate(), [@heex_stage])
      assert {:ok, :noop} = PreplanStep.audit_ui_prediction(Ecto.UUID.generate(), :not_a_list)

      task = task!(project, @non_ui_title)
      assert {:ok, :noop} = PreplanStep.audit_ui_prediction(task.id, [@heex_stage])
    end
  end

  # ── the audit's real call site ────────────────────────────────────────────

  describe "GUARD — plan_create runs the audit" do
    test "a plan naming a .heex file contradicts a no_ui_surface skip end to end", %{
      project: project
    } do
      attach_telemetry(PreplanStep.false_negative_event())

      task = task!(project, @non_ui_title)
      quietly(fn -> assert {:ok, :not_applicable} = PreplanStep.start(task) end)

      quietly(fn ->
        assert {:ok, plan} =
                 Platform.Federation.ToolSurface.execute(
                   "plan_create",
                   %{
                     "task_id" => task.id,
                     "stages" => [
                       %{
                         "name" => "Render the design column",
                         "position" => 1,
                         "description" =>
                           "Edit lib/platform_web/live/tasks_live.html.heex to add the column."
                       }
                     ]
                   },
                   %{}
                 )

        assert length(plan.stages) == 1
      end)

      assert_receive {:telemetry, [:platform, :design, :ui_heuristic, :false_negative], _,
                      %{task_id: audited}}

      assert audited == task.id
      assert design_entry(task)["reason"] == "no_ui_surface_contradicted"
      assert design_entry(task)["outcome"] == "not_applicable"
    end

    # Paired control: the same call site, a plan that names nothing UI, and no
    # telemetry. Without it the assertion above could pass against an audit
    # that fired unconditionally.
    test "a backend-only plan leaves the skip alone", %{project: project} do
      attach_telemetry(PreplanStep.false_negative_event())

      task = task!(project, @non_ui_title)
      quietly(fn -> assert {:ok, :not_applicable} = PreplanStep.start(task) end)

      quietly(fn ->
        assert {:ok, _plan} =
                 Platform.Federation.ToolSurface.execute(
                   "plan_create",
                   %{
                     "task_id" => task.id,
                     "stages" => [
                       %{
                         "name" => "Add the context function",
                         "position" => 1,
                         "description" => "Add Platform.Tasks.record_thing/2 and its test."
                       }
                     ]
                   },
                   %{}
                 )
      end)

      refute_receive {:telemetry, [:platform, :design, :ui_heuristic, :false_negative], _, _}, 100
      assert design_entry(task)["reason"] == "no_ui_surface"
    end
  end

  # ── the "no second mapping" guards ────────────────────────────────────────

  describe "GUARD — no second mapping" do
    setup do
      %{source: File.read!(@module_path)}
    end

    test "the module never calls Responsibilities.outcome/1", %{source: source} do
      # A CALL, not a mention: the moduledoc names `Responsibilities.outcome/1`
      # on purpose — it is the whole point of the "one mapping" section — so a
      # bare substring check would be unsatisfiable for a module that documents
      # its own contract.
      call = ~r/Responsibilities\.outcome\(/

      refute Regex.match?(call, source),
             "the module calls the mapping instead of reading the persisted outcome: " <>
               inspect(Regex.run(call, source))

      refute source =~ "def outcome("

      # Control: the probe is proven capable of firing.
      assert Regex.match?(call, "x = Responsibilities.outcome(fire_result)\n")

      # And a positive control for the delegation itself, so the absence above
      # reads as "delegated", not "nothing is wired".
      assert function_exported?(Platform.Tasks, :record_planning_step, 3)
      assert function_exported?(Platform.Responsibilities, :outcome, 1)
      assert source =~ "Tasks.record_planning_step(task, @step, fire_result)"
    end

    test "the module never mentions :unknown_responsibility at all", %{source: source} do
      # Unlike the other two fire results this module has no reason to
      # CONSTRUCT it, so any occurrence would be a match — a second mapping.
      refute source =~ ":unknown_responsibility"
    end

    test "no fire-result tuple appears in a pattern position", %{source: source} do
      pattern_positions = ~r/\{:ok,\s*:(dispatched|unfilled|unknown_responsibility)\}[^\n]*->/
      function_heads = ~r/def[p]?\s+\w+\([^)]*\{:ok,\s*:(dispatched|unfilled)\}/

      refute Regex.match?(pattern_positions, source),
             "a fire-result tuple appears on the left of a `->`: " <>
               inspect(Regex.run(pattern_positions, source))

      refute Regex.match?(function_heads, source),
             "a fire-result tuple appears in a function head: " <>
               inspect(Regex.run(function_heads, source))

      # Control for the two refutes: the probes are proven capable of firing.
      assert Regex.match?(pattern_positions, "      {:ok, :unfilled} -> :whatever\n")
      assert Regex.match?(function_heads, "defp thing({:ok, :dispatched}, x) do\n")
    end

    # Task 019fa504 stage 1: the decline is the fourth terminal exit, and it is
    # the one most likely to be written as a second mapping — it is the only
    # one whose caller (an MCP tool) knows the outcome word it wants.
    test "the decline path names no outcome of its own", %{source: source} do
      literal = ~s("not_applicable")

      refute source =~ literal,
             "the decline branch restates member 1's mapping as a literal instead of " <>
               "handing a fire result to the writer and reading the outcome back"

      # Control: the probe is proven capable of firing.
      assert ~s|Map.put(entry, "outcome", "not_applicable")| =~ literal

      # The decline hands over an existing fire-result constant rather than
      # inventing a fourth tuple `Responsibilities.outcome/1` has no clause for.
      assert source =~ "@declined_fire @no_designer_fire"
      assert Responsibilities.outcome({:ok, :unfilled}) == :not_applicable

      # And the discriminator is the reason, not a new outcome word.
      assert PreplanStep.reasons().declined != PreplanStep.reasons().no_designer
      assert PreplanStep.reasons().declined != PreplanStep.reasons().timeout
    end

    test "both fire-result constants exist and are what member 1 maps", %{source: source} do
      # The two that DO appear, appear exactly as named constructor constants.
      assert source =~ "@no_designer_fire {:ok, :unfilled}"
      assert source =~ "@design_delivered_fire {:ok, :dispatched}"

      # And member 1 still maps them the way this module assumes when it reads
      # the persisted value back. If either mapping moved, this fails here
      # rather than as a mystery outcome three modules downstream.
      assert Responsibilities.outcome({:ok, :unfilled}) == :not_applicable
      assert Responsibilities.outcome({:ok, :dispatched}) == :complete
      assert Responsibilities.outcome({:error, :anything}) == :failed
    end
  end

  # ── the replacement route, end to end (task 019f9b29-e447 stage 1) ────────

  describe "BEHAVIOURAL CONTROL — a UI task reaches the designer's runtime" do
    # Member 9 deletes `Stage.responsibility`, the field that used to route a
    # planner-authored "Design direction" stage to Saru. This is the proof that
    # the behaviour that field provided — a UI task reaches the designer —
    # still happens by the pre-plan step, with zero involvement from any plan
    # stage. It is the positive half of the deletion's argument; without it
    # member 9 removes a route and shows only that the old one is gone.
    #
    # WHY IT WAS ADDED RATHER THAN CITED: every other design test in the tree
    # (this file, `TaskRouterTest`'s "pre-plan design hold",
    # `DesignTaskDirectionTest`) overrides
    # `:responsibility_router_native_dispatcher` with a stub, so all of them
    # stop one layer above the wire. `AgentResponderTest` "broadcasts a bare
    # signal envelope to the federated agent's runtime" reaches the wire but is
    # keyed on `memory.dreaming` and starts from a hand-built signal, so it
    # proves the transport, not that a UI TASK produces one. Nothing asserted
    # the join. This test does, through the real dispatcher.

    test "the design step broadcasts to the role owner's runtime; a non-UI task does not",
         %{project: project} do
      use_real_dispatcher!()
      {agent, runtime} = wire_federated_designer!()

      topic = "runtime:#{runtime.runtime_id}"
      :ok = PlatformWeb.Endpoint.subscribe(topic)

      ui = task!(project, @ui_title)
      _space = execution_space!(ui)

      quietly(fn -> PreplanStep.start(ui) end)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "attention",
                       payload: %{signal: signal}
                     },
                     2_000

      # It is the design responsibility, for THIS task, carrying a rendered
      # prompt. Asserting only "a broadcast arrived" would pass on any
      # unrelated fire that happened to reach the same runtime.
      assert signal.responsibility_key == @key
      assert signal.agent_id == agent.id
      assert signal.metadata[:task_id] == ui.id
      assert is_binary(signal.prompt) and signal.prompt != ""

      # And the step is OPEN, which is what holds the planner (member 7 stage
      # 5). A dispatch that fired without moving the cursor would leave the
      # planner racing the designer.
      assert cursor(ui) == "designing"

      # PAIRED CONTROL — same setup, same runtime, same subscription, same
      # window; only the classifier's verdict differs. Without it the assertion
      # above cannot distinguish "UI tasks reach the designer" from
      # "everything reaches the designer".
      non_ui = task!(project, @non_ui_title)
      _control_space = execution_space!(non_ui)

      quietly(fn -> PreplanStep.start(non_ui) end)

      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "attention"}, 700

      assert design_entry(non_ui)["reason"] == "no_ui_surface"
      refute cursor(non_ui) == "designing"
    end
  end

  # ── pins ──────────────────────────────────────────────────────────────────

  describe "pins (vacuous — restatements of the module, kept for future edits)" do
    test "the responsibility key is stage 3's key" do
      assert PreplanStep.responsibility_key() == @key
      assert PreplanStep.responsibility_key() == DesignTaskDirection.key()
    end

    test "reasons/0 returns the shipped strings" do
      assert PreplanStep.reasons() == %{
               no_ui_surface: "no_ui_surface",
               no_designer: "no_designer",
               canvas_attached: "canvas_attached",
               contradicted: "no_ui_surface_contradicted",
               timeout: "design_timeout",
               declined: "designer_declined"
             }
    end
  end
end
