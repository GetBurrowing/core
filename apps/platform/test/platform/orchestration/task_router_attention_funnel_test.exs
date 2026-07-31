defmodule Platform.Orchestration.TaskRouterAttentionFunnelTest do
  @moduledoc """
  Task 019fb90f stage 3 — the TaskRouter's dispatch goes through
  `Platform.Federation.AttentionDispatch`.

  ## This is a behaviour change, not a refactor, and the negative control is
  ## what says so

  `Platform.Orchestration.ExecutionSpace.add_participant/2` had ZERO production
  call sites before this stage — the only reference in the repo was its own
  test. So a federated assignee was dispatched into an execution space it had
  never been added to, and became able to write there only *incidentally*, when
  a router prompt happened to contain an `@[slug]` token that
  `Chat.reinvite_and_pin_mentioned/1` picked up.

  "The agent can write the execution space after a dispatch" is therefore not
  the claim. The claim is that it **could not before and can now**, which is why
  the first assertion of the happy-path test is a real
  `ToolSurface.execute("canvas_create", ...)` refusal against the already-created
  execution space, taken before the router starts. Without that half, a test
  asserting only the post-state would pass just as happily on a tree where the
  agent had always been a member.

  ## The probe context has to be built the way production builds it

  `Canvas.ToolHandlers.create/2` reads `context[:agent_participant_id]` and does
  NOT derive it from `:agent_id`. A probe passing `%{agent_id: agent.id}` alone
  refuses identically before AND after the invite — a negative control that
  looks like it is working while proving nothing. `mcp_context/2` below resolves
  the participant at call time, mirroring `PlatformWeb.MCPController.build_context/2`.

  ## `async: false`

  The router is a real GenServer started per test and reads `Repo` from its own
  process, so the sandbox has to be in shared mode. Same reason as
  `task_router_test.exs`.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  @invite_event [:platform, :chat, :dispatch_auto_invite]

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Funnel Router Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/funnel-router"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Funnel Router Task",
        description: "Bridges the router onto the attention funnel",
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "coding",
        description: "Write code"
      })

    {:ok, _validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    on_exit(fn ->
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{pid, _}] ->
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{project: project, task: task, plan: plan, stage: stage}
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  # An agent linked to an AgentRuntime, addressed by the runtime's EXTERNAL
  # `runtime_id` string — the same shape `%{type: :federated, id: ...}` carries
  # and the same one `Federation.lookup_assignment/1` resolves.
  defp federated_agent do
    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "funnel-router-#{n}@example.com",
        name: "Funnel Router Owner #{n}",
        oidc_sub: "oidc-funnel-router-#{n}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-funnel-router-#{n}",
        display_name: "funnel-router-#{n}"
      })

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "funnel-router-agent-#{n}",
        name: "Funnel Router Agent #{n}",
        status: "active",
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert!()

    # The link is BIDIRECTIONAL and both halves are load-bearing here:
    # `agent.runtime_id` is what `Federation.get_runtime_for_agent/1` follows,
    # and `runtime.agent_id` is what `Federation.lookup_assignment/1` follows.
    # The router resolves through the second one, so a fixture that set only
    # the first would report `:no_agent_named` and quietly test nothing.
    runtime =
      runtime
      |> Ecto.Changeset.change(%{agent_id: agent.id})
      |> Repo.update!()

    %{agent: agent, runtime: runtime, assignee: %{type: :federated, id: runtime.runtime_id}}
  end

  defp mcp_context(space_id, agent_id) do
    participant_id =
      case Chat.get_agent_participant(space_id, agent_id) do
        %Participant{id: id} -> id
        _ -> nil
      end

    %{space_id: space_id, agent_id: agent_id, agent_participant_id: participant_id}
  end

  defp canvas_probe(space_id, agent_id) do
    args = %{
      "space_id" => space_id,
      "title" => "writability probe",
      "document" => %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "text",
          "props" => %{"value" => "probe"},
          "children" => []
        }
      }
    }

    ToolSurface.execute("canvas_create", args, mcp_context(space_id, agent_id))
  end

  defp participant_count(space_id, agent_id) do
    Repo.aggregate(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "agent" and
            p.participant_id == ^agent_id
      ),
      :count
    )
  end

  defp agent_participant_ids(space_id) do
    Repo.all(
      from(p in Participant,
        where: p.space_id == ^space_id and p.participant_type == "agent",
        select: p.participant_id
      )
    )
    |> MapSet.new()
  end

  defp attach_invite_telemetry do
    ref = make_ref()
    pid = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      @invite_event,
      fn _event, measurements, metadata, _cfg ->
        send(pid, {:auto_invite, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  # ── The gap this stage closes ──────────────────────────────────────────────

  describe "a federated dispatch makes the assignee writable in the execution space" do
    test "it could not write before the dispatch and can after", %{task: task} do
      %{agent: agent, assignee: assignee} = federated_agent()

      # The router creates this in `init/1`, but `find_or_create/1` is
      # idempotent — creating it here is what lets the negative control run
      # against the SAME space the router will dispatch into.
      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      assert space.kind == "execution"

      # NEGATIVE CONTROL. Not decoration: the whole claim is that this refusal
      # used to survive the dispatch.
      assert Chat.get_agent_participant(space.id, agent.id) == nil
      assert {:error, %{recoverable: false} = refusal} = canvas_probe(space.id, agent.id)
      assert refusal.error =~ "is not a participant"

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      # Byte-identical call, opposite result. The success shape is
      # `%{id: _, title: _, kind: _, view_url: _}` — there is no `:canvas_id`
      # key on this tool's reply, and the refusal above is keyed `:error`, not
      # `:message`. Both differ from the shapes stage 5's e2e script names.
      assert {:ok, %{id: canvas_id, kind: "text"}} = canvas_probe(space.id, agent.id)
      assert is_binary(canvas_id)
    end

    test "the participant row is a member on \"all\", exactly one of it", %{task: task} do
      ref = attach_invite_telemetry()
      %{agent: agent, assignee: assignee} = federated_agent()

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      space = ExecutionSpace.find_by_task_id(task.id)

      # `"all"`, not `"mention"`. The router's engagement messages do not
      # @-mention the assignee, so a `"mention"` posture would deliver the
      # invite and still leave the agent deaf to everything it was invited for.
      # This is the one behaviour the deleted `ExecutionSpace.add_participant/2`
      # encoded, now living once in DispatchMembership's per-kind policy.
      assert %Participant{attention_mode: "all", role: "member"} =
               Chat.get_agent_participant(space.id, agent.id)

      # Equality with 1, not a floor: the router dispatches more than once over
      # a task's life and a find-or-insert bug would show up as churn here.
      assert participant_count(space.id, agent.id) == 1

      assert_receive {:auto_invite, ^ref, %{count: 1},
                      %{outcome: :invited, source: :task_router, space_kind: "execution"}},
                     1_000
    end

    test "the invite commits BEFORE the attention broadcast leaves", %{task: task} do
      ref = attach_invite_telemetry()
      %{assignee: assignee} = federated_agent()

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # POSITIONAL, not selective. `assert_receive` with a pattern scans the
      # whole mailbox, so two pattern-matched assertions would pass with the
      # order inverted — and inverted is the dead-on-arrival window this stage
      # exists to close. Both sends reach this process directly, so mailbox
      # order is the happens-before order.
      assert_receive first, 1_000
      assert {:auto_invite, ^ref, _measurements, %{outcome: :invited}} = first

      assert_receive second, 1_000
      assert %Phoenix.Socket.Broadcast{event: "attention"} = second
    end
  end

  describe "resolution failures never block the dispatch" do
    test "an assignee whose runtime_id resolves to no agent still gets its signal", %{task: task} do
      ref = attach_invite_telemetry()

      # A runtime_id with no AgentRuntime row behind it. The signal is
      # addressed by runtime_id, not by the agent row, so delivery must not
      # depend on the lookup succeeding.
      assignee = %{type: :federated, id: "rt-unresolvable-#{System.unique_integer([:positive])}"}

      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      # Snapshot the ROSTER, not a count against a remembered expectation. The
      # space is not empty — `Chat.create_space/1` auto-adds the Historian — so
      # "assert zero agent participants" would be false for reasons that have
      # nothing to do with this stage. Diffing the set instead means ANY agent
      # added by the dispatch fails the test, including one nobody thought to
      # name.
      before = agent_participant_ids(space.id)

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      # `:no_agent_named`, not a shared `:refused` — an operator seeing this
      # knows the runtime is unlinked, which is a different repair from a
      # deleted space or an archived one.
      assert_receive {:auto_invite, ^ref, _, %{outcome: :no_agent_named, source: :task_router}},
                     1_000

      assert agent_participant_ids(space.id) == before
    end
  end
end
