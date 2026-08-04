defmodule Platform.Review.MeetingIntentE2EReviewTest do
  @moduledoc """
  E2E review harness for the Meeting Producer runtime (task 019f2452).

  Each test maps 1:1 to one of the six `e2e_behavior` validations in the
  stage 6 review payload. Room IDs, stubbed provider responses, expected
  telemetry, and log expectations are all pulled verbatim from the plan
  so the assertions ARE the review clauses.

  ExUnit is the environment here — this is what the reviewer runs to
  disposition each case. Failures represent contract misses versus the
  planner-authored expected clauses; passes go up to `validation_pass`.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

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

  # ── Stub provider (same seam the unit + integration tests use) ────────────

  defmodule StubProvider do
    def chat(credentials, messages, opts) do
      case Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end
  end

  # ── Setup ─────────────────────────────────────────────────────────────────

  setup do
    # Bump logger to :info so `capture_log/2` sees the no-assignee + fallback
    # + model-error lines the plan asserts on. Mirrors intent_classifier_test.
    Logger.put_module_level(Platform.Meetings.IntentClassifier, :info)
    on_exit(fn -> Logger.delete_module_level(Platform.Meetings.IntentClassifier) end)

    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Task 019f70b8 stage 3 made the intent queue meeting-keyed, so every
  # case now needs a real project → meeting → chat space chain: the
  # chunk's meeting_id is resolved from the transcript's space_id, and
  # a chunk with no meeting behind it has nowhere to be enqueued.
  defp create_meeting!(name) do
    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "#{name} project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/meeting-intent-review"
      })

    {:ok, meeting} = Platform.Meetings.create_meeting(%{project_id: project.id, name: name})
    on_exit(fn -> IntentQueue.stop(meeting.id) end)
    meeting
  end

  defp transcript_for!(meeting, room_id) do
    {:ok, transcript} =
      Meetings.ensure_transcript(%{room_id: room_id, space_id: meeting.chat_space_id})

    transcript
  end

  defp create_agent!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          slug: "review-intent-agent-#{System.unique_integer([:positive])}",
          name: "Review Intent Agent",
          status: "active"
        },
        overrides
      )

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  defp assign_intent_role!(agent) do
    {:ok, _} = Roles.set_override(@responsibility_key, agent.id)
    :ok
  end

  defp start_classifier! do
    name = :"classifier_review_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised({IntentClassifier, name: name, provider_module: StubProvider})

    {pid, name}
  end

  defp plant_stub_fun(pid, fun) do
    ref = make_ref()
    send(pid, {:__test_plant_stub, self(), ref, fun})

    receive do
      {^ref, :ok} -> :ok
    after
      500 -> flunk("classifier did not ack stub fun plant")
    end
  end

  defp attach_telemetry!(event, tag) do
    handler_id = "review-#{tag}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn _event, measurements, metadata, pid ->
        send(pid, {tag, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp nuke_prompt_template do
    case PromptTemplates.get_template_by_slug(@prompt_slug) do
      nil -> :ok
      template -> PromptTemplates.delete_template(template)
    end
  end

  # ── Case 1: Happy path ────────────────────────────────────────────────────

  describe "case 1 — happy path chunk arrival → queue entry" do
    test "stubbed provider response lands in queue with matching telemetry" do
      attach_telemetry!([:platform, :meetings, :intent_classified], :classified)

      agent = create_agent!()
      assign_intent_role!(agent)
      nuke_prompt_template()

      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, _m, _o ->
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

      meeting = create_meeting!("Review Happy")
      transcript = transcript_for!(meeting, "e2e-happy-1")

      {:ok, _} =
        Meetings.append_segment(transcript.id, %{
          participant_identity: "alice",
          speaker_name: "Alice",
          text: "Let's schedule a follow-up meeting Friday at 3pm",
          start_time: 0,
          end_time: 2500
        })

      # Expected clause verbatim: intent, target_role, confidence, dedupe_key_hit_or_new
      assert_receive {:classified, %{count: 1},
                      %{
                        room_id: "e2e-happy-1",
                        intent: "schedule_followup",
                        target_role: "scheduler",
                        confidence: 0.87,
                        dedupe_key_hit_or_new: :inserted
                      }},
                     2_000

      entries = IntentQueue.list(meeting.id)
      assert length(entries) == 1
      [entry] = entries
      assert entry.classified_intent == "schedule_followup"
      assert entry.target_role == "scheduler"
      assert entry.confidence == 0.87
      assert entry.status == :queued
      assert entry.room_id == "e2e-happy-1"

      # Dedupe key is carried on the row itself now — the pre-019f70b8
      # queue encoded it in a composite ETS key, which a remote runtime
      # could not address.
      assert is_binary(entry.dedupe_key)
      assert is_binary(entry.id)

      # Classifier mailbox drained.
      assert Process.info(pid, :message_queue_len) == {:message_queue_len, 0}
    end
  end

  # ── Case 2: Idempotence — same text twice → :duplicate on second ─────────

  describe "case 2 — idempotence" do
    test "same chunk text twice → one queue row, telemetry shows :duplicate second time" do
      attach_telemetry!([:platform, :meetings, :intent_classified], :classified)
      attach_telemetry!([:platform, :meetings, :intent_queue, :enqueue], :queue_enqueue)

      agent = create_agent!()
      assign_intent_role!(agent)
      nuke_prompt_template()

      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, _m, _o ->
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

      meeting = create_meeting!("Review Dedupe")
      transcript = transcript_for!(meeting, "e2e-dedupe-1")

      segment = %{
        participant_identity: "alice",
        speaker_name: "Alice",
        text: "Let's schedule a follow-up",
        start_time: 0,
        end_time: 2500
      }

      {:ok, _} = Meetings.append_segment(transcript.id, segment)

      assert_receive {:classified, _, %{dedupe_key_hit_or_new: :inserted}}, 2_000

      # Plan case 2 clause: first enqueue telemetry carries result: :inserted.
      assert_receive {:queue_enqueue, %{count: 1}, %{result: :inserted, room_id: "e2e-dedupe-1"}},
                     2_000

      # Second identical append — dedupe_key sha256(intent, target_role, text)
      # should collide, so the second classify pass returns :duplicate.
      {:ok, _} = Meetings.append_segment(transcript.id, segment)

      assert_receive {:classified, _, %{dedupe_key_hit_or_new: :duplicate}}, 2_000

      # Plan case 2 clause: second enqueue telemetry carries result: :duplicate.
      assert_receive {:queue_enqueue, %{count: 1},
                      %{result: :duplicate, room_id: "e2e-dedupe-1"}},
                     2_000

      # Exactly one row in the queue for this room.
      assert length(IntentQueue.list(meeting.id)) == 1
    end
  end

  # ── Case 3: No-assignee inert path ────────────────────────────────────────

  describe "case 3 — no assignee" do
    test "chunk arrives, telemetry :no_assignee fires, no crash, log suppression on repeat" do
      attach_telemetry!([:platform, :meetings, :intent_classifier, :skipped], :skipped)

      # DELIBERATELY skip assign_intent_role! — this is the "no assignee" path.
      # DataCase ensures no leftover role assignments from prior test runs.
      # Also nuke any existing override just in case.
      Roles.clear_override(@responsibility_key)

      {pid, _name} = start_classifier!()

      meeting = create_meeting!("Review No Assignee")
      transcript = transcript_for!(meeting, "e2e-noassignee-1")

      log =
        capture_log([level: :info], fn ->
          {:ok, _} =
            Meetings.append_segment(transcript.id, %{
              participant_identity: "alice",
              speaker_name: "Alice",
              text: "we should try to schedule something",
              start_time: 0,
              end_time: 2500
            })

          assert_receive {:skipped, %{count: 1},
                          %{reason: :no_assignee, room_id: "e2e-noassignee-1"}},
                         2_000
        end)

      assert log =~ "no assignee"
      assert log =~ "e2e-noassignee-1"

      # Classifier still alive; queue still empty for this room.
      assert Process.alive?(pid)
      assert IntentQueue.list(meeting.id) == []

      # Second chunk for same room: telemetry still fires but no NEW log line.
      log2 =
        capture_log([level: :info], fn ->
          {:ok, _} =
            Meetings.append_segment(transcript.id, %{
              participant_identity: "bob",
              speaker_name: "Bob",
              text: "yet another suggestion",
              start_time: 3000,
              end_time: 4500
            })

          assert_receive {:skipped, _, %{reason: :no_assignee, room_id: "e2e-noassignee-1"}},
                         2_000
        end)

      refute log2 =~ "no assignee for meetings.intent_classify"
    end
  end

  # ── Case 4: Template missing → inline fallback ────────────────────────────

  describe "case 4 — template missing → fallback" do
    test "template_fallback telemetry fires, entry lands, warning logged once" do
      attach_telemetry!(
        [:platform, :meetings, :intent_classifier, :template_fallback],
        :fallback
      )

      attach_telemetry!([:platform, :meetings, :intent_classified], :classified)

      agent = create_agent!()
      assign_intent_role!(agent)
      nuke_prompt_template()

      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, _m, _o ->
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

      meeting = create_meeting!("Review Fallback")
      transcript = transcript_for!(meeting, "e2e-fallback-1")

      log =
        capture_log([level: :warning], fn ->
          {:ok, _} =
            Meetings.append_segment(transcript.id, %{
              participant_identity: "alice",
              speaker_name: "Alice",
              text: "fallback prompt test",
              start_time: 0,
              end_time: 2500
            })

          assert_receive {:fallback, %{count: 1},
                          %{room_id: "e2e-fallback-1", slug: @prompt_slug}},
                         2_000

          assert_receive {:classified, _, %{dedupe_key_hit_or_new: :inserted}}, 2_000
        end)

      assert log =~ "fallback"
      assert length(IntentQueue.list(meeting.id)) == 1

      # Subsequent chunk in same VM should NOT re-log the warning (per-boot gate).
      # Broadcast a fresh chunk with different text so we don't collide dedupe_key.
      log2 =
        capture_log([level: :warning], fn ->
          {:ok, _} =
            Meetings.append_segment(transcript.id, %{
              participant_identity: "bob",
              speaker_name: "Bob",
              text: "second fallback chunk with different text",
              start_time: 3000,
              end_time: 4500
            })

          assert_receive {:fallback, _, _}, 2_000
        end)

      refute log2 =~ "prompt template #{@prompt_slug} missing"
    end
  end

  # ── Case 5: Model 500 → warning + no queue entry + recovery ──────────────

  describe "case 5 — model error recovery" do
    test "500 warns, no queue row, second healthy chunk succeeds" do
      attach_telemetry!(
        [:platform, :meetings, :intent_classifier, :model_error],
        :model_error
      )

      attach_telemetry!([:platform, :meetings, :intent_classified], :classified)

      agent = create_agent!()
      assign_intent_role!(agent)
      nuke_prompt_template()

      {pid, _name} = start_classifier!()

      # First stub: 500 error.
      plant_stub_fun(pid, fn _c, _m, _o ->
        {:error, %{status: 500, body: "upstream failure"}}
      end)

      meeting = create_meeting!("Review Model Fail")
      transcript = transcript_for!(meeting, "e2e-modelfail-1")

      log =
        capture_log([level: :warning], fn ->
          {:ok, _} =
            Meetings.append_segment(transcript.id, %{
              participant_identity: "alice",
              speaker_name: "Alice",
              text: "first attempt that hits the failing model",
              start_time: 0,
              end_time: 2500
            })

          assert_receive {:model_error, %{count: 1}, %{room_id: "e2e-modelfail-1"}}, 2_000
        end)

      assert log =~ "LLM call failed"
      assert IntentQueue.list(meeting.id) == []
      assert Process.alive?(pid)

      # Second stub: healthy.
      plant_stub_fun(pid, fn _c, _m, _o ->
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

      {:ok, _} =
        Meetings.append_segment(transcript.id, %{
          participant_identity: "alice",
          speaker_name: "Alice",
          text: "we should retry after the provider recovers",
          start_time: 3000,
          end_time: 5500
        })

      assert_receive {:classified, _, %{room_id: "e2e-modelfail-1", intent: "schedule_followup"}},
                     2_000

      assert length(IntentQueue.list(meeting.id)) == 1
    end
  end

  # ── Case 6: meeting:finished cleanup + cross-meeting isolation ───────────

  describe "case 6 — cleanup on meeting:finished" do
    test "the finished meeting's queue dies with its rows, another meeting's survives" do
      cleanup = create_meeting!("Review Cleanup")
      untouched = create_meeting!("Review Untouched")

      {:ok, _} = IntentQueue.ensure_started(cleanup.id, room_id: "e2e-cleanup-1")
      {:ok, _} = IntentQueue.ensure_started(untouched.id, room_id: "e2e-untouched")

      Enum.each(1..3, fn n ->
        {:ok, _row} =
          IntentQueue.enqueue(cleanup.id, %{
            room_id: "e2e-cleanup-1",
            dedupe_key: "key#{n}",
            classified_intent: "x",
            target_role: "y",
            confidence: 0.5
          })
      end)

      {:ok, _row} =
        IntentQueue.enqueue(untouched.id, %{
          room_id: "e2e-untouched",
          dedupe_key: "keyU",
          classified_intent: "z",
          target_role: "y",
          confidence: 0.5
        })

      assert length(IntentQueue.list(cleanup.id)) == 3
      assert length(IntentQueue.list(untouched.id)) == 1

      # Broadcast meeting_finished for the cleanup room.
      :ok =
        MeetingsPubSub.broadcast_meeting_finished("e2e-cleanup-1", %{
          transcript_id: "t",
          room_id: "e2e-cleanup-1",
          space_id: "s"
        })

      # The plan's case-6 clause was "rows for the finished room are
      # dropped, other rooms untouched". Task 019f70b8 satisfies it
      # more strongly: there is no shared table to selectively drop
      # from. The finished meeting's queue OWNER stops, and its
      # unnamed ETS table is reclaimed with it — cleanup is
      # structural, so a sweep can no longer get the scoping wrong.
      wait_for(fn -> not IntentQueue.running?(cleanup.id) end, 1_000)

      assert IntentQueue.list(cleanup.id) == []

      # Cross-meeting isolation invariant.
      assert IntentQueue.running?(untouched.id)
      assert length(IntentQueue.list(untouched.id)) == 1
    end
  end

  # ── Utilities ─────────────────────────────────────────────────────────────

  defp wait_for(fun, timeout_ms) do
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
