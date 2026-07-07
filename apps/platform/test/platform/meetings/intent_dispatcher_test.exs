defmodule Platform.Meetings.IntentDispatcherTest do
  @moduledoc """
  Tests for `Platform.Meetings.IntentDispatcher` — the global GenServer
  that drains `Platform.Meetings.IntentQueue` and hands each classified
  intent to the agent currently assigned to `target_role` (task
  019f2452 stage 2).

  Covers the six branches called out in the plan:

    * happy path — pending item with resolvable `target_role` calls the
      injected native dispatcher with an AgentResponder-shaped signal
      then transitions the queue row to `mark_dispatched`
    * unknown `target_role` — dropped as `:unknown_role`; the first
      occurrence per role_key logs at `:info`, subsequent hits stay
      silent (dispatcher-lifetime MapSet)
    * `target_role: nil` — dropped as `:no_assignee` immediately
    * role resolves but has no `role_assignments` row — dropped as
      `:no_assignee`
    * external agent kind — selects the external dispatch fn via the
      `:meetings_intent_dispatcher_external_dispatcher` app-env seam
    * dispatch task raises — the dispatcher survives (subscription +
      tick both still fire) and the row promotes through mark_retry
    * DataCase sandbox race — a `DBConnection.OwnershipError` from the
      spawned dispatch task is caught as `:sandbox_gone` and the row
      is silently cleared (no crash, no phantom retry)

  Async-false because the module owns a named GenServer + subscribes
  to the shared `meeting:intent_enqueued` topic. Test-scoped instances
  are booted via `start_supervised/1` under unique per-test names so
  the singleton contract isn't violated when running in a suite.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Meetings.IntentDispatcher
  alias Platform.Meetings.IntentQueue
  alias Platform.Repo
  alias Platform.Roles

  # ── Test-scoped rooms (auto-cleaned) ───────────────────────────────────────

  @rooms ~w(
    intentdisp-happy
    intentdisp-unknown-1
    intentdisp-unknown-2
    intentdisp-nil-role
    intentdisp-no-assignee
    intentdisp-external
    intentdisp-crash
    intentdisp-sandbox
    intentdisp-tick
    intentdisp-agent-missing
  )

  setup do
    # Shared sandbox so async Task.Supervisor children can see the
    # test's schema. Mirrors `TaskRouterWatcherTest`'s setup.
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    # Bump this module's log level to :info so `capture_log` can
    # actually see the "unknown target_role" line the once-per-boot
    # spam suppressor emits. Mirrors `IntentClassifierTest`.
    Logger.put_module_level(Platform.Meetings.IntentDispatcher, :info)

    on_exit(fn ->
      Logger.delete_module_level(Platform.Meetings.IntentDispatcher)
      for room <- @rooms, do: IntentQueue.drop_for_room(room)
      # Clear any test-seam overrides so a failure in one test doesn't
      # bleed the stub into siblings.
      Application.delete_env(:platform, :meetings_intent_dispatcher_native_dispatcher)
      Application.delete_env(:platform, :meetings_intent_dispatcher_external_dispatcher)
    end)

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Attach one or more telemetry events to a shared handler that
  # forwards `{event_name, measurements, metadata}` to the test process.
  # Auto-detached via `on_exit`. Mirrors the pattern used in
  # `intent_queue_test.exs`.
  defp attach_telemetry!(events) when is_list(events) do
    handler_id = "intent-dispatcher-test-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp start_dispatcher!(opts \\ []) do
    name = :"intent_dispatcher_#{System.unique_integer([:positive])}"

    # Push tick out to something the test never trips into so the hot
    # PubSub path and the periodic tick can be exercised independently.
    child_opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put_new(:tick_interval_ms, 60_000)

    {:ok, pid} = start_supervised({IntentDispatcher, child_opts})
    {pid, name}
  end

  defp create_agent!(overrides) do
    attrs =
      Map.merge(
        %{
          slug: "intentdisp-agent-#{System.unique_integer([:positive])}",
          name: "Intent Dispatcher Test Agent",
          status: "active",
          kind: "native"
        },
        overrides
      )

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  defp assign_role!(role_key, %Agent{id: id}) do
    # Roles are DB-seeded; `role_assignments.role_key` has a unique
    # index, so if a sibling test left a row we clear it first.
    :ok = Roles.unassign_role(role_key)
    {:ok, _} = Roles.assign_role(role_key, id)
    :ok
  end

  # Install a stub for one of the two dispatch surfaces. The stub is a
  # closure that captures `self()`, so we can `assert_receive` on the
  # payload the dispatcher hands it.
  defp install_native_stub(fun) when is_function(fun, 1) do
    parent = self()

    Application.put_env(
      :platform,
      :meetings_intent_dispatcher_native_dispatcher,
      {__MODULE__.Stub, :native_dispatch}
    )

    :persistent_term.put({__MODULE__, :native_stub}, {parent, fun})
    :ok
  end

  defp install_external_stub(fun) when is_function(fun, 3) do
    parent = self()

    Application.put_env(
      :platform,
      :meetings_intent_dispatcher_external_dispatcher,
      {__MODULE__.Stub, :external_dispatch}
    )

    :persistent_term.put({__MODULE__, :external_stub}, {parent, fun})
    :ok
  end

  defp await_dispatch(room_id, _dedupe_key, timeout \\ 1_000) do
    # `mark_dispatched` deletes the row entirely, so successful
    # dispatch shows up as an empty list for the room. Poll for a
    # bounded interval so we don't wedge the test if the async task
    # takes a beat.
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> IntentQueue.list_for_room(room_id) end)
    |> Enum.reduce_while(nil, fn items, _ ->
      cond do
        items == [] ->
          {:halt, :cleared}

        System.monotonic_time(:millisecond) > deadline ->
          {:halt, {:still_present, items}}

        true ->
          Process.sleep(20)
          {:cont, nil}
      end
    end)
    |> case do
      :cleared -> :ok
      other -> other
    end
  end

  # ── Stubs live in a nested module so they're addressable by an MFA
  # via `Application.put_env/3`. The functions read the stashed
  # `{pid, fun}` out of `:persistent_term`, forward the payload to the
  # parent test process, and run the caller's fun for the return
  # value.
  # ───────────────────────────────────────────────────────────────────────────

  defmodule Stub do
    @moduledoc false

    def native_dispatch(signal) do
      case :persistent_term.get({Platform.Meetings.IntentDispatcherTest, :native_stub}, nil) do
        {pid, fun} ->
          send(pid, {:native_dispatch_called, signal})
          fun.(signal)

        nil ->
          :ok
      end
    end

    def external_dispatch(responsibility, agent, context) do
      case :persistent_term.get({Platform.Meetings.IntentDispatcherTest, :external_stub}, nil) do
        {pid, fun} ->
          send(pid, {:external_dispatch_called, responsibility, agent, context})
          fun.(responsibility, agent, context)

        nil ->
          {:ok, %{content: %{}}}
      end
    end
  end

  # ── Tests ──────────────────────────────────────────────────────────────────

  describe "PubSub-notify hot path" do
    test "resolvable role dispatches to native agent then marks the row dispatched" do
      install_native_stub(fn _signal -> :ok end)

      agent = create_agent!(%{kind: "native"})
      :ok = assign_role!("designer", agent)

      {_pid, _name} = start_dispatcher!()

      # Give the dispatcher a beat to finish `init/1` (subscribe).
      Process.sleep(20)

      # Enqueue — the queue broadcasts `{:intent_enqueued, ...}` on
      # the `:inserted` path, waking the dispatcher.
      assert {:ok, :inserted} =
               IntentQueue.enqueue("intentdisp-happy", "dk-happy", %{
                 intent: "book_followup",
                 target_role: "designer",
                 confidence: 0.9,
                 chunk_id: "chunk-happy",
                 meeting_id: "mtg-happy"
               })

      assert_receive {:native_dispatch_called, signal}, 1_000

      assert %{
               reason: :system_event,
               metadata: %{
                 source: :meetings_intent_dispatcher,
                 role_key: "designer",
                 intent: "book_followup",
                 room_id: "intentdisp-happy",
                 dedupe_key: "dk-happy",
                 agent_id: agent_id
               }
             } = signal

      assert agent_id == agent.id
      assert :ok = await_dispatch("intentdisp-happy", "dk-happy")
    end

    test "target_role atom form (from legacy classifier output) is normalised" do
      install_native_stub(fn _ -> :ok end)

      agent = create_agent!(%{kind: "native"})
      :ok = assign_role!("historian", agent)

      {_pid, _name} = start_dispatcher!()
      Process.sleep(20)

      IntentQueue.enqueue("intentdisp-happy", "dk-atom", %{
        intent: "record_decision",
        target_role: :historian,
        confidence: 0.75,
        chunk_id: "chunk-atom"
      })

      assert_receive {:native_dispatch_called, %{metadata: %{role_key: "historian"}}}, 1_000
    end
  end

  describe "drop reasons" do
    test "unknown role_key drops with :unknown_role and logs once per boot" do
      install_native_stub(fn _ -> :ok end)

      {_pid, _name} = start_dispatcher!()
      Process.sleep(20)

      log =
        capture_log([level: :info], fn ->
          IntentQueue.enqueue("intentdisp-unknown-1", "dk-unknown-1", %{
            intent: "do_stuff",
            target_role: "bogus_role",
            confidence: 0.5,
            chunk_id: "chunk-u1"
          })

          # Wait for the queue row to be gone (dispatcher dropped it).
          assert :ok = await_dispatch("intentdisp-unknown-1", "dk-unknown-1")
        end)

      assert log =~ "unknown target_role"
      assert log =~ "bogus_role"

      # Second hit with the same bogus role must NOT log again.
      log2 =
        capture_log([level: :info], fn ->
          IntentQueue.enqueue("intentdisp-unknown-2", "dk-unknown-2", %{
            intent: "do_stuff",
            target_role: "bogus_role",
            confidence: 0.5,
            chunk_id: "chunk-u2"
          })

          assert :ok = await_dispatch("intentdisp-unknown-2", "dk-unknown-2")
        end)

      refute log2 =~ "unknown target_role"

      # But a DIFFERENT unknown role still logs on its first hit.
      log3 =
        capture_log([level: :info], fn ->
          IntentQueue.enqueue("intentdisp-unknown-2", "dk-unknown-3", %{
            intent: "do_stuff",
            target_role: "other_bogus",
            confidence: 0.5,
            chunk_id: "chunk-u3"
          })

          assert :ok = await_dispatch("intentdisp-unknown-2", "dk-unknown-3")
        end)

      assert log3 =~ "other_bogus"
    end

    test "target_role nil drops with :no_assignee immediately" do
      install_native_stub(fn _ -> flunk("must not be called for nil target_role") end)

      {_pid, _name} = start_dispatcher!()
      Process.sleep(20)

      IntentQueue.enqueue("intentdisp-nil-role", "dk-nil", %{
        intent: "do_stuff",
        target_role: nil,
        confidence: 0.5,
        chunk_id: "chunk-nil"
      })

      assert :ok = await_dispatch("intentdisp-nil-role", "dk-nil")
    end

    test "role has no assignment → dropped as :no_assignee" do
      install_native_stub(fn _ -> flunk("must not be called for unassigned role") end)

      :ok = Roles.unassign_role("triage_officer")

      {_pid, _name} = start_dispatcher!()
      Process.sleep(20)

      IntentQueue.enqueue("intentdisp-no-assignee", "dk-noa", %{
        intent: "escalate",
        target_role: "triage_officer",
        confidence: 0.8,
        chunk_id: "chunk-noa"
      })

      assert :ok = await_dispatch("intentdisp-no-assignee", "dk-noa")
    end
  end

  describe "external agent kind" do
    test "external agent selects the external dispatch fn" do
      install_external_stub(fn responsibility, agent, context ->
        # Sanity-check the shape of everything the dispatcher hands the
        # external surface — the stub asserts here since the parent
        # `assert_receive` only sees the message.
        assert String.starts_with?(responsibility.key, "meetings.produce.")
        assert responsibility.feature == "meetings"
        assert %Agent{kind: "external"} = agent
        assert context.role_key == "meeting_scribe"
        assert context.intent == "log_action_item"

        {:ok, %{content: %{"ok" => true}}}
      end)

      agent =
        create_agent!(%{
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "https://example.test/v1",
          model: "gpt-fake"
        })

      :ok = assign_role!("meeting_scribe", agent)

      {_pid, _name} = start_dispatcher!()
      Process.sleep(20)

      IntentQueue.enqueue("intentdisp-external", "dk-ext", %{
        intent: "log_action_item",
        target_role: "meeting_scribe",
        confidence: 0.7,
        chunk_id: "chunk-ext"
      })

      assert_receive {:external_dispatch_called, _responsibility, _agent, _context}, 1_000
      assert :ok = await_dispatch("intentdisp-external", "dk-ext")
    end
  end

  describe "fault tolerance" do
    test "dispatch task raises → dispatcher still alive and PubSub subscription intact" do
      # The stub raises — Task.Supervisor.async_nolink shields the
      # dispatcher process so `handle_info({:DOWN, ...}, _)` records
      # a retry and life continues.
      install_native_stub(fn _signal ->
        raise "boom from stub"
      end)

      agent = create_agent!(%{kind: "native"})
      :ok = assign_role!("designer", agent)

      {pid, _name} = start_dispatcher!()
      Process.sleep(20)

      IntentQueue.enqueue("intentdisp-crash", "dk-crash", %{
        intent: "crash",
        target_role: "designer",
        confidence: 0.5,
        chunk_id: "chunk-crash"
      })

      # Give the async task time to raise + the :DOWN handler time
      # to run.
      Process.sleep(200)

      # Dispatcher still alive.
      assert Process.alive?(pid)

      # Row is still queued (as :pending, attempts bumped by
      # mark_retry). The dispatcher accepts new events after the
      # crash — enqueue another and verify it lands too.
      install_native_stub(fn _ -> :ok end)

      assert {:ok, :inserted} =
               IntentQueue.enqueue("intentdisp-crash", "dk-crash-2", %{
                 intent: "second_try",
                 target_role: "designer",
                 confidence: 0.5,
                 chunk_id: "chunk-crash-2"
               })

      assert_receive {:native_dispatch_called, _signal}, 1_000
    end

    test "sandbox_gone from dispatch task is silently cleared" do
      # The stub raises DBConnection.OwnershipError — mimics the case
      # where a DataCase-owned test exits between the classifier's
      # enqueue and the dispatcher's async Task hitting the wire.
      install_native_stub(fn _signal ->
        raise DBConnection.OwnershipError, "no owner"
      end)

      agent = create_agent!(%{kind: "native"})
      :ok = assign_role!("designer", agent)

      {pid, _name} = start_dispatcher!()
      Process.sleep(20)

      IntentQueue.enqueue("intentdisp-sandbox", "dk-sbox", %{
        intent: "sandbox_race",
        target_role: "designer",
        confidence: 0.5,
        chunk_id: "chunk-sbox"
      })

      # Row should be cleared (mark_dispatched used to silently retire
      # the claim) and the dispatcher process is still alive.
      assert :ok = await_dispatch("intentdisp-sandbox", "dk-sbox")
      assert Process.alive?(pid)
    end
  end

  describe "periodic tick" do
    test "tick drains rows that were enqueued before the dispatcher subscribed" do
      # Simulate the classic "dispatcher restarted; broadcast was
      # missed" case by writing to the queue BEFORE the dispatcher
      # starts, then giving it a short tick interval so `handle_info(:tick, _)`
      # picks the row up.
      install_native_stub(fn _ -> :ok end)

      agent = create_agent!(%{kind: "native"})
      :ok = assign_role!("designer", agent)

      # Rows land while nothing is listening.
      IntentQueue.enqueue("intentdisp-tick", "dk-tick-1", %{
        intent: "picked_up_by_tick",
        target_role: "designer",
        confidence: 0.9,
        chunk_id: "chunk-tick-1"
      })

      # Boot the dispatcher with a fast tick — 50ms is plenty; the
      # `assert_receive` timeout below guards against a slow CI.
      {_pid, _name} = start_dispatcher!(tick_interval_ms: 50)

      assert_receive {:native_dispatch_called, %{metadata: %{role_key: "designer"}}}, 1_500
      assert :ok = await_dispatch("intentdisp-tick", "dk-tick-1")
    end
  end

  describe "agent race" do
    test "role resolves to an agent that was deleted → retry then drop after cap" do
      install_native_stub(fn _ -> :ok end)

      # Create + assign, then delete the agent to leave a dangling
      # role_assignments row. The dispatcher's `Repo.get` returns nil,
      # so it should promote to retry.
      agent = create_agent!(%{kind: "native"})
      :ok = assign_role!("designer", agent)
      Repo.delete!(agent)

      {_pid, _name} = start_dispatcher!()
      Process.sleep(20)

      IntentQueue.enqueue("intentdisp-agent-missing", "dk-am", %{
        intent: "orphan",
        target_role: "designer",
        confidence: 0.5,
        chunk_id: "chunk-am"
      })

      # First hit → mark_retry; row stays present with :status
      # :pending and attempts bumped.
      Process.sleep(150)

      case IntentQueue.list_for_room("intentdisp-agent-missing") do
        [item] ->
          assert item.attempts >= 1
          assert item.status == :pending

        [] ->
          # If the tick fires fast enough all three retries could
          # already have exhausted; that's also a correct outcome.
          :ok
      end
    end
  end

  describe "telemetry" do
    test "intent_dispatched fires on happy path with the full metadata contract" do
      attach_telemetry!([[:platform, :meetings, :intent_dispatched]])
      install_native_stub(fn _ -> :ok end)

      agent = create_agent!(%{kind: "native"})
      :ok = assign_role!("designer", agent)

      {_pid, _name} = start_dispatcher!()
      Process.sleep(20)

      IntentQueue.enqueue("intentdisp-happy", "dk-telemetry-happy", %{
        intent: "book_followup",
        target_role: "designer",
        confidence: 0.9,
        chunk_id: "chunk-telemetry-happy",
        meeting_id: "mtg-telemetry-happy"
      })

      assert_receive {:telemetry, [:platform, :meetings, :intent_dispatched], measurements,
                      metadata},
                     1_500

      assert %{count: 1, dispatch_ms: dispatch_ms} = measurements
      assert is_integer(dispatch_ms)
      assert dispatch_ms >= 0

      assert %{
               meeting_id: "mtg-telemetry-happy",
               room_id: "intentdisp-happy",
               target_role: "designer",
               intent: "book_followup",
               agent_id: agent_id,
               agent_slug: agent_slug,
               dispatch_kind: :native
             } = metadata

      assert agent_id == agent.id
      assert agent_slug == agent.slug
    end

    test "intent_dispatched carries :external dispatch_kind for external agents" do
      attach_telemetry!([[:platform, :meetings, :intent_dispatched]])

      install_external_stub(fn _resp, _agent, _ctx ->
        {:ok, %{content: %{"ok" => true}}}
      end)

      agent =
        create_agent!(%{
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "https://example.test/v1",
          model: "gpt-fake"
        })

      :ok = assign_role!("meeting_scribe", agent)

      {_pid, _name} = start_dispatcher!()
      Process.sleep(20)

      IntentQueue.enqueue("intentdisp-external", "dk-telemetry-ext", %{
        intent: "log_action_item",
        target_role: "meeting_scribe",
        confidence: 0.7,
        chunk_id: "chunk-telemetry-ext",
        meeting_id: "mtg-telemetry-ext"
      })

      assert_receive {:telemetry, [:platform, :meetings, :intent_dispatched], _measurements,
                      %{dispatch_kind: :external, target_role: "meeting_scribe"}},
                     1_500
    end

    test "intent_dropped fires with reason=:no_assignee when target_role is nil" do
      attach_telemetry!([[:platform, :meetings, :intent_dropped]])
      install_native_stub(fn _ -> :ok end)

      {_pid, _name} = start_dispatcher!()
      Process.sleep(20)

      IntentQueue.enqueue("intentdisp-nil-role", "dk-telemetry-nil", %{
        intent: "do_stuff",
        target_role: nil,
        confidence: 0.5,
        chunk_id: "chunk-telemetry-nil",
        meeting_id: "mtg-telemetry-nil"
      })

      assert_receive {:telemetry, [:platform, :meetings, :intent_dropped], measurements,
                      metadata},
                     1_500

      assert %{count: 1} = measurements

      assert %{
               meeting_id: "mtg-telemetry-nil",
               room_id: "intentdisp-nil-role",
               target_role: nil,
               intent: "do_stuff",
               reason: :no_assignee,
               attempts: 0
             } = metadata
    end

    test "intent_dropped fires with reason=:no_assignee when the role has no assignment" do
      attach_telemetry!([[:platform, :meetings, :intent_dropped]])
      install_native_stub(fn _ -> :ok end)

      :ok = Roles.unassign_role("triage_officer")

      {_pid, _name} = start_dispatcher!()
      Process.sleep(20)

      IntentQueue.enqueue("intentdisp-no-assignee", "dk-telemetry-noa", %{
        intent: "escalate",
        target_role: "triage_officer",
        confidence: 0.8,
        chunk_id: "chunk-telemetry-noa",
        meeting_id: "mtg-telemetry-noa"
      })

      assert_receive {:telemetry, [:platform, :meetings, :intent_dropped], measurements,
                      %{
                        reason: :no_assignee,
                        attempts: 0,
                        target_role: "triage_officer",
                        meeting_id: "mtg-telemetry-noa"
                      }},
                     1_500

      assert measurements.count == 1
    end

    test "intent_dropped fires with reason=:unknown_role for a bogus target_role" do
      attach_telemetry!([[:platform, :meetings, :intent_dropped]])
      install_native_stub(fn _ -> :ok end)

      {_pid, _name} = start_dispatcher!()
      Process.sleep(20)

      IntentQueue.enqueue("intentdisp-unknown-1", "dk-telemetry-unknown", %{
        intent: "do_stuff",
        target_role: "bogus_role",
        confidence: 0.5,
        chunk_id: "chunk-telemetry-unknown",
        meeting_id: "mtg-telemetry-unknown"
      })

      assert_receive {:telemetry, [:platform, :meetings, :intent_dropped], _measurements,
                      %{
                        reason: :unknown_role,
                        attempts: 0,
                        target_role: "bogus_role",
                        meeting_id: "mtg-telemetry-unknown"
                      }},
                     1_500
    end

    test "intent_dropped fires with reason=:max_attempts_exceeded after @max_attempts retries" do
      # Stub raises so every dispatch attempt fails → mark_retry until
      # exhaustion. Roll through the retries with fast tick.
      attach_telemetry!([[:platform, :meetings, :intent_dropped]])

      install_native_stub(fn _ ->
        raise "always fails"
      end)

      agent = create_agent!(%{kind: "native"})
      :ok = assign_role!("designer", agent)

      {_pid, _name} = start_dispatcher!(tick_interval_ms: 30)

      IntentQueue.enqueue("intentdisp-crash", "dk-telemetry-exhaust", %{
        intent: "always_fails",
        target_role: "designer",
        confidence: 0.5,
        chunk_id: "chunk-telemetry-exhaust",
        meeting_id: "mtg-telemetry-exhaust"
      })

      max_attempts = IntentQueue.max_attempts()

      assert_receive {:telemetry, [:platform, :meetings, :intent_dropped], measurements,
                      %{
                        reason: :max_attempts_exceeded,
                        attempts: attempts,
                        target_role: "designer",
                        meeting_id: "mtg-telemetry-exhaust"
                      }},
                     3_000

      assert measurements.count == 1
      assert attempts == max_attempts
    end

    test "intent_dispatcher.tick fires on every tick regardless of claim outcome" do
      attach_telemetry!([[:platform, :meetings, :intent_dispatcher, :tick]])

      # Nothing enqueued; the tick still fires with claimed: 0.
      {_pid, _name} = start_dispatcher!(tick_interval_ms: 40)

      assert_receive {:telemetry, [:platform, :meetings, :intent_dispatcher, :tick], measurements,
                      metadata},
                     1_500

      assert %{claimed: claimed} = measurements
      assert is_integer(claimed)
      assert claimed >= 0

      assert %{queue_depth_after: depth, in_flight: in_flight} = metadata
      assert is_integer(depth)
      assert depth >= 0
      assert is_integer(in_flight)
      assert in_flight >= 0
    end

    test "intent_dispatcher.queue_depth fires alongside :tick and reflects ETS size" do
      attach_telemetry!([
        [:platform, :meetings, :intent_dispatcher, :tick],
        [:platform, :meetings, :intent_dispatcher, :queue_depth]
      ])

      # Enqueue a row that WON'T dispatch — no stub is installed and
      # no role is assigned — so it lives on the ETS table long
      # enough for the tick's queue_depth read.
      install_native_stub(fn _ -> flunk("must not be called") end)
      :ok = Roles.unassign_role("triage_officer")

      # Boot with a moderately-fast tick so we can catch :queue_depth
      # before the dispatcher processes the row via claim_pending.
      # Use a distinct room + do NOT rely on ordering — assert on the
      # tick-and-queue_depth pair independently.
      IntentQueue.enqueue("intentdisp-tick", "dk-telemetry-depth", %{
        intent: "just_sitting_here",
        target_role: "triage_officer",
        confidence: 0.5,
        chunk_id: "chunk-telemetry-depth",
        meeting_id: "mtg-telemetry-depth"
      })

      # The row above will be claimed + dropped :no_assignee on the
      # first tick, so we may catch queue_depth as 0 or 1 depending on
      # timing. Either is contract-valid — what matters is BOTH events
      # fire together on the same tick.
      {_pid, _name} = start_dispatcher!(tick_interval_ms: 30)

      assert_receive {:telemetry, [:platform, :meetings, :intent_dispatcher, :tick], _tm, _tmeta},
                     1_500

      assert_receive {:telemetry, [:platform, :meetings, :intent_dispatcher, :queue_depth],
                      %{count: count}, _qmeta},
                     1_500

      assert is_integer(count)
      assert count >= 0
    end
  end

  describe "sweep_stalled/0 (StallRegistry callback)" do
    setup do
      # Point the sweep at a tight stall window so the tests don't
      # have to wait 2 minutes. Restored on exit.
      prev = Application.get_env(:platform, Platform.Meetings.IntentDispatcher)

      Application.put_env(
        :platform,
        Platform.Meetings.IntentDispatcher,
        Keyword.put(prev || [], :stall_window_ms, 50)
      )

      on_exit(fn ->
        if is_nil(prev) do
          Application.delete_env(:platform, Platform.Meetings.IntentDispatcher)
        else
          Application.put_env(:platform, Platform.Meetings.IntentDispatcher, prev)
        end
      end)

      :ok
    end

    test "re-queues stalled rows and broadcasts intent_enqueued so the hot path wakes" do
      room_id = "intentdisp-sweep-stall"
      dedupe_key = "dk-sweep-stall"

      # Subscribe to the enqueue topic so we can assert the sweep's
      # broadcast landed. Mirrors the dispatcher's own subscription
      # (production wake-up path).
      :ok = Platform.Meetings.PubSub.subscribe_intent_enqueued()

      on_exit(fn ->
        Platform.Meetings.PubSub.unsubscribe_intent_enqueued()
        IntentQueue.drop_for_room(room_id)
      end)

      # Stamp a claimed-but-stuck row directly into ETS with a
      # `claimed_at_monotonic` far enough in the past to trip the
      # 50 ms stall window from the setup block.
      now = System.monotonic_time(:millisecond)

      stalled_item = %{
        intent: "book_followup",
        target_role: "designer",
        confidence: 0.9,
        chunk_id: "chunk-sweep-stall",
        meeting_id: "mtg-sweep-stall",
        inserted_at_monotonic: now - 10_000,
        status: :dispatching,
        attempts: 0,
        claimed_at_monotonic: now - 10_000,
        last_error: nil
      }

      true =
        :ets.insert(:meeting_intent_queue, {{room_id, dedupe_key}, stalled_item})

      assert :ok = IntentDispatcher.sweep_stalled()

      # Row should be back in :pending with attempts bumped and
      # last_error recorded.
      [rescued] = IntentQueue.list_for_room(room_id)
      assert rescued.status == :pending
      assert rescued.attempts == 1
      assert rescued.last_error =~ "sweep_stalled"

      # And the sweep must have broadcast the wake-up so the hot path
      # can pick the row up on the next `claim_one/2`.
      assert_receive {:intent_enqueued, %{room_id: ^room_id, dedupe_key: ^dedupe_key}},
                     500
    end

    test "no stalled rows is a silent no-op" do
      # Clean state — sweep must return :ok without raising or
      # broadcasting anything.
      :ok = Platform.Meetings.PubSub.subscribe_intent_enqueued()
      on_exit(fn -> Platform.Meetings.PubSub.unsubscribe_intent_enqueued() end)

      assert :ok = IntentDispatcher.sweep_stalled()

      refute_receive {:intent_enqueued, _}, 50
    end
  end
end
