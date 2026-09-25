defmodule Mix.Tasks.Platform.SeedMeetingVoiceAgentTest do
  @moduledoc """
  Task 01a0d4a0-6570 stage 2 — the Meeting Assistant persona and its voice
  runtime are provisioned entirely through already-shipped mechanisms
  (`Federation.register_voice_runtime/3`,
  `MemoryContext.upsert_workspace_file/4`, `agents.voice_config`,
  `agent_runtimes.allowed_bundles`), and re-running the seed does not
  duplicate either the agent row or its voice runtime row.

  `async: false`: `RuntimePresence` is one named process and the seeded
  agent's slug (`"meeting-assistant"`) is a fixed, shared identity across
  tests in this module.
  """
  use PlatformWeb.ChannelCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Mix.Tasks.Platform.SeedMeetingVoiceAgent
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation
  alias Platform.Federation.ToolAuthorization
  alias Platform.Meetings
  alias Platform.Repo

  defp owner! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "meeting-assistant-seed-#{n}@example.com",
      name: "Seed Owner #{n}",
      oidc_sub: "oidc-mva-seed-#{n}"
    })
  end

  # ── Idempotent seeding ─────────────────────────────────────────────────────

  describe "seed!/1" do
    test "creates exactly one agent row, and a second run does not duplicate it" do
      owner = owner!()

      assert {:ok, %{agent: agent_a}} = SeedMeetingVoiceAgent.seed!(owner)
      assert {:ok, %{agent: agent_b}} = SeedMeetingVoiceAgent.seed!(owner)

      assert agent_a.id == agent_b.id

      assert Repo.aggregate(
               from(a in Agent, where: a.slug == "meeting-assistant"),
               :count
             ) == 1
    end

    test "creates exactly one voice runtime row, and a second run reuses it" do
      owner = owner!()

      assert {:ok, %{agent: agent, runtime: runtime_a, raw_token: token_a}} =
               SeedMeetingVoiceAgent.seed!(owner)

      assert is_binary(token_a)

      assert {:ok, %{runtime: runtime_b, raw_token: token_b}} = SeedMeetingVoiceAgent.seed!(owner)

      assert runtime_a.id == runtime_b.id
      assert is_nil(token_b), "a reused row must not mint (or print) a second token"

      voice_rows =
        agent
        |> Repo.reload()
        |> Federation.voice_runtimes_for_agent()
        |> Enum.filter(&(&1.metadata["role"] == "voice"))

      assert length(voice_rows) == 1
    end

    test "the agent stays kind \"native\" with no external fields" do
      owner = owner!()
      assert {:ok, %{agent: agent}} = SeedMeetingVoiceAgent.seed!(owner)

      assert agent.kind == "native"
      assert is_nil(agent.base_url)
      assert is_nil(agent.endpoint_kind)
      assert is_nil(agent.model)
    end

    test "writes SOUL.md, IDENTITY.md, and VOICE.md" do
      owner = owner!()
      assert {:ok, %{agent: agent}} = SeedMeetingVoiceAgent.seed!(owner)

      files =
        Platform.Agents.MemoryContext.list_workspace_files(agent.id,
          keys: ~w(SOUL.md IDENTITY.md VOICE.md)
        )

      keys = Enum.map(files, & &1.file_key) |> Enum.sort()

      assert keys == ~w(IDENTITY.md SOUL.md VOICE.md)
      assert Enum.all?(files, &(String.trim(&1.content) != ""))
    end

    test "re-running does not duplicate workspace file rows and content stays stable" do
      owner = owner!()
      assert {:ok, %{agent: agent}} = SeedMeetingVoiceAgent.seed!(owner)
      first = Platform.Agents.MemoryContext.get_workspace_file(agent.id, "SOUL.md")

      assert {:ok, _} = SeedMeetingVoiceAgent.seed!(owner)
      second = Platform.Agents.MemoryContext.get_workspace_file(agent.id, "SOUL.md")

      assert second.content == first.content

      assert Repo.aggregate(
               from(f in Platform.Agents.WorkspaceFile,
                 where: f.agent_id == ^agent.id and f.file_key == "SOUL.md"
               ),
               :count
             ) == 1
    end

    test "sets voice_config informationally (provider/voice_id/model)" do
      owner = owner!()
      assert {:ok, %{agent: agent}} = SeedMeetingVoiceAgent.seed!(owner)

      assert agent.voice_config["provider"] in Platform.Agents.Voice.known_providers()
      assert is_binary(agent.voice_config["voice_id"])
    end

    test "declares meeting_voice in the runtime's client_info.features" do
      owner = owner!()
      assert {:ok, %{runtime: runtime}} = SeedMeetingVoiceAgent.seed!(owner)

      assert AgentRuntime.client_supports?(runtime, "meeting_voice")
    end

    test "declares the LiveKit Agent Dispatch agent_name (task 01a0d4a0)" do
      # This is the opt-in Platform.Meetings reads (`livekit_dispatch_agent_name/1`)
      # to route an invite through LiveKit's own Agent Dispatch API instead of
      # the RuntimeChannel presence check this Python worker can never satisfy.
      # It must match `services/meeting-voice-agent`'s own registered
      # `WorkerOptions(agent_name: ...)` — currently `config.py`'s
      # `MVA_WORKER_AGENT_NAME` default, `"meeting-voice-agent"`.
      owner = owner!()
      assert {:ok, %{runtime: runtime}} = SeedMeetingVoiceAgent.seed!(owner)

      assert runtime.metadata["client_info"]["livekit_agent_name"] == "meeting-voice-agent"
    end

    test "re-running preserves both client_info.features and livekit_agent_name" do
      # `Federation.update_metadata/2` replaces `"client_info"` wholesale, so
      # a seed that only re-applied `features` on rerun would silently drop
      # `livekit_agent_name` the second time. Pin that both survive a rerun.
      owner = owner!()
      assert {:ok, _} = SeedMeetingVoiceAgent.seed!(owner)
      assert {:ok, %{runtime: runtime}} = SeedMeetingVoiceAgent.seed!(owner)

      assert AgentRuntime.client_supports?(runtime, "meeting_voice")
      assert runtime.metadata["client_info"]["livekit_agent_name"] == "meeting-voice-agent"
    end
  end

  # ── allowed_bundles: scoped tool surface ────────────────────────────────────

  describe "the voice runtime's allowed_bundles" do
    test "denies task/plan/review tool calls and allows a messaging one" do
      owner = owner!()
      assert {:ok, %{runtime: runtime}} = SeedMeetingVoiceAgent.seed!(owner)

      assert MapSet.new(runtime.allowed_bundles) ==
               MapSet.new(~w(messaging context_read))

      refute "task" in runtime.allowed_bundles
      refute "plan" in runtime.allowed_bundles
      refute "review" in runtime.allowed_bundles

      assert {:error, :forbidden} = ToolAuthorization.authorize("task_create", runtime)
      assert {:error, :forbidden} = ToolAuthorization.authorize("plan_create", runtime)
      assert {:error, :forbidden} = ToolAuthorization.authorize("review_request_create", runtime)

      assert :ok = ToolAuthorization.authorize("send_media", runtime)
      assert "send_media" in ToolAuthorization.tool_names(runtime)
    end

    test "allows the read-only tool-call e2e case's space_get_context (task 01a0d4a0 stage 5)" do
      owner = owner!()
      assert {:ok, %{runtime: runtime}} = SeedMeetingVoiceAgent.seed!(owner)

      assert :ok = ToolAuthorization.authorize("space_get_context", runtime)
      assert "space_get_context" in ToolAuthorization.tool_names(runtime)
    end

    test "no longer grants space or memory (round 3 of Dalton's live moon run, task 01a0d4a0 stage 5)" do
      # Dalton's third live moon run against 2312d761 found the seeded row
      # still granting `memory_create`/`memory_delete`/`memory_rename`/
      # `memory_str_replace`, `space_create`, `space_leave`, and `dm_create`
      # — none of which a single-purpose meeting assistant has any business
      # calling. `space`/`memory` are dropped from `allowed_bundles`
      # entirely (see `mix platform.seed_meeting_voice_agent`'s moduledoc
      # for why neither can be narrowed any finer than an outright drop).
      owner = owner!()
      assert {:ok, %{runtime: runtime}} = SeedMeetingVoiceAgent.seed!(owner)

      refute "space" in runtime.allowed_bundles
      refute "memory" in runtime.allowed_bundles

      denied = ~w(
        memory_create memory_delete memory_rename memory_str_replace memory_insert
        memory_view memory_search
        space_create space_leave space_list space_list_agents dm_create
      )

      tool_names = ToolAuthorization.tool_names(runtime)

      for name <- denied do
        assert {:error, :forbidden} = ToolAuthorization.authorize(name, runtime),
               "expected #{name} to be forbidden"

        refute name in tool_names, "expected #{name} to be absent from the granted tool surface"
      end
    end

    test "does NOT allow mail_draft_create even with the Mail module enabled (task 01a0d4a0 stage 4 round 2)" do
      # Regression for Dalton's live moon run (rollup space 01a0b5bf): before
      # `mail` was split out of the `messaging` bundle
      # (`Platform.Federation.ToolSurface`), this runtime's `messaging` grant
      # implicitly carried `mail_draft_create`/`mail_draft_update` too, and
      # the agent used it to attempt a prod write during a hand-off. Pin that
      # this persona's `allowed_bundles` never includes `mail`, and that
      # `mail_draft_create` is refused, regardless of the Mail module flag.
      previous = Application.fetch_env(:platform, :mail_enabled)
      Application.put_env(:platform, :mail_enabled, true)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
          :error -> Application.delete_env(:platform, :mail_enabled)
        end
      end)

      owner = owner!()
      assert {:ok, %{runtime: runtime}} = SeedMeetingVoiceAgent.seed!(owner)

      refute "mail" in runtime.allowed_bundles
      assert {:error, :forbidden} = ToolAuthorization.authorize("mail_draft_create", runtime)
      refute "mail_draft_create" in ToolAuthorization.tool_names(runtime)
    end

    test "does not touch any other agent's runtime row" do
      owner = owner!()

      other_agent =
        Repo.insert!(
          Agent.changeset(%Agent{}, %{
            slug: "other-agent-#{System.unique_integer([:positive])}",
            name: "Other Agent",
            status: "active"
          })
        )

      {:ok, other_runtime, _token} = Federation.register_voice_runtime(owner.id, other_agent)
      before_bundles = other_runtime.allowed_bundles

      assert {:ok, _} = SeedMeetingVoiceAgent.seed!(owner)

      assert Federation.get_runtime(other_runtime.id).allowed_bundles == before_bundles
    end
  end

  # ── resolve_voice_target/1 over the seeded row ──────────────────────────────

  describe "Meetings.resolve_voice_target/1 with the seeded runtime" do
    test "picks the seeded runtime once it is online" do
      owner = owner!()

      assert {:ok, %{agent: agent, runtime: runtime, raw_token: raw_token}} =
               SeedMeetingVoiceAgent.seed!(owner)

      assert {:ok, socket} =
               connect(PlatformWeb.RuntimeSocket, %{
                 "runtime_id" => runtime.runtime_id,
                 "token" => raw_token
               })

      assert {:ok, _reply, joined} =
               join(socket, "runtime:#{runtime.runtime_id}", %{
                 "client_info" => %{
                   "product" => "unknown",
                   "version" => "0.1.0",
                   "features" => ["meeting_voice"]
                 }
               })

      assert {:ok, %{runtime: %AgentRuntime{id: id}, runtime_id: rid}} =
               Meetings.resolve_voice_target(Repo.reload(agent))

      assert id == runtime.id
      assert rid == runtime.runtime_id

      # Clean up: leave so the process does not linger past the test.
      Process.unlink(joined.channel_pid)
      ref = Process.monitor(joined.channel_pid)
      _ = leave(joined)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 2_000
    end

    test "falls back to a clean :voice_runtime_offline error when the row is not connected" do
      owner = owner!()

      assert {:ok, %{agent: agent}} = SeedMeetingVoiceAgent.seed!(owner)

      # No socket ever connects for this agent's voice row in this test, so
      # `RuntimePresence.online?/1` is false and, because a capable row
      # exists but none is online, `resolve_voice_target/1` must not
      # silently fall through to a legacy brain (this agent has none).
      assert {:error, :voice_runtime_offline} =
               Meetings.resolve_voice_target(Repo.reload(agent))
    end
  end
end
