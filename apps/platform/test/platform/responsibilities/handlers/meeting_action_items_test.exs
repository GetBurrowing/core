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
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Responsibilities.Handlers.MeetingActionItems
  alias Platform.Responsibilities.Responsibility

  defp unique_id, do: Platform.Types.UUIDv7.generate()

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: MeetingActionItems.key(),
      feature: "meetings",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => "meeting:finished"},
      scope: "per_meeting",
      context_provided: ["org_identity", "meeting_transcript"],
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

  defp trigger_meta(transcript) do
    %{
      kind: :event_topic,
      topic: "meeting:finished",
      payload: %{
        transcript_id: transcript.id,
        room_id: transcript.room_id,
        space_id: transcript.space_id
      }
    }
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
               "topic" => "meeting:finished",
               "topic_pattern" => "meeting:finished:*",
               "event_match" => "meeting_finished"
             }

      assert spec.scope == "per_meeting"
      assert spec.context_provided == ["org_identity", "meeting_transcript"]
      assert spec.default_prompt_template == "meetings.action_items.v1"
      assert spec.cost_profile == "low_freq_capable"
    end

    test "output_contract satisfies the M1 schema invariant (map-of-strings)" do
      [spec] = MeetingActionItems.register()

      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value), "#{inspect(key)}=#{inspect(value)} must be a string type name"
      end)

      assert spec.output_contract == %{"action_items" => "list[string]"}
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

  describe "gather_context/2" do
    # Task 019fa56b-c81f e2e fix. This used to read
    # `assert {:ok, %{}} = ...` under the title "returns an empty map —
    # the shim handles the shared meetings slots". Both halves were
    # wrong: `%{}` is a pattern that matches ANY map, so the assertion
    # could never fail, and the shim does NOT resolve the slots — it
    # delegates straight back here, which is why the dispatch went out
    # with no transcript. Assert the declared slots explicitly.
    test "gathers the two slots register/0 declares in context_provided" do
      transcript = create_transcript!(%{segments: [segment("Priya", "I'll revert onboarding.")]})

      assert {:ok, ctx} =
               MeetingActionItems.gather_context(responsibility(), %{
                 payload: %{transcript_id: transcript.id}
               })

      assert Map.has_key?(ctx, :org_identity)
      assert Map.has_key?(ctx, :meeting_transcript)
      assert ctx.meeting_transcript.formatted_text =~ "Priya"
      assert ctx.meeting_transcript.formatted_text =~ "revert onboarding"
    end

    test "a trigger with no transcript_id yields a missing transcript, not a crash" do
      assert {:ok, ctx} = MeetingActionItems.gather_context(responsibility(), %{})
      assert ctx.meeting_transcript.missing?
      assert ctx.meeting_transcript.formatted_text == ""
    end

    # The claim is keyed by transcript and MeetingSummarize takes it.
    # Taking it here too would starve whichever co-subscriber lost.
    test "does NOT claim the router dispatch — summarize must still win its claim" do
      transcript = create_transcript!(%{segments: [segment("Alex", "I'll email the audit.")]})

      assert {:ok, _} =
               MeetingActionItems.gather_context(responsibility(), %{
                 payload: %{transcript_id: transcript.id}
               })

      assert {:ok, :claimed} = Platform.Meetings.claim_router_dispatch(transcript.id)
    end
  end

  describe "build_prompt/1" do
    test "renders the transcript into the user turn, never the template name" do
      transcript =
        create_transcript!(%{segments: [segment("Priya", "I'll revert onboarding by Friday.")]})

      {:ok, ctx} =
        MeetingActionItems.gather_context(responsibility(), %{
          payload: %{transcript_id: transcript.id}
        })

      assert {:ok, %{system: system, user: user}} = MeetingActionItems.build_prompt(ctx)

      assert user =~ "Extract the action items"
      assert user =~ "Priya"
      assert user =~ "revert onboarding by Friday"
      refute user =~ "meetings.action_items.v1"
      assert system =~ "action_items"
    end

    test "refuses an empty transcript rather than spending a round-trip" do
      assert {:error, :no_transcript_text} = MeetingActionItems.build_prompt(%{})

      assert {:error, :no_transcript_text} =
               MeetingActionItems.build_prompt(%{meeting_transcript: %{formatted_text: "   "}})
    end
  end

  describe "handle_output/3 — the delivery this stage exists for" do
    test "POSITIVE CONTROL: extracted items land as a message in the meeting space" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      before_count = length(messages(space.id))

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 %{"action_items" => ["Ship the thing", "Email Rowan"]},
                 trigger_meta(transcript)
               )

      posted = action_item_messages(space.id)

      # A row EXISTS — not merely "the call returned :ok", which is exactly
      # what the discarding stub did.
      assert length(posted) == 1
      [message] = posted

      # And it carries the actual items.
      assert message.content =~ "Ship the thing"
      assert message.content =~ "Email Rowan"

      assert message.metadata["transcript_id"] == transcript.id
      assert length(messages(space.id)) == before_count + 1
    end

    test "renders the items as a markdown checklist under a header" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 %{"action_items" => ["Ship the thing", "Email Rowan"]},
                 trigger_meta(transcript)
               )

      [message] = action_item_messages(space.id)

      assert message.content =~ "**Action Items**"
      assert message.content =~ "- [ ] Ship the thing"
      assert message.content =~ "- [ ] Email Rowan"
    end

    test "atom-keyed action_items are delivered too" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 %{action_items: ["Atom-keyed item"]},
                 trigger_meta(transcript)
               )

      assert [message] = action_item_messages(space.id)
      assert message.content =~ "Atom-keyed item"
    end

    test "non-string entries are filtered out but the string ones still land" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 %{"action_items" => ["Real item", 42, %{"nested" => "junk"}]},
                 trigger_meta(transcript)
               )

      assert [message] = action_item_messages(space.id)
      assert message.content =~ "Real item"
      refute message.content =~ "42"
      refute message.content =~ "nested"
    end

    test "falls back to the transcript row's space_id when the trigger omits it" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      meta = %{
        kind: :event_topic,
        topic: "meeting:finished",
        payload: %{transcript_id: transcript.id, room_id: transcript.room_id}
      }

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 %{"action_items" => ["Recovered via the transcript row"]},
                 meta
               )

      assert [message] = action_item_messages(space.id)
      assert message.content =~ "Recovered via the transcript row"
    end
  end

  describe "handle_output/3 — non-delivery outcomes" do
    test "an EMPTY item list posts nothing and returns :ok" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      before_count = length(messages(space.id))

      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 %{"action_items" => []},
                 trigger_meta(transcript)
               )

      # The message COUNT is unchanged — not just "no error was raised".
      assert length(messages(space.id)) == before_count
      assert action_item_messages(space.id) == []
    end

    test "a malformed payload logs the shape warning, posts nothing, returns :ok" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      before_count = length(messages(space.id))

      log =
        capture_log(fn ->
          assert :ok =
                   MeetingActionItems.handle_output(
                     responsibility(),
                     %{"items" => ["wrong key"]},
                     trigger_meta(transcript)
                   )

          assert :ok =
                   MeetingActionItems.handle_output(
                     responsibility(),
                     nil,
                     trigger_meta(transcript)
                   )
        end)

      assert log =~ "[meetings.action_items]"
      assert log =~ "unexpected output shape"

      assert length(messages(space.id)) == before_count
      assert action_item_messages(space.id) == []
    end

    test "a missing transcript_id returns {:error, :missing_transcript_id}" do
      # Mirrors MeetingSummarize — a trigger with no transcript is a failed
      # outcome, not a silent success.
      capture_log(fn ->
        assert {:error, :missing_transcript_id} =
                 MeetingActionItems.handle_output(
                   responsibility(),
                   %{"action_items" => ["orphan item"]},
                   %{kind: :event_topic, topic: "meeting:finished", payload: %{}}
                 )
      end)
    end

    test "an unresolvable space returns {:error, :missing_space_id} rather than :ok" do
      # Transcript row carries a space_id that is not a real space, and the
      # trigger omits one: nothing to post to. The items are lost either
      # way, but the outcome must be recorded as a failure.
      transcript = create_transcript!(%{space_id: nil})

      meta = %{
        kind: :event_topic,
        topic: "meeting:finished",
        payload: %{transcript_id: transcript.id}
      }

      log =
        capture_log(fn ->
          assert {:error, :missing_space_id} =
                   MeetingActionItems.handle_output(
                     responsibility(),
                     %{"action_items" => ["nowhere to go"]},
                     meta
                   )
        end)

      assert log =~ "no space_id for transcript"
    end

    test "arity-2 delegates to arity-3, which has no transcript to post to" do
      assert {:error, :missing_transcript_id} =
               MeetingActionItems.handle_output(responsibility(), %{"action_items" => ["x"]})
    end
  end

  # Task 019fa56b-c81f e2e fix, defect 1. In production the handler is
  # only ever reached via `Router.invoke_handle_output/3`, whose `parsed`
  # comes from `ContractValidator.validate/2` — which returns the RAW
  # STRING for this responsibility's field-map contract. Every other test
  # in this file hands `handle_output/3` a map, so none of them exercises
  # the shape production actually sends. These pin the string rule
  # documented on `extract_items/1`.
  #
  # End-to-end proof that the dispatch path really produces these shapes
  # lives in `meeting_action_items_dispatch_test.exs`.
  describe "handle_output/3 — freeform STRING output (the production shape)" do
    defp post_and_read(string, space, transcript) do
      assert :ok =
               MeetingActionItems.handle_output(
                 responsibility(),
                 string,
                 trigger_meta(transcript)
               )

      action_item_messages(space.id)
    end

    test "rule 1: a JSON object carrying the contract shape decodes to its items" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      # Byte-for-byte the live e2e response (server3.log:1392).
      assert [message] =
               post_and_read(
                 ~s({"action_items": ["Ship the adapter fix", "Email Rowan the audit"]}),
                 space,
                 transcript
               )

      assert message.content =~ "- [ ] Ship the adapter fix"
      assert message.content =~ "- [ ] Email Rowan the audit"
    end

    test "rule 1: a bare JSON array decodes too" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      assert [message] = post_and_read(~s(["Book the review", "Send the doc"]), space, transcript)
      assert message.content =~ "- [ ] Book the review"
      assert message.content =~ "- [ ] Send the doc"
    end

    test "rule 1: JSON with the wrong key falls through to the prose splitter" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      # Not the contract — so it is prose, and prose with no marker keeps
      # every non-blank line. One line in, one item out.
      assert [message] = post_and_read(~s({"items": ["nope"]}), space, transcript)
      assert message.content =~ ~s(- [ ] {"items": ["nope"]})
    end

    test "rule 2a: when ANY line is marked, ONLY marked lines survive" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      assert [message] =
               post_and_read(
                 """
                 Here are the action items from the meeting:

                 - Revert the onboarding flow
                 * Email the deploy audit
                 3. Book the compliance sign-off

                 Let me know if I missed anything.
                 """,
                 space,
                 transcript
               )

      assert message.content =~ "- [ ] Revert the onboarding flow"
      assert message.content =~ "- [ ] Email the deploy audit"
      assert message.content =~ "- [ ] Book the compliance sign-off"

      # The preamble and the sign-off are NOT action items.
      refute message.content =~ "Here are the action items"
      refute message.content =~ "Let me know if I missed anything"
    end

    test "rule 2b: with no marked line, every non-blank line is an item" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      assert [message] =
               post_and_read(
                 "Revert the onboarding flow\n\n   \nEmail the deploy audit\n",
                 space,
                 transcript
               )

      assert message.content =~ "- [ ] Revert the onboarding flow"
      assert message.content =~ "- [ ] Email the deploy audit"
      refute message.content =~ "- [ ] \n"
    end

    test "rule 3: the marker is stripped once, so an inner hyphen survives" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      assert [message] = post_and_read("- see - the tradeoff doc", space, transcript)
      assert message.content =~ "- [ ] see - the tradeoff doc"
    end

    test "a blank or whitespace-only string posts nothing and returns :ok" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      assert post_and_read("   \n\n \n", space, transcript) == []
      assert post_and_read("", space, transcript) == []
    end

    test "an empty contract array posts nothing — 'no action items' is legitimate" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      assert post_and_read(~s({"action_items": []}), space, transcript) == []
    end

    test "decoded non-string entries are filtered, the string ones still land" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})

      assert [message] =
               post_and_read(~s({"action_items": ["Real item", 42, null]}), space, transcript)

      # Assert on the checklist lines, NOT on the whole body: the body
      # carries a `/api/transcripts/<uuid>/download` link and a random
      # UUID can contain any digit pair, which made an earlier
      # `refute content =~ "42"` fail roughly one seed in five.
      assert ["- [ ] Real item"] =
               message.content
               |> String.split("\n")
               |> Enum.filter(&String.starts_with?(&1, "- [ ] "))
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
