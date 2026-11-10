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
    * skip `api_key_shape/1` → "a bad key is refused";
    * post the kickoff without the claim → "once across two transitions";
    * `assign(socket, :code, code)` in the Claude submit handler → "the code
      is never assigned";
    * `phx-change` on the Claude code form → "no keystroke reaches the
      server" (task 01a1b365 stage 3).
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.AsyncAssertions

  alias Platform.AgentHost.{FakeHost, Reconciler}
  alias Platform.Agents.{AgentRuntime, Burrow, NativeAgents, NativeLogin}
  alias Platform.Agents.Burrow.GettingStarted
  alias Platform.Chat.{Message, Participant, Space}
  alias Platform.Repo
  alias Platform.VaultFixtures

  # The dev stand-in host's sign-in URL (Platform.AgentHost.FakeHost).
  @claude_url "https://claude.com/cai/oauth/authorize?code=true&state=fake-agent-host"
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

  defp choose(view, "api_key") do
    view |> element("#connect-ai-api-key-link") |> render_click()
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

  test "the heading, the two subscriptions (ChatGPT first by default) and a quiet API key link",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/setup/connect-ai")

    assert html =~ "Which subscription do you use?"
    assert providers(view) == ["codex", "claude_subscription"]
    assert has_element?(view, "#connect-ai-option-codex", "ChatGPT (Codex)")
    assert has_element?(view, "#connect-ai-option-claude_subscription", "Claude Pro or Max")
    refute has_element?(view, "#connect-ai-option-api_key")
    assert has_element?(view, "#connect-ai-option-codex.ring-primary")

    # The key is a text link, never a primary button.
    assert has_element?(view, "button#connect-ai-api-key-link", "Have an API key instead?")
    refute has_element?(view, "#connect-ai-api-key-link.btn")
    refute has_element?(view, "#connect-ai-api-key-link.btn-primary")
    refute has_element?(view, "#provider-panel-api_key")

    choose(view, "api_key")
    assert has_element?(view, "#provider-panel-api_key #connect-ai-api-key-form")
    refute html =~ "Suite"
  end

  test "the option order follows config", %{conn: conn} do
    previous = Application.get_env(:platform, PlatformWeb.ConnectAiLive)

    Application.put_env(:platform, PlatformWeb.ConnectAiLive,
      provider_order: [:claude_subscription, :api_key, :codex]
    )

    on_exit(fn -> Application.put_env(:platform, PlatformWeb.ConnectAiLive, previous) end)

    {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
    # The :api_key entry is accepted and left out of the choices.
    assert providers(view) == ["claude_subscription", "codex"]
    assert has_element?(view, "#connect-ai-option-claude_subscription.ring-primary")
  end

  test "ChatGPT: the host's device code renders, sign-in opens in a new tab, and the screen turns connected by itself",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")

    assert_eventually(fn -> has_element?(view, "#connect-ai-code", "FAKE-1234") end, 3_000)
    agent = Burrow.get()
    assert Burrow.harness(agent) == "codex"

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

    # The same two-step card as Claude's.
    assert has_element?(view, "#connect-ai-codex-card #connect-ai-codex-step-1 .bg-base-200", "1")
    assert has_element?(view, "#connect-ai-codex-card #connect-ai-codex-step-2 .bg-base-200", "2")
    assert has_element?(view, "#connect-ai-codex-step-1", "Sign in to ChatGPT.")
    assert has_element?(view, "#connect-ai-codex-step-2 #connect-ai-code-callout")

    # The person signs in on OpenAI's page; nothing is clicked here.
    :ok = FakeHost.complete(agent.id)

    assert_eventually(fn -> has_element?(view, "#connect-ai-getting-started") end, 3_000)
    assert has_element?(view, "#connect-ai-status", "Burrow is connected.")

    assert has_element?(
             view,
             "#connect-ai-codex-connected.flex .text-success",
             "Connected to ChatGPT"
           )

    space = GettingStarted.getting_started_space(agent)

    assert has_element?(
             view,
             ~s(a#connect-ai-getting-started[href="/chat/#{space.slug}"]),
             "Go to Getting started"
           )

    refute render(view) =~ "<iframe"
  end

  describe "Claude Pro or Max: two steps, open Claude and paste the code (task 01a1b365)" do
    defp open_claude(conn) do
      {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
      choose(view, "claude_subscription")
      assert_eventually(fn -> has_element?(view, "a#connect-ai-claude-open") end, 3_000)
      view
    end

    defp click_open(view) do
      view |> element("a#connect-ai-claude-open") |> render_click()
    end

    defp submit_code(view, code) do
      view |> form("#connect-ai-claude-form", %{"code" => code}) |> render_submit()
    end

    defp panel_text(view) do
      view
      |> element("#provider-panel-claude_subscription")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
    end

    # The whole LiveView process state, structs flattened, so a LoginCode's
    # redacted Inspect cannot hide one.
    defp state_text(view) do
      inspect(:sys.get_state(view.pid),
        limit: :infinity,
        printable_limit: :infinity,
        structs: false
      )
    end

    defp with_short_login_timeout(_context) do
      previous = Application.get_env(:platform, PlatformWeb.ConnectAiLive)

      Application.put_env(
        :platform,
        PlatformWeb.ConnectAiLive,
        Keyword.put(previous || [], :claude_login_timeout_ms, 300)
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:platform, PlatformWeb.ConnectAiLive, previous),
          else: Application.delete_env(:platform, PlatformWeb.ConnectAiLive)
      end)

      :ok
    end

    setup :with_short_login_timeout

    test "start: the heading, the card, a one-click link to Claude in a new tab, step 2 locked",
         %{conn: conn} do
      view = open_claude(conn)

      agent = Burrow.get()
      assert Burrow.harness(agent) == "claude_code"

      assert has_element?(
               view,
               "h2#connect-ai-claude-heading",
               "Connect your Claude subscription"
             )

      assert has_element?(
               view,
               "#connect-ai-claude-subhead",
               "Use your Claude Pro or Max plan. No API key needed."
             )

      assert has_element?(view, "ol#connect-ai-claude-card.bg-base-100")
      assert has_element?(view, "#connect-ai-claude-step-1 .bg-base-200", "1")
      assert has_element?(view, "#connect-ai-claude-step-2 .bg-base-200", "2")
      assert has_element?(view, "#connect-ai-claude-step-1", "Sign in to Claude")

      assert has_element?(
               view,
               "#connect-ai-claude-step-1",
               "Opens claude.ai in a new tab. Sign in with the account that has your Pro or Max plan."
             )

      # The host's own sign-in URL, fetched when the option was chosen: one
      # click opens it. A plain link, no popup, no frame.
      assert has_element?(
               view,
               ~s(a#connect-ai-claude-open.btn-primary[href="#{@claude_url}"][target="_blank"][rel="noopener noreferrer"]),
               "Open Claude sign-in ↗"
             )

      refute render(view) =~ "<iframe"
      refute render(view) =~ "window.open"

      assert has_element?(view, "#connect-ai-claude-step-2", "Paste the code Claude shows you")
      assert has_element?(view, "#connect-ai-claude-step-2.opacity-60")
      assert has_element?(view, "#connect-ai-claude-locked", "Do step 1 first.")
      assert has_element?(view, "#connect-ai-claude-code[disabled]")
      assert has_element?(view, "#connect-ai-claude-connect[disabled]", "Connect")
      refute has_element?(view, "#connect-ai-claude-waiting")

      assert has_element?(
               view,
               "#connect-ai-claude-reassurance",
               "The code goes straight to your Burrow and is not kept."
             )

      text = String.downcase(panel_text(view))

      for word <- ["oauth", "token", "/login", "ssh", "sudo", "terminal"] do
        refute text =~ word, "the Claude panel says #{inspect(word)}"
      end

      # Positive control: the text read is the panel's.
      assert text =~ "paste the code claude shows you"
    end

    test "the code field: masked, no value, never autocompleted, and no keystroke reaches the server",
         %{conn: conn} do
      view = open_claude(conn)

      # Positive control: the form and its submit exist.
      assert has_element?(view, ~s(form#connect-ai-claude-form[phx-submit="claude_submit"]))
      refute has_element?(view, "#connect-ai-claude-form[phx-change]")
      refute has_element?(view, "#connect-ai-claude-form [phx-change]")
      refute has_element?(view, "#connect-ai-claude-form [phx-keyup]")
      refute has_element?(view, "#connect-ai-claude-form [phx-keydown]")
      refute has_element?(view, "#connect-ai-claude-form [phx-blur]")

      assert has_element?(
               view,
               ~s(input#connect-ai-claude-code.font-mono[type="password"][name="code"][autocomplete="off"][spellcheck="false"])
             )

      refute has_element?(view, "#connect-ai-claude-code[value]")

      # The show toggle is the hook's, in the browser: no server event.
      assert has_element?(view, ~s(#connect-ai-claude-form[phx-hook="ConnectAiCode"]))

      assert has_element?(
               view,
               ~s(button#connect-ai-claude-code-toggle[type="button"][data-code-toggle])
             )

      refute has_element?(view, "#connect-ai-claude-code-toggle[phx-click]")
    end

    test "after the click: Opened in a new tab, Open it again, step 2 active and waiting",
         %{conn: conn} do
      view = open_claude(conn)
      click_open(view)

      assert has_element?(view, "#connect-ai-claude-opened", "Opened in a new tab")

      assert has_element?(
               view,
               ~s(#connect-ai-claude-opened a#connect-ai-claude-open-again[target="_blank"][rel="noopener noreferrer"][href^="https://claude.com/"]),
               "Open it again"
             )

      refute has_element?(view, "a#connect-ai-claude-open")
      refute has_element?(view, "#connect-ai-claude-locked")
      refute has_element?(view, "#connect-ai-claude-step-2.opacity-60")
      refute has_element?(view, "#connect-ai-claude-code[disabled]")
      refute has_element?(view, "#connect-ai-claude-connect[disabled]")
      assert has_element?(view, "#connect-ai-claude-waiting.text-info", "Waiting for the code…")
    end

    test "happy path: the code is wrapped, cleared, never assigned, and the screen says Connected as the account",
         %{conn: conn} do
      view = open_claude(conn)
      click_open(view)
      code = FakeHost.claude_login_code()
      html = submit_code(view, code)

      # The field is cleared in the browser.
      assert_push_event(view, "connect-ai-clear-code", %{})
      refute html =~ code

      # The code is never assigned. Positive control: the state is the view's.
      state = state_text(view)
      assert state =~ "claude_subscription"
      refute state =~ code
      refute state =~ "fake-claude-login-code"
      refute state =~ "AgentHost.LoginCode"

      assert_eventually(
        fn ->
          has_element?(
            view,
            "#connect-ai-claude-connected .text-success",
            "Connected as owner@example.com · Claude Max"
          )
        end,
        3_000
      )

      assert has_element?(view, "#connect-ai-claude-disconnect.btn-ghost", "Disconnect")
      assert_eventually(fn -> has_element?(view, "#connect-ai-getting-started") end, 3_000)
      refute render(view) =~ code
      refute state_text(view) =~ code
    end

    test "Connecting… shows while the host answers, with Connect disabled", %{conn: conn} do
      view = open_claude(conn)
      click_open(view)
      # The host answers nothing: the screen stays on Connecting… until the
      # (shortened) wait ends.
      :ok = FakeHost.set_claude_login(:timeout)
      html = submit_code(view, FakeHost.claude_login_code())

      assert html =~ "Connecting…"
      assert html =~ ~s(id="connect-ai-claude-connecting")
      doc = LazyHTML.from_fragment(html)
      assert doc |> LazyHTML.query("#connect-ai-claude-connect[disabled]") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#connect-ai-claude-connecting.text-info") |> Enum.count() == 1
    end

    test "a bad code: the plain-words failure, and a fresh sign-in link for Open Claude sign-in again",
         %{conn: conn} do
      view = open_claude(conn)
      click_open(view)
      submit_code(view, "not-the-code")

      assert_eventually(
        fn ->
          has_element?(
            view,
            "#connect-ai-claude-error.text-error",
            "That code didn't work. Codes expire after a few minutes. Open Claude sign-in again and paste the new code."
          )
        end,
        3_000
      )

      # A new start: the button is back, and step 2 stays open.
      assert_eventually(fn -> has_element?(view, "a#connect-ai-claude-open") end, 3_000)
      refute has_element?(view, "#connect-ai-claude-code[disabled]")
      refute render(view) =~ "not-the-code"
    end

    test "a code the host has no login for reads as a bad code", %{conn: conn} do
      view = open_claude(conn)
      click_open(view)
      # A code that is not shaped like one never leaves this view.
      submit_code(view, "has spaces in it")

      assert has_element?(view, ~s(#connect-ai-claude-error[data-reason="bad_code"]))
    end

    test "an account with no Pro or Max plan says which account to use", %{conn: conn} do
      view = open_claude(conn)
      :ok = FakeHost.set_claude_login(:no_subscription)
      click_open(view)
      submit_code(view, FakeHost.claude_login_code())

      assert_eventually(
        fn ->
          has_element?(
            view,
            "#connect-ai-claude-error.text-error",
            "This account doesn't have Claude Pro or Max. Sign in with the account that does."
          )
        end,
        3_000
      )
    end

    test "a server that does not answer says to try again, then ask Burrow support", %{conn: conn} do
      view = open_claude(conn)
      click_open(view)
      :ok = FakeHost.set_claude_login(:timeout)
      submit_code(view, FakeHost.claude_login_code())

      assert_eventually(
        fn ->
          has_element?(
            view,
            "#connect-ai-claude-error.text-error",
            "Burrow didn't answer. Try again in a minute. If it keeps happening, ask Burrow support."
          )
        end,
        3_000
      )

      # The fresh start times out too: step 1 offers Try again.
      assert_eventually(fn -> has_element?(view, "#connect-ai-claude-retry-link") end, 3_000)
      :ok = FakeHost.set_claude_login(:ok)
      view |> element("#connect-ai-claude-retry-link") |> render_click()
      assert_eventually(fn -> has_element?(view, "a#connect-ai-claude-open") end, 3_000)
    end

    test "Disconnect logs the agent out and offers a fresh sign-in", %{conn: conn} do
      view = open_claude(conn)
      click_open(view)
      submit_code(view, FakeHost.claude_login_code())
      assert_eventually(fn -> has_element?(view, "#connect-ai-claude-disconnect") end, 3_000)

      view |> element("#connect-ai-claude-disconnect") |> render_click()

      assert_eventually(fn -> has_element?(view, "a#connect-ai-claude-open") end, 3_000)
      refute has_element?(view, "#connect-ai-claude-connected")
    end

    test "an unknown event is refused, and only its name is logged", %{conn: conn} do
      view = open_claude(conn)
      code = FakeHost.claude_login_code()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          render_hook(view, "paste_claude_code", %{"code" => code, "other" => code})
          # Positive control: the view is still up and answering.
          assert has_element?(view, "a#connect-ai-claude-open")
        end)

      assert log =~ "refused unknown event"
      assert log =~ "paste_claude_code"
      refute log =~ code
      refute log =~ "fake-claude-login-code"
      assert Process.alive?(view.pid)
    end
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

    agent = Burrow.get()
    assert Burrow.harness(agent) == "claude_code"
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
    agent = Burrow.get()

    :ok = FakeHost.complete(agent.id)
    assert_eventually(fn -> has_element?(view, "#connect-ai-getting-started") end, 3_000)

    # Second transition: a restart goes starting -> running again, seen by a
    # second screen and by a direct call.
    :ok = Platform.AgentHost.restart_agent(agent)
    assert_eventually(fn -> Burrow.running?(agent) end, 3_000)
    {:ok, view2, _html} = live(conn, ~p"/setup/connect-ai")
    assert has_element?(view2, "#connect-ai-getting-started")
    assert {:ok, _} = GettingStarted.ensure_getting_started(agent, admin)

    spaces = Repo.all(from(s in Space, where: s.slug == ^GettingStarted.space_slug(agent)))
    assert [%Space{name: "Getting started"} = space] = spaces

    kickoffs =
      Repo.all(
        from(m in Message,
          where:
            m.space_id == ^space.id and fragment("?->>'source'", m.metadata) == "setup_kickoff"
        )
      )

    assert length(kickoffs) == 1
    refute hd(kickoffs).content =~ "integrations"
    assert hd(kickoffs).content =~ "first project"
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

  test "Burrow's instructions carry the setup guide", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
    assert_eventually(fn -> has_element?(view, "#connect-ai-code") end, 3_000)

    agents_md = Platform.Agents.MemoryContext.get_workspace_file(Burrow.get().id, "AGENTS.md")
    assert agents_md
    assert agents_md.content =~ "Helping your owner finish setup"
    assert agents_md.content =~ "Never ask them to open a terminal"

    refute Platform.Agents.NativeAgents.identity_template("Ada", "codex") =~
             "Helping your owner finish setup"
  end

  defp with_agent_host_token(_context) do
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, "test-host-token")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)

    :ok
  end

  defp agents_md(agent) do
    Platform.Agents.MemoryContext.get_workspace_file(agent.id, "AGENTS.md")
  end

  describe "one first agent, named Burrow, on the provider chosen (task 01a19505)" do
    setup :with_agent_host_token

    test "ChatGPT first: exactly one native agent, named Burrow, running codex, holding the first-agent grant",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
      assert_eventually(fn -> has_element?(view, "#connect-ai-code", "FAKE-1234") end, 3_000)

      assert [%{agent: agent, runtime: runtime}] = NativeAgents.list()
      assert agent.name == "Burrow"
      assert agent.slug == "burrow"
      assert runtime.harness == "codex"
      assert Repo.get!(AgentRuntime, runtime.id).metadata["first_agent_grant"] == true
    end

    test "API key first: exactly one native agent, named Burrow, running claude_code, holding the first-agent grant",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
      choose(view, "api_key")

      view
      |> form("#connect-ai-api-key-form", api_key: %{value: @key})
      |> render_submit()

      assert [%{agent: agent, runtime: runtime}] = NativeAgents.list()
      assert agent.name == "Burrow"
      assert agent.slug == "burrow"
      assert runtime.harness == "claude_code"
      assert Repo.get!(AgentRuntime, runtime.id).metadata["first_agent_grant"] == true
    end

    test "first login then connect-ai with Codex leaves exactly one agent", %{conn: conn} do
      n = System.unique_integer([:positive])

      {:ok, owner} =
        Platform.Accounts.find_or_create_from_oidc(%{
          sub: "oidc-connect-ai-first-login-#{n}",
          email: "connect-ai-first-login-#{n}@example.com",
          name: "Connect AI Owner #{n}"
        })

      {:ok, _} = Platform.Tenancy.promote_to_admin(owner)

      # The login started nothing that creates an agent: whatever it put under
      # the task supervisor has finished, and there is still no agent.
      assert :ok = Platform.SandboxHelpers.await_supervised_writes()
      assert NativeAgents.list() == []

      conn = Plug.Test.init_test_session(conn, %{"current_user_id" => owner.id})
      {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
      choose(view, "codex")
      assert_eventually(fn -> has_element?(view, "#connect-ai-code", "FAKE-1234") end, 3_000)

      assert [%{agent: %{name: "Burrow"}, runtime: %{harness: "codex"}}] = NativeAgents.list()
    end

    test "a second agent the owner creates is not Burrow and gets no setup guide", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
      assert_eventually(fn -> has_element?(view, "#connect-ai-code") end, 3_000)
      burrow = Burrow.get()

      {:ok, helper, helper_runtime} =
        NativeAgents.create(admin.id, %{name: "Helper", harness: "codex"})

      refute Burrow.burrow?(helper)
      refute agents_md(helper).content =~ "## Helping your owner finish setup"
      assert agents_md(burrow).content =~ "## Helping your owner finish setup"
      refute Map.has_key?(helper_runtime.metadata || %{}, "first_agent_grant")
      assert Burrow.get().id == burrow.id
    end

    test "an install that already has an unconnected Claude Burrow reuses it when the owner picks ChatGPT",
         %{conn: conn, admin: admin} do
      {:ok, legacy, _runtime} =
        NativeAgents.create(admin.id, %{name: "Burrow", harness: "claude_code"})

      {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
      choose(view, "codex")
      assert_eventually(fn -> has_element?(view, "#connect-ai-code", "FAKE-1234") end, 3_000)

      assert [%{agent: agent, runtime: runtime}] = NativeAgents.list()
      assert agent.id == legacy.id
      assert runtime.harness == "codex"
      assert agents_md(agent).content =~ "## Helping your owner finish setup"
    end
  end

  describe "the /admin card" do
    test "shows while Burrow is not connected and links here", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(
               view,
               ~s(a#admin-connect-ai-card[href="/setup/connect-ai"]),
               "Connect your AI"
             )
    end

    test "is gone once Burrow is connected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
      assert_eventually(fn -> has_element?(view, "#connect-ai-code") end, 3_000)
      :ok = FakeHost.complete(Burrow.get().id)
      assert_eventually(fn -> Burrow.connected?() end, 3_000)

      {:ok, admin_view, _html} = live(conn, ~p"/admin")
      refute has_element?(admin_view, "#admin-connect-ai-card")
    end
  end

  describe "the hand-over passkey card (stage 6 round 2)" do
    test "an owner signed in through the hand-over link is offered a passkey on the sign-in host",
         %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, %{"signed_in_with_link" => true})
      {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")

      assert has_element?(
               view,
               ~s(#connect-ai-passkey-link[href="https://issuer.example.com/settings/account"][target="_blank"][rel="noopener noreferrer"]),
               "Set up Face ID or device unlock"
             )
    end

    test "any other sign-in shows no passkey card", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")
      refute has_element?(view, "#connect-ai-passkey")
    end
  end

  describe "while Burrow runs on the starter allowance" do
    setup %{admin: admin} do
      Application.put_env(
        :platform,
        :starter_anthropic_api_key,
        "sk-ant-api03-" <> String.duplicate("s", 40) <> "STARTERKEYtail"
      )

      on_exit(fn -> Application.delete_env(:platform, :starter_anthropic_api_key) end)
      {:ok, _space} = Platform.Agents.Burrow.Starter.provision(admin)
      :ok
    end

    test "the page offers the choices with none selected and starts nothing", %{conn: conn} do
      agent = Burrow.get()
      {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")

      assert providers(view) == ["codex", "claude_subscription"]
      refute has_element?(view, "#connect-ai-option-codex.ring-primary")
      refute has_element?(view, "#connect-ai-option-claude_subscription.ring-primary")
      assert has_element?(view, "#connect-ai-back-to-getting-started")
      assert Burrow.Starter.state(agent) == "active"
    end

    test "choosing ChatGPT retires the starter", %{conn: conn} do
      agent = Burrow.get()
      {:ok, view, _html} = live(conn, ~p"/setup/connect-ai")

      choose(view, "codex")

      assert Burrow.Starter.state(agent) == "retired"
      assert Burrow.harness(agent) == "codex"
    end

    test "/admin keeps the Connect your AI card", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      assert has_element?(view, "#admin-connect-ai-card")
    end
  end
end
