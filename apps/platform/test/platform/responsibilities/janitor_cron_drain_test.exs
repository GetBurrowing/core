defmodule Platform.Responsibilities.JanitorCronDrainTest do
  @moduledoc """
  Integration of the `janitor.cron_drain` fire with normal task
  orchestration, the hand-back path, and the run's audit trail (task
  `019fa1ac-6685` stage 3).

  Every fire goes through `Router.fire_trigger/3`, the funnel the Router's
  own cron tick uses; nothing here calls the handler's callbacks directly
  except where a test is about the service function itself.

  ## Against unfixed code (stage-2 tip 2d0afc41)

  At that tip a fire claims, but routes nothing, records no audit rows, and
  there is no `Janitor.hand_back/3`, `route_claimed/2`,
  `reconcile_stranded/1` or `janitor_hand_back` tool. So every assigned,
  cap, audit, routing and hand-back test below fails there. The one
  exception is the unassigned no-op test: its assertions ("no dispatch, no
  writes") hold for any janitor that never dispatches, so it is NOT a fix
  detector. It is paired, over the same fixture builder, with the assigned
  positive control directly above it, which must dispatch and write.

  Measured on moon, this file run on 2d0afc41: 19 of its 21 tests fail.
  The two that pass are the unassigned no-op (above) and the reachability
  test, whose provider stage 1 already shipped.

  ## Mutation probes (measured on moon; this file plus
  ## janitor_registration_test, janitor_policy_test, provider_coverage_test)

    * `auto_approve_plan: false` dropped from the hand-back write: 10
      failures, all hand-back tests in this file.
    * the handler routes one extra eligible task beyond the claimed batch:
      4 failures (the assigned positive control and the cap test here, two
      stage-2 policy tests).
    * `providers/janitor.ex` deleted: 23 failures. It still COMPILES — the
      registry holds the module only as an atom — so the failures are
      behavioural: the Router falls back to its generic context and nothing
      is claimed, and the reachability tests here and in
      `provider_coverage_test.exs` fail on the load.

  ## "Unchanged" is the whole row

  As in `janitor_policy_test.exs`: `row_to_json` over the `tasks` row read
  straight from Postgres, compared as text, so a column the schema does not
  declare is covered too.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Audit.Event
  alias Platform.Chat.Message
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.ArchitectureCronSweep
  alias Platform.Responsibilities.Handlers.JanitorCronDrain
  alias Platform.Responsibilities.Janitor
  alias Platform.Responsibilities.Providers
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Seeds
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  @key "janitor.cron_drain"
  @pid_key :janitor_cron_drain_test_pid
  @fail_key :janitor_cron_drain_test_fail

  @safe_description "Rename the private helper format_line/1 in lib/platform/chat/formatter.ex " <>
                      "to render_line/1 so the name matches what it returns."

  defmodule CapturingNativeDispatcher do
    @moduledoc false
    # Forwards each native hand-off to the test process; returns an error
    # instead when the test asks for a failed dispatch.
    def maybe_dispatch(signal) do
      case Application.get_env(:platform, :janitor_cron_drain_test_pid) do
        pid when is_pid(pid) -> send(pid, {:native_dispatch, signal})
        _ -> :ok
      end

      case Application.get_env(:platform, :janitor_cron_drain_test_fail) do
        nil -> :ok
        reason -> {:error, reason}
      end
    end
  end

  setup do
    previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {CapturingNativeDispatcher, :maybe_dispatch}
    )

    Application.put_env(:platform, @pid_key, self())

    on_exit(fn ->
      Application.delete_env(:platform, @pid_key)
      Application.delete_env(:platform, @fail_key)

      if previous do
        Application.put_env(:platform, :responsibility_router_native_dispatcher, previous)
      else
        Application.delete_env(:platform, :responsibility_router_native_dispatcher)
      end
    end)

    :ok = Seeds.seed_defaults(only_keys: ["janitor"])
    [spec] = JanitorCronDrain.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)

    {:ok, project} =
      Tasks.create_project(%{name: "Janitor drain #{System.unique_integer([:positive])}"})

    %{row: row, project: project}
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp native_agent! do
    %Agent{}
    |> Agent.changeset(%{
      slug: "janitor-drain-#{System.unique_integer([:positive])}",
      name: "Janitor Drain Agent",
      status: "active",
      kind: "native",
      workspace_id: nil
    })
    |> Repo.insert!()
  end

  defp assign_janitor! do
    agent = native_agent!()
    {:ok, _} = Roles.assign_role("janitor", agent.id)
    agent
  end

  defp chore!(project, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            title: "Tidy #{System.unique_integer([:positive])}",
            description: @safe_description,
            kind: "chore"
          },
          attrs
        )
      )

    task
  end

  defp architect_chore!(project, attrs \\ %{}) do
    chore!(
      project,
      Map.put(attrs, :metadata, %{"filed_by" => "architect_cron_sweep", "adr" => "0044"})
    )
  end

  # The OLDEST architect chore is dangerous, so the run meets and refuses it
  # first (a refusal does not count toward the cap); then four safe
  # architect chores, one ordinary chore, one bug.
  defp mixed_backlog!(project) do
    dangerous =
      architect_chore!(project, %{
        title: "Drop the stale column",
        description: "Write a migration in priv/repo/migrations that drops tasks.legacy_ref."
      })

    %{
      dangerous: dangerous,
      architect: for(_ <- 1..4, do: architect_chore!(project)),
      ordinary: chore!(project),
      bug: chore!(project, %{kind: "bug"})
    }
  end

  defp row_json(id) do
    {:ok, uuid} = Ecto.UUID.dump(id)

    %{rows: [[json]]} =
      Repo.query!("SELECT row_to_json(t)::text FROM tasks t WHERE t.id = $1", [uuid])

    json
  end

  defp all_rows_json do
    %{rows: rows} =
      Repo.query!("SELECT row_to_json(t)::text FROM tasks t ORDER BY t.id")

    rows
  end

  defp reload(id), do: Repo.get!(TaskSchema, id)

  defp fire!(row) do
    capture_log([level: :info], fn ->
      send(self(), {:fire_result, Router.fire_trigger(row, %{kind: :cron}, %{})})
    end)

    assert_received {:fire_result, result}
    result
  end

  defp dispatched_signal! do
    assert_received {:native_dispatch, signal}
    refute_received {:native_dispatch, _}
    signal
  end

  defp janitor_audit(task_id) do
    Repo.all(
      from(e in Event,
        where: e.resource_type == "task" and e.resource_id == ^task_id,
        where: like(e.event_type, "platform.janitor.%"),
        order_by: [asc: e.inserted_at]
      )
    )
  end

  defp janitor_audit_count do
    Repo.aggregate(from(e in Event, where: like(e.event_type, "platform.janitor.%")), :count)
  end

  defp janitor_log_lines(task_id) do
    case ExecutionSpace.find_by_task_id(task_id) do
      nil ->
        []

      space ->
        Repo.all(
          from(m in Message,
            where: m.space_id == ^space.id,
            where: fragment("?->>'source' = 'janitor'", m.metadata),
            order_by: [asc: m.inserted_at]
          )
        )
    end
  end

  defp claimed_and_routed!(row, project) do
    agent = assign_janitor!()
    task = architect_chore!(project)
    assert {:ok, :dispatched} = fire!(row)
    _ = dispatched_signal!()
    routed = reload(task.id)
    assert routed.status == "planning"
    {agent, routed}
  end

  # ── assignment gating (paired) ───────────────────────────────────────────

  describe "assignment gating" do
    # POSITIVE CONTROL for the unassigned test below. Fails on the stage-2
    # tip: the claim happens there but nothing moves into planning.
    test "an assigned fire dispatches once and moves ONLY the claimed tasks into planning",
         %{row: row, project: project} do
      agent = assign_janitor!()
      backlog = mixed_backlog!(project)
      [a1, a2, a3, a4] = backlog.architect

      untouched = [a4, backlog.ordinary, backlog.bug]
      before = Map.new(untouched, &{&1.id, row_json(&1.id)})

      assert {:ok, :dispatched} = fire!(row)
      signal = dispatched_signal!()

      claimed_ids = Enum.map([a1, a2, a3], & &1.id)

      for id <- claimed_ids do
        task = reload(id)
        assert task.status == "planning", "claimed #{id} was not routed into planning"
        assert task.auto_approve_plan == true
        assert task.metadata["janitor_disposition"] == "claimed"
        assert task.metadata["janitor_agent_id"] == agent.id
        assert task.metadata["filed_by"] == "architect_cron_sweep"
        assert get_in(task.phase_assignees, ["planning", "assignee_id"]) == agent.id
        assert get_in(task.phase_assignees, ["execution", "assignee_id"]) == agent.id
        # The planning-phase flat pointer is the janitor, which is what the
        # TaskRouter dispatches planning to.
        assert task.assignee_id == agent.id
      end

      # Refused, not routed: stays backlog, no auto-approval.
      dangerous = reload(backlog.dangerous.id)
      assert dangerous.status == "backlog"
      assert dangerous.auto_approve_plan == false
      assert dangerous.metadata["janitor_disposition"] == "refused"
      assert dangerous.metadata["janitor_reason"] == "database_migration"

      for task <- untouched do
        assert row_json(task.id) == before[task.id],
               "#{task.title} is outside the claimed batch and must be byte-for-byte unchanged"
      end

      # The prompt names exactly the routed ids, nothing else.
      prompt = signal.metadata.prompt
      assert String.contains?(prompt, JanitorCronDrain.system_prompt())
      for id <- claimed_ids, do: assert(prompt =~ id)

      for task <- [a4, backlog.ordinary, backlog.bug, backlog.dangerous] do
        refute prompt =~ task.id, "#{task.title} reached the prompt but was not claimed"
      end
    end

    # NOT A FIX DETECTOR ON ITS OWN: holds for a janitor that never
    # dispatches. Meaningful only beside the positive control above, over
    # the same fixture builder.
    test "an unassigned fire is a no-op: zero dispatches, zero task writes, zero audit rows",
         %{row: row, project: project} do
      _backlog = mixed_backlog!(project)
      assert Roles.assignee_for(@key) == nil

      rows_before = all_rows_json()
      audit_before = janitor_audit_count()

      assert {:ok, :unfilled} = fire!(row)

      refute_received {:native_dispatch, _}
      assert all_rows_json() == rows_before
      assert janitor_audit_count() == audit_before
    end
  end

  # ── the cap ──────────────────────────────────────────────────────────────

  describe "the per-run cap" do
    test "with five eligible chores exactly three are routed and two stay byte-identical",
         %{row: row, project: project} do
      _agent = assign_janitor!()
      chores = for _ <- 1..5, do: architect_chore!(project)
      {first_three, last_two} = Enum.split(chores, 3)
      before = Map.new(last_two, &{&1.id, row_json(&1.id)})

      assert {:ok, :dispatched} = fire!(row)
      signal = dispatched_signal!()

      assert Enum.map(first_three, &reload(&1.id).status) == ~w(planning planning planning)

      for task <- last_two do
        assert row_json(task.id) == before[task.id]
      end

      ids_in_prompt = Regex.scan(~r/^- ([0-9a-f-]{36}):/m, signal.metadata.prompt)

      assert Enum.sort(Enum.map(ids_in_prompt, &List.last/1)) ==
               Enum.sort(Enum.map(first_three, & &1.id))

      first_rows = Map.new(first_three, &{&1.id, row_json(&1.id)})

      # The second fire takes the remaining two and never re-takes the first three.
      assert {:ok, :dispatched} = fire!(row)
      _ = dispatched_signal!()

      assert Enum.map(last_two, &reload(&1.id).status) == ~w(planning planning)

      for task <- first_three do
        assert row_json(task.id) == first_rows[task.id]
      end
    end
  end

  # ── audit ────────────────────────────────────────────────────────────────

  describe "run attribution" do
    test "claimed and refused outcomes land in audit_events and the routed task's execution space",
         %{row: row, project: project} do
      agent = assign_janitor!()
      claimed = architect_chore!(project)

      refused =
        chore!(project, %{
          title: "Rotate the signing key",
          description: "Move the session signing secret into lib/platform/vault.ex helpers."
        })

      assert {:ok, :dispatched} = fire!(row)
      _ = dispatched_signal!()

      run_id = reload(claimed.id).metadata["janitor_run_id"]
      assert is_binary(run_id)

      assert [claim_event] = janitor_audit(claimed.id)
      assert claim_event.event_type == "platform.janitor.claimed"
      assert claim_event.action == "claimed"
      assert claim_event.actor_type == "agent"
      assert claim_event.actor_id == agent.id
      assert claim_event.metadata["run_id"] == run_id
      assert claim_event.metadata["handled_by"] == "janitor"

      assert [refuse_event] = janitor_audit(refused.id)
      assert refuse_event.event_type == "platform.janitor.refused"
      assert refuse_event.metadata["reason"] == "vault"
      assert refuse_event.metadata["run_id"] == run_id

      assert [line] = janitor_log_lines(claimed.id)
      assert line.log_only == true
      assert line.content =~ run_id
      assert line.metadata["janitor_disposition"] == "claimed"

      # A refusal does not conjure an execution space for a task nobody runs.
      assert ExecutionSpace.find_by_task_id(refused.id) == nil
    end
  end

  # ── hand-back ────────────────────────────────────────────────────────────

  describe "hand-back" do
    test "a claimed chore hands back atomically: backlog, no auto-approval, no janitor slots, metadata kept",
         %{row: row, project: project} do
      {agent, routed} = claimed_and_routed!(row, project)
      claim_metadata = routed.metadata
      now = ~U[2026-10-12 06:30:00.000000Z]

      assert {:ok, back} =
               Janitor.hand_back(routed.id, "not_small",
                 agent_id: agent.id,
                 detail: "touches eleven modules",
                 now: now
               )

      task = reload(back.id)
      assert task.status == "backlog"
      assert task.auto_approve_plan == false
      assert task.phase_assignees["planning"] in [nil, %{}]
      assert task.phase_assignees["execution"] in [nil, %{}]
      assert task.assignee_id == nil

      # Every prior key survives, the claim's own stamps included.
      for {key, value} <- claim_metadata, key != "janitor_disposition" do
        assert task.metadata[key] == value, "metadata #{inspect(key)} was not preserved"
      end

      assert task.metadata["filed_by"] == "architect_cron_sweep"
      assert task.metadata["handled_by"] == "janitor"
      assert task.metadata["janitor_disposition"] == "handed_back"
      assert task.metadata["janitor_reason"] == "not_small"
      assert task.metadata["janitor_reason_detail"] == "touches eleven modules"
      assert task.metadata["janitor_handed_back_at"] == DateTime.to_iso8601(now)

      assert [_claimed, handed] = janitor_audit(task.id)
      assert handed.event_type == "platform.janitor.handed_back"
      assert handed.actor_id == agent.id
      assert handed.metadata["reason"] == "not_small"

      assert Enum.any?(
               janitor_log_lines(task.id),
               &(&1.metadata["janitor_disposition"] == "handed_back")
             )

      # A handed-back task is never re-claimed by a later run.
      assert {:ok, :dispatched} = fire!(row)
      _ = dispatched_signal!()
      assert reload(task.id).metadata["janitor_disposition"] == "handed_back"
    end

    test "a hand-back from in_progress walks through blocked and lands in backlog",
         %{row: row, project: project} do
      {agent, routed} = claimed_and_routed!(row, project)

      # Simulate the auto-approved plan having started execution.
      routed |> Ecto.Changeset.change(status: "in_progress") |> Repo.update!()

      assert {:ok, _} = Janitor.hand_back(routed.id, "not_small", agent_id: agent.id)

      task = reload(routed.id)
      assert task.status == "backlog"
      assert task.auto_approve_plan == false
    end

    test "a step that fails mid-hand-back rolls the whole hand-back back",
         %{row: row, project: project} do
      {agent, routed} = claimed_and_routed!(row, project)

      # Plant a phase key the changeset rejects. The status walk succeeds;
      # releasing the janitor's slots then fails validation.
      {:ok, uuid} = Ecto.UUID.dump(routed.id)

      Repo.query!(
        "UPDATE tasks SET phase_assignees = phase_assignees || '{\"bogus\": {}}'::jsonb WHERE id = $1",
        [uuid]
      )

      before = row_json(routed.id)

      assert {:error, %Ecto.Changeset{}} =
               Janitor.hand_back(routed.id, "not_small", agent_id: agent.id)

      assert row_json(routed.id) == before
      task = reload(routed.id)
      assert task.status == "planning"
      assert task.auto_approve_plan == true
    end

    test "only a janitor claim can be handed back, and only by its holder",
         %{row: row, project: project} do
      {_agent, routed} = claimed_and_routed!(row, project)
      stranger = native_agent!()
      unclaimed = chore!(project)

      before_claimed = row_json(routed.id)
      before_unclaimed = row_json(unclaimed.id)

      assert {:error, :not_claim_holder} =
               Janitor.hand_back(routed.id, "not_small", agent_id: stranger.id)

      assert {:error, {:not_janitor_claimed, nil}} = Janitor.hand_back(unclaimed.id, "not_small")
      assert {:error, :invalid_reason} = Janitor.hand_back(routed.id, "because")
      # A malformed id (an MCP argument) is refused before any lookup.
      assert {:error, :invalid_task_id} = Janitor.hand_back("not-a-uuid", "not_small")

      assert row_json(routed.id) == before_claimed
      assert row_json(unclaimed.id) == before_unclaimed
    end
  end

  describe "forbidden-scope discovery" do
    for {path, code} <- [
          {"apps/platform/priv/repo/migrations/20261012000000_add_x.exs", "database_migration"},
          {"apps/platform/lib/platform/vault.ex", "vault"},
          {"apps/platform/config/runtime.exs", "deploy_runtime_config"},
          {"apps/platform/lib/platform/accounts/user.ex", "auth_or_secrets"},
          {"apps/platform/lib/platform/tenancy/scope.ex", "tenancy_boundary"}
        ] do
      @path path
      @code code

      test "finding #{code} scope forces the hand-back and records #{code}",
           %{row: row, project: project} do
        {agent, routed} = claimed_and_routed!(row, project)

        assert {:ok, _} =
                 Janitor.hand_back(routed.id, "not_small",
                   agent_id: agent.id,
                   paths: ["apps/platform/lib/platform/chat/formatter.ex", @path]
                 )

        task = reload(routed.id)
        assert task.status == "backlog"
        assert task.auto_approve_plan == false
        assert task.metadata["janitor_reason"] == @code
        assert task.metadata["janitor_reason_detail"] =~ "reported as not_small"
      end
    end

    test "the janitor_hand_back tool forces the same category and names the caller",
         %{row: row, project: project} do
      {agent, routed} = claimed_and_routed!(row, project)

      assert {:ok, result} =
               ToolSurface.execute(
                 "janitor_hand_back",
                 %{
                   "task_id" => routed.id,
                   "reason" => "not_small",
                   "detail" => "needs a schema change",
                   "paths" => ["apps/platform/priv/repo/migrations/x.exs"]
                 },
                 %{agent_id: agent.id}
               )

      assert result.status == "backlog"
      assert result.auto_approve_plan == false
      assert result.janitor_reason == "database_migration"

      assert [_claimed, handed] = janitor_audit(routed.id)
      assert handed.actor_id == agent.id

      assert {:error, %{code: :not_janitor_claimed}} =
               ToolSurface.execute(
                 "janitor_hand_back",
                 %{"task_id" => routed.id, "reason" => "not_small"},
                 %{agent_id: agent.id}
               )
    end

    test "janitor_hand_back is a task-bundle tool" do
      assert %{bundle: "task"} =
               Enum.find(ToolSurface.tool_definitions(), &(&1.name == "janitor_hand_back"))
    end
  end

  # ── nothing strands ──────────────────────────────────────────────────────

  describe "claims cannot strand" do
    test "a failed dispatch leaves the claimed tasks under the TaskRouter, not stranded in backlog",
         %{row: row, project: project} do
      agent = assign_janitor!()
      task = architect_chore!(project)
      Application.put_env(:platform, @fail_key, :runtime_offline)

      assert {:error, _} = fire!(row)

      routed = reload(task.id)
      assert routed.status == "planning"
      assert routed.auto_approve_plan == true
      assert get_in(routed.phase_assignees, ["planning", "assignee_id"]) == agent.id
    end

    test "a claim a dead run left in backlog is handed back as claim_not_routed on the next fire",
         %{row: row, project: project} do
      agent = assign_janitor!()
      task = architect_chore!(project)

      # The claim commits but the run dies before routing it.
      two_hours_ago = DateTime.add(DateTime.utc_now(), -7200, :second)

      {{:ok, %{claimed: [claimed]}}, _log} =
        with_log(fn -> Janitor.claim(agent_id: agent.id, now: two_hours_ago) end)

      assert claimed.status == "backlog" and claimed.auto_approve_plan == true

      assert {:ok, :dispatched} = fire!(row)
      signal = dispatched_signal!()

      back = reload(task.id)
      assert back.status == "backlog"
      assert back.auto_approve_plan == false
      assert back.metadata["janitor_disposition"] == "handed_back"
      assert back.metadata["janitor_reason"] == "claim_not_routed"
      refute signal.metadata.prompt =~ task.id
    end

    test "a claim committed moments ago is NOT reconciled by an overlapping run",
         %{project: project} do
      agent = assign_janitor!()
      task = architect_chore!(project)

      {{:ok, %{claimed: [_]}}, _log} = with_log(fn -> Janitor.claim(agent_id: agent.id) end)
      before = row_json(task.id)

      assert Janitor.reconcile_stranded() == []
      assert row_json(task.id) == before
    end

    test "a stack member is handed back instead of being routed around its stack",
         %{project: project} do
      agent = assign_janitor!()
      _task = architect_chore!(project)
      fake_stack = Ecto.UUID.generate()

      {{:ok, %{claimed: [claimed]}}, _} = with_log(fn -> Janitor.claim(agent_id: agent.id) end)
      as_member = %{claimed | stack_id: fake_stack}

      assert %{routed: [], handed_back: [{back, "stack_member"}]} =
               Janitor.route_claimed([as_member], agent_id: agent.id)

      assert back.status == "backlog"
      assert back.auto_approve_plan == false
    end
  end

  # ── the architect sweep feeds the janitor ────────────────────────────────

  describe "end to end from the architect sweep" do
    test "follow-ups the sweep files are claimed and routed by the next janitor fire",
         %{row: row, project: project} do
      _agent = assign_janitor!()

      output = %{
        "followups" =>
          for n <- 1..3 do
            %{
              "title" => "Inline the single-use helper #{n}",
              "rationale" =>
                "lib/platform/chat/formatter.ex keeps a one-caller private helper #{n}; " <>
                  "inline it so the call site reads straight through.",
              "refs" => ["lib/platform/chat/formatter.ex"]
            }
          end
      }

      capture_log(fn ->
        assert :ok =
                 ArchitectureCronSweep.handle_output(
                   %Responsibilities.Responsibility{key: "architecture.cron_sweep"},
                   output,
                   %{kind: :cron, project_id: project.id}
                 )
      end)

      filed =
        Repo.all(
          from(t in TaskSchema,
            where: t.project_id == ^project.id,
            where: fragment("?->>'filed_by' = 'architect_cron_sweep'", t.metadata)
          )
        )

      assert length(filed) == 3

      assert {:ok, :dispatched} = fire!(row)
      _ = dispatched_signal!()

      for task <- filed do
        routed = reload(task.id)
        assert routed.kind == "chore"
        assert routed.status == "planning", "sweep follow-up #{task.title} was not drained"
        assert routed.metadata["janitor_disposition"] == "claimed"
      end
    end
  end

  # ── reachability ─────────────────────────────────────────────────────────

  describe "reachability through Providers.Janitor" do
    # Extends the task-019f9b28 walk (`provider_coverage_test.exs`) for this
    # key: the Router must resolve `janitor` to a LOADED provider that
    # routes `gather_context/2` to the handler. Delete `providers/janitor.ex`
    # and the registry still names the atom, so `feature_provider/1` keeps
    # answering `{:ok, _}`; this test then fails on the load, and every
    # assigned-fire test above fails on behaviour (the Router falls back to
    # its generic context and nothing is claimed).
    test "the registered janitor provider loads and routes the key to the handler",
         %{row: row} do
      assert {:ok, provider} = Providers.feature_provider(row.feature)

      assert Code.ensure_loaded?(provider),
             "Providers.feature_provider(#{inspect(row.feature)}) names #{inspect(provider)}, " <>
               "which does not load: janitor.cron_drain has no reachable provider"

      assert function_exported?(provider, :gather_context, 2)
      assert function_exported?(provider, :build_prompt, 1)
      assert provider.handler_for(@key) == JanitorCronDrain
    end
  end
end
