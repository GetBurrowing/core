defmodule Platform.Responsibilities.Handlers.MeetingSummarizeTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.MeetingSummarize` — the
  M8 stage 4 provider body. Covers:

    * `handle_output/3` happy path → `complete_transcript` + `post_summary_to_space`
    * `handle_output/3` failure path → `fail_transcript`
    * `build_messages/1` grounding payload (ORG_IDENTITY + recent journal
      land verbatim in the system prompt) — the M8 deliverable.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Responsibilities.Handlers.MeetingSummarize
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

  defp create_transcript!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          room_id: unique_id(),
          space_id: Map.get(overrides, :space_id) || unique_id(),
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

  # The post_summary_to_space helper expects a real chat space — create
  # one and use its id as the transcript's space_id. The space must
  # exist so ensure_system_participant/1 succeeds.
  defp create_space!(overrides \\ %{}) do
    # `execution` kind doesn't require name/slug, so it's the lowest-
    # ceremony choice for tests that only need a real `spaces` row to
    # back `post_summary_to_space/3`.
    attrs = Map.merge(%{kind: "execution"}, overrides)
    {:ok, space} = Chat.create_space(attrs)
    space
  end

  describe "handle_output/3" do
    test "happy path persists summary and posts to space" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})
      _ = ExecutionSpace.ensure_system_participant(space.id)

      assert :ok =
               MeetingSummarize.handle_output(
                 responsibility(),
                 "## Overview\nWe shipped X.\n## Action Items\n- Harper: follow up",
                 trigger_meta(transcript)
               )

      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == "complete"
      assert reloaded.summary =~ "We shipped X."
      assert reloaded.completed_at

      # post_summary_to_space inserts a system-kind chat message; assert
      # we can find one referencing the transcript by metadata.
      messages = Chat.list_messages(space.id) || []

      assert Enum.any?(messages, fn m ->
               m.metadata["transcript_id"] == transcript.id and
                 m.metadata["source"] == "meeting_summarizer"
             end)
    end

    test "accepts %{\"summary\" => string} map shape" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})
      _ = ExecutionSpace.ensure_system_participant(space.id)

      assert :ok =
               MeetingSummarize.handle_output(
                 responsibility(),
                 %{"summary" => "Map-shaped summary."},
                 trigger_meta(transcript)
               )

      assert Meetings.get_transcript(transcript.id).summary == "Map-shaped summary."
    end

    test "accepts atom-keyed %{summary: string} map shape" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})
      _ = ExecutionSpace.ensure_system_participant(space.id)

      assert :ok =
               MeetingSummarize.handle_output(
                 responsibility(),
                 %{summary: "Atom-keyed summary."},
                 trigger_meta(transcript)
               )

      assert Meetings.get_transcript(transcript.id).summary == "Atom-keyed summary."
    end

    test "missing transcript_id surfaces error without touching DB" do
      assert {:error, :missing_transcript_id} =
               MeetingSummarize.handle_output(
                 responsibility(),
                 "anything",
                 %{kind: :event_topic, topic: "meeting:finished", payload: %{}}
               )
    end

    test "invalid output shape fails the transcript" do
      transcript = create_transcript!()

      assert {:error, :invalid_output_shape} =
               MeetingSummarize.handle_output(
                 responsibility(),
                 %{not_a_summary: 123},
                 trigger_meta(transcript)
               )

      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == "failed"
    end

    test "empty string summary is rejected and fails the transcript" do
      transcript = create_transcript!()

      assert {:error, :invalid_output_shape} =
               MeetingSummarize.handle_output(
                 responsibility(),
                 %{"summary" => ""},
                 trigger_meta(transcript)
               )

      assert Meetings.get_transcript(transcript.id).status == "failed"
    end

    test "explicit {:error, reason} dispatch result fails the transcript" do
      transcript = create_transcript!()

      assert {:error, {:dispatch_failed, :llm_down}} =
               MeetingSummarize.handle_output(
                 responsibility(),
                 {:error, :llm_down},
                 trigger_meta(transcript)
               )

      assert Meetings.get_transcript(transcript.id).status == "failed"
    end

    test "nil space_id skips the chat post but still persists summary" do
      transcript = create_transcript!(%{space_id: nil})

      assert :ok =
               MeetingSummarize.handle_output(
                 responsibility(),
                 "Headless summary.",
                 trigger_meta(transcript)
               )

      assert Meetings.get_transcript(transcript.id).summary == "Headless summary."
    end
  end

  describe "build_messages/1 — grounding payoff" do
    test "system prompt contains verbatim ORG_IDENTITY content" do
      identity_body =
        "# Org Identity\n\nAcme Robotics ships **autonomous fryers** for QSR brands."

      {:ok, _file} =
        OrgContext.upsert_file(%{
          file_key: "ORG_IDENTITY.md",
          content: identity_body
        })

      {:ok, %{org_identity: identity}} =
        Platform.Responsibilities.ContextProviders.gather_context(:org_identity, [])

      context = %{
        org_identity: identity,
        recent_journal: %{entries_by_date: [], total: 0, days: 7},
        meeting_transcript: %{formatted_text: "[00:00:00] Harper: Hello"}
      }

      [system_msg, user_msg] = MeetingSummarize.build_messages(context)

      assert system_msg.role == "system"
      assert system_msg.content =~ "Acme Robotics ships **autonomous fryers**"
      assert system_msg.content =~ "## Grounding context"
      assert system_msg.content =~ "### Org identity"

      assert user_msg.role == "user"
      assert user_msg.content =~ "[00:00:00] Harper: Hello"
    end

    test "system prompt contains a journal date string when recent_journal has entries" do
      today = Date.utc_today()

      {:ok, _entry} =
        OrgContext.append_memory_entry(%{
          content: "Hal noticed an emerging pattern in the daily summaries.",
          date: today
        })

      {:ok, %{recent_journal: journal}} =
        Platform.Responsibilities.ContextProviders.gather_context(:recent_journal, [])

      context = %{
        org_identity: %{content: "", missing?: true, version: nil},
        recent_journal: journal,
        meeting_transcript: %{formatted_text: ""}
      }

      [system_msg, _user_msg] = MeetingSummarize.build_messages(context)

      assert system_msg.content =~ "### Recent journal"
      assert system_msg.content =~ Date.to_iso8601(today)
      assert system_msg.content =~ "Hal noticed an emerging pattern"
    end

    test "missing grounding slots still yield the canonical system prompt" do
      [system_msg, _user_msg] = MeetingSummarize.build_messages(%{})

      # Even with no context, the base SummaryPrompt body must land
      # so the LLM has its formatting instructions.
      assert system_msg.role == "system"
      assert system_msg.content =~ "Overview"
      assert system_msg.content =~ "Action Items"
      # No grounding section should be emitted when both slots are empty.
      refute system_msg.content =~ "## Grounding context"
    end
  end

  describe "system_prompt_with_grounding/1" do
    test "preserves the canonical body when context is empty" do
      assert MeetingSummarize.system_prompt_with_grounding(%{}) ==
               Platform.Meetings.SummaryPrompt.system_prompt()
    end
  end
end
