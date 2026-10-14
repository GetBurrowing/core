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
        → IntentQueue.enqueue/2      (per MEETING, task 019f70b8)
        → :telemetry.execute([:platform, :meetings, :intent_classified], …)

  Task 019f70b8 stage 3 made this path meeting-keyed, which put a new
  link under test: `append_segment/2` resolves the chunk's
  `meeting_id` from the transcript's `space_id`. Before stage 3 that
  field was hardcoded nil and a room-keyed fallback queue absorbed the
  consequence; now a broken space→meeting link means the intent has
  nowhere to land, so this file drives the real chain — project →
  meeting → chat space → transcript → segment.

  Also exercises cleanup on `:meeting_finished` — the queue owner is
  per-meeting and subscribes to the broadcast, so the finished
  meeting's queue process (and its ETS table with it) goes away while
  another meeting's queue survives untouched.

  The provider is stubbed via the `provider_module` opt on
  `start_link/1` — same seam the unit test uses
  (`Platform.Meetings.IntentClassifierTest`). No real Ollama call.

  ## Manual runtime verification note

  For reviewer sanity-check:

      iex -S mix
      # ...seed a role assignee, start a classifier with a real Ollama...
      {:ok, t} = Platform.Meetings.ensure_transcript(%{room_id: "room-x"})
      Platform.Meetings.append_segment(t.id, %{
        participant_identity: "you", text: "we should follow up",
        start_time: 0, end_time: 1000
      })
      Platform.Meetings.IntentQueue.list(meeting_id)
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

  setup do
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

  # A real project → meeting → chat space chain. The meeting's
  # `chat_space_id` is what `append_segment/2` resolves the chunk's
  # meeting_id through, so a stubbed id here would test nothing.
  defp create_meeting!(name) do
    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "#{name} project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/meeting-intent-e2e"
      })

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})

    on_exit(fn -> IntentQueue.stop(meeting.id) end)

    meeting
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

  # ── Test 1: chunk arrival → queue entry ───────────────────────────────────

  describe "chunk arrival → classifier → queue" do
    test "append_segment/2 flows all the way to a queued intent row",
         %{classifier_pid: classifier_pid} do
      attach_intent_classified_recorder!(:classified)

      plant_stub_fun(classifier_pid, fn _creds, messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "schedule_followup",
               "target_role" => "scheduler",
               "confidence" => 0.87,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      meeting = create_meeting!("E2E Happy Meeting")

      # Real transcript row bound to the meeting's chat space — this is
      # what a real LiveKit-driven meeting hits, and the space is the
      # only path from a transcript back to its meeting.
      {:ok, transcript} =
        Meetings.ensure_transcript(%{
          room_id: "room-e2e-happy",
          space_id: meeting.chat_space_id
        })

      {:ok, updated} =
        Meetings.append_segment(transcript.id, %{
          participant_identity: "user-1",
          text: "let's schedule a follow-up meeting Friday",
          start_time: 0,
          end_time: 1000
        })

      # Terminal telemetry fires once the classifier finishes the
      # prompt-render + provider-call + parse + enqueue chain. The
      # meeting_id in the metadata proves the space→meeting resolution
      # happened in `append_segment/2`, not in the test.
      assert_receive {:classified, %{count: 1},
                      %{
                        room_id: "room-e2e-happy",
                        intent: "schedule_followup",
                        target_role: "scheduler",
                        confidence: 0.87,
                        dedupe_key_hit_or_new: :inserted,
                        meeting_id: meeting_id
                      }},
                     500

      assert meeting_id == meeting.id

      # And the row is observable in the MEETING's queue.
      entries = IntentQueue.list(meeting.id)
      assert length(entries) == 1
      [entry] = entries
      assert entry.classified_intent == "schedule_followup"
      assert entry.target_role == "scheduler"
      assert entry.confidence == 0.87
      assert entry.status == :queued
      # `append_segment/2` mints the segment id under the STRING key
      # "id" (task 01a06672), and that id is the chunk's key. Until task
      # 01a1265f the classifier read only `:id`, so this fell back to the
      # transcript id and every chunk of one transcript shared one key.
      [segment] = updated.segments
      assert is_binary(segment["id"])
      assert entry.transcript_chunk_id == segment["id"]
      refute entry.transcript_chunk_id == transcript.id
    end

    test "a transcript with no meeting behind it classifies but enqueues nowhere",
         %{classifier_pid: classifier_pid} do
      attach_intent_classified_recorder!(:orphan)

      plant_stub_fun(classifier_pid, fn _creds, messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "schedule_followup",
               "target_role" => "scheduler",
               "confidence" => 0.5,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      # No space_id, so no meeting. This is the honest failure mode of
      # a meeting-keyed queue, and it is reported rather than hidden.
      {:ok, transcript} = Meetings.ensure_transcript(%{room_id: "room-e2e-orphan"})

      {:ok, _} =
        Meetings.append_segment(transcript.id, %{
          participant_identity: "user-1",
          text: "somebody should follow up on this",
          start_time: 0,
          end_time: 1000
        })

      assert_receive {:orphan, %{count: 1},
                      %{meeting_id: nil, dedupe_key_hit_or_new: :no_meeting}},
                     500
    end
  end

  # ── Test 2: cleanup on meeting:finished ───────────────────────────────────

  describe "meeting:finished broadcast cleanup" do
    test "the finished meeting's queue dies, another meeting's survives" do
      target = create_meeting!("E2E Cleanup Target")
      untouched = create_meeting!("E2E Untouched")

      {:ok, _} = IntentQueue.ensure_started(target.id, room_id: "room-cleanup-target")
      {:ok, _} = IntentQueue.ensure_started(untouched.id, room_id: "room-untouched")

      Enum.each(1..3, fn n ->
        {:ok, _row} =
          IntentQueue.enqueue(target.id, %{
            room_id: "room-cleanup-target",
            dedupe_key: "dedupe-#{n}",
            classified_intent: "schedule_followup",
            target_role: "scheduler",
            confidence: 0.5,
            transcript_chunk_id: "chunk-#{n}"
          })
      end)

      {:ok, _row} =
        IntentQueue.enqueue(untouched.id, %{
          room_id: "room-untouched",
          dedupe_key: "dedupe-untouched",
          classified_intent: "assign_owner",
          target_role: "scribe",
          confidence: 0.9,
          transcript_chunk_id: "chunk-untouched"
        })

      assert length(IntentQueue.list(target.id)) == 3
      assert length(IntentQueue.list(untouched.id)) == 1

      # Each queue owner subscribes to `meeting:finished` and stops
      # itself when the payload names its room. Cleanup is structural:
      # the ETS table is owned by that process and dies with it, so
      # there is no sweeper to get wrong.
      MeetingsPubSub.broadcast_meeting_finished("room-cleanup-target", %{
        transcript_id: "t1",
        room_id: "room-cleanup-target",
        space_id: "s1"
      })

      wait_for(fn -> not IntentQueue.running?(target.id) end, 500)

      assert IntentQueue.list(target.id) == []
      # Braces invariant: the other meeting is untouched.
      assert IntentQueue.running?(untouched.id)
      assert length(IntentQueue.list(untouched.id)) == 1
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

  # Task 01a03f57 stage 2: the classifier demotes a non-off_topic
  # classification to off_topic unless `evidence_quote` is a verbatim
  # span of the chunk. Stubs echo the chunk back as their citation —
  # the user message the classifier sends IS the chunk text.
  defp echo_quote(messages) do
    Enum.find_value(messages, "", fn message ->
      role = Map.get(message, :role) || Map.get(message, "role")
      if role == "user", do: Map.get(message, :content) || Map.get(message, "content")
    end)
  end
end
