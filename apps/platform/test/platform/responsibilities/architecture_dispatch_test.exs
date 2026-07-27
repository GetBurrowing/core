defmodule Platform.Responsibilities.ArchitectureDispatchTest do
  @moduledoc """
  End-to-end fix detector for task `019f9b28` (ADR-0046 stack member 2):
  a `Router.fire_trigger/3` on a real `architecture.*` row must reach the
  handler's `ExecutionSpace.post_log/2` and land an `[architect]`
  annotation in the task's execution space.

  ## Why this file exists

  `architecture.review_plan` and `architecture.audit_diff` shipped with
  a full `build_prompt/1` + `handle_output/3` body months ago
  (ADR-0044). They were never reachable. The Router resolved a provider
  module by camelising `Responsibility.feature` — `"architecture"` →
  `Platform.Responsibilities.Providers.Architecture` — and that module
  did not exist, so:

    * `build_prompt_via_provider/2` fell through to `:legacy` and the
      dispatcher rendered the *slug string*
      `"architecture.review_plan.v1"` as the whole user turn, and
    * `invoke_handle_output/3` logged
      `"no output handler for architecture.review_plan"` and dropped
      the architect's answer on the floor.

  Everything the earlier stages of this task added — the shim's shape,
  the explicit `Providers` registry, the Registry-boot drift log, the
  BuiltIns coverage walk — passes on a repo where the architect's
  answer is still discarded. This file does not. It is the task's fix
  detector; the others are guards.

  ## Negative verification (detonation)

  Remove `"architecture"` from
  `Platform.Responsibilities.Providers.@feature_providers` and leave
  `providers/architecture.ex` in place, then re-run this file. All
  three assertions in each test fail on *behaviour*:

    1. the outbound request body carries the legacy slug render instead
       of the architect's own `build_prompt/1` output,
    2. no message beginning `"[architect]"` exists in the execution
       space, and
    3. the captured log contains
       `"no output handler for architecture.review_plan"`.

  Deleting `providers/architecture.ex` outright also detonates it, but
  that reversion risks failing on compile/`ArgumentError` mechanics
  rather than on behaviour, so the `@feature_providers` edit is the
  canonical detonation. Note this branch is stacked: reverting `HEAD~1`
  would leave an earlier stage's fix in place and produce a false
  negative.

  ## Stated exclusion: `architecture.cron_sweep`

  The third architecture key is deliberately NOT exercised end-to-end
  here. Its `gather_context/2` shells out to `gh` and its
  `handle_output/3` files real tasks, so an e2e harness would have to
  stub a subprocess and a task-creation side effect — disproportionate
  to the signal gained. Its routing is covered by
  `providers/architecture_test.exs` (`handler_for/1`, `register/0`) and
  by `provider_coverage_test.exs`. Recording the gap here so it is a
  stated exclusion rather than an assumed one: **if `cron_sweep` ever
  regresses at dispatch time, no test in this repo catches it.**
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.ExternalAgents.EphemeralCredentials
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.ArchitectureAuditDiff
  alias Platform.Responsibilities.Handlers.ArchitectureReviewPlan
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility
  alias Platform.Tasks

  # The sentinel travels: stub response body → Dispatcher.parse_response
  # → ContractValidator (both architecture contracts classify as
  # :unknown, i.e. freeform, so the raw string survives) →
  # extract_comment/1's bare-binary clause → post_log/2. No JSON
  # contract to satisfy, so a mismatch means the path broke, not that
  # the payload shape drifted.
  @sentinel "ARCHITECT_SENTINEL"

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    Application.put_env(
      :platform,
      :external_agents_dispatcher_req_client,
      Req.new(plug: {Req.Test, :arch_dispatch_test})
    )

    on_exit(fn ->
      Application.delete_env(:platform, :external_agents_dispatcher_req_client)
    end)

    # config/test.exs pins the repo logger at :warning; the Router's
    # dispatch + missing-handler lines are :info / :warning, and
    # assertion 3 is a `refute` against the missing-handler line, so we
    # must be able to see it if it fires.
    Logger.put_module_level(Router, :info)
    on_exit(fn -> Logger.delete_module_level(Router) end)

    :ok
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  # The row under test comes from the handler's OWN `register/0`, never
  # a hand-written map. If the shipped spec drifts (key renamed, feature
  # changed, output_contract turned into something the validator rejects)
  # this test must go red — a fixture that re-states the spec by hand
  # would keep passing against a row nobody dispatches.
  defp upsert_registered_row!(handler) do
    [spec] = handler.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)
    row
  end

  # Mirrors `router_test.exs`'s `wire_external_assignee/1`, with
  # `role_key: "architect"` — the role the ADR-0044 seeds bundle these
  # keys under. The agent is deliberately **external**: the Router only
  # runs `handle_output/3` inline on the external path, so a native
  # assignee would never reach `ExecutionSpace.post_log/2` and this
  # detector would prove nothing.
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
        slug: "arch-dispatch-ext-#{System.unique_integer([:positive])}",
        name: "Architect Test External",
        status: "active",
        kind: "external",
        endpoint_kind: "openai_compat",
        base_url: "https://api.example.test",
        model: "test-model",
        workspace_id: nil
      })
      |> Repo.insert!()

    :ok = EphemeralCredentials.put(agent.id, "sk-arch-dispatch-test")
    on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

    {:ok, _} = Roles.assign_role(role_key, agent.id)

    agent
  end

  defp stub_architect_reply!(comment) do
    test_pid = self()

    Req.Test.stub(:arch_dispatch_test, fn conn ->
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

  defp annotation_in(space_id, prefix) do
    space_id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.find(fn msg ->
      is_binary(msg.content) and String.starts_with?(msg.content, prefix)
    end)
  end

  defp make_project(name) do
    {:ok, project} = Tasks.create_project(%{name: name})
    project
  end

  # The meta shape here is exactly what
  # `Platform.Tasks.PlanEngine.after_stage_completed/1` publishes on the
  # "passed" transition — a hand-simplified map would let the real
  # publisher drift away from what the handler can read.
  defp audit_trigger_meta(ctx) do
    %{
      stage_id: ctx.stage.id,
      plan_id: ctx.plan.id,
      task_id: ctx.task.id,
      stage: ctx.stage,
      plan: ctx.plan,
      task: ctx.task
    }
  end

  # ── architecture.review_plan ─────────────────────────────────────────────

  describe "architecture.review_plan end-to-end via Router.fire_trigger/3" do
    setup do
      row = upsert_registered_row!(ArchitectureReviewPlan)

      project = make_project("Arch Dispatch Review Project")

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Bridge the architect dispatch path",
          status: "planning"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Wire the provider shim",
          description: "Edit only apps/platform/lib/platform/responsibilities/providers.ex."
        })

      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      agent = wire_external_architect(row.key)

      %{row: row, task: task, plan: plan, stage: stage, space: space, agent: agent}
    end

    test "the architect's own build_prompt/1 output is what goes on the wire", ctx do
      :ok = stub_architect_reply!("#{@sentinel} boundary objection")

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(
                   ctx.row,
                   %{plan_id: ctx.plan.id, task_id: ctx.task.id, plan: ctx.plan},
                   %{}
                 )
      end)

      assert_receive {:outbound, "/chat/completions", body}

      messages = body["messages"]
      assert is_list(messages)

      system = message_role(messages, "system")
      user = message_role(messages, "user")

      # From ArchitectureReviewPlan.build_prompt/1 verbatim. The legacy
      # render path emits no system turn at all.
      assert is_binary(system),
             "no system turn on the wire — build_prompt/1 never ran (legacy fallback)"

      # ADR-0046 member 5 stage 4 rewrote this slot: the architect is no
      # longer "additive", it holds a gate. The prefix moved with it.
      assert system =~ "You are the Architect on the Suite plan-review path (ADR-0044"
      assert system =~ "plan_architecture_verdict"

      # From the architecture.review_plan.v1 template body, rendered by
      # ArchitectureReviewPlan.render_instruction/1.
      assert user =~ "held at\n`pending_review` until you answer"

      # Data-derived: only reachable if the provider's gather_context/2
      # walked the plan. Under :legacy the user turn is the literal slug
      # string "architecture.review_plan.v1".
      assert user =~ ctx.task.title
      assert user =~ ctx.stage.name
      refute user == ArchitectureReviewPlan.template_slug()
    end

    test "the architect's answer lands in the execution space as an [architect] annotation",
         ctx do
      :ok = stub_architect_reply!("#{@sentinel} boundary objection")

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Router.fire_trigger(
                   ctx.row,
                   %{plan_id: ctx.plan.id, task_id: ctx.task.id, plan: ctx.plan},
                   %{}
                 )
      end)

      assert_receive {:outbound, "/chat/completions", _body}

      annotation = annotation_in(ctx.space.id, "[architect] ")

      assert annotation,
             "no \"[architect] \" message in the execution space — handle_output/3 never ran"

      assert annotation.content =~ @sentinel
    end

    test "the Router does not log a missing output handler for the key", ctx do
      :ok = stub_architect_reply!("#{@sentinel} boundary objection")

      log =
        capture_log([level: :info], fn ->
          assert {:ok, :dispatched} =
                   Router.fire_trigger(
                     ctx.row,
                     %{plan_id: ctx.plan.id, task_id: ctx.task.id, plan: ctx.plan},
                     %{}
                   )
        end)

      assert_receive {:outbound, "/chat/completions", _body}

      refute log =~ "no output handler for architecture.review_plan"
      assert log =~ "external dispatch ok key=architecture.review_plan"
    end
  end

  # ── architecture.audit_diff ──────────────────────────────────────────────

  describe "architecture.audit_diff end-to-end via Router.fire_trigger/3" do
    setup do
      row = upsert_registered_row!(ArchitectureAuditDiff)

      project = make_project("Arch Dispatch Audit Project")

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Audit the shipped stage against its planned shape",
          status: "in_progress"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Land the coverage walk",
          description: "Edit only apps/platform/test/platform/responsibilities/."
        })

      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      agent = wire_external_architect(row.key)

      %{row: row, task: task, plan: plan, stage: stage, space: space, agent: agent}
    end

    test "the architect's own build_prompt/1 output is what goes on the wire", ctx do
      :ok = stub_architect_reply!("#{@sentinel} drift: touched an unplanned subsystem")

      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} = Router.fire_trigger(ctx.row, audit_trigger_meta(ctx), %{})
      end)

      assert_receive {:outbound, "/chat/completions", body}

      messages = body["messages"]
      assert is_list(messages)

      system = message_role(messages, "system")
      user = message_role(messages, "user")

      assert is_binary(system),
             "no system turn on the wire — build_prompt/1 never ran (legacy fallback)"

      assert system =~ "You are the Architect on the Suite post-executor drift-audit path"

      assert user =~ "A stage just transitioned to `passed`"
      assert user =~ ctx.stage.name
      assert user =~ ctx.task.title
      refute user == ArchitectureAuditDiff.template_slug()
    end

    test "the architect's answer lands in the execution space as an [architect] annotation",
         ctx do
      :ok = stub_architect_reply!("#{@sentinel} drift: touched an unplanned subsystem")

      log =
        capture_log([level: :info], fn ->
          assert {:ok, :dispatched} = Router.fire_trigger(ctx.row, audit_trigger_meta(ctx), %{})
        end)

      assert_receive {:outbound, "/chat/completions", _body}

      annotation = annotation_in(ctx.space.id, "[architect | audit_diff] ")

      assert annotation,
             "no \"[architect | audit_diff] \" message in the execution space — " <>
               "handle_output/3 never ran"

      assert annotation.content =~ @sentinel

      refute log =~ "no output handler for architecture.audit_diff"
      assert log =~ "external dispatch ok key=architecture.audit_diff"
    end
  end
end
