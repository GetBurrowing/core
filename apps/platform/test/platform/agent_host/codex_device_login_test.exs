defmodule Platform.AgentHost.CodexDeviceLoginTest do
  @moduledoc """
  Codex's device login (task 01a10315 stage 4): what core keeps of it, how a
  screen asks for it, and the dev stand-in host.

    * the reconciler keeps a device code only at step `device_code`, only in
      the shape `^[A-Z0-9-]{4,16}$`, and only with an https URL on
      auth.openai.com; anything else is dropped (and a Claude login, task
      01a17b10, stays a step name only);
    * `Platform.AgentHost.State` round-trips `login_code` and `device_url`,
      and a later observation without them clears them;
    * `NativeLogin.login_view/1,3` per harness and login mode;
    * `Platform.AgentHost.FakeHost`: codex waits at FAKE-1234 until
      `complete/1` (and its dev route), then runs; Claude Code runs once a key
      is saved.

  Mutants these name:

    * drop the regex check in `Reconciler.device_login/2` → "a malformed code
      is dropped" goes red;
    * drop the host check → "a URL off auth.openai.com is dropped" goes red;
    * keep `login` for any step → "a Claude login_url step keeps nothing"
      goes red;
    * make `FakeHost` report `running` for codex on start → "waits at the
      device code" goes red.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.AgentHost.{FakeHost, Reconciler, State}
  alias Platform.Agents.{NativeAgents, NativeLogin}
  alias Platform.Repo

  @url "https://auth.openai.com/codex/device"

  setup do
    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "codex-device-#{n}@example.com",
        name: "Codex device #{n}",
        oidc_sub: "oidc-codex-device-#{n}"
      })

    %{owner: owner, n: n}
  end

  defp native!(owner, name, harness) do
    {:ok, agent, runtime} = NativeAgents.create(owner.id, %{name: name, harness: harness})
    {agent, runtime}
  end

  defp receive_forever do
    receive do
      _ -> receive_forever()
    end
  end

  defp join_test_host! do
    host = spawn_link(fn -> receive_forever() end)
    :ok = Reconciler.host_joined(host, %{"profile" => "contained"})
    host
  end

  defp needs_login(agent_id, login),
    do: %{"agent_id" => agent_id, "state" => "needs_login", "login" => login}

  describe "the reconciler keeps a device code only in its measured shape" do
    setup %{owner: owner} do
      {agent, _} = native!(owner, "Cody", "codex")
      %{agent: agent, host: join_test_host!()}
    end

    test "a valid code and its auth.openai.com URL are kept", %{agent: agent, host: host} do
      login = %{"step" => "device_code", "url" => @url, "code" => "QOHQ-5M34L"}
      :ok = Reconciler.agent_state(host, needs_login(agent.id, login))

      assert %{state: :needs_login, login_code: "QOHQ-5M34L", device_url: @url} =
               State.get(agent.id)
    end

    test "a malformed code is dropped, and its URL with it", %{agent: agent, host: host} do
      for code <- ["qohq-5m34l", "QO", "QOHQ 5M34L", "ABCDEFGHIJ-KLMNOPQ", "<b>X</b>", 1234] do
        login = %{"step" => "device_code", "url" => @url, "code" => code}
        :ok = Reconciler.agent_state(host, needs_login(agent.id, login))
        entry = State.get(agent.id)
        # Positive control: the observation itself was recorded.
        assert entry.state == :needs_login
        assert {entry.login_code, entry.device_url} == {nil, nil}, inspect(code)
      end
    end

    test "a URL off auth.openai.com is dropped", %{agent: agent, host: host} do
      for url <- [
            "http://auth.openai.com/codex/device",
            "https://auth.openai.com.evil.test/codex/device",
            "https://claude.com/cai/oauth/authorize",
            "https://auth.openai.com:8443/codex/device",
            "https://auth.openai.com/codex/device?next=https://evil.test"
          ] do
        login = %{"step" => "device_code", "url" => url, "code" => "QOHQ-5M34L"}
        :ok = Reconciler.agent_state(host, needs_login(agent.id, login))
        assert %{login_code: nil, device_url: nil} = State.get(agent.id), url
      end
    end

    test "a Claude login_url step keeps nothing, even carrying a valid-looking code", %{
      agent: agent,
      host: host
    } do
      login = %{"step" => "login_url", "url" => @url, "code" => "QOHQ-5M34L"}
      :ok = Reconciler.agent_state(host, needs_login(agent.id, login))

      assert %{state: :needs_login, detail: nil, login_code: nil, device_url: nil} =
               State.get(agent.id)
    end

    test "only needs_login keeps it", %{agent: agent, host: host} do
      login = %{"step" => "device_code", "url" => @url, "code" => "QOHQ-5M34L"}

      :ok =
        Reconciler.agent_state(host, %{
          "agent_id" => agent.id,
          "state" => "running",
          "login" => login
        })

      assert %{state: :running, login_code: nil} = State.get(agent.id)
    end

    test "the next observation without a code clears it", %{agent: agent, host: host} do
      login = %{"step" => "device_code", "url" => @url, "code" => "QOHQ-5M34L"}
      :ok = Reconciler.agent_state(host, needs_login(agent.id, login))
      assert State.get(agent.id).login_code == "QOHQ-5M34L"

      :ok = Reconciler.agent_state(host, %{"agent_id" => agent.id, "state" => "running"})
      assert %{state: :running, login_code: nil, device_url: nil} = State.get(agent.id)
    end
  end

  describe "State" do
    test "round-trips login_code and device_url" do
      id = Ecto.UUID.generate()

      State.put(id, :needs_login, %{
        detail: "device_code",
        login_code: "AB12-CD34E",
        device_url: @url
      })

      assert %{
               state: :needs_login,
               detail: "device_code",
               login_code: "AB12-CD34E",
               device_url: @url
             } =
               State.get(id)

      State.put(id, :starting)
      assert %{login_code: nil, device_url: nil} = State.get(id)
    end
  end

  describe "NativeLogin" do
    test "device_login?/1 is codex only; api_key_harness?/1 stays Claude Code only" do
      assert NativeLogin.device_login?("codex")
      refute NativeLogin.device_login?("claude_code")
      refute NativeLogin.device_login?(nil)
      assert NativeLogin.api_key_harness?("claude_code")
      refute NativeLogin.api_key_harness?("codex")
    end

    test "login_view/3 per harness and mode" do
      observed = %{state: :needs_login, login_code: "AB12-CD34E", device_url: @url}

      assert NativeLogin.login_view("codex", observed, :api_key) ==
               %{kind: :device_code, url: @url, code: "AB12-CD34E"}

      assert NativeLogin.login_view("codex", nil, :operator) ==
               %{kind: :device_code, url: nil, code: nil}

      assert NativeLogin.login_view("claude_code", observed, :api_key) == :api_key

      assert NativeLogin.login_view("claude_code", observed, :operator) ==
               :subscription_terminal_only

      assert NativeLogin.login_view("gemini", nil, :api_key) == :unsupported
    end

    test "login_view/1 reads the agent's harness and observed state", %{owner: owner} do
      {codex, _} = native!(owner, "Cody", "codex")
      {claude, _} = native!(owner, "Clio", "claude_code")
      host = join_test_host!()

      login = %{"step" => "device_code", "url" => @url, "code" => "AB12-CD34E"}
      :ok = Reconciler.agent_state(host, needs_login(codex.id, login))

      assert NativeLogin.login_view(codex) == %{kind: :device_code, url: @url, code: "AB12-CD34E"}
      assert NativeLogin.login_view(claude) == :api_key
    end
  end

  describe "FakeHost" do
    setup do
      # The reconciler holds one host; whatever a previous test joined is gone
      # with its process, and this one goes with the test.
      pid = start_supervised!({FakeHost, report_after_ms: 0})
      %{fake: pid}
    end

    test "waits for the Endpoint before joining (no agent.start before it is up)" do
      # Stage 6: an Endpoint that is not running holds the join back.
      stop_supervised!(FakeHost)
      waiting = start_supervised!({FakeHost, report_after_ms: 0, endpoint: :no_endpoint_here})
      Process.sleep(200)
      refute Reconciler.host_pid() == waiting
      assert Process.alive?(waiting)
    end

    test "joins as the install's host", %{fake: fake} do
      assert_eventually(fn -> Reconciler.host_pid() == fake end, 3_000)
      assert %{profile: "fake"} = State.host()
    end

    test "a codex agent waits at the device code, then runs once completed", %{
      owner: owner,
      fake: fake
    } do
      {agent, runtime} = native!(owner, "Cody", "codex")
      {:ok, _} = NativeAgents.set_desired_state(runtime, "running")
      assert_eventually(fn -> Reconciler.host_pid() == fake end, 3_000)
      :ok = Reconciler.converge(agent.id)

      entry =
        assert_eventually(fn ->
          match?(%{state: :needs_login}, State.get(agent.id)) && State.get(agent.id)
        end)

      assert %{login_code: "FAKE-1234", device_url: @url, detail: "device_code"} = entry

      assert NativeLogin.login_view(agent) == %{kind: :device_code, url: @url, code: "FAKE-1234"}

      assert :ok = FakeHost.complete(agent.id)
      assert_eventually(fn -> match?(%{state: :running}, State.get(agent.id)) end)
      assert %{login_code: nil} = State.get(agent.id)
    end

    test "the dev route completes it too", %{owner: owner, fake: fake} do
      {agent, runtime} = native!(owner, "Cody", "codex")
      {:ok, _} = NativeAgents.set_desired_state(runtime, "running")
      assert_eventually(fn -> Reconciler.host_pid() == fake end, 3_000)
      :ok = Reconciler.converge(agent.id)
      assert_eventually(fn -> match?(%{state: :needs_login}, State.get(agent.id)) end)

      conn =
        Plug.Test.conn(:post, "/#{agent.id}/complete")
        |> PlatformWeb.Dev.FakeAgentHost.call([])

      assert conn.status == 200
      assert_eventually(fn -> match?(%{state: :running}, State.get(agent.id)) end)

      unknown =
        Plug.Test.conn(:post, "/#{Ecto.UUID.generate()}/complete")
        |> PlatformWeb.Dev.FakeAgentHost.call([])

      assert unknown.status == 404
    end

    test "a claude_code agent needs a key, and runs once one is saved", %{
      owner: owner,
      fake: fake
    } do
      {agent, runtime} = native!(owner, "Clio", "claude_code")
      {:ok, _} = NativeAgents.set_desired_state(runtime, "running")
      assert_eventually(fn -> Reconciler.host_pid() == fake end, 3_000)
      :ok = Reconciler.converge(agent.id)

      entry =
        assert_eventually(fn ->
          match?(%{state: :needs_login}, State.get(agent.id)) && State.get(agent.id)
        end)

      # Never a Claude login URL or code.
      assert %{login_code: nil, device_url: nil, detail: "login"} = entry
      assert {:error, :not_device_login} = FakeHost.complete(agent.id)

      key = "sk-ant-api03-" <> String.duplicate("f", 40)
      :ok = NativeLogin.put_api_key(owner.id, agent, key)
      :ok = Reconciler.restart(agent.id)
      assert_eventually(fn -> match?(%{state: :running}, State.get(agent.id)) end)
    end
  end
end
