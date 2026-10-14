defmodule Platform.Agents.NativeLoginTest do
  @moduledoc """
  A native agent's login (task 01a10322 stage 6): an Anthropic API key in
  the Vault, scoped to the agent, delivered only in that agent's
  `agent.start`, and the login state the detail pane shows.

  The host is a real `PlatformWeb.AgentHostSocket` connection joined from the
  test, so the key is asserted in the push the daemon would receive.

  Mutants these name:

    * drop the `can_manage?/2` check in `NativeLogin.put_api_key/3` → "a
      non-manager cannot save a key" goes red (a Vault row appears);
    * make `start_env/1` read the key at `{:platform, nil}` or by slug alone →
      "the key reaches only its own agent's start" goes red;
    * return `%{}` from `start_env/1` → the positive control in the same test
      goes red;
    * accept any string in `api_key_shape/1` → the login-code case goes red.
  """
  use PlatformWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Accounts.User
  alias Platform.Agents.{NativeAgents, NativeLogin}
  alias Platform.Repo
  alias Platform.Vault

  @token "agent-host-token-01a10322-s6-login"
  @key "sk-ant-api03-" <> String.duplicate("k", 60) <> "OWNKEY01a10322s6tail"

  setup do
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, @token)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)

    %{owner: user!("owner"), stranger: user!("stranger")}
  end

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "native-login-#{label}-#{n}@example.com",
      name: "Native login #{label} #{n}",
      oidc_sub: "oidc-native-login-#{label}-#{n}"
    })
  end

  defp native!(owner, name) do
    {:ok, agent, runtime} = NativeAgents.create(owner.id, %{name: name, harness: "claude_code"})
    {agent, runtime}
  end

  defp join_host! do
    {:ok, socket} =
      connect(PlatformWeb.AgentHostSocket, %{},
        connect_info: %{x_headers: [{"x-agent-host-token", @token}]}
      )

    {:ok, _reply, channel} = subscribe_and_join(socket, "agent_host:control", %{})
    channel
  end

  describe "storing the key" do
    test "the owner's key is stored encrypted, scoped to the agent", %{owner: owner} do
      {agent, _} = native!(owner, "Ada")
      refute NativeLogin.api_key_set?(agent)

      assert :ok = NativeLogin.put_api_key(owner.id, agent, "  " <> @key <> "\n")
      assert NativeLogin.api_key_set?(agent)

      [cred] = Vault.list(scope: {:agent, agent.id})
      assert cred.slug == "anthropic-api-key"
      assert cred.scope_type == "agent"
      assert cred.provider == "anthropic"
      # Metadata only: no value in the listing.
      refute inspect(cred) =~ @key

      # The agent reads its own key; another agent cannot.
      {other, _} = native!(owner, "Bea")

      assert {:ok, @key} =
               Vault.get("anthropic-api-key",
                 scope: {:agent, agent.id},
                 accessor: {:agent, agent.id}
               )

      assert {:error, :access_denied} =
               Vault.get("anthropic-api-key",
                 scope: {:agent, agent.id},
                 accessor: {:agent, other.id}
               )
    end

    test "saving again replaces the key; one row per agent", %{owner: owner} do
      {agent, _} = native!(owner, "Cy")
      :ok = NativeLogin.put_api_key(owner.id, agent, @key)
      second = "sk-ant-api03-" <> String.duplicate("z", 60) <> "SECONDKEY01a10322s6t"
      :ok = NativeLogin.put_api_key(owner.id, agent, second)

      assert [_one] = Vault.list(scope: {:agent, agent.id})
      assert %{"ANTHROPIC_API_KEY" => ^second} = NativeLogin.start_env(agent)
    end

    test "a non-manager cannot save a key (positive control: the owner can)", %{
      owner: owner,
      stranger: stranger
    } do
      {agent, _} = native!(owner, "Dee")

      assert {:error, :forbidden} = NativeLogin.put_api_key(stranger.id, agent, @key)
      assert {:error, :forbidden} = NativeLogin.put_api_key(nil, agent, @key)
      assert Vault.list(scope: {:agent, agent.id}) == []

      assert :ok = NativeLogin.put_api_key(owner.id, agent, @key)
      assert NativeLogin.api_key_set?(agent)

      assert {:error, :forbidden} = NativeLogin.remove_api_key(stranger.id, agent)
      assert NativeLogin.api_key_set?(agent)
    end

    test "only an Anthropic API key is accepted: never a login code", %{owner: owner} do
      {agent, _} = native!(owner, "Eve")

      for bad <- [
            # The shape of the code claude.ai shows after a subscription login.
            "AbCdEf0123456789AbCdEf0123456789#AbCdEf0123456789AbCdEf0123",
            "sk-ant-short",
            "sk-ant-api03-has a space in it 0123456789",
            "sk-proj-" <> String.duplicate("a", 40),
            "",
            nil,
            123
          ] do
        assert {:error, :invalid_api_key} = NativeLogin.put_api_key(owner.id, agent, bad),
               "accepted #{inspect(bad)}"
      end

      assert Vault.list(scope: {:agent, agent.id}) == []
    end

    test "a federated (not install-managed) agent has no key path", %{owner: owner} do
      {:ok, agent, _runtime, _token} =
        Platform.Federation.provision_agent_runtime(
          owner.id,
          %{slug: "fed-#{System.unique_integer([:positive])}", name: "Fed", status: "active"},
          %{
            runtime_id: "fed-#{System.unique_integer([:positive])}",
            display_name: "Fed",
            transport: "websocket"
          }
        )

      assert {:error, :not_managed} = NativeLogin.put_api_key(owner.id, agent, @key)
      assert NativeLogin.start_env(agent) == %{}
    end

    test "remove deletes the key and the next start carries none", %{owner: owner} do
      {agent, _} = native!(owner, "Fay")
      :ok = NativeLogin.put_api_key(owner.id, agent, @key)
      assert :ok = NativeLogin.remove_api_key(owner.id, agent)
      refute NativeLogin.api_key_set?(agent)
      assert NativeLogin.start_env(agent) == %{}
      # Idempotent.
      assert :ok = NativeLogin.remove_api_key(owner.id, agent)
    end
  end

  describe "delivery" do
    test "the key reaches only its own agent's start, and is never logged", %{owner: owner} do
      {ada, _} = native!(owner, "Gil")
      {bea, _} = native!(owner, "Hal")
      :ok = NativeLogin.put_api_key(owner.id, ada, @key)

      _channel = join_host!()

      log =
        capture_log(fn ->
          {:ok, _} = NativeAgents.set_desired_state(ada, "running")
          {:ok, _} = NativeAgents.set_desired_state(bea, "running")
          :ok = Platform.AgentHost.Reconciler.converge(ada.id)
          :ok = Platform.AgentHost.Reconciler.converge(bea.id)

          ada_id = ada.id
          bea_id = bea.id
          assert_push "agent.start", %{"agent_id" => ^ada_id, "env" => ada_env}
          assert_push "agent.start", %{"agent_id" => ^bea_id, "env" => bea_env}

          # Positive control: the key IS delivered to its own agent.
          assert ada_env == %{"ANTHROPIC_API_KEY" => @key}
          assert bea_env == %{}
        end)

      refute log =~ @key
      refute log =~ String.slice(@key, -20, 20)
    end

    test "a restart carries the key too", %{owner: owner} do
      {agent, _} = native!(owner, "Ivy")
      :ok = NativeLogin.put_api_key(owner.id, agent, @key)
      _channel = join_host!()

      :ok = Platform.AgentHost.restart_agent(agent)
      agent_id = agent.id

      assert_push "agent.restart", %{
        "agent_id" => ^agent_id,
        "env" => %{"ANTHROPIC_API_KEY" => @key}
      }
    end
  end

  describe "login state transitions" do
    test "step/2 from the observed state and whether a key is saved" do
      assert NativeLogin.step(%{state: :needs_login}, false) == :needs_key
      assert NativeLogin.step(%{state: :needs_login}, true) == :key_refused
      assert NativeLogin.step(%{state: :starting}, true) == :waiting
      assert NativeLogin.step(%{state: :running}, true) == :logged_in
      assert NativeLogin.step(%{state: :running}, false) == :idle
      assert NativeLogin.step(%{state: :starting}, false) == :idle
      assert NativeLogin.step(%{state: :stopped}, true) == :idle
      assert NativeLogin.step(%{state: :crashed}, true) == :idle
      assert NativeLogin.step(nil, true) == :idle
    end
  end
end
