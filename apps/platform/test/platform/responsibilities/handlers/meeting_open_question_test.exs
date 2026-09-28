defmodule Platform.Responsibilities.Handlers.MeetingOpenQuestionTest do
  @moduledoc """
  The candid-register floor on `meetings.open_question` (task `01a0e58f`,
  acceptance 2 and 3), and the `handle_refusal/3` that closes the queue
  row a gather refusal leaves behind.

  Without `handle_refusal/3` a refusal here would leave the row
  `:dispatched`, pinning the meeting's serial cursor until the 90-second
  claim watchdog. Mutation M-p4 (remove `handle_refusal/3` from
  `MeetingOpenQuestion`) is what the row-closing test in the open-question
  copy of this file exists to kill.

  Rows are synthesised; names are invented; the shape was filed from the
  2026-09-14 one-to-one.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Meetings
  alias Platform.Meetings.IntentQueue
  alias Platform.Responsibilities.Handlers.MeetingOpenQuestion
  alias Platform.Responsibilities.Responsibility

  @priya "Priya to deliver list of demands to Marcus by end of week"

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: MeetingOpenQuestion.key(),
      feature: "meetings",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => "meeting:open_question_intent"},
      scope: "per_meeting",
      enabled: true
    }
  end

  defp create_meeting! do
    {:ok, project} =
      Platform.Tasks.create_project(%{name: "Candid #{System.unique_integer([:positive])}"})

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "One to one #{System.unique_integer([:positive])}"
      })

    meeting
  end

  defp meta(meeting, overrides) do
    payload =
      Map.merge(
        %{
          intent_id: Platform.Types.UUIDv7.generate(),
          meeting_id: meeting.id,
          chunk_excerpt: "",
          classified_intent: "open_question",
          confidence: 0.9,
          speaker: nil
        },
        overrides
      )

    %{kind: :event_topic, topic: "meeting:open_question_intent", payload: payload}
  end

  describe "gather_context/2 — the candid-register floor" do
    test "a candid-register excerpt is refused" do
      assert {:error, :candid_register} =
               MeetingOpenQuestion.gather_context(
                 responsibility(),
                 meta(create_meeting!(), %{chunk_excerpt: @priya})
               )
    end

    test "the same excerpt at confidence 1.0 is still refused" do
      assert {:error, :candid_register} =
               MeetingOpenQuestion.gather_context(
                 responsibility(),
                 meta(create_meeting!(), %{chunk_excerpt: @priya, confidence: 1.0})
               )
    end

    # Anti-vacuity: an ordinary line gathers as before.
    test "an ordinary excerpt gathers context" do
      assert {:ok, ctx} =
               MeetingOpenQuestion.gather_context(
                 responsibility(),
                 meta(create_meeting!(), %{
                   chunk_excerpt: "Dana to send the sprint notes to the team by Friday"
                 })
               )

      assert ctx.meeting_intent.chunk_excerpt ==
               "Dana to send the sprint notes to the team by Friday"
    end

    # A blank excerpt passes the floor untouched, so `build_prompt/1`'s
    # own `:no_intent_text` refusal still owns it.
    test "a blank excerpt passes through to build_prompt's refusal" do
      assert {:ok, ctx} =
               MeetingOpenQuestion.gather_context(responsibility(), meta(create_meeting!(), %{}))

      assert {:error, :no_intent_text} = MeetingOpenQuestion.build_prompt(ctx)
    end
  end

  defp create_canvas!(space_id, title) do
    {:ok, participant} = Platform.Orchestration.ExecutionSpace.ensure_system_participant(space_id)

    {:ok, canvas} =
      Platform.Chat.create_canvas(%{
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

  # ── NEAR-MISS WITHOUT A CANVAS (task 01a0e58f, acceptance 4) ──────────
  #
  # A near-miss (see `IntentContext.near_miss/1`) dispatched into a space
  # with NO canvas yet would have the recipient create one for a line that
  # adds no item. Refused at gather, in code. Rows are synthesised; names
  # are invented; the shape was filed from the 2026-09-14 one-to-one.
  describe "gather_context/2 — a near-miss with no canvas" do
    @near_miss "My contention is we log an action item for the retro"

    defp room_with!(names) do
      {:ok, space} = Platform.Chat.create_space(%{kind: "execution"})

      room =
        %Platform.Meetings.Room{}
        |> Platform.Meetings.Room.changeset(%{
          space_id: space.id,
          livekit_room_name: "space:#{space.id}"
        })
        |> Platform.Repo.insert!()

      for name <- names do
        %Platform.Meetings.Participant{}
        |> Platform.Meetings.Participant.changeset(%{
          room_id: room.id,
          display_name: name,
          joined_at: DateTime.utc_now()
        })
        |> Platform.Repo.insert!()
      end

      room
    end

    # M-n3 would not show here (gather is called directly); the Router
    # test in `intent_privacy_dispatch_test.exs` carries that one.
    test "a speech-act near-miss in an empty space is refused" do
      meeting = create_meeting!()

      assert {:error, :near_miss_without_canvas} =
               MeetingOpenQuestion.gather_context(
                 responsibility(),
                 meta(meeting, %{chunk_excerpt: @near_miss})
               )
    end

    # M-n1 (drop the `missing?` condition) kills this.
    test "the same near-miss in a space that already holds a canvas dispatches" do
      meeting = create_meeting!()
      _canvas = create_canvas!(meeting.chat_space_id, "Notes")

      assert {:ok, ctx} =
               MeetingOpenQuestion.gather_context(
                 responsibility(),
                 meta(meeting, %{chunk_excerpt: @near_miss})
               )

      assert ctx.dispatch_space_id == meeting.chat_space_id
    end

    # FIRST-REAL-BRIEF control. M-n2 (near_miss always answers
    # `{:near_miss, _}`) kills this: a clean line in an empty space is the
    # first real open question, and must dispatch exactly as before.
    test "FIRST REAL OPEN QUESTION: a clean line in an empty space dispatches" do
      meeting = create_meeting!()

      assert {:ok, ctx} =
               MeetingOpenQuestion.gather_context(
                 responsibility(),
                 meta(meeting, %{chunk_excerpt: "Open question: who owns the migration runbook?"})
               )

      assert ctx.meeting_canvases.missing?
      assert ctx.dispatch_space_id == meeting.chat_space_id
    end

    test "an absent-addressee near-miss in an empty space is refused" do
      meeting = create_meeting!()
      room = room_with!(["Priya", "Dana"])

      assert {:error, :near_miss_without_canvas} =
               MeetingOpenQuestion.gather_context(
                 responsibility(),
                 meta(meeting, %{
                   chunk_excerpt: "Tobias, can you send the deck over by Friday?",
                   room_id: room.id
                 })
               )
    end

    # Anti-vacuity for the addressee half: with the addressee IN the room
    # the same line is not a near-miss.
    test "the same line with the addressee in the room dispatches" do
      meeting = create_meeting!()
      room = room_with!(["Priya", "Tobias"])

      assert {:ok, _ctx} =
               MeetingOpenQuestion.gather_context(
                 responsibility(),
                 meta(meeting, %{
                   chunk_excerpt: "Tobias, can you send the deck over by Friday?",
                   room_id: room.id
                 })
               )
    end
  end

  describe "handle_refusal/3 — closing the row a refusal leaves behind" do
    test "a gather refusal lands the row :dispatch_failed with the inner reason" do
      meeting = create_meeting!()

      {:ok, row} =
        IntentQueue.enqueue(meeting.id, %{
          room_id: "room-#{System.unique_integer([:positive])}",
          chunk_excerpt: @priya,
          classified_intent: "open_question",
          confidence: 0.9
        })

      {:ok, _} = IntentQueue.transition(meeting.id, row.id, :dispatched)
      on_exit(fn -> IntentQueue.stop(meeting.id) end)

      log =
        capture_log(fn ->
          assert :ok =
                   MeetingOpenQuestion.handle_refusal(
                     responsibility(),
                     {:context_gather_refused, :candid_register},
                     meta(meeting, %{intent_id: row.id, chunk_excerpt: @priya})
                   )
        end)

      {:ok, closed} = IntentQueue.get(meeting.id, row.id)
      assert closed.status == :dispatch_failed
      assert closed.dispatch_failure_reason == :candid_register
      assert IntentQueue.cursor(meeting.id) == nil

      refute log =~ "Priya"
      refute log =~ "demands"
    end
  end
end
