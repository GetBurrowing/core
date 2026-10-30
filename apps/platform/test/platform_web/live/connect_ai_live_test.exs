defmodule PlatformWeb.ConnectAiLiveTest do
  @moduledoc """
  `/setup/connect-ai` (task 01a10315 stage 5), driven against the dev
  stand-in agent host (`Platform.AgentHost.FakeHost`), which joins the real
  reconciler: a codex agent waits at device code FAKE-1234 until completed,
  a Claude Code agent runs once its start carries an API key.

  Mutants these name:

    * render the options in a fixed order → "the option order follows config";
    * drop `target="_blank"` → the codex test;
    * render the device code from anything but the observed state → the codex
      test (FAKE-1234 only ever comes from the host);
    * stop subscribing to agent-host state → "turns connected by itself";
    * add any text input to the Claude panel → the Claude test;
    * skip `api_key_shape/1` → "a bad key is refused";
    * post the kickoff without the claim → "once across two transitions".
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.AsyncAssertions

  alias Platform.AgentHost.{FakeHost, Reconciler}
  alias Platform.Agents.{NativeLogin, SetupAgent}
  alias Platform.Chat.{Message, Participant, Space}
  alias Platform.Repo
  alias Platform.VaultFixtures

  @key "sk-ant-api03-" <> String.duplicate("k", 40) <> "CONNECTAI05tail"

  setup %{conn: conn} do
    fake = start_supervised!({FakeHost, report_after_ms: 0})
    assert_eventually(fn -> Reconciler.host_pid() == fake end, 3_000)
    admin = VaultFixtures.admin!()

    %{
      conn: Plug.Test.init_test_session(conn, %{"current_user_id" => admin.id}),
      admin: admin,
      fake: fake
    }
  end

  defp providers(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#connect-ai-options [data-provider]")
    |> Enum.map(&(&1 |> LazyHTML.attribute("data-provider") |> hd()))
  end

  defp choose(view, provider) do
    view |> form("#connect-ai-options") |> render_change(%{"provider" => provider})
  end

  test "a non-admin mount is redirected", %{conn: conn} do
    user = VaultFixtures.non_admin!()

    assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
             conn
             |> Plug.Test.init_test_session(%{"current_user_id" => user.id})
             |> live(~p"/setup/connect-ai")
  end

  test "the heading and the three options, ChatGPT first by default", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/setup/connect-ai")

    assert html =~ "Which subscription do you use?"
    assert providers(view) == ["codex", "api_key", "claude_subscription"]
    assert has_element?(view, "#connect-ai-option-codex", "ChatGPT (Codex)")
    assert has_element?(view, "#connect-ai-option-api_key", "API key")
    assert has_element?(view, "#connect-ai-option-claude_subscription", "Claude Pro or Max")
    assert has_element?(view, "#connect-ai-option-codex.ring-primary")
    refute html =~ "Suite"
  end

  test "the option order follows config", %{conn: conn} do
    previous = Application.get_env(:platform, PlatformWeb.ConnectAiLive)

    Application.put_env(:platform, PlatformWeb.ConnectAiLive,
      provider_order: [:claude_subscription, :api_key, :codex]
    )

    on_exit(fn -> Application.put_env(:platform, PlatformWeb.ConnectAiLive, previous) end)

    {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
    assert providers(view) == ["claude_subscription", "api_key", "codex"]
    assert has_element?(view, "#connect-ai-option-claude_subscription.ring-primary")
  end

  test "ChatGPT: the host's device code renders, sign-in opens in a new tab, and the screen turns connected by itself",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")

    assert_eventually(fn -> has_element?(view, "#connect-ai-code", "FAKE-1234") end, 3_000)
    agent = SetupAgent.get()
    assert SetupAgent.harness(agent) == "codex"

    assert has_element?(
             view,
             ~s(a#connect-ai-codex-open[href="https://auth.openai.com/codex/device"][target="_blank"][rel="noopener noreferrer"]),
             "Open ChatGPT sign-in"
           )

    html = render(view)
    assert html =~ "Opens in a new tab."
    assert html =~ "Enter this code there:"
    assert has_element?(view, "#connect-ai-status", "Waiting for sign-in...")
    assert has_element?(view, "#connect-ai-code-callout.bg-info\\/10")
    refute html =~ "<iframe"

    # The person signs in on OpenAI's page; nothing is clicked here.
    :ok = FakeHost.complete(agent.id)

    assert_eventually(fn -> has_element?(view, "#connect-ai-getting-started") end, 3_000)
    assert has_element?(view, "#connect-ai-status", "Setup is connected.")
    space = SetupAgent.getting_started_space(agent)

    assert has_element?(
             view,
             ~s(a#connect-ai-getting-started[href="/chat/#{space.slug}"]),
             "Go to Getting started"
           )

    refute render(view) =~ "<iframe"
  end

  test "Claude Pro or Max: no input but the radios, no iframe, terminal steps for the agent's account",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
    html = choose(view, "claude_subscription")

    assert has_element?(view, "#provider-panel-claude_subscription")
    # Positive control: the radios ARE inputs, outside the panel.
    assert has_element?(view, "#connect-ai-options input[type=radio]")
    refute has_element?(view, "#provider-panel-claude_subscription input:not([type=radio])")
    refute has_element?(view, "#provider-panel-claude_subscription textarea")
    refute has_element?(view, "#provider-panel-claude_subscription form")
    refute html =~ "<iframe"
    assert html =~ "needs a terminal"
    assert html =~ "We recommend ChatGPT (Codex) or an API key"
    assert has_element?(view, "details#connect-ai-claude-technical:not([open])")

    agent = assert_eventually(fn -> SetupAgent.get() end)
    assert SetupAgent.harness(agent) == "claude_code"
    os_user = "agent-" <> String.slice(agent.id, -12, 12)

    steps =
      view
      |> element("#connect-ai-claude-steps")
      |> render()

    assert steps =~ "ssh root@"
    assert steps =~ "sudo -iu #{os_user}"
    assert steps =~ "claude"
    assert steps =~ "/login"
  end

  test "API key: a bad key is refused, a good one is stored and never shown", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
    choose(view, "api_key")

    # A text input exists here (positive control for the Claude test above).
    assert has_element?(view, "#provider-panel-api_key input[type=password]")
    refute has_element?(view, "#connect-ai-api-key-input[value]")

    html =
      view
      |> form("#connect-ai-api-key-form", api_key: %{value: "not-a-key"})
      |> render_submit()

    assert html =~ "That is not an Anthropic API key."

    html =
      view
      |> form("#connect-ai-api-key-form", api_key: %{value: @key})
      |> render_submit()

    agent = SetupAgent.get()
    assert SetupAgent.harness(agent) == "claude_code"
    assert NativeLogin.api_key_set?(agent)
    refute html =~ @key
    refute html =~ "CONNECTAI05tail"

    # The fake host runs a Claude Code agent whose start carries a key.
    assert_eventually(fn -> has_element?(view, "#connect-ai-getting-started") end, 3_000)
    refute render(view) =~ "CONNECTAI05tail"
  end

  test "the Getting started space and its kickoff are created once across two running transitions",
       %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
    assert_eventually(fn -> has_element?(view, "#connect-ai-code") end, 3_000)
    agent = SetupAgent.get()

    :ok = FakeHost.complete(agent.id)
    assert_eventually(fn -> has_element?(view, "#connect-ai-getting-started") end, 3_000)

    # Second transition: a restart goes starting -> running again, seen by a
    # second screen and by a direct call.
    :ok = Platform.AgentHost.restart_agent(agent)
    assert_eventually(fn -> SetupAgent.running?(agent) end, 3_000)
    {:ok, view2, _html} = live(conn, ~p"/setup/connect-ai")
    assert has_element?(view2, "#connect-ai-getting-started")
    assert {:ok, _} = SetupAgent.ensure_getting_started(agent, admin)

    spaces = Repo.all(from(s in Space, where: s.slug == ^SetupAgent.space_slug(agent)))
    assert [%Space{name: "Getting started"} = space] = spaces

    kickoffs =
      Repo.all(
        from(m in Message,
          where:
            m.space_id == ^space.id and fragment("?->>'source'", m.metadata) == "setup_kickoff"
        )
      )

    assert length(kickoffs) == 1
    assert hd(kickoffs).content =~ "integrations"
    assert hd(kickoffs).content =~ "first space"

    members =
      Repo.all(
        from(p in Participant,
          where: p.space_id == ^space.id and p.participant_type in ["user", "agent"],
          select: {p.participant_type, p.participant_id}
        )
      )

    assert Enum.sort(members) == Enum.sort([{"user", admin.id}, {"agent", agent.id}])
  end

  test "the agent host being offline shows the plain-words failure and Retry", %{
    conn: conn,
    fake: fake
  } do
    {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
    assert_eventually(fn -> has_element?(view, "#connect-ai-code") end, 3_000)

    :ok = stop_supervised(FakeHost)
    refute Process.alive?(fake)

    assert_eventually(fn -> has_element?(view, "#connect-ai-failed") end, 3_000)
    assert render(view) =~ "isn&#39;t answering right now"
    assert has_element?(view, "#connect-ai-retry", "Retry")
    assert has_element?(view, "#connect-ai-failed.bg-error\\/10")
  end

  test "the Setup agent's instructions carry the setup guide", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
    assert_eventually(fn -> has_element?(view, "#connect-ai-code") end, 3_000)

    agents_md = Platform.Agents.MemoryContext.get_workspace_file(SetupAgent.get().id, "AGENTS.md")
    assert agents_md
    assert agents_md.content =~ "Helping your owner finish setup"
    assert agents_md.content =~ "Never ask them to open a terminal"

    refute Platform.Agents.NativeAgents.identity_template("Ada", "codex") =~
             "Helping your owner finish setup"
  end

  describe "the /admin card" do
    test "shows while the Setup agent is not connected and links here", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(
               view,
               ~s(a#admin-connect-ai-card[href="/setup/connect-ai"]),
               "Connect your AI"
             )
    end

    test "is gone once the Setup agent is connected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
      assert_eventually(fn -> has_element?(view, "#connect-ai-code") end, 3_000)
      :ok = FakeHost.complete(SetupAgent.get().id)
      assert_eventually(fn -> SetupAgent.connected?() end, 3_000)

      {:ok, admin_view, _html} = live(conn, ~p"/admin")
      refute has_element?(admin_view, "#admin-connect-ai-card")
    end
  end
end
