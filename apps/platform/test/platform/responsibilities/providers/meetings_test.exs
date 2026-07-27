defmodule Platform.Responsibilities.Providers.MeetingsTest do
  @moduledoc """
  Tests for the M8 stage 6 shim
  `Platform.Responsibilities.Providers.Meetings` — the seam that lets
  the M6 Router's `provider_module_for("meetings")` lookup resolve the
  meeting-summary handler. Without this shim, router-fired
  `meetings.summarize` dispatches log "no output handler" and the
  legacy bridge does the work alone.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Responsibilities.Handlers
  alias Platform.Responsibilities.Handlers.IntentClassify
  alias Platform.Responsibilities.Handlers.MeetingActionItems
  alias Platform.Responsibilities.Handlers.MeetingAttendanceFollowup
  alias Platform.Responsibilities.Handlers.MeetingSummarize
  alias Platform.Responsibilities.Providers.Meetings, as: MeetingsProvider
  alias Platform.Responsibilities.Responsibility

  defp unique_id, do: Platform.Types.UUIDv7.generate()

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: MeetingSummarize.key(),
      feature: "meetings",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => "meeting:finished"},
      scope: "per_meeting",
      context_provided: ["org_identity", "recent_journal", "meeting_transcript"],
      enabled: true
    }
  end

  defp intent_classify_responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: IntentClassify.key(),
      feature: "meetings",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => "meeting:transcript_chunk"},
      scope: "per_meeting",
      context_provided: ["meeting_transcript_chunk"],
      enabled: true
    }
  end

  defp create_space! do
    {:ok, space} = Chat.create_space(%{kind: "execution"})
    space
  end

  defp create_transcript!(space_id) do
    {:ok, t} =
      Meetings.create_transcript(%{
        room_id: unique_id(),
        space_id: space_id,
        segments: [
          %{
            "speaker_name" => "Hal",
            "text" => "We should ship the shim.",
            "start_time" => 0,
            "end_time" => 1000,
            "final" => true
          }
        ]
      })

    t
  end

  describe "register/0" do
    test "fans in every meetings handler's specs" do
      specs = MeetingsProvider.register()

      # Four responsibilities: summariser + intent-classify placeholder
      # (task 019f2451 stage 3) + action-items + attendance-followup
      # (task 019f2455 stage 3).
      assert length(specs) == 4

      keys = Enum.map(specs, & &1.key) |> Enum.sort()

      assert keys == [
               "meetings.action_items",
               "meetings.attendance_followup",
               "meetings.intent_classify",
               "meetings.summarize"
             ]

      # Each concrete spec is passed through verbatim — the shim doesn't
      # rewrite trigger config or output contract.
      assert MeetingSummarize.register() -- specs == []
      assert IntentClassify.register() -- specs == []
      assert MeetingActionItems.register() -- specs == []
      assert MeetingAttendanceFollowup.register() -- specs == []
    end

    test "still exposes meetings.summarize after per-key fan-out refactor (regression)" do
      # Guard against future fan-out refactors dropping the summariser
      # inadvertently. The Meeting Scribe MVP hinges on
      # `meetings.summarize` being present.
      specs = MeetingsProvider.register()
      assert Enum.any?(specs, fn s -> s.key == "meetings.summarize" end)
    end
  end

  describe "handler_for/1" do
    test "routes summarize responsibilities to MeetingSummarize" do
      assert MeetingsProvider.handler_for(responsibility()) == Handlers.MeetingSummarize
      assert MeetingsProvider.handler_for("meetings.summarize") == Handlers.MeetingSummarize
    end

    test "routes intent_classify responsibilities to IntentClassify" do
      assert MeetingsProvider.handler_for(intent_classify_responsibility()) ==
               Handlers.IntentClassify

      assert MeetingsProvider.handler_for("meetings.intent_classify") ==
               Handlers.IntentClassify
    end

    test "routes action_items to MeetingActionItems" do
      assert MeetingsProvider.handler_for("meetings.action_items") ==
               Handlers.MeetingActionItems
    end

    test "routes attendance_followup to MeetingAttendanceFollowup" do
      assert MeetingsProvider.handler_for("meetings.attendance_followup") ==
               Handlers.MeetingAttendanceFollowup
    end

    test "returns nil for unmapped keys" do
      assert MeetingsProvider.handler_for("meetings.something_new") == nil
      assert MeetingsProvider.handler_for("memory.daily_summary") == nil
      assert MeetingsProvider.handler_for(nil) == nil
    end
  end

  describe "handle_output/3" do
    test "delegates the canonical event_topic payload to the handler" do
      space = create_space!()
      transcript = create_transcript!(space.id)
      _ = ExecutionSpace.ensure_system_participant(space.id)

      trigger_meta = %{
        kind: :event_topic,
        topic: "meeting:finished",
        payload: %{
          transcript_id: transcript.id,
          room_id: transcript.room_id,
          space_id: space.id
        }
      }

      assert :ok =
               MeetingsProvider.handle_output(
                 responsibility(),
                 "## Overview\nWe shipped the shim.",
                 trigger_meta
               )

      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == "complete"
      assert reloaded.summary =~ "shipped the shim"
    end

    test "normalises a flat trigger_meta (transcript_id at top level) into :payload" do
      # This is the operator-from-iex shape: `Router.fire(:meetings_summarize,
      # %{transcript_id: id, space_id: sid})`. Without the shim's
      # normalize_meta the handler's accessors return nil for both
      # transcript_id and space_id and the dispatch errors out.
      #
      # NB the `:ok` asserted below is `handle_output/3`'s own contract
      # (`:ok | {:error, term}`), not the Router's. Since ADR-0046
      # prerequisite 1 (task 019f9b27) the enclosing `Router.fire/2` the
      # comment above describes answers
      # `{:ok, :dispatched} | {:ok, :unfilled} | {:ok, :unknown_responsibility}
      # | {:error, reason}` — never a flat `:ok`. This test drives the
      # provider callback directly, so it sees the callback shape.
      space = create_space!()
      transcript = create_transcript!(space.id)
      _ = ExecutionSpace.ensure_system_participant(space.id)

      flat_meta = %{
        kind: :cron,
        transcript_id: transcript.id,
        space_id: space.id
      }

      assert :ok =
               MeetingsProvider.handle_output(
                 responsibility(),
                 "Flat-meta dispatch summary.",
                 flat_meta
               )

      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == "complete"
      assert reloaded.summary =~ "Flat-meta dispatch summary"
    end

    test "rejects missing transcript_id with :missing_transcript_id" do
      assert {:error, :missing_transcript_id} =
               MeetingsProvider.handle_output(
                 responsibility(),
                 "no transcript id at all",
                 %{kind: :event_topic, payload: %{}}
               )
    end

    test "routes an intent_classify responsibility to the IntentClassify placeholder" do
      log =
        capture_log(fn ->
          assert :ok =
                   MeetingsProvider.handle_output(
                     intent_classify_responsibility(),
                     %{"intent" => "assign_task", "confidence" => 0.9},
                     %{kind: :event_topic, topic: "meeting:transcript_chunk"}
                   )
        end)

      # The placeholder log line is the smoke signal the runtime ticket
      # hasn't landed yet — it must fire on every dispatch until then.
      assert log =~ "[meetings.intent_classify]"
      assert log =~ "placeholder handler"
    end

    test "returns :unknown_meetings_responsibility for an unmapped key" do
      unknown = %Responsibility{
        id: Ecto.UUID.generate(),
        key: "meetings.foo",
        feature: "meetings",
        trigger_kind: "event_topic",
        trigger_config: %{},
        scope: "per_meeting",
        context_provided: [],
        enabled: true
      }

      log =
        capture_log(fn ->
          assert {:error, :unknown_meetings_responsibility} =
                   MeetingsProvider.handle_output(unknown, %{}, %{kind: :event_topic})
        end)

      assert log =~ "unknown responsibility key"
      assert log =~ "meetings.foo"
    end
  end

  describe "handle_output/2" do
    test "delegates the arity-2 form to the handler (defaults trigger_meta)" do
      # The handler rejects when no transcript_id is present, so arity-2
      # naturally returns :missing_transcript_id. We're proving the
      # shim doesn't crash on this code path and the same error
      # surfaces.
      assert {:error, :missing_transcript_id} =
               MeetingsProvider.handle_output(responsibility(), %{"summary" => "x"})
    end
  end

  # ── task 019f2570 stage 1 — build_prompt/1 delegation ───────────────────
  describe "build_prompt/1" do
    test "delegates to MeetingSummarize.build_prompt when the fired responsibility is summariser" do
      context = %{
        __responsibility__: responsibility(),
        org_identity: %{content: "", missing?: true, version: nil},
        recent_journal: %{entries_by_date: [], total: 0, days: 7},
        meeting_transcript: %{formatted_text: "[00:00:00] Hal: Hi"}
      }

      assert {:ok, %{system: system, user: user}} = MeetingsProvider.build_prompt(context)
      assert user =~ "[00:00:00] Hal: Hi"
      assert system =~ "Overview"
    end

    test "returns {:error, :no_transcript_text} for summariser + empty transcript" do
      context = %{
        __responsibility__: responsibility(),
        meeting_transcript: %{formatted_text: ""}
      }

      assert {:error, :no_transcript_text} = MeetingsProvider.build_prompt(context)
    end

    test "returns {:error, :no_build_prompt} for other keys (falls back to legacy template)" do
      context = %{__responsibility__: intent_classify_responsibility()}
      assert {:error, :no_build_prompt} = MeetingsProvider.build_prompt(context)
    end

    test "returns {:error, :no_build_prompt} when no responsibility hint present" do
      assert {:error, :no_build_prompt} = MeetingsProvider.build_prompt(%{})
    end
  end
end
