defmodule Platform.Orchestration.ExecutionSpaceLatestEngagementTest do
  @moduledoc """
  Task 01a03ed3 — the durable record a boot-re-engagement guard reads.

  ## Why the record has to exist at all

  A dispatch that resolves no stage persists nothing.
  `TaskRouter.arm_liveness_timers/3` has an `(_task_id, nil, _stage_kind), do:
  :ok` clause, so a planning dispatch writes no `LeaseManager` row. The
  engagement message posted into the execution space is the only trace it
  happened. Every repeat therefore looks, to anything reading state, exactly
  like a first attempt.

  ## Why `latest_engagement/1` cannot just mean "the newest message"

  `ExecutionSpace.post_log/2` writes rows into the same space under the same
  `"source" => "task_router"`, and the suppression status line it carries is
  ~213 bytes against a dispatch prompt's ~30,000. A query that matched on
  source alone, or on `log_only == false` alone, would hand a caller a status
  line where a prompt was expected — and a guard comparing two "engagements"
  would then find them different and conclude a repeat was legitimate. The
  third test below posts a log AFTER an engagement for exactly that reason.

  ## `async: false`

  The router is a real GenServer started per test and reads `Repo` from its own
  process, so the sandbox has to be in shared mode. `RuntimePresence` is a
  named application-level Agent that the sandbox does NOT roll back, hence the
  explicit `untrack/1` in `on_exit`.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Federation.RuntimePresence
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  # The identifying literal every content assertion in this file is built
  # from. It is written onto the fixture task's `description` and read back
  # off `task.description`, never off this constant — see `identifying_text/1`.
  @description_marker "Boot re-engagement probe: the router restarts and dispatches again."

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{
        name: "Boot Re-engagement Project #{n}",
        repo_url: "https://github.com/example-org/boot-reengagement"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Boot Re-engagement Task #{n}",
        description: @description_marker,
        deploy_target: "production"
      })

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

    %{project: project, task: task}
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  # ANTI-VACUITY GATE. Every content assertion below routes through here, so
  # the literal it compares against is the value actually persisted on the
  # task row, not `@description_marker`. A fixture that silently dropped the
  # description (a changeset rename, a `:description` field removal) makes this
  # raise instead of making the content assertions pass against "".
  defp identifying_text(task) do
    reloaded = Repo.get!(Platform.Tasks.Task, task.id)
    description = reloaded.description

    refute is_nil(description),
           "fixture task #{task.id} persisted no description — every content " <>
             "assertion in this file would be vacuous"

    refute String.trim(description) == "",
           "fixture task #{task.id} persisted a blank description — every " <>
             "content assertion in this file would be vacuous"

    description
  end

  # An agent linked to an AgentRuntime and addressed by the runtime's EXTERNAL
  # `runtime_id` string. The link is bidirectional on purpose:
  # `Federation.lookup_assignment/1` follows `runtime.agent_id`, and a fixture
  # setting only `agent.runtime_id` resolves to no agent.
  defp federated_agent do
    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "boot-reengagement-#{n}@example.com",
        name: "Boot Re-engagement Owner #{n}",
        oidc_sub: "oidc-boot-reengagement-#{n}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "runtime-test-#{n}",
        display_name: "boot-reengagement-#{n}"
      })

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "boot-reengagement-agent-#{n}",
        name: "Boot Re-engagement Agent #{n}",
        status: "active",
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert!()

    runtime =
      runtime
      |> Ecto.Changeset.change(%{agent_id: agent.id})
      |> Repo.update!()

    %{agent: agent, runtime: runtime, assignee: %{type: :federated, id: runtime.runtime_id}}
  end

  defp message_count(space_id) do
    Repo.aggregate(
      from(m in Message, where: m.space_id == ^space_id and is_nil(m.deleted_at)),
      :count
    )
  end

  # The engagement is posted AFTER `dispatch_attention/5` returns, so the
  # attention broadcast can land in this process's mailbox before the row is
  # committed. Poll rather than read once.
  defp await_engagement(space_id, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_engagement(space_id, deadline)
  end

  defp do_await_engagement(space_id, deadline) do
    case ExecutionSpace.latest_engagement(space_id) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("no engagement was posted into space #{space_id} before the deadline")
        else
          Process.sleep(25)
          do_await_engagement(space_id, deadline)
        end

      engagement ->
        engagement
    end
  end

  # ── The query ──────────────────────────────────────────────────────────────

  describe "latest_engagement/1 distinguishes an engagement from a log line" do
    test "a space holding only post_log/2 rows yields nil", %{task: task} do
      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      {:ok, _} =
        ExecutionSpace.post_log(
          space.id,
          "Dispatch suppressed: plan is awaiting human review | Task: #{task.title}"
        )

      {:ok, _} =
        ExecutionSpace.post_log(space.id, "Task assigned: #{task.title} | Stage: -/0")

      # POSITIVE CONTROL. "Returns nil" is also what an empty space returns and
      # what a broken `post_log/2` would produce, so assert the rows are really
      # in the space before reading nil as a filtering result.
      assert message_count(space.id) == 2

      assert ExecutionSpace.latest_engagement(space.id) == nil
    end

    test "a log posted AFTER an engagement does not displace it", %{task: task} do
      description = identifying_text(task)
      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      prompt = "Dispatch prompt for #{task.title}.\n\nDescription: #{description}"

      {:ok, _} =
        ExecutionSpace.post_engagement(space.id, prompt, metadata: %{"reason" => "task_assigned"})

      # 213 bytes of status against a real prompt, and NEWER. This is the exact
      # substitution the `"kind" => "engagement"` filter exists to refuse.
      {:ok, _} =
        ExecutionSpace.post_log(
          space.id,
          "Dispatch suppressed: plan is awaiting human review | Task: #{task.title}"
        )

      latest = ExecutionSpace.latest_engagement(space.id)

      assert latest.content == prompt
      assert latest.metadata["kind"] == "engagement"
      refute latest.log_only
    end

    test "an engagement-kind message from another source does not displace it", %{task: task} do
      description = identifying_text(task)
      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      prompt = "Dispatch prompt for #{task.title}.\n\nDescription: #{description}"

      {:ok, _} =
        ExecutionSpace.post_engagement(space.id, prompt, metadata: %{"reason" => "task_assigned"})

      # `"kind" => "engagement"` under a DIFFERENT source, posted later. The
      # filter is an AND for this case: execution spaces carry human and agent
      # traffic too, and a guard handed one of those rows would compare a reply
      # against a prompt and call every repeat legitimate.
      {:ok, participant} = ExecutionSpace.ensure_system_participant(space.id)

      {:ok, _} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: participant.id,
          content_type: "text",
          content: "Acknowledged, starting work.",
          log_only: false,
          metadata: %{"kind" => "engagement", "source" => "agent_reply"}
        })

      latest = ExecutionSpace.latest_engagement(space.id)

      assert latest.content == prompt
      assert latest.metadata["source"] == "task_router"
    end

    test "with two engagements it returns the SECOND, byte-for-byte", %{task: task} do
      description = identifying_text(task)
      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      first = "First dispatch for #{task.title}.\n\nDescription: #{description}"
      second = "Second dispatch for #{task.title}.\n\nDescription: #{description}"

      # Distinct prefixes over a SHARED identifying body. Two prompts that
      # differ only in a prefix is what a genuine repeat looks like; comparing
      # against two wholly unrelated strings would pass on an implementation
      # that returned whichever row it liked.
      refute first == second

      {:ok, _} =
        ExecutionSpace.post_engagement(space.id, first, metadata: %{"reason" => "task_assigned"})

      {:ok, _} =
        ExecutionSpace.post_engagement(space.id, second, metadata: %{"reason" => "task_assigned"})

      latest = ExecutionSpace.latest_engagement(space.id)

      assert latest.content == second
      refute latest.content == first
      assert latest.content =~ description
    end
  end

  # ── The stamp ──────────────────────────────────────────────────────────────

  describe "a real router dispatch stamps who it was addressed to" do
    test "dispatch_runtime_id is the runtime the attention broadcast went to, and " <>
           "delivered_online is true when that runtime was tracked first",
         %{task: task} do
      description = identifying_text(task)
      %{assignee: assignee} = federated_agent()

      RuntimePresence.track(assignee.id)
      on_exit(fn -> RuntimePresence.untrack(assignee.id) end)

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # The broadcast is the ground truth for "who it was addressed to": this
      # process is subscribed to ONE runtime topic, so receiving it at all is
      # what makes the metadata assertion below a comparison and not a
      # restatement of the fixture.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000

      space = ExecutionSpace.find_by_task_id(task.id)
      assert space, "the router must have created an execution space"

      engagement = await_engagement(space.id)

      assert engagement.metadata["dispatch_runtime_id"] == assignee.id
      assert engagement.metadata["delivered_online"] == true
      assert engagement.metadata["reason"] == "task_assigned"

      # The row carries the PROMPT, not a status line. Without this the two
      # metadata assertions above would hold just as well on a 213-byte log.
      assert engagement.content =~ description
    end

    test "delivered_online is false when the runtime was never tracked", %{task: task} do
      %{assignee: assignee} = federated_agent()

      # No `RuntimePresence.track/1`. The broadcast still succeeds — a PubSub
      # publish to a topic with no subscriber is a successful no-op — which is
      # the whole reason a delivery flag has to be recorded separately from the
      # dispatch's return value.
      refute RuntimePresence.online?(assignee.id)

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000

      space = ExecutionSpace.find_by_task_id(task.id)
      assert space, "the router must have created an execution space"

      engagement = await_engagement(space.id)

      assert engagement.metadata["dispatch_runtime_id"] == assignee.id
      assert engagement.metadata["delivered_online"] == false
    end
  end
end
