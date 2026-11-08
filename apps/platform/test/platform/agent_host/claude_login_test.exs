defmodule Platform.AgentHost.ClaudeLoginTest do
  @moduledoc """
  The owner's Claude subscription login through core (task 01a1b365 stage 2):
  `Platform.AgentHost.claude_login_start/3`, `claude_login_submit/4` and
  `claude_logout/3` against the stubbed host (`Platform.FakeAgentHost`) and
  through the real channel, the server-side `can_manage?/2` gate, the
  single-flight pending login bound to its caller, `LoginCode`'s redaction
  and `NativeLogin.login_view/1`'s `:claude_subscription` view.

  Mutants these name:

    * remove `defimpl Inspect` from `Platform.AgentHost.LoginCode` → "a
      crash of the process holding the code does not print it" goes red (the
      crash report prints the struct's `secret`);
    * drop the `can_manage?` check in `AgentHost.login_gate/2` → "a
      non-manager is refused" goes red;
    * drop the actor/caller match in the Reconciler's `:claude_login_code`
      clause → "a code goes only into the login its own caller started"
      goes red.
  """
  use PlatformWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Accounts.User
  alias Platform.AgentHost
  alias Platform.AgentHost.{FakeHost, LoginCode, Reconciler}
  alias Platform.Agents.{NativeAgents, NativeLogin}
  alias Platform.FakeAgentHost
  alias Platform.Repo

  @token "agent-host-token-01a1b365-s2"
  @key "sk-ant-api03-" <> String.duplicate("k", 60) <> "KEY01a1b365s2tail"

  setup do
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, @token)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)

    owner = user!("owner")

    {:ok, agent, _runtime} =
      NativeAgents.create(owner.id, %{name: "Clio", harness: "claude_code"})

    %{owner: owner, stranger: user!("stranger"), agent: agent}
  end

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "claude-login-#{label}-#{n}@example.com",
      name: "Claude login #{label} #{n}",
      oidc_sub: "oidc-claude-login-#{label}-#{n}"
    })
  end

  defp fake_host!(opts \\ []), do: start_supervised!({FakeAgentHost, opts})

  defp good_code do
    {:ok, code} = LoginCode.new(FakeHost.claude_login_code())
    code
  end

  # Run `fun` in a separate process and return its result.
  defp in_other_process(fun), do: fun |> Task.async() |> Task.await(10_000)

  describe "LoginCode" do
    test "inspects as redacted and refuses what is not code-shaped" do
      {:ok, code} = LoginCode.new("  SENTINEL-01a1b365#state\n")
      assert inspect(code) == "#LoginCode<redacted>"
      assert inspect(%{code: code}) == "%{code: #LoginCode<redacted>}"
      refute inspect(code, structs: true, limit: :infinity) =~ "SENTINEL"
      assert LoginCode.reveal(code) == "SENTINEL-01a1b365#state"

      assert {:error, :bad_code} = LoginCode.new("")
      assert {:error, :bad_code} = LoginCode.new("two words")
      assert {:error, :bad_code} = LoginCode.new(String.duplicate("a", 513))
      assert {:error, :bad_code} = LoginCode.new(nil)
    end

    test "cannot be interpolated or JSON-encoded" do
      {:ok, code} = LoginCode.new("SENTINEL-01a1b365#json")
      assert_raise Protocol.UndefinedError, fn -> apply(String.Chars, :to_string, [code]) end

      error = assert_raise Protocol.UndefinedError, fn -> Jason.encode!(%{"code" => code}) end
      refute Exception.message(error) =~ "SENTINEL"
    end
  end

  describe "start and submit against the stubbed host" do
    test "a good code signs in: url, then account and plan", %{owner: owner, agent: agent} do
      fake_host!()

      assert {:ok, url} = AgentHost.claude_login_start(owner, agent)
      assert %URI{scheme: "https", host: "claude.com"} = URI.parse(url)
      assert Reconciler.claude_login_pending?(agent.id)

      assert {:ok, %{account: "owner@example.com", plan: "max"}} =
               AgentHost.claude_login_submit(owner, agent, good_code())

      refute Reconciler.claude_login_pending?(agent.id)
    end

    test "a wrong code is bad_code, and the login must be started again", %{
      owner: owner,
      agent: agent
    } do
      fake_host!()
      {:ok, _url} = AgentHost.claude_login_start(owner, agent)
      {:ok, wrong} = LoginCode.new("not-the-code#x")

      assert {:error, :bad_code} = AgentHost.claude_login_submit(owner, agent, wrong)
      assert {:error, :no_session} = AgentHost.claude_login_submit(owner, agent, good_code())
    end

    test "no_subscription", %{owner: owner, agent: agent} do
      fake_host!(claude_login: :no_subscription)
      {:ok, _url} = AgentHost.claude_login_start(owner, agent)
      assert {:error, :no_subscription} = AgentHost.claude_login_submit(owner, agent, good_code())
    end

    test "a host that never answers times out, and the pending login ends", %{
      owner: owner,
      agent: agent
    } do
      host = fake_host!(claude_login: :timeout)

      assert {:error, :timeout} = AgentHost.claude_login_start(owner, agent, timeout: 100)
      refute Reconciler.claude_login_pending?(agent.id)

      :ok = FakeAgentHost.set_claude_login(host, :ok)
      {:ok, _url} = AgentHost.claude_login_start(owner, agent)
      :ok = FakeAgentHost.set_claude_login(host, :timeout)

      assert {:error, :timeout} =
               AgentHost.claude_login_submit(owner, agent, good_code(), timeout: 100)
    end

    test "a code with no login started is no_session", %{owner: owner, agent: agent} do
      fake_host!()
      assert {:error, :no_session} = AgentHost.claude_login_submit(owner, agent, good_code())
    end

    test "no host connected", %{owner: owner, agent: agent} do
      assert {:error, :not_connected} = AgentHost.claude_login_start(owner, agent)
      assert {:error, :not_connected} = AgentHost.claude_login_submit(owner, agent, good_code())
      assert {:error, :not_connected} = AgentHost.claude_logout(owner, agent)
    end

    test "logout", %{owner: owner, agent: agent} do
      fake_host!()
      {:ok, _url} = AgentHost.claude_login_start(owner, agent)

      assert :ok = AgentHost.claude_logout(owner, agent, restart: false)
      refute Reconciler.claude_login_pending?(agent.id)
      # Default: the agent is restarted so it drops the login at once.
      assert :ok = AgentHost.claude_logout(owner, agent)
    end

    test "a codex agent is refused before anything reaches the host", %{owner: owner} do
      fake_host!()
      {:ok, codex, _} = NativeAgents.create(owner.id, %{name: "Cody", harness: "codex"})

      assert {:error, :unsupported_harness} = AgentHost.claude_login_start(owner, codex)
      refute Reconciler.claude_login_pending?(codex.id)
    end
  end

  describe "authorization, checked in core" do
    test "a non-manager is refused, and nothing is sent", %{
      owner: owner,
      stranger: stranger,
      agent: agent
    } do
      fake_host!()
      refute NativeAgents.can_manage?(stranger, agent)

      assert {:error, :forbidden} = AgentHost.claude_login_start(stranger, agent)
      assert {:error, :forbidden} = AgentHost.claude_login_start(stranger.id, agent)
      refute Reconciler.claude_login_pending?(agent.id)

      # Even into a login the owner started.
      {:ok, _url} = AgentHost.claude_login_start(owner, agent)
      assert {:error, :forbidden} = AgentHost.claude_login_submit(stranger, agent, good_code())
      assert {:error, :forbidden} = AgentHost.claude_logout(stranger, agent)
      assert {:error, :forbidden} = AgentHost.claude_login_start(nil, agent)

      # Positive control: the owner's own login is untouched.
      assert Reconciler.claude_login_pending?(agent.id)
      assert {:ok, _} = AgentHost.claude_login_submit(owner, agent, good_code())
    end
  end

  describe "single flight: one pending login per agent, bound to its caller" do
    test "another manager can neither start over it nor submit into it", %{
      owner: owner,
      agent: agent
    } do
      fake_host!()
      admin = Platform.TenancyFixtures.root_admin!()
      assert NativeAgents.can_manage?(admin, agent)

      {:ok, _url} = AgentHost.claude_login_start(owner, agent)

      assert {:error, :busy} =
               in_other_process(fn -> AgentHost.claude_login_start(admin, agent) end)

      assert {:error, :forbidden} =
               in_other_process(fn ->
                 AgentHost.claude_login_submit(admin, agent, good_code())
               end)

      # Positive control: the starter's own submit still goes through.
      assert {:ok, %{account: "owner@example.com"}} =
               AgentHost.claude_login_submit(owner, agent, good_code())
    end

    test "the same user in another process (another tab) is refused too", %{
      owner: owner,
      agent: agent
    } do
      fake_host!()
      {:ok, _url} = AgentHost.claude_login_start(owner, agent)

      assert {:error, :busy} =
               in_other_process(fn -> AgentHost.claude_login_start(owner, agent) end)

      assert {:error, :forbidden} =
               in_other_process(fn ->
                 AgentHost.claude_login_submit(owner, agent, good_code())
               end)

      assert Reconciler.claude_login_pending?(agent.id)
    end

    test "the same caller may start again; a starter that exits frees the agent", %{
      owner: owner,
      agent: agent
    } do
      fake_host!()
      admin = Platform.TenancyFixtures.root_admin!()

      {:ok, _} = AgentHost.claude_login_start(owner, agent)
      assert {:ok, _} = AgentHost.claude_login_start(owner, agent)

      # A starter in another process that then exits.
      Reconciler.claude_logout(agent.id, "clear")
      {:ok, _} = in_other_process(fn -> AgentHost.claude_login_start(owner, agent) end)

      # Task.await observes the caller's exit; the Reconciler receives its
      # own DOWN independently, so wait for that cleanup before starting again.
      assert_eventually(fn -> not Reconciler.claude_login_pending?(agent.id) end)
      assert {:ok, _} = AgentHost.claude_login_start(admin, agent)
      assert {:ok, _} = AgentHost.claude_login_submit(admin, agent, good_code())
    end
  end

  describe "through the real channel" do
    test "the code is unwrapped only in the push; the reply carries no code", %{
      owner: owner,
      agent: agent
    } do
      {:ok, socket} =
        connect(PlatformWeb.AgentHostSocket, %{},
          connect_info: %{x_headers: [{"x-agent-host-token", @token}]}
        )

      {:ok, _reply, channel} = subscribe_and_join(socket, "agent_host:control", %{})
      code = good_code()

      # One caller starts and submits; this test process plays the host.
      login =
        Task.async(fn ->
          {:ok, url} = AgentHost.claude_login_start(owner, agent)
          {url, AgentHost.claude_login_submit(owner, agent, code)}
        end)

      assert_push "agent.claude_login_start", %{"agent_id" => id, "ref" => ref}
      assert id == agent.id

      push(channel, "agent.claude_login", %{
        "ref" => ref,
        "agent_id" => id,
        "result" => "url",
        "url" => "https://claude.com/cai/oauth/authorize?code=true&state=s"
      })

      assert_push "agent.claude_login_code", %{"code" => raw, "ref" => code_ref}, 2_000
      # Unwrapped exactly here, as the push is serialised.
      assert raw == FakeHost.claude_login_code()

      push(channel, "agent.claude_login", %{
        "ref" => code_ref,
        "agent_id" => id,
        "result" => "ok",
        "account" => "owner@example.com",
        "plan" => "max",
        "code" => raw
      })

      assert {"https://claude.com/" <> _, {:ok, result}} = Task.await(login)
      assert result == %{account: "owner@example.com", plan: "max"}
    end

    test "the reply is sanitised: unknown results fail, foreign URLs are dropped" do
      reply = &PlatformWeb.AgentHostChannel.claude_login_reply/2

      assert reply.("url", %{"url" => "https://evil.example/claude.com?x"}) == %{
               "result" => "failed"
             }

      assert reply.("url", %{"url" => "http://claude.com/x?y"}) == %{"result" => "failed"}
      assert reply.("weird", %{}) == %{"result" => "failed"}
      assert reply.("ok", %{"account" => "a@example.com"}) == %{"result" => "ok"}

      assert reply.("bad_code", %{"code" => "x"}) == %{"result" => "bad_code"}
    end
  end

  describe "the dev stand-in host's stub" do
    test "one good code, anything else bad_code; the switch" do
      good = good_code()
      {:ok, wrong} = LoginCode.new("wrong#x")
      reply = &FakeHost.claude_login_reply/3

      assert %{"result" => "url", "url" => "https://claude.com/" <> _} =
               reply.("agent.claude_login_start", %{}, :ok)

      assert reply.("agent.claude_login_code", %{"code" => good}, :ok) == %{
               "result" => "ok",
               "account" => "owner@example.com",
               "plan" => "max"
             }

      assert reply.("agent.claude_login_code", %{"code" => wrong}, :ok) == %{
               "result" => "bad_code"
             }

      assert reply.("agent.claude_login_code", %{"code" => good}, :no_subscription) ==
               %{"result" => "no_subscription"}

      assert reply.("agent.claude_login_code", %{"code" => good}, :timeout) == nil
      assert {:error, :unknown_mode} = FakeHost.set_claude_login(:nope)
    end

    test "the dev route" do
      conn =
        Plug.Test.conn(:post, "/claude-login/nope")
        |> PlatformWeb.Dev.FakeAgentHost.call([])

      assert conn.status == 404

      conn =
        Plug.Test.conn(:post, "/claude-login/timeout")
        |> PlatformWeb.Dev.FakeAgentHost.call([])

      # The dev fake host is not running in test.
      assert conn.status == 503
    end
  end

  describe "login_view/1" do
    test "a claude_code agent with no key gets the subscription view", %{
      owner: owner,
      agent: agent
    } do
      assert NativeLogin.login_view(agent) == %{
               kind: :claude_subscription,
               account: nil,
               plan: nil
             }

      assert NativeLogin.login_view(agent, %{account: "owner@example.com", plan: "max"}) == %{
               kind: :claude_subscription,
               account: "owner@example.com",
               plan: "max"
             }

      :ok = NativeLogin.put_api_key(owner.id, agent, @key)
      assert NativeLogin.login_view(agent) == :api_key
    end

    test "pure: key_set? and operator mode" do
      assert NativeLogin.login_view("claude_code", nil, :api_key, key_set?: true) == :api_key

      assert %{kind: :claude_subscription} =
               NativeLogin.login_view("claude_code", nil, :api_key)

      assert NativeLogin.login_view("claude_code", nil, :operator) ==
               :subscription_terminal_only
    end
  end

  describe "the code never reaches a log" do
    setup do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)
      :ok
    end

    test "a full start and submit at :debug", %{owner: owner, agent: agent} do
      fake_host!()
      sentinel = FakeHost.claude_login_code()

      log =
        capture_log([level: :debug], fn ->
          {:ok, _url} = AgentHost.claude_login_start(owner, agent)
          {:ok, _} = AgentHost.claude_login_submit(owner, agent, good_code())

          # Positive control: the same sentinel in a logged non-secret field.
          require Logger
          Logger.debug("[ClaudeLoginTest] detail=#{sentinel}")
        end)

      [before_control | _] = String.split(log, "[ClaudeLoginTest] detail=")
      assert log =~ sentinel
      refute before_control =~ sentinel
      refute before_control =~ "fake-claude-login-code"
    end

    test "a crash of the process holding the code does not print it" do
      sentinel = "SENTINEL-CRASH-01a1b365#state"
      {:ok, code} = LoginCode.new(sentinel)

      log = capture_log([level: :debug], fn -> crash_holding(%{code: code}) end)
      # The report was printed, with the state and the failing lookup.
      assert log =~ "#LoginCode<redacted>"
      refute log =~ sentinel
      refute log =~ "SENTINEL-CRASH"

      # Positive control: the same sentinel in a non-secret field IS found by
      # the same capture.
      control = capture_log([level: :debug], fn -> crash_holding(%{detail: sentinel}) end)
      assert control =~ sentinel
    end
  end

  # Start a GenServer (an Agent) holding `state`, make it raise on a lookup
  # whose error message and crash report both print the state, and wait for it
  # to die.
  defp crash_holding(state) do
    {:ok, pid} = Agent.start(fn -> state end)
    mref = Process.monitor(pid)
    Agent.cast(pid, fn s -> Map.fetch!(s, :missing) end)
    assert_receive {:DOWN, ^mref, :process, ^pid, _reason}, 2_000
    # The report is written by the dying process; let the handler flush.
    Logger.flush()
  end
end
