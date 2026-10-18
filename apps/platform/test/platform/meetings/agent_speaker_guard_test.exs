defmodule Platform.Meetings.AgentSpeakerGuardTest do
  @moduledoc """
  Task 01a03fba — agent speech must not re-enter the intent pipeline.

  Audio an agent speaks into a meeting is audio the VAD chunks and the
  STT transcribes. Before this guard existed the resulting final segment
  reached `IntentClassifier` indistinguishable from a human's: measured
  on `7f1390df`, a segment with `participant_identity: "agent:probe-scribe"`
  and the text *"I'm adding this to a task and will follow up with
  everyone tomorrow"* produced **one queued intent**, exactly as the same
  text from a human did. Speaker identity was already carried end to end
  (`normalize_segment/1` in both producers, `segment_speaker/2` in the
  classifier); nothing ACTED on it. This file pins that it now does.

  ## Every negative here is paired

  A guard that drops everything passes "an agent produces no intent".
  So each test that refutes an intent for an agent runs the SAME text,
  through the SAME transcript-append path, from a human, and asserts one
  intent DOES land. A lone refutation would also pass against a broken
  classifier, an unseeded assignee, or a stub that never answered.

  ## What is deliberately NOT excluded

  Agent speech still lands in the transcript and still enters the
  classifier's prior-context window. This is about excluding agent
  speech from CLASSIFICATION, not from history — different pipelines,
  and the ticket is explicit that conflating them would be the wrong
  fix. Both are asserted below so the decision is recorded rather than
  assumed.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Meetings
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentQueue
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles

  @responsibility_key "meetings.intent_classify"
  @prompt_slug "meetings.intent_classify.v1"

  # The utterance the ticket names: an agent's own acknowledgement, which
  # is exactly the shape the classifier bites on. Used verbatim for the
  # agent case AND the human control so the only difference between them
  # is the identity on the segment.
  @acknowledgement "I'm adding this to a task and will follow up with everyone tomorrow"

  defmodule StubProvider do
    @moduledoc false

    def chat(credentials, messages, opts) do
      case Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end
  end

  # ── agent_identity?/1 ─────────────────────────────────────────────────────

  describe "Meetings.agent_identity?/1" do
    test "true for the SLUG form generate_agent_token/3 actually mints" do
      # `generate_agent_token/3` builds `"agent:" <> agent.slug`. This is
      # the identity on the token an agent joins LiveKit with, so it is
      # the identity that would appear on a segment of its speech.
      assert Meetings.agent_identity?("agent:probe-scribe")
      assert Meetings.agent_identity?("agent:meeting-scribe-2")
    end

    test "true for the UUID form the participant tiles use" do
      assert Meetings.agent_identity?("agent:#{Ecto.UUID.generate()}")
    end

    test "the slug form does NOT parse — a parse_identity/1 guard would miss it" do
      # The landmine, pinned. `parse_identity/1` casts the suffix as a
      # UUID and answers `:unknown` for a slug, so a guard written on it
      # would pass agent speech through for exactly the identity the
      # audio-publish path mints — silently, with no raise and no log.
      #
      # Both halves in one test on purpose: the disagreement between the
      # two functions IS the fact being recorded, and asserting either
      # alone records nothing.
      slug_identity = "agent:probe-scribe"

      assert :unknown == Meetings.parse_identity(slug_identity)
      assert Meetings.agent_identity?(slug_identity)

      # Same pair for the form that DOES parse, so the test above cannot
      # be passing merely because `parse_identity/1` is broken outright.
      uuid = Ecto.UUID.generate()
      assert {:agent, ^uuid} = Meetings.parse_identity("agent:#{uuid}")
      assert Meetings.agent_identity?("agent:#{uuid}")
    end

    test "false for humans, guests, workers and malformed input" do
      refute Meetings.agent_identity?("user:#{Ecto.UUID.generate()}")
      refute Meetings.agent_identity?("guest:#{Ecto.UUID.generate()}")
      refute Meetings.agent_identity?("transcriber:worker-1")
      refute Meetings.agent_identity?("meeting-transcriber")
      refute Meetings.agent_identity?("Blake Moreno")
      refute Meetings.agent_identity?("")
      refute Meetings.agent_identity?(nil)
      refute Meetings.agent_identity?(:agent)

      # A bare prefix with no suffix names nobody. Answering `true` here
      # would let an empty-string identity suppress classification for a
      # participant the system cannot even identify.
      refute Meetings.agent_identity?("agent:")

      # Presence half: the same call shape DOES answer true, so the
      # refutations above are about their inputs and not about a
      # predicate that returns false for everything.
      assert Meetings.agent_identity?("agent:x")
    end
  end

  # ── End to end: append_segment → classifier → queue ───────────────────────

  describe "an agent-authored segment reaches the transcript but not the queue" do
    setup :classifier

    test "agent speech is skipped; the SAME text from a human is classified", ctx do
      attach_recorders!()
      plant_classifying_stub(ctx.pid)

      agent_meeting = meeting!("Agent Speaker")
      agent_transcript = transcript!(agent_meeting, "room-agent-speaker")

      append!(agent_transcript, "agent:probe-scribe", "Scribe", @acknowledgement)

      assert_receive {:skipped, %{count: 1},
                      %{
                        reason: :agent_speaker,
                        room_id: "room-agent-speaker",
                        speaker_identity: "agent:probe-scribe"
                      }},
                     1000

      refute_receive {:classified, _, %{room_id: "room-agent-speaker"}}, 200
      assert IntentQueue.list(agent_meeting.id) == []

      # POSITIVE CONTROL. Same text, same append path, same stub, same
      # classifier process — only the identity differs.
      human_meeting = meeting!("Human Speaker")
      human_transcript = transcript!(human_meeting, "room-human-speaker")

      append!(
        human_transcript,
        "user:#{Ecto.UUID.generate()}",
        "Blake",
        @acknowledgement
      )

      assert_receive {:classified, %{count: 1}, %{room_id: "room-human-speaker"}}, 1000
      assert [entry] = IntentQueue.list(human_meeting.id)
      assert entry.classified_intent == "schedule_followup"
      assert entry.status == :queued
    end

    test "the agent's words are still IN the transcript — history is not filtered", ctx do
      attach_recorders!()
      plant_classifying_stub(ctx.pid)

      meeting = meeting!("Agent In Transcript")
      transcript = transcript!(meeting, "room-agent-history")

      append!(transcript, "agent:probe-scribe", "Scribe", @acknowledgement)

      assert_receive {:skipped, %{count: 1}, %{reason: :agent_speaker}}, 1000

      stored = Meetings.get_transcript(transcript.id)
      assert [segment] = stored.segments
      assert segment["text"] == @acknowledgement
      assert segment["participant_identity"] == "agent:probe-scribe"
      assert IntentQueue.list(meeting.id) == []
    end

    test "the guard reads participant_identity, NOT the display name", ctx do
      attach_recorders!()
      plant_classifying_stub(ctx.pid)

      # An agent's display name is chosen for humans to read. A guard
      # built on `speaker_name` / `segment_speaker/2` would let this
      # through, because nothing about "Robin" says machine.
      agent_meeting = meeting!("Human Named Agent")
      agent_transcript = transcript!(agent_meeting, "room-human-named-agent")

      append!(agent_transcript, "agent:robin", "Robin", @acknowledgement)

      assert_receive {:skipped, %{count: 1},
                      %{reason: :agent_speaker, room_id: "room-human-named-agent"}},
                     1000

      assert IntentQueue.list(agent_meeting.id) == []

      # And the mirror: a HUMAN whose display name looks like a machine
      # is still classified. Together these pin that the decision tracks
      # the identity field and nothing else — a guard that matched on
      # the display name would fail one of the two whichever way it was
      # written.
      human_meeting = meeting!("Robot Named Human")
      human_transcript = transcript!(human_meeting, "room-robot-named-human")

      append!(
        human_transcript,
        "user:#{Ecto.UUID.generate()}",
        "agent:robin",
        @acknowledgement
      )

      assert_receive {:classified, %{count: 1}, %{room_id: "room-robot-named-human"}}, 1000
      assert length(IntentQueue.list(human_meeting.id)) == 1
    end
  end

  # ── Guard ORDER: agent speaker answers before configuration does ──────────

  describe "the agent-speaker guard preempts the assignee guard" do
    # Deliberately NO assignee seeded — that is the condition under test.
    setup do
      refute Roles.assignee_for(@responsibility_key)
      start_classifier!([])
    end

    test "an unassigned room reports :agent_speaker, not :no_assignee", ctx do
      # Pins the guard's position ahead of the assignee lookup. Moved
      # below it, this room would report `:no_assignee` — naming a
      # condition an operator could "fix" by assigning the
      # responsibility, at which point the agent's speech classifies.
      attach_recorders!()
      plant_classifying_stub(ctx.pid)

      meeting = meeting!("Unassigned")
      transcript = transcript!(meeting, "room-unassigned-agent")

      append!(transcript, "agent:probe-scribe", "Scribe", @acknowledgement)

      assert_receive {:skipped, %{count: 1},
                      %{reason: :agent_speaker, room_id: "room-unassigned-agent"}},
                     1000

      # Control for the SAME unassigned classifier: a human reports
      # `:no_assignee`, which is what proves the reason above is about
      # the speaker and not about the room's configuration.
      human_transcript = transcript!(meeting, "room-unassigned-human")

      append!(
        human_transcript,
        "user:#{Ecto.UUID.generate()}",
        "Blake",
        @acknowledgement
      )

      assert_receive {:skipped, %{count: 1},
                      %{reason: :no_assignee, room_id: "room-unassigned-human"}},
                     1000
    end
  end

  describe "the agent-speaker guard preempts the mute guard" do
    setup :classifier

    test "a muted meeting reports :agent_speaker for an agent, :muted for a human", ctx do
      attach_recorders!()
      plant_classifying_stub(ctx.pid)

      meeting = meeting!("Muted")
      {:ok, _} = Meetings.set_intent_muted(meeting, true)
      assert Meetings.intent_muted?(meeting.id)

      agent_transcript = transcript!(meeting, "room-muted-agent")
      append!(agent_transcript, "agent:probe-scribe", "Scribe", @acknowledgement)

      assert_receive {:skipped, %{count: 1},
                      %{reason: :agent_speaker, room_id: "room-muted-agent"}},
                     1000

      # Control: the same muted meeting reports `:muted` for a human, so
      # the reason above is not simply what this meeting always says.
      human_transcript = transcript!(meeting, "room-muted-human")

      append!(
        human_transcript,
        "user:#{Ecto.UUID.generate()}",
        "Blake",
        @acknowledgement
      )

      assert_receive {:skipped, %{count: 1}, %{reason: :muted, room_id: "room-muted-human"}},
                     1000
    end
  end

  # ── Recorded decision: agent speech stays in the CONTEXT window ───────────

  describe "agent speech remains available as prior context" do
    setup :classifier

    test "a skipped agent chunk still appears in the next human chunk's prompt", ctx do
      attach_recorders!()

      # Capture the prompt the classifier renders for the human chunk.
      test_pid = self()

      plant_stub(ctx.pid, fn _creds, messages, _opts ->
        send(test_pid, {:prompt, messages})

        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "schedule_followup",
               "target_role" => "scheduler",
               "confidence" => 0.9,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      meeting = meeting!("Context Retention")
      transcript = transcript!(meeting, "room-context-retention")

      append!(transcript, "agent:probe-scribe", "Scribe", "I'll take the deploy checklist")
      assert_receive {:skipped, %{count: 1}, %{reason: :agent_speaker}}, 1000

      # The agent chunk was skipped, so no prompt was rendered for it.
      refute_receive {:prompt, _}, 200

      append!(
        transcript,
        "user:#{Ecto.UUID.generate()}",
        "Blake",
        "yes please do that before Friday"
      )

      assert_receive {:prompt, messages}, 1000

      rendered = messages |> Enum.map_join("\n", &message_content/1)

      # The agent's utterance is in the window the human chunk classifies
      # against. This is the accepted cost of not filtering the context
      # buffer: agent speech shapes the classification of the human turn
      # that answers it, which is the point — "yes please do that" is
      # unresolvable without it.
      assert rendered =~ "I'll take the deploy checklist"
      # And the human chunk itself is the one being classified.
      assert rendered =~ "yes please do that before Friday"
    end
  end

  # ── Debounce: identity, not display name, bounds a turn ───────────────────

  describe "the same-speaker merge is keyed on identity" do
    setup do
      classifier(%{}, debounce_ms: 60)
    end

    test "an agent and a human sharing a display name do not merge", ctx do
      attach_recorders!()

      test_pid = self()

      plant_stub(ctx.pid, fn _creds, messages, _opts ->
        send(test_pid, {:prompt, messages})

        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "schedule_followup",
               "target_role" => "scheduler",
               "confidence" => 0.9,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      meeting = meeting!("Name Collision")
      transcript = transcript!(meeting, "room-name-collision")

      # Both carry `speaker_name: "Sam"`. Before the hold key moved to
      # the identity these merged into ONE held turn, and
      # `merged_payload/1` keeps the FIRST fragment's segment — so the
      # agent's words would have reached the classifier stamped with
      # whichever identity spoke first. When the human speaks first that
      # is a human identity, and guard 1 never sees the agent's text at
      # all: the loop this task closes, reopened by the debounce.
      append!(
        transcript,
        "user:#{Ecto.UUID.generate()}",
        "Sam",
        "can you handle the migration"
      )

      append!(transcript, "agent:sam-bot", "Sam", @acknowledgement)

      assert_receive {:skipped, %{count: 1},
                      %{reason: :agent_speaker, speaker_identity: "agent:sam-bot"}},
                     1000

      assert_receive {:prompt, messages}, 1000
      rendered = messages |> Enum.map_join("\n", &message_content/1)

      # The human's own words classified, alone.
      assert rendered =~ "can you handle the migration"

      # The agent's acknowledgement is in the CONTEXT lines (the buffer
      # is not filtered — see the test above), but it must not have been
      # folded into the utterance under classification. The classifier
      # sends the chunk under classification as the `user` message, so
      # that message is where a merge would show.
      user_message =
        Enum.find_value(messages, "", fn message ->
          if message_role(message) == "user", do: message_content(message)
        end)

      assert user_message =~ "can you handle the migration"
      refute user_message =~ "follow up with everyone tomorrow"

      assert [entry] = IntentQueue.list(meeting.id)
      assert entry.status == :queued
    end

    test "consecutive fragments from ONE identity still merge", ctx do
      # Presence half for the test above: the debounce still does the job
      # it exists for. A hold key that never matched would also produce a
      # non-merge, and would pass the previous test for the wrong reason.
      attach_recorders!()

      test_pid = self()

      plant_stub(ctx.pid, fn _creds, messages, _opts ->
        send(test_pid, {:prompt, messages})

        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "schedule_followup",
               "target_role" => "scheduler",
               "confidence" => 0.9,
               "evidence_quote" => echo_quote(messages)
             })
         }}
      end)

      meeting = meeting!("Same Identity Merge")
      transcript = transcript!(meeting, "room-same-identity")
      identity = "user:#{Ecto.UUID.generate()}"

      append!(transcript, identity, "Sam", "we should ship the podcast")
      append!(transcript, identity, "Sam", "software before Friday")

      assert_receive {:prompt, messages}, 1000

      user_message =
        Enum.find_value(messages, "", fn message ->
          if message_role(message) == "user", do: message_content(message)
        end)

      assert user_message =~ "we should ship the podcast"
      assert user_message =~ "software before Friday"

      refute_receive {:prompt, _}, 200
    end
  end

  # ── Fixtures / helpers ────────────────────────────────────────────────────

  defp classifier(ctx, opts \\ []) do
    _ = ctx
    seed_assignee!()
    start_classifier!(opts)
  end

  # Boots a per-test classifier so the sandbox owns the process. The
  # suite-wide one is gated off in `config/test.exs`, so this is the only
  # subscriber to `meeting:transcript_chunk`.
  defp start_classifier!(opts) do
    name = :"agent_speaker_guard_#{System.unique_integer([:positive])}"

    start_opts = Keyword.merge([name: name, provider_module: StubProvider], opts)
    {:ok, pid} = start_supervised({IntentClassifier, start_opts})

    # No seeded template row — the classifier walks its inline fallback,
    # same as the runtime integration test.
    case PromptTemplates.get_template_by_slug(@prompt_slug) do
      nil -> :ok
      template -> PromptTemplates.delete_template(template)
    end

    {:ok, pid: pid}
  end

  defp seed_assignee! do
    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "agent-speaker-guard-#{System.unique_integer([:positive])}",
        name: "Guard Test Agent",
        status: "active"
      })
      |> Repo.insert!()

    {:ok, _} = Roles.set_override(@responsibility_key, agent.id)
    agent
  end

  defp meeting!(name) do
    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "#{name} #{System.unique_integer([:positive])}"
      })

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    on_exit(fn -> IntentQueue.stop(meeting.id) end)
    meeting
  end

  defp transcript!(meeting, room_id) do
    {:ok, transcript} =
      Meetings.ensure_transcript(%{room_id: room_id, space_id: meeting.chat_space_id})

    transcript
  end

  # Goes through `append_segment/2` — the real producer entry point —
  # rather than broadcasting a hand-built payload, so the space→meeting
  # resolution and the segment's own key shape are under test too. Both
  # HTTP producers stamp string keys, which is what this mirrors.
  defp append!(transcript, identity, speaker_name, text) do
    {:ok, _} =
      Meetings.append_segment(transcript.id, %{
        "participant_identity" => identity,
        "speaker_name" => speaker_name,
        "text" => text,
        "start_time" => 0,
        "end_time" => 1000
      })

    :ok
  end

  defp plant_stub(pid, fun) do
    ref = make_ref()
    send(pid, {:__test_plant_stub, self(), ref, fun})

    receive do
      {^ref, :ok} -> :ok
    after
      500 -> flunk("classifier did not ack stub fun plant")
    end
  end

  defp plant_classifying_stub(pid) do
    plant_stub(pid, fn _creds, messages, _opts ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "intent" => "schedule_followup",
             "target_role" => "scheduler",
             "confidence" => 0.9,
             "evidence_quote" => echo_quote(messages)
           })
       }}
    end)
  end

  defp attach_recorders! do
    tag = System.unique_integer([:positive])
    test_pid = self()

    skipped_id = "agent-speaker-skipped-#{tag}"
    classified_id = "agent-speaker-classified-#{tag}"

    :telemetry.attach(
      skipped_id,
      [:platform, :meetings, :intent_classifier, :skipped],
      fn _event, measurements, metadata, _cfg ->
        send(test_pid, {:skipped, measurements, metadata})
      end,
      nil
    )

    :telemetry.attach(
      classified_id,
      [:platform, :meetings, :intent_classified],
      fn _event, measurements, metadata, _cfg ->
        send(test_pid, {:classified, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(skipped_id)
      :telemetry.detach(classified_id)
    end)

    :ok
  end

  defp message_role(message), do: Map.get(message, :role) || Map.get(message, "role")

  defp message_content(message),
    do: to_string(Map.get(message, :content) || Map.get(message, "content") || "")

  # The classifier demotes a non-off_topic classification to off_topic
  # unless `evidence_quote` is a verbatim span of the chunk, so the stub
  # cites the chunk back at it.
  defp echo_quote(messages) do
    Enum.find_value(messages, "", fn message ->
      if message_role(message) == "user", do: message_content(message)
    end)
  end
end
