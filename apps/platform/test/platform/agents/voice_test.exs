defmodule Platform.Agents.VoiceTest do
  @moduledoc """
  Task 01a03f4f — the per-agent voice seam, storage half.

  These tests cover what an agent KNOWS about its voice. They deliberately do
  NOT prove that knowledge reaches anybody: asserting a field can be written
  is the vacuous version of this feature. The claim that it arrives at a
  runtime is made — over a real websocket — in
  `Platform.Meetings.MeetingJoinVoicePayloadTest`.
  """
  use Platform.DataCase, async: true

  alias Platform.Agents.{Agent, MemoryContext, Voice}
  alias Platform.Repo

  defp agent!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(
      Map.merge(
        %{slug: "voice-agent-#{n}", name: "Voice Agent #{n}", status: "active"},
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "known_providers/0" do
    test "names no vendor in the schema, and is the list the changeset enforces" do
      assert "elevenlabs" in Voice.known_providers()

      # The whole point of the ticket: ElevenLabs is one entry, not the seam.
      # A second provider must already be present or this is a one-vendor
      # design wearing a list.
      assert length(Voice.known_providers()) > 1
      assert "openai" in Voice.known_providers()
    end
  end

  describe "voice_config validation" do
    test "an agent with no voice is valid — the default state, not a degraded one" do
      agent = agent!()
      assert agent.voice_config == %{}
      assert Voice.config_for(agent) == nil
    end

    test "a complete selection is accepted and normalises" do
      agent =
        agent!(%{
          voice_config: %{
            "provider" => "elevenlabs",
            "voice_id" => "21m00Tcm4TlvDq8ikWAM",
            "model" => "eleven_turbo_v2_5"
          }
        })

      assert Voice.config_for(agent) == %{
               "provider" => "elevenlabs",
               "voice_id" => "21m00Tcm4TlvDq8ikWAM",
               "model" => "eleven_turbo_v2_5"
             }
    end

    test "an unknown provider is REJECTED rather than passed through to the worker" do
      changeset =
        Agent.changeset(%Agent{}, %{
          slug: "voice-bad-provider",
          name: "Bad Provider",
          status: "active",
          voice_config: %{"provider" => "definitely-not-a-tts-vendor", "voice_id" => "abc"}
        })

      refute changeset.valid?
      assert {message, _meta} = changeset.errors[:voice_config]
      assert message =~ "is not one of"

      # Positive control on the identical changeset: swapping ONLY the
      # provider for a known one makes it valid, so the rejection above is
      # about the provider value and not about the map, the slug, or the
      # required-fields guard.
      assert Agent.changeset(%Agent{}, %{
               slug: "voice-good-provider",
               name: "Good Provider",
               status: "active",
               voice_config: %{"provider" => "elevenlabs", "voice_id" => "abc"}
             }).valid?
    end

    test "a provider with no voice_id is REJECTED — the half-set state" do
      changeset =
        Agent.changeset(%Agent{}, %{
          slug: "voice-no-id",
          name: "No Id",
          status: "active",
          voice_config: %{"provider" => "elevenlabs"}
        })

      refute changeset.valid?
      assert {message, _meta} = changeset.errors[:voice_config]
      assert message =~ "voice_id is required"
    end

    test "a blank voice_id is not a voice_id" do
      changeset =
        Agent.changeset(%Agent{}, %{
          slug: "voice-blank-id",
          name: "Blank Id",
          status: "active",
          voice_config: %{"provider" => "elevenlabs", "voice_id" => "   "}
        })

      refute changeset.valid?
    end
  end

  describe "personality_for/1" do
    test "reads VOICE.md from the agent's existing workspace files" do
      agent = agent!()
      assert Voice.personality_for(agent) == nil

      {:ok, _file} =
        MemoryContext.upsert_workspace_file(
          agent.id,
          Voice.personality_file_key(),
          "  Dry. One sentence. Never two.  \n"
        )

      assert Voice.personality_for(agent) == "Dry. One sentence. Never two."
    end

    test "does NOT read SOUL.md — VOICE.md is a distinct, narrower register" do
      agent = agent!()

      {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "SOUL.md", "who I am everywhere")

      # If personality_for/1 fell back to SOUL.md, this would be non-nil and
      # every agent would silently start speaking its whole soul aloud.
      assert Voice.personality_for(agent) == nil
    end

    test "a blank VOICE.md cannot be written in the first place" do
      agent = agent!()

      # Discovered while writing this file, not assumed: WorkspaceFile's
      # existing `validate_required([:content])` already refuses whitespace,
      # so the "empty personality" row has no route through the supported
      # writer. Pinned here so a future relaxation of that validation shows
      # up as a failure in the voice suite rather than as a silently empty
      # persona in a live meeting.
      assert {:error, %Ecto.Changeset{} = changeset} =
               MemoryContext.upsert_workspace_file(
                 agent.id,
                 Voice.personality_file_key(),
                 "   \n\n "
               )

      assert {"can't be blank", _meta} = changeset.errors[:content]

      # Positive control: the identical call with real content succeeds, so
      # the refusal above is about the blank content and not about the key,
      # the agent, or the sandbox.
      assert {:ok, _} =
               MemoryContext.upsert_workspace_file(
                 agent.id,
                 Voice.personality_file_key(),
                 "terse"
               )
    end

    test "blank content resolves to nil, not an empty string" do
      # Defence in depth for the row the writer above cannot produce but a
      # direct SQL write or a future schema default could. An empty string in
      # the dispatch payload is a producer that produced nothing —
      # indistinguishable downstream from never having been wired at all.
      agent = agent!()

      Repo.insert!(%Platform.Agents.WorkspaceFile{
        agent_id: agent.id,
        file_key: Voice.personality_file_key(),
        content: "   \n ",
        version: 1
      })

      assert Voice.personality_for(agent) == nil
    end

    test "the file key is the one the Control Center editor can already create" do
      # No whitelist exists in MemoryContext.upsert_workspace_file/4 and the
      # Control Center form takes a free-text file_key, so VOICE.md is
      # settable today with no new UI. Asserted rather than assumed.
      agent = agent!()

      {:ok, file} =
        MemoryContext.upsert_workspace_file(agent.id, Voice.personality_file_key(), "terse")

      assert file.file_key == "VOICE.md"
      assert file.version == 1

      assert Enum.any?(
               MemoryContext.list_workspace_files(agent.id),
               &(&1.file_key == "VOICE.md")
             )
    end
  end

  describe "config_for/1 normalisation" do
    test "a half-written stored map resolves to nil rather than a partial selection" do
      # Defence in depth: the changeset refuses to WRITE this, but a row
      # predating the validation (or a direct SQL write) must not reach the
      # worker as a map missing the field it needs.
      assert Voice.config_for(%Agent{voice_config: %{"provider" => "elevenlabs"}}) == nil
      assert Voice.config_for(%Agent{voice_config: %{"voice_id" => "abc"}}) == nil
    end

    test "model is optional and omitted rather than sent as nil" do
      config =
        Voice.config_for(%Agent{voice_config: %{"provider" => "openai", "voice_id" => "x"}})

      assert config == %{"provider" => "openai", "voice_id" => "x"}
      refute Map.has_key?(config, "model")
    end
  end
end
