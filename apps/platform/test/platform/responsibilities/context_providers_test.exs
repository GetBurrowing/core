defmodule Platform.Responsibilities.ContextProvidersTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.ContextProviders` (ADR-0041 M8
  stage 1).

  Covers each slot's happy path, the missing-row fallbacks that prevent
  Hal's first nightly on a fresh org from crashing, the
  `:meeting_transcript` error tuple, and a round-trip that materialises
  all three slots into a single keyed map.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Meetings
  alias Platform.Meetings.SummaryPrompt
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Responsibilities.ContextProviders

  import Ecto.Query

  defp drop_org_identity_files do
    Repo.delete_all(
      from(p in WikiPage,
        where:
          p.file_key in [
            "ORG_IDENTITY.md",
            "org/identity.md",
            "org/page/identity.md"
          ]
      )
    )
  end

  defp post_message do
    slug = "ctxprov-#{System.unique_integer([:positive])}"

    {:ok, space} =
      Chat.create_space(%{name: "Ctx Prov #{slug}", slug: slug, kind: "channel"})

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Ctx Author",
        joined_at: DateTime.utc_now()
      })

    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: "context-provider test message"
      })

    message
  end

  defp sample_segments do
    [
      %{
        "participant_identity" => "user_1",
        "speaker_name" => "Harper",
        "text" => "Helios milestone is on track.",
        "start_time" => 0,
        "end_time" => 3000,
        "final" => true
      },
      %{
        "participant_identity" => "user_2",
        "speaker_name" => "Mira Chen",
        "text" => "Let's land the rollout this week.",
        "start_time" => 3500,
        "end_time" => 6000,
        "final" => true
      }
    ]
  end

  describe "gather_context/2 — :org_identity" do
    test "returns missing? true and empty content when ORG_IDENTITY.md isn't seeded" do
      # The test DB may have a seeded ORG_IDENTITY.md (or its path-style
      # alias `org/identity.md` / `org/page/identity.md`) — clear every
      # variant so the gather actually exercises the missing-file branch.
      drop_org_identity_files()

      assert {:ok, %{org_identity: payload}} = ContextProviders.gather_context(:org_identity, [])

      assert payload.missing? == true
      assert payload.content == ""
      assert payload.version == nil
    end

    test "returns the file body, version, and missing? false when seeded" do
      {:ok, page} =
        OrgContext.upsert_file(%{
          file_key: "ORG_IDENTITY.md",
          content: "# Mission\nBuild Helios.",
          updated_by: Ecto.UUID.generate()
        })

      assert {:ok, %{org_identity: payload}} = ContextProviders.gather_context(:org_identity, [])

      assert payload.missing? == false
      assert payload.content == "# Mission\nBuild Helios."
      assert payload.version == page.version
    end
  end

  describe "gather_context/2 — :recent_journal" do
    test "returns an empty entries_by_date list and total 0 on an empty wiki" do
      assert {:ok, %{recent_journal: payload}} =
               ContextProviders.gather_context(:recent_journal, [])

      assert payload.days == 7
      assert payload.entries_by_date == []
      assert payload.total == 0
    end

    test "groups entries by date and counts the total" do
      today = Date.utc_today()

      {:ok, _entry} =
        OrgContext.append_memory_entry(%{
          content: "Decision: ship Helios v1 by Friday.",
          date: today
        })

      assert {:ok, %{recent_journal: payload}} =
               ContextProviders.gather_context(:recent_journal, [])

      assert payload.total >= 1
      assert is_list(payload.entries_by_date)
    end

    test "honours the :workspace_id opt by filtering recent_memory accordingly" do
      ws_id = Ecto.UUID.generate()
      today = Date.utc_today()

      {:ok, _global_entry} =
        OrgContext.append_memory_entry(%{
          content: "Unscoped entry",
          date: today
        })

      {:ok, _scoped_entry} =
        OrgContext.append_memory_entry(%{
          content: "Workspace-scoped entry",
          date: today,
          workspace_id: ws_id
        })

      # Scoped query should ONLY surface the workspace-scoped entry
      assert {:ok, %{recent_journal: scoped}} =
               ContextProviders.gather_context(:recent_journal, workspace_id: ws_id)

      flattened = scoped.entries_by_date |> Enum.flat_map(fn {_d, entries} -> entries end)
      assert Enum.all?(flattened, fn entry -> entry.workspace_id == ws_id end)
      assert Enum.any?(flattened, fn entry -> entry.content == "Workspace-scoped entry" end)
    end

    test "accepts a map of opts as well as a keyword list" do
      assert {:ok, %{recent_journal: payload}} =
               ContextProviders.gather_context(:recent_journal, %{days: 3})

      assert payload.days == 3
    end
  end

  describe "gather_context/2 — :meeting_transcript" do
    test "returns {:error, :missing_transcript_id} when opts has no transcript_id" do
      assert {:error, :missing_transcript_id} =
               ContextProviders.gather_context(:meeting_transcript, [])
    end

    test "returns {:error, :not_found} for an unknown transcript_id" do
      assert {:error, :not_found} =
               ContextProviders.gather_context(:meeting_transcript,
                 transcript_id: Ecto.UUID.generate()
               )
    end

    test "loads a real transcript and returns formatted_text + counts" do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: Ecto.UUID.generate(),
          space_id: Ecto.UUID.generate(),
          segments: sample_segments()
        })

      assert {:ok, %{meeting_transcript: payload}} =
               ContextProviders.gather_context(:meeting_transcript,
                 transcript_id: transcript.id
               )

      assert payload.transcript_id == transcript.id
      assert payload.segment_count == 2
      assert payload.duration_ms == 6000
      # formatted_text must byte-for-byte match SummaryPrompt.format_segments/1
      # so handlers stay in sync with the canonical formatting.
      assert payload.formatted_text == SummaryPrompt.format_segments(sample_segments())
      assert payload.formatted_text =~ "Harper"
      assert payload.formatted_text =~ "Mira Chen"
    end

    test "handles a transcript with no segments without crashing" do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: Ecto.UUID.generate(),
          space_id: Ecto.UUID.generate(),
          segments: []
        })

      assert {:ok, %{meeting_transcript: payload}} =
               ContextProviders.gather_context(:meeting_transcript,
                 transcript_id: transcript.id
               )

      assert payload.segment_count == 0
      assert payload.duration_ms == 0
      assert payload.formatted_text == ""
    end
  end

  # Slots ported in from ContextGatherer when the two materialisers
  # collapsed onto this module. The batch adapter degrades every tuple
  # below to `nil`; these assert the reason it degrades from, which is
  # the whole point of the port.
  describe "gather_context/2 — :current_message" do
    test "returns {:error, :missing_message_id} when opts has no message_id" do
      assert {:error, :missing_message_id} =
               ContextProviders.gather_context(:current_message, [])
    end

    test "returns {:error, :invalid_message_id} for a non-binary id" do
      assert {:error, :invalid_message_id} =
               ContextProviders.gather_context(:current_message, message_id: 42)
    end

    test "returns {:error, :not_found} for an unknown message id" do
      assert {:error, :not_found} =
               ContextProviders.gather_context(:current_message,
                 message_id: Ecto.UUID.generate()
               )
    end

    test "loads a real message and returns it under :current_message" do
      message = post_message()

      assert {:ok, %{current_message: %Message{id: id}}} =
               ContextProviders.gather_context(:current_message, message_id: message.id)

      assert id == message.id
    end

    test "reads a string-keyed message_id out of a raw trigger_meta map" do
      message = post_message()

      assert {:ok, %{current_message: %Message{id: id}}} =
               ContextProviders.gather_context(:current_message, %{
                 "message_id" => message.id
               })

      assert id == message.id
    end

    test "an unconvertible sibling key does not blank the slot's real id" do
      # The router hands `trigger_meta` through verbatim and it routinely
      # carries string keys that were never atoms. Per-key coercion means
      # the junk key is dropped, not the whole opts list.
      message = post_message()

      bogus = "never_an_atom_#{System.unique_integer([:positive])}"

      assert {:ok, %{current_message: %Message{id: id}}} =
               ContextProviders.gather_context(:current_message, %{
                 "message_id" => message.id,
                 bogus => "junk"
               })

      assert id == message.id
    end
  end

  describe "gather_context/2 — :current_meeting" do
    test "returns {:error, :missing_meeting_id} when opts has no meeting_id" do
      assert {:error, :missing_meeting_id} =
               ContextProviders.gather_context(:current_meeting, [])
    end

    test "returns {:error, :not_found} for an unknown meeting id" do
      assert {:error, :not_found} =
               ContextProviders.gather_context(:current_meeting,
                 meeting_id: Ecto.UUID.generate()
               )
    end
  end

  describe "gather_context/2 — :trigger_payload" do
    test "echoes the payload straight through" do
      payload = %{"event" => "test", "value" => 42}

      assert {:ok, %{trigger_payload: ^payload}} =
               ContextProviders.gather_context(:trigger_payload, %{payload: payload})
    end

    test "tolerates a string-keyed payload" do
      payload = %{"hello" => "world"}

      assert {:ok, %{trigger_payload: ^payload}} =
               ContextProviders.gather_context(:trigger_payload, %{"payload" => payload})
    end

    test "returns {:error, :missing_payload} when the trigger carried none" do
      assert {:error, :missing_payload} =
               ContextProviders.gather_context(:trigger_payload, %{})
    end
  end

  describe "gather_context/2 — unknown slot" do
    test "returns {:error, {:unknown_slot, _}} for slots this module doesn't materialise" do
      assert {:error, {:unknown_slot, :not_a_real_slot}} =
               ContextProviders.gather_context(:not_a_real_slot, [])
    end
  end

  describe "round-trip — all three slots in sequence" do
    test "Hal's full context_provided list (org_identity + recent_journal) resolves cleanly" do
      {:ok, _page} =
        OrgContext.upsert_file(%{
          file_key: "ORG_IDENTITY.md",
          content: "# Helios HQ\nProject lead: Mira Chen.",
          updated_by: Ecto.UUID.generate()
        })

      {:ok, _entry} =
        OrgContext.append_memory_entry(%{
          content: "Stand-up: Helios sprint kickoff.",
          date: Date.utc_today()
        })

      gathered =
        [:org_identity, :recent_journal]
        |> Enum.reduce(%{}, fn slot, acc ->
          {:ok, payload} = ContextProviders.gather_context(slot, [])
          Map.merge(acc, payload)
        end)

      assert gathered.org_identity.content =~ "Helios HQ"
      assert gathered.org_identity.missing? == false
      assert gathered.recent_journal.total >= 1
    end

    test "meetings.summarize's full context_provided list resolves into one keyed map" do
      {:ok, _page} =
        OrgContext.upsert_file(%{
          file_key: "ORG_IDENTITY.md",
          content: "# Org\nCEO: Mira Chen.",
          updated_by: Ecto.UUID.generate()
        })

      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: Ecto.UUID.generate(),
          space_id: Ecto.UUID.generate(),
          segments: sample_segments()
        })

      slot_opts = %{
        org_identity: [],
        recent_journal: [],
        meeting_transcript: [transcript_id: transcript.id]
      }

      gathered =
        [:org_identity, :recent_journal, :meeting_transcript]
        |> Enum.reduce(%{}, fn slot, acc ->
          {:ok, payload} = ContextProviders.gather_context(slot, slot_opts[slot])
          Map.merge(acc, payload)
        end)

      # All three top-level keys land in the merged context map, keyed by
      # their symbolic name — exactly what M1's Router will hand to the
      # prompt-rendering step.
      assert Map.has_key?(gathered, :org_identity)
      assert Map.has_key?(gathered, :recent_journal)
      assert Map.has_key?(gathered, :meeting_transcript)

      assert gathered.org_identity.content =~ "Mira Chen"
      assert gathered.meeting_transcript.segment_count == 2
      assert gathered.meeting_transcript.formatted_text =~ "Helios milestone"
    end
  end
end
