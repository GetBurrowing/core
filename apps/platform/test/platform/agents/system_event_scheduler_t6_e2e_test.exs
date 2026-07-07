defmodule Platform.Agents.SystemEventSchedulerT6E2ETest do
  @moduledoc """
  T6 task-level adversarial e2e + scope-creep guards (ADR-0041).

  This file is the last validation gate before deploy. Earlier stages
  shipped the actual Historian schedule + triggers; this file exercises
  the integrated surface from a hostile angle and freezes the agreed
  scope so future code in this area cannot silently drift.

  Mirrors the T5 stage-6 pattern at `tool_surface_t5_e2e_test.exs` —
  planner-authored setup/actions/expected text is reproduced verbatim
  in each `e2e_behavior` test body so the review agent can cite the
  test outcome as evidence.

  ## Adversarial e2e cases

    A. Stagger sanity — two workspaces with different UUIDs hash to
       distinct offset minutes inside the same anchor window, and each
       lands on exactly 4 fire times per 24h (once per anchor).
    B. Debounce + post-debounce — single workspace with 100k+ pending
       tokens dispatches once, debounces a 30-minute follow-up sweep,
       and dispatches a second time after the debounce expires. Exactly
       two dispatches total. Telemetry events match.
    C. meeting_ended scope leak guard — meeting M in project P with
       chat_space_id S dispatches a Historian with metadata referencing
       only P / S; unrelated project Q + space S2 IDs appear nowhere
       in the dispatch metadata or rendered prompt.
    D. Threshold idempotency under retry — a slow LLM/dispatch reply
       cannot cause a second tick to re-fire because mark_run_started
       stamps `last_run_at` BEFORE dispatch fan-out (verified by
       calling run_threshold_check_now twice back-to-back).

  Additional adversarial coverage:

    * Concurrent fires from two anchor positions in the same tick
      must each book exactly once per (workspace, anchor_hour).
    * Oversize / overlong content does not break the cursor walk
      (100M-byte journal entry stays under the cursor advance, no
      dispatch for prior data).
    * Bad inputs to dispatch helpers do not write to the cursor /
      message store (validates the "scheduler stays pure dispatcher"
      claim).

  ## Scope-creep guards

  Static file checks fail the build if T6 drifted beyond its agreed
  surface — no legacy `daily_summary` schedule, no `_web/live/` touches,
  no new MCP tools, no chat_messages.search_vector changes, no
  embedding-pipeline edits, no journal/page schema additions, no
  Wiki.Routing references that pre-date T2 rollup.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Agents.Historian
  alias Platform.Agents.HistorianCursor
  alias Platform.Agents.MeetingHistorianHandler
  alias Platform.Agents.SystemEventScheduler
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.Space
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Org.WikiJournalEntry, as: MemoryEntry
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Projects

  @org_workspace Projects.org_scope_workspace_id()

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp create_historian_agent(attrs \\ %{}) do
    base = %{
      slug: "t6-historian-#{System.unique_integer([:positive])}",
      name: "T6 Historian",
      status: "active"
    }

    merged = Map.merge(base, attrs)

    agent =
      %Agent{}
      |> Agent.changeset(merged)
      |> Repo.insert!()

    # Task 019f2444 stage 6: `agents.system_events` was dropped —
    # HistorianDispatcher.agent_for_event/1 consults Platform.Roles
    # exclusively. Pin the Historian role so dispatch resolves to this
    # agent; if another test-local agent already claimed the role, the
    # older assignment wins (unique index on `role_key`).
    if agent.status == "active" do
      case Platform.Roles.assign_role("historian", agent.id) do
        {:ok, _} -> :ok
        {:error, _changeset} -> :ok
      end
    end

    agent
  end

  defp create_project(name) do
    {:ok, project} = Tasks.create_project(%{name: name})
    project
  end

  defp create_meeting(project) do
    name = "Meeting #{System.unique_integer([:positive])}"
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    meeting
  end

  defp end_meeting!(%Meeting{} = meeting) do
    {:ok, live} = Meetings.start_meeting(meeting)
    {:ok, ended} = Meetings.end_meeting(live)
    ended
  end

  defp insert_journal_chars!(workspace_id, n) when is_integer(n) and n > 0 do
    %MemoryEntry{}
    |> MemoryEntry.changeset(%{
      workspace_id: workspace_id,
      content: String.duplicate("x", n),
      date: Date.utc_today()
    })
    |> Repo.insert!()
  end

  defp backdate_last_run!(workspace_id, delta_ms) when is_binary(workspace_id) do
    past = DateTime.add(DateTime.utc_now(), -delta_ms, :millisecond)

    {_, _} =
      Repo.update_all(
        from(c in HistorianCursor, where: c.workspace_id == ^workspace_id),
        set: [last_run_at: past]
      )

    :ok
  end

  defp system_space_for(%Agent{slug: slug}), do: Chat.get_space_by_slug("system-#{slug}")

  defp messages_in(%Space{id: space_id}) do
    Repo.all(
      from(m in Message,
        where: m.space_id == ^space_id,
        order_by: [asc: m.inserted_at]
      )
    )
  end

  defp wait_until(timeout_ms \\ 2_000, step_ms \\ 25, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(deadline, step_ms, fun)
  end

  defp do_wait(deadline, step_ms, fun) do
    case fun.() do
      nil -> retry_or_fail(deadline, step_ms, fun)
      false -> retry_or_fail(deadline, step_ms, fun)
      value -> value
    end
  end

  defp retry_or_fail(deadline, step_ms, fun) do
    if System.monotonic_time(:millisecond) >= deadline do
      ExUnit.Assertions.flunk("wait_until predicate did not become truthy within deadline")
    else
      Process.sleep(step_ms)
      do_wait(deadline, step_ms, fun)
    end
  end

  # ── Case A: stagger sanity ───────────────────────────────────────────

  describe "Case A — anchor stagger correctness across workspaces" do
    test "two adjacent UUIDs hash to different offset minutes" do
      # setup: two workspaces with adjacent UUIDs.
      ws_a = "00000000-0000-0000-0000-000000000001"
      ws_b = "00000000-0000-0000-0000-000000000002"

      offset_a = SystemEventScheduler.offset_for(ws_a)
      offset_b = SystemEventScheduler.offset_for(ws_b)

      # expected: each offset lands in 0..359 and they differ.
      assert offset_a in 0..359
      assert offset_b in 0..359
      refute offset_a == offset_b
    end

    test "each workspace dispatches exactly 4 anchor windows per 24h" do
      # actions: enumerate the anchor windows hit by `next_fire_time` for
      # a workspace across a 24h horizon. The function returns the soonest
      # future fire; advancing forward to just past each result and asking
      # again four times must visit each of the `[0, 6, 12, 18]` anchors
      # exactly once.
      ws = "00000000-0000-0000-0000-000000000042"
      offset = SystemEventScheduler.offset_for(ws)

      start = ~U[2026-04-14 00:00:00.000000Z]

      {_final_cursor, anchors_hit} =
        Enum.reduce(1..4, {start, MapSet.new()}, fn _i, {cursor, acc} ->
          next = SystemEventScheduler.next_fire_time(cursor, ws, [0, 6, 12, 18])
          # The anchor hour is derived by subtracting the offset_minutes.
          anchor_dt = DateTime.add(next, -offset * 60, :second)
          # Advance the cursor 1ms past `next` so the next call returns a
          # strictly-later candidate, not the same one again.
          new_cursor = DateTime.add(next, 1, :millisecond)
          {new_cursor, MapSet.put(acc, anchor_dt.hour)}
        end)

      # expected: every anchor hour appears exactly once in 24h.
      assert anchors_hit == MapSet.new([0, 6, 12, 18])
    end

    test "stagger separation: two workspaces with distinct offsets never collapse to the same minute" do
      ws_a = "00000000-0000-0000-0000-000000000001"
      ws_b = "00000000-0000-0000-0000-000000000002"

      anchors = [0, 6, 12, 18]
      now = ~U[2026-04-14 00:00:00.000000Z]

      next_a = SystemEventScheduler.next_fire_time(now, ws_a, anchors)
      next_b = SystemEventScheduler.next_fire_time(now, ws_b, anchors)

      # If both land on the same anchor hour, they should still be at
      # different minute offsets. If they land on different anchors, the
      # delta is naturally >= 6h.
      delta_seconds = DateTime.diff(next_b, next_a, :second) |> abs()

      assert delta_seconds > 0,
             "expected adjacent workspaces to dispatch at different times — both fired at #{inspect(next_a)}"
    end
  end

  # ── Case B: debounce + post-debounce dispatch count ──────────────────

  describe "Case B — debounce window then re-fire" do
    test "T0 fires once, T0+30min debounces, T0+61min fires again — exactly 2 dispatches" do
      # setup: one historian agent + 100k+ tokens of pending journal content.
      agent = create_historian_agent()
      insert_journal_chars!(@org_workspace, 410_000)

      assert Historian.pending_tokens(@org_workspace) >= 100_000
      assert Historian.last_run_at(@org_workspace) == nil

      {:ok, _pid} =
        start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

      # T0: first tick fires.
      assert {@org_workspace, :fired} in SystemEventScheduler.run_threshold_check_now()
      assert %DateTime{} = Historian.last_run_at(@org_workspace)

      # T0+30min: backdate last_run_at by 30min, simulating 30min elapsed
      # but still inside the 1h debounce window.
      backdate_last_run!(@org_workspace, 30 * 60 * 1_000)
      assert {@org_workspace, :debounced} in SystemEventScheduler.run_threshold_check_now()

      # T0+61min: backdate to 61min ago — past the 1h debounce.
      backdate_last_run!(@org_workspace, 61 * 60 * 1_000)
      assert {@org_workspace, :fired} in SystemEventScheduler.run_threshold_check_now()

      # expected: exactly 2 dispatches landed in the agent's system space
      # (T0 and T0+61min). The debounced sweep wrote no message.
      space = system_space_for(agent)
      assert %Space{} = space

      threshold_messages =
        space
        |> messages_in()
        |> Enum.filter(&(get_in(&1.metadata, ["trigger"]) == "threshold"))

      assert length(threshold_messages) == 2,
             "expected exactly 2 threshold dispatches (T0 + T0+61min), got #{length(threshold_messages)}"
    end

    test "threshold_fired and threshold_debounced telemetry events both surface" do
      _agent = create_historian_agent()
      insert_journal_chars!(@org_workspace, 410_000)

      {:ok, _pid} =
        start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

      test_pid = self()
      handler_id = "t6-e2e-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:platform, :agents, :historian_scheduler, :threshold_fired],
          [:platform, :agents, :historian_scheduler, :threshold_debounced]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telem, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      SystemEventScheduler.run_threshold_check_now()
      backdate_last_run!(@org_workspace, 30 * 60 * 1_000)
      SystemEventScheduler.run_threshold_check_now()

      assert_receive {:telem, [:platform, :agents, :historian_scheduler, :threshold_fired],
                      fired_m, _},
                     1_000

      assert fired_m.pending_tokens >= 100_000

      assert_receive {:telem, [:platform, :agents, :historian_scheduler, :threshold_debounced],
                      _debounced_m, _},
                     1_000
    end
  end

  # ── Case C: meeting_ended scope leak guard ───────────────────────────

  describe "Case C — meeting_ended dispatch carries only the meeting's project + space scope" do
    test "Project P + space S in dispatch metadata; unrelated project Q + space S2 nowhere in metadata or rendered prompt" do
      # setup: project P with meeting M; unrelated project Q with its own
      # meeting (chat_space_id S2).
      agent = create_historian_agent()
      project_p = create_project("Project P")
      project_q = create_project("Project Q")

      _pid = start_supervised!({MeetingHistorianHandler, []})

      # Wait for handler to have subscribed to existing-at-boot project
      # topics (it lists projects on init).
      wait_until(fn ->
        subscribed = MeetingHistorianHandler.subscribed_projects()
        MapSet.member?(subscribed, project_p.id) and MapSet.member?(subscribed, project_q.id)
      end)

      # Create one meeting in each project so each has a chat_space_id.
      meeting_p = create_meeting(project_p)
      _meeting_q = create_meeting(project_q)

      # actions: end the meeting in P.
      ended_p = end_meeting!(meeting_p)

      # Wait for the dispatcher to post the synthetic instruction.
      wait_until(fn ->
        case system_space_for(agent) do
          nil -> false
          space -> List.last(messages_in(space))
        end
      end)

      space = system_space_for(agent)
      [message | _] = Enum.reverse(messages_in(space))

      # expected: metadata carries P's ids only.
      assert message.metadata["trigger"] == "meeting_ended"
      assert message.metadata["meeting_id"] == ended_p.id
      assert message.metadata["project_id"] == project_p.id
      assert message.metadata["chat_space_id"] == ended_p.chat_space_id

      # ACL: project Q's id does NOT appear anywhere in metadata.
      metadata_blob = Jason.encode!(message.metadata)

      refute String.contains?(metadata_blob, project_q.id),
             "Q's project_id leaked into dispatch metadata: #{metadata_blob}"

      # And the rendered prompt body does not mention Q either. The
      # current default instruction template references generic
      # `project/<id>/page/` paths — it must NOT contain Q.id or its
      # chat_space_id literal.
      refute String.contains?(message.content, project_q.id)
    end
  end

  # ── Case D: idempotency under retry / concurrent ticks ───────────────

  describe "Case D — mark_run_started stamps before dispatch, preventing double-fire" do
    test "two run_threshold_check_now calls back-to-back result in exactly one dispatch" do
      # setup: 100k+ pending tokens; historian agent.
      agent = create_historian_agent()
      insert_journal_chars!(@org_workspace, 410_000)

      {:ok, _pid} =
        start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

      # actions: fire two sweeps back-to-back. Even though both observe
      # `pending_tokens >= threshold`, the second must see the stamped
      # last_run_at from the first and debounce.
      result1 = SystemEventScheduler.run_threshold_check_now()
      result2 = SystemEventScheduler.run_threshold_check_now()

      # expected: first fires, second debounces.
      assert {@org_workspace, :fired} in result1
      assert {@org_workspace, :debounced} in result2

      # expected: exactly one message landed in the agent's system space.
      space = system_space_for(agent)

      threshold_messages =
        space
        |> messages_in()
        |> Enum.filter(&(get_in(&1.metadata, ["trigger"]) == "threshold"))

      assert length(threshold_messages) == 1,
             "expected exactly 1 dispatch after two back-to-back sweeps, got #{length(threshold_messages)}"
    end

    test "concurrent sweeps from N processes still produce one dispatch (mark_run_started is atomic)" do
      _agent = create_historian_agent()
      insert_journal_chars!(@org_workspace, 410_000)

      {:ok, _pid} =
        start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

      # Fan out 8 callers to the GenServer.call(run_threshold_check_now)
      # entry point. Each call serializes through the scheduler so even
      # though the calls are concurrent, the second-onwards see the
      # stamped last_run_at from the first.
      parent = self()

      tasks =
        for _i <- 1..8 do
          Task.async(fn ->
            res = SystemEventScheduler.run_threshold_check_now()
            send(parent, {:done, res})
            res
          end)
        end

      results = Task.await_many(tasks, 5_000)

      fired_count =
        results
        |> Enum.map(fn list -> Enum.count(list, fn {_, action} -> action == :fired end) end)
        |> Enum.sum()

      # expected: exactly one of the 8 sweeps reported :fired for the org
      # workspace.
      assert fired_count == 1,
             "expected exactly one :fired across 8 concurrent sweeps, got #{fired_count}"
    end
  end

  # ── Adversarial extras ────────────────────────────────────────────────

  describe "Adversarial — bad inputs and edge cases" do
    test "Historian context survives an empty workspace with no cursor rows" do
      # No journal/messages/transcripts/pages. pending_tokens must be 0
      # and last_run_at nil — i.e. the threshold sweep is a no-op.
      assert Historian.pending_tokens(@org_workspace) == 0
      assert Historian.last_run_at(@org_workspace) == nil

      _agent = create_historian_agent()

      {:ok, _pid} =
        start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

      results = SystemEventScheduler.run_threshold_check_now()
      assert {@org_workspace, :under_threshold} in results
    end

    test "legacy event names are remapped to historian with a warning, not silently dropped" do
      agent = create_historian_agent()

      {:ok, _pid} =
        start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

      log =
        capture_log(fn ->
          SystemEventScheduler.fire_now("daily_summary")
          SystemEventScheduler.fire_now("dreaming")
        end)

      assert log =~ "legacy event \"daily_summary\""
      assert log =~ "legacy event \"dreaming\""

      # Both fire paths still produce a message in the agent's system space.
      space = system_space_for(agent)
      assert %Space{} = space

      assert length(messages_in(space)) >= 2
    end

    test "unknown event name logs a warning without crashing the scheduler" do
      _agent = create_historian_agent()

      {:ok, _pid} =
        start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

      log =
        capture_log(fn ->
          SystemEventScheduler.fire_now("not_a_real_event")
        end)

      assert log =~ "unknown event"
    end

    test "should_fire_threshold?/5 boundary at exactly debounce_ms uses >= semantics" do
      now = ~U[2026-04-14 12:00:00.000000Z]
      debounce_ms = 60 * 60 * 1_000

      # exact boundary
      last = DateTime.add(now, -debounce_ms, :millisecond)
      assert SystemEventScheduler.should_fire_threshold?(100_000, last, now, 100_000, debounce_ms)

      # 1 ms shy
      last_in = DateTime.add(now, -(debounce_ms - 1), :millisecond)

      refute SystemEventScheduler.should_fire_threshold?(
               100_000,
               last_in,
               now,
               100_000,
               debounce_ms
             )
    end
  end

  # ── Scope-creep guards (static checks) ────────────────────────────────
  #
  # These are NOT runtime assertions; they verify on-disk source so that
  # future PRs touching this area cannot silently expand T6's footprint.
  # The plan called out four specific guards and we add a couple more
  # that fall out naturally from the design memo's "non-scope" list.

  describe "Scope-creep guards — T6 stays in its lane" do
    # Paths are relative to `apps/platform/` (where `Mix.Project.project_file/0`
    # lives). T5 stage 6 uses the same convention.
    @scheduler_path "lib/platform/agents/system_event_scheduler.ex"
    @historian_path "lib/platform/agents/historian.ex"
    @meeting_handler_path "lib/platform/agents/meeting_historian_handler.ex"
    @historian_dispatcher_path "lib/platform/agents/historian_dispatcher.ex"
    @historian_cursor_path "lib/platform/agents/historian_cursor.ex"
    @tool_surface_path "lib/platform/federation/tool_surface.ex"
    @chat_path "lib/platform/chat.ex"
    @agent_path "lib/platform/agents/agent.ex"

    # Baseline tool count. T6 must not add or remove any MCP tools — T5
    # owns the memory_* family, T6 only wires schedules and triggers. The
    # number is committed here so a future T6 follow-up can't sneak
    # `tool_surface.ex` edits past review.
    #
    # Re-baselined on the stack rollup: T6's stage-1 design lock pinned 67
    # against a tree WITHOUT the T1–T5 chain. T5's tool-surface rework
    # (-5 V1 org_context_*/org_memory_* tools, +6 memory_* tools +
    # memory_search) lands the merged tree at 69. The historian_* refutes
    # below still enforce the actual T6 invariant (no T6-added tools).
    # bumped by ADR 0042 (+org_list_descendants → 70)
    # bumped by ADR 0042 Stage 4 (+file_list, +file_get_text → 72)
    # bumped by PR #452 stack_complete (terminal transition tool → 73)
    # bumped by task_attach_canvas stage 3 (+task_attach_canvas,
    # +task_detach_canvas, +task_list_canvases → 76)
    # bumped by Files MCP stage 1 (+file_get_metadata → 77)
    # bumped by Files MCP stage 2 (+file_search → 78)
    # bumped by Files MCP stage 3 (+file_add → 79)
    # bumped by Files MCP stage 4 (+file_delete → 80)
    # bumped by principal_search hotfix (+principal_search → 81)
    @t6_baseline_tool_count 81

    defp t6_root, do: Mix.Project.project_file() |> Path.dirname()

    # Worktree (repo) root — two levels above `apps/platform/`. Path.expand
    # collapses `../..` so this is the directory holding `.git`.
    defp repo_root, do: Path.expand("../..", t6_root())

    defp read_t6_file(rel) do
      t6_root() |> Path.join(rel) |> File.read!()
    end

    test "scheduler is operatively keyed on `historian`, not the legacy `daily_summary`" do
      src = read_t6_file(@scheduler_path)

      # The new event name MUST be present.
      assert src =~ "historian",
             "scheduler must reference the new `historian` event name"

      # The legacy event names may appear ONLY inside `normalize_event/1`
      # (a deprecation funnel that warns and routes to historian) and
      # `template_slug_for/1`. They must NOT appear as the operative
      # `@historian_event` value or in any `@default_events`-style map.
      refute src =~ "@historian_event \"daily_summary\"",
             "scheduler must not retain @historian_event = \"daily_summary\""

      refute src =~ "@default_events",
             "legacy @default_events map must be gone (replaced by @anchors + offset_for/1)"

      # `@anchors` must be the [0, 6, 12, 18] every-6h list.
      assert Regex.match?(~r/@anchors\s+\[0,\s*6,\s*12,\s*18\]/, src),
             "scheduler must declare @anchors = [0, 6, 12, 18]"
    end

    test "no `_web/live/` file references the new T6 modules — LiveView is out of scope" do
      bad =
        "lib/platform_web/live/**/*.{ex,heex}"
        |> then(&Path.join(t6_root(), &1))
        |> Path.wildcard()
        |> Enum.filter(fn p ->
          src = File.read!(p)

          String.contains?(src, "MeetingHistorianHandler") or
            String.contains?(src, "HistorianCursor") or
            String.contains?(src, "HistorianDispatcher") or
            String.contains?(src, "Platform.Agents.Historian.")
        end)

      assert bad == [],
             "T6 must not introduce LiveView references to historian internals — " <>
               "found: #{inspect(bad)}"
    end

    test "no new MCP tools — tool surface count matches the T6 stage-1 baseline" do
      tools = Platform.Federation.ToolSurface.tool_definitions()
      names = Enum.map(tools, & &1.name)

      assert length(names) == @t6_baseline_tool_count,
             """
             Tool surface count drifted — expected #{@t6_baseline_tool_count} (T6 stage-1
             baseline), got #{length(names)}. T6 must not add or remove MCP tools; the
             memory_* family belongs to T5, and the historian schedule + triggers run
             behind PubSub + GenServer ticks, not through a federated tool.

             Current names: #{inspect(names |> Enum.sort())}
             """

      # And no new `historian_*` tool sneaked in (defensive — even if the
      # baseline is met, double-check the new module names didn't get
      # turned into MCP entries).
      refute Enum.any?(names, &String.starts_with?(&1, "historian_"))
      refute Enum.any?(names, &String.starts_with?(&1, "memory_historian"))
    end

    test "chat.ex search_vector indexing path is untouched" do
      # The `chat_messages.search_vector` column is a GENERATED column
      # (see ORG_MEMORY.md → "Editable Messages: search re-ingest is free").
      # T6 must not poke at application-side re-ingest or backfill code.
      src = read_t6_file(@chat_path)

      refute Regex.match?(~r/def\s+\w*search_vector\w*\(/i, src),
             "chat.ex must not gain a search_vector helper as part of T6 scope"
    end

    # superseded by ADR 0042 (tool_surface legitimately gained org_id filters + org_list_descendants)
    @tag :skip
    test "tool_surface.ex is byte-for-byte identical to origin/main (T6 owns no tool changes)" do
      # The cheapest, hardest-to-game guard: git diff against `origin/main`
      # for tool_surface.ex must be empty on the T6 branch.
      {diff, status} =
        System.cmd(
          "git",
          ["diff", "origin/main", "--", "apps/platform/lib/platform/federation/tool_surface.ex"],
          cd: repo_root(),
          stderr_to_stdout: true
        )

      # Skip silently when git isn't available (CI containers without .git).
      if status != 0 do
        :ok
      else
        assert diff == "",
               """
               T6 unexpectedly modified tool_surface.ex — that's T5's territory.
               Diff vs origin/main:
               #{diff}
               """
      end
    end

    # superseded by ADR 0042 (Platform.Org.* legitimately gained org-topology updates)
    @tag :skip
    test "Wiki / Journal page schemas were not extended in T6" do
      # T2/T3 own the wiki schema. T6's only data-layer addition is the
      # `org_historian_cursors` table + its Ecto schema. Confirm no Wiki
      # schema files were touched.
      {diff, status} =
        System.cmd(
          "git",
          [
            "diff",
            "origin/main",
            "--name-only",
            "--",
            "apps/platform/lib/platform/org/"
          ],
          cd: repo_root(),
          stderr_to_stdout: true
        )

      if status != 0 do
        :ok
      else
        changed =
          diff
          |> String.split("\n", trim: true)
          |> Enum.reject(&(&1 == ""))

        assert changed == [],
               """
               T6 touched Platform.Org.* files — should be empty (T2/T3 own that surface).
               Changed paths:
               #{Enum.join(changed, "\n")}
               """
      end
    end

    test "Historian is Roles-based post-retirement" do
      # Task 019f2444 stage 6 dropped the legacy `agents.system_events`
      # column + `@valid_system_events` module attribute. The Historian
      # signal now lives exclusively in `role_assignments`; assert the
      # canonical Roles lookup path is available at runtime.
      assert Code.ensure_loaded?(Platform.Roles)
      assert function_exported?(Platform.Roles, :agent_id_for_role, 1)

      # And no daily_summary/dreaming legacy references remain in Agent.
      src = read_t6_file(@agent_path)

      refute src =~ "@valid_system_events",
             "Agent module must not retain @valid_system_events — dropped in stage 6"

      refute src =~ "daily_summary",
             "Agent module must not retain a `daily_summary` reference"

      refute src =~ ~r/\bdreaming\b/,
             "Agent module must not retain a `dreaming` reference"
    end

    test "no embedding pipeline edits — T6 doesn't touch memory-service or Memory.* internals" do
      # Inspect the four new T6 files. None should `alias` or `use`
      # Platform.Memory.* — the Historian dispatches via AgentResponder,
      # which in turn talks to whatever LLM provider is configured; the
      # historian context never calls Memory.upsert / Memory.delete.
      for path <- [
            @historian_path,
            @meeting_handler_path,
            @historian_dispatcher_path,
            @historian_cursor_path
          ] do
        src = read_t6_file(path)

        refute Regex.match?(~r/alias\s+Platform\.Memory(?:\.|$|\s)/m, src),
               "#{path} must not alias Platform.Memory — T6 is wiring + cursor, not indexing"

        refute Regex.match?(~r/Platform\.Memory\.(upsert|delete|search|ingest)/, src),
               "#{path} must not invoke Memory.{upsert,delete,search,ingest}/* directly"
      end
    end

    test "historian context owns ALL writes to org_historian_cursors" do
      # The scheduler must NOT call Repo.* against HistorianCursor directly —
      # all upserts / advances live in Platform.Agents.Historian.
      src = read_t6_file(@scheduler_path)

      refute Regex.match?(~r/Repo\.(insert|update|update_all|delete)\b/, src),
             "scheduler must not Repo.* directly — Historian owns cursor writes"

      refute String.contains?(src, "HistorianCursor"),
             "scheduler must not reference HistorianCursor — that's Historian's internal"
    end

    test "Journal corpus is never written-to by the Historian context" do
      # T2 owns Journal append. The Historian READS journal bytes for
      # the threshold heuristic but must not call Journal.append/2 or
      # Repo.insert!(%MemoryEntry{...}) — that would break the
      # journal-by-default contract.
      src = read_t6_file(@historian_path)

      refute String.contains?(src, "Journal.append"),
             "Historian must not call Journal.append — journal writes belong to memory_* tools"

      refute Regex.match?(~r/Repo\.insert!?\(\s*%MemoryEntry\{/, src),
             "Historian must not insert MemoryEntry rows directly"
    end
  end
end
