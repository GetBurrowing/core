defmodule Platform.Orchestration.TaskRouterBootReengagementTest do
  @moduledoc """
  Task 01a03ed3 stage 3 — a restarted router must not re-send a planning
  prompt it already delivered.

  ## Why the assertions are PAIRED in one test body

  A test asserting that a restart dispatches passes today and passes against
  every version of this defect, because dispatching is what it does. And a test
  that only asserts silence cannot tell a working suppressor from a dead
  dispatcher — an implementation that never dispatched anything at all would be
  green. So the single test below asserts, in order:

    1. the first boot dispatches (baseline, and the thing being repeated),
    2. an identical restart does NOT (the fix),
    3. a restart after a REAL state change DOES (the control that keeps 2
       honest).

  Splitting 2 and 3 into separate tests would let a change that broke
  dispatching outright pass 2 while stranding every task on the platform, since
  nothing would force both facts to hold of the same code in the same run.

  ## Why row counts, not `refute_received`

  `refute_received` reads this process's mailbox at one instant. The engagement
  is written after `dispatch_attention/5` returns, so a second dispatch can be
  in flight while the mailbox is momentarily empty. Engagement ROWS in the
  execution space are the durable, non-racy count, and the broadcast refute is
  layered on top of a settle window rather than used alone.

  ## Why not an assertion on the log line's TEXT via capture_log

  `config :logger, level: :warning` in the test env drops `Logger.info` before
  any capture handler sees it, so an assertion on the suppression log line
  would be silently vacuous. The evidence assertion below reads the persisted
  `post_log/2` message ROW instead.

  ## `async: false`

  The router is a real GenServer reading `Repo` from its own process, so the
  sandbox must be in shared mode. `RuntimePresence` is a named application-level
  Agent the sandbox does not roll back, hence the explicit `untrack/1`.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.Message
  alias Platform.Federation.RuntimePresence
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  @description_marker "Boot re-engagement probe: an identical restart must not re-prompt."

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
        status: "planning",
        deploy_target: "production"
      })

    # The guard's conjunct (b) is `task.status == "planning" and is_nil(stage)`,
    # so a fixture left at the `backlog` default would exercise nothing — the
    # first restart would dispatch and this file would be asserting the
    # pre-fix behaviour. Read the status back rather than trusting the write.
    assert Repo.get!(Platform.Tasks.Task, task.id).status == "planning"

    on_exit(fn ->
      stop_router(task.id)

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{project: project, task: task}
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  # ANTI-VACUITY GATE. Content assertions compare against the value actually
  # persisted on the task row, never against `@description_marker`. A fixture
  # that dropped the description would otherwise make `content =~ ""` pass.
  defp identifying_text(task_id) do
    description = Repo.get!(Platform.Tasks.Task, task_id).description

    refute is_nil(description),
           "fixture task #{task_id} persisted no description — every content " <>
             "assertion in this file would be vacuous"

    refute String.trim(description) == "",
           "fixture task #{task_id} persisted a blank description — every " <>
             "content assertion in this file would be vacuous"

    description
  end

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

  # The restart path exactly as production runs it: a NEW process running the
  # real `init/1`, whose unguarded tail `send(self(), :dispatch_boot)` is the
  # thing under test. Nothing here is mocked.
  defp start_router(task_id, assignee) do
    {:ok, pid} = TaskRouter.start_link(task_id: task_id, assignee: assignee)
    pid
  end

  defp stop_router(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end

  defp engagements(space_id) do
    from(m in Message,
      where: m.space_id == ^space_id and is_nil(m.deleted_at),
      where: fragment("?->>'kind' = ?", m.metadata, "engagement"),
      where: fragment("?->>'source' = ?", m.metadata, "task_router"),
      order_by: [asc: m.inserted_at, asc: m.id]
    )
    |> Repo.all()
  end

  defp logs(space_id) do
    from(m in Message,
      where: m.space_id == ^space_id and is_nil(m.deleted_at),
      where: fragment("?->>'kind' = ?", m.metadata, "log"),
      order_by: [asc: m.inserted_at, asc: m.id]
    )
    |> Repo.all()
  end

  # Rewrites metadata on a persisted engagement row, leaving CONTENT untouched
  # so a single conjunct is varied at a time. Two conjuncts moved together
  # would absorb each other and neither probe would prove anything.
  defp restamp(row, metadata_overrides) do
    message = Repo.get!(Message, row.id)

    message
    |> Ecto.Changeset.change(%{metadata: Map.merge(message.metadata, metadata_overrides)})
    |> Repo.update!()
  end

  # `restamp/2` MERGES, and merging cannot express absence: `Map.merge/2` has
  # no way to remove a key, and a key present with a `nil` value is a
  # different input from a key that is not there at all (only the latter fires
  # a `Map.get/3` default). Deleting is therefore its own helper rather than a
  # flag on `restamp/2`, so the two shapes can never be confused at a call
  # site.
  defp unstamp(row, keys) do
    message = Repo.get!(Message, row.id)

    message
    |> Ecto.Changeset.change(%{metadata: Map.drop(message.metadata, keys)})
    |> Repo.update!()
  end

  defp drain_attention_broadcasts do
    receive do
      %Phoenix.Socket.Broadcast{event: "attention"} -> drain_attention_broadcasts()
    after
      0 -> :ok
    end
  end

  defp await_engagement_count(space_id, n, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_engagement_count(space_id, n, deadline)
  end

  defp do_await_engagement_count(space_id, n, deadline) do
    rows = engagements(space_id)

    cond do
      length(rows) >= n ->
        rows

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "expected at least #{n} engagement(s) in space #{space_id}, saw #{length(rows)} " <>
            "before the deadline"
        )

      true ->
        Process.sleep(25)
        do_await_engagement_count(space_id, n, deadline)
    end
  end

  # ── The pair ───────────────────────────────────────────────────────────────

  describe "a rebooted router and an unchanged planning prompt" do
    test "an identical restart is withheld, and a restart after a real change dispatches",
         %{task: task} do
      description = identifying_text(task.id)
      %{assignee: assignee} = federated_agent()

      RuntimePresence.track(assignee.id)
      on_exit(fn -> RuntimePresence.untrack(assignee.id) end)

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      # ── 1. First boot: the dispatch that will be repeated ────────────────
      start_router(task.id, assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 5_000

      space = ExecutionSpace.find_by_task_id(task.id)
      assert space, "the router must have created an execution space"

      [first] = await_engagement_count(space.id, 1)

      # The row must carry the PROMPT. Without this the count assertions below
      # would hold just as well over 213-byte status lines.
      assert first.content =~ description
      assert first.metadata["dispatch_runtime_id"] == assignee.id
      assert first.metadata["delivered_online"] == true

      log_count_after_first = length(logs(space.id))

      # ── 2. Identical restart: nothing at all has changed ─────────────────
      stop_router(task.id)
      # Drop the first boot's broadcast so what we refute below can only be a
      # SECOND one.
      receive do
        %Phoenix.Socket.Broadcast{event: "attention"} -> :ok
      after
        0 -> :ok
      end

      start_router(task.id, assignee)

      # Settle window sized to the same order as the 5s the positive dispatch
      # above needed, so "no broadcast" is a real absence and not an early read.
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 3_000

      # THE DURABLE ASSERTION. Row count, not the mailbox.
      assert [^first] = engagements(space.id),
             "a restart with nothing changed re-sent the planning prompt"

      # ── The suppression evidence ─────────────────────────────────────────
      #
      # `log_only == true` is what shows the fix suppressed the ENGAGEMENT and
      # not the whole heartbeat: the router still narrated itself into the
      # execution space, it just declined to wake the agent.
      new_logs = Enum.drop(logs(space.id), log_count_after_first)

      suppression =
        Enum.find(new_logs, fn m ->
          m.content =~ "Dispatch withheld" and m.content =~ task.title
        end)

      assert suppression,
             "no suppression evidence line naming #{inspect(task.title)} was posted; " <>
               "new log rows were #{inspect(Enum.map(new_logs, & &1.content))}"

      assert suppression.log_only == true
      assert suppression.content =~ "unchanged"

      # Exactly ONE line, not one per restart-ish code path.
      assert Enum.count(new_logs, &(&1.content =~ "Dispatch withheld")) == 1

      # ── 3. POSITIVE CONTROL: a real change re-engages ────────────────────
      #
      # The guard is a comparison against what was last delivered, and the
      # prompt is re-rendered from live state on every dispatch — so editing
      # the task body is the change this mechanism is supposed to notice. It
      # also keeps the task in `planning` with no resolved stage, i.e. inside
      # the guard's own conjunction, which is where a broken guard would be
      # able to hide. Restarting after a change that moved the task OUT of
      # `planning` would exit the guard on conjunct (b) and prove less.
      stop_router(task.id)

      changed_marker = "Scope revised after review: the plan must cover rollback."

      {:ok, _} =
        task
        |> Repo.reload!()
        |> Ecto.Changeset.change(%{description: changed_marker})
        |> Repo.update()

      refute identifying_text(task.id) == description

      start_router(task.id, assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 5_000

      [^first, second] = await_engagement_count(space.id, 2)

      refute second.content == first.content
      assert second.content =~ changed_marker
      assert second.metadata["dispatch_runtime_id"] == assignee.id
    end
  end

  # ── One case per conjunct ──────────────────────────────────────────────────
  #
  # The paired test above proves the guard as a whole does something. It says
  # nothing about whether each of the five conjuncts is load-bearing, and an
  # ANDed guard has two distinct silent failures needing different detectors:
  # a conjunct stuck FALSE disables suppression (the paired test's silence
  # assertion catches that), while a conjunct stuck TRUE makes the guard MORE
  # aggressive than designed — the direction that strands work at a gate, and
  # the one nothing in the happy path can see. Each test below is the
  # stuck-true detector for one conjunct.

  describe "each conjunct is load-bearing" do
    # (a) boot-dispatch only. An event-driven `:dispatch` means something
    # actually asked for a prompt; suppressing it would swallow every
    # reconnect re-dispatch and heartbeat.
    test "an event-driven dispatch is never withheld, even with everything else identical",
         %{task: task} do
      %{assignee: assignee} = federated_agent()
      RuntimePresence.track(assignee.id)
      on_exit(fn -> RuntimePresence.untrack(assignee.id) end)

      pid = start_router(task.id, assignee)
      space = ExecutionSpace.find_by_task_id(task.id)
      [_first] = await_engagement_count(space.id, 1)

      # Same process, same state, nothing changed — only the provenance of the
      # dispatch differs.
      send(pid, :dispatch)

      assert [_, _] = await_engagement_count(space.id, 2)
    end

    # (b) planning + nil stage. This keeps the guard the smallest thing that
    # covers the incident; outside it, suppressing would delete the
    # `:check_no_ack` timer that is the only thing able to surface a wrong
    # suppression. `backlog` is byte-stable across boots for the same reason
    # `planning` is, so this isolates the status conjunct rather than also
    # changing the prompt.
    test "a task that is not in planning re-engages on restart", %{task: task} do
      {:ok, task} =
        task |> Ecto.Changeset.change(%{status: "backlog"}) |> Repo.update()

      assert Repo.get!(Platform.Tasks.Task, task.id).status == "backlog"

      %{assignee: assignee} = federated_agent()
      RuntimePresence.track(assignee.id)
      on_exit(fn -> RuntimePresence.untrack(assignee.id) end)

      start_router(task.id, assignee)
      space = ExecutionSpace.find_by_task_id(task.id)
      [first] = await_engagement_count(space.id, 1)

      stop_router(task.id)
      start_router(task.id, assignee)

      [^first, second] = await_engagement_count(space.id, 2)

      # ANTI-VACUITY: the two rows must be the SAME prompt, or this passed
      # because something else changed rather than because (b) was false.
      assert second.content == first.content
    end

    # (d) the stored engagement must name the runtime THIS dispatch is
    # addressed to. A phase reassignment through `refresh_assignee/2` points
    # the dispatch at a new runtime that has never received the prompt; without
    # (d) that runtime is never prompted at all.
    test "an engagement addressed to a different runtime does not suppress", %{task: task} do
      %{assignee: assignee} = federated_agent()
      RuntimePresence.track(assignee.id)
      on_exit(fn -> RuntimePresence.untrack(assignee.id) end)

      start_router(task.id, assignee)
      space = ExecutionSpace.find_by_task_id(task.id)
      [first] = await_engagement_count(space.id, 1)

      stop_router(task.id)

      # Content stays byte-identical on purpose: only conjunct (d) changes, so
      # a dispatch here can only be attributed to the runtime mismatch.
      other = "runtime-test-#{System.unique_integer([:positive])}"
      refute other == assignee.id
      restamp(first, %{"dispatch_runtime_id" => other})

      start_router(task.id, assignee)

      # Not a `^first` pin: `restamp/2` rewrote that row, so the struct captured
      # before the rewrite no longer equals what the query returns.
      [reloaded, second] = await_engagement_count(space.id, 2)
      assert reloaded.id == first.id
      assert second.content == first.content
      assert second.metadata["dispatch_runtime_id"] == assignee.id
    end

    # (e) `delivered_online` exactly `true`. `AttentionDispatch.broadcast/3`
    # returns `:ok` for a topic with no subscriber, so an engagement can be
    # recorded for a runtime that never received it. Suppressing on one of
    # those strands the task outright — nothing else would ever deliver it.
    test "an engagement recorded while the runtime was offline does not suppress", %{task: task} do
      %{assignee: assignee} = federated_agent()
      RuntimePresence.track(assignee.id)
      on_exit(fn -> RuntimePresence.untrack(assignee.id) end)

      start_router(task.id, assignee)
      space = ExecutionSpace.find_by_task_id(task.id)
      [first] = await_engagement_count(space.id, 1)
      assert first.metadata["delivered_online"] == true

      stop_router(task.id)
      restamp(first, %{"delivered_online" => false})

      start_router(task.id, assignee)

      [reloaded, second] = await_engagement_count(space.id, 2)
      assert reloaded.id == first.id
      assert second.content == first.content
      assert second.metadata["delivered_online"] == true
    end

    # (e) again, for the ABSENT key — a different input from the `=> false`
    # row above, and the one with the dangerous neighbour.
    #
    # Today `Map.get(metadata, "delivered_online")` returns `nil` for a missing
    # key and `nil == true` is false, so an engagement whose metadata never
    # recorded delivery does not suppress. The two shapes are separated by
    # exactly one plausible edit: a default for the read — `Map.get/3`'s third
    # argument, or a `Map.merge(%{"delivered_online" => true}, metadata)` on the
    # way in — leaves the `=> false` row reading false and flips the ABSENT key
    # to `true`, permitting suppression of a prompt that was never delivered.
    # The `=> false` test above stays green through that edit, so it is not a
    # detector for it. This one is.
    #
    # That direction strands the task and does it silently:
    # `AttentionDispatch.broadcast/3` returns `:ok` for a topic with no
    # subscriber and TaskRouter dispatches are not dead-lettered, so a
    # suppressed-but-undelivered prompt leaves no signal anywhere.
    #
    # The shape is not hypothetical: every engagement row written before the
    # metadata stamp was introduced has exactly this metadata.
    #
    # Phrased as BEHAVIOUR — the prompt is dispatched again — not as "an absent
    # key is handled" or "does not crash". Those phrasings are satisfied by the
    # `rescue` arm, which dispatches too, and would leave the suppression path
    # itself untested.
    test "an engagement whose metadata has no delivered_online key does not suppress",
         %{task: task} do
      description = identifying_text(task.id)
      %{assignee: assignee} = federated_agent()
      RuntimePresence.track(assignee.id)
      on_exit(fn -> RuntimePresence.untrack(assignee.id) end)

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")

      start_router(task.id, assignee)
      space = ExecutionSpace.find_by_task_id(task.id)
      [first] = await_engagement_count(space.id, 1)

      # The row must carry the PROMPT, or every `content ==` comparison below
      # holds just as well over two empty strings.
      assert first.content =~ description
      assert first.metadata["delivered_online"] == true

      stop_router(task.id)

      # Content and `dispatch_runtime_id` are left byte-identical on purpose:
      # conjuncts (c) and (d) both still hold, so a dispatch below is
      # attributable to (e) and to nothing else.
      unstamp(first, ["delivered_online"])

      # Read the ABSENCE back from the row. Without this the test would be
      # green if the delete silently no-opped — it would then be re-running the
      # `=> true` suppression case with an inverted expectation, failing for a
      # reason that says nothing about a missing key.
      stripped = Repo.get!(Message, first.id)
      refute Map.has_key?(stripped.metadata, "delivered_online")
      assert stripped.metadata["dispatch_runtime_id"] == assignee.id
      assert stripped.content == first.content

      # ── The assertion: an absent key does NOT suppress ───────────────────
      start_router(task.id, assignee)

      # Not a `^first` pin: `unstamp/2` rewrote that row.
      [reloaded, second] = await_engagement_count(space.id, 2)
      assert reloaded.id == first.id
      assert second.content == first.content
      assert second.metadata["delivered_online"] == true
      assert second.metadata["dispatch_runtime_id"] == assignee.id

      # ── POSITIVE CONTROL, and the reason this test is not vacuous ────────
      #
      # "Does not suppress" is a claim that a guard DELETED ENTIRELY also
      # satisfies, so the half above constrains nothing on its own. `second` is
      # now the latest engagement and satisfies all five conjuncts, so a third
      # restart must be WITHHELD. That half goes red if the guard is removed or
      # stuck false, which is what makes the dispatch above attributable to the
      # absent key rather than to a guard that never suppresses anything.
      stop_router(task.id)

      # Drop the two broadcasts already delivered, so what is refuted below can
      # only be a third.
      drain_attention_broadcasts()

      log_count_before = length(logs(space.id))

      start_router(task.id, assignee)

      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 3_000

      # The durable assertion. Row count, not the mailbox.
      assert [^reloaded, ^second] = engagements(space.id),
             "a restart on a fully stamped engagement re-sent the planning prompt"

      withheld =
        logs(space.id)
        |> Enum.drop(log_count_before)
        |> Enum.filter(&(&1.content =~ "Dispatch withheld"))

      assert length(withheld) == 1,
             "expected exactly one suppression evidence line, saw #{inspect(Enum.map(withheld, & &1.content))}"
    end
  end

  # ── The rescue ─────────────────────────────────────────────────────────────

  describe "the predicate fails OPEN" do
    # An untested rescue clause is indistinguishable from an unreachable one,
    # and this rescue is what stands between a bug in the predicate and every
    # task on the platform stalling at a gate. The emission matters as much as
    # the dispatch: falling open silently reproduces the pre-fix behaviour
    # exactly, so without a warning the guard could be dead from the first
    # deploy with no new symptom to notice.
    test "a raising engagement lookup dispatches anyway AND records the fail-open", %{task: task} do
      %{assignee: assignee} = federated_agent()
      RuntimePresence.track(assignee.id)
      on_exit(fn -> RuntimePresence.untrack(assignee.id) end)

      start_router(task.id, assignee)
      space = ExecutionSpace.find_by_task_id(task.id)
      [first] = await_engagement_count(space.id, 1)

      stop_router(task.id)

      Application.put_env(:platform, :execution_space_engagement_lookup, RaisingLookup)
      on_exit(fn -> Application.delete_env(:platform, :execution_space_engagement_lookup) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_router(task.id, assignee)
          # Without the rescue this restart is the suppressed one, so a second
          # engagement here can only come from the fail-open path.
          [^first, second] = await_engagement_count(space.id, 2)
          assert second.content == first.content
        end)

      assert log =~ "boot re-engagement guard failed open"
      assert log =~ task.id
    end
  end

  # A lookup that raises where the real one queries. `Logger.warning` survives
  # the test env's `level: :warning`, unlike `Logger.info`, so the assertion
  # above is a real observation rather than a vacuous one.
  defmodule RaisingLookup do
    def latest_engagement(_space_id), do: raise("engagement lookup exploded")
  end
end
