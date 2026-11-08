defmodule PlatformWeb.ConnectAi.PanelTest do
  @moduledoc """
  The per-agent Connect AI panel (task 01a1b84b stage 1), hosted the way the
  builder step and the agent page host it (`PlatformWeb.ConnectAiPanelHostLive`),
  driven against the dev stand-in host (`Platform.AgentHost.FakeHost`).

  Mutants these name:

    * schedule the start or the submit with `send/2` instead of `send_update/3`
      -> the happy path (the component has no handle_info; nothing starts);
    * drop `allowed?/2` from the claude_* events -> the B4 test (the fake
      host records a login command);
    * read Burrow's (or any other agent's) summary -> the B3 test;
    * offer Disconnect to a ChatGPT agent -> the Codex test;
    * render controls for a non-manager -> the B4 test.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.AsyncAssertions

  alias Platform.AgentHost
  alias Platform.AgentHost.{FakeHost, Reconciler}
  alias Platform.Agents.{AiConnect, Burrow, Character, NativeAgents}
  alias Platform.Repo
  alias Platform.VaultFixtures
  alias PlatformWeb.ConnectAiPanelHostLive

  setup %{conn: conn} do
    previous = Application.get_env(:platform, PlatformWeb.ConnectAiLive)

    Application.put_env(
      :platform,
      PlatformWeb.ConnectAiLive,
      Keyword.put(previous || [], :claude_login_timeout_ms, 500)
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, PlatformWeb.ConnectAiLive, previous),
        else: Application.delete_env(:platform, PlatformWeb.ConnectAiLive)
    end)

    fake = start_supervised!({FakeHost, report_after_ms: 0})
    assert_eventually(fn -> Reconciler.host_pid() == fake end, 3_000)
    owner = VaultFixtures.admin!()
    %{conn: conn, owner: owner, fake: fake}
  end

  defp character!(creator) do
    b =
      Character.new("scout")
      |> Map.merge(%{
        n: "Tester #{System.unique_integer([:positive])}",
        color: "indigo",
        portrait: "fox",
        sl: %{"chatty" => 20, "bold" => 80, "playful" => 10, "collab" => 90},
        traits: ["skeptic", "tidy", "night owl"],
        vc: %{p: 3, ov: %{"emoji" => 1}, q: "pr", free: nil}
      })

    {:ok, %{agent: agent}} = Character.create(b, creator)
    agent
  end

  defp panel(conn, agent, user) do
    {:ok, view, _html} =
      live_isolated(conn, ConnectAiPanelHostLive,
        session: %{"agent_id" => agent.id, "user_id" => user.id}
      )

    view
  end

  defp choose(view, provider) do
    view |> form("#agent-ai-options") |> render_change(%{"provider" => provider})
  end

  defp open_claude(view) do
    choose(view, "claude_subscription")
    assert_eventually(fn -> has_element?(view, "a#agent-ai-claude-open") end, 3_000)
    view |> element("a#agent-ai-claude-open") |> render_click()
  end

  defp submit_code(view, code),
    do: view |> form("#agent-ai-claude-form", %{"code" => code}) |> render_submit()

  defp state_text(view),
    do:
      inspect(:sys.get_state(view.pid),
        limit: :infinity,
        printable_limit: :infinity,
        structs: false
      )

  test "a builder agent: not connected, picking Claude adopts it, the good code connects it as the account",
       %{conn: conn, owner: owner} do
    agent = character!(owner)
    view = panel(conn, agent, owner)

    assert has_element?(view, ~s(#agent-ai-panel[data-connected="false"]))
    assert has_element?(view, "#agent-ai-option-claude_subscription")
    assert has_element?(view, "#agent-ai-option-codex")
    refute NativeAgents.managed?(Repo.reload!(agent))

    open_claude(view)
    assert NativeAgents.managed?(Repo.reload!(agent))
    assert NativeAgents.get_managed_runtime(Repo.reload!(agent)).harness == "claude_code"
    assert NativeAgents.get_managed_runtime(Repo.reload!(agent)).owner_user_id == owner.id

    code = FakeHost.claude_login_code()
    html = submit_code(view, code)
    assert html =~ "Connecting…"
    assert_push_event(view, "connect-ai-clear-code", %{})
    refute state_text(view) =~ code

    assert_eventually(
      fn ->
        has_element?(view, "#agent-ai-claude-connected", "Connected as owner@example.com")
      end,
      3_000
    )

    assert has_element?(view, "#agent-ai-claude-disconnect", "Disconnect")

    assert NativeAgents.ai_login(Repo.reload!(agent)) ==
             %{"provider" => "claude", "account" => "owner@example.com", "plan" => "max"}

    refute render(view) =~ code
    refute state_text(view) =~ code

    # A later page load reads the stored summary.
    assert_eventually(fn -> match?(%{state: :running}, AgentHost.status(agent)) end, 3_000)
    again = panel(conn, agent, owner)
    assert has_element?(again, "#agent-ai-claude-connected", "Connected as owner@example.com")
  end

  test "a bad code says so and fetches a fresh link", %{conn: conn, owner: owner} do
    view = panel(conn, character!(owner), owner)
    open_claude(view)
    submit_code(view, "not-the-code")

    assert_eventually(
      fn -> has_element?(view, ~s(#agent-ai-claude-error[data-reason="bad_code"])) end,
      3_000
    )

    assert_eventually(fn -> has_element?(view, "a#agent-ai-claude-open") end, 3_000)
    refute render(view) =~ "not-the-code"
  end

  test "an account with no Pro or Max plan says which account to use", %{
    conn: conn,
    owner: owner
  } do
    view = panel(conn, character!(owner), owner)
    :ok = FakeHost.set_claude_login(:no_subscription)
    open_claude(view)
    submit_code(view, FakeHost.claude_login_code())

    assert_eventually(
      fn -> has_element?(view, ~s(#agent-ai-claude-error[data-reason="no_subscription"])) end,
      3_000
    )
  end

  test "Disconnect logs this agent out, forgets the summary and offers a fresh sign-in",
       %{conn: conn, owner: owner, fake: fake} do
    agent = character!(owner)
    view = panel(conn, agent, owner)
    open_claude(view)
    submit_code(view, FakeHost.claude_login_code())
    assert_eventually(fn -> has_element?(view, "#agent-ai-claude-disconnect") end, 3_000)

    view |> element("#agent-ai-claude-disconnect") |> render_click()

    assert_eventually(fn -> has_element?(view, "a#agent-ai-claude-open") end, 3_000)
    refute has_element?(view, "#agent-ai-claude-connected")
    assert NativeAgents.ai_login(Repo.reload!(agent)) == nil
    assert "agent.claude_logout" in FakeHost.login_commands(agent.id, fake)
  end

  test "ChatGPT: the device code, then connected by itself, with no Disconnect", %{
    conn: conn,
    owner: owner
  } do
    agent = character!(owner)
    view = panel(conn, agent, owner)
    choose(view, "codex")

    assert_eventually(
      fn -> has_element?(view, "#agent-ai-code", FakeHost.device_code()) end,
      3_000
    )

    assert NativeAgents.get_managed_runtime(Repo.reload!(agent)).harness == "codex"

    :ok = FakeHost.complete(agent.id)

    assert_eventually(
      fn -> has_element?(view, "#agent-ai-codex-connected", "Connected to ChatGPT") end,
      3_000
    )

    refute has_element?(view, "#agent-ai-claude-disconnect")
    refute render(view) =~ "Disconnect"

    assert_eventually(
      fn -> NativeAgents.ai_login(Repo.reload!(agent)) == %{"provider" => "chatgpt"} end,
      3_000
    )
  end

  test "B3: with Burrow connected, a fresh adopted agent is not connected and has no summary",
       %{conn: conn, owner: owner} do
    {:ok, burrow} = Burrow.ensure(owner.id, "claude_code")

    :ok =
      Reconciler.agent_state(Reconciler.host_pid(), %{
        "agent_id" => burrow.id,
        "state" => "running"
      })

    assert_eventually(fn -> Burrow.connected?() end, 3_000)

    {:ok, _} =
      NativeAgents.put_ai_login(burrow, %{
        "provider" => "claude",
        "account" => "burrow@example.com"
      })

    {:ok, agent} = NativeAgents.adopt(owner, character!(owner), "claude_code")
    view = panel(conn, agent, owner)

    assert has_element?(view, ~s(#agent-ai-panel[data-connected="false"]))
    refute has_element?(view, "#agent-ai-connected")
    refute render(view) =~ "burrow@example.com"
    assert NativeAgents.ai_login(Repo.reload!(agent)) == nil
    # No "use Burrow's account" shortcut: the only choices are the providers.
    assert has_element?(view, "#agent-ai-option-claude_subscription")
    refute render(view) =~ "Burrow's account"
  end

  test "B4: a member who does not manage the agent sees no controls, and every forged event is refused",
       %{conn: conn, owner: owner, fake: fake} do
    {:ok, agent} = NativeAgents.adopt(owner, character!(owner), "claude_code")
    member = VaultFixtures.non_admin!()
    refute NativeAgents.can_manage?(member, agent)

    view = panel(conn, agent, member)
    assert has_element?(view, "#agent-ai-not-connected")
    refute has_element?(view, "#agent-ai-options")
    refute has_element?(view, "#agent-ai-claude-card")

    target = with_target(view, "#agent-ai-panel")
    code = FakeHost.claude_login_code()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        render_hook(target, "claude_opened", %{})
        render_hook(target, "claude_submit", %{"code" => code})
        render_hook(target, "claude_retry_link", %{})
        render_hook(target, "claude_disconnect", %{})
        render_hook(target, "select", %{"provider" => "codex"})
        render_hook(target, "select", %{"provider" => "claude_subscription"})
      end)

    assert FakeHost.login_commands(agent.id, fake) == []
    assert NativeAgents.get_managed_runtime(Repo.reload!(agent)).harness == "claude_code"
    assert NativeAgents.get_managed_runtime(Repo.reload!(agent)).owner_user_id == owner.id
    assert NativeAgents.get_managed_runtime(Repo.reload!(agent)).desired_state == "stopped"
    assert log =~ ~s(refused "claude_submit")
    refute log =~ code
    refute state_text(view) =~ code
    assert Process.alive?(view.pid)

    # Positive control: the owner's own event does reach the host.
    owner_view = panel(conn, agent, owner)
    open_claude(owner_view)
    assert "agent.claude_login_start" in FakeHost.login_commands(agent.id, fake)
  end

  test "B4: a member cannot adopt the owner's builder agent through the panel", %{
    conn: conn,
    owner: owner
  } do
    agent = character!(owner)
    member = VaultFixtures.non_admin!()
    view = panel(conn, agent, member)

    refute has_element?(view, "#agent-ai-options")

    render_hook(with_target(view, "#agent-ai-panel"), "select", %{
      "provider" => "claude_subscription"
    })

    refute NativeAgents.managed?(Repo.reload!(agent))
  end

  test "an unknown event is refused and only its name is logged", %{conn: conn, owner: owner} do
    view = panel(conn, character!(owner), owner)
    code = FakeHost.claude_login_code()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        render_hook(with_target(view, "#agent-ai-panel"), "paste_claude_code", %{"code" => code})
      end)

    assert log =~ ~s(refused unknown event "paste_claude_code")
    refute log =~ code
    assert Process.alive?(view.pid)
  end

  test "prepare is what the panel runs: a prepared agent shows its provider", %{
    conn: conn,
    owner: owner
  } do
    {:ok, agent} = AiConnect.prepare(owner, character!(owner), :codex)
    view = panel(conn, agent, owner)

    assert_eventually(
      fn -> has_element?(view, "#agent-ai-code", FakeHost.device_code()) end,
      3_000
    )
  end
end
