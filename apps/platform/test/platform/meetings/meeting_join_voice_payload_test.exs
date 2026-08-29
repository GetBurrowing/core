defmodule Platform.Meetings.MeetingJoinVoicePayloadTest do
  @moduledoc """
  Task 01a03f4f — the claim that an agent's voice actually REACHES its runtime.

  ## Why this file exists separately from `Platform.Agents.VoiceTest`

  Storing a voice id proves nothing. The failure this feature is exposed to is
  exactly the one task 01a04f31 fixed next door: a value written, a broadcast
  logged, and nobody on the other end. `persona` shipped in this payload for
  months with no producer and no reader, which is that failure in its passive
  form.

  So the assertions here use `assert_push`, driving a REAL runtime through
  `PlatformWeb.RuntimeSocket.connect/3` and `subscribe_and_join/3`, the same
  discipline as `MeetingJoinDispatchTopicTest`. `Endpoint.subscribe/1` is
  deliberately never called: a test process can subscribe to any PubSub topic,
  so it can confirm a broadcast happened and never discover the frame was
  unreachable.

  ## The mutants these tests name

  * Delete `voice: Voice.config_for(agent)` from the payload in
    `Meetings.dispatch_meeting_join/3` → "carries the agent's stored voice
    selection" fails on the missing key.
  * Revert `persona:` to `Map.get(context, :persona)` (its state before this
    task, i.e. remove the producer) → "persona is produced from VOICE.md"
    fails with `persona == nil`.
  * Swap the `||` so `context[:persona]` no longer wins → "an explicit
    context persona overrides" fails.

  `async: false` — LiveKit config lives in app env and `RuntimeChannel.join/3`
  writes through the shared sandbox from a separate process.
  """
  use PlatformWeb.ChannelCase, async: false

  alias Platform.Agents.{Agent, MemoryContext, Voice}
  alias Platform.Accounts.User
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Repo

  @room_name "meeting-voice-payload-test"

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "meeting-voice-#{n}@example.com",
      name: "Meeting Voice #{n}",
      oidc_sub: "oidc-meeting-voice-#{n}"
    })
  end

  # An agent with a live, activated, LINKED runtime — the only kind a real
  # websocket client can be connected for.
  defp agent_with_runtime!(agent_attrs \\ %{}) do
    owner = user!()
    n = System.unique_integer([:positive])

    agent =
      %Agent{}
      |> Agent.changeset(
        Map.merge(
          %{slug: "voice-payload-agent-#{n}", name: "Voice Payload #{n}", status: "active"},
          agent_attrs
        )
      )
      |> Repo.insert!()

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "voice-payload-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    %{agent: agent, runtime: Federation.get_runtime(activated.id), raw_token: raw_token}
  end

  defp joined_runtime_client!(%{runtime: runtime, raw_token: raw_token}) do
    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => raw_token
      })

    {:ok, _reply, _channel} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})
    :ok
  end

  setup do
    original = Application.get_env(:platform, :livekit)

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    :ok
  end

  # ── The voice half of the payload ────────────────────────────────────────

  describe "the meeting_join frame a runtime actually receives" do
    test "carries the agent's stored voice selection" do
      ctx =
        agent_with_runtime!(%{
          voice_config: %{
            "provider" => "elevenlabs",
            "voice_id" => "21m00Tcm4TlvDq8ikWAM",
            "model" => "eleven_turbo_v2_5"
          }
        })

      :ok = joined_runtime_client!(ctx)

      assert :ok = Meetings.dispatch_meeting_join(ctx.agent, @room_name, %{})

      assert_push "meeting_join", payload, 1_000

      assert payload.voice == %{
               "provider" => "elevenlabs",
               "voice_id" => "21m00Tcm4TlvDq8ikWAM",
               "model" => "eleven_turbo_v2_5"
             }

      # Positive control on the same frame: the fields that shipped before
      # this task are still there, so a failure above is about `voice` and
      # not about the dispatch, the token, or the topic.
      assert payload.agent_identity == "agent:" <> ctx.agent.slug
      assert payload.room_name == @room_name
    end

    test "carries voice: nil — not %{} — for an agent with no voice configured" do
      ctx = agent_with_runtime!()
      :ok = joined_runtime_client!(ctx)

      assert :ok = Meetings.dispatch_meeting_join(ctx.agent, @room_name, %{})
      assert_push "meeting_join", payload, 1_000

      # A worker reads nil as "this agent stays muted". `%{}` would be
      # ambiguous with a half-written selection.
      assert payload.voice == nil
      assert Map.has_key?(payload, :voice)
    end

    test "the provider is a value in the payload, so a second vendor needs no core change" do
      ctx =
        agent_with_runtime!(%{
          voice_config: %{"provider" => "openai", "voice_id" => "alloy"}
        })

      :ok = joined_runtime_client!(ctx)
      assert :ok = Meetings.dispatch_meeting_join(ctx.agent, @room_name, %{})
      assert_push "meeting_join", payload, 1_000

      # The identical code path carried "elevenlabs" in the test above.
      assert payload.voice["provider"] == "openai"
      assert payload.voice["voice_id"] == "alloy"
      refute Map.has_key?(payload.voice, "model")
    end
  end

  # ── persona: the key that had no producer ────────────────────────────────

  describe "persona" do
    test "is produced from the agent's VOICE.md" do
      ctx = agent_with_runtime!()

      {:ok, _file} =
        MemoryContext.upsert_workspace_file(
          ctx.agent.id,
          Voice.personality_file_key(),
          "Blunt. Answer first. One sentence unless asked."
        )

      :ok = joined_runtime_client!(ctx)

      assert :ok = Meetings.dispatch_meeting_join(ctx.agent, @room_name, %{})
      assert_push "meeting_join", payload, 1_000

      assert payload.persona == "Blunt. Answer first. One sentence unless asked."
    end

    test "is nil when the agent has no VOICE.md, rather than an empty string" do
      ctx = agent_with_runtime!()
      :ok = joined_runtime_client!(ctx)

      assert :ok = Meetings.dispatch_meeting_join(ctx.agent, @room_name, %{})
      assert_push "meeting_join", payload, 1_000

      assert payload.persona == nil
    end

    test "an explicit context persona overrides the stored file" do
      ctx = agent_with_runtime!()

      {:ok, _file} =
        MemoryContext.upsert_workspace_file(
          ctx.agent.id,
          Voice.personality_file_key(),
          "the stored register"
        )

      :ok = joined_runtime_client!(ctx)

      assert :ok =
               Meetings.dispatch_meeting_join(ctx.agent, @room_name, %{
                 persona: "the caller's override"
               })

      assert_push "meeting_join", payload, 1_000

      assert payload.persona == "the caller's override"
    end
  end
end
