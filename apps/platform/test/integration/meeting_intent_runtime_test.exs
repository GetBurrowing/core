defmodule Platform.Integration.MeetingIntentRuntimeTest do
  @moduledoc """
  End-to-end integration test for the Meeting Producer runtime
  pipeline (task 019f2452 stage 5). Exercises the full path a real
  meeting takes:

      Meetings.append_segment/2
        → PubSub.broadcast_transcript_chunk/2
        → IntentClassifier.handle_info/2
        → resolve_prompt (fallback branch — no seeded template row)
        → provider_module.chat/3  (stubbed)
        → parse_content/2
        → IntentQueue.enqueue/3
        → :telemetry.execute([:platform, :meetings, :intent_classified], …)

  Also exercises cleanup on `:meeting_finished` broadcast — the
  primary "belt" path where the classifier's PubSub subscriber walks
  the ETS table and drops all rows for the finished room. Rows for
  other rooms must survive untouched (the "braces" invariant).

  The provider is stubbed via the `provider_module` opt on
  `start_link/1` — same seam the unit test uses
  (`Platform.Meetings.IntentClassifierTest`). No real Ollama call.

  ## Manual runtime verification note

  For reviewer sanity-check:

      iex -S mix
      Application.put_env(:platform, :meeting_producer_runtime_enabled, true)
      # ...seed a role assignee, start a classifier with a real Ollama...
      {:ok, t} = Platform.Meetings.ensure_transcript(%{room_id: "room-x"})
      Platform.Meetings.append_segment(t.id, %{
        participant_identity: "you", text: "we should follow up",
        start_time: 0, end_time: 1000
      })
      Platform.Meetings.IntentQueue.list_for_room("room-x")
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Meetings
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles

  @responsibility_key "meetings.intent_classify"
  @prompt_slug "meetings.intent_classify.v1"

  # ── Provider stub ─────────────────────────────────────────────────────────

  defmodule StubProvider do
    @moduledoc """
    Runs inside the classifier's own process. Reads a fun off the
    process dictionary key `:intent_classifier_stub_fun` and calls it
    with `(credentials, messages, opts)`. If nothing is planted, we
    return `{:error, :no_stub_configured}` — surfaces as
    `intent_classifier :model_error` telemetry without crashing.
    """

    def chat(credentials, messages, opts) do
      case Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Test rooms used across cases — collected here so `setup` can wipe
  # any cross-test contamination from the shared ETS table. IntentQueue
  # is meeting-lifetime state that outlives each test's Ecto sandbox,
  # so we sweep by room_id both before and after.
  @rooms [
    "room-e2e-happy",
    "room-cleanup-target",
    "room-untouched",
    "room-flag-off-e2e"
  ]

  setup do
    # Flag ON is the whole point of this suite — we want the runtime
    # to actually fire. Individual tests can override this locally
    # (test 3 flips it OFF mid-flight to prove the guard).
    prior_flag = Application.get_env(:platform, :meeting_producer_runtime_enabled, false)
    Application.put_env(:platform, :meeting_producer_runtime_enabled, true)

    # Sweep ETS on both edges. IntentQueue is a `:public` `:named_table`
    # started in `Platform.Application`'s child list, so tests share
    # the same table — hence the belt-and-braces cleanup.
    Enum.each(@rooms, &IntentQueue.drop_for_room/1)

    on_exit(fn ->
      Application.put_env(:platform, :meeting_producer_runtime_enabled, prior_flag)
      Enum.each(@rooms, &IntentQueue.drop_for_room/1)
    end)

    # Boot a per-test classifier so the sandbox owns the process +
    # can be shut down cleanly by `start_supervised!`. The suite-wide
    # classifier is gated off in `config/test.exs` via
    # `:start_meeting_intent_classifier`, so this is the only one
    # subscribed to `meeting:transcript_chunk`.
    classifier_name = :"intent_classifier_e2e_#{System.unique_integer([:positive])}"

    {:ok, classifier_pid} =
      start_supervised({IntentClassifier, name: classifier_name, provider_module: StubProvider})

    # Seed an assignee via `Roles.set_override/2`. The closed roster
    # has no "producer" role yet; the responsibility-override table
    # is the escape hatch the unit tests use for the same reason.
    # No `on_exit` cleanup for this — the DataCase sandbox rolls back
    # `responsibility_overrides` writes automatically at test end, and
    # doing DB work in on_exit fires AFTER the sandbox owner exits
    # (checkout error).
    agent = create_agent!(%{slug: "e2e-intent-agent-#{System.unique_integer([:positive])}"})
    {:ok, _} = Roles.set_override(@responsibility_key, agent.id)

    # No prompt template row seeded upstream (task 019f2451-b627 owns
    # it, out-of-scope for stage 5). Nuke any incidental row so
    # `render_template/2` returns `{:error, :not_found}` cleanly and
    # the classifier walks the inline fallback path.
    case PromptTemplates.get_template_by_slug(@prompt_slug) do
      nil -> :ok
      template -> PromptTemplates.delete_template(template)
    end

    {:ok, classifier_pid: classifier_pid, classifier_name: classifier_name, agent: agent}
  end

  defp create_agent!(overrides) do
    attrs =
      Map.merge(
        %{
          slug: "e2e-agent-#{System.unique_integer([:positive])}",
          name: "E2E Intent Agent",
          status: "active"
        },
        overrides
      )

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  # Plant the stub fun in the classifier's own process dictionary via
  # the test-only `:__test_plant_stub` message the module registers
  # under `Mix.env() == :test`. Same handshake shape the unit test
  # uses — send `{:__test_plant_stub, from, ref, fun}`, wait for
  # `{ref, :ok}` back. Blocks until the plant is confirmed so the
  # very next PubSub broadcast is guaranteed to see it.
  defp plant_stub_fun(pid, fun) do
    ref = make_ref()
    send(pid, {:__test_plant_stub, self(), ref, fun})

    receive do
      {^ref, :ok} -> :ok
    after
      500 -> flunk("classifier did not ack stub fun plant")
    end
  end

  defp attach_intent_classified_recorder!(tag) do
    handler_id = "intent-classified-e2e-#{tag}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:platform, :meetings, :intent_classified],
      fn _event, measurements, metadata, pid ->
        send(pid, {tag, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp attach_skipped_recorder!(tag) do
    handler_id = "intent-classifier-skipped-e2e-#{tag}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:platform, :meetings, :intent_classifier, :skipped],
      fn _event, measurements, metadata, pid ->
        send(pid, {tag, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # ── Test 1: chunk arrival → queue entry ───────────────────────────────────

  describe "chunk arrival → classifier → queue" do
    test "append_segment/2 flows all the way to a queued IntentQueue row",
         %{classifier_pid: classifier_pid} do
      attach_intent_classified_recorder!(:classified)

      plant_stub_fun(classifier_pid, fn _creds, _messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "schedule_followup",
               "target_role" => "scheduler",
               "confidence" => 0.87
             })
         }}
      end)

      # Real transcript row so append_segment/2 has something to
      # update — this is what a real LiveKit-driven meeting hits.
      {:ok, transcript} = Meetings.ensure_transcript(%{room_id: "room-e2e-happy"})

      {:ok, _updated} =
        Meetings.append_segment(transcript.id, %{
          participant_identity: "user-1",
          text: "let's schedule a follow-up meeting Friday",
          start_time: 0,
          end_time: 1000
        })

      # Terminal telemetry fires once the classifier finishes the
      # prompt-render + provider-call + parse + enqueue chain.
      assert_receive {:classified, %{count: 1},
                      %{
                        room_id: "room-e2e-happy",
                        intent: "schedule_followup",
                        target_role: "scheduler",
                        confidence: 0.87,
                        dedupe_key_hit_or_new: :inserted
                      }},
                     500

      # And the row is observable in the queue.
      entries = IntentQueue.list_for_room("room-e2e-happy")
      assert length(entries) == 1
      [entry] = entries
      assert entry.intent == "schedule_followup"
      assert entry.target_role == "scheduler"
      assert entry.confidence == 0.87
      # `chunk_id` falls back to transcript_id when the segment lacks
      # its own id — `append_segment/2` doesn't stamp one.
      assert entry.chunk_id == transcript.id
    end
  end

  # ── Test 2: cleanup on meeting:finished ───────────────────────────────────

  describe "meeting:finished broadcast cleanup" do
    test "drops all rows for the finished room, leaves other rooms alone" do
      now = System.monotonic_time()

      # Pre-populate three entries under the target room with distinct
      # dedupe_keys so `:ets.insert_new/2` accepts all three.
      Enum.each(1..3, fn n ->
        {:ok, :inserted} =
          IntentQueue.enqueue(
            "room-cleanup-target",
            "dedupe-#{n}",
            %{
              intent: "schedule_followup",
              target_role: "scheduler",
              confidence: 0.5,
              chunk_id: "chunk-#{n}",
              meeting_id: nil,
              inserted_at_monotonic: now
            }
          )
      end)

      # One survivor row in an unrelated room — the invariant we care
      # about is that finish-cleanup is scoped to the finished room_id.
      {:ok, :inserted} =
        IntentQueue.enqueue(
          "room-untouched",
          "dedupe-untouched",
          %{
            intent: "assign_owner",
            target_role: "scribe",
            confidence: 0.9,
            chunk_id: "chunk-untouched",
            meeting_id: nil,
            inserted_at_monotonic: now
          }
        )

      # Sanity: pre-state.
      assert length(IntentQueue.list_for_room("room-cleanup-target")) == 3
      assert length(IntentQueue.list_for_room("room-untouched")) == 1

      # Broadcast the finished event. The IntentQueue GenServer is
      # subscribed to `meeting:finished` and reacts by dropping every
      # row keyed on `room-cleanup-target`.
      MeetingsPubSub.broadcast_meeting_finished("room-cleanup-target", %{
        transcript_id: "t1",
        room_id: "room-cleanup-target",
        space_id: "s1"
      })

      # PubSub delivery is async; sync on the state change we care
      # about (the drop). A short wait_for is more honest than
      # `Process.sleep/1` because it exits early on success.
      wait_for(fn -> IntentQueue.list_for_room("room-cleanup-target") == [] end, 500)

      assert IntentQueue.list_for_room("room-cleanup-target") == []
      # Braces invariant: the other room is untouched.
      assert length(IntentQueue.list_for_room("room-untouched")) == 1
    end
  end

  # ── Test 3: flag-off end-to-end (kill-switch) ─────────────────────────────

  describe "runtime flag off — end-to-end short-circuit" do
    setup do
      # Local override: this describe block runs with the runtime
      # kill-switch flipped OFF. The outer `setup` restores it on exit.
      Application.put_env(:platform, :meeting_producer_runtime_enabled, false)
      :ok
    end

    test "chunk fires PubSub but classifier drops it — no queue row, no terminal telemetry",
         %{classifier_pid: classifier_pid} do
      attach_skipped_recorder!(:skipped)
      attach_intent_classified_recorder!(:classified)

      # Even if the provider were called it would classify successfully;
      # the assertion is that guard 1 short-circuits before we ever
      # reach the provider.
      plant_stub_fun(classifier_pid, fn _c, _m, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "should_not_land",
               "target_role" => "scheduler",
               "confidence" => 0.99
             })
         }}
      end)

      {:ok, transcript} = Meetings.ensure_transcript(%{room_id: "room-flag-off-e2e"})

      {:ok, _} =
        Meetings.append_segment(transcript.id, %{
          participant_identity: "user-1",
          text: "we should absolutely schedule something",
          start_time: 0,
          end_time: 1000
        })

      # `:skipped` with `reason: :flag_off` is the proof the guard
      # fired instead of the pipeline. Terminal telemetry MUST NOT
      # arrive (we assert its absence below).
      assert_receive {:skipped, %{count: 1}, %{reason: :flag_off, room_id: "room-flag-off-e2e"}},
                     500

      refute_receive {:classified, _, _}, 200
      assert IntentQueue.list_for_room("room-flag-off-e2e") == []
    end
  end

  # ── Utilities ─────────────────────────────────────────────────────────────

  # Poll a predicate at ~10ms cadence up to `timeout_ms`. Returns
  # `:ok` on first truthy result, raises on timeout. Preferred over
  # a fixed `Process.sleep/1` — exits early on success and gives a
  # clean failure mode.
  defp wait_for(fun, timeout_ms) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("wait_for timed out")

      true ->
        Process.sleep(10)
        do_wait_for(fun, deadline)
    end
  end
end
