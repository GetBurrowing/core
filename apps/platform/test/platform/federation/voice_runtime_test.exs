defmodule Platform.Federation.VoiceRuntimeTest do
  @moduledoc """
  Task 01a06686 stage 1: a voice runtime is a SECOND `agent_runtimes` row for
  an agent, and `Meetings.join_capability/1` answers over the whole set.
  """
  use PlatformWeb.ChannelCase, async: false

  import ExUnit.CaptureIO

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Repo

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp create_user do
    Repo.insert!(%User{
      email: "voice_rt_#{System.unique_integer([:positive])}@example.com",
      name: "Voice Runtime Test User",
      oidc_sub: "oidc-voice-rt-#{System.unique_integer([:positive])}"
    })
  end

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "Test Agent",
      status: "active"
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  # The legacy path: one row, linked as the brain via `link_agent/2`.
  defp link_brain!(user, agent) do
    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "brain-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)
    %{agent: agent, brain: Federation.get_runtime(activated.id), raw_token: raw_token}
  end

  # Simulates `RuntimeChannel.persist_client_info/2`: replaces the whole
  # `client_info` map, features included. `nil` means the client never
  # declared a features list.
  defp declare!(%AgentRuntime{} = runtime, features) do
    client_info =
      %{"product" => "openclaw", "version" => "0.1.0"}
      |> then(fn ci -> if is_nil(features), do: ci, else: Map.put(ci, "features", features) end)

    {:ok, updated} = Federation.update_metadata(runtime, %{"client_info" => client_info})
    updated
  end

  # ── register_voice_runtime/3 ──────────────────────────────────────────────

  describe "register_voice_runtime/3" do
    test "leaves agent.runtime_id untouched and does not rebind the brain" do
      user = create_user()
      %{agent: agent, brain: brain} = link_brain!(user, create_agent())
      before = Repo.reload(agent).runtime_id
      assert before == brain.id

      assert {:ok, %AgentRuntime{} = voice, raw_token} =
               Federation.register_voice_runtime(user.id, agent)

      assert is_binary(raw_token)
      assert voice.id != brain.id
      assert Repo.reload(agent).runtime_id == before
      assert Repo.reload(agent).runtime_id == brain.id
      refute Repo.reload(agent).runtime_id == voice.id
    end

    test "binds the row to the agent with role voice and a derived display name" do
      user = create_user()
      %{agent: agent} = link_brain!(user, create_agent(%{name: "Nova"}))

      {:ok, voice, _token} = Federation.register_voice_runtime(user.id, agent)

      persisted = Federation.get_runtime(voice.id)
      assert persisted.agent_id == agent.id
      assert persisted.owner_user_id == user.id
      assert persisted.display_name == "Nova voice"
      assert persisted.metadata["role"] == "voice"
      assert persisted.status == "active"
    end

    test "attrs override display_name and merge metadata but role stays voice" do
      user = create_user()
      %{agent: agent} = link_brain!(user, create_agent())

      {:ok, voice, _token} =
        Federation.register_voice_runtime(user.id, agent, %{
          display_name: "Custom mouth",
          runtime_id: "custom-voice-#{System.unique_integer([:positive])}",
          metadata: %{"region" => "eu", "role" => "brain"}
        })

      persisted = Federation.get_runtime(voice.id)
      assert persisted.display_name == "Custom mouth"
      assert persisted.runtime_id =~ "custom-voice-"
      assert persisted.metadata["region"] == "eu"
      assert persisted.metadata["role"] == "voice"
    end

    test "the returned raw token authenticates RuntimeSocket for the voice row" do
      user = create_user()
      %{agent: agent, raw_token: brain_token} = link_brain!(user, create_agent())

      {:ok, voice, raw_token} = Federation.register_voice_runtime(user.id, agent)
      refute raw_token == brain_token

      assert {:ok, socket} =
               connect(PlatformWeb.RuntimeSocket, %{
                 "runtime_id" => voice.runtime_id,
                 "token" => raw_token
               })

      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket, "runtime:#{voice.runtime_id}", %{})
    end

    test "works for an agent that has no brain row yet" do
      user = create_user()
      agent = create_agent()
      assert is_nil(agent.runtime_id)

      {:ok, voice, _token} = Federation.register_voice_runtime(user.id, agent)

      assert is_nil(Repo.reload(agent).runtime_id)
      assert Federation.get_runtime(voice.id).agent_id == agent.id
    end
  end

  # ── runtimes_for_agent/1 and voice_runtimes_for_agent/1 ──────────────────

  describe "runtimes_for_agent/1" do
    test "returns the brain row first, then voice rows by insertion order" do
      user = create_user()
      # Register the voice rows BEFORE the brain so `inserted_at` alone would
      # put the brain last: the ordering has to come from `agent.runtime_id`.
      agent = create_agent()
      {:ok, voice_a, _} = Federation.register_voice_runtime(user.id, agent)
      {:ok, voice_b, _} = Federation.register_voice_runtime(user.id, agent)
      %{agent: agent, brain: brain} = link_brain!(user, agent)

      assert [first | rest] = Federation.runtimes_for_agent(agent)
      assert first.id == brain.id
      assert Enum.map(rest, & &1.id) == [voice_a.id, voice_b.id]
    end

    test "returns [] for an agent with nothing linked" do
      assert Federation.runtimes_for_agent(create_agent()) == []
    end

    test "an agent with only voice rows and no brain lists them all" do
      user = create_user()
      agent = create_agent()
      {:ok, voice, _} = Federation.register_voice_runtime(user.id, agent)

      assert [%AgentRuntime{id: id}] = Federation.runtimes_for_agent(agent)
      assert id == voice.id
    end
  end

  describe "voice_runtimes_for_agent/1" do
    test "excludes the brain row" do
      user = create_user()
      %{agent: agent, brain: brain} = link_brain!(user, create_agent())
      {:ok, voice, _} = Federation.register_voice_runtime(user.id, agent)

      ids = agent |> Federation.voice_runtimes_for_agent() |> Enum.map(& &1.id)
      assert ids == [voice.id]
      refute brain.id in ids
    end

    test "returns [] for an agent with only a brain, and for one with nothing" do
      user = create_user()
      %{agent: agent} = link_brain!(user, create_agent())

      assert Federation.voice_runtimes_for_agent(agent) == []
      assert Federation.voice_runtimes_for_agent(create_agent()) == []
    end
  end

  # ── Meetings.join_capability/1 over the set ───────────────────────────────

  describe "join_capability/1 over brain + voice rows" do
    setup do
      user = create_user()
      %{agent: agent, brain: brain} = link_brain!(user, create_agent())
      {:ok, voice, _} = Federation.register_voice_runtime(user.id, agent)
      %{user: user, agent: agent, brain: brain, voice: voice}
    end

    test "(a) brain [] + voice [meeting_voice] is capable", ctx do
      declare!(ctx.brain, [])
      declare!(ctx.voice, ["meeting_voice"])

      assert Meetings.join_capability(ctx.agent) == :capable
    end

    test "(b) still capable when the brain declares LAST (the live symptom)", ctx do
      # This is the ordering that used to flip the answer: the voice worker
      # connected, then the brain reconnected and its `client_info` — the
      # only one a brain-only read ever saw — said no voice.
      declare!(ctx.voice, ["meeting_voice"])
      declare!(ctx.brain, [])

      assert Meetings.join_capability(ctx.agent) == :capable
    end

    test "(c) brain [] + voice [] is incapable", ctx do
      declare!(ctx.brain, [])
      declare!(ctx.voice, [])

      assert Meetings.join_capability(ctx.agent) == :incapable
    end

    test "(d) brain undeclared + voice undeclared is unknown", ctx do
      declare!(ctx.brain, nil)
      declare!(ctx.voice, nil)

      assert Meetings.join_capability(ctx.agent) == :unknown
    end

    test "one declared-incapable row outranks an undeclared one", ctx do
      declare!(ctx.brain, ["system_event_prompt"])
      declare!(ctx.voice, nil)

      assert Meetings.join_capability(ctx.agent) == :incapable
    end
  end

  describe "join_capability/1 legacy shapes" do
    test "(e) a single legacy runtime declaring voice is capable" do
      user = create_user()
      %{agent: agent, brain: brain} = link_brain!(user, create_agent())
      declare!(brain, ["meeting_voice"])

      assert Meetings.join_capability(agent) == :capable
    end

    test "(f) an agent with no runtime is unknown" do
      assert Meetings.join_capability(create_agent()) == :unknown
    end

    test "a non-Agent is unknown" do
      assert Meetings.join_capability(nil) == :unknown
      assert Meetings.join_capability(%{runtime_id: nil}) == :unknown
    end
  end

  # ── mix platform.voice_runtime ────────────────────────────────────────────

  describe "mix platform.voice_runtime" do
    test "prints the new runtime once and leaves agent.runtime_id alone" do
      user = create_user()
      %{agent: agent, brain: brain} = link_brain!(user, create_agent(%{name: "Nova"}))

      output =
        capture_io(fn ->
          assert :ok =
                   Mix.Tasks.Platform.VoiceRuntime.run([
                     "--agent",
                     agent.slug,
                     "--owner",
                     user.email
                   ])
        end)

      assert [_, runtime_id] = Regex.run(~r/runtime_id:\s+(\S+)/, output)
      assert %AgentRuntime{} = row = Federation.get_runtime_by_runtime_id(runtime_id)
      assert row.agent_id == agent.id
      assert row.metadata["role"] == "voice"
      assert output =~ "display_name: Nova voice"
      assert output =~ "will not be shown again"

      assert [_, token] = Regex.run(~r/token:\s+(\S+)/, output)
      assert Federation.get_runtime_by_token(token).id == row.id

      assert Repo.reload(agent).runtime_id == brain.id
    end

    test "resolves the agent by id and honours --name" do
      user = create_user()
      %{agent: agent} = link_brain!(user, create_agent())

      output =
        capture_io(fn ->
          Mix.Tasks.Platform.VoiceRuntime.run([
            "--agent",
            agent.id,
            "--owner",
            user.email,
            "--name",
            "Nova mouth"
          ])
        end)

      assert output =~ "display_name: Nova mouth"
    end

    test "an unknown agent slug raises a Mix.Error" do
      user = create_user()

      assert_raise Mix.Error, ~r/Unknown agent "no-such-agent"/, fn ->
        capture_io(fn ->
          Mix.Tasks.Platform.VoiceRuntime.run([
            "--agent",
            "no-such-agent",
            "--owner",
            user.email
          ])
        end)
      end
    end

    test "an unknown owner email raises a Mix.Error" do
      agent = create_agent()

      assert_raise Mix.Error, ~r/Unknown owner "nobody@example.com"/, fn ->
        capture_io(fn ->
          Mix.Tasks.Platform.VoiceRuntime.run([
            "--agent",
            agent.slug,
            "--owner",
            "nobody@example.com"
          ])
        end)
      end
    end

    test "missing --agent or --owner raises with usage" do
      assert_raise Mix.Error, ~r/--agent is required/, fn ->
        Mix.Tasks.Platform.VoiceRuntime.run(["--owner", "x@example.com"])
      end

      assert_raise Mix.Error, ~r/--owner is required/, fn ->
        Mix.Tasks.Platform.VoiceRuntime.run(["--agent", "x"])
      end
    end
  end
end
