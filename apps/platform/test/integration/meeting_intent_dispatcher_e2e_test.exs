defmodule Platform.Integration.MeetingIntentDispatcherE2ETest do
  @moduledoc """
  End-to-end integration test for the FULL Meeting Producer runtime
  pipeline (task 019f2452 stage 5). Extends the classifier's e2e
  coverage (`Platform.Integration.MeetingIntentRuntimeTest`, stage 5's
  sibling for stage 1) past the queue-insert assertion — this one
  walks the last two hops end-to-end:

      Meetings.append_segment/2
        → PubSub.broadcast_transcript_chunk/2
        → IntentClassifier.handle_info/2       (stubbed provider)
        → IntentQueue.enqueue/3
        → PubSub.broadcast_intent_enqueued/1
        → IntentDispatcher.handle_info/2       (per-case instance)
        → dispatch seam (native OR external — stubbed)
        → IntentQueue.mark_dispatched/2        (row disappears)
        → :telemetry.execute([:platform, :meetings, :intent_dispatched], …)

  Everything runs on a real BEAM node under a shared-mode DataCase
  sandbox — no mocks between classifier and dispatcher, just the two
  boundaries where an LLM call and an outbound dispatch would otherwise
  cross the wire. Those two ARE stubbed via the seams the unit tests
  already exercise:

    * classifier provider — `provider_module:` opt on `start_link/1`
      (mirrors `Platform.Integration.MeetingIntentRuntimeTest`)
    * dispatcher native / external — Application env-based MFA
      swap (mirrors `Platform.Meetings.IntentDispatcherTest`)

  ## Cases

    1. **Happy path, external agent** — classifier LLM emits
       `target_role: "designer"`, an external agent is assigned to
       that role, dispatcher routes to the external seam. Asserts the
       dispatch received a synthetic Responsibility + the queue row
       disappeared + `[:platform, :meetings, :intent_dispatched]` fired
       with `dispatch_kind: :external`.

    2. **Happy path, native agent** — same shape but with a native
       agent on `target_role: "historian"`. Asserts the native
       dispatch seam received an AgentResponder-shaped signal and the
       terminal telemetry carried `dispatch_kind: :native`.

    3. **Cross-room isolation** — two parallel classifier→dispatcher
       flows on distinct rooms both dispatch cleanly, with
       `mark_dispatched` scoped to the emitting room (the "braces"
       invariant for the dispatcher: sibling rooms' queue rows are
       untouched).

  ## Sandbox note

  DataCase runs `Sandbox.mode(Repo, {:shared, self()})` for `async: false`
  tests, so per-case `start_supervised!` children see the test's Repo
  connection transparently. That's why we don't need to hand-thread
  `Sandbox.allow/3` for every child — the `{:shared, self()}` mode
  already grants ambient access on this node. `Task.Supervisor.async_nolink`
  workers spawned by the dispatcher inherit through the same mode.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Meetings
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentDispatcher
  alias Platform.Meetings.IntentQueue
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles

  # The classifier walks `Roles.assignee_for/1` on this responsibility
  # key to find its LLM-owning agent. Independent of the `target_role`
  # the LLM later emits (which resolves via `Roles.agent_id_for_role/1`
  # inside the dispatcher).
  @responsibility_key "meetings.intent_classify"
  @prompt_slug "meetings.intent_classify.v1"

  # Rooms swept across all cases so a stray ETS row from a prior run
  # (IntentQueue is a `:public :named_table` that outlives the sandbox
  # transaction) can't leak between tests.
  @rooms [
    "e2e-dispatch-external",
    "e2e-dispatch-native",
    "e2e-dispatch-room-a",
    "e2e-dispatch-room-b"
  ]

  # ── Provider stub — same shape as the classifier's e2e ─────────────────────

  defmodule StubProvider do
    @moduledoc """
    Runs inside the classifier's own process. Reads a fun off the
    process dictionary key `:intent_classifier_stub_fun` and calls it
    with `(credentials, messages, opts)`. Mirrors
    `Platform.Integration.MeetingIntentRuntimeTest.StubProvider` — kept
    private to this suite so a change here can't accidentally shift
    behaviour of the sibling test.
    """

    def chat(credentials, messages, opts) do
      case Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end
  end

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup do
    # Bump this module's log level to :info so the dispatcher's
    # `unknown target_role` log doesn't get swallowed on a debug-off
    # CI (belt-and-braces; none of these cases exercise it, but sibling
    # tests running under the same setup can rely on it).
    Logger.put_module_level(Platform.Meetings.IntentDispatcher, :info)

    # Nuke any stray ETS rows before the case runs. The IntentQueue
    # table is `:public :named_table` and started under the app tree,
    # so it survives the DB transaction rollback that DataCase runs.
    Enum.each(@rooms, &IntentQueue.drop_for_room/1)

    # Boot a per-case classifier + dispatcher. Unique names keep them
    # from clashing with any app-tree singletons (both are gated OFF
    # in `config/test.exs`).
    classifier_name = :"intent_classifier_e2e_#{System.unique_integer([:positive])}"
    dispatcher_name = :"intent_dispatcher_e2e_#{System.unique_integer([:positive])}"

    {:ok, classifier_pid} =
      start_supervised({IntentClassifier, name: classifier_name, provider_module: StubProvider})

    # Long tick — the hot PubSub path is what these cases exercise;
    # we don't want a periodic tick claiming rows out from under the
    # notify handler and muddying the assertions.
    {:ok, dispatcher_pid} =
      start_supervised({IntentDispatcher, name: dispatcher_name, tick_interval_ms: 60_000})

    # Seed the classifier's responsibility assignee. The closed roster
    # has no `meetings.intent_classify` role, so we use the override
    # escape hatch — same pattern the classifier e2e uses.
    classifier_agent =
      create_agent!(%{
        slug: "e2e-dispatch-classifier-#{System.unique_integer([:positive])}",
        kind: "native"
      })

    {:ok, _} = Roles.set_override(@responsibility_key, classifier_agent.id)

    # No prompt template row for the classifier — force the inline
    # fallback path, matches the sibling e2e.
    case PromptTemplates.get_template_by_slug(@prompt_slug) do
      nil -> :ok
      template -> PromptTemplates.delete_template(template)
    end

    on_exit(fn ->
      Logger.delete_module_level(Platform.Meetings.IntentDispatcher)
      Application.delete_env(:platform, :meetings_intent_dispatcher_native_dispatcher)
      Application.delete_env(:platform, :meetings_intent_dispatcher_external_dispatcher)
      Enum.each(@rooms, &IntentQueue.drop_for_room/1)
    end)

    {:ok,
     classifier_pid: classifier_pid,
     classifier_name: classifier_name,
     dispatcher_pid: dispatcher_pid,
     dispatcher_name: dispatcher_name}
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp create_agent!(overrides) do
    attrs =
      Map.merge(
        %{
          slug: "e2e-dispatch-agent-#{System.unique_integer([:positive])}",
          name: "E2E Dispatch Test Agent",
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
    # Idempotent — role_assignments.role_key has a unique index, so
    # if a sibling case left a row we clear it first.
    :ok = Roles.unassign_role(role_key)
    {:ok, _} = Roles.assign_role(role_key, id)
    :ok
  end

  # Plant the provider stub fun in the classifier's process dictionary
  # via its test-only handshake message. Matches the shape used in
  # `Platform.Meetings.IntentClassifierTest` and the classifier's e2e.
  defp plant_stub_fun(classifier_pid, fun) do
    ref = make_ref()
    send(classifier_pid, {:__test_plant_stub, self(), ref, fun})

    receive do
      {^ref, :ok} -> :ok
    after
      500 -> flunk("classifier did not ack stub fun plant")
    end
  end

  # Install a stub for the dispatcher's native / external dispatch
  # surfaces. The stub forwards its call to the parent test process
  # and returns whatever `fun` yields. Mirrors
  # `Platform.Meetings.IntentDispatcherTest.install_native_stub/1`.
  defp install_native_stub(fun) when is_function(fun, 1) do
    Application.put_env(
      :platform,
      :meetings_intent_dispatcher_native_dispatcher,
      {__MODULE__.Stub, :native_dispatch}
    )

    :persistent_term.put({__MODULE__, :native_stub}, {self(), fun})
    :ok
  end

  defp install_external_stub(fun) when is_function(fun, 3) do
    Application.put_env(
      :platform,
      :meetings_intent_dispatcher_external_dispatcher,
      {__MODULE__.Stub, :external_dispatch}
    )

    :persistent_term.put({__MODULE__, :external_stub}, {self(), fun})
    :ok
  end

  defp attach_telemetry!(events) when is_list(events) do
    handler_id = "intent-dispatcher-e2e-#{System.unique_integer([:positive])}"
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

  # Build the classifier's happy-path response — the raw string content
  # the provider returns is parsed by the classifier as JSON.
  defp classifier_response(intent, target_role, confidence) do
    {:ok,
     %{
       content:
         Jason.encode!(%{
           "intent" => intent,
           "target_role" => target_role,
           "confidence" => confidence
         })
     }}
  end

  defp append_transcript_segment!(room_id, participant, text) do
    {:ok, transcript} = Meetings.ensure_transcript(%{room_id: room_id})

    {:ok, updated} =
      Meetings.append_segment(transcript.id, %{
        participant_identity: participant,
        text: text,
        start_time: 0,
        end_time: 1000
      })

    updated
  end

  # ── Stub module — addressable via Application env MFA. Reads the
  # `{pid, fun}` out of `:persistent_term`, forwards the payload to
  # the parent, then invokes fun for the return value.
  # ───────────────────────────────────────────────────────────────────────────

  defmodule Stub do
    @moduledoc false

    def native_dispatch(signal) do
      case :persistent_term.get(
             {Platform.Integration.MeetingIntentDispatcherE2ETest, :native_stub},
             nil
           ) do
        {pid, fun} ->
          send(pid, {:native_dispatch_called, signal})
          fun.(signal)

        nil ->
          :ok
      end
    end

    def external_dispatch(responsibility, agent, context) do
      case :persistent_term.get(
             {Platform.Integration.MeetingIntentDispatcherE2ETest, :external_stub},
             nil
           ) do
        {pid, fun} ->
          send(pid, {:external_dispatch_called, responsibility, agent, context})
          fun.(responsibility, agent, context)

        nil ->
          {:ok, %{content: %{}}}
      end
    end
  end

  # ── Test 1: happy path (external agent kind) ──────────────────────────────

  describe "happy path — external agent" do
    test "classifier → queue → dispatcher → external seam → mark_dispatched",
         %{classifier_pid: classifier_pid} do
      attach_telemetry!([[:platform, :meetings, :intent_dispatched]])

      # Stub the classifier's LLM to emit target_role=designer.
      plant_stub_fun(classifier_pid, fn _c, _m, _o ->
        classifier_response("design_task", "designer", 0.92)
      end)

      # Stub the dispatcher's external dispatch surface — capture the
      # full (responsibility, agent, context) payload.
      install_external_stub(fn _resp, _agent, _ctx ->
        {:ok, %{content: %{"ack" => true}}}
      end)

      # Seed the target agent + role assignment. Kind: external so the
      # dispatcher routes via the external seam.
      target_agent =
        create_agent!(%{
          slug: "e2e-dispatch-designer-external-#{System.unique_integer([:positive])}",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "https://example.test/v1",
          model: "gpt-fake"
        })

      :ok = assign_role!("designer", target_agent)

      # Kick off the pipeline. A single transcript segment triggers
      # the whole chain.
      _ =
        append_transcript_segment!(
          "e2e-dispatch-external",
          "user-1",
          "we should redesign the onboarding funnel"
        )

      # External seam received the dispatch.
      assert_receive {:external_dispatch_called, responsibility, agent, context}, 1_500

      assert %Platform.Responsibilities.Responsibility{
               key: "meetings.produce.designer",
               feature: "meetings",
               metadata: %{role_key: "designer", intent: "design_task"}
             } = responsibility

      assert %Agent{id: agent_id, kind: "external"} = agent
      assert agent_id == target_agent.id

      assert %{
               role_key: "designer",
               room_id: "e2e-dispatch-external",
               intent: "design_task",
               target_role: "designer",
               confidence: 0.92
             } = context

      # Terminal telemetry with dispatch_kind: :external.
      assert_receive {:telemetry, [:platform, :meetings, :intent_dispatched], measurements,
                      metadata},
                     1_500

      assert %{count: 1, dispatch_ms: dispatch_ms} = measurements
      assert is_integer(dispatch_ms) and dispatch_ms >= 0

      assert %{
               room_id: "e2e-dispatch-external",
               target_role: "designer",
               intent: "design_task",
               dispatch_kind: :external,
               agent_slug: agent_slug
             } = metadata

      assert agent_slug == target_agent.slug

      # Queue row disappeared (mark_dispatched deletes).
      assert IntentQueue.list_for_room("e2e-dispatch-external") == []
    end
  end

  # ── Test 2: happy path (native agent kind) ────────────────────────────────

  describe "happy path — native agent" do
    test "classifier → queue → dispatcher → native seam → mark_dispatched",
         %{classifier_pid: classifier_pid} do
      attach_telemetry!([[:platform, :meetings, :intent_dispatched]])

      plant_stub_fun(classifier_pid, fn _c, _m, _o ->
        classifier_response("record_decision", "historian", 0.85)
      end)

      install_native_stub(fn _signal -> :ok end)

      target_agent =
        create_agent!(%{
          slug: "e2e-dispatch-historian-native-#{System.unique_integer([:positive])}",
          kind: "native"
        })

      :ok = assign_role!("historian", target_agent)

      _ =
        append_transcript_segment!(
          "e2e-dispatch-native",
          "user-2",
          "let's record that we're going to ship weekly"
        )

      # Native seam receives an AgentResponder-shaped signal.
      assert_receive {:native_dispatch_called, signal}, 1_500

      assert %{
               reason: :system_event,
               metadata: %{
                 source: :meetings_intent_dispatcher,
                 role_key: "historian",
                 intent: "record_decision",
                 room_id: "e2e-dispatch-native",
                 agent_id: agent_id,
                 agent_slug: agent_slug
               }
             } = signal

      assert agent_id == target_agent.id
      assert agent_slug == target_agent.slug

      # Terminal telemetry with dispatch_kind: :native.
      assert_receive {:telemetry, [:platform, :meetings, :intent_dispatched], %{count: 1},
                      %{
                        room_id: "e2e-dispatch-native",
                        target_role: "historian",
                        intent: "record_decision",
                        dispatch_kind: :native
                      }},
                     1_500

      assert IntentQueue.list_for_room("e2e-dispatch-native") == []
    end
  end

  # ── Test 3: cross-room isolation ──────────────────────────────────────────

  describe "cross-room isolation" do
    test "two rooms dispatch in parallel — mark_dispatched scoped per room",
         %{classifier_pid: classifier_pid} do
      attach_telemetry!([[:platform, :meetings, :intent_dispatched]])

      # Both rooms drive the same target_role, so we only need one
      # role assignment. The dispatcher is a global singleton, so
      # concurrent enqueues on distinct rooms hit `claim_one/2`
      # under distinct `(room_id, dedupe_key)` keys — no cross-talk.
      plant_stub_fun(classifier_pid, fn _c, _m, _o ->
        classifier_response("schedule_followup", "meeting_scribe", 0.8)
      end)

      # Native stub so both dispatches share the same seam; the parent
      # test process differentiates by the signal's `room_id`.
      install_native_stub(fn _signal -> :ok end)

      target_agent =
        create_agent!(%{
          slug: "e2e-dispatch-scribe-shared-#{System.unique_integer([:positive])}",
          kind: "native"
        })

      :ok = assign_role!("meeting_scribe", target_agent)

      # Room A.
      _ =
        append_transcript_segment!(
          "e2e-dispatch-room-a",
          "user-a",
          "let's follow up on the roadmap next Friday"
        )

      # Room B (kicked off before room A's dispatch completes, so the
      # two flow through the queue + dispatcher concurrently).
      _ =
        append_transcript_segment!(
          "e2e-dispatch-room-b",
          "user-b",
          "we should schedule a follow-up on that item"
        )

      # Collect BOTH native dispatch invocations. Order isn't
      # guaranteed — they race through the classifier's serial
      # handle_info loop, then hit the dispatcher's async_nolink
      # workers in parallel. Assert on set-equality of the observed
      # room_ids.
      room_a = "e2e-dispatch-room-a"
      room_b = "e2e-dispatch-room-b"

      rooms_seen =
        for _ <- 1..2 do
          assert_receive {:native_dispatch_called, %{metadata: %{room_id: r}}}, 2_000
          r
        end

      assert Enum.sort(rooms_seen) == Enum.sort([room_a, room_b])

      # Both terminal telemetry events fire — same set-equality
      # invariant.
      dispatched_rooms =
        for _ <- 1..2 do
          assert_receive {:telemetry, [:platform, :meetings, :intent_dispatched], %{count: 1},
                          %{room_id: r, dispatch_kind: :native}},
                         2_000

          r
        end

      assert Enum.sort(dispatched_rooms) == Enum.sort([room_a, room_b])

      # And both rooms' queues are cleared — mark_dispatched scoped
      # per-room ("braces" invariant: neither dispatch touched the
      # sibling room's rows).
      assert IntentQueue.list_for_room(room_a) == []
      assert IntentQueue.list_for_room(room_b) == []
    end
  end
end
