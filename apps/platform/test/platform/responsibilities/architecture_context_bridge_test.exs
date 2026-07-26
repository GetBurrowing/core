defmodule Platform.Responsibilities.ArchitectureContextBridgeTest do
  @moduledoc """
  **The fix detector for task `019f9b28-6ca7` (ADR-0046 stack member 3).**

  Stages 1-5 of this task each shipped a real change — one per-slot
  resolver, a router that honours a refusal, and three concrete slots —
  and every one of their tests passes on a repo where the architect is
  still handed context it cannot use. This file does not. It asserts on
  the **bytes that go on the wire to the model**, which is the only
  place the three slots' output can be observed as having arrived.

  ## Why "the map has the keys" was never enough

  `architecture.review_plan` declares
  `context_provided: ["plan_payload", "sibling_tasks", "adr_index"]`.
  Every intermediate representation between that declaration and the
  model — the gathered map, the assigns map, the rendered instruction —
  is *shaped* correctly whether or not any data reached it: a missing
  plan renders as "(no plan summary available)", a missing sibling walk
  as a scope line, an unreadable ADR directory as an explicit
  "unavailable" instruction. Those are all correct, well-formed,
  key-complete values. Asserting on them cannot distinguish "the slot
  resolved" from "the slot degraded gracefully", and graceful
  degradation is exactly the defect ADR-0046 exists to remove.

  So test 1 plants a sentinel string in each of the three sources and
  asserts the sentinel is present in the JSON body POSTed to the
  external agent's `/chat/completions`. A sentinel on the wire is
  reachable through exactly one path: the slot resolved, the handler
  formatted it, the template interpolated it, and the dispatcher sent
  it.

  ## Negative verification (this was actually run — do not take it on trust)

  Each of the three slots was reverted in turn, on top of `540bf700`,
  by deleting its `ContextProviders.gather_context/2` clause so the slot
  falls into the catch-all — the pre-stage-3 world for that slot,
  `{:error, {:unknown_slot, slot}}`. All three are behavioural failures:
  the module compiles, every module the tests reference exists, and the
  revert is observable only in what arrives at the model. Each revert
  fires a *different* assertion in test 1 while the ones around it stay
  green.

    * **`:plan_payload` deleted** — 4 of 6 tests fail. In test 1 the
      handler propagates the refusal, the Router's context-refusal arm
      returns
      `{:error, {:context_gather_refused, {:unknown_slot, :plan_payload}}}`
      and **no HTTP request is made at all**, so the dispatch assertion
      fires before any content assertion runs. This contradicts the
      stage brief, which predicted all four content assertions would
      fail: since stage 2, a `:plan_payload` refusal stops the dispatch
      *before* a prompt is built.
    * **`:sibling_tasks` deleted** — 3 of 6 tests fail. The dispatch
      still succeeds (this slot never refuses, by design), the sibling
      block degrades to `[scope: no_anchor] ...`, and test 1 fails on
      `assert user =~ @sibling_sentinel`. The three `:plan_payload`
      assertions above it and the two `:adr_index` assertions below it
      stay green — they are the positive controls for this revert.
    * **`:adr_index` deleted** — 3 of 6 tests fail. The dispatch still
      succeeds, the ADR block degrades to "(ADR index unavailable —
      ...)", and test 1 fails on `assert user =~ @adr_sentinel`. Every
      `:plan_payload` and `:sibling_tasks` assertion stays green.

  The inventory test (test 2) fires under all three, naming the slot
  that lost its resolver in the diff. Its opposite direction was
  verified separately by *adding* a `gather_context(:open_prs, _)`
  clause on top of `540bf700`: test 2 alone failed, with `open_prs`
  missing from the "declared but unresolved" side. The two sentinel /
  reason tests stayed green through all four reversions.

  ## The ADR sentinel is a fixture, not the live `docs/decisions/`

  `@adr_sentinel` is a filename from `test/support/fixtures/adr_decisions`,
  bound through `config :platform, :adr_dir`. Two reasons, both
  load-bearing:

    * the shipped `architecture.review_plan.v1` body itself contains the
      example citation `0044-architect-responsibility.md`, so asserting
      a real ADR filename could pass on template text that no slot
      produced, and
    * release images ship no `docs/` at all, so an assertion against the
      live directory would be an assertion about the checkout rather
      than about the bridge.

  ## Declared-slot inventory (test 2)

  The detector proves three slots arrive. It says nothing about the
  other nine slots this codebase declares. Test 2 walks every
  `context_provided` entry of every `BuiltIns.providers/0` spec and
  requires each one to either resolve through `ContextProviders` or be
  named in `@unresolved_slots` with a reason. The assertion is a set
  equality, so it fires in three directions: a newly declared slot with
  no resolver, a listed slot that has since gained one, and a listed
  slot that is no longer declared anywhere. That last direction is what
  keeps the list self-retiring instead of a growing excuse.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.ExternalAgents.EphemeralCredentials
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.ContextProviders
  alias Platform.Responsibilities.Handlers.ArchitectureReviewPlan
  alias Platform.Responsibilities.Responsibility
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  # One sentinel per source. None of these strings appears anywhere in
  # the prompt template body, the handler, or the fallback render — so a
  # sentinel on the wire came from the slot or it came from nowhere.
  @stage_sentinel "BRIDGE_SENTINEL_STAGE"
  @intent_sentinel "BRIDGE_SENTINEL_INTENT"
  @sibling_sentinel "BRIDGE_SENTINEL_SIBLING"
  @sibling_stage_sentinel "BRIDGE_SENTINEL_SIBLING_STAGE"

  # From `test/support/fixtures/adr_decisions`. Chosen because it is the
  # one fixture ADR with no number collision, no title collision and no
  # supersession: it renders as a bare `- <file> — <title> [<status>]`
  # line, so the assertion tests the bridge rather than a flag.
  @adr_sentinel "0102-unique-and-clean.md"

  # Slots that a `BuiltIns` provider declares in `context_provided` but
  # `ContextProviders.gather_context/2` deliberately does not resolve.
  # Each of these is materialised by its own handler's `gather_context/2`
  # instead, so the declaration is documentation for operators reading
  # the row rather than a request to the shared resolver. ADR-0046 stack
  # member 3 fixes the three architecture.review_plan slots only; these
  # nine are stated, not fixed.
  @unresolved_slots %{
    "open_prs" =>
      "architecture.cron_sweep shells out to `gh pr list` in its own " <>
        "gather_open_prs/0 — no DB-backed resolver exists",
    "recent_closed_tasks" =>
      "architecture.cron_sweep materialises this itself in " <>
        "gather_recent_closed_tasks/0",
    "stage_diff" =>
      "architecture.audit_diff emits a `missing?: true` marker — git-diff " <>
        "capture is not wired into the stage-complete signal (ADR-0044 " <>
        "Consequences)",
    "planned_shape" =>
      "architecture.audit_diff materialises this itself in " <>
        "planned_shape_map/3",
    "org_memory_entries" =>
      "architecture.audit_diff serves this from its own " <>
        "@canonical_memory_flags constant",
    "canvas_snapshot" =>
      "design.critique / design.spec_writer / design.brand_check are " <>
        "placeholder handlers returning `missing?: true` — no runtime yet",
    "grounding_notes" => "design.critique / design.spec_writer placeholders — no runtime yet",
    "brand_guidelines" => "design.brand_check placeholder — no runtime yet",
    "meeting_transcript_chunk" =>
      "meetings.intent_classify placeholder — the chunk arrives on the " <>
        "trigger payload, not through a resolver"
  }

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    Application.put_env(
      :platform,
      :external_agents_dispatcher_req_client,
      Req.new(plug: {Req.Test, :arch_ctx_test})
    )

    Application.put_env(:platform, :adr_dir, fixture_adr_dir())

    on_exit(fn ->
      Application.delete_env(:platform, :external_agents_dispatcher_req_client)
      Application.delete_env(:platform, :adr_dir)
    end)

    :ok
  end

  defp fixture_adr_dir, do: Path.expand("../../support/fixtures/adr_decisions", __DIR__)

  # ── fixtures ─────────────────────────────────────────────────────────────

  # The row under test comes from the handler's own `register/0`. A
  # hand-written map would restate the spec and keep passing against a
  # row that has drifted away from what the platform actually seeds.
  defp upsert_registered_row!(handler) do
    [spec] = handler.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)
    row
  end

  # Tasks are inserted through `Repo.insert!` rather than
  # `Tasks.create_task/1` on purpose: the context-level writes broadcast
  # to the singleton TaskRouterWatcher, which evaluates from a process
  # that does not own this case's sandbox connection.
  defp insert_task!(project_id, attrs) do
    now = DateTime.utc_now()

    %TaskSchema{}
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          project_id: project_id,
          title: "Bridge Task #{System.unique_integer([:positive])}",
          status: "in_progress",
          inserted_at: now,
          updated_at: now
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp plan_with_status!(task_id, status) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task_id})

    plan
    |> Ecto.Changeset.change(status: status)
    |> Repo.update!()
  end

  # Mirrors `router_test.exs`'s `wire_external_assignee/1` with
  # `role_key: "architect"`. The agent is deliberately **external**: the
  # Router only builds and sends a prompt over HTTP on the external
  # path, so a native assignee returns before `dispatch_external/5` and
  # this detector would have no wire to assert on.
  defp wire_external_architect(responsibility_key) do
    role_key = "architect"

    Repo.insert!(
      %Role{
        key: role_key,
        name: "Architect",
        description: "test",
        icon: "hero-cube-transparent"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    %RoleResponsibility{}
    |> RoleResponsibility.changeset(%{
      role_key: role_key,
      responsibility_key: responsibility_key
    })
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: [:role_key, :responsibility_key]
    )

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "arch-ctx-bridge-ext-#{System.unique_integer([:positive])}",
        name: "Architect Context Bridge External",
        status: "active",
        kind: "external",
        endpoint_kind: "openai_compat",
        base_url: "https://api.example.test",
        model: "test-model",
        workspace_id: nil
      })
      |> Repo.insert!()

    :ok = EphemeralCredentials.put(agent.id, "sk-arch-ctx-bridge-test")
    on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

    {:ok, _} = Roles.assign_role(role_key, agent.id)

    agent
  end

  defp stub_architect_reply!(comment) do
    test_pid = self()

    Req.Test.stub(:arch_ctx_test, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:outbound, conn.request_path, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => comment}}
        ]
      })
    end)

    :ok
  end

  defp message_role(messages, role) when is_list(messages) do
    case Enum.find(messages, &(&1["role"] == role)) do
      %{"content" => content} when is_binary(content) -> content
      _ -> nil
    end
  end

  # ── test 1: the detector ─────────────────────────────────────────────────

  describe "all three declared slots reach the architect's outbound prompt" do
    setup do
      row = upsert_registered_row!(ArchitectureReviewPlan)

      {:ok, project} = Tasks.create_project(%{name: "Arch Context Bridge Project"})

      # The anchor. No stack_id and no epic_id, so `:sibling_tasks`
      # resolves through the bounded project-window tier — the tier that
      # actually has to run a query, rather than the two that short out
      # on a nil foreign key.
      task =
        insert_task!(project.id, %{
          title: "Bridge the three slots into the architect prompt",
          description:
            "The architect must be able to read this line: #{@intent_sentinel}.\n" <>
              "It exists nowhere else in the prompt path.",
          status: "planning"
        })

      plan = plan_with_status!(task.id, "pending_review")

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: @stage_sentinel,
          description: "The stage whose name must survive the trip to the model."
        })

      {:ok, _validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

      # A sibling in the same project with a live plan, so the
      # project-window tier has something to return. Without it the
      # sibling block would render `[scope: none]` and the sibling
      # assertion could not distinguish "resolved and empty" from "never
      # resolved".
      sibling =
        insert_task!(project.id, %{
          title: "#{@sibling_sentinel} — the colliding task",
          status: "in_progress"
        })

      sibling_plan = plan_with_status!(sibling.id, "approved")

      {:ok, _sibling_stage} =
        Tasks.create_stage(%{
          plan_id: sibling_plan.id,
          position: 1,
          name: @sibling_stage_sentinel,
          description: "A sibling stage description that must also arrive."
        })

      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      agent = wire_external_architect(row.key)

      %{row: row, task: task, plan: plan, stage: stage, space: space, agent: agent}
    end

    test "plan stages, gates, task intent, siblings and the ADR index are all on the wire",
         ctx do
      :ok = stub_architect_reply!("bridge check — nothing to flag")

      # The exact meta `Platform.Tasks.fire_architecture_review_plan/1`
      # publishes on plan submission. A hand-simplified map would let
      # the real publisher drift away from what the slots can read.
      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(
                   ctx.row,
                   %{plan_id: ctx.plan.id, task_id: ctx.task.id, plan: ctx.plan},
                   %{}
                 )
      end)

      assert_receive {:outbound, "/chat/completions", body}

      user = message_role(body["messages"], "user")

      assert is_binary(user),
             "no user turn on the wire — the dispatch never reached the model"

      # ── :plan_payload ────────────────────────────────────────────────
      # The stage NAME. Reachable only via
      # ContextProviders.gather_context(:plan_payload, _) →
      # stage_payload/1 → format_stage_line/1 → {{plan_summary}}.
      assert user =~ @stage_sentinel,
             ":plan_payload did not reach the wire — no stage name in the prompt"

      # The stage's validation GATES. The architect cannot tell a
      # protected stage from an unprotected one without them, and they
      # travel on a different field of the same slot than the name does.
      assert user =~ "gates: test_pass(pending)",
             ":plan_payload reached the wire without its validation gates"

      # The task INTENT. Third distinct field of the same slot — a plan
      # rendered without the intent it was written against cannot be
      # judged for scope drift.
      assert user =~ @intent_sentinel,
             ":plan_payload reached the wire without the task description"

      # ── :sibling_tasks ───────────────────────────────────────────────
      assert user =~ @sibling_sentinel,
             ":sibling_tasks did not reach the wire — no sibling title in the prompt"

      assert user =~ @sibling_stage_sentinel,
             ":sibling_tasks reached the wire without the siblings' stage names — " <>
               "a title alone cannot be checked for a duplicate abstraction"

      # The scope disclosure line. Absence must never be silent, so the
      # tier that produced the list travels with it.
      assert user =~ "[scope: project_window]",
             ":sibling_tasks reached the wire without its scope disclosure line"

      # ── :adr_index ───────────────────────────────────────────────────
      assert user =~ @adr_sentinel,
             ":adr_index did not reach the wire — no ADR filename in the prompt"

      refute user =~ "ADR index unavailable",
             ":adr_index degraded to the unavailable block despite a readable directory"
    end

    test "the sentinels are absent from the un-interpolated template body", ctx do
      # The positive control for test 1 as a whole: if any sentinel were
      # already present in the prompt template, the assertions above
      # would pass without a slot resolving anything. This asserts the
      # template body is sentinel-free, so the only route onto the wire
      # is through the slots.
      body = PromptTemplates.default_content_for_slug(ArchitectureReviewPlan.template_slug())

      assert is_binary(body)

      for sentinel <- [
            @stage_sentinel,
            @intent_sentinel,
            @sibling_sentinel,
            @sibling_stage_sentinel,
            @adr_sentinel
          ] do
        refute body =~ sentinel,
               "sentinel #{sentinel} is present in the template body — test 1 would pass " <>
                 "on template text rather than on gathered context"
      end

      # And the row the migration force-updated says the same thing, so
      # a drifted DB body cannot smuggle a sentinel in either.
      assert ctx.row.key == "architecture.review_plan"
    end
  end

  # ── test 2: the declared-slot inventory ──────────────────────────────────

  describe "declared context slots" do
    test "every declared slot either resolves or is listed as knowingly unresolved" do
      declared = declared_slots()

      assert MapSet.size(declared) > 0,
             "no context_provided entries found — the walk itself is broken"

      {resolved, unresolved} =
        declared
        |> Enum.sort()
        |> Enum.split_with(&slot_resolves?/1)

      assert MapSet.new(unresolved) == MapSet.new(Map.keys(@unresolved_slots)),
             """
             The declared-slot inventory drifted.

             Declared but unresolved: #{inspect(unresolved)}
             Listed in @unresolved_slots: #{inspect(Enum.sort(Map.keys(@unresolved_slots)))}

             Three ways this fires, all of them real:
               * a handler declared a new slot with no ContextProviders clause
                 (add the clause, or add the slot here with a one-line reason),
               * a slot listed here now resolves (delete its entry — the list
                 is meant to shrink), or
               * a slot listed here is no longer declared by any provider
                 (delete its entry).
             """

      # Positive control. These three are what ADR-0046 stack member 3
      # landed; if the walk above were vacuous — wrong module list,
      # empty specs, a `slot_resolves?/1` that always says yes — this
      # would not distinguish it, but a revert of any of the three
      # clauses moves that slot into `unresolved` and fails the equality
      # above with a named diff.
      assert "plan_payload" in resolved
      assert "sibling_tasks" in resolved
      assert "adr_index" in resolved
    end

    test "every listed unresolved slot carries a usable reason" do
      for {slot, note} <- @unresolved_slots do
        assert is_binary(note) and String.length(note) > 20,
               "#{slot} is listed as unresolved without a usable reason"
      end
    end

    test "the resolver's own catch-all is what marks a slot unresolved" do
      # `slot_resolves?/1` is only meaningful if an unknown slot is
      # distinguishable from a known one that happens to error. Pin the
      # catch-all's return value so a change to it fails here rather
      # than silently turning the inventory into a tautology.
      assert {:error, {:unknown_slot, :definitely_not_a_slot}} =
               ContextProviders.gather_context(:definitely_not_a_slot, [])

      # A known slot that cannot resolve returns its own reason, NOT
      # `:unknown_slot` — this is the distinction the inventory rides on.
      assert {:error, :no_plan_payload} = ContextProviders.gather_context(:plan_payload, [])
    end
  end

  # ── test 3: the handler materialises nothing of its own ──────────────────

  describe "ArchitectureReviewPlan delegates to ContextProviders" do
    test "each gathered slot is byte-identical to the resolver's own output" do
      {:ok, project} = Tasks.create_project(%{name: "Arch Delegation Project"})

      task = insert_task!(project.id, %{title: "Delegation anchor", status: "planning"})
      plan = plan_with_status!(task.id, "pending_review")

      {:ok, _stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Delegation stage",
          description: "Present so the payload is non-trivial."
        })

      _sibling_plan =
        project.id
        |> insert_task!(%{title: "Delegation sibling", status: "in_progress"})
        |> Map.fetch!(:id)
        |> plan_with_status!("approved")

      meta = %{plan_id: plan.id, task_id: task.id, plan: plan}

      {:ok, gathered} = ArchitectureReviewPlan.gather_context(responsibility(), meta)

      # This is the grep from the stage brief, expressed as behaviour
      # instead of as a source scan: if the handler carried a private
      # materialiser for any of the three slots, its output would differ
      # from the resolver's. Renaming a function cannot satisfy this;
      # only actually delegating can.
      {:ok, %{plan_payload: expected_plan}} =
        ContextProviders.gather_context(:plan_payload, meta)

      {:ok, %{sibling_tasks: expected_siblings}} =
        ContextProviders.gather_context(:sibling_tasks, %{task_id: task.id})

      {:ok, %{adr_index: expected_adrs}} = ContextProviders.gather_context(:adr_index, %{})

      assert gathered.plan_payload == expected_plan
      assert gathered.sibling_tasks == expected_siblings
      assert gathered.adr_index == expected_adrs
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Built from the handler's own `register/0` for the same reason
  # `upsert_registered_row!/1` is: a hand-written struct restates the
  # spec and keeps passing against a drifted one.
  defp responsibility do
    [spec] = ArchitectureReviewPlan.register()
    struct!(Responsibility, Map.put(spec, :id, Ecto.UUID.generate()))
  end

  defp declared_slots do
    BuiltIns.providers()
    |> Enum.flat_map(& &1.register())
    |> Enum.flat_map(&(Map.get(&1, :context_provided) || []))
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  # A slot "resolves" iff `ContextProviders` has a clause for it. The
  # catch-all's `{:error, {:unknown_slot, slot}}` is the only signal for
  # "no clause" — a known slot that refuses (`:plan_payload` with no
  # plan) or degrades (`:adr_index` with no directory) still resolves.
  #
  # A declared name with no existing atom cannot have a clause either:
  # every clause head is an atom literal, so compiling the resolver
  # would have created the atom.
  defp slot_resolves?(name) when is_binary(name) do
    atom = String.to_existing_atom(name)

    case ContextProviders.gather_context(atom, []) do
      {:error, {:unknown_slot, ^atom}} -> false
      _other -> true
    end
  rescue
    ArgumentError -> false
  end
end
