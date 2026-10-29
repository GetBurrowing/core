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
              "speaker_name" => "Sam",
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
      summary_input_hash: Platform.Meetings.Transcript.summary_fingerprint(transcript),
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
    test "captured context fingerprint fences a stale responsibility callback" do
      transcript = create_transcript!(%{status: "processing", space_id: nil})

      {:ok, %{meeting_transcript: context}} =
        Platform.Responsibilities.ContextProviders.gather_context(:meeting_transcript,
          transcript_id: transcript.id
        )

      assert context.summary_input_hash ==
               Platform.Meetings.Transcript.summary_fingerprint(transcript)

      old_meta =
        trigger_meta(transcript) |> Map.put(:summary_input_hash, context.summary_input_hash)

      {:ok, changed} =
        Meetings.append_segment(transcript.id, %{"text" => "New material", "start_time" => 2})

      {:ok, _} =
        Meetings.complete_transcript(
          transcript.id,
          "New summary",
          Platform.Meetings.Transcript.summary_fingerprint(changed)
        )

      assert {:error, {:complete_failed, :stale_summary}} =
               MeetingSummarize.handle_output(responsibility(), "Old summary", old_meta)

      assert Meetings.get_transcript(transcript.id).summary == "New summary"
      assert Meetings.get_transcript(transcript.id).status == "complete"
    end

    test "happy path persists summary and posts to space" do
      space = create_space!()
      transcript = create_transcript!(%{space_id: space.id})
      _ = ExecutionSpace.ensure_system_participant(space.id)

      assert :ok =
               MeetingSummarize.handle_output(
                 responsibility(),
                 "## Overview\nWe shipped X.\n## Action Items\n- Sam: follow up",
                 trigger_meta(transcript)
               )

      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == "complete"
      assert reloaded.summary =~ "We shipped X."
      assert reloaded.completed_at
      assert Platform.Meetings.Transcript.summary_current?(reloaded)

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
        meeting_transcript: %{formatted_text: "[00:00:00] Sam: Hello"}
      }

      [system_msg, user_msg] = MeetingSummarize.build_messages(context)

      assert system_msg.role == "system"
      assert system_msg.content =~ "Acme Robotics ships **autonomous fryers**"
      assert system_msg.content =~ "## Grounding context"
      assert system_msg.content =~ "### Org identity"

      assert user_msg.role == "user"
      assert user_msg.content =~ "[00:00:00] Sam: Hello"
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

  # ── task 019f2570 stage 2 — max_tokens hint on register/0 (bug 2) ──────
  describe "register/0" do
    test "carries metadata['max_tokens'] = 2500 so Dispatcher sends it verbatim" do
      [attrs] = MeetingSummarize.register()

      assert Map.get(attrs.metadata, "max_tokens") == 2500,
             "meetings.summarize must declare a max_tokens override so the OpenAI-" <>
               "compat concierge doesn't apply its own ~800-token default and truncate " <>
               "summaries mid-sentence (task 019f2570 bug 2)."
    end
  end

  # ── task 019f2570 stage 1 — build_prompt/1 callback ─────────────────────
  describe "build_prompt/1 (task 019f2570 bug 1 fix)" do
    test "returns {:ok, %{system, user}} carrying the transcript verbatim" do
      context = %{
        org_identity: %{content: "", missing?: true, version: nil},
        recent_journal: %{entries_by_date: [], total: 0, days: 7},
        meeting_transcript: %{
          formatted_text: "[00:00:00] Sam: We shipped X.\n[00:00:10] Alex: Great."
        }
      }

      assert {:ok, %{system: system, user: user}} = MeetingSummarize.build_prompt(context)

      # System prompt carries the canonical body (SummaryPrompt.system_prompt()).
      assert system =~ "Overview"
      assert system =~ "Action Items"

      # User prompt carries the transcript verbatim — Hermione will
      # actually see the segments, not the "meetings.summarize.v1"
      # slug the pre-019f2570 dispatcher shipped as literal text.
      assert user =~ "Please summarize the following meeting transcript:"
      assert user =~ "[00:00:00] Sam: We shipped X."
      assert user =~ "[00:00:10] Alex: Great."
    end

    test "returns {:error, :no_transcript_text} when transcript slot is empty" do
      context = %{
        org_identity: %{content: "", missing?: true, version: nil},
        recent_journal: %{entries_by_date: [], total: 0, days: 7},
        meeting_transcript: %{formatted_text: ""}
      }

      assert {:error, :no_transcript_text} = MeetingSummarize.build_prompt(context)
    end

    test "returns {:error, :no_transcript_text} when transcript slot is whitespace-only" do
      context = %{meeting_transcript: %{formatted_text: "  \n\t  "}}
      assert {:error, :no_transcript_text} = MeetingSummarize.build_prompt(context)
    end

    test "returns {:error, :no_transcript_text} when meeting_transcript key is absent" do
      assert {:error, :no_transcript_text} = MeetingSummarize.build_prompt(%{})
    end

    test "system prompt still carries grounding when ORG_IDENTITY + journal present" do
      identity_body = "# Org Identity\n\nAcme Robotics ships **autonomous fryers**."

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
        meeting_transcript: %{formatted_text: "[00:00:00] Sam: Hello"}
      }

      assert {:ok, %{system: system}} = MeetingSummarize.build_prompt(context)
      assert system =~ "## Grounding context"
      assert system =~ "Acme Robotics ships **autonomous fryers**"
    end
  end

  # ── task 019f2566 stage 3 — agent-kind preamble templating ──────────────
  describe "system_prompt_with_grounding/1 — agent-kind preamble (task 019f2566)" do
    test ":fed_conversational prepends the subagent-handoff preamble" do
      system = MeetingSummarize.system_prompt_with_grounding(%{agent_kind: :fed_conversational})

      assert system =~ "conversational Claude runtime"
      assert system =~ "Task tool"
      assert system =~ "subagent"

      # Preamble sits ABOVE the canonical body — the base prompt
      # follows once we get past the preamble.
      preamble_idx = :binary.match(system, "conversational Claude runtime") |> elem(0)
      base_idx = :binary.match(system, "Overview") |> elem(0)
      assert preamble_idx < base_idx, "preamble must precede the canonical summary body"
    end

    test ":ext_single_responsibility gets NO preamble (Hermione shape)" do
      system =
        MeetingSummarize.system_prompt_with_grounding(%{agent_kind: :ext_single_responsibility})

      refute system =~ "conversational Claude runtime"
      refute system =~ "Task tool"
      assert system =~ "Overview"
    end

    test ":loc_built_in gets NO preamble" do
      system = MeetingSummarize.system_prompt_with_grounding(%{agent_kind: :loc_built_in})

      refute system =~ "conversational Claude runtime"
      assert system =~ "Overview"
    end

    test "missing agent_kind gets NO preamble (backward-compat with pre-stage-3 callers)" do
      system = MeetingSummarize.system_prompt_with_grounding(%{})

      refute system =~ "conversational Claude runtime"
      assert system =~ "Overview"
    end
  end

  describe "build_messages/1 — agent-kind preamble (task 019f2566)" do
    test ":fed_conversational carries the preamble into the system message" do
      [system_msg, _user_msg] =
        MeetingSummarize.build_messages(%{
          agent_kind: :fed_conversational,
          meeting_transcript: %{formatted_text: "[00:00:00] Sam: Hi"}
        })

      assert system_msg.role == "system"
      assert system_msg.content =~ "conversational Claude runtime"
      assert system_msg.content =~ "subagent"
    end

    test ":ext_single_responsibility does NOT carry the preamble" do
      [system_msg, _user_msg] =
        MeetingSummarize.build_messages(%{
          agent_kind: :ext_single_responsibility,
          meeting_transcript: %{formatted_text: "[00:00:00] Sam: Hi"}
        })

      refute system_msg.content =~ "conversational Claude runtime"
    end

    test "preamble stacks CORRECTLY with grounding — order is preamble → base → grounding" do
      identity_body = "# Org Identity\n\nAcme Robotics is the identity."

      {:ok, _file} =
        OrgContext.upsert_file(%{
          file_key: "ORG_IDENTITY.md",
          content: identity_body
        })

      {:ok, %{org_identity: identity}} =
        Platform.Responsibilities.ContextProviders.gather_context(:org_identity, [])

      context = %{
        agent_kind: :fed_conversational,
        org_identity: identity,
        recent_journal: %{entries_by_date: [], total: 0, days: 7},
        meeting_transcript: %{formatted_text: "[00:00:00] Sam: Hi"}
      }

      [system_msg, _] = MeetingSummarize.build_messages(context)

      preamble_idx = :binary.match(system_msg.content, "conversational Claude runtime") |> elem(0)
      base_idx = :binary.match(system_msg.content, "Overview") |> elem(0)
      grounding_idx = :binary.match(system_msg.content, "## Grounding context") |> elem(0)

      assert preamble_idx < base_idx
      assert base_idx < grounding_idx
    end
  end

  describe "gather_context/2 — passthrough of :agent_kind (task 019f2566)" do
    test "propagates trigger :agent_kind into the returned context map" do
      {:ok, ctx} =
        MeetingSummarize.gather_context(responsibility(), %{
          payload: %{transcript_id: nil},
          agent_kind: :fed_conversational
        })

      assert ctx.agent_kind == :fed_conversational
    end

    test "returned :agent_kind is nil when trigger meta omits it (dispatcher will backfill)" do
      {:ok, ctx} =
        MeetingSummarize.gather_context(responsibility(), %{payload: %{transcript_id: nil}})

      assert Map.get(ctx, :agent_kind) == nil
    end
  end
end
