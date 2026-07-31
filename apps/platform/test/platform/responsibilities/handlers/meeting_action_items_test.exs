defmodule Platform.Responsibilities.Handlers.MeetingActionItemsTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.MeetingActionItems`.

  Task 019fa56b-c81f stage 3 turned this from a registration-only stub
  (extract the items, log the count, discard them) into a handler that
  actually delivers. The tests are written accordingly: the positive
  control asserts a MESSAGE ROW EXISTS carrying both item strings, not
  that `handle_output/3` returned `:ok` — returning `:ok` while doing
  nothing is precisely what the stub did, and is why the defect survived
  its own test file.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.ActionItemsCanvas
  alias Platform.Meetings.IntentQueue
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Handlers.MeetingActionItems
  alias Platform.Responsibilities.Responsibility

  defp unique_id, do: Platform.Types.UUIDv7.generate()

  # The `{{marker}}` names a prompt body actually interpolates. Derived
  # with the same regex `PromptTemplates.interpolate/2` uses, so the set
  # is what the renderer sees rather than what someone remembered to
  # list.
  defp markers(content) do
    ~r/\{\{(\w+)\}\}/
    |> Regex.scan(content)
    |> Enum.map(fn [_full, marker] -> marker end)
    |> MapSet.new()
  end

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
        "action_items_canvas"
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
          # `Map.merge/2` (not `||`) so an explicit `space_id: nil` sticks —
          # the no-space-to-post-to case needs a genuinely null column.
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

  # The `meeting:finished` trigger fixture is GONE, along with the tests
  # that used it (task 019fb90f-36e3 stage 4). This key no longer has a
  # post-meeting shape to be triggered with; every dispatch carries the
  # live intent payload below.

  # ── live-intent fixtures (task 019fb90f-36e3 stage 2) ──────────────────────

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
  # ignores any `chat_space_id` in the attrs (meetings.ex:295-306), so a
  # fixture that creates a space and hands it in gets a meeting bound to
  # a DIFFERENT space — and every canvas assertion silently looks in the
  # wrong place. The meeting's own `chat_space_id` is the space.
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

  defp create_action_items_canvas!(space_id, meeting_id, items) do
    {:ok, participant} = ExecutionSpace.ensure_system_participant(space_id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space_id,
        "created_by" => participant.id,
        "title" => "Action Items",
        "metadata" => Platform.Meetings.ActionItemsCanvas.metadata_for(meeting_id),
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{
            "id" => "root",
            "type" => "checklist",
            "children" =>
              Enum.map(items, fn {node_id, label, state} ->
                %{
                  "id" => node_id,
                  "type" => "checklist_item",
                  "props" => %{"label" => label, "state" => state}
                }
              end)
          }
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

      assert spec.trigger_config == %{
               "topic" => "meeting:action_item_intent",
               "event_match" => "action_item_intent"
             }

      assert spec.scope == "per_meeting"

      assert spec.context_provided == [
               "org_identity",
               "meeting_intent",
               "transcript_window",
               "action_items_canvas"
             ]

      # The retired slot, named explicitly. `context_provided` is
      # declarative for this key (nothing validates it against a
      # roster), so its only value is telling the next reader what the
      # handler is obliged to gather — and leaving `meeting_transcript`
      # on the list would be a live claim that the whole transcript is
      # still being loaded on every utterance.
      refute "meeting_transcript" in spec.context_provided
      assert spec.default_prompt_template == "meetings.action_items.v1"
      assert spec.cost_profile == "low_freq_capable"
    end

    test "the trigger points at the live intent path, NOT at meeting end" do
      # Split out from the exact-map assertion above deliberately. That
      # assertion pins the whole map, so it fails for any edit at all —
      # including a harmless one — and its failure message does not say
      # WHICH property broke. These name the two properties that
      # actually carry the retarget (task 019fb90f-36e3), so a
      # regression reads as "it went back to firing at meeting end"
      # rather than "a map changed".
      [spec] = MeetingActionItems.register()
      config = spec.trigger_config

      assert config["topic"] == "meeting:action_item_intent"
      assert config["event_match"] == "action_item_intent"

      # The negative halves. `event_match` is what the Router actually
      # routes on (Phoenix.PubSub withholds the topic), so a row that
      # kept `"meeting_finished"` would still fire at meeting end even
      # with the topic changed.
      refute config["topic"] == "meeting:finished"
      refute config["event_match"] == "meeting_finished"

      # `topic_pattern` described a wildcard subscribe that never
      # existed. Leaving it behind would be a live claim about a
      # `meeting:finished:*` subscription this key no longer has.
      refute Map.has_key?(config, "topic_pattern")
    end

    test "the retarget PROPAGATES to a pre-existing row without a migration" do
      # `trigger_config` is in `@upsert_replace_fields`, which is the
      # stated reason this stage ships no migration. If it were ever
      # removed from that list, the code would say
      # "meeting:action_item_intent" while every already-migrated
      # environment kept firing on `meeting:finished` — a silent
      # no-op deploy indistinguishable from success.
      [spec] = MeetingActionItems.register()

      {:ok, existing} =
        Platform.Responsibilities.upsert_by_key(%{
          spec
          | trigger_config: %{
              "topic" => "meeting:finished",
              "topic_pattern" => "meeting:finished:*",
              "event_match" => "meeting_finished"
            }
        })

      assert existing.trigger_config["topic"] == "meeting:finished"

      {:ok, reregistered} = Platform.Responsibilities.upsert_by_key(spec)

      assert reregistered.id == existing.id
      assert reregistered.trigger_config["topic"] == "meeting:action_item_intent"
      assert reregistered.trigger_config["event_match"] == "action_item_intent"
      refute Map.has_key?(reregistered.trigger_config, "topic_pattern")
    end

    test "output_contract satisfies the M1 schema invariant (map-of-strings)" do
      [spec] = MeetingActionItems.register()

      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value), "#{inspect(key)}=#{inspect(value)} must be a string type name"
      end)

      # The contract is a list of CANVAS OPERATIONS, not a list of items
      # (task 019fb90f-36e3 stage 3). The key answers with what to change
      # about a canvas that already exists, so an item list cannot
      # express "mark that one complete" or "drop that one".
      assert [{"operations", shape}] = Map.to_list(spec.output_contract)
      refute Map.has_key?(spec.output_contract, "action_items")

      for verb <- ["add", "update", "remove"] do
        assert shape =~ verb, "contract shape must name the #{verb} operation"
      end

      # A changeset round-trip, because `Responsibility.changeset/2`
      # casts this into JSONB and a non-string value would be rejected
      # at the DB seam rather than here.
      assert {:ok, row} = Platform.Responsibilities.upsert_by_key(spec)
      assert row.output_contract == spec.output_contract
    end

    test "metadata identifies the platform owner and declares the key active" do
      [spec] = MeetingActionItems.register()
      assert spec.metadata["owner"] == "platform.meetings"
      assert spec.metadata["status"] == "active"
    end

    test "the active declaration PROPAGATES to a pre-existing row, where enabled would not" do
      # The whole reason `status` lives in `metadata` and not in `enabled`.
      # Simulate the production row as it exists today (no status, and an
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
    # Task 019fb90f-36e3 stage 2. Every degraded case below asserts a
    # DIFFERENT observable, on purpose. If they all asserted "something
    # is missing", one collapsed `%{missing?: true}` map returned for
    # every slot would satisfy the lot of them and the suite could not
    # tell a working gatherer from a stub that gives up.
    test "POSITIVE CONTROL: all four slots populate from a live payload" do
      meeting = create_meeting!()
      space_id = meeting.chat_space_id

      transcript =
        create_transcript!(%{space_id: space_id, segments: [segment("Priya", "I'll revert it.")]})

      canvas =
        create_action_items_canvas!(space_id, meeting.id, [
          {"item-1", "Alex emails the deploy audit", "pending"}
        ])

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

      assert ctx.action_items_canvas.canvas_id == canvas.id
      assert ctx.action_items_canvas.revision == 1

      assert ctx.action_items_canvas.items == [
               %{node_id: "item-1", label: "Alex emails the deploy audit", state: "pending"}
             ]

      refute ctx.action_items_canvas.missing?
    end

    test "the window is BOUNDED at 8 — 12 segments in, the last 8 out" do
      # Non-emptiness would pass against a gatherer that hands over the
      # whole transcript, which is precisely the unbounded per-utterance
      # cost this stage exists to remove. Assert the bound and the
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
      # very first action item of every meeting.
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

    test "no canvas in the space: missing? is true and canvas_id is nil" do
      meeting = create_meeting!()
      space_id = meeting.chat_space_id
      transcript = create_transcript!(%{space_id: space_id, segments: [segment("Priya", "Hi")]})

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(
                 responsibility(),
                 intent_trigger_meta(meeting, transcript, %{chunk_excerpt: "Ship it"})
               )

      assert ctx.action_items_canvas.missing?
      assert ctx.action_items_canvas.canvas_id == nil
      assert ctx.action_items_canvas.items == []

      # And the OTHER two slots are fine — a missing canvas is the normal
      # state before the meeting's first action item, not a failure.
      refute ctx.transcript_window.missing?
      refute ctx.meeting_intent.missing?
    end

    test "NEGATIVE CONTROL: another meeting's canvas in the same space is not adopted" do
      # A space can hold more than one meeting's action-items canvas — a
      # recurring standup, or a meeting re-created after a cancel.
      # Reconciling this meeting's utterance onto the previous one's
      # canvas is a silent merge of two meetings' work, and every content
      # assertion above would still pass while it happened.
      meeting = create_meeting!()
      other_meeting = create_meeting!()
      space_id = meeting.chat_space_id
      transcript = create_transcript!(%{space_id: space_id, segments: [segment("Priya", "Hi")]})

      foreign =
        create_action_items_canvas!(space_id, other_meeting.id, [
          {"item-1", "Belongs to the other meeting", "pending"}
        ])

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(
                 responsibility(),
                 intent_trigger_meta(meeting, transcript, %{chunk_excerpt: "Ship it"})
               )

      assert ctx.action_items_canvas.missing?
      assert ctx.action_items_canvas.canvas_id == nil

      # The foreign canvas is genuinely in the space this gatherer looked
      # at — otherwise the refusal above would be proving nothing.
      assert Enum.any?(Chat.list_canvases(space_id), &(&1.id == foreign.id))
    end

    test "a blank chunk_excerpt is missing? true — and the other slots still populate" do
      # Stage 3 owns the refusal; the gatherer's job is only to report
      # it honestly. Asserting the window is STILL populated is what
      # stops this from being satisfiable by a bail-out.
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
      assert ctx.action_items_canvas.missing?
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

    test "the canvas is found via the MEETING's chat_space_id, with no space_id on the payload" do
      # The first rung of the ladder. A canvas belongs to a meeting;
      # reaching its space through the transcript is an inference where
      # `chat_space_id` is a fact. Omit `space_id` AND `transcript_id`
      # so only the meeting rung can succeed.
      meeting = create_meeting!()
      space_id = meeting.chat_space_id
      canvas = create_action_items_canvas!(space_id, meeting.id, [{"i", "Existing", "pending"}])

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(responsibility(), %{
                 payload: %{meeting_id: meeting.id, chunk_excerpt: "Ship it"}
               })

      assert ctx.action_items_canvas.canvas_id == canvas.id
    end

    test "the canvas is found via the TRANSCRIPT's space when the meeting row is gone" do
      # The last rung. A meeting_id that resolves to no row must fall
      # through rather than short-circuit the ladder.
      space = create_space!()
      meeting_id = Ecto.UUID.generate()
      transcript = create_transcript!(%{space_id: space.id, segments: [segment("Priya", "Hi")]})
      canvas = create_action_items_canvas!(space.id, meeting_id, [{"i", "Existing", "pending"}])

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(responsibility(), %{
                 payload: %{
                   meeting_id: meeting_id,
                   transcript_id: transcript.id,
                   chunk_excerpt: "Ship it"
                 }
               })

      assert ctx.action_items_canvas.canvas_id == canvas.id
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
    end

    # The claim is keyed by transcript and MeetingSummarize takes it.
    # Taking it here too would starve whichever co-subscriber lost —
    # and now that this key fires many times per transcript rather than
    # once, it would take the token on the first utterance and never
    # give it back.
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
    # Stage 3: the system turn is the `meetings.action_items.v1` DB row
    # rendered over the four gathered slots, and the refusal moves from
    # the transcript window onto the classified chunk.
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

      # A value that exists ONLY in the assigns. A body that rendered
      # its `{{...}}` markers literally, or a build_prompt that stopped
      # passing the slots, cannot produce this.
      assert system =~ "I'll revert onboarding by Friday"
      assert system =~ "Priya"

      assert system =~ "revert onboarding by Friday.",
             "the transcript window did not reach the system turn"

      refute system =~ "{{", "an un-interpolated marker survived into the system turn"

      # The mid-meeting framing came from the migrated row, not from a
      # heredoc that happens to be in the module.
      assert system =~ "DURING a live meeting"
      refute system =~ "A meeting just ended"

      # The user turn is the utterance, and never the template NAME —
      # the live capture that opened task 019fa56b-c81f had exactly the
      # slug as the whole user turn.
      assert user =~ "I'll revert onboarding by Friday"
      refute user =~ "meetings.action_items.v1"
    end

    test "the DB row is LIVE — editing it changes what goes to the model" do
      # The trap this stage exists for. Until now the row was DORMANT:
      # `Router.build_prompt_via_provider/2` never renders
      # `default_prompt_template` when the provider exports
      # `build_prompt/1`, so the live body was a heredoc and an operator
      # who edited the row through `prompt_template_update` observed
      # nothing. Every other assertion in this file is satisfiable by a
      # `system_prompt/1` that ignores the row and returns the inline
      # fallback — the two bodies deliberately share their anchors. Only
      # editing the row and watching the render move can tell them apart.
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
      refute system =~ "DURING a live meeting"
    end

    test "renders the canvas contents, and its absence, into the system turn" do
      meeting = create_meeting!()
      space_id = meeting.chat_space_id
      transcript = create_transcript!(%{space_id: space_id})

      meta =
        intent_trigger_meta(meeting, transcript, %{chunk_excerpt: "Ship the adapter fix"})

      {:ok, before_ctx} = MeetingActionItems.gather_context(responsibility(), meta)
      assert {:ok, %{system: before_system}} = MeetingActionItems.build_prompt(before_ctx)
      assert before_system =~ "No action-items canvas exists for this meeting yet"

      _canvas =
        create_action_items_canvas!(space_id, meeting.id, [
          {"item-1", "Priya reverts the onboarding flow by Friday", "pending"},
          {"item-2", "Alex emails the deploy audit", "complete"}
        ])

      {:ok, after_ctx} = MeetingActionItems.gather_context(responsibility(), meta)
      assert {:ok, %{system: after_system}} = MeetingActionItems.build_prompt(after_ctx)

      assert after_system =~ "Priya reverts the onboarding flow by Friday"
      assert after_system =~ "[complete] Alex emails the deploy audit"
      refute after_system =~ "No action-items canvas exists for this meeting yet"

      # Node ids are deliberately withheld: item identity is matched on
      # label text downstream, and a model that has seen a node id will
      # start quoting node ids back as handles.
      refute after_system =~ "item-1"
      refute after_system =~ "item-2"
    end

    test "falls back to the inline body when the row is missing, with the SAME marker set" do
      template = PromptTemplates.get_template_by_slug("meetings.action_items.v1")
      assert template, "the migrated row must exist for its removal to prove anything"

      db_markers = markers(template.content)
      fallback_markers = markers(MeetingActionItems.fallback_prompt())

      assert MapSet.size(db_markers) > 0

      assert db_markers == fallback_markers,
             "rollout gap: DB markers #{inspect(db_markers)} != fallback #{inspect(fallback_markers)}"

      # …and the declared variables agree with both, so the migration
      # descriptor cannot drift from either body. Derived on all three
      # sides rather than compared against a listed set.
      assert MapSet.new(template.variables) == db_markers

      {:ok, _} = PromptTemplates.delete_template(template)

      ctx = %{meeting_intent: %{chunk_excerpt: "Ship the adapter fix", speaker: "Alex"}}

      {result, log} = with_log(fn -> MeetingActionItems.build_prompt(ctx) end)

      assert {:ok, %{system: system}} = result

      assert log =~ "meetings.action_items.v1 missing",
             "a silent fallback is how a rollout gap goes unnoticed"

      assert system =~ "Ship the adapter fix"
      refute system =~ "{{", "the fallback was returned un-interpolated"
      assert system =~ "DURING a live meeting"
    end

    test "refuses a blank chunk — and a blank WINDOW is an ordinary render" do
      # These two must diverge. Before stage 3 both refused, so this
      # pair is the behavioural proof that the refusal moved off the
      # transcript and onto the utterance.
      assert {:error, :no_intent_text} = MeetingActionItems.build_prompt(%{})

      assert {:error, :no_intent_text} =
               MeetingActionItems.build_prompt(%{meeting_intent: %{chunk_excerpt: "   "}})

      # A present utterance with no transcript window at all: mid-meeting
      # the first action item routinely lands before the transcript row
      # exists, and that must cost a model call, not a refusal.
      assert {:ok, %{system: system, user: user}} =
               MeetingActionItems.build_prompt(%{
                 meeting_intent: %{chunk_excerpt: "Priya will revert onboarding by Friday"},
                 transcript_window: %{formatted_text: "", missing?: true}
               })

      assert user =~ "Priya will revert onboarding by Friday"
      assert system =~ "no surrounding transcript captured yet"
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
      assert system =~ "best-effort attribution"
    end
  end

  # ── handle_output/3 (task 019fb90f-36e3 stage 4) ───────────────────────────
  #
  # The delivery surface moved from a markdown message to a canvas, and
  # the handler picked up a second job: closing the intent row that the
  # dispatcher left `:dispatched`.
  #
  # The load-bearing control in this block is
  # `assert length(action_items_canvases(space_id)) == 1` on the UPDATE
  # path. Every content assertion here — "the item is present", "its
  # state is complete" — is equally satisfied by a handler that creates a
  # brand-new canvas on every single utterance, which is the exact defect
  # this stage exists to avoid. Only the count separates them.

  defp canvases(space_id), do: Chat.list_canvases(space_id)

  defp action_items_canvases(space_id) do
    space_id
    |> canvases()
    |> Enum.filter(&(&1.metadata["source"] == ActionItemsCanvas.metadata_source()))
  end

  # Read the LIVE document, not the row. `Canvas.Server` is the
  # authoritative writer and Postgres is a write-through sink; in test
  # `:canvas_persist_sync` makes the two agree, but asserting against the
  # server means these tests keep meaning the same thing if it ever does
  # not.
  defp live_document(canvas_id) do
    {:ok, %{document: document}} = Platform.Chat.Canvas.Server.describe(canvas_id)
    document
  end

  defp live_revision(canvas_id) do
    {:ok, %{revision: revision}} = Platform.Chat.Canvas.Server.describe(canvas_id)
    revision
  end

  defp items_on(canvas_id), do: canvas_id |> live_document() |> ActionItemsCanvas.summarize()

  defp labels_on(canvas_id), do: canvas_id |> items_on() |> Enum.map(& &1.label)

  defp operations_payload(operations), do: %{"operations" => operations}

  # A live queue row in `:dispatched`, exactly as `IntentDispatcher`
  # leaves it before the model round trip.
  defp dispatched_row!(meeting, overrides \\ %{}) do
    {:ok, row} =
      IntentQueue.enqueue(
        meeting.id,
        Map.merge(
          %{
            room_id: "room-#{System.unique_integer([:positive])}",
            chunk_excerpt: "Priya will revert the onboarding flow by Friday",
            classified_intent: "action_items",
            confidence: 0.9
          },
          overrides
        )
      )

    {:ok, dispatched} = IntentQueue.transition(meeting.id, row.id, :dispatched)

    on_exit(fn -> IntentQueue.stop(meeting.id) end)

    dispatched
  end

  defp row_status(meeting_id, intent_id) do
    {:ok, row} = IntentQueue.get(meeting_id, intent_id)
    row
  end

  describe "handle_output/3 — the CREATE path" do
    test "POSITIVE CONTROL: no canvas yet, add operations create exactly one" do
      meeting = create_meeting!()
      space_id = meeting.chat_space_id

      assert action_items_canvases(space_id) == []

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([
                   %{"op" => "add", "label" => "Priya reverts the onboarding flow by Friday"},
                   %{"op" => "add", "label" => "Alex emails the deploy audit"}
                 ]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      assert [canvas] = action_items_canvases(space_id)

      assert canvas.metadata["source"] == "meeting_action_items"
      assert canvas.metadata["meeting_id"] == meeting.id

      # The items are on a CHECKLIST — not a markdown blob that happens
      # to contain the same words. `summarize/1` only collects
      # `checklist_item` children of a `checklist`, so this fails for a
      # markdown document even though the labels would still be visible.
      assert labels_on(canvas.id) == [
               "Priya reverts the onboarding flow by Friday",
               "Alex emails the deploy audit"
             ]

      assert Enum.all?(items_on(canvas.id), &(&1.state == "pending"))
    end

    test "the create posts exactly one companion canvas message" do
      meeting = create_meeting!()
      space_id = meeting.chat_space_id

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([%{"op" => "add", "label" => "Ship the adapter fix"}]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      assert [canvas] = action_items_canvases(space_id)

      canvas_messages =
        space_id
        |> messages()
        |> Enum.filter(&(&1.canvas_id == canvas.id))

      assert length(canvas_messages) == 1
    end

    test "the canvas title names the meeting" do
      meeting = create_meeting!()

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([%{"op" => "add", "label" => "Ship it"}]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      assert [canvas] = action_items_canvases(meeting.chat_space_id)
      assert canvas.title == "Action Items — #{meeting.name}"
    end

    test "NEGATIVE CONTROL: zero operations creates NO canvas at all" do
      # The failure mode this pins is "skip the create" — but the mirror
      # failure, creating an empty canvas for every quiet utterance, is
      # just as real and only this assertion catches it.
      meeting = create_meeting!()

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      assert canvases(meeting.chat_space_id) == []
    end

    test "update and remove operations against a canvas that does not exist create nothing" do
      # There is nothing to update. Reinterpreting them as adds would put
      # items on the canvas that the model explicitly did not ask to add.
      meeting = create_meeting!()

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([
                   %{"op" => "update", "match" => "something", "state" => "complete"},
                   %{"op" => "remove", "match" => "something else"}
                 ]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      assert canvases(meeting.chat_space_id) == []
    end

    test "does NOT post the post-meeting markdown checklist" do
      # `post_action_items_to_space/3` renders the WHOLE list every call.
      # Mid-meeting that reposts everything once per utterance. The
      # companion canvas message is the announcement; this message is not.
      meeting = create_meeting!()

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([%{"op" => "add", "label" => "Ship the adapter fix"}]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      refute Enum.any?(messages(meeting.chat_space_id), &(&1.content =~ "**Action Items**"))
    end
  end

  describe "handle_output/3 — the UPDATE path" do
    test "POSITIVE CONTROL: adds and completes land on the SAME canvas" do
      meeting = create_meeting!()
      space_id = meeting.chat_space_id

      canvas =
        create_action_items_canvas!(space_id, meeting.id, [
          {"item-1", "Priya reverts the onboarding flow", "pending"},
          {"item-2", "Book the compliance sign-off", "pending"}
        ])

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([
                   %{"op" => "add", "label" => "Alex emails the deploy audit"},
                   %{
                     "op" => "update",
                     "match" => "Priya reverts the onboarding flow",
                     "state" => "complete"
                   }
                 ]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      # THE control. Every assertion below is also satisfied by a handler
      # that created a second canvas and wrote to that.
      assert length(action_items_canvases(space_id)) == 1
      assert [found] = action_items_canvases(space_id)
      assert found.id == canvas.id

      items = items_on(canvas.id)
      assert length(items) == 3

      assert Enum.find(items, &(&1.label == "Priya reverts the onboarding flow")).state ==
               "complete"

      assert Enum.any?(items, &(&1.label == "Alex emails the deploy audit"))
      assert Enum.find(items, &(&1.label == "Book the compliance sign-off")).state == "pending"
    end

    test "a remove operation deletes the item and leaves the others" do
      meeting = create_meeting!()

      canvas =
        create_action_items_canvas!(meeting.chat_space_id, meeting.id, [
          {"item-1", "Retracted idea", "pending"},
          {"item-2", "Still standing", "pending"}
        ])

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([%{"op" => "remove", "match" => "Retracted idea"}]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      assert labels_on(canvas.id) == ["Still standing"]
    end

    test "an item the operations do not touch is left exactly as it was" do
      meeting = create_meeting!()

      canvas =
        create_action_items_canvas!(meeting.chat_space_id, meeting.id, [
          {"item-1", "Untouched", "active"}
        ])

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([%{"op" => "add", "label" => "Brand new"}]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      assert Enum.find(items_on(canvas.id), &(&1.label == "Untouched")).state == "active"
    end

    test "ZERO operations leave the document byte-identical and the revision unchanged" do
      meeting = create_meeting!()

      canvas =
        create_action_items_canvas!(meeting.chat_space_id, meeting.id, [
          {"item-1", "Unchanged", "pending"}
        ])

      before_document = live_document(canvas.id)
      before_revision = live_revision(canvas.id)

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      assert live_document(canvas.id) == before_document
      assert live_revision(canvas.id) == before_revision
      assert length(action_items_canvases(meeting.chat_space_id)) == 1
    end

    test "an add whose label already exists updates that item instead of duplicating it" do
      # The e2e case: the model says "add: Priya reverts the onboarding
      # flow" on a canvas that already holds it. Reconcile, don't append.
      meeting = create_meeting!()

      canvas =
        create_action_items_canvas!(meeting.chat_space_id, meeting.id, [
          {"item-1", "Priya reverts the onboarding flow", "pending"}
        ])

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([
                   %{
                     "op" => "add",
                     "label" => "Priya reverts the onboarding flow",
                     "state" => "complete"
                   }
                 ]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      assert [item] = items_on(canvas.id)
      assert item.state == "complete"
    end

    test "an operation with NO verb but a match is an update, not an add" do
      # A model that quotes an existing item back without naming a verb
      # means "this one changes". Reading it as an add duplicates the
      # item it was pointing at.
      meeting = create_meeting!()

      canvas =
        create_action_items_canvas!(meeting.chat_space_id, meeting.id, [
          {"item-1", "Ship the adapter fix", "pending"}
        ])

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([
                   %{"match" => "Ship the adapter fix", "state" => "complete"}
                 ]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      assert [item] = items_on(canvas.id)
      assert item.state == "complete"
    end

    test "an operation with NO verb and NO match is an add" do
      meeting = create_meeting!()

      canvas =
        create_action_items_canvas!(meeting.chat_space_id, meeting.id, [
          {"item-1", "Ship the adapter fix", "pending"}
        ])

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([%{"label" => "Brand new commitment"}]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      assert labels_on(canvas.id) == ["Ship the adapter fix", "Brand new commitment"]
    end

    test "an unresolvable match is SKIPPED, not turned into an add" do
      meeting = create_meeting!()

      canvas =
        create_action_items_canvas!(meeting.chat_space_id, meeting.id, [
          {"item-1", "Ship the adapter fix", "pending"}
        ])

      before_revision = live_revision(canvas.id)

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([
                   %{
                     "op" => "update",
                     "match" => "nothing like this exists",
                     "state" => "complete"
                   }
                 ]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      assert labels_on(canvas.id) == ["Ship the adapter fix"]
      assert live_revision(canvas.id) == before_revision
    end

    test "the canvas is found by meeting, so a sibling meeting's canvas is untouched" do
      # Two meetings can share nothing but the space in a recurring
      # standup. Writing to the wrong one merges two meetings' lists.
      meeting = create_meeting!()
      other_meeting_id = unique_id()

      ours =
        create_action_items_canvas!(meeting.chat_space_id, meeting.id, [
          {"item-1", "Ours", "pending"}
        ])

      theirs =
        create_action_items_canvas!(meeting.chat_space_id, other_meeting_id, [
          {"item-2", "Theirs", "pending"}
        ])

      theirs_before = live_document(theirs.id)

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([%{"op" => "add", "label" => "New item"}]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      assert length(labels_on(ours.id)) == 2
      assert live_document(theirs.id) == theirs_before
    end
  end

  describe "handle_output/3 — failure outcomes" do
    test "a malformed output writes NOTHING and returns an error" do
      meeting = create_meeting!()

      canvas =
        create_action_items_canvas!(meeting.chat_space_id, meeting.id, [
          {"item-1", "Unchanged", "pending"}
        ])

      before_revision = live_revision(canvas.id)

      log =
        capture_log(fn ->
          assert {:error, :unexpected_output_shape} =
                   MeetingActionItems.handle_output(
                     responsibility(),
                     nil,
                     intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
                   )
        end)

      assert log =~ "unexpected output shape"
      assert live_revision(canvas.id) == before_revision
      assert length(action_items_canvases(meeting.chat_space_id)) == 1
    end

    test "JSON that is not the operations contract is an error, NOT prose" do
      # Sending a decoded JSON object to the prose splitter would shred
      # its punctuation into invented action items.
      meeting = create_meeting!()

      log =
        capture_log(fn ->
          assert {:error, :unexpected_operations_shape} =
                   MeetingActionItems.handle_output(
                     responsibility(),
                     ~s({"action_items": ["Ship the adapter fix"]}),
                     intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
                   )
        end)

      assert log =~ "not the operations"
      assert canvases(meeting.chat_space_id) == []
    end

    test "no meeting_id in the payload is {:error, :missing_meeting_id}" do
      capture_log(fn ->
        assert {:error, :missing_meeting_id} =
                 MeetingActionItems.handle_output(
                   responsibility(),
                   operations_payload([%{"op" => "add", "label" => "orphan"}]),
                   %{kind: :event_topic, topic: "meeting:action_item_intent", payload: %{}}
                 )
      end)
    end

    test "a meeting whose space cannot be resolved is {:error, :missing_space_id}" do
      log =
        capture_log(fn ->
          assert {:error, :missing_space_id} =
                   MeetingActionItems.handle_output(
                     responsibility(),
                     operations_payload([%{"op" => "add", "label" => "nowhere to go"}]),
                     %{
                       kind: :event_topic,
                       topic: "meeting:action_item_intent",
                       payload: %{meeting_id: unique_id(), intent_id: intent_id()}
                     }
                   )
        end)

      assert log =~ "no space for meeting"
    end

    test "arity-2 delegates to arity-3, which has no meeting to reconcile" do
      capture_log(fn ->
        assert {:error, :missing_meeting_id} =
                 MeetingActionItems.handle_output(
                   responsibility(),
                   operations_payload([%{"op" => "add", "label" => "x"}])
                 )
      end)
    end
  end

  describe "handle_output/3 — closing the intent row" do
    test "a landed canvas write completes the row" do
      meeting = create_meeting!()
      row = dispatched_row!(meeting)

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([%{"op" => "add", "label" => "Ship the adapter fix"}]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "...", intent_id: row.id})
               )

      assert row_status(meeting.id, row.id).status == :completed
    end

    test "a ZERO-operation response still completes the row" do
      # A quiet utterance is a successful dispatch that changed nothing.
      # Leaving it `:dispatched` would hold the meeting's serial cursor
      # for the full 90-second ack window.
      meeting = create_meeting!()
      row = dispatched_row!(meeting)

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "...", intent_id: row.id})
               )

      assert row_status(meeting.id, row.id).status == :completed
    end

    test "a malformed output lands the row :dispatch_failed with the reason" do
      # Paired with the zero-operation case above ON PURPOSE. If both
      # landed the same status the suite could not tell a parse failure
      # from a quiet meeting, which is the whole reason
      # `extract_operations/1` stopped returning a bare list.
      meeting = create_meeting!()
      row = dispatched_row!(meeting)

      capture_log(fn ->
        assert {:error, :unexpected_output_shape} =
                 MeetingActionItems.handle_output(
                   responsibility(),
                   nil,
                   intent_trigger_meta(meeting, nil, %{chunk_excerpt: "...", intent_id: row.id})
                 )
      end)

      closed = row_status(meeting.id, row.id)

      assert closed.status == :dispatch_failed
      assert closed.dispatch_failure_reason == :unexpected_output_shape
    end

    test "the cursor is released, so the next intent can go out" do
      meeting = create_meeting!()
      row = dispatched_row!(meeting)

      assert IntentQueue.cursor(meeting.id) == row.id

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([%{"op" => "add", "label" => "Ship the adapter fix"}]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "...", intent_id: row.id})
               )

      assert IntentQueue.cursor(meeting.id) == nil
    end

    test "a row that ALREADY timed out is left alone, and the canvas write still stands" do
      # `transition/4` does not police terminal -> terminal, so writing
      # `:completed` here would SUCCEED and erase the timeout from the
      # operator's view. Delete the terminal guard and this goes red.
      meeting = create_meeting!()
      row = dispatched_row!(meeting)

      {:ok, timed_out} = IntentQueue.transition(meeting.id, row.id, :timed_out)

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([%{"op" => "add", "label" => "Late but real"}]),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "...", intent_id: row.id})
               )

      closed = row_status(meeting.id, row.id)

      assert closed.status == :timed_out

      # The timeout's own stamp is intact too — a transition would have
      # left `timed_out_at` in place while adding `completed_at`, so the
      # status assertion alone does not prove no write happened.
      assert closed.timed_out_at == timed_out.timed_out_at
      assert is_nil(closed.completed_at)

      # The work is not thrown away just because the row gave up on it.
      assert [canvas] = action_items_canvases(meeting.chat_space_id)
      assert labels_on(canvas.id) == ["Late but real"]
    end

    test "no queue server for the meeting: the canvas write still lands and nothing raises" do
      # The meeting ended, or this row was never queued. A handler that
      # treated the missing row as a failure would throw away a canvas
      # write that succeeded.
      meeting = create_meeting!()
      refute IntentQueue.running?(meeting.id)

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 operations_payload([%{"op" => "add", "label" => "Ship the adapter fix"}]),
                 intent_trigger_meta(meeting, nil, %{
                   chunk_excerpt: "...",
                   intent_id: unique_id()
                 })
               )

      assert [canvas] = action_items_canvases(meeting.chat_space_id)
      assert labels_on(canvas.id) == ["Ship the adapter fix"]

      # And no queue was started as a side effect of trying to close a
      # row that does not exist.
      refute IntentQueue.running?(meeting.id)
    end
  end

  # Task 019fa56b-c81f e2e fix, defect 1. In production the handler is
  # only ever reached via `Router.invoke_handle_output/3`, whose `parsed`
  # comes from `ContractValidator.validate/2` — which returns the RAW
  # STRING for this responsibility's field-map contract. The map-shaped
  # tests above never exercise the shape production actually sends. These
  # pin the string rules documented on `extract_operations/1`.
  #
  # End-to-end proof that the dispatch path really produces these shapes
  # lives in `meeting_action_items_dispatch_test.exs`.
  describe "handle_output/3 — freeform STRING output (the production shape)" do
    defp apply_string!(string, meeting) do
      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 string,
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      action_items_canvases(meeting.chat_space_id)
    end

    test "rule 1: a JSON object carrying the operations contract decodes" do
      meeting = create_meeting!()

      assert [canvas] =
               apply_string!(
                 ~s({"operations": [{"op": "add", "label": "Ship the adapter fix"},
                                    {"op": "add", "label": "Email Rowan the audit"}]}),
                 meeting
               )

      assert labels_on(canvas.id) == ["Ship the adapter fix", "Email Rowan the audit"]
    end

    test "rule 1: a bare JSON array of strings reads as adds" do
      # The pre-stage-3 `list[string]` contract. A model still answering
      # it adds items rather than failing.
      meeting = create_meeting!()

      assert [canvas] = apply_string!(~s(["Book the review", "Send the doc"]), meeting)
      assert labels_on(canvas.id) == ["Book the review", "Send the doc"]
    end

    test "rule 3: prose with markers keeps ONLY the marked lines, as adds" do
      meeting = create_meeting!()

      assert [canvas] =
               apply_string!(
                 """
                 Here are the action items from the meeting:

                 - Revert the onboarding flow
                 * Email the deploy audit
                 3. Book the compliance sign-off

                 Let me know if I missed anything.
                 """,
                 meeting
               )

      assert labels_on(canvas.id) == [
               "Revert the onboarding flow",
               "Email the deploy audit",
               "Book the compliance sign-off"
             ]
    end

    test "rule 3b: with no marked line, every non-blank line is an add" do
      meeting = create_meeting!()

      assert [canvas] =
               apply_string!(
                 "Revert the onboarding flow\n\n   \nEmail the deploy audit\n",
                 meeting
               )

      assert labels_on(canvas.id) == ["Revert the onboarding flow", "Email the deploy audit"]
    end

    test "rule 4: the marker is stripped once, so an inner hyphen survives" do
      meeting = create_meeting!()

      assert [canvas] = apply_string!("- see - the tradeoff doc", meeting)
      assert labels_on(canvas.id) == ["see - the tradeoff doc"]
    end

    test "a blank string writes nothing and creates no canvas" do
      meeting = create_meeting!()

      assert apply_string!("   \n\n \n", meeting) == []
      assert apply_string!("", meeting) == []
    end

    test "an empty operations array writes nothing and creates no canvas" do
      meeting = create_meeting!()

      assert apply_string!(~s({"operations": []}), meeting) == []
    end

    test "a string answer can complete an existing item" do
      meeting = create_meeting!()

      canvas =
        create_action_items_canvas!(meeting.chat_space_id, meeting.id, [
          {"item-1", "Revert the onboarding flow", "pending"}
        ])

      assert [^canvas] = [canvas]

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 ~s({"operations": [{"op": "update", "match": "revert the onboarding flow",
                                     "state": "complete"}]}),
                 intent_trigger_meta(meeting, nil, %{chunk_excerpt: "..."})
               )

      assert [item] = items_on(canvas.id)
      assert item.state == "complete"
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
      # PINS PRE-EXISTING BEHAVIOUR, not a choice made by this stage.
      # `ExecutionSpace.ensure_system_participant/1` inserts a
      # chat_participants row whose changeset declares no
      # `foreign_key_constraint`, so a dangling space_id surfaces as an
      # Ecto.ConstraintError rather than `{:error, _}`. The gold-standard
      # `post_summary_to_space/3` goes through the identical `with`, so
      # this stage deliberately mirrors it instead of diverging. The blast
      # radius is bounded: `Router.invoke_handle_output/3` already rescues
      # and logs "handle_output raised" (router.ex:1349).
      transcript = create_transcript!()

      assert_raise Ecto.ConstraintError, fn ->
        Meetings.post_action_items_to_space(unique_id(), transcript.id, ["item"])
      end
    end
  end
end
