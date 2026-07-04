defmodule Platform.Meetings.SummarizerSweeperTest do
  @moduledoc """
  Tests for the SummarizerSweeper GenServer (task 019f2566 stage 2).

  Each test spins up its own sweeper with a shortened `check_interval_ms`
  and `stall_window_ms` so the periodic tick + sweep body run inside
  the DataCase ExUnit case rather than the application-wide singleton
  (disabled via `:start_summarizer_sweeper false` in `config/test.exs`).

  Sweep behavior is asserted via:

    * the telemetry event `[:platform, :meetings, :summarize_fallback_fired]`,
      which fires exactly once per stalled transcript that a given
      sweep picks up
    * `ExUnit.CaptureLog` on the `[SummarizerSweeper] fallback firing …`
      warning, so operators can grep for it in prod
    * `Meetings.list_stalled_router_dispatches/1` behavior (indirect —
      exercised through the sweep itself)

  The spawned fallback body (`Summarizer.run_summary_legacy/3`) runs
  under `Platform.TaskSupervisor` and doesn't need a real LLM in tests
  — the default test config sets provider `:none`, so the fallback
  short-circuits to `Meetings.fail_transcript/1` after emitting
  telemetry. The failure path is intentional; the sweeper's contract
  is "hand off the stalled dispatch to the legacy body", not "produce
  a valid summary".

  Runs `async: false` because we mutate `Meetings.SummarizerSweeper`
  telemetry handlers globally, and because tasks spawned under the
  supervisor need `Sandbox.mode({:shared, _})` to reach the test's DB
  connection.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.SummarizerSweeper
  alias Platform.Responsibilities.Handlers.MeetingSummarize
  alias Platform.Responsibilities.StallRegistry
  alias Platform.Roles

  @telemetry_event [:platform, :meetings, :summarize_fallback_fired]

  defp unique_name do
    Module.concat([SummarizerSweeper, "Inst#{System.unique_integer([:positive])}"])
  end

  defp start_sweeper(opts) do
    name = unique_name()
    pid = start_supervised!({SummarizerSweeper, Keyword.put(opts, :name, name)})
    {pid, name}
  end

  defp create_processing_transcript!(router_dispatched_at) do
    # Insert via Repo directly so we can set router_dispatched_at
    # in one round-trip without a second UPDATE that would race the
    # sweep window.
    {:ok, transcript} =
      Meetings.create_transcript(%{
        room_id: "space-#{Ecto.UUID.generate()}",
        space_id: Ecto.UUID.generate(),
        segments: [],
        status: "processing"
      })

    {1, nil} =
      Platform.Repo.update_all(
        from(t in Platform.Meetings.Transcript, where: t.id == ^transcript.id),
        set: [router_dispatched_at: router_dispatched_at]
      )

    Meetings.get_transcript(transcript.id)
  end

  # Wait for the fallback tasks spawned by the sweeper to finish so the
  # SQL sandbox connection isn't torn down while they still hold it.
  defp await_pids(pids) do
    Enum.each(pids, fn pid ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        2_000 ->
          flunk("Task under Platform.TaskSupervisor did not exit within 2s (pid=#{inspect(pid)})")
      end
    end)
  end

  defp attach_telemetry_recorder(test_pid) do
    handler_id = "sweeper-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      @telemetry_event,
      fn event, measurements, metadata, _cfg ->
        send(test_pid, {:sweep_telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "sweep_now/1 — fires fallback for stalled processing transcripts" do
    test "picks up a transcript whose router_dispatched_at is older than stall_window_ms" do
      attach_telemetry_recorder(self())

      # 500ms in the past — well past the 200ms stall window
      stale =
        create_processing_transcript!(DateTime.add(DateTime.utc_now(), -500, :millisecond))

      {_pid, name} = start_sweeper(check_interval_ms: 60_000, stall_window_ms: 200)

      log =
        capture_log(fn ->
          {:ok, pids} = SummarizerSweeper.sweep_now(name)
          await_pids(pids)
          # Wait a beat for the async telemetry send to land in our mailbox.
          assert_receive {:sweep_telemetry, @telemetry_event, measurements, metadata}, 500
          # Attach measurement + metadata assertions here so the log capture
          # scope covers the sweeper's warning log write.
          assert measurements.stalled_for_ms >= 500
          assert metadata.transcript_id == stale.id
          assert metadata.stalled_for_ms >= 500
          # Stage 3 populates this; stage 2 always returns nil.
          assert is_nil(metadata.previously_assigned_agent_slug)
        end)

      assert log =~ "[SummarizerSweeper] fallback firing transcript_id=#{stale.id}"
      assert log =~ "stalled_for="
    end

    test "skips a transcript whose router_dispatched_at is inside stall_window_ms" do
      attach_telemetry_recorder(self())

      # 50ms in the past — inside the 200ms stall window, so NOT stalled.
      fresh =
        create_processing_transcript!(DateTime.add(DateTime.utc_now(), -50, :millisecond))

      {_pid, name} = start_sweeper(check_interval_ms: 60_000, stall_window_ms: 200)

      capture_log(fn ->
        {:ok, pids} = SummarizerSweeper.sweep_now(name)
        await_pids(pids)
      end)

      refute_receive {:sweep_telemetry, @telemetry_event, _, _}, 300

      # Sanity: fresh row still there and still processing.
      assert %{status: "processing"} = Meetings.get_transcript(fresh.id)
    end

    test "fires for the stale transcript but not for the fresh one in a mixed batch" do
      attach_telemetry_recorder(self())

      stale =
        create_processing_transcript!(DateTime.add(DateTime.utc_now(), -500, :millisecond))

      _fresh =
        create_processing_transcript!(DateTime.add(DateTime.utc_now(), -50, :millisecond))

      {_pid, name} = start_sweeper(check_interval_ms: 60_000, stall_window_ms: 200)

      capture_log(fn ->
        {:ok, pids} = SummarizerSweeper.sweep_now(name)
        await_pids(pids)
        assert_receive {:sweep_telemetry, @telemetry_event, _measurements, metadata}, 500
        assert metadata.transcript_id == stale.id
      end)

      # Exactly one fire — no second telemetry event lands after a
      # quick drain window.
      refute_receive {:sweep_telemetry, @telemetry_event, _, _}, 300
    end

    test "ignores transcripts with status != processing even if router_dispatched_at is stale" do
      attach_telemetry_recorder(self())

      {:ok, complete_transcript} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          status: "complete",
          summary: "already done"
        })

      {1, nil} =
        Platform.Repo.update_all(
          from(t in Platform.Meetings.Transcript, where: t.id == ^complete_transcript.id),
          set: [router_dispatched_at: DateTime.add(DateTime.utc_now(), -600, :millisecond)]
        )

      {_pid, name} = start_sweeper(check_interval_ms: 60_000, stall_window_ms: 200)

      capture_log(fn ->
        {:ok, pids} = SummarizerSweeper.sweep_now(name)
        await_pids(pids)
      end)

      refute_receive {:sweep_telemetry, @telemetry_event, _, _}, 300
    end

    test "ignores transcripts with router_dispatched_at IS NULL" do
      attach_telemetry_recorder(self())

      # Never dispatched — stage 2 only covers the "router fired but
      # stalled" path, not the belt-and-braces "router never fired"
      # branch.
      {:ok, _never_dispatched} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          status: "processing"
        })

      {_pid, name} = start_sweeper(check_interval_ms: 60_000, stall_window_ms: 200)

      capture_log(fn ->
        {:ok, pids} = SummarizerSweeper.sweep_now(name)
        await_pids(pids)
      end)

      refute_receive {:sweep_telemetry, @telemetry_event, _, _}, 300
    end
  end

  describe "post-fallback notice into the meeting space (task 019f2566 stage 5)" do
    defp create_execution_space! do
      {:ok, space} = Chat.create_space(%{kind: "execution"})
      space
    end

    defp insert_agent!(slug) do
      %Platform.Agents.Agent{}
      |> Platform.Agents.Agent.changeset(%{
        slug: slug,
        name: slug,
        status: "active",
        kind: "native"
      })
      |> Platform.Repo.insert!()
    end

    defp create_stalled_processing_transcript!(space_id, router_dispatched_at) do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          space_id: space_id,
          segments: [],
          status: "processing"
        })

      {1, nil} =
        Platform.Repo.update_all(
          from(t in Platform.Meetings.Transcript, where: t.id == ^transcript.id),
          set: [router_dispatched_at: router_dispatched_at]
        )

      Meetings.get_transcript(transcript.id)
    end

    defp wait_for_fallback_notice(space_id, transcript_id, timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      Stream.repeatedly(fn ->
        message =
          space_id
          |> Chat.list_messages()
          |> Kernel.||([])
          |> Enum.find(fn m ->
            m.metadata["source"] == "meeting_summarizer_fallback" and
              m.metadata["transcript_id"] == transcript_id
          end)

        {message, System.monotonic_time(:millisecond)}
      end)
      |> Enum.reduce_while(nil, fn
        {%_{} = message, _now}, _ ->
          {:halt, message}

        {nil, now}, _ when now >= deadline ->
          {:halt, nil}

        {nil, _now}, _ ->
          Process.sleep(25)
          {:cont, nil}
      end)
    end

    test "seeds a stalled dispatch, sweep tick runs, notice posts naming the assigned agent" do
      # LLM provider is `:none` in test config, so the legacy body will
      # ultimately return `{:error, {:llm_failed, :no_summary_provider_configured}}`.
      # That's still a "legacy path ran to completion" from the sweeper's POV
      # — we should see the `also_failed` notice land in the meeting space.
      space = create_execution_space!()
      agent = insert_agent!("scribe-under-test-#{System.unique_integer([:positive])}")
      {:ok, _} = Roles.set_override(MeetingSummarize.key(), agent.id)

      stale =
        create_stalled_processing_transcript!(
          space.id,
          DateTime.add(DateTime.utc_now(), -500, :millisecond)
        )

      {_pid, name} = start_sweeper(check_interval_ms: 60_000, stall_window_ms: 200)

      capture_log(fn ->
        {:ok, pids} = SummarizerSweeper.sweep_now(name)
        await_pids(pids)
        # Give the sweeper GenServer a beat to receive the {ref, result}
        # message from the async task and post the fallback notice.
        assert notice = wait_for_fallback_notice(space.id, stale.id, 2_000),
               "expected a fallback notice message in the meeting space"

        assert notice.content_type == "system"
        assert notice.content =~ "@#{agent.slug}"
        assert notice.content =~ "/control-center/roles"
        # Real provider is :none in tests → legacy body fails → also_failed shape.
        assert notice.content =~ "Summary fallback also failed"
        assert notice.metadata["mode"] == "also_failed"
        assert notice.metadata["previously_assigned_agent"] == agent.slug
      end)
    end

    test "notice degrades to generic phrasing when no agent is assigned" do
      # No `set_override/2`, no role assignment — `assignee_for/1` returns nil,
      # so the sweeper's `previously_assigned_agent_slug/1` is nil, and the
      # notice's "previously-assigned" phrase collapses to the generic
      # "The assigned summarizer" copy.
      space = create_execution_space!()

      stale =
        create_stalled_processing_transcript!(
          space.id,
          DateTime.add(DateTime.utc_now(), -500, :millisecond)
        )

      {_pid, name} = start_sweeper(check_interval_ms: 60_000, stall_window_ms: 200)

      capture_log(fn ->
        {:ok, pids} = SummarizerSweeper.sweep_now(name)
        await_pids(pids)

        assert notice = wait_for_fallback_notice(space.id, stale.id, 2_000)
        assert notice.content =~ "The assigned summarizer"
        refute notice.content =~ "@"
        assert notice.metadata["previously_assigned_agent"] in [nil, ""]
      end)
    end
  end

  describe "handle_info(:tick, ...) — periodic sweep" do
    test "the scheduled tick sweeps without an explicit sweep_now call" do
      attach_telemetry_recorder(self())

      stale =
        create_processing_transcript!(DateTime.add(DateTime.utc_now(), -500, :millisecond))

      # Stage 6 refactor: the sweeper's `:tick` handler walks
      # StallRegistry callbacks instead of running its own sweep body
      # directly. To exercise the tick path we need a per-case registry
      # with the sweeper's own callback registered.
      registry_name =
        Module.concat([StallRegistry, "TickInst#{System.unique_integer([:positive])}"])

      _reg = start_supervised!({StallRegistry, name: registry_name})

      :ok =
        StallRegistry.register(
          {Platform.Meetings.SummarizerSweeper, :sweep_meetings_summarize},
          registry_name
        )

      # 100ms tick + 200ms stall window — the first scheduled tick
      # should fire within ~100ms. Note that `sweep_meetings_summarize/0`
      # delegates to `sweep_now(SummarizerSweeper)` via the default name,
      # so this test uses the default `__MODULE__` name for the sweeper
      # itself (rather than `unique_name/0`).
      capture_log(fn ->
        _pid =
          start_supervised!(
            {SummarizerSweeper,
             check_interval_ms: 100,
             stall_window_ms: 200,
             stall_registry: registry_name,
             name: Platform.Meetings.SummarizerSweeper}
          )

        assert_receive {:sweep_telemetry, @telemetry_event, _, metadata}, 2_000
        assert metadata.transcript_id == stale.id

        # Wait for any in-flight fallback tasks under Platform.TaskSupervisor
        # to drain so their sandbox connections aren't cut off at test exit.
        await_task_supervisor_children()
      end)
    end
  end

  defp await_task_supervisor_children do
    pids = Task.Supervisor.children(Platform.TaskSupervisor)
    await_pids(pids)
  end

  describe "StallRegistry integration (task 019f2566 stage 6)" do
    defp start_registry! do
      name = Module.concat([StallRegistry, "Inst#{System.unique_integer([:positive])}"])
      _pid = start_supervised!({StallRegistry, name: name})
      name
    end

    defp start_sweeper_with_registry!(opts, registry_name) do
      name = unique_name()

      pid =
        start_supervised!(
          {SummarizerSweeper,
           opts
           |> Keyword.put(:name, name)
           |> Keyword.put(:stall_registry, registry_name)}
        )

      {pid, name}
    end

    # A stub sweep function that records into an ETS table so the
    # test can assert it ran. Global ETS handle keyed off `test_ref`
    # so multiple tests don't clobber each other.
    defmodule StubSweep do
      def counter_table, do: :summarizer_sweeper_stub_counters

      def ensure_table do
        try do
          :ets.new(counter_table(), [:public, :named_table, :set, {:write_concurrency, true}])
        rescue
          ArgumentError -> :already_exists
        end
      end

      def bump(key) do
        ensure_table()
        :ets.update_counter(counter_table(), key, 1, {key, 0})
      end

      def count(key) do
        ensure_table()

        case :ets.lookup(counter_table(), key) do
          [{^key, n}] -> n
          [] -> 0
        end
      end

      def sweep_ok_a, do: bump(:sweep_ok_a)
      def sweep_ok_b, do: bump(:sweep_ok_b)
      def sweep_raise, do: raise("boom from stub sweeper")

      def reset do
        ensure_table()
        :ets.delete_all_objects(counter_table())
        :ok
      end
    end

    setup do
      StubSweep.reset()
      :ok
    end

    test "tick invokes each registered {mod, fun} callback" do
      registry = start_registry!()
      :ok = StallRegistry.register({StubSweep, :sweep_ok_a}, registry)
      :ok = StallRegistry.register({StubSweep, :sweep_ok_b}, registry)

      # 100ms tick — should fire once inside the assert_eventually window.
      capture_log(fn ->
        {_pid, _name} =
          start_sweeper_with_registry!(
            [check_interval_ms: 100, stall_window_ms: 60_000],
            registry
          )

        # Wait for both stub callbacks to have run at least once.
        Enum.reduce_while(1..40, nil, fn _, _ ->
          if StubSweep.count(:sweep_ok_a) >= 1 and StubSweep.count(:sweep_ok_b) >= 1 do
            {:halt, :ok}
          else
            Process.sleep(50)
            {:cont, nil}
          end
        end)

        await_task_supervisor_children()
      end)

      assert StubSweep.count(:sweep_ok_a) >= 1
      assert StubSweep.count(:sweep_ok_b) >= 1
    end

    test "a raising callback does NOT prevent sibling callbacks from running" do
      registry = start_registry!()
      :ok = StallRegistry.register({StubSweep, :sweep_raise}, registry)
      :ok = StallRegistry.register({StubSweep, :sweep_ok_a}, registry)

      log =
        capture_log(fn ->
          {_pid, _name} =
            start_sweeper_with_registry!(
              [check_interval_ms: 100, stall_window_ms: 60_000],
              registry
            )

          Enum.reduce_while(1..40, nil, fn _, _ ->
            if StubSweep.count(:sweep_ok_a) >= 1 do
              {:halt, :ok}
            else
              Process.sleep(50)
              {:cont, nil}
            end
          end)

          await_task_supervisor_children()
        end)

      # Sibling still ran despite raising callback…
      assert StubSweep.count(:sweep_ok_a) >= 1
      # …and the raise was logged so operators can see it.
      assert log =~ "sweep callback"
      assert log =~ "raised"
      assert log =~ "boom from stub sweeper"
    end

    test "tick with an empty registry is a no-op that reschedules cleanly" do
      registry = start_registry!()

      capture_log(fn ->
        {pid, _name} =
          start_sweeper_with_registry!(
            [check_interval_ms: 100, stall_window_ms: 60_000],
            registry
          )

        # Give a few ticks a chance to fire without any callbacks.
        Process.sleep(350)

        # Sweeper is still alive and responding to :sweep_now.
        assert Process.alive?(pid)
        {:ok, _pids} = SummarizerSweeper.sweep_now(pid)

        await_task_supervisor_children()
      end)
    end

    test "sweep_meetings_summarize/0 with no default-name sweeper is a silent no-op" do
      # The default __MODULE__ name isn't registered in test env
      # (config :platform, :start_summarizer_sweeper, false), and this
      # case doesn't start one, so `GenServer.whereis(SummarizerSweeper)`
      # returns nil.
      refute GenServer.whereis(SummarizerSweeper)
      assert :ok = SummarizerSweeper.sweep_meetings_summarize()
    end
  end
end
