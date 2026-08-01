defmodule Platform.Responsibilities.Handlers.MeetingActionItemsTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.MeetingActionItems`.

  ## What this file stopped testing, and why

  Until the reconciler was deleted, most of this file drove
  `handle_output/3` with a JSON `operations` payload and asserted on the
  checklist that came out the other side. None of it ran in production:
  `handle_output/3` is reachable only from
  `Router.run_external_dispatch/5`, and this key's assignee resolves
  NATIVE, so the reconciler never executed once. The recipient holds
  `canvas_describe` / `canvas_create` / `canvas_patch` and does the work
  itself.

  So the surface under test is the same as every sibling intent
  handler's: registration, the four gathered slots, the prompt built
  over them — plus the one thing this key owns that the siblings do not,
  `handle_refusal/3`, which closes the `IntentQueue` row a refusal would
  otherwise leave holding the meeting's serial cursor for 90 seconds.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.IntentQueue
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Handlers.MeetingActionItems
  alias Platform.Responsibilities.Responsibility

  defp unique_id, do: Platform.Types.UUIDv7.generate()

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: MeetingActionItems.key(),
      feature: "meetings",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => "meeting:action_item_intent"},
      scope: "per_meeting",
      context_provided: [
        "org_identity",
        "meeting_intent",
        "transcript_window",
        "meeting_canvases"
      ],
      enabled: true
    }
  end

  defp create_space! do
    {:ok, space} = Chat.create_space(%{kind: "execution"})
    _ = ExecutionSpace.ensure_system_participant(space.id)
    space
  end

  defp create_transcript!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          room_id: unique_id(),
          space_id: unique_id(),
          segments: [
            %{
              "speaker_name" => "Harper",
              "text" => "Hello",
              "start_time" => 0,
              "end_time" => 1000,
              "final" => true
            }
          ]
        },
        overrides
      )

    {:ok, transcript} = Meetings.create_transcript(attrs)
    transcript
  end

  defp segment(speaker, text) do
    %{
      "speaker_name" => speaker,
      "text" => text,
      "start_time" => 0,
      "end_time" => 5_000,
      "final" => true
    }
  end

  # A fixed intent id so a test can assert the slot carried THIS row's
  # id rather than merely a non-nil one.
  @intent_id "019fb90f-36e3-7000-8000-000000000001"

  defp intent_id, do: @intent_id

  defp create_project! do
    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Meetings #{System.unique_integer([:positive])}"
      })

    project
  end

  # `Meetings.create_meeting/1` MINTS the backing chat space itself and
  # ignores any `chat_space_id` in the attrs, so a fixture that creates a
  # space and hands it in gets a meeting bound to a DIFFERENT space — and
  # every canvas assertion silently looks in the wrong place. The
  # meeting's own `chat_space_id` is the space.
  defp create_meeting! do
    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: create_project!().id,
        name: "Standup #{System.unique_integer([:positive])}"
      })

    {:ok, _} = ExecutionSpace.ensure_system_participant(meeting.chat_space_id)
    meeting
  end

  # The shape `IntentDispatcher.action_item_payload/2` broadcasts.
  defp intent_trigger_meta(meeting, transcript, overrides) do
    payload =
      %{
        intent_id: @intent_id,
        meeting_id: meeting.id,
        room_id: transcript && transcript.room_id,
        space_id: transcript && transcript.space_id,
        transcript_id: transcript && transcript.id,
        chunk_excerpt: "",
        classified_intent: "action_items",
        confidence: 0.9,
        speaker: nil
      }
      |> Map.merge(overrides)

    %{kind: :event_topic, topic: "meeting:action_item_intent", payload: payload}
  end

  # A plain canvas in the meeting's space. There is no longer a blessed
  # action-items canvas SHAPE the platform recognises — the slot is an
  # inventory of whatever the space holds, and the recipient decides
  # which of them is the running list.
  defp create_canvas!(space_id, title) do
    {:ok, participant} = ExecutionSpace.ensure_system_participant(space_id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space_id,
        "created_by" => participant.id,
        "title" => title,
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{"id" => "root", "type" => "checklist", "children" => []}
        }
      })

    canvas
  end

  defp messages(space_id), do: Chat.list_messages(space_id) || []

  defp action_item_messages(space_id) do
    space_id
    |> messages()
    |> Enum.filter(&(&1.metadata["source"] == "meeting_action_items"))
  end

  describe "register/0" do
    test "returns exactly one spec with the canonical key + feature" do
      specs = MeetingActionItems.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "meetings.action_items"
      assert spec.feature == "meetings"
      assert spec.trigger_kind == "event_topic"
      assert spec.scope == "per_meeting"

      assert spec.context_provided == [
               "org_identity",
               "meeting_intent",
               "transcript_window",
               "meeting_canvases"
             ]

      # The two retired slots, named explicitly. `meeting_transcript`
      # was the whole transcript on every utterance;
      # `action_items_canvas` was the server-side reconciler's read of
      # one blessed canvas. Leaving either on the list would be a live
      # claim that the handler still gathers it.
      refute "meeting_transcript" in spec.context_provided
      refute "action_items_canvas" in spec.context_provided

      assert spec.default_prompt_template == "meetings.action_items.v1"
      assert spec.cost_profile == "low_freq_capable"
    end

    test "the trigger is READ from IntentRouting, not restated here" do
      # Three copies of one fact is how a responsibility is silently
      # unfired: the Router subscribes at boot to the topic the ROW
      # declares, so a handler that names a different topic than the
      # dispatcher broadcasts on produces no error, no log and no
      # dispatch — just a row that times out 90 seconds later against a
      # listener that was never there.
      [spec] = MeetingActionItems.register()
      entry = Platform.Meetings.IntentRouting.entry_for_key("meetings.action_items")

      assert spec.trigger_config == %{
               "topic" => entry.topic,
               "event_match" => Atom.to_string(entry.event)
             }

      # Pinned as literals as well as derived, because deriving both
      # sides from the same table would stay green if the table itself
      # were renamed. The singular "item" against the plural intent is
      # deliberate and load-bearing.
      assert spec.trigger_config["topic"] == "meeting:action_item_intent"
      assert spec.trigger_config["event_match"] == "action_item_intent"

      # The negative halves. `event_match` is what the Router routes on
      # (Phoenix.PubSub withholds the topic), so a row that kept
      # `"meeting_finished"` would still fire at meeting end even with
      # the topic changed.
      refute spec.trigger_config["topic"] == "meeting:finished"
      refute spec.trigger_config["event_match"] == "meeting_finished"
      refute Map.has_key?(spec.trigger_config, "topic_pattern")
    end

    test "the output contract is EMPTY — the recipient owns the canvas write" do
      [spec] = MeetingActionItems.register()

      assert spec.output_contract == %{}

      # Named rather than implied by the equality above, because this is
      # the defect being removed: an `operations` schema asked a model
      # holding canvas_create/canvas_patch to answer in JSON verbs so
      # Elixir could re-derive what it had already decided, and the
      # applying code was unreachable on the native path anyway.
      refute Map.has_key?(spec.output_contract, "operations")
      refute Map.has_key?(spec.output_contract, "action_items")
    end

    test "the empty contract PROPAGATES to a row still holding the operations schema" do
      # `output_contract` is in `@upsert_replace_fields`, which is why
      # this ships without a migration. If it were ever dropped from that
      # list the code would declare no contract while every migrated
      # environment kept validating model output against the reconciler's
      # JSON schema — a silent no-op deploy indistinguishable from
      # success.
      [spec] = MeetingActionItems.register()

      {:ok, existing} =
        Platform.Responsibilities.upsert_by_key(%{
          spec
          | output_contract: %{
              "operations" =>
                "list[object{op:add|update|remove, match:string, label:string, state:pending|active|complete}]"
            },
            context_provided: [
              "org_identity",
              "meeting_intent",
              "transcript_window",
              "action_items_canvas"
            ]
        })

      assert existing.output_contract["operations"]

      {:ok, reregistered} = Platform.Responsibilities.upsert_by_key(spec)

      assert reregistered.id == existing.id
      assert reregistered.output_contract == %{}
      assert "meeting_canvases" in reregistered.context_provided
      refute "action_items_canvas" in reregistered.context_provided
    end

    test "metadata identifies the platform owner and declares the key active" do
      [spec] = MeetingActionItems.register()
      assert spec.metadata["owner"] == "platform.meetings"
      assert spec.metadata["status"] == "active"
    end

    test "the active declaration PROPAGATES to a pre-existing row, where enabled would not" do
      # The whole reason `status` lives in `metadata` and not in
      # `enabled`. Simulate the production row (no status, and an
      # operator-flipped `enabled: false`), then re-run registration the
      # way boot does.
      [spec] = MeetingActionItems.register()

      {:ok, existing} =
        Platform.Responsibilities.upsert_by_key(%{
          spec
          | metadata: %{"owner" => "platform.meetings"}
        })

      {:ok, _} =
        existing
        |> Ecto.Changeset.change(%{enabled: false})
        |> Platform.Repo.update()

      {:ok, reregistered} = Platform.Responsibilities.upsert_by_key(spec)

      assert reregistered.id == existing.id
      # metadata IS in @upsert_replace_fields — the declaration lands.
      assert reregistered.metadata["status"] == "active"
      # enabled is NOT — the operator toggle survives, which is exactly
      # why a code-only `enabled` change would have been a no-op.
      refute reregistered.enabled
    end
  end

  describe "key/0" do
    test "matches the registered spec key" do
      [spec] = MeetingActionItems.register()
      assert MeetingActionItems.key() == spec.key
      assert MeetingActionItems.key() == "meetings.action_items"
    end
  end

  describe "gather_context/2 — the live mid-meeting slots" do
    # Every degraded case below asserts a DIFFERENT observable, on
    # purpose. If they all asserted "something is missing", one collapsed
    # `%{missing?: true}` map returned for every slot would satisfy the
    # lot of them and the suite could not tell a working gatherer from a
    # stub that gives up.
    test "POSITIVE CONTROL: all four slots populate from a live payload" do
      meeting = create_meeting!()
      space_id = meeting.chat_space_id

      transcript =
        create_transcript!(%{space_id: space_id, segments: [segment("Priya", "I'll revert it.")]})

      canvas = create_canvas!(space_id, "Action Items")

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(
                 responsibility(),
                 intent_trigger_meta(meeting, transcript, %{
                   chunk_excerpt: "I'll revert the onboarding flow by Friday",
                   speaker: "Priya"
                 })
               )

      assert Map.has_key?(ctx, :org_identity)

      # The utterance, verbatim. A gatherer that dropped the excerpt and
      # left the model to infer it from the window would still populate
      # every other key.
      assert ctx.meeting_intent.chunk_excerpt == "I'll revert the onboarding flow by Friday"
      assert ctx.meeting_intent.intent_id == intent_id()
      assert ctx.meeting_intent.meeting_id == meeting.id
      assert ctx.meeting_intent.classified_intent == "action_items"
      assert ctx.meeting_intent.speaker == "Priya"
      refute ctx.meeting_intent.missing?

      refute ctx.transcript_window.missing?
      assert ctx.transcript_window.formatted_text =~ "Priya"

      refute ctx.meeting_canvases.missing?
      assert ctx.meeting_canvases.space_id == space_id

      assert [%{id: id, title: "Action Items", kind: "checklist"}] = ctx.meeting_canvases.canvases
      assert id == canvas.id
    end

    test "the window is BOUNDED at 8 — 12 segments in, the last 8 out" do
      # Non-emptiness would pass against a gatherer that hands over the
      # whole transcript, which is precisely the unbounded per-utterance
      # cost this shape exists to remove. Assert the bound and the
      # DIRECTION of the trim: the tail is what matters mid-meeting.
      meeting = create_meeting!()
      space_id = meeting.chat_space_id

      segments = for n <- 1..12, do: segment("Speaker#{n}", "line number #{n}")
      transcript = create_transcript!(%{space_id: space_id, segments: segments})

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(
                 responsibility(),
                 intent_trigger_meta(meeting, transcript, %{chunk_excerpt: "line number 12"})
               )

      assert length(ctx.transcript_window.segments) == 8

      # Newest kept, oldest dropped.
      assert ctx.transcript_window.formatted_text =~ "line number 12"
      assert ctx.transcript_window.formatted_text =~ "line number 5"
      refute ctx.transcript_window.formatted_text =~ "line number 4"
      refute ctx.transcript_window.formatted_text =~ "line number 1:"
    end

    test "no transcript row: the window is missing and the INTENT is not" do
      # The independence proof. Mid-meeting the first action item can
      # legitimately arrive before a transcript row exists, and the
      # utterance is still the ground truth. A gatherer that treated a
      # missing transcript as a whole-context failure would refuse the
      # very first commitment of every meeting.
      meeting = create_meeting!()

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(
                 responsibility(),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "Ship it by Friday"})
               )

      assert ctx.transcript_window.missing?
      assert ctx.transcript_window.segments == []
      assert ctx.transcript_window.formatted_text == ""

      refute ctx.meeting_intent.missing?
      assert ctx.meeting_intent.chunk_excerpt == "Ship it by Friday"
    end

    test "a transcript with no segments yet is a missing window, not an error" do
      meeting = create_meeting!()
      space_id = meeting.chat_space_id
      transcript = create_transcript!(%{space_id: space_id, segments: []})

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(
                 responsibility(),
                 intent_trigger_meta(meeting, transcript, %{chunk_excerpt: "Ship it"})
               )

      assert ctx.transcript_window.missing?
      assert ctx.transcript_window.transcript_id == transcript.id
      refute ctx.meeting_intent.missing?
    end

    test "an empty space is an empty INVENTORY, not a failure" do
      # How the recipient learns it must create the list rather than
      # patch one. The other two slots staying populated is what stops
      # this from being satisfiable by a bail-out.
      meeting = create_meeting!()
      space_id = meeting.chat_space_id
      transcript = create_transcript!(%{space_id: space_id, segments: [segment("Priya", "Hi")]})

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(
                 responsibility(),
                 intent_trigger_meta(meeting, transcript, %{chunk_excerpt: "Ship it"})
               )

      assert ctx.meeting_canvases.missing?
      assert ctx.meeting_canvases.canvases == []

      refute ctx.transcript_window.missing?
      refute ctx.meeting_intent.missing?
    end

    test "the inventory lists EVERY canvas in the space, not one blessed shape" do
      # The reconciler recognised exactly one canvas, by metadata it had
      # written itself, and anything else in the space was invisible to
      # the prompt. The recipient decides which canvas is the running
      # list, so it has to be shown all of them — including the ones it
      # made itself, which carry none of the platform's metadata.
      meeting = create_meeting!()
      space_id = meeting.chat_space_id

      a = create_canvas!(space_id, "Action Items")
      b = create_canvas!(space_id, "Rough notes")

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(
                 responsibility(),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "Ship it"})
               )

      ids = Enum.map(ctx.meeting_canvases.canvases, & &1.id)
      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
      assert "Rough notes" in Enum.map(ctx.meeting_canvases.canvases, & &1.title)
    end

    test "a blank chunk_excerpt is missing? true — and the other slots still populate" do
      # `build_prompt/1` owns the refusal; the gatherer's job is only to
      # report it honestly.
      meeting = create_meeting!()
      space_id = meeting.chat_space_id
      transcript = create_transcript!(%{space_id: space_id, segments: [segment("Priya", "Hi")]})

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(
                 responsibility(),
                 intent_trigger_meta(meeting, transcript, %{chunk_excerpt: "   "})
               )

      assert ctx.meeting_intent.missing?
      assert ctx.meeting_intent.chunk_excerpt == "   "
      refute ctx.transcript_window.missing?
    end

    test "a payload with no chunk_excerpt at all yields \"\", not nil" do
      assert {:ok, ctx} = MeetingActionItems.gather_context(responsibility(), %{payload: %{}})

      assert ctx.meeting_intent.chunk_excerpt == ""
      assert ctx.meeting_intent.missing?
      assert ctx.meeting_intent.speaker == nil
    end

    test "an entirely empty trigger yields four slots, no crash" do
      assert {:ok, ctx} = MeetingActionItems.gather_context(responsibility(), %{})

      assert Map.has_key?(ctx, :org_identity)
      assert ctx.meeting_intent.missing?
      assert ctx.transcript_window.missing?
      assert ctx.meeting_canvases.missing?
    end

    test "string-keyed payloads resolve the same as atom-keyed ones" do
      meeting = create_meeting!()
      space_id = meeting.chat_space_id
      transcript = create_transcript!(%{space_id: space_id, segments: [segment("Priya", "Hi")]})

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(responsibility(), %{
                 "payload" => %{
                   "meeting_id" => meeting.id,
                   "transcript_id" => transcript.id,
                   "chunk_excerpt" => "Ship it by Friday",
                   "speaker" => "Priya"
                 }
               })

      assert ctx.meeting_intent.chunk_excerpt == "Ship it by Friday"
      assert ctx.meeting_intent.speaker == "Priya"
      refute ctx.transcript_window.missing?
    end

    test "the space resolves from the MEETING when the payload carries no space_id" do
      # A canvas belongs to a meeting, and `chat_space_id` is a fact
      # where anything derived from the payload is what the dispatcher
      # managed to stamp at broadcast time. Omit `space_id` entirely so
      # only the meeting rung can succeed.
      meeting = create_meeting!()
      canvas = create_canvas!(meeting.chat_space_id, "Action Items")

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(responsibility(), %{
                 payload: %{meeting_id: meeting.id, chunk_excerpt: "Ship it"}
               })

      assert ctx.meeting_canvases.space_id == meeting.chat_space_id
      assert [%{id: found}] = ctx.meeting_canvases.canvases
      assert found == canvas.id
    end

    test "the payload's own space_id wins over the meeting's" do
      # The dispatcher stamps `space_id` when it resolved one; a meeting
      # can outlive the space its current conversation is happening in,
      # and writing to the meeting's original space would put the list
      # where nobody is looking.
      meeting = create_meeting!()
      elsewhere = create_space!()
      canvas = create_canvas!(elsewhere.id, "Action Items")
      _decoy = create_canvas!(meeting.chat_space_id, "Old meeting's list")

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(responsibility(), %{
                 payload: %{
                   meeting_id: meeting.id,
                   space_id: elsewhere.id,
                   chunk_excerpt: "Ship it"
                 }
               })

      assert ctx.meeting_canvases.space_id == elsewhere.id
      assert [%{id: found}] = ctx.meeting_canvases.canvases
      assert found == canvas.id
    end

    test "the whole transcript is NOT gathered any more" do
      # The retired slot, asserted absent. Leaving `meeting_transcript`
      # in the map alongside the new slots would keep the unbounded
      # per-utterance cost while every new assertion above went green.
      meeting = create_meeting!()
      space_id = meeting.chat_space_id
      transcript = create_transcript!(%{space_id: space_id, segments: [segment("Priya", "Hi")]})

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(
                 responsibility(),
                 intent_trigger_meta(meeting, transcript, %{chunk_excerpt: "Ship it"})
               )

      refute Map.has_key?(ctx, :meeting_transcript)
      refute Map.has_key?(ctx, :action_items_canvas)
    end

    # The claim is keyed by transcript and MeetingSummarize takes it.
    # Taking it here too would starve whichever co-subscriber lost — and
    # since this key fires many times per transcript, it would take the
    # token on the first utterance and never give it back.
    test "does NOT claim the router dispatch — summarize must still win its claim" do
      meeting = create_meeting!()
      space_id = meeting.chat_space_id

      transcript =
        create_transcript!(%{space_id: space_id, segments: [segment("Alex", "I'll email it.")]})

      assert {:ok, _} =
               MeetingActionItems.gather_context(
                 responsibility(),
                 intent_trigger_meta(meeting, transcript, %{chunk_excerpt: "I'll email it."})
               )

      assert {:ok, :claimed} = Platform.Meetings.claim_router_dispatch(transcript.id)
    end
  end

  describe "build_prompt/1" do
    test "renders the DB row over the assigns — no marker survives into the system turn" do
      meeting = create_meeting!()
      space_id = meeting.chat_space_id

      transcript =
        create_transcript!(%{
          space_id: space_id,
          segments: [segment("Priya", "I'll revert onboarding by Friday.")]
        })

      {:ok, ctx} =
        MeetingActionItems.gather_context(
          responsibility(),
          intent_trigger_meta(meeting, transcript, %{
            chunk_excerpt: "I'll revert onboarding by Friday",
            speaker: "Priya"
          })
        )

      assert {:ok, %{system: system, user: user}} = MeetingActionItems.build_prompt(ctx)

      # Values that exist ONLY in the assigns. A body that rendered its
      # `{{...}}` markers literally, or a build_prompt that stopped
      # passing the slots, cannot produce these.
      assert system =~ "I'll revert onboarding by Friday"
      assert system =~ "Priya"

      assert system =~ "revert onboarding by Friday.",
             "the transcript window did not reach the system turn"

      refute system =~ "{{", "an un-interpolated marker survived into the system turn"

      # The user turn is the utterance, and never the template NAME — the
      # live capture that opened task 019fa56b-c81f had exactly the slug
      # as the whole user turn.
      assert user =~ "I'll revert onboarding by Friday"
      refute user =~ "meetings.action_items.v1"
    end

    test "the DB row is LIVE — editing it changes what goes to the model" do
      # Every other assertion in this file is satisfiable by a
      # `system_prompt/1` that ignores the row and returns the inline
      # fallback: the two bodies deliberately share their subject matter.
      # Only editing the row and watching the render move can tell them
      # apart, and an operator retuning this key through
      # `prompt_template_update` is relying on exactly that.
      template = PromptTemplates.get_template_by_slug("meetings.action_items.v1")
      assert template

      {:ok, _} =
        PromptTemplates.update_template(template, %{
          content: "SENTINEL-BODY-019FB90F\n\n{{meeting_intent}}\n"
        })

      assert {:ok, %{system: system}} =
               MeetingActionItems.build_prompt(%{
                 meeting_intent: %{chunk_excerpt: "Ship the adapter fix"}
               })

      assert system =~ "SENTINEL-BODY-019FB90F",
             "the rendered system turn did not come from the DB row"

      assert system =~ "Ship the adapter fix"
    end

    test "the ack contract is composed on in CODE, ahead of the tunable body" do
      # The meeting's serial cursor is released by the recipient's
      # `intent_ack` and by nothing else on the native path — the
      # platform-side close died with the reconciler. A prompt author who
      # deleted this section from the row would reintroduce a 90-second
      # stall per intent and nothing would go red, so it is not in the
      # row to delete.
      template = PromptTemplates.get_template_by_slug("meetings.action_items.v1")

      {:ok, _} =
        PromptTemplates.update_template(template, %{content: "TUNED-BODY\n\n{{meeting_intent}}\n"})

      assert {:ok, %{system: system}} =
               MeetingActionItems.build_prompt(%{
                 meeting_intent: %{chunk_excerpt: "Ship it", intent_id: intent_id()}
               })

      assert system =~ "intent_ack"
      assert system =~ intent_id()

      # FIRST, not merely present. A recipient that stops reading early
      # must still have seen the thing that unblocks the meeting.
      {preamble_at, _} = :binary.match(system, "intent_ack")
      {body_at, _} = :binary.match(system, "TUNED-BODY")

      assert preamble_at < body_at
    end

    test "a fire with no intent id renders no ack section rather than naming a nil handle" do
      # A direct `Router.fire/2` from a console has no queue row behind
      # it and nothing to release.
      assert {:ok, %{system: system}} =
               MeetingActionItems.build_prompt(%{meeting_intent: %{chunk_excerpt: "Ship it"}})

      refute system =~ "intent_ack"
    end

    test "falls back to the inline body when the row is missing, and every marker is fed" do
      template = PromptTemplates.get_template_by_slug("meetings.action_items.v1")
      assert template, "the row must exist for its removal to prove anything"
      {:ok, _} = PromptTemplates.delete_template(template)

      ctx = %{
        meeting_intent: %{chunk_excerpt: "Ship the adapter fix", speaker: "Alex"},
        transcript_window: %{formatted_text: "Alex: we still owe the audit", missing?: false},
        meeting_canvases: %{
          space_id: unique_id(),
          canvases: [%{id: "c-1", title: "Action Items", kind: "checklist"}],
          missing?: false
        },
        org_identity: %{content: "Ellis ships Startup Suite", missing?: false}
      }

      {result, log} = with_log(fn -> MeetingActionItems.build_prompt(ctx) end)

      assert {:ok, %{system: system}} = result

      assert log =~ "meetings.action_items.v1 missing",
             "a silent fallback is how a rollout gap goes unnoticed"

      # THE DRIFT GUARD. `substitute/2` replaces only the markers it has
      # an assign for, so a marker added to the fallback body without a
      # matching slot survives literally — which is what this refutes.
      # (The DB path cannot be guarded this way: `PromptTemplates`
      # interpolates an unknown marker to "", leaving a heading with
      # nothing under it and no evidence in the output.)
      refute system =~ "{{", "a fallback marker has no assign feeding it"

      # And each of the four slots reached the body, so the guard above
      # is not passing on a body that dropped its markers entirely.
      assert system =~ "Ship the adapter fix"
      assert system =~ "we still owe the audit"
      assert system =~ "Action Items"
      assert system =~ "Ellis ships Startup Suite"
    end

    test "the fallback asks for judgement, not for a JSON schema" do
      # The defect this shape exists to remove. A prompt that specifies
      # an output contract puts the model's answer into operation verbs
      # for Elixir to re-apply — code that was unreachable on the native
      # path — instead of into the wording of the item and the decision
      # of whether anything changed at all.
      body = MeetingActionItems.fallback_prompt()

      refute body =~ "JSON"
      refute body =~ "operations"
      refute body =~ ~s("op")

      # The instructions that must survive the deletion.
      assert body =~ "Reconcile, do not append"
      assert body =~ "ground truth"
      assert body =~ "Never open a second"
      assert body =~ "Changing nothing is a correct outcome"
    end

    test "renders the canvas inventory, and its absence, into the system turn" do
      # Asserted through the fallback because the inventory is what tells
      # the recipient to create rather than patch, and "there is nothing
      # here yet" has to be STATED — a section that interpolates to
      # nothing reads as truncated rather than as empty.
      template = PromptTemplates.get_template_by_slug("meetings.action_items.v1")
      {:ok, _} = PromptTemplates.delete_template(template)

      meeting = create_meeting!()
      space_id = meeting.chat_space_id
      meta = intent_trigger_meta(meeting, nil, %{chunk_excerpt: "Ship the adapter fix"})

      {:ok, before_ctx} = MeetingActionItems.gather_context(responsibility(), meta)

      {{:ok, %{system: before_system}}, _log} =
        with_log(fn -> MeetingActionItems.build_prompt(before_ctx) end)

      assert before_system =~ "(no canvases in this meeting's space yet)"

      canvas = create_canvas!(space_id, "Action Items — Standup")

      {:ok, after_ctx} = MeetingActionItems.gather_context(responsibility(), meta)

      {{:ok, %{system: after_system}}, _log} =
        with_log(fn -> MeetingActionItems.build_prompt(after_ctx) end)

      assert after_system =~ "Action Items — Standup"
      assert after_system =~ canvas.id
      refute after_system =~ "(no canvases in this meeting's space yet)"
    end

    test "refuses a blank chunk — and a blank WINDOW is an ordinary render" do
      # These two must diverge. A blank window is the normal state at a
      # meeting's first commitment, so refusing on it would silently
      # drop the one utterance the list starts from.
      assert {:error, :no_intent_text} = MeetingActionItems.build_prompt(%{})

      assert {:error, :no_intent_text} =
               MeetingActionItems.build_prompt(%{meeting_intent: %{chunk_excerpt: "   "}})

      assert {:ok, %{system: system, user: user}} =
               MeetingActionItems.build_prompt(%{
                 meeting_intent: %{chunk_excerpt: "Priya will revert onboarding by Friday"},
                 transcript_window: %{formatted_text: "", missing?: true}
               })

      assert user =~ "Priya will revert onboarding by Friday"
      assert system =~ "no surrounding transcript captured yet"
    end

    test "a non-map context refuses rather than raising" do
      assert {:error, :no_intent_text} = MeetingActionItems.build_prompt(nil)
    end

    test "an unattributed speaker is rendered as an absence, never as a name" do
      # `speaker` is best-effort — the dispatcher recovers it by matching
      # excerpt text against transcript segments — so "we could not
      # attribute this line" must not read as an attribution.
      assert {:ok, %{system: system, user: user}} =
               MeetingActionItems.build_prompt(%{
                 meeting_intent: %{chunk_excerpt: "I'll send the audit", speaker: nil}
               })

      assert user =~ "Unattributed speaker"
      assert system =~ "Speaker: (unknown)"
    end
  end

  describe "handle_output/2" do
    test "returns :ok and writes NOTHING — the recipient owns the canvas" do
      # The reconciler's grave. `apply_operations/2` was reachable only
      # from the external dispatch path and this key's assignee resolves
      # native, so nothing it did ever ran; what it WOULD have done —
      # minting a canvas out of a parsed JSON body — is what this refutes.
      meeting = create_meeting!()
      space_id = meeting.chat_space_id
      before_messages = messages(space_id)

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 %{"operations" => [%{"op" => "add", "label" => "Ship the adapter fix"}]}
               )

      assert Chat.list_canvases(space_id) == []
      assert messages(space_id) == before_messages
    end

    test "an unparseable answer is still :ok — there is no contract to violate" do
      assert :ok = MeetingActionItems.handle_output(responsibility(), nil)
      assert :ok = MeetingActionItems.handle_output(responsibility(), "any prose at all")
    end
  end

  # ── handle_refusal/3 ───────────────────────────────────────────────────────
  #
  # The one piece of per-dispatch state this key holds. `IntentDispatcher`
  # marks the row `:dispatched` before handing off, which pins the
  # meeting's SERIAL cursor; a refusal returns up through
  # `Router.dispatch_external/5` without ever reaching a recipient, so
  # no `intent_ack` is coming and the only other exit is the 90-second
  # claim watchdog. Measured before this existed: one whitespace-only
  # utterance cost the meeting 90 seconds of queue and every intent
  # behind it waited.

  # A live queue row in `:dispatched`, exactly as `IntentDispatcher`
  # leaves it before the model round trip.
  defp dispatched_row!(meeting) do
    {:ok, row} =
      IntentQueue.enqueue(meeting.id, %{
        room_id: "room-#{System.unique_integer([:positive])}",
        chunk_excerpt: "Priya will revert the onboarding flow by Friday",
        classified_intent: "action_items",
        confidence: 0.9
      })

    {:ok, dispatched} = IntentQueue.transition(meeting.id, row.id, :dispatched)

    on_exit(fn -> IntentQueue.stop(meeting.id) end)

    dispatched
  end

  defp row_status(meeting_id, intent_id) do
    {:ok, row} = IntentQueue.get(meeting_id, intent_id)
    row
  end

  describe "handle_refusal/3 — closing the row a refusal leaves behind" do
    test "POSITIVE CONTROL: the row lands :dispatch_failed and the cursor is released" do
      meeting = create_meeting!()
      row = dispatched_row!(meeting)

      assert IntentQueue.cursor(meeting.id) == row.id

      capture_log(fn ->
        assert :ok =
                 MeetingActionItems.handle_refusal(
                   responsibility(),
                   {:build_prompt_refused, :no_intent_text},
                   intent_trigger_meta(meeting, nil, %{chunk_excerpt: "   ", intent_id: row.id})
                 )
      end)

      closed = row_status(meeting.id, row.id)

      # The INNER reason, not the `{:build_prompt_refused, _}` wrapper.
      # The wrapper names the Router's seam; the inner atom names what
      # was wrong with the utterance, which is what the meeting UI's
      # intent strip is for.
      assert closed.status == :dispatch_failed
      assert closed.dispatch_failure_reason == :no_intent_text

      # No round trip is claimed for a round trip that never happened —
      # `:timed_out` would have stamped this.
      assert is_nil(closed.timed_out_at)

      # The consequence the row status is a proxy for: the next intent
      # can go out now, not in 90 seconds.
      assert IntentQueue.cursor(meeting.id) == nil
    end

    test "a bare reason with no wrapper is carried through unchanged" do
      meeting = create_meeting!()
      row = dispatched_row!(meeting)

      capture_log(fn ->
        assert :ok =
                 MeetingActionItems.handle_refusal(
                   responsibility(),
                   :some_other_reason,
                   intent_trigger_meta(meeting, nil, %{intent_id: row.id})
                 )
      end)

      assert row_status(meeting.id, row.id).dispatch_failure_reason == :some_other_reason
    end

    test "a tuple reason is coerced to text rather than reaching the intent strip raw" do
      # `dispatch_failure_reason` is typed `atom | binary | nil` and is
      # rendered straight into the meeting UI. A tuple would arrive at a
      # person mid-meeting as Elixir debug output.
      meeting = create_meeting!()
      row = dispatched_row!(meeting)

      capture_log(fn ->
        assert :ok =
                 MeetingActionItems.handle_refusal(
                   responsibility(),
                   {:context_gather_refused, {:nested, :shape}},
                   intent_trigger_meta(meeting, nil, %{intent_id: row.id})
                 )
      end)

      reason = row_status(meeting.id, row.id).dispatch_failure_reason

      assert is_binary(reason)
      assert reason =~ "nested"
    end

    test "a row that ALREADY timed out is left alone" do
      # `transition/4` does not police terminal -> terminal, so writing
      # here would SUCCEED and erase the timeout from the operator's
      # view. Delete the terminal guard and this goes red.
      meeting = create_meeting!()
      row = dispatched_row!(meeting)

      {:ok, timed_out} = IntentQueue.transition(meeting.id, row.id, :timed_out)

      capture_log(fn ->
        assert :ok =
                 MeetingActionItems.handle_refusal(
                   responsibility(),
                   {:build_prompt_refused, :no_intent_text},
                   intent_trigger_meta(meeting, nil, %{intent_id: row.id})
                 )
      end)

      closed = row_status(meeting.id, row.id)

      assert closed.status == :timed_out

      # The timeout's own stamp is intact too — a transition would have
      # left `timed_out_at` in place while adding a second terminal
      # marker, so the status assertion alone does not prove no write.
      assert closed.timed_out_at == timed_out.timed_out_at
      assert is_nil(closed.dispatch_failure_reason)
    end

    test "no queue server for the meeting: nothing raises and none is started" do
      # The meeting ended, or this row was never queued. Treating the
      # missing row as a failure — or starting a queue to close a row
      # that does not exist — would be worse than the silence.
      meeting = create_meeting!()
      refute IntentQueue.running?(meeting.id)

      capture_log(fn ->
        assert :ok =
                 MeetingActionItems.handle_refusal(
                   responsibility(),
                   {:build_prompt_refused, :no_intent_text},
                   intent_trigger_meta(meeting, nil, %{intent_id: unique_id()})
                 )
      end)

      refute IntentQueue.running?(meeting.id)
    end

    test "a payload with no ids at all is a no-op" do
      assert :ok =
               MeetingActionItems.handle_refusal(
                 responsibility(),
                 {:build_prompt_refused, :no_intent_text},
                 %{kind: :event_topic, topic: "meeting:action_item_intent", payload: %{}}
               )
    end

    test "string-keyed payloads close the row the same as atom-keyed ones" do
      # Atom-keyed from an in-process broadcast, string-keyed from
      # anything that made a JSON round trip. A refusal that only
      # understood one spelling would leave half the rows stalled.
      meeting = create_meeting!()
      row = dispatched_row!(meeting)

      capture_log(fn ->
        assert :ok =
                 MeetingActionItems.handle_refusal(
                   responsibility(),
                   {:build_prompt_refused, :no_intent_text},
                   %{
                     "payload" => %{
                       "meeting_id" => meeting.id,
                       "intent_id" => row.id
                     }
                   }
                 )
      end)

      assert row_status(meeting.id, row.id).status == :dispatch_failed
    end
  end

  describe "Meetings.post_action_items_to_space/3" do
    test "inserts one system message tagged with the action-items source" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      assert :ok =
               Meetings.post_action_items_to_space(space.id, transcript.id, [
                 "First",
                 "Second"
               ])

      assert [message] = action_item_messages(space.id)
      assert message.content_type == "system"
      assert message.metadata["source"] == "meeting_action_items"
      assert message.metadata["transcript_id"] == transcript.id
      assert message.content =~ "- [ ] First"
      assert message.content =~ "- [ ] Second"
      assert message.content =~ "/api/transcripts/#{transcript.id}/download"
    end

    test "refuses an empty list instead of posting an empty checklist" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      assert {:error, :no_items} =
               Meetings.post_action_items_to_space(space.id, transcript.id, [])

      assert messages(space.id) == []
    end

    test "a space_id with no spaces row raises, exactly as post_summary_to_space/3 does" do
      # PINS PRE-EXISTING BEHAVIOUR, not a choice made here.
      # `ExecutionSpace.ensure_system_participant/1` inserts a
      # chat_participants row whose changeset declares no
      # `foreign_key_constraint`, so a dangling space_id surfaces as an
      # Ecto.ConstraintError rather than `{:error, _}`. The gold-standard
      # `post_summary_to_space/3` goes through the identical `with`, so
      # this deliberately mirrors it instead of diverging.
      transcript = create_transcript!()

      assert_raise Ecto.ConstraintError, fn ->
        Meetings.post_action_items_to_space(unique_id(), transcript.id, ["item"])
      end
    end
  end
end
