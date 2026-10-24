defmodule PlatformWeb.ControlCenter.NativeAgentsLiveTest do
  @moduledoc """
  Native (install-managed) agents on Agent Resources (task 01a10322 stage 4).

  The agent host is THIS test process: it joins the reconciler with
  `Reconciler.host_joined/2`, so every command core sends arrives here as
  `{:agent_host_push, event, payload}`, and every observed state is reported
  through `Reconciler.agent_state/2` exactly as the real host's channel does.
  No agent-host daemon runs.

  Mutants these name:

    * delete the `can_manage?/2` check in `NativeAgentEvents.handle/3` →
      "a non-manager's Start is refused server-side" goes red: the desired
      state flips to running and an `agent.start` is pushed;
    * show the row button for a running agent → the running-row case fails;
    * render the regenerate-token control for a managed agent → the panels
      case fails;
    * drop the `AgentHost.subscribe/0` in mount → the live re-render case
      fails.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.AgentHost.Reconciler
  alias Platform.Agents.{Agent, AgentRuntime, NativeAgents}
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ──────────────────────────────────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "native-lv-#{label}-#{n}@example.com",
      name: "Native LV #{label} #{n}",
      oidc_sub: "oidc-native-lv-#{label}-#{n}"
    })
  end

  defp member!(role) do
    user = user!(role)

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: role
    })
    |> Repo.insert!()

    user
  end

  defp as(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp native!(owner, name, desired \\ "stopped") do
    {:ok, agent, runtime} = NativeAgents.create(owner.id, %{name: name, harness: "claude_code"})
    {:ok, runtime} = NativeAgents.set_desired_state(runtime, desired)
    {agent, runtime}
  end

  # This process becomes the install's one agent host.
  defp join_host!(profile \\ "contained") do
    :ok = Reconciler.host_joined(self(), %{"profile" => profile})
  end

  defp observe!(%Agent{id: id}, state, extra \\ %{}) do
    :ok = Reconciler.agent_state(self(), Map.merge(%{"agent_id" => id, "state" => state}, extra))
  end

  defp row(view, slug), do: element(view, "#agent-row-#{slug}")

  defp row_state(html, slug) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#agent-row-#{slug}")
    |> LazyHTML.attribute("data-row-state")
    |> List.first()
  end

  defp row_text(view, slug),
    do: view |> row(slug) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  defp has_row_action?(view, slug),
    do: has_element?(view, "#agent-row-#{slug} [data-role=row-action]")

  defp desired(%Agent{} = agent), do: NativeAgents.get_managed_runtime(agent).desired_state

  setup do
    # An install with an agent host configured, so "not connected" is the
    # state when no host has joined (without a token it is "No agent host
    # configured").
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, "agent-host-token-01a10322-s4-live")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)

    owner = member!("member")
    %{owner: owner}
  end

  # ── Rows ──────────────────────────────────────────────────────────

  describe "every row state, driven from the host's observations" do
    test "each state has its tag and its one button", %{conn: conn, owner: owner} do
      join_host!()

      {needs_login, _} = native!(owner, "Nell", "running")
      {crashed, _} = native!(owner, "Cass", "running")
      {stopped, _} = native!(owner, "Stan")
      {starting, _} = native!(owner, "Tess", "running")
      {running, _} = native!(owner, "Rune", "running")
      {to_apply, _} = native!(owner, "Appa", "running")
      {unreported_stopped, _} = native!(owner, "Una")
      {unreported_running, _} = native!(owner, "Ura", "running")

      observe!(needs_login, "needs_login", %{
        "login" => %{"step" => "login", "url" => "https://claude.ai/oauth/authorize?x=1"}
      })

      observe!(crashed, "crashed", %{"detail" => "the agent kept exiting"})
      observe!(stopped, "stopped")
      observe!(starting, "starting")
      observe!(running, "running")
      # Stage 5: the host applied CLAUDE.md at version 0; the stored one is 1.
      observe!(to_apply, "running", %{
        "files_applied" => %{"CLAUDE.md" => 0, ".claude/settings.json" => 1}
      })

      {:ok, view, html} = live(as(conn, owner), ~p"/control")

      # Needs login: warning fill, black text, Log in opens the detail pane's
      # login steps (stage 6), never the login page the host reported.
      assert row_state(html, needs_login.slug) == "needs_login"

      assert has_element?(
               view,
               "#agent-row-#{needs_login.slug} [data-role=row-tag].bg-warning.text-warning-content",
               "Needs login"
             )

      assert has_element?(
               view,
               ~s{#agent-row-#{needs_login.slug} a[data-role=row-action][href="/control/#{needs_login.slug}"]},
               "Log in"
             )

      refute html =~ "claude.ai/oauth/authorize"

      # Crashed: the error icon and the word, and Restart.
      assert row_state(html, crashed.slug) == "crashed"

      assert has_element?(
               view,
               "#agent-row-#{crashed.slug} [data-role=row-tag] .hero-exclamation-circle.text-error"
             )

      assert row_text(view, crashed.slug) =~ "Crashed"
      assert has_element?(view, "#agent-row-#{crashed.slug} [data-role=row-action]", "Restart")

      # Stopped: a status, so body text (task 01a15902 stage 3), and Start.
      assert row_state(html, stopped.slug) == "stopped"

      assert has_element?(
               view,
               "#agent-row-#{stopped.slug} [data-role=row-tag].text-base-content",
               "Stopped"
             )

      assert has_element?(view, "#agent-row-#{stopped.slug} [data-role=row-action]", "Start")

      # Starting: grey text, the button disabled at the same width.
      assert row_state(html, starting.slug) == "starting"
      assert row_text(view, starting.slug) =~ "Starting"

      assert has_element?(
               view,
               "#agent-row-#{starting.slug} button[data-role=row-action][disabled].w-20"
             )

      # Running: no tag, no button, green dot.
      assert row_state(html, running.slug) == "running"
      refute has_element?(view, "#agent-row-#{running.slug} [data-role=row-tag]")
      refute has_row_action?(view, running.slug)
      assert has_element?(view, "#agent-row-#{running.slug} .bg-success")

      # Restart to apply: the lowest tag, with Restart.
      assert has_element?(
               view,
               "#agent-row-#{to_apply.slug} [data-role=row-tag]",
               "Restart to apply"
             )

      assert has_element?(view, "#agent-row-#{to_apply.slug} [data-role=row-action]", "Restart")

      # Not reported yet: the desired state decides.
      assert row_state(html, unreported_stopped.slug) == "stopped"
      assert row_state(html, unreported_running.slug) == "starting"

      # Every native row says where it runs, in the meta line.
      for agent <- [needs_login, crashed, stopped, running] do
        assert has_element?(
                 view,
                 "#agent-row-#{agent.slug} [data-role=row-meta]",
                 "Claude Code on this server"
               )
      end

      # The row's tap target is the link; the button sits outside it.
      refute has_element?(view, "#agent-row-#{stopped.slug} a [data-role=row-action]")
    end

    test "the needs_login row keeps only an https login page", %{conn: conn, owner: owner} do
      join_host!()
      {agent, _} = native!(owner, "Jay", "running")

      observe!(agent, "needs_login", %{
        "login" => %{"step" => "login", "url" => "javascript:alert(1)"}
      })

      {:ok, view, html} = live(as(conn, owner), ~p"/control")

      refute html =~ "javascript:alert"
      # No reported page: Log in opens the agent's detail instead.
      assert has_element?(
               view,
               ~s{#agent-row-#{agent.slug} a[data-role=row-action][href="/control/#{agent.slug}"]},
               "Log in"
             )
    end

    test "no host connected: a running-desired agent reads Host offline, with no button", %{
      conn: conn,
      owner: owner
    } do
      {agent, _} = native!(owner, "Hoff", "running")

      {:ok, view, html} = live(as(conn, owner), ~p"/control")

      assert row_state(html, agent.slug) == "host_offline"
      assert row_text(view, agent.slug) =~ "Host offline"
      refute has_row_action?(view, agent.slug)
    end

    test "a non-manager sees the row button disabled", %{conn: conn, owner: owner} do
      join_host!()
      {agent, _} = native!(owner, "Stu")
      observe!(agent, "stopped")
      other = member!("member")

      {:ok, view, _html} = live(as(conn, other), ~p"/control")

      assert has_element?(
               view,
               "#agent-row-#{agent.slug} button[data-role=row-action][disabled]",
               "Start"
             )
    end
  end

  describe "the federated row" do
    test "has the same shape: meta line instead of the Federated pill", %{
      conn: conn,
      owner: owner
    } do
      {:ok, agent, _runtime, _token} =
        Federation.provision_agent_runtime(
          owner.id,
          %{slug: "octo-#{System.unique_integer([:positive])}", name: "Octo", status: "active"},
          %{
            runtime_id: "octo-rt-#{System.unique_integer([:positive])}",
            display_name: "test-host.legacy"
          }
        )

      {:ok, view, html} = live(as(conn, owner), ~p"/control")

      assert has_element?(
               view,
               "#agent-row-#{agent.slug} [data-role=row-meta]",
               "Federated from test-host.legacy"
             )

      # The pill is gone; the offline state has words, not only a grey dot.
      refute has_element?(view, "#agent-row-#{agent.slug} .hero-globe-alt")
      assert row_state(html, agent.slug) == "offline"
      assert row_text(view, agent.slug) =~ "Offline"
      refute has_row_action?(view, agent.slug)
    end
  end

  # ── Detail header ─────────────────────────────────────────────────

  describe "the managed detail header" do
    test "Start, Restart and Stop are disabled at the boundaries, never hidden", %{
      conn: conn,
      owner: owner
    } do
      join_host!("full_machine")
      {agent, _} = native!(owner, "Ada")
      observe!(agent, "stopped")

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")

      assert has_element?(view, "#native-start:not([disabled])", "Start")
      assert has_element?(view, "#native-restart[disabled]", "Restart")
      assert has_element?(view, "#native-stop[disabled]", "Stop")
      assert has_element?(view, "#native-agent-meta", "Claude Code on this server · Full machine")

      # The built-in controls are not drawn for a managed agent.
      refute has_element?(view, "#start-runtime")

      observe!(agent, "running")
      render(view)

      assert has_element?(view, "#native-start[disabled]")
      assert has_element?(view, "#native-restart:not([disabled])")
      assert has_element?(view, "#native-stop:not([disabled])")
    end

    test "every button is disabled while no host is connected", %{conn: conn, owner: owner} do
      {agent, _} = native!(owner, "Ada")

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")

      for id <- ~w(native-start native-restart native-stop) do
        assert has_element?(view, "##{id}[disabled]")
      end

      assert has_element?(view, "#native-agent-meta", "Agent host not connected")
    end

    test "the profile the host reports reads Contained", %{conn: conn, owner: owner} do
      join_host!("contained")
      {agent, _} = native!(owner, "Cora")
      observe!(agent, "running")

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")
      assert has_element?(view, "#native-agent-meta", "Contained")
    end

    test "Restart reads Restarting while in flight, then clears", %{conn: conn, owner: owner} do
      join_host!()
      {agent, _} = native!(owner, "Remy", "running")
      observe!(agent, "running")

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")

      view |> element("#native-restart") |> render_click()

      assert_receive {:agent_host_push, "agent.restart", %{"agent_id" => agent_id}}
      assert agent_id == agent.id
      assert has_element?(view, "#native-restart[disabled]", "Restarting")

      observe!(agent, "running")
      render(view)

      assert has_element?(view, "#native-restart:not([disabled])", "Restart")
      refute has_element?(view, "#native-restart", "Restarting")
    end

    test "Stop records stopped and tells the host", %{conn: conn, owner: owner} do
      join_host!()
      {agent, _} = native!(owner, "Sol", "running")
      observe!(agent, "running")

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")
      view |> element("#native-stop") |> render_click()

      assert_receive {:agent_host_push, "agent.stop", %{"agent_id" => _}}
      assert desired(agent) == "stopped"
    end

    test "the built-in header is unchanged", %{conn: conn, owner: owner} do
      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "builtin-#{System.unique_integer([:positive])}",
          name: "Builtin",
          status: "active"
        })
        |> Repo.insert!()

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")

      # Built-in agents have no owner runtime. RBAC requires manage_all for
      # their controls; ordinary members retain the read-only header.
      refute has_element?(view, "#start-runtime")
      refute has_element?(view, "#refresh-runtime")
      refute has_element?(view, "#stop-runtime")
      admin = member!("admin")
      {:ok, view, _html} = live(as(conn, admin), ~p"/control/#{agent.slug}")

      assert has_element?(view, "#start-runtime", "Start runtime")
      assert has_element?(view, "#refresh-runtime", "Refresh runtime")
      assert has_element?(view, "#stop-runtime", "Stop runtime")
      refute has_element?(view, "#native-start")
    end
  end

  # ── Refused server-side ───────────────────────────────────────────

  describe "can_manage? is enforced on the server" do
    test "a non-manager's Start is refused server-side", %{conn: conn, owner: owner} do
      join_host!()
      {agent, _} = native!(owner, "Guard")
      observe!(agent, "stopped")
      other = member!("member")

      {:ok, view, _html} = live(as(conn, other), ~p"/control/#{agent.slug}")

      # Sent straight down the socket: the disabled button is not the guard.
      html = render_hook(view, "native_start", %{"agent_id" => agent.id})

      assert html =~ "Only the agent&#39;s owner or an admin can do that."
      assert desired(agent) == "stopped"
      refute_receive {:agent_host_push, "agent.start", _}, 100

      for event <- ~w(native_stop native_restart) do
        render_hook(view, event, %{"agent_id" => agent.id})
      end

      refute_receive {:agent_host_push, _, _}, 100
    end

    test "a malformed agent_id is refused, not raised", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(as(conn, owner), ~p"/control")

      for bad <- ["not-a-uuid", "sixteen-byte-str", ""] do
        html = render_hook(view, "native_start", %{"agent_id" => bad})
        assert html =~ "That agent is not run by this server."
      end
    end

    test "POSITIVE CONTROL: the owner and an admin are allowed", %{conn: conn, owner: owner} do
      join_host!()
      {agent, _} = native!(owner, "Allowed")
      observe!(agent, "stopped")

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")
      render_hook(view, "native_start", %{"agent_id" => agent.id})

      assert_receive {:agent_host_push, "agent.start", %{"agent_id" => id}}
      assert id == agent.id
      assert desired(agent) == "running"

      admin = member!("admin")
      {:ok, admin_view, _html} = live(as(build_conn(), admin), ~p"/control/#{agent.slug}")
      render_hook(admin_view, "native_stop", %{"agent_id" => agent.id})

      assert desired(agent) == "stopped"
    end
  end

  # ── Create flow ───────────────────────────────────────────────────

  describe "Run on this server" do
    test "is offered only while an agent host is connected", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(as(conn, owner), ~p"/control")
      view |> element("#add-agent-btn-sidebar") |> render_click()
      refute has_element?(view, "#choose-native")

      join_host!()
      {:ok, view, _html} = live(as(conn, owner), ~p"/control")
      view |> element("#add-agent-btn-sidebar") |> render_click()
      assert has_element?(view, "#choose-native", "Run on this server")
    end

    test "creates the agent, starts it, and opens it", %{conn: conn, owner: owner} do
      join_host!()
      {:ok, view, _html} = live(as(conn, owner), ~p"/control")

      view |> element("#add-agent-btn-sidebar") |> render_click()
      view |> element("#choose-native") |> render_click()

      # Codex is shown and disabled until `suite codex` has merged.
      assert has_element?(view, ~s{#native-agent-form input[value=codex][disabled]})
      assert render(view) =~ "Not available yet"

      view
      |> form("#native-agent-form", native: %{name: "Ada Native", harness: "claude_code"})
      |> render_submit()

      agent = Repo.get_by!(Agent, name: "Ada Native")
      assert_patch(view, ~p"/control/#{agent.slug}")

      runtime = NativeAgents.get_managed_runtime(agent)
      assert %AgentRuntime{managed_by: "install", harness: "claude_code"} = runtime
      assert runtime.desired_state == "running"
      assert agent.runtime_type == "external"

      assert_receive {:agent_host_push, "agent.start", %{"agent_id" => id}}
      assert id == agent.id
    end

    test "a codex harness is refused server-side", %{conn: conn, owner: owner} do
      join_host!()
      {:ok, view, _html} = live(as(conn, owner), ~p"/control")

      html =
        render_hook(view, "submit_native", %{
          "native" => %{"name" => "Cody", "harness" => "codex"}
        })

      assert html =~ "That harness is not available yet."
      refute Repo.get_by(Agent, name: "Cody")
    end

    test "is refused when no host is connected, even when submitted directly", %{
      conn: conn,
      owner: owner
    } do
      {:ok, view, _html} = live(as(conn, owner), ~p"/control")
      html = render_hook(view, "submit_native", %{"native" => %{"name" => "Nobody"}})

      assert html =~ "Agent host not connected"
      refute Repo.get_by(Agent, name: "Nobody")
    end
  end

  # ── Panels ────────────────────────────────────────────────────────

  describe "managed agents render the federated panels" do
    test "bundles, spaces and voice, without token regeneration", %{conn: conn, owner: owner} do
      join_host!()
      {first, _} = native!(owner, "Ada")
      {second, _} = native!(owner, "Bea")

      {:ok, view, html} = live(as(conn, owner), ~p"/control/#{first.slug}")

      assert html =~ "Tool profile"
      assert html =~ "Spaces this agent participates in."
      assert has_element?(view, ~s{[data-role="agent-voice-card"]})
      refute html =~ "Regenerate Token"
      refute html =~ "Federation Connection"

      assert has_element?(
               view,
               "#first-agent-note.bg-info.text-info-content",
               "Ada is the first agent on this install, so its tool profile starts with the configured modules. Access stays capped at its owner."
             )

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{second.slug}")
      refute has_element?(view, "#first-agent-note")
    end

    test "token regeneration is refused server-side for a managed agent", %{
      conn: conn,
      owner: owner
    } do
      {agent, runtime} = native!(owner, "Tok")
      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")

      html = render_hook(view, "regenerate_federated_token", %{})

      assert html =~ "This agent gets a new token every time it starts."
      assert Repo.get!(AgentRuntime, runtime.id).auth_token_hash == runtime.auth_token_hash
    end

    test "a federated agent keeps its connection panel and Regenerate Token", %{
      conn: conn,
      owner: owner
    } do
      {:ok, agent, _runtime, _token} =
        Federation.provision_agent_runtime(
          owner.id,
          %{slug: "fedp-#{System.unique_integer([:positive])}", name: "FedP", status: "active"},
          %{runtime_id: "fedp-rt-#{System.unique_integer([:positive])}"}
        )

      {:ok, _view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}")

      assert html =~ "Federation Connection"
      assert html =~ "Regenerate Token"
    end
  end

  # ── Live updates ──────────────────────────────────────────────────

  describe "agent_host:status" do
    test "rows and the header re-render when the host reports a change", %{
      conn: conn,
      owner: owner
    } do
      join_host!()
      {agent, _} = native!(owner, "Live", "running")
      observe!(agent, "running")

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")
      refute has_element?(view, "#agent-row-#{agent.slug} [data-role=row-tag]")

      observe!(agent, "crashed")

      html = render(view)
      assert row_state(html, agent.slug) == "crashed"
      assert has_element?(view, "#native-restart:not([disabled])")
      assert has_element?(view, "#native-agent-meta", "Crashed at")
    end
  end
end
