defmodule Platform.Meetings.IntentClassifierTest do
  @moduledoc """
  Tests for `Platform.Meetings.IntentClassifier` — the transcript-chunk
  subscriber that drives the Meeting Producer classifier pipeline
  (task 019f2452 stages 3–4).

  Stage 3 shipped the module SHELL: subscription, feature-flag gate,
  assignee-lookup gate, spam-suppressor MapSet.

  Stage 4 shipped the full pipeline in `classify_and_enqueue/3`:
  prompt render + LLM call + JSON parse + dedupe + `IntentQueue.enqueue/2`
  + terminal telemetry. Coverage below extends the stage-3 guard
  assertions with the pipeline's happy-path, idempotent-replay,
  template-fallback, model-error, truncated-output, and parse-error
  branches. The
  provider is stubbed via the `provider_module` opt on `start_link/1`
  so tests can pipe any response through without hitting a real Ollama.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Meetings
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles

  @responsibility_key "meetings.intent_classify"
  @prompt_slug "meetings.intent_classify.v1"

  # config/test.exs pins the Logger to :warning; bump this module to
  # :info so `capture_log/2` actually sees the boot + no-assignee lines
  # we assert on. Mirrors `Platform.Responsibilities.RouterTest`.
  setup do
    Logger.put_module_level(Platform.Meetings.IntentClassifier, :info)
    on_exit(fn -> Logger.delete_module_level(Platform.Meetings.IntentClassifier) end)
    :ok
  end

  # ── Provider stub ─────────────────────────────────────────────────────────

  defmodule StubProvider do
    @moduledoc """
    Provider stub — the classifier passes it in via `provider_module`.
    Tests drop a `fun` into an agent-based Process dictionary key so
    concurrent instances stay isolated, then this module reads the
    matching fun and calls it. Returns whatever the test set up.
    """

    def chat(credentials, messages, opts) do
      case Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp start_classifier!(opts \\ []) do
    # ExUnit test names include the describe title, which for this suite
    # holds an em-dash and other Unicode — `binary_to_atom(_, :utf8)`
    # chokes on the byte-level slice. Use a unique-integer suffix so the
    # process name stays ASCII and collision-free across runs.
    name = :"intent_classifier_#{System.unique_integer([:positive])}"

    child_opts =
      opts
      |> Keyword.put_new(:provider_module, StubProvider)
      |> Keyword.put(:name, name)

    {:ok, pid} = start_supervised({IntentClassifier, child_opts})

    # The `StubProvider` module (see above) reads the stub fun out of
    # the process dictionary of whatever process it's called from —
    # which, for the classifier, IS the classifier's own process. The
    # `plant_stub_fun/2` helper below sends a `:__test_plant_stub`
    # message that the classifier handles by storing the fun in its
    # dict; that's the whole seam.
    {pid, name}
  end

  # Plant the stub fun in the CLASSIFIER's process dictionary — the stub
  # runs inside the classifier's handle_info loop, not the test process.
  defp plant_stub_fun(pid, fun) do
    ref = make_ref()
    send(pid, {:__test_plant_stub, self(), ref, fun})

    receive do
      {^ref, :ok} -> :ok
    after
      500 -> flunk("classifier did not ack stub fun plant")
    end
  end

  # Task 01a03f57 stage 2: the classifier now DEMOTES any non-off_topic
  # classification whose `evidence_quote` is not a verbatim span of the
  # chunk. Fixed happy-path stubs would all demote, so they echo the
  # chunk back as their citation — the user message the classifier
  # sends IS the chunk text (`call_provider/5`).
  defp echo_quote(messages) do
    Enum.find_value(messages, "", fn message ->
      role = Map.get(message, :role) || Map.get(message, "role")
      if role == "user", do: Map.get(message, :content) || Map.get(message, "content")
    end)
  end

  defp create_agent!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          slug: "intent-agent-#{System.unique_integer([:positive])}",
          name: "Intent Agent",
          status: "active"
        },
        overrides
      )

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  defp assign_intent_role!(agent) do
    # Task 019f2452: no "producer" role in the closed roster yet — use
    # the leaf-level responsibility override so `assignee_for/1`
    # resolves to this agent independent of role bundle wiring.
    {:ok, _} = Roles.set_override(@responsibility_key, agent.id)
    :ok
  end

  defp attach_recorder!(event_suffix, tag) do
    handler_id = "intent-classifier-test-#{tag}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:platform, :meetings, :intent_classifier, event_suffix],
      fn _event, measurements, metadata, pid ->
        send(pid, {tag, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  # The terminal `intent_classified` telemetry lives at a different
  # namespace (no `:intent_classifier` suffix); recorder helper mirrors
  # `attach_recorder!/2` for that event.
  defp attach_terminal_recorder!(tag) do
    handler_id = "intent-classified-test-#{tag}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:platform, :meetings, :intent_classified],
      fn _event, measurements, metadata, pid ->
        send(pid, {tag, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp broadcast_chunk(room_id, overrides \\ %{}) do
    overrides_map = if is_map(overrides), do: overrides, else: Enum.into(overrides, %{})

    payload =
      Map.merge(
        %{
          room_id: room_id,
          transcript_id: "transcript-#{System.unique_integer([:positive])}",
          segment: %{
            id: "seg-#{System.unique_integer([:positive])}",
            text: "we need to schedule a follow-up on the billing bug",
            speaker_name: "alice"
          },
          # Every chunk carries a meeting by default. Since task
          # 019f70b8 stage 3 the queue is keyed by MEETING — a chunk
          # with no meeting_id has nowhere to be enqueued, which is
          # its own test below rather than the ambient case.
          meeting_id: meeting_id_for(room_id)
        },
        overrides_map
      )

    :ok = MeetingsPubSub.broadcast_transcript_chunk(room_id, payload)
    payload
  end

  # Deterministic room -> meeting mapping so a test can enqueue by room
  # and read back by meeting without threading an id through every
  # helper.
  #
  # It MUST be a real UUID. `meeting_candidates.meeting_id` is a
  # `:binary_id`, so the durable candidate mirror in
  # `Platform.Meetings.IntentQueue.Server` raises `Ecto.ChangeError` at
  # dump time on anything else — and its deliberately non-fatal
  # `mirror/1` wrapper swallows that raise into a log line. With the
  # old `"meeting-" <> room_id` shape every enqueue in this file
  # mirrored nothing and the suite stayed green anyway (task 01a049f9).
  # Hashed rather than generated so the mapping stays deterministic.
  defp meeting_id_for(room_id) do
    <<a::binary-8, b::binary-4, c::binary-3, d::binary-3, e::binary-12, _::binary>> =
      Base.encode16(:crypto.hash(:sha256, "meeting:" <> room_id), case: :lower)

    "#{a}-#{b}-7#{c}-8#{d}-#{e}"
  end

  # A fresh meeting id for tests that do not key off a room. Same
  # constraint as `meeting_id_for/1`: it has to be a real UUID or the
  # mirror silently does nothing.
  defp unique_meeting_id, do: Ecto.UUID.generate()

  # Rows for the meeting this room's chunks land in.
  defp queued_for_room(room_id), do: IntentQueue.list(meeting_id_for(room_id))

  # Tear down a room's meeting queue. Replaces the old
  # `IntentQueue.drop_for_room/1` — there is no shared table to scrub
  # any more, just a process to stop.
  defp drop_queue_for_room(room_id), do: IntentQueue.stop(meeting_id_for(room_id))

  # ── Tests ──────────────────────────────────────────────────────────────────

  describe "init/1" do
    test "subscribes to the canonical transcript_chunk topic and logs on boot" do
      log =
        capture_log([level: :info], fn ->
          {_pid, _name} = start_classifier!()
          # Give init a beat to emit the log line.
          Process.sleep(20)
        end)

      assert log =~ "[IntentClassifier] started"
      assert log =~ "meeting:transcript_chunk"
    end
  end

  describe "handle_info/2 — no assignee" do
    test "logs at :info the first time a room appears with no assignee" do
      _ = attach_recorder!(:skipped, :skipped)
      {_pid, _name} = start_classifier!()

      log =
        capture_log([level: :info], fn ->
          _ = broadcast_chunk("room-no-assignee-first")

          assert_receive {:skipped, %{count: 1},
                          %{reason: :no_assignee, room_id: "room-no-assignee-first"}},
                         500
        end)

      assert log =~ "[IntentClassifier] no assignee for meetings.intent_classify"
      assert log =~ "room=room-no-assignee-first"
    end

    test "second chunk from the same room does NOT re-log at :info" do
      _ = attach_recorder!(:skipped, :skipped)
      {_pid, _name} = start_classifier!()

      # Prime seen_rooms with the first chunk (may log; we don't care here).
      _ =
        capture_log(fn ->
          _ = broadcast_chunk("room-no-assignee-repeat")
          assert_receive {:skipped, _measurements, %{reason: :no_assignee}}, 500
        end)

      # Second chunk for the same room: telemetry still fires but no
      # info-level log line is emitted.
      log =
        capture_log([level: :info], fn ->
          _ = broadcast_chunk("room-no-assignee-repeat")

          assert_receive {:skipped, _measurements,
                          %{reason: :no_assignee, room_id: "room-no-assignee-repeat"}},
                         500
        end)

      refute log =~ "[IntentClassifier] no assignee"
    end

    test "does not crash the classifier when the responsibility has no assignee" do
      {pid, _name} = start_classifier!()

      _ = broadcast_chunk("room-liveness-check")
      Process.sleep(50)

      assert Process.alive?(pid)
    end
  end

  describe "classify_and_enqueue — happy path" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-happy"})
      assign_intent_role!(agent)
      drop_queue_for_room("room-happy")
      %{agent: agent}
    end

    test "parses the JSON response, writes to IntentQueue, fires intent_classified telemetry",
         %{agent: agent} do
      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "schedule_follow_up",
               "target_role" => "scribe",
               "confidence" => 0.87,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      happy_meeting_id = unique_meeting_id()
      _ = broadcast_chunk("room-happy", meeting_id: happy_meeting_id)

      assert_receive {:classified, %{count: 1},
                      %{
                        room_id: "room-happy",
                        intent: "schedule_follow_up",
                        target_role: "scribe",
                        confidence: 0.87,
                        dedupe_key_hit_or_new: :inserted,
                        meeting_id: ^happy_meeting_id
                      }},
                     500

      # And the row landed in the MEETING's queue — the chunk named
      # that meeting explicitly, so that is where it lives.
      entries = IntentQueue.list(happy_meeting_id)
      on_exit(fn -> IntentQueue.stop(happy_meeting_id) end)
      assert length(entries) == 1
      [entry] = entries
      assert entry.classified_intent == "schedule_follow_up"
      assert entry.target_role == "scribe"
      assert entry.confidence == 0.87
      assert entry.meeting_id == happy_meeting_id
      assert entry.status == :queued

      # Silence the "unused" compiler warning for the injected agent.
      assert agent.slug == "intent-agent-happy"
    end
  end

  # Task 01a03fb8 stage 2: the classifier's model is a ~2B reasoning
  # model. Without an explicit opt-out it burns the entire completion
  # budget on `reasoning_content` and hands back `content: ""` with
  # `finish_reason: "length"`, so the classification never arrives.
  # `chat_template_kwargs` is what llama.cpp reads (the provider's
  # `think: false` is the Ollama-side flag and llama-server ignores it),
  # and stage 1 taught the Ollama provider to forward the key. This
  # guard pins the opt onto the request the classifier actually builds.
  describe "call_provider/5 — request shape disables model thinking" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-thinking"})
      assign_intent_role!(agent)
      drop_queue_for_room("room-thinking")
      %{agent: agent}
    end

    test "sends chat_template_kwargs enable_thinking=false to the provider" do
      test_pid = self()
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _creds, messages, opts ->
        send(test_pid, {:captured_opts, opts})

        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "schedule_follow_up",
               "target_role" => "scribe",
               "confidence" => 0.9,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      capture_log(fn ->
        _ = broadcast_chunk("room-thinking")

        assert_receive {:captured_opts, opts}, 500

        assert Keyword.get(opts, :chat_template_kwargs) == %{"enable_thinking" => false},
               """
               The classifier must ask the model to skip its reasoning pass. \
               Got opts: #{inspect(opts)}\
               """

        # The flag rides ALONGSIDE the existing budget — stage 2 is not a
        # token-budget re-tune, so a change to either of these is a
        # regression this guard should catch too.
        assert Keyword.get(opts, :temperature) == 0.0
        assert Keyword.get(opts, :max_tokens) == 1024
      end)
    end
  end

  # Task 019f70b8: the classifier writes into the per-meeting queue the
  # dispatcher drains and the live-tuning UI renders, with the extra
  # fields that surface makes use of. Stage 3 retired the legacy
  # room-keyed write, so this is now the only enqueue path.
  describe "classify_and_enqueue — per-meeting queue write" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-permeeting"})
      assign_intent_role!(agent)

      target = create_agent!(%{slug: "intent-target-designer"})
      :ok = Roles.unassign_role("designer")
      {:ok, _} = Roles.assign_role("designer", target.id)
      # No on_exit unassign — the DataCase sandbox rolls the row back,
      # and an on_exit DB call runs after the sandbox owner has exited.

      meeting_id = unique_meeting_id()
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      %{agent: agent, target: target, meeting_id: meeting_id}
    end

    test "stamps the excerpt, the chunk id, and the resolved target agent", %{
      target: target,
      meeting_id: meeting_id
    } do
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "visual_adjust",
               "target_role" => "designer",
               "confidence" => 0.91,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      :ok = MeetingsPubSub.subscribe_intents(meeting_id)

      payload =
        broadcast_chunk("room-permeeting",
          meeting_id: meeting_id,
          segment: %{
            id: "seg-permeeting",
            text: "the nav bar contrast is too low on mobile",
            speaker_name: "alice"
          }
        )

      assert_receive {:intent_classified, row}, 1_000

      assert row.meeting_id == meeting_id
      assert row.room_id == "room-permeeting"
      assert row.status == :queued
      assert row.classified_intent == "visual_adjust"
      assert row.target_role == "designer"
      assert row.confidence == 0.91
      assert row.transcript_chunk_id == "seg-permeeting"
      assert row.chunk_excerpt == "the nav bar contrast is too low on mobile"

      # `Roles.agent_id_for_role/1` is guarded `when is_binary(role_key)`;
      # the classifier stringifies before calling it, so a role that
      # arrives as an atom resolves rather than raising.
      assert row.target_agent_id == target.id
      assert row.target_agent_slug == "intent-target-designer"

      assert [^row] = IntentQueue.list(meeting_id)
      assert payload.meeting_id == meeting_id
    end

    test "an unassigned role still enqueues, with a nil target", %{meeting_id: meeting_id} do
      :ok = Roles.unassign_role("designer")

      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "visual_adjust",
               "target_role" => "designer",
               "confidence" => 0.5,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      :ok = MeetingsPubSub.subscribe_intents(meeting_id)
      _ = broadcast_chunk("room-permeeting-noassignee", meeting_id: meeting_id)

      assert_receive {:intent_classified, row}, 1_000

      # Do NOT silently drop: the row lands as :queued with no target
      # and fails visibly at dispatch. That IS the tuning signal.
      assert row.status == :queued
      assert row.target_role == "designer"
      assert row.target_agent_id == nil
      assert row.target_agent_slug == nil
    end

    test "a chunk with no meeting_id is classified but has no queue to land in" do
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "visual_adjust",
               "target_role" => "designer",
               "confidence" => 0.5,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      drop_queue_for_room("room-permeeting-nomeeting")
      on_exit(fn -> drop_queue_for_room("room-permeeting-nomeeting") end)

      _ = attach_terminal_recorder!(:nomeeting)
      _ = broadcast_chunk("room-permeeting-nomeeting", meeting_id: nil)

      # The classification still happened and is still reported — what
      # changed in stage 3 is that there is no room-keyed fallback
      # queue to write it to. The telemetry says so out loud rather
      # than the row vanishing silently.
      assert_receive {:nomeeting, %{count: 1},
                      %{meeting_id: nil, dedupe_key_hit_or_new: :no_meeting}},
                     1_000

      assert queued_for_room("room-permeeting-nomeeting") == []
    end

    test "the excerpt is capped at 280 characters", %{meeting_id: meeting_id} do
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "visual_adjust",
               "target_role" => "designer",
               "confidence" => 0.5,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      # A realistic long utterance, not `String.duplicate("a", 400)` —
      # a single 400-character token carries no content and is now
      # (correctly) refused by the pre-model gate before it can reach
      # the excerpt path at all.
      long_text = String.duplicate("we should ship the billing fix today. ", 12)
      :ok = MeetingsPubSub.subscribe_intents(meeting_id)

      _ =
        broadcast_chunk("room-permeeting-long",
          meeting_id: meeting_id,
          segment: %{id: "seg-long", text: long_text, speaker_name: "alice"}
        )

      assert_receive {:intent_classified, row}, 1_000
      assert String.length(row.chunk_excerpt) == 280
    end
  end

  # ── Durable candidate mirror (task 01a049f9) ──────────────────────────────
  #
  # `IntentQueue.Server` mirrors every queue write into
  # `meeting_candidates`, behind a wrapper that rescues, catches `:exit`
  # AND discards an `{:error, changeset}` return. Three independent ways
  # for the mirror to do nothing without failing a test, which is how
  # this file ran 76 green tests over a mirror that inserted zero rows.
  #
  # So the assertion here is POSITIVE and on the row itself: absence of
  # an error is not presence of a row. Every id the mirror carries
  # through is a real UUID, because `uuid_or_nil/1` degrades anything
  # else to nil — asserting on a `"room-x"` literal would pass against a
  # mirror that had thrown the value away.
  describe "durable candidate mirror" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-mirror"})
      assign_intent_role!(agent)

      target = create_agent!(%{slug: "intent-target-mirror"})
      :ok = Roles.unassign_role("designer")
      {:ok, _} = Roles.assign_role("designer", target.id)

      meeting_id = unique_meeting_id()
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      %{agent: agent, target: target, meeting_id: meeting_id}
    end

    test "a classifier-driven enqueue writes a durable candidate row", %{
      target: target,
      meeting_id: meeting_id
    } do
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "visual_adjust",
               "target_role" => "designer",
               "confidence" => 0.91,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      room_id = Ecto.UUID.generate()
      chunk_id = Ecto.UUID.generate()
      :ok = MeetingsPubSub.subscribe_intents(meeting_id)

      _ =
        broadcast_chunk(room_id,
          meeting_id: meeting_id,
          segment: %{
            id: chunk_id,
            text: "the nav bar contrast is too low on mobile",
            speaker_name: "alice"
          }
        )

      assert_receive {:intent_classified, row}, 1_000

      # The mirror is a cast off the same GenServer call that produced
      # the queue row, so by the time the broadcast lands the insert has
      # already returned. No polling.
      candidate = Candidates.get_by_intent_id(row.id)

      assert candidate,
             "no meeting_candidates row for intent #{row.id} — the durable mirror " <>
               "did not run (see task 01a049f9: it fails silently)"

      assert candidate.meeting_id == meeting_id
      assert candidate.room_id == room_id
      assert candidate.transcript_chunk_id == chunk_id
      assert candidate.evidence_quote == "the nav bar contrast is too low on mobile"
      assert candidate.classified_intent == "visual_adjust"
      assert candidate.classifier_confidence == 0.91
      assert candidate.target_role == "designer"
      assert candidate.assigned_agent_id == target.id
      assert candidate.assigned_agent_slug == "intent-target-mirror"

      # The lifecycle axis on first sight, and the verbatim queue-status
      # echo the measurement query reads.
      assert candidate.state == :heard
      assert candidate.queue_status == "queued"
      assert candidate.outcome_kind == :task
      assert candidate.heard_at

      # Not closed and not yet dispositioned: an enqueue is not an outcome.
      assert is_nil(candidate.closed_reason)
      assert is_nil(candidate.disposition)

      # One row per intent — the unique index on `intent_id` is the
      # mirror's idempotence key.
      assert [^candidate] = Candidates.list_for_meeting(meeting_id)
    end

    # ── Threading columns (task 01a03fb9 stage 1) ───────────────────────────
    #
    # Two DIFFERENT speakers in ONE meeting, on purpose. A single-speaker
    # case asserting `candidate.speaker != nil` is satisfied by a
    # hardcoded constant, by the room id, by the classifier's own agent
    # slug — by anything at all that happens to be a non-empty string at
    # that point in the code. The only assertion that distinguishes "the
    # actual speaker was recorded" from "something was recorded" is two
    # rows in the same meeting carrying two different, correct values.
    test "the mirror records each utterance's ACTUAL speaker, for two speakers in one meeting",
         %{meeting_id: meeting_id} do
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "visual_adjust",
               "target_role" => "designer",
               "confidence" => 0.88,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      room_id = Ecto.UUID.generate()
      :ok = MeetingsPubSub.subscribe_intents(meeting_id)

      alice_text = "the nav bar contrast is too low on mobile"
      bruno_text = "the checkout button is the wrong shade of green"

      _ =
        broadcast_chunk(room_id,
          meeting_id: meeting_id,
          segment: %{id: Ecto.UUID.generate(), text: alice_text, speaker_name: "alice"}
        )

      assert_receive {:intent_classified, alice_row}, 1_000

      _ =
        broadcast_chunk(room_id,
          meeting_id: meeting_id,
          segment: %{id: Ecto.UUID.generate(), text: bruno_text, speaker_name: "bruno"}
        )

      assert_receive {:intent_classified, bruno_row}, 1_000

      alice = Candidates.get_by_intent_id(alice_row.id)
      bruno = Candidates.get_by_intent_id(bruno_row.id)

      assert alice, "no candidate row for alice's intent #{alice_row.id} — the mirror is silent"
      assert bruno, "no candidate row for bruno's intent #{bruno_row.id} — the mirror is silent"

      # Correlate by what was SAID, not by arrival order, so a
      # transposition is a failure rather than an invisible pass.
      assert alice.evidence_quote == alice_text
      assert bruno.evidence_quote == bruno_text

      # THE assertion. Two different speakers, two different recorded
      # values, each matching the segment it came from.
      assert alice.speaker == "alice"
      assert bruno.speaker == "bruno"
      refute alice.speaker == bruno.speaker

      # Both rows are populated — the mirror wrote a real timestamp, not
      # a nil the column's default would have supplied anyway.
      assert alice.last_utterance_at
      assert bruno.last_utterance_at

      # At creation the first utterance IS the last one, and the two
      # candidates were created seconds apart in order.
      assert alice.last_utterance_at == alice.heard_at
      assert DateTime.compare(alice.last_utterance_at, bruno.last_utterance_at) == :lt

      # Nothing has threaded yet — this stage is the slot, not the rule.
      assert alice.threading_events == []
      assert bruno.threading_events == []

      # Two rows, not one: this stage must not have started threading.
      assert length(Candidates.list_for_meeting(meeting_id)) == 2
    end

    test "an unattributed segment mirrors a nil speaker, not an empty string", %{
      meeting_id: meeting_id
    } do
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "visual_adjust",
               "target_role" => "designer",
               "confidence" => 0.88,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      room_id = Ecto.UUID.generate()
      :ok = MeetingsPubSub.subscribe_intents(meeting_id)

      # `segment_speaker/2` answers `""` for a segment with no
      # attribution — the value that must NOT reach the column, because
      # stage 3's same-speaker rule would read `"" == ""` as one person.
      _ =
        broadcast_chunk(room_id,
          meeting_id: meeting_id,
          segment: %{
            id: Ecto.UUID.generate(),
            # Comfortably past the content gate's five-word short-utterance
            # rule, so the only thing this case is testing is the speaker.
            text: "the sidebar padding is inconsistent across the settings pages"
          }
        )

      assert_receive {:intent_classified, row}, 1_000

      candidate = Candidates.get_by_intent_id(row.id)

      assert candidate, "no candidate row for intent #{row.id} — the mirror is silent"
      assert is_nil(candidate.speaker)
      refute candidate.speaker == ""
    end
  end

  # ── Threading (task 01a03fb9 stage 4) ───────────────────────────────────────
  #
  # The probe that established this ticket's premise, INVERTED. Baseline
  # measured on 590a845d (stage 3, before this stage's wiring): two
  # related utterances from one speaker produced two independent
  # candidate rows, both carrying `transcript_chunk_ids == []` and
  # `threading_events == []`. Every test here runs the real production
  # path — a transcript chunk over PubSub, the classifier, the
  # per-meeting queue, and `mirror_enqueue` inside the queue's own
  # GenServer — because the thing this stage changes is a decision made
  # in that hook and nowhere else.
  #
  # THE ASSERTION IS ON THE ACCUMULATED CHUNK IDS, NOT ON THE ROW COUNT.
  # "One candidate exists" is also true of an implementation that
  # silently dropped the second utterance's mirror altogether, which is
  # a strictly worse outcome than the bug being fixed. The chunk id list
  # is the only evidence that distinguishes "the second utterance
  # attached here" from "the second utterance went nowhere".
  describe "threaded utterances accrete onto one candidate" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-threading"})
      assign_intent_role!(agent)

      target = create_agent!(%{slug: "intent-target-threading"})
      :ok = Roles.unassign_role("designer")
      {:ok, _} = Roles.assign_role("designer", target.id)

      meeting_id = unique_meeting_id()
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      %{agent: agent, meeting_id: meeting_id, room_id: Ecto.UUID.generate()}
    end

    # One utterance in, one classified intent out, and the id of the
    # queue row it produced. Each call is a SEPARATE classifier turn: the
    # reply is awaited before the next chunk is broadcast, so the
    # same-speaker debounce (which merges consecutive fragments of one
    # turn into a single classification) has already flushed. Without
    # that sequencing two same-speaker chunks become ONE utterance and
    # there is nothing left for threading to do — the test would pass on
    # the debounce and prove nothing about this stage.
    defp say!(context, speaker, text) do
      _ =
        broadcast_chunk(context.room_id,
          meeting_id: context.meeting_id,
          segment: %{id: Ecto.UUID.generate(), text: text, speaker_name: speaker}
        )

      assert_receive {:intent_classified, row}, 2_000
      assert row.chunk_excerpt == text
      row
    end

    defp start_threading_classifier!(meeting_id) do
      # A short debounce keeps each utterance its own turn without
      # waiting out the 1.5s default four times over.
      {pid, _name} = start_classifier!(debounce_ms: 150)

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "visual_adjust",
               "target_role" => "designer",
               "confidence" => 0.91,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      :ok = MeetingsPubSub.subscribe_intents(meeting_id)
      pid
    end

    # Every utterance below has to be one the classifier would actually
    # forward. Its content gate drops utterances of five words or fewer
    # with no action verb, and a scenario built from a chunk that fails
    # the gate exercises a path production never reaches: green and
    # meaningless. Asserted here rather than assumed, with a positive
    # control proving the gate can answer false.
    @dashboard "we should make the dashboard load faster"
    @follow_up "make that mobile only"
    @unrelated "can someone book the offsite room"
    @release "we should move the release date to the fifteenth"
    @release_follow_up "the release date needs to slip a week"

    test "every scenario utterance clears the classifier's content gate" do
      for text <- [@dashboard, @follow_up, @unrelated, @release, @release_follow_up] do
        assert IntentClassifier.content_bearing?(text),
               "#{inspect(text)} does not clear the content gate, so the classifier " <>
                 "never runs on it and any scenario built from it is vacuous"
      end

      # POSITIVE CONTROL on the gate itself: it is capable of answering
      # false, so the five assertions above are not trivially true.
      refute IntentClassifier.content_bearing?("yeah")
    end

    test "PROVES IT WORKS: two related utterances from one speaker yield ONE candidate carrying TWO chunk ids",
         context do
      _pid = start_threading_classifier!(context.meeting_id)

      first = say!(context, "alice", @dashboard)
      second = say!(context, "alice", @follow_up)

      # The queue still holds TWO intents. Threading is a decision about
      # the durable candidate mirror, not about the queue — if the queue
      # had collapsed to one row this test would be measuring the
      # dedupe index instead.
      assert length(IntentQueue.list(context.meeting_id)) == 2
      refute first.id == second.id

      candidates = Candidates.list_for_meeting(context.meeting_id)

      assert [candidate] = candidates,
             "expected ONE candidate after a threaded follow-up, got #{length(candidates)}"

      # THE assertion. Two chunk ids on one row. A "no duplicate
      # candidates" check alone is satisfied by an implementation that
      # simply never mirrored the second utterance.
      assert length(candidate.transcript_chunk_ids) == 2

      assert candidate.transcript_chunk_ids == [
               first.transcript_chunk_id,
               second.transcript_chunk_id
             ]

      # The singular column is the FIRST chunk and does not move.
      assert candidate.transcript_chunk_id == first.transcript_chunk_id

      # The candidate is the one the FIRST utterance opened, not a row
      # the second utterance created and backfilled.
      assert candidate.intent_id == first.id
      assert candidate.evidence_quote == @dashboard

      # ONE threading event, and the REASON asserted BY VALUE. The
      # resolver returns a map on purpose: an atom would record THAT a
      # rule fired without recording what it saw, and a wrong
      # attachment is only diagnosable afterwards from what it saw.
      assert [event] = candidate.threading_events

      assert event["reason"]["rule"] == "anaphoric_fragment"
      assert event["reason"]["deictic"] == "that"
      assert event["reason"]["token_count"] == 4
      assert event["reason"]["open_candidates_in_window"] == 1
      assert event["transcript_chunk_id"] == second.transcript_chunk_id

      # The attached intent is not lost even though it has no row of its
      # own — its id is in the event, which is the only place it is
      # recoverable from.
      assert event["intent_id"] == second.id
      refute Candidates.get_by_intent_id(second.id)

      # `last_utterance_at` moved and `heard_at` did not. The two
      # utterances are at least a debounce apart, so this is a real
      # ordering assertion and not two reads of the same instant.
      assert DateTime.compare(candidate.last_utterance_at, candidate.heard_at) == :gt
      assert candidate.heard_at == first.enqueued_at
      assert candidate.last_utterance_at == second.enqueued_at

      # Attaching is not lifecycle progress.
      assert candidate.state == :heard
    end

    test "CATCHES THE VACUOUS VERSION: an unrelated utterance from the SAME speaker inside the window yields TWO candidates",
         context do
      _pid = start_threading_classifier!(context.meeting_id)

      first = say!(context, "alice", @dashboard)
      second = say!(context, "alice", @unrelated)

      candidates = Candidates.list_for_meeting(context.meeting_id)

      assert length(candidates) == 2,
             "same speaker and inside the window must NOT be enough to thread — this is " <>
               "the assertion that fails if the resolver was written as 'attach to the " <>
               "most recent open candidate'"

      dashboard = Candidates.get_by_intent_id(first.id)
      offsite = Candidates.get_by_intent_id(second.id)

      assert dashboard, "the first utterance produced no candidate"
      assert offsite, "the second utterance produced no candidate"

      # One chunk each, not two on one row and none on the other.
      assert dashboard.transcript_chunk_ids == [first.transcript_chunk_id]
      assert offsite.transcript_chunk_ids == [second.transcript_chunk_id]

      assert dashboard.threading_events == []
      assert offsite.threading_events == []

      # POSITIVE CONTROLS that this :new was the relatedness floor and
      # not a broken scenario: the speaker gate and the time gate were
      # both satisfied.
      assert dashboard.speaker == "alice"
      assert offsite.speaker == "alice"
      assert DateTime.diff(second.enqueued_at, first.enqueued_at, :second) <= 60
      assert dashboard.last_utterance_at == dashboard.heard_at
    end

    test "CATCHES THE VACUOUS VERSION: the same follow-up from a DIFFERENT speaker yields TWO candidates",
         context do
      _pid = start_threading_classifier!(context.meeting_id)

      first = say!(context, "alice", @dashboard)
      second = say!(context, "bruno", @follow_up)

      assert length(Candidates.list_for_meeting(context.meeting_id)) == 2

      dashboard = Candidates.get_by_intent_id(first.id)
      bruno = Candidates.get_by_intent_id(second.id)

      assert dashboard.transcript_chunk_ids == [first.transcript_chunk_id]
      assert bruno.transcript_chunk_ids == [second.transcript_chunk_id]
      assert dashboard.threading_events == []

      # The word-for-word same follow-up threads when alice says it —
      # asserted in the proves-it-works test above — so the only thing
      # that changed here is who said it.
      assert dashboard.speaker == "alice"
      assert bruno.speaker == "bruno"
      assert dashboard.last_utterance_at == dashboard.heard_at
    end

    test "with TWO open candidates the follow-up attaches to the RIGHT one and leaves the other untouched",
         context do
      _pid = start_threading_classifier!(context.meeting_id)

      # ORDER IS LOAD-BEARING. The release ask is said FIRST and the
      # dashboard ask second, so the candidate the follow-up must attach
      # to is the OLDER one — and `open_for_meeting/1` hands the
      # resolver its list NEWEST FIRST. Said the other way round the
      # right answer would also be the head of the list, and an
      # implementation that ignored the resolver and reached for
      # `hd(open)` would pass. Measured: it does. Written in the
      # convenient order this test went green against exactly that
      # mutant.
      release_intent = say!(context, "alice", @release)
      dashboard_intent = say!(context, "alice", @dashboard)

      # Two independent candidates before the follow-up: the dashboard
      # ask is unrelated to the release ask, so it opened its own row.
      assert length(Candidates.list_for_meeting(context.meeting_id)) == 2

      dashboard_before = Candidates.get_by_intent_id(dashboard_intent.id)
      assert dashboard_before.transcript_chunk_ids == [dashboard_intent.transcript_chunk_id]

      # THE PIN that makes this test discriminating: the WRONG candidate
      # is the head of the list the resolver is given. Asserted rather
      # than assumed, because it is a property of `open_for_meeting/1`'s
      # ordering and a change there would silently make this whole test
      # vacuous again.
      open = Candidates.open_for_meeting(context.meeting_id)
      assert hd(open).id == dashboard_before.id

      follow_up_intent = say!(context, "alice", @release_follow_up)

      assert length(Candidates.list_for_meeting(context.meeting_id)) == 2

      release = Candidates.get_by_intent_id(release_intent.id)

      # It attached to the release candidate — the one the resolver
      # chose, NOT the one at the head of the list.
      assert release.transcript_chunk_ids == [
               release_intent.transcript_chunk_id,
               follow_up_intent.transcript_chunk_id
             ]

      refute release.id == dashboard_before.id

      assert [event] = release.threading_events

      # A DIFFERENT rule than the proves-it-works case, asserted by
      # value. A hardcoded event — or one that recorded only the fact of
      # an attachment — passes that test and fails this one.
      assert event["reason"]["rule"] == "topic_overlap"
      assert event["reason"]["shared"] == ["date", "release"]
      assert event["reason"]["open_candidates_in_window"] == 2
      assert event["reason"]["score"] == 0.6667

      # THE INVISIBLE FAILURE. Attaching to the wrong candidate silently
      # moves the wrong card's clock, so the untouched half is asserted
      # explicitly, READ BACK FROM THE DATABASE rather than from the
      # struct captured before the follow-up.
      dashboard_after = Repo.get!(MeetingCandidate, dashboard_before.id)

      assert dashboard_after.transcript_chunk_ids == [dashboard_intent.transcript_chunk_id]
      assert dashboard_after.threading_events == []
      assert dashboard_after.last_utterance_at == dashboard_before.last_utterance_at
      assert dashboard_after.last_utterance_at == dashboard_after.heard_at
      assert dashboard_after.evidence_quote == @dashboard
    end

    test "a nil speaker never threads, even onto another unattributed candidate", context do
      _pid = start_threading_classifier!(context.meeting_id)

      # `segment_speaker/2` answers "" for a segment with no
      # attribution and stage 1 stores that as nil, precisely so two
      # unattributed strangers cannot read as one person continuing.
      first = say!(context, nil, @dashboard)
      second = say!(context, nil, @follow_up)

      dashboard = Candidates.get_by_intent_id(first.id)
      follow_up = Candidates.get_by_intent_id(second.id)

      assert is_nil(dashboard.speaker)
      assert is_nil(follow_up.speaker)

      assert length(Candidates.list_for_meeting(context.meeting_id)) == 2
      assert dashboard.transcript_chunk_ids == [first.transcript_chunk_id]
      assert follow_up.transcript_chunk_ids == [second.transcript_chunk_id]
      assert dashboard.threading_events == []
    end
  end

  describe "classify_and_enqueue — idempotent replay" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-idempotent"})
      assign_intent_role!(agent)
      drop_queue_for_room("room-idempotent")
      %{agent: agent}
    end

    test "same chunk twice produces :inserted then :duplicate; queue has one entry" do
      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, messages, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "assign_owner",
               "target_role" => "scribe",
               "confidence" => 0.9,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      # Broadcast the SAME payload twice — segment text is identical,
      # so the sha256(intent <> target_role <> chunk_text) dedupe key
      # collides.
      payload = %{
        room_id: "room-idempotent",
        transcript_id: "transcript-idem",
        segment: %{id: "seg-idem", text: "please own this bug", speaker_name: "bob"},
        meeting_id: meeting_id_for("room-idempotent")
      }

      :ok = MeetingsPubSub.broadcast_transcript_chunk("room-idempotent", payload)
      assert_receive {:classified, _m, %{dedupe_key_hit_or_new: :inserted}}, 500

      :ok = MeetingsPubSub.broadcast_transcript_chunk("room-idempotent", payload)
      assert_receive {:classified, _m, %{dedupe_key_hit_or_new: :duplicate}}, 500

      assert queued_for_room("room-idempotent") |> length() == 1
    end
  end

  # ── Content gate (pre-model) ──────────────────────────────────────────────
  #
  # The corpus below is verbatim from three real calls. The measured
  # baseline was ~25 dispatches across those calls, none of which
  # needed action; every MUST-DROP line is one of those wasted model
  # calls, and every MUST-KEEP line is an utterance a producer would
  # want surfaced.

  @gate_must_drop [
    "Yep.",
    "Mm-hmm.",
    "Yeah, wild.",
    "You guys?",
    "Skills.",
    "the problem.",
    "and assign them.",
    "In their view, okay.",
    "The meeting.",
    "with the back end.",
    "Right of the P.",
    "I didn't see this.",
    "Yeah, that's different.",
    "Yeah, that looks good."
  ]

  @gate_must_keep [
    "As an action item, Chris needs to start developing the podcast software on suite.",
    "A pretty simple HTML page for now, what we're trying to build is a dog training app.",
    "Give me the Fabrikam stuff so I can just make this Fabrikam",
    "Yeah, I mean, that's all well and good. This is on Cloudflare. Again, I have not been shown where the domain or anything like that is registered.",
    "Actually, they need sweet because they need the ability to add its skills and stuff."
  ]

  describe "content_bearing?/1 — transcript corpus" do
    test "drops every measured non-content utterance" do
      kept = Enum.filter(@gate_must_drop, &IntentClassifier.content_bearing?/1)

      assert kept == [],
             "these carry no actionable content and must not cost a model call: #{inspect(kept)}"
    end

    test "keeps every measured content-bearing utterance" do
      dropped = Enum.reject(@gate_must_keep, &IntentClassifier.content_bearing?/1)

      assert dropped == [],
             "a dropped real item is invisible and unrecoverable: #{inspect(dropped)}"
    end
  end

  describe "content_bearing?/1 — precision bias" do
    test "empty, whitespace-only and punctuation-only text is not content" do
      refute IntentClassifier.content_bearing?("")
      refute IntentClassifier.content_bearing?("   ")
      refute IntentClassifier.content_bearing?("... ?!")
    end

    test "non-binary input is not content" do
      refute IntentClassifier.content_bearing?(nil)
      refute IntentClassifier.content_bearing?(%{text: "hello"})
    end

    test "an all-backchannel run is dropped even past the short-utterance length" do
      refute IntentClassifier.content_bearing?("yeah yeah okay okay right sure yep totally")
    end

    test "anything longer than five words is kept regardless of shape" do
      # Deliberately vapid, deliberately kept: past five words the gate
      # stops guessing and pays for the model call.
      assert IntentClassifier.content_bearing?("the thing over there near the other thing")
    end

    test "short imperatives survive — they are exactly what must never be lost" do
      assert IntentClassifier.content_bearing?("ship it")
      assert IntentClassifier.content_bearing?("file a ticket")
      assert IntentClassifier.content_bearing?("Chris, own this.")
    end

    test "fragments merged back into a whole survive even though each half would not" do
      # Both halves of this real split are rejected alone...
      refute IntentClassifier.content_bearing?("and assign them.")
      refute IntentClassifier.content_bearing?("with the back end.")

      # ...and survive as part of the merged whole.
      assert IntentClassifier.content_bearing?(
               "Take the two open tickets and assign them with the back end."
             )

      # Worth being precise about what the merge does and does not buy.
      # The canonical split from the brief —
      # "I just put together a file" / "in the past 30 minutes." — has a
      # SIX-word first half, which is past the gate's short-utterance
      # threshold, so the gate keeps it either way. Merging fixes the
      # CLASSIFICATION of that pair (one whole thought instead of two
      # half ones), not the gating of it.
      assert IntentClassifier.content_bearing?("I just put together a file")
      refute IntentClassifier.content_bearing?("in the past 30 minutes.")
    end
  end

  describe "handle_info/2 — content gate skips the model call" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-gate"})
      assign_intent_role!(agent)
      drop_queue_for_room("room-gate")
      %{agent: agent}
    end

    test "a backchannel chunk emits :no_content, calls no provider, and enqueues nothing" do
      _ = attach_recorder!(:skipped, :skipped)
      {pid, _name} = start_classifier!()

      test_pid = self()

      plant_stub_fun(pid, fn _c, _m, _o ->
        send(test_pid, :provider_called)
        {:error, :should_not_happen}
      end)

      _ =
        broadcast_chunk("room-gate",
          segment: %{id: "seg-gate-1", text: "Yeah, that looks good.", speaker_name: "alice"}
        )

      assert_receive {:skipped, %{count: 1},
                      %{reason: :no_content, room_id: "room-gate", chunk_excerpt: excerpt}},
                     500

      assert excerpt == "Yeah, that looks good."
      refute_received :provider_called
      assert queued_for_room("room-gate") == []
      assert Process.alive?(pid)
    end

    test ":no_content is a distinct reason — not folded into :no_assignee" do
      _ = attach_recorder!(:skipped, :skipped)
      {pid, _name} = start_classifier!()
      test_pid = self()

      plant_stub_fun(pid, fn _c, _m, _o ->
        send(test_pid, :provider_called)
        {:error, :should_not_happen}
      end)

      _ = broadcast_chunk("room-gate", segment: %{id: "seg-gate-2", text: "Mm-hmm."})

      assert_receive {:skipped, _m, %{reason: reason}}, 500
      refute_received :provider_called
      assert reason == :no_content
      refute reason == :no_assignee
    end

    test "a content-bearing chunk still classifies normally after a gated one" do
      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, messages, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "assign_owner",
               "target_role" => "scribe",
               "confidence" => 0.9,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      _ = broadcast_chunk("room-gate", segment: %{id: "seg-gate-3", text: "Yep."})
      _ = broadcast_chunk("room-gate", segment: %{id: "seg-gate-4", text: "The meeting."})

      _ =
        broadcast_chunk("room-gate",
          segment: %{
            id: "seg-gate-5",
            text: "As an action item, Chris needs to start developing the podcast software"
          }
        )

      assert_receive {:classified, _m, %{dedupe_key_hit_or_new: :inserted}}, 500
      assert length(queued_for_room("room-gate")) == 1
    end

    test "the gated chunk still warms the context window for the next utterance" do
      _ = attach_recorder!(:skipped, :skipped)
      {pid, _name} = start_classifier!(context_window_size: 3)
      test_pid = self()

      plant_stub_fun(pid, fn _c, _m, _o ->
        send(test_pid, :provider_called)
        {:error, :should_not_happen}
      end)

      _ =
        broadcast_chunk("room-gate",
          segment: %{id: "seg-gate-6", text: "the problem.", speaker_name: "alice"}
        )

      assert_receive {:skipped, _m, %{reason: :no_content}}, 500
      refute_received :provider_called

      # A fragment is worthless as an intent but valuable as context for
      # resolving the NEXT utterance's pronouns.
      assert [%{text: "the problem."}] = :sys.get_state(pid).recent_chunks["room-gate"]
    end
  end

  # ── Same-speaker debounce / merge ─────────────────────────────────────────
  #
  # `config/test.exs` pins `:intent_classifier_debounce_ms` to 0 so the
  # rest of this suite delivers synchronously. These cases opt in with
  # an explicit `debounce_ms:`.

  describe "same-speaker debounce" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-debounce"})
      assign_intent_role!(agent)
      drop_queue_for_room("room-debounce")
      force_fallback_prompt!()
      %{agent: agent}
    end

    test "two fragments from the same speaker classify ONCE, on the merged text" do
      {pid, _name} = start_classifier!(debounce_ms: 400)
      plant_stub_fun(pid, capture_prompt_stub(self()))

      capture_log(fn ->
        for {id, text} <- [
              {"seg-d1", "I just put together a file"},
              {"seg-d2", "in the past 30 minutes."}
            ] do
          _ =
            broadcast_chunk("room-debounce",
              segment: %{id: id, text: text, speaker_name: "alice"}
            )
        end

        assert_receive {:captured_prompt, messages}, 1_000

        prompt =
          messages
          |> Enum.find(fn %{role: role} -> role == "system" end)
          |> Map.fetch!(:content)

        assert prompt =~ "I just put together a file in the past 30 minutes."

        # Exactly one classification — the second fragment did not get
        # its own model call.
        refute_receive {:captured_prompt, _}, 300
      end)

      assert length(queued_for_room("room-debounce")) == 1
    end

    test "the merged utterance is ONE context-window entry, not two" do
      {pid, _name} = start_classifier!(debounce_ms: 400, context_window_size: 3)
      plant_stub_fun(pid, capture_prompt_stub(self()))

      capture_log(fn ->
        _ =
          broadcast_chunk("room-debounce",
            segment: %{id: "seg-w1", text: "we should ship the podcast", speaker_name: "alice"}
          )

        _ =
          broadcast_chunk("room-debounce",
            segment: %{id: "seg-w2", text: "software before Friday.", speaker_name: "alice"}
          )

        assert_receive {:captured_prompt, _}, 1_000
      end)

      assert [%{text: text}] = :sys.get_state(pid).recent_chunks["room-debounce"]
      assert text == "we should ship the podcast software before Friday."
    end

    test "a speaker change flushes the held turn immediately" do
      {pid, _name} = start_classifier!(debounce_ms: 5_000)
      plant_stub_fun(pid, capture_prompt_stub(self()))

      capture_log(fn ->
        _ =
          broadcast_chunk("room-debounce",
            segment: %{
              id: "seg-s1",
              text: "we should ship the podcast software",
              speaker_name: "alice"
            }
          )

        # Nothing yet — alice's turn is still open.
        refute_receive {:captured_prompt, _}, 200

        _ =
          broadcast_chunk("room-debounce",
            segment: %{
              id: "seg-s2",
              text: "someone needs to write the docs first",
              speaker_name: "bob"
            }
          )

        # Bob's arrival is an utterance boundary: alice classifies now,
        # well inside the 5s quiet window that has not elapsed.
        assert_receive {:captured_prompt, messages}, 1_000

        prompt =
          messages
          |> Enum.find(fn %{role: role} -> role == "system" end)
          |> Map.fetch!(:content)

        assert prompt =~ "we should ship the podcast software"
        refute prompt =~ "someone needs to write the docs first"
      end)
    end

    test "max_hold_ms caps a monologue that never pauses" do
      {pid, _name} = start_classifier!(debounce_ms: 5_000, max_hold_ms: 100)
      plant_stub_fun(pid, capture_prompt_stub(self()))

      capture_log(fn ->
        _ =
          broadcast_chunk("room-debounce",
            segment: %{id: "seg-m1", text: "we should ship the thing", speaker_name: "alice"}
          )

        Process.sleep(150)

        _ =
          broadcast_chunk("room-debounce",
            segment: %{id: "seg-m2", text: "before Friday afternoon", speaker_name: "alice"}
          )

        # Second fragment pushes elapsed past max_hold_ms, so the merged
        # utterance flushes without waiting out the 5s debounce.
        assert_receive {:captured_prompt, messages}, 1_000

        prompt =
          messages
          |> Enum.find(fn %{role: role} -> role == "system" end)
          |> Map.fetch!(:content)

        assert prompt =~ "we should ship the thing before Friday afternoon"
      end)
    end

    test "meeting_finished FLUSHES the held chunk rather than dropping it" do
      {pid, _name} = start_classifier!(debounce_ms: 5_000)
      plant_stub_fun(pid, capture_prompt_stub(self()))

      capture_log(fn ->
        _ =
          broadcast_chunk("room-debounce",
            segment: %{
              id: "seg-f1",
              text: "we should ship the podcast software",
              speaker_name: "alice"
            }
          )

        refute_receive {:captured_prompt, _}, 200

        :ok =
          MeetingsPubSub.broadcast_meeting_finished("room-debounce", %{
            room_id: "room-debounce",
            transcript_id: "t-debounce",
            space_id: "s-debounce"
          })

        # The last thing said in a meeting is exactly where action items
        # live — losing it would be worse than the noise we removed.
        assert_receive {:captured_prompt, _}, 1_000
      end)

      # Deliberately NOT asserting on the queue here: `IntentQueue`
      # subscribes to the same `meeting:finished` broadcast and stops the
      # meeting's queue process, so a row count after the flush races the
      # teardown. The captured prompt above is the proof that the held
      # chunk classified rather than evaporating.
      refute Map.has_key?(:sys.get_state(pid).recent_chunks, "room-debounce")
    end

    test "shutdown FLUSHES every held room" do
      {pid, _name} = start_classifier!(debounce_ms: 5_000)
      plant_stub_fun(pid, capture_prompt_stub(self()))

      capture_log(fn ->
        _ =
          broadcast_chunk("room-debounce",
            segment: %{
              id: "seg-t1",
              text: "we should ship the podcast software",
              speaker_name: "alice"
            }
          )

        refute_receive {:captured_prompt, _}, 200

        # Supervised stop → trap_exit → terminate/2 → flush.
        :ok = GenServer.stop(pid, :normal, 2_000)

        assert_receive {:captured_prompt, _}, 1_000
      end)
    end

    test "a gated fragment plus a gated fragment can merge into a kept utterance" do
      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!(debounce_ms: 400)

      plant_stub_fun(pid, fn _c, messages, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "assign_owner",
               "target_role" => "scribe",
               "confidence" => 0.9,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      # Each half fails the gate on its own.
      refute IntentClassifier.content_bearing?("and assign them.")
      refute IntentClassifier.content_bearing?("with the back end.")

      for {id, text} <- [
            {"seg-g1", "Take the two open tickets"},
            {"seg-g2", "and assign them."},
            {"seg-g3", "with the back end."}
          ] do
        _ =
          broadcast_chunk("room-debounce",
            segment: %{id: id, text: text, speaker_name: "alice"}
          )
      end

      assert_receive {:classified, _m, %{dedupe_key_hit_or_new: :inserted}}, 1_000
      assert length(queued_for_room("room-debounce")) == 1
    end
  end

  describe "classify_and_enqueue — template fallback" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-fallback"})
      assign_intent_role!(agent)
      drop_queue_for_room("room-fallback")

      # Nuke any pre-seeded row for the slug so `render_template/2`
      # definitely returns {:error, :not_found}.
      case PromptTemplates.get_template_by_slug(@prompt_slug) do
        nil -> :ok
        template -> PromptTemplates.delete_template(template)
      end

      %{agent: agent}
    end

    test "logs the warning, emits template_fallback telemetry, entry still lands" do
      _ = attach_recorder!(:template_fallback, :fallback)
      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, messages, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "capture_action",
               "target_role" => "scribe",
               "confidence" => 0.6,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      log =
        capture_log([level: :warning], fn ->
          _ = broadcast_chunk("room-fallback")

          assert_receive {:fallback, %{count: 1},
                          %{room_id: "room-fallback", slug: @prompt_slug}},
                         500

          assert_receive {:classified, _m, %{dedupe_key_hit_or_new: :inserted}}, 500
        end)

      assert log =~ "prompt template #{@prompt_slug} missing"
      assert queued_for_room("room-fallback") |> length() == 1
    end
  end

  describe "classify_and_enqueue — model error" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-model-error"})
      assign_intent_role!(agent)
      drop_queue_for_room("room-model-error")
      %{agent: agent}
    end

    test "logs :warning, emits model_error telemetry, no queue entry, subsequent chunk works" do
      _ = attach_recorder!(:model_error, :model_error)
      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!()

      # First stub: HTTP 500 shape from the provider (mirrors
      # `Platform.Agents.Providers.Ollama.chat/3` failure shape).
      plant_stub_fun(pid, fn _c, _m, _o ->
        {:error, {:http_error, 500, %{"error" => "boom"}}}
      end)

      log =
        capture_log([level: :warning], fn ->
          _ = broadcast_chunk("room-model-error")

          assert_receive {:model_error, %{count: 1}, %{room_id: "room-model-error"}}, 500
        end)

      assert log =~ "LLM call failed"
      assert log =~ "room-model-error"
      assert queued_for_room("room-model-error") == []
      assert Process.alive?(pid), "classifier crashed on model error"

      # Second stub: now the provider returns cleanly. The classifier
      # should process this new chunk without any state corruption from
      # the earlier failure.
      plant_stub_fun(pid, fn _c, messages, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "recovered",
               "target_role" => "scribe",
               "confidence" => 0.5,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      _ = broadcast_chunk("room-model-error", segment: %{id: "seg-2", text: "post-recovery"})

      assert_receive {:classified, _m, %{room_id: "room-model-error", intent: "recovered"}},
                     500

      assert queued_for_room("room-model-error") |> length() == 1
    end

    test "provider raising is trapped and reported as model_error" do
      _ = attach_recorder!(:model_error, :model_error)
      {pid, _name} = start_classifier!()
      plant_stub_fun(pid, fn _c, _m, _o -> raise "boom from stub" end)

      capture_log([level: :warning], fn ->
        _ = broadcast_chunk("room-model-error-raise")
        assert_receive {:model_error, %{count: 1}, %{room_id: "room-model-error-raise"}}, 500
      end)

      assert Process.alive?(pid)
    end
  end

  describe "classify_and_enqueue — parse error" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-parse-error"})
      assign_intent_role!(agent)
      drop_queue_for_room("room-parse-error")
      %{agent: agent}
    end

    test "emits parse_error telemetry on non-JSON content, no queue entry, no crash" do
      _ = attach_recorder!(:parse_error, :parse_error)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, _m, _o ->
        {:ok, %{content: "definitely not json {{{"}}
      end)

      capture_log([level: :warning], fn ->
        _ = broadcast_chunk("room-parse-error")
        assert_receive {:parse_error, %{count: 1}, %{room_id: "room-parse-error"}}, 500
      end)

      assert queued_for_room("room-parse-error") == []
      assert Process.alive?(pid)
    end

    test "emits parse_error when JSON decodes but required keys are missing" do
      _ = attach_recorder!(:parse_error, :parse_error)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, _m, _o ->
        {:ok, %{content: Jason.encode!(%{"intent" => "no_role_no_conf"})}}
      end)

      capture_log([level: :warning], fn ->
        _ = broadcast_chunk("room-parse-missing-keys")
        assert_receive {:parse_error, %{count: 1}, %{room_id: "room-parse-missing-keys"}}, 500
      end)

      assert queued_for_room("room-parse-missing-keys") == []
    end
  end

  # The prompt's `target_role` enum is closed and its last member is the
  # JSON literal `null` — the answer the model is TOLD to give for
  # `off_topic`. Before this fix the parse guard demanded a binary, so
  # the instructed answer fell through to the malformed-payload branch:
  # a correct decline enqueued nothing and incremented `parse_error`,
  # making the model look broken precisely when it was right. 83 of the
  # 102 recorded negatives take this path.
  describe "classify_and_enqueue — JSON null target_role" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-null-role"})
      assign_intent_role!(agent)
      drop_queue_for_room("room-null-role")
      drop_queue_for_room("room-null-role-malformed")
      %{agent: agent}
    end

    test "off_topic with JSON null target_role enqueues and emits NO parse_error" do
      _ = attach_recorder!(:parse_error, :parse_error)
      terminal = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, _m, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "off_topic",
               "target_role" => nil,
               "confidence" => 0.9
             })
         }}
      end)

      _ = broadcast_chunk("room-null-role")

      # The decline is VISIBLE: it lands in the queue where the
      # corrections corpus can learn from it, spelled with the same
      # "nobody" token the stage-2 demotion path writes.
      assert_receive {:classified, %{count: 1},
                      %{room_id: "room-null-role", intent: "off_topic", target_role: "null"}},
                     500

      refute_receive {:parse_error, _, _}, 200

      assert [row] = queued_for_room("room-null-role")
      assert row.classified_intent == "off_topic"
      assert row.target_role == "null"

      :telemetry.detach(terminal)
    end

    # ANTI-VACUITY CONTROL. Without this, a "fix" that accepted any
    # shape at all — or that deleted the parse_error branch outright —
    # would pass the test above. A structurally-invalid `target_role`
    # (here a number, which no member of the closed enum can be) must
    # STILL be refused and still counted as a parse error.
    test "a non-string, non-null target_role still emits parse_error and enqueues nothing" do
      _ = attach_recorder!(:parse_error, :parse_error)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, _m, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "action_items",
               "target_role" => 42,
               "confidence" => 0.9,
               "evidence_quote" => "we need to schedule a follow-up on the billing bug"
             })
         }}
      end)

      capture_log([level: :warning], fn ->
        _ = broadcast_chunk("room-null-role-malformed")

        assert_receive {:parse_error, %{count: 1}, %{room_id: "room-null-role-malformed"}}, 500
      end)

      assert queued_for_room("room-null-role-malformed") == []
      assert Process.alive?(pid)
    end
  end

  describe "classify_and_enqueue — truncated output" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-truncated"})
      assign_intent_role!(agent)

      Enum.each(
        ~w(room-truncated-empty room-truncated-whitespace room-truncated-length
           room-truncated-string-key room-truncated-negative room-truncated-shape),
        &drop_queue_for_room/1
      )

      %{agent: agent}
    end

    # EVERY test in this block attaches all THREE recorders —
    # `truncated_output`, `parse_error` and `model_error` — and asserts
    # both what DID fire and what did NOT.
    #
    # That is the entire point of the block. On main an empty
    # completion was a BINARY, so the success clause accepted it,
    # `Jason.decode("")` failed, and the event that reached the
    # operator was `parse_error` — indistinguishable from a model
    # emitting malformed JSON, which is why an exhausted token budget
    # was triaged for weeks as a flaky classifier. If any pair of these
    # three names collapses into one, that bug recurs invisibly.

    test "empty content emits truncated_output and NEITHER parse_error NOR model_error" do
      _ = attach_recorder!(:truncated_output, :truncated)
      _ = attach_recorder!(:parse_error, :parse_error)
      _ = attach_recorder!(:model_error, :model_error)
      {pid, _name} = start_classifier!()

      # Exactly what `Ollama.extract_message_content/1` hands back when
      # the model burned its budget on `reasoning_content`: `""`, a
      # binary, with no `finish_reason` key at all — stubs omit it and
      # the classifier must not crash on the absence.
      plant_stub_fun(pid, fn _c, _m, _o -> {:ok, %{content: ""}} end)

      log =
        capture_log([level: :warning], fn ->
          _ = broadcast_chunk("room-truncated-empty")

          assert_receive {:truncated, %{count: 1},
                          %{room_id: "room-truncated-empty", finish_reason: nil}},
                         500
        end)

      refute_receive {:parse_error, _, _}, 200
      refute_receive {:model_error, _, _}, 200

      # A human reading production logs must see "budget", not "flaky".
      assert String.downcase(log) =~ "budget"
      assert log =~ "room-truncated-empty"

      # Control flow is UNCHANGED — only the name is new.
      assert queued_for_room("room-truncated-empty") == []
      assert Process.alive?(pid), "classifier crashed on empty model output"
    end

    test "whitespace-only content is empty too — truncated_output, not parse_error" do
      _ = attach_recorder!(:truncated_output, :truncated)
      _ = attach_recorder!(:parse_error, :parse_error)
      _ = attach_recorder!(:model_error, :model_error)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _c, _m, _o -> {:ok, %{content: "  \n\t  "}} end)

      capture_log([level: :warning], fn ->
        _ = broadcast_chunk("room-truncated-whitespace")

        assert_receive {:truncated, %{count: 1}, %{room_id: "room-truncated-whitespace"}}, 500
      end)

      refute_receive {:parse_error, _, _}, 200
      refute_receive {:model_error, _, _}, 200

      assert queued_for_room("room-truncated-whitespace") == []
      assert Process.alive?(pid)
    end

    test "finish_reason \"length\" rides through into the telemetry metadata" do
      _ = attach_recorder!(:truncated_output, :truncated)
      _ = attach_recorder!(:parse_error, :parse_error)
      _ = attach_recorder!(:model_error, :model_error)
      {pid, _name} = start_classifier!()

      # The production shape: the provider succeeded, reported it ran
      # out of completion tokens, and handed back nothing.
      plant_stub_fun(pid, fn _c, _m, _o ->
        {:ok, %{content: "", finish_reason: "length", model: "qwen3:1.7b"}}
      end)

      log =
        capture_log([level: :warning], fn ->
          _ = broadcast_chunk("room-truncated-length")

          assert_receive {:truncated, %{count: 1},
                          %{room_id: "room-truncated-length", finish_reason: "length"}},
                         500
        end)

      refute_receive {:parse_error, _, _}, 200
      refute_receive {:model_error, _, _}, 200

      assert log =~ "length"
      assert queued_for_room("room-truncated-length") == []
    end

    test "string-key provider shape is normalised in the same place" do
      _ = attach_recorder!(:truncated_output, :truncated)
      _ = attach_recorder!(:parse_error, :parse_error)
      _ = attach_recorder!(:model_error, :model_error)
      {pid, _name} = start_classifier!()

      # The guard must live in ONE place: applying it to the atom-key
      # shape and forgetting the string-key shape is how this comes
      # back.
      plant_stub_fun(pid, fn _c, _m, _o ->
        {:ok, %{"content" => "   ", "finish_reason" => "length"}}
      end)

      capture_log([level: :warning], fn ->
        _ = broadcast_chunk("room-truncated-string-key")

        assert_receive {:truncated, %{count: 1},
                        %{room_id: "room-truncated-string-key", finish_reason: "length"}},
                       500
      end)

      refute_receive {:parse_error, _, _}, 200
      refute_receive {:model_error, _, _}, 200
    end

    test "non-empty non-JSON content still emits parse_error and NOT truncated_output" do
      _ = attach_recorder!(:truncated_output, :truncated)
      _ = attach_recorder!(:parse_error, :parse_error)
      _ = attach_recorder!(:model_error, :model_error)
      {pid, _name} = start_classifier!()

      # The reverse direction. `finish_reason` is "length" here ON
      # PURPOSE: the classifier keys off EMPTINESS, not off the finish
      # reason, so a truncated-but-non-empty completion is still a
      # parse failure and must not be renamed.
      plant_stub_fun(pid, fn _c, _m, _o ->
        {:ok, %{content: "definitely not json {{{", finish_reason: "length"}}
      end)

      capture_log([level: :warning], fn ->
        _ = broadcast_chunk("room-truncated-negative")

        assert_receive {:parse_error, %{count: 1}, %{room_id: "room-truncated-negative"}}, 500
      end)

      refute_receive {:truncated, _, _}, 200
      refute_receive {:model_error, _, _}, 200

      assert queued_for_room("room-truncated-negative") == []
    end

    test "an unrecognised map is still model_error, not truncated_output" do
      _ = attach_recorder!(:truncated_output, :truncated)
      _ = attach_recorder!(:parse_error, :parse_error)
      _ = attach_recorder!(:model_error, :model_error)
      {pid, _name} = start_classifier!()

      # The third name. No binary `content` key at all — the shape the
      # classifier genuinely does not recognise. This branch stays
      # exactly as it was.
      plant_stub_fun(pid, fn _c, _m, _o -> {:ok, %{message: "no content key here"}} end)

      capture_log([level: :warning], fn ->
        _ = broadcast_chunk("room-truncated-shape")

        assert_receive {:model_error, %{count: 1}, %{room_id: "room-truncated-shape"}}, 500
      end)

      refute_receive {:truncated, _, _}, 200
      refute_receive {:parse_error, _, _}, 200

      assert queued_for_room("room-truncated-shape") == []
      assert Process.alive?(pid)
    end
  end

  describe "malformed events" do
    test "ignores unknown messages without crashing" do
      {pid, _name} = start_classifier!()

      send(pid, :garbage)
      send(pid, {:unrelated_topic, %{}})
      Process.sleep(30)

      assert Process.alive?(pid)
    end
  end

  describe "chunk buffer — sliding window" do
    test "prepends the current chunk into state.recent_chunks (head-first)" do
      {pid, _name} = start_classifier!(context_window_size: 3)

      _ =
        broadcast_chunk("room-buffer-1",
          segment: %{id: "seg-1", text: "first chunk", speaker_name: "alice"}
        )

      # Give the classifier's handle_info a beat to process.
      Process.sleep(30)

      state = :sys.get_state(pid)
      assert Map.has_key?(state.recent_chunks, "room-buffer-1")
      [head] = state.recent_chunks["room-buffer-1"]
      assert head.text == "first chunk"
      assert head.speaker == "alice"
    end

    test "keeps at most context_window_size + 1 entries per room (head = current)" do
      {pid, _name} = start_classifier!(context_window_size: 3)

      for i <- 1..5 do
        _ =
          broadcast_chunk("room-buffer-window",
            segment: %{id: "seg-#{i}", text: "chunk #{i}", speaker_name: "alice"}
          )
      end

      Process.sleep(50)

      state = :sys.get_state(pid)
      window = state.recent_chunks["room-buffer-window"]

      # window size 3 => head + prior 3 => 4 stored entries max.
      assert length(window) == 4

      # Most-recent-first: head is chunk 5, oldest kept is chunk 2.
      assert Enum.map(window, & &1.text) ==
               ["chunk 5", "chunk 4", "chunk 3", "chunk 2"]
    end

    test "buffers are per-room isolated — interleaved chunks stay separate" do
      {pid, _name} = start_classifier!(context_window_size: 3)

      _ =
        broadcast_chunk("room-A", segment: %{id: "a1", text: "A1", speaker_name: "alice"})

      _ =
        broadcast_chunk("room-B", segment: %{id: "b1", text: "B1", speaker_name: "bob"})

      _ =
        broadcast_chunk("room-A", segment: %{id: "a2", text: "A2", speaker_name: "alice"})

      Process.sleep(50)

      state = :sys.get_state(pid)
      assert Enum.map(state.recent_chunks["room-A"], & &1.text) == ["A2", "A1"]
      assert Enum.map(state.recent_chunks["room-B"], & &1.text) == ["B1"]
    end

    test "buffer stays populated even when there is no assignee (warms the window)" do
      _ = attach_recorder!(:skipped, :skipped)
      {pid, _name} = start_classifier!(context_window_size: 3)

      # No assign_intent_role! call — assignee lookup returns nil.
      _ =
        capture_log(fn ->
          _ =
            broadcast_chunk("room-no-assignee-warm",
              segment: %{id: "warm-1", text: "warm chunk", speaker_name: "carol"}
            )

          assert_receive {:skipped, %{count: 1}, %{reason: :no_assignee}}, 500
        end)

      state = :sys.get_state(pid)
      assert [entry] = state.recent_chunks["room-no-assignee-warm"]
      assert entry.text == "warm chunk"
      assert entry.speaker == "carol"
    end
  end

  describe "chunk buffer — cleanup on meeting_finished" do
    test "clears the per-room buffer when meeting_finished fires for that room" do
      {pid, _name} = start_classifier!(context_window_size: 3)

      _ = broadcast_chunk("room-cleanup", segment: %{id: "c1", text: "c1"})
      _ = broadcast_chunk("room-cleanup", segment: %{id: "c2", text: "c2"})
      Process.sleep(30)

      assert Map.has_key?(:sys.get_state(pid).recent_chunks, "room-cleanup")

      :ok =
        MeetingsPubSub.broadcast_meeting_finished("room-cleanup", %{
          room_id: "room-cleanup",
          transcript_id: "t-cleanup",
          space_id: "s-cleanup"
        })

      Process.sleep(30)

      refute Map.has_key?(:sys.get_state(pid).recent_chunks, "room-cleanup")
      assert Process.alive?(pid)
    end

    test "cleanup is scoped — a different room's buffer is untouched" do
      {pid, _name} = start_classifier!(context_window_size: 3)

      _ = broadcast_chunk("room-keep", segment: %{id: "k1", text: "k1"})
      _ = broadcast_chunk("room-drop", segment: %{id: "d1", text: "d1"})
      Process.sleep(30)

      :ok =
        MeetingsPubSub.broadcast_meeting_finished("room-drop", %{
          room_id: "room-drop",
          transcript_id: "t-drop",
          space_id: "s-drop"
        })

      Process.sleep(30)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.recent_chunks, "room-drop")
      assert Enum.map(state.recent_chunks["room-keep"], & &1.text) == ["k1"]
    end
  end

  # ── Stage 2 (task 019f474d) — prompt context injection ────────────────────
  #
  # These tests capture the messages the classifier hands to the
  # provider so we can assert on the rendered prompt string. The
  # stub returns a fixed happy-path JSON so the pipeline still runs
  # to completion (queue write + terminal telemetry) and we can
  # correlate rendered prompt to enqueue result.

  # Delete the DB template so `resolve_prompt/5` walks the inline
  # fallback branch. That's the only prompt content we can assert
  # exact strings on from within the test — the DB template body is
  # rewritten by a migration whose exact wording lives elsewhere.
  defp force_fallback_prompt! do
    case PromptTemplates.get_template_by_slug(@prompt_slug) do
      nil -> :ok
      template -> PromptTemplates.delete_template(template)
    end
  end

  # Stub that captures every messages list it is called with into the
  # test's mailbox and returns a fixed valid intent JSON — so the
  # classifier makes it all the way to enqueue + terminal telemetry.
  defp capture_prompt_stub(test_pid) do
    fn _creds, messages, _opts ->
      send(test_pid, {:captured_prompt, messages})

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "intent" => "brief_worthy",
             "target_role" => "meeting_scribe",
             "confidence" => 0.8,
             "evidence_quote" => echo_quote(messages)
           })
       }}
    end
  end

  describe "classify_and_enqueue — context injection" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-context"})
      assign_intent_role!(agent)
      drop_queue_for_room("room-context")
      force_fallback_prompt!()
      %{agent: agent}
    end

    test "3rd chunk's prompt lists chunks 1-2 as prior context with do-not-classify framing and excludes the current chunk" do
      {pid, _name} = start_classifier!(context_window_size: 3)
      plant_stub_fun(pid, capture_prompt_stub(self()))

      capture_log(fn ->
        _ =
          broadcast_chunk("room-context",
            segment: %{
              id: "seg-c1",
              text: "we should review the billing report first",
              speaker_name: "alice",
              timestamp_ms: 5_000
            }
          )

        _ = assert_receive {:captured_prompt, _}, 500

        _ =
          broadcast_chunk("room-context",
            segment: %{
              id: "seg-c2",
              text: "someone needs to fix the billing bug",
              speaker_name: "bob",
              timestamp_ms: 12_000
            }
          )

        _ = assert_receive {:captured_prompt, _}, 500

        _ =
          broadcast_chunk("room-context",
            segment: %{
              id: "seg-c3",
              text: "third chunk should be classified",
              speaker_name: "carol",
              timestamp_ms: 20_000
            }
          )

        assert_receive {:captured_prompt, messages}, 500

        prompt =
          messages
          |> Enum.find(fn %{role: role} -> role == "system" end)
          |> Map.fetch!(:content)

        # do-not-classify framing must be present
        assert prompt =~ "DO NOT classify these lines"

        # chunks 1 and 2 appear in chronological order (oldest first)
        idx_1 = :binary.match(prompt, "we should review the billing report first") |> elem(0)
        idx_2 = :binary.match(prompt, "someone needs to fix the billing bug") |> elem(0)
        assert idx_1 < idx_2, "prior context must be rendered oldest-first"

        # timestamps + speakers render as `- [MM:SS] speaker: text`
        assert prompt =~ "- [00:05] alice: we should review the billing report first"
        assert prompt =~ "- [00:12] bob: someone needs to fix the billing bug"

        # current chunk MUST NOT appear inside the prior-context block —
        # it's rendered as the Transcript chunk line in the fallback
        # template. We assert absence by pattern: the third chunk's
        # text must not appear preceded by the `- [` list marker.
        refute prompt =~ "- [00:20] carol: third chunk should be classified"

        # It DOES appear as the current utterance in the fallback
        # template.
        assert prompt =~ "third chunk should be classified"
      end)
    end
  end

  describe "classify_and_enqueue — sliding window in prompt" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-window"})
      assign_intent_role!(agent)
      drop_queue_for_room("room-window")
      force_fallback_prompt!()
      %{agent: agent}
    end

    test "with window size 3 and 5 chunks, the 5th sees chunks 2..4 as prior context — chunk 1 evicted" do
      {pid, _name} = start_classifier!(context_window_size: 3)
      plant_stub_fun(pid, capture_prompt_stub(self()))

      capture_log(fn ->
        # Broadcast 5 chunks; capture each rendered prompt in order.
        prompts =
          for i <- 1..5 do
            _ =
              broadcast_chunk("room-window",
                segment: %{
                  id: "seg-w#{i}",
                  text: "we should review window chunk #{i}",
                  speaker_name: "spk-#{i}",
                  timestamp_ms: i * 1_000
                }
              )

            assert_receive {:captured_prompt, messages}, 500

            messages
            |> Enum.find(fn %{role: role} -> role == "system" end)
            |> Map.fetch!(:content)
          end

        fifth_prompt = List.last(prompts)

        # Chunks 2, 3, 4 land in the prior-context block for chunk 5.
        assert fifth_prompt =~ "- [00:02] spk-2: we should review window chunk 2"
        assert fifth_prompt =~ "- [00:03] spk-3: we should review window chunk 3"
        assert fifth_prompt =~ "- [00:04] spk-4: we should review window chunk 4"

        # Chunk 1 must have been evicted from the 3-wide window when
        # chunk 5 renders — its formatted line must not appear.
        refute fifth_prompt =~ "- [00:01] spk-1: we should review window chunk 1",
               "chunk 1 must be evicted from a 3-wide window when chunk 5 renders"

        # Chunk 5 is the CURRENT utterance, not in the prior list.
        refute fifth_prompt =~ "- [00:05] spk-5: we should review window chunk 5"
        assert fifth_prompt =~ "we should review window chunk 5"
      end)
    end
  end

  describe "classify_and_enqueue — dedupe key unchanged by context" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-dedupe"})
      assign_intent_role!(agent)
      drop_queue_for_room("room-dedupe")
      %{agent: agent}
    end

    test "A -> B -> C -> A: the second A collides with the first even though the surrounding context differs" do
      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!(context_window_size: 3)

      # Fixed happy-path stub — same intent+role for every chunk, so
      # the dedupe key depends solely on `chunk_text`.
      plant_stub_fun(pid, fn _c, messages, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "brief_worthy",
               "target_role" => "meeting_scribe",
               "confidence" => 0.75,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      utter_a = "please summarise last quarter's revenue"
      utter_b = "we need to update the billing docs"
      utter_c = "who is on the release call"

      # First A
      :ok =
        MeetingsPubSub.broadcast_transcript_chunk("room-dedupe", %{
          room_id: "room-dedupe",
          transcript_id: "t-dedupe-a1",
          meeting_id: meeting_id_for("room-dedupe"),
          segment: %{id: "seg-a1", text: utter_a, speaker_name: "alice"}
        })

      assert_receive {:classified, _m,
                      %{dedupe_key_hit_or_new: :inserted, dedupe_key: dedupe_key_first}},
                     500

      # B
      :ok =
        MeetingsPubSub.broadcast_transcript_chunk("room-dedupe", %{
          room_id: "room-dedupe",
          transcript_id: "t-dedupe-b",
          meeting_id: meeting_id_for("room-dedupe"),
          segment: %{id: "seg-b", text: utter_b, speaker_name: "bob"}
        })

      assert_receive {:classified, _m, _md}, 500

      # C
      :ok =
        MeetingsPubSub.broadcast_transcript_chunk("room-dedupe", %{
          room_id: "room-dedupe",
          transcript_id: "t-dedupe-c",
          meeting_id: meeting_id_for("room-dedupe"),
          segment: %{id: "seg-c", text: utter_c, speaker_name: "carol"}
        })

      assert_receive {:classified, _m, _md}, 500

      # Second A — same utterance text, different surrounding context
      # (window now holds C+B before it, not empty).
      :ok =
        MeetingsPubSub.broadcast_transcript_chunk("room-dedupe", %{
          room_id: "room-dedupe",
          transcript_id: "t-dedupe-a2",
          meeting_id: meeting_id_for("room-dedupe"),
          segment: %{id: "seg-a2", text: utter_a, speaker_name: "alice"}
        })

      assert_receive {:classified, _m,
                      %{dedupe_key_hit_or_new: :duplicate, dedupe_key: dedupe_key_second}},
                     500

      # The dedupe key MUST NOT depend on prior context — it is a
      # function of `intent <> target_role <> chunk_text` only.
      assert dedupe_key_first == dedupe_key_second,
             "dedupe key must be identical for the same utterance regardless of context window"
    end
  end

  describe "chunk buffer — cleanup on meeting_finished clears prompt context" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-cleanup-context"})
      assign_intent_role!(agent)
      drop_queue_for_room("room-cleanup-context")
      force_fallback_prompt!()
      %{agent: agent}
    end

    test "after meeting_finished, the next chunk renders (no prior context) instead of the pre-cleanup window" do
      {pid, _name} = start_classifier!(context_window_size: 3)
      plant_stub_fun(pid, capture_prompt_stub(self()))

      capture_log(fn ->
        # Warm the window with two chunks — third will see them as prior.
        _ =
          broadcast_chunk("room-cleanup-context",
            segment: %{
              id: "seg-x1",
              text: "we should review the warmup notes",
              speaker_name: "alice",
              timestamp_ms: 1_000
            }
          )

        assert_receive {:captured_prompt, _}, 500

        _ =
          broadcast_chunk("room-cleanup-context",
            segment: %{
              id: "seg-x2",
              text: "someone must update the warmup docs",
              speaker_name: "bob",
              timestamp_ms: 2_000
            }
          )

        assert_receive {:captured_prompt, _}, 500

        # Fire the cleanup — this drops the room's buffer entry.
        :ok =
          MeetingsPubSub.broadcast_meeting_finished("room-cleanup-context", %{
            room_id: "room-cleanup-context",
            transcript_id: "t-cleanup-ctx",
            space_id: "s-cleanup-ctx"
          })

        # Wait for the cleanup to land in classifier state.
        Process.sleep(30)
        refute Map.has_key?(:sys.get_state(pid).recent_chunks, "room-cleanup-context")

        # Now broadcast a fresh chunk. Its prompt must render the
        # `(no prior context)` sentinel — NOT the warmup lines.
        _ =
          broadcast_chunk("room-cleanup-context",
            segment: %{
              id: "seg-x3",
              text: "post-cleanup utterance",
              speaker_name: "carol",
              timestamp_ms: 10_000
            }
          )

        assert_receive {:captured_prompt, messages}, 500

        prompt =
          messages
          |> Enum.find(fn %{role: role} -> role == "system" end)
          |> Map.fetch!(:content)

        assert prompt =~ "(no prior context)"
        refute prompt =~ "we should review the warmup notes"
        refute prompt =~ "someone must update the warmup docs"
      end)
    end
  end

  # ── Few-shot correction exemplars (task 019f70b8 stage 6, AC16) ───────────

  describe "classify_and_enqueue — correction exemplars in the prompt" do
    # These cases build a REAL org → project → meeting chain and let the
    # classifier resolve the org itself from the `meeting_id` on the
    # transcript payload. The rest of this file uses the synthetic
    # `"meeting-" <> room_id` id, which is correct for the ETS queue and
    # cannot resolve a tenant — so an exemplar test written on top of it
    # would assert against an empty corpus forever and stay green
    # against a classifier that never queried one.

    setup do
      agent = create_agent!(%{slug: "intent-agent-exemplars"})
      assign_intent_role!(agent)
      force_fallback_prompt!()
      %{agent: agent}
    end

    defp create_meeting_in_org!(org_id) do
      {:ok, project} =
        Platform.Tasks.create_project(%{
          name: "Intent Classifier #{System.unique_integer([:positive])}",
          org_id: org_id
        })

      {:ok, space} =
        Platform.Chat.create_space(%{
          name: "Intent Classifier Space #{System.unique_integer([:positive])}",
          slug: "intent-classifier-#{System.unique_integer([:positive])}",
          kind: "meeting"
        })

      meeting =
        %Platform.Meetings.Meeting{}
        |> Platform.Meetings.Meeting.changeset(%{
          project_id: project.id,
          chat_space_id: space.id,
          slug: "classify-#{System.unique_integer([:positive])}",
          name: "Classifier Meeting",
          livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
        })
        |> Repo.insert!()

      on_exit(fn -> IntentQueue.stop(meeting.id) end)

      meeting
    end

    defp record_correction!(meeting_id, attrs) do
      {:ok, correction} =
        Platform.Meetings.IntentCorrections.create_correction(
          Map.merge(
            %{
              meeting_id: meeting_id,
              correction: :corrected,
              reason: :wrong_intent
            },
            attrs
          )
        )

      correction
    end

    # Render one chunk into `meeting`'s queue and hand back the system
    # prompt the classifier built for it.
    defp capture_prompt_for!(meeting, room_id) do
      {pid, _name} = start_classifier!()
      plant_stub_fun(pid, capture_prompt_stub(self()))

      # `capture_log/1` returns the LOG, not the block's value — the
      # fallback-prompt branch this suite forces logs a warning, so the
      # noise has to be captured while the prompt itself comes back.
      {prompt, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          _ =
            broadcast_chunk(room_id,
              meeting_id: meeting.id,
              segment: %{
                id: "seg-exemplar-#{System.unique_integer([:positive])}",
                text: "make the sidebar narrower",
                speaker_name: "alice",
                timestamp_ms: 1_000
              }
            )

          assert_receive {:captured_prompt, messages}, 1_000

          messages
          |> Enum.find(fn %{role: role} -> role == "system" end)
          |> Map.fetch!(:content)
        end)

      prompt
    end

    test "the org's prior corrections are rendered into the prompt" do
      meeting = create_meeting_in_org!(fabrikam_org_id())

      record_correction!(meeting.id, %{
        transcript_chunk_excerpt: "bump the header type up a notch",
        classified_intent: "off_topic",
        corrected_intent: "visual_adjust"
      })

      prompt = capture_prompt_for!(meeting, "room-exemplars")

      assert prompt =~ ~s(- utterance: "bump the header type up a notch")
      assert prompt =~ "classified as: off_topic"
      assert prompt =~ "producer verdict: corrected (wrong_intent)"
      assert prompt =~ "should have been: visual_adjust"

      refute prompt =~ "(no prior corrections)",
             "the sentinel must be replaced once the corpus is non-empty"
    end

    test "an empty corpus renders the stable sentinel, not an empty block" do
      meeting = create_meeting_in_org!(tenant_org_id("paragon"))

      prompt = capture_prompt_for!(meeting, "room-exemplars-empty")

      # The prompt's SHAPE must not vary with the corpus. A block that
      # silently disappears when there is nothing to show is a prompt
      # nobody can reason about — and it is how a broken exemplar query
      # would look identical to a genuinely empty corpus.
      assert prompt =~ "(no prior corrections)"
    end

    test "another org's corrections never reach this meeting's prompt" do
      other_meeting = create_meeting_in_org!(tenant_org_id("sxi"))

      record_correction!(other_meeting.id, %{
        transcript_chunk_excerpt: "sxi-only utterance nobody else may see",
        classified_intent: "off_topic",
        corrected_intent: "brief_worthy"
      })

      meeting = create_meeting_in_org!(tenant_org_id("soylent"))
      prompt = capture_prompt_for!(meeting, "room-exemplars-cross-org")

      refute prompt =~ "sxi-only utterance nobody else may see",
             "exemplars must be scoped to the meeting's own org (AC16)"

      assert prompt =~ "(no prior corrections)"
    end

    test "the exemplar block is bounded by the configured limit" do
      meeting = create_meeting_in_org!(tenant_org_id("wayne_tech"))

      for n <- 1..6 do
        record_correction!(meeting.id, %{
          transcript_chunk_excerpt: "bounded utterance #{n}",
          classified_intent: "off_topic",
          corrected_intent: "visual_adjust"
        })
      end

      {pid, _name} = start_classifier!(correction_exemplar_limit: 2)
      plant_stub_fun(pid, capture_prompt_stub(self()))

      capture_log(fn ->
        _ =
          broadcast_chunk("room-exemplars-bounded",
            meeting_id: meeting.id,
            segment: %{id: "seg-bounded", text: "make it narrower", speaker_name: "alice"}
          )

        assert_receive {:captured_prompt, messages}, 1_000

        prompt =
          messages
          |> Enum.find(fn %{role: role} -> role == "system" end)
          |> Map.fetch!(:content)

        # Newest two only, rendered oldest-first so the freshest sits
        # closest to the utterance being classified.
        assert prompt =~ "bounded utterance 6"
        assert prompt =~ "bounded utterance 5"
        refute prompt =~ "bounded utterance 4"
        refute prompt =~ "bounded utterance 1"

        idx_5 = :binary.match(prompt, "bounded utterance 5") |> elem(0)
        idx_6 = :binary.match(prompt, "bounded utterance 6") |> elem(0)

        assert idx_5 < idx_6,
               "exemplars must render oldest-first so the newest correction is closest to the utterance"
      end)
    end

    test "an unresolvable meeting degrades to the sentinel and still classifies" do
      # The default `broadcast_chunk/2` meeting id is `"meeting-" <> room`
      # — not a uuid, so the org lookup raises inside Ecto's cast. A
      # dropped classification here would mean an unreadable tuning
      # corpus could stop the classifier working at all.
      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!()
      plant_stub_fun(pid, capture_prompt_stub(self()))

      capture_log(fn ->
        _ =
          broadcast_chunk("room-exemplars-unresolvable",
            segment: %{
              id: "seg-unresolvable",
              text: "we should still classify this billing request",
              speaker_name: "alice"
            }
          )

        assert_receive {:captured_prompt, messages}, 1_000

        prompt =
          messages
          |> Enum.find(fn %{role: role} -> role == "system" end)
          |> Map.fetch!(:content)

        assert prompt =~ "(no prior corrections)"

        # And the chunk still made it all the way to the terminal event.
        assert_receive {:classified, _measurements, _metadata}, 1_000
      end)
    end
  end

  # ── Per-meeting mute (task 019fbaac stage 2) ───────────────────────────────
  #
  # Every case here assigns the responsibility first. Without an
  # assignee the chunk stops at guard 1 and a mute test would go green
  # against a classifier that had never heard of mute — the reason
  # metadata (`:muted` vs `:no_assignee`) is what tells the two apart,
  # and test 2 asserts on exactly that.
  describe "handle_info/2 — per-meeting mute" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-mute-#{System.unique_integer([:positive])}"})
      assign_intent_role!(agent)
      %{agent: agent}
    end

    test "holds classification while muted and resumes on unmute" do
      # THE load-bearing case, and both halves live in one body on
      # purpose. A lone `refute_receive` cannot tell "correctly held"
      # from "the classifier is broken for an unrelated reason"; the
      # assert BEFORE it proves the pipeline works for this fixture and
      # the assert AFTER it proves the harness was still live when the
      # refute ran.
      meeting = create_meeting!()
      room = "room-mute-holds-#{System.unique_integer([:positive])}"
      on_exit(fn -> IntentQueue.stop(meeting.id) end)

      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!()
      test_pid = self()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        send(test_pid, {:model_called, messages})

        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "schedule_follow_up",
               "target_role" => "scribe",
               "confidence" => 0.9,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      # Every fixture below is a REAL, substantive utterance rather than
      # a placeholder like "first utterance before the mute". The content
      # gate (guard 3) refuses short verbless strings, so a placeholder
      # would make this test go green or red for gate reasons instead of
      # mute reasons. Each is over the gate's short-utterance threshold
      # and carries an action verb, so it is unconditionally kept — the
      # ONLY thing that can stop it here is the mute.

      # 1. UNMUTED — the model is called and a row lands.
      _ = broadcast_mute_chunk(room, meeting.id, "Can you send me the deck before Thursday?")
      assert_receive {:model_called, _}, 1_000
      assert_receive {:classified, _measurements, _metadata}, 1_000
      assert length(IntentQueue.list(meeting.id)) == 1

      # 2. MUTED — no model call, no new row. The utterance is
      # deliberately SUBSTANTIVE: it would sail through the content gate,
      # so its absence here can only be the mute.
      {:ok, _} = Meetings.set_intent_muted(meeting, true)

      _ =
        broadcast_mute_chunk(
          room,
          meeting.id,
          "Let's schedule the follow-up review for next Tuesday."
        )

      refute_receive {:model_called, _}, 500
      assert length(IntentQueue.list(meeting.id)) == 1

      # 3. UNMUTED AGAIN — the model is called again. This is what makes
      # step 2's absence mean something.
      {:ok, _} = Meetings.set_intent_muted(meeting, false)

      _ =
        broadcast_mute_chunk(room, meeting.id, "Please update the roadmap doc with these dates.")

      assert_receive {:model_called, _}, 1_000
      assert_receive {:classified, _measurements, _metadata}, 1_000
      assert length(IntentQueue.list(meeting.id)) == 2
    end

    test "emits skipped telemetry with reason :muted, not :no_assignee" do
      # Separate test rather than an extra assertion on the one above:
      # the first failing assertion ends a test, so a telemetry
      # assertion appended after the refute would be unreachable the
      # moment the mute itself regressed.
      meeting = create_meeting!()
      room = "room-mute-telemetry-#{System.unique_integer([:positive])}"
      meeting_id = meeting.id
      {:ok, _} = Meetings.set_intent_muted(meeting, true)

      _ = attach_recorder!(:skipped, :skipped)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _creds, _messages, _opts ->
        {:ok, %{content: ~s({"intent":"x","target_role":"scribe","confidence":0.5})}}
      end)

      capture_log(fn ->
        _ =
          broadcast_mute_chunk(
            room,
            meeting.id,
            "We should book the client workshop for next month."
          )

        assert_receive {:skipped, %{count: 1},
                        %{reason: :muted, room_id: ^room, meeting_id: ^meeting_id}},
                       1_000
      end)
    end

    test "mute is not shadowed by the content gate — a substantive utterance still reports :muted" do
      # Guard ORDER, asserted directly. Guards 2 (`:muted`) and 3
      # (`:no_content`) both end in a `:skipped` event, so a chain that
      # ran them in the wrong order would still skip the chunk and every
      # other mute test here would stay green. What changes is the REASON,
      # and an operator reading telemetry needs "a human muted this" to
      # survive rather than be relabelled "the transcript said nothing".
      #
      # The utterance is one the content gate unconditionally KEEPS
      # (well over the short-utterance threshold, carries an action
      # verb), so `:no_content` is not even an available answer for it —
      # which is what makes the positive `:muted` assertion below mean
      # the mute guard ran FIRST rather than merely that something
      # skipped.
      meeting = create_meeting!()
      room = "room-mute-not-shadowed-#{System.unique_integer([:positive])}"
      meeting_id = meeting.id
      on_exit(fn -> IntentQueue.stop(meeting.id) end)

      substantive = "Can you create a ticket to migrate the billing service next sprint?"

      # Sanity: the gate itself would let this through. Without this the
      # test could pass against a gate that had started refusing
      # everything.
      assert IntentClassifier.content_bearing?(substantive)

      _ = attach_recorder!(:skipped, :skipped)
      {pid, _name} = start_classifier!()
      test_pid = self()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        send(test_pid, {:model_called, messages})
        {:ok, %{content: ~s({"intent":"x","target_role":"scribe","confidence":0.5})}}
      end)

      {:ok, _} = Meetings.set_intent_muted(meeting, true)

      capture_log(fn ->
        _ = broadcast_mute_chunk(room, meeting.id, substantive)

        assert_receive {:skipped, %{count: 1},
                        %{reason: :muted, room_id: ^room, meeting_id: ^meeting_id}},
                       1_000
      end)

      # No model call, and nothing queued: mute short-circuits ABOVE the
      # classify path, not merely alongside it.
      refute_receive {:model_called, _}, 500
      assert IntentQueue.list(meeting.id) == []
    end

    test "mute is per meeting — an unmuted sibling keeps classifying" do
      # The assertion that catches a gate keyed on the wrong id: a
      # global flag would silence both queues and still pass a
      # single-meeting test.
      muted = create_meeting!()
      live = create_meeting!()
      live_id = live.id
      on_exit(fn -> IntentQueue.stop(muted.id) end)
      on_exit(fn -> IntentQueue.stop(live.id) end)

      {:ok, _} = Meetings.set_intent_muted(muted, true)

      _ = attach_terminal_recorder!(:classified)
      {pid, _name} = start_classifier!()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "schedule_follow_up",
               "target_role" => "scribe",
               "confidence" => 0.8,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      # Both utterances are substantive and would pass the content gate,
      # so the only thing separating the two rooms is the mute flag.
      _ =
        broadcast_mute_chunk(
          "room-mute-sibling-muted",
          muted.id,
          "Can you check the billing export for last week?"
        )

      _ =
        broadcast_mute_chunk(
          "room-mute-sibling-live",
          live.id,
          "Please create a ticket for the login timeout bug."
        )

      # Wait on the LIVE meeting's terminal event by id, not on whatever
      # arrives first. Matching the bare shape would be satisfied by the
      # muted meeting's own event if the gate ever stopped working, and
      # the red would then land on the presence half for a race reason
      # instead of on the absence half for the real one.
      #
      # Once the live event has landed, the muted meeting's chunk —
      # broadcast FIRST, handled by the same serial GenServer — has
      # already been through the guard chain.
      assert_receive {:classified, _measurements, %{meeting_id: ^live_id}}, 1_000

      assert length(IntentQueue.list(live.id)) == 1
      assert IntentQueue.list(muted.id) == []
    end

    test "a chunk with a nil meeting_id still walks the classify path" do
      # `intent_muted?/1` answers false for nil, so the mute guard must
      # be transparent here. Asserted positively (the model IS called),
      # not as a refute — a refute would pass on a classifier that had
      # crashed.
      room = "room-mute-nil-meeting-#{System.unique_integer([:positive])}"
      {pid, _name} = start_classifier!()
      test_pid = self()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        send(test_pid, {:model_called, messages})
        {:ok, %{content: ~s({"intent":"x","target_role":"scribe","confidence":0.5})}}
      end)

      capture_log(fn ->
        _ =
          broadcast_chunk(room,
            meeting_id: nil,
            segment: %{
              id: "seg-nil-meeting",
              # Substantive on purpose: with a nil meeting_id the mute
              # guard is transparent, so this must reach the model — a
              # placeholder string would stop at the content gate instead
              # and the test would fail for the wrong reason.
              text: "Let's follow up on the pricing question tomorrow.",
              speaker_name: "alice"
            }
          )

        assert_receive {:model_called, _}, 1_000
      end)

      assert Process.alive?(pid)
    end
  end

  # ── Mute helpers ───────────────────────────────────────────────────────────

  # A REAL meetings row — the mute lives in a column, so the fabricated
  # `"meeting-" <> room` ids the rest of this file uses would answer
  # `intent_muted?/1` with a permanent `false`.
  defp create_meeting! do
    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Intent Mute #{System.unique_integer([:positive])}"
      })

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Intent Mute Space #{System.unique_integer([:positive])}",
        slug: "intent-mute-#{System.unique_integer([:positive])}",
        kind: "meeting"
      })

    %Platform.Meetings.Meeting{}
    |> Platform.Meetings.Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space.id,
      slug: "intent-mute-#{System.unique_integer([:positive])}",
      name: "Intent Mute Meeting",
      livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
    })
    |> Repo.insert!()
  end

  # Distinct chunk text per call so the dedupe key differs — otherwise a
  # post-unmute chunk would collapse against the pre-mute one and the
  # resumed classification would be invisible in the queue.
  defp broadcast_mute_chunk(room_id, meeting_id, text) do
    broadcast_chunk(room_id,
      meeting_id: meeting_id,
      segment: %{
        id: "seg-#{System.unique_integer([:positive])}",
        text: text,
        speaker_name: "alice"
      }
    )
  end

  # ── decide/1 ───────────────────────────────────────────────────────────────
  #
  # `decide/1` is the SINGLE classification code path — `classify_and_enqueue/4`
  # calls it too. These tests exercise it directly (no GenServer), which is
  # legal because `StubProvider` reads the stub fun out of the CALLING
  # process's dictionary; called inline, that is the test process.

  describe "decide/1" do
    setup do
      Process.delete(:intent_classifier_stub_fun)
      on_exit(fn -> Process.delete(:intent_classifier_stub_fun) end)
      :ok
    end

    defp decide_args(overrides \\ %{}) do
      Map.merge(
        %{
          provider_module: StubProvider,
          agent: %{model: "stub-model"},
          prompt: "system prompt",
          chunk_text: "can someone pull the Q3 numbers",
          room_id: "room-decide"
        },
        overrides
      )
    end

    defp stub!(fun), do: Process.put(:intent_classifier_stub_fun, fun)

    test "returns the parsed decision on a well-formed positive answer" do
      stub!(fn _c, _m, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "pull_numbers",
               "target_role" => "scribe",
               "confidence" => 0.82,
               "evidence_quote" => "pull the Q3 numbers"
             })
         }}
      end)

      assert {:ok, decision} = IntentClassifier.decide(decide_args())
      assert decision.intent == "pull_numbers"
      assert decision.target_role == "scribe"
      assert decision.confidence == 0.82
    end

    test "returns the decision for an off-topic / no-action answer" do
      stub!(fn _c, _m, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "off_topic",
               "target_role" => "none",
               "confidence" => 0.05
             })
         }}
      end)

      assert {:ok, decision} =
               IntentClassifier.decide(decide_args(%{chunk_text: "anyway, nice weather"}))

      assert decision.intent == "off_topic"
      assert decision.target_role == "none"
    end

    test "empty content returns {:error, :empty_output}, not a parse error" do
      stub!(fn _c, _m, _o -> {:ok, %{content: "   \n  "}} end)

      capture_log([level: :warning], fn ->
        assert IntentClassifier.decide(decide_args()) == {:error, :empty_output}
      end)
    end

    test "undecodable content returns {:error, :parse_error}" do
      stub!(fn _c, _m, _o -> {:ok, %{content: "definitely not json {{{"}} end)

      capture_log([level: :warning], fn ->
        assert IntentClassifier.decide(decide_args()) == {:error, :parse_error}
      end)
    end

    test "a failing provider call returns {:error, :model_error}" do
      stub!(fn _c, _m, _o -> {:error, {:http_error, 500, %{"error" => "boom"}}} end)

      capture_log([level: :warning], fn ->
        assert IntentClassifier.decide(decide_args()) == {:error, :model_error}
      end)
    end

    # The evidence gate (task 01a03f57) is wired into `decide/1` itself,
    # not bolted onto a parallel route: these two tests exercise it
    # THROUGH `decide/1` so a future refactor that leaves the gate on a
    # path production no longer takes shows up here as a failure.
    #
    # An uncited positive is not an error shape — it is a DEMOTION, so it
    # comes back as a well-formed `{:ok, off_topic}` decision.
    test "an uncited positive is demoted to off_topic rather than returned as an error" do
      stub!(fn _c, _m, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "pull_numbers",
               "target_role" => "scribe",
               "confidence" => 0.9,
               "evidence_quote" => ""
             })
         }}
      end)

      assert {:ok, decision} = IntentClassifier.decide(decide_args())
      assert decision.intent == "off_topic"
      assert decision.target_role == "null"
    end

    # The JSON `null` the prompt's own closed enum instructs the model to
    # emit for `off_topic` must survive `decide/1` as a decision, not fall
    # through to `:parse_error`.
    test "a JSON null target_role decides off_topic instead of erroring" do
      stub!(fn _c, _m, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "off_topic",
               "target_role" => nil,
               "confidence" => 0.04
             })
         }}
      end)

      assert {:ok, decision} =
               IntentClassifier.decide(decide_args(%{chunk_text: "anyway, nice weather"}))

      assert decision.intent == "off_topic"
      assert decision.target_role == "null"
    end

    # A `target_role` of some OTHER shape (or absent entirely) is still a
    # structurally-invalid payload — and it must surface as the tagged
    # `{:error, :parse_error}` `decide/1` promises, not the bare `:error`
    # the pre-extraction parser returned, which a `with` would leak
    # straight through to the caller's `case`.
    test "a non-binary, non-null target_role still returns {:error, :parse_error}" do
      stub!(fn _c, _m, _o ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "off_topic",
               "target_role" => 42,
               "confidence" => 0.1
             })
         }}
      end)

      capture_log([level: :warning], fn ->
        assert IntentClassifier.decide(decide_args()) == {:error, :parse_error}
      end)
    end
  end

  # Task 01a03f57 stage 2: stage 1 told the model to CITE the span it
  # classified on. A prompt instruction the runtime does not check is a
  # suggestion — these tests pin the server-side enforcement. An
  # uncited or fabricated-cite positive DEMOTES to off_topic (it still
  # lands in the queue, where routing sends it nowhere and the
  # corrections corpus keeps a row); it is never dropped.
  describe "classify_and_enqueue — evidence_quote enforcement" do
    setup do
      agent = create_agent!(%{slug: "intent-agent-evidence"})
      assign_intent_role!(agent)
      :ok
    end

    defp evidence_chunk(room_id, meeting_id) do
      broadcast_chunk(room_id,
        meeting_id: meeting_id,
        segment: %{
          id: "seg-evidence-#{System.unique_integer([:positive])}",
          text: "the nav bar contrast is too low on mobile",
          speaker_name: "alice"
        }
      )
    end

    defp evidence_stub(pid, body) do
      plant_stub_fun(pid, fn _c, _m, _o -> {:ok, %{content: Jason.encode!(body)}} end)
    end

    test "a verbatim quote from the chunk enqueues the intent unchanged" do
      _ = attach_recorder!(:evidence_missing, :evidence_missing)
      _ = attach_terminal_recorder!(:classified)
      meeting_id = unique_meeting_id()
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      {pid, _name} = start_classifier!()

      evidence_stub(pid, %{
        "intent" => "visual_adjust",
        "target_role" => "designer",
        "confidence" => 0.91,
        "evidence_quote" => "contrast is too low"
      })

      _ = evidence_chunk("room-evidence-ok", meeting_id)

      assert_receive {:classified, %{count: 1}, %{intent: "visual_adjust"}}, 1_000
      refute_receive {:evidence_missing, _, _}, 200

      assert [entry] = IntentQueue.list(meeting_id)
      assert entry.classified_intent == "visual_adjust"
      assert entry.target_role == "designer"
    end

    test "a missing quote demotes to off_topic and emits :evidence_missing with :blank" do
      _ = attach_recorder!(:evidence_missing, :evidence_missing)
      _ = attach_terminal_recorder!(:classified)
      meeting_id = unique_meeting_id()
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      {pid, _name} = start_classifier!()

      evidence_stub(pid, %{
        "intent" => "visual_adjust",
        "target_role" => "designer",
        "confidence" => 0.91
      })

      _ = evidence_chunk("room-evidence-blank", meeting_id)

      assert_receive {:evidence_missing, %{count: 1},
                      %{intent: "visual_adjust", reason: :blank, room_id: "room-evidence-blank"}},
                     1_000

      assert_receive {:classified, %{count: 1}, %{intent: "off_topic", target_role: "null"}},
                     1_000

      assert [entry] = IntentQueue.list(meeting_id)
      assert entry.classified_intent == "off_topic"
      assert entry.target_role == "null"
    end

    test "a fabricated quote demotes to off_topic with :not_in_chunk" do
      _ = attach_recorder!(:evidence_missing, :evidence_missing)
      _ = attach_terminal_recorder!(:classified)
      meeting_id = unique_meeting_id()
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      {pid, _name} = start_classifier!()

      evidence_stub(pid, %{
        "intent" => "visual_adjust",
        "target_role" => "designer",
        "confidence" => 0.91,
        "evidence_quote" => "ship the redesign by friday"
      })

      _ = evidence_chunk("room-evidence-fab", meeting_id)

      assert_receive {:evidence_missing, %{count: 1},
                      %{intent: "visual_adjust", reason: :not_in_chunk}},
                     1_000

      assert_receive {:classified, %{count: 1}, %{intent: "off_topic"}}, 1_000
      assert [entry] = IntentQueue.list(meeting_id)
      assert entry.classified_intent == "off_topic"
    end

    # Anti-vacuity guard: without this, a rule that demoted EVERYTHING
    # would still pass the two demotion tests above.
    test "an off_topic answer with an empty quote is untouched and emits no :evidence_missing" do
      _ = attach_recorder!(:evidence_missing, :evidence_missing)
      _ = attach_terminal_recorder!(:classified)
      meeting_id = unique_meeting_id()
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      {pid, _name} = start_classifier!()

      evidence_stub(pid, %{
        "intent" => "off_topic",
        "target_role" => "null",
        "confidence" => 0.42,
        "evidence_quote" => ""
      })

      _ = evidence_chunk("room-evidence-off", meeting_id)

      assert_receive {:classified, %{count: 1}, %{intent: "off_topic", confidence: 0.42}}, 1_000
      refute_receive {:evidence_missing, _, _}, 200

      assert [entry] = IntentQueue.list(meeting_id)
      assert entry.classified_intent == "off_topic"
      assert entry.confidence == 0.42
    end
  end
end
