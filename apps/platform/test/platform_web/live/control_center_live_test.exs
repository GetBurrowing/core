defmodule PlatformWeb.ControlCenterLiveTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime, AgentServer, MemoryContext}
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "control_test_#{System.unique_integer([:positive])}@example.com",
        name: "Control Test User",
        oidc_sub: "oidc-control-test-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_agent(attrs \\ %{}) do
    default = %{
      slug: "control-agent-#{System.unique_integer([:positive, :monotonic])}",
      name: "Control Agent",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{
        "primary" => "anthropic/claude-sonnet-4-6",
        "fallbacks" => ["openai/gpt-4.1"]
      }
    }

    {:ok, agent} =
      default
      |> Map.merge(attrs)
      |> then(&Agent.changeset(%Agent{}, &1))
      |> Repo.insert()

    agent
  end

  defp configure_workspace!(context, agents) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "control-center-workspace-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(workspace)

    openclaw = %{
      "agents" => %{
        "list" =>
          Enum.map(agents, fn {slug, name} ->
            %{
              "id" => slug,
              "name" => name,
              "model" => %{"primary" => "anthropic/claude-sonnet-4-6"}
            }
          end)
      }
    }

    File.write!(Path.join(workspace, "openclaw.json"), Jason.encode!(openclaw))
    File.write!(Path.join(workspace, "SOUL.md"), "steady")

    previous_workspace = Application.get_env(:platform, :agent_workspace_path)
    Application.put_env(:platform, :agent_workspace_path, workspace)

    on_exit(fn ->
      Application.put_env(:platform, :agent_workspace_path, previous_workspace)
      File.rm_rf(workspace)
    end)

    context
  end

  test "GET /control redirects unauthenticated users to login", %{conn: conn} do
    conn = get(conn, ~p"/control")
    assert redirected_to(conn) == "/auth/login"
  end

  test "GET /control renders the full control center for the first agent", %{conn: conn} do
    agent = create_agent(%{name: "Zip", thinking_default: "medium"})
    {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "SOUL.md", "steady")
    {:ok, _} = MemoryContext.append_memory(agent.id, :long_term, "calm systems win")

    {:ok, _} =
      Platform.Vault.put("anthropic-oauth", :oauth2, ~s({"access_token":"token"}),
        provider: "anthropic",
        scope: {:platform, nil}
      )

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control/#{agent.slug}")

    assert html =~ "Agent Resources"
    assert html =~ "Zip"
    assert html =~ "Config + model routing"
    assert html =~ "Workspace files"
    assert html =~ "Memory browser"
    assert html =~ "Vault visibility"
    assert html =~ "calm systems win"
    assert html =~ "anthropic/claude-sonnet-4-6"
  end

  test "GET /control lists agents from the mounted workspace config alongside persisted rows", %{
    conn: conn
  } do
    configure_workspace!(%{}, [{"zip", "Zip"}, {"alice", "Alice"}])
    create_agent(%{slug: "repl-test-agent", name: "REPL Test Agent"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control")

    assert html =~ "Zip"
    assert html =~ "Alice"
    assert html =~ "REPL Test Agent"
    assert html =~ "Mounted Workspace"
    assert html =~ "Control Center"
  end

  test "starting and stopping the runtime updates the dashboard", %{conn: conn} do
    agent = create_agent()
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    html = render_click(view, "start_runtime", %{})
    assert is_pid(AgentServer.whereis(agent.id))
    assert html =~ "Started runtime"
    assert render(view) =~ "Runtime Idle"

    html = render_click(view, "stop_runtime", %{})
    assert AgentServer.whereis(agent.id) == nil
    assert html =~ "Stopped runtime"
  end

  test "shell indicator reflects the default workspace runtime on /control", %{conn: conn} do
    configure_workspace!(%{}, [{"main", "Main"}])
    main = create_agent(%{slug: "main", name: "Main"})
    {:ok, _pid} = AgentServer.start_agent(main)
    on_exit(fn -> AgentServer.stop_agent(main) end)

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control")

    assert html =~ "Agent"
    refute html =~ "Agent unknown"
  end

  test "opening /control boots the first configured workspace agent when no main agent exists", %{
    conn: conn
  } do
    configure_workspace!(%{}, [{"zip", "Zip"}, {"sidecar", "Sidecar"}])

    on_exit(fn ->
      AgentServer.stop_agent("zip")
      AgentServer.stop_agent("sidecar")
    end)

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control")

    assert html =~ "Agent"
    assert is_pid(AgentServer.whereis("zip"))
    assert AgentServer.whereis("sidecar") == nil
  end

  test "opening /control falls back to persisted main agent when workspace bootstrap is unavailable",
       %{
         conn: conn
       } do
    previous_workspace = Application.get_env(:platform, :agent_workspace_path)
    Application.put_env(:platform, :agent_workspace_path, "/tmp/does-not-exist/platform-agent")

    main = create_agent(%{slug: "main", name: "Zip"})

    on_exit(fn ->
      AgentServer.stop_agent(main)
      Application.put_env(:platform, :agent_workspace_path, previous_workspace)
    end)

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control")

    assert html =~ "Agent"
    assert is_pid(AgentServer.whereis(main.id))
  end

  test "saving a workspace file persists through MemoryContext", %{conn: conn} do
    agent = create_agent()
    {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "SOUL.md", "steady")

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    html =
      view
      |> form("#workspace-file-form", workspace_file: %{file_key: "SOUL.md", content: "steadier"})
      |> render_submit()

    assert html =~ "Saved SOUL.md"
    assert MemoryContext.get_workspace_file(agent.id, "SOUL.md").content == "steadier"
    assert render(view) =~ "steadier"
  end

  test "appending a memory writes a real memory row", %{conn: conn} do
    agent = create_agent()
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    html =
      view
      |> form("#memory-entry-form",
        memory_entry: %{
          memory_type: "long_term",
          date: Date.utc_today() |> Date.to_iso8601(),
          content: "Remember this from control center"
        }
      )
      |> render_submit()

    assert html =~ "Added Long Term memory"

    assert Enum.any?(MemoryContext.list_memories(agent.id), fn memory ->
             memory.content == "Remember this from control center"
           end)

    assert render(view) =~ "Remember this from control center"
  end

  test "saving config updates the persisted agent definition", %{conn: conn} do
    agent = create_agent(%{name: "Before"})
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    html =
      view
      |> form("#agent-config-form",
        config: %{
          name: "After",
          status: "paused",
          primary_model: "openai/gpt-4.1",
          fallback_models: "anthropic/claude-sonnet-4-6",
          thinking_default: "high",
          max_concurrent: 3,
          sandbox_mode: "require"
        }
      )
      |> render_submit()

    updated = Repo.get!(Agent, agent.id)

    assert html =~ "Updated After"
    assert updated.name == "After"
    assert updated.status == "paused"
    assert updated.thinking_default == "high"
    assert updated.max_concurrent == 3
    assert updated.sandbox_mode == "require"
    assert updated.model_config["primary"] == "openai/gpt-4.1"
    assert updated.model_config["fallbacks"] == ["anthropic/claude-sonnet-4-6"]
  end

  test "creating a new agent from the UI persists and selects it", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    refute render(view) =~ "create-agent-form"

    render_click(view, "choose_onboarding", %{"flow" => "create"})

    html =
      view
      |> form("#create-agent-form",
        create_agent: %{
          name: "Runtime Ops",
          slug: "runtime-ops",
          primary_model: "openai/gpt-4.1",
          status: "active",
          max_concurrent: 2,
          sandbox_mode: "require"
        }
      )
      |> render_submit()

    created = Repo.get_by!(Agent, slug: "runtime-ops")

    assert html =~ "Created Runtime Ops"
    assert created.name == "Runtime Ops"
    assert created.model_config["primary"] == "openai/gpt-4.1"
    assert render(view) =~ "Runtime Ops"
    assert render(view) =~ "runtime-ops"
  end

  test "deleting a database-managed agent removes it from the UI", %{conn: conn} do
    agent = create_agent(%{slug: "stale-repl", name: "Stale REPL"})
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    html = render_click(view, "request_delete_agent", %{})
    assert html =~ "Confirm delete"

    html = render_click(view, "delete_agent", %{})

    refute Repo.get(Agent, agent.id)
    assert html =~ "Deleted Stale REPL"
  end

  test "mobile-oriented layout hooks are rendered on /control", %{conn: conn} do
    agent = create_agent()
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control/#{agent.slug}")

    assert html =~ "id=\"agent-directory\""
    assert html =~ "id=\"agent-primary-actions\""
    assert html =~ "overflow-y-auto"
    refute html =~ "create-agent-form"
  end

  test "shell sidebar is rendered on /control", %{conn: conn} do
    agent = create_agent()
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control/#{agent.slug}")

    assert html =~ "Startup Suite"
    assert html =~ "/chat"
    assert html =~ "/control"
  end

  # ── Onboarding flows ──────────────────────────────────────────────

  test "opening the onboarding chooser shows 4 flow options", %{conn: conn} do
    create_agent()
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    html = render_click(view, "open_onboarding_chooser", %{})

    assert html =~ "Add Agent"
    assert html =~ "From a Template"
    assert html =~ "Federate"
    assert html =~ "Import"
    assert html =~ "Create Custom"
  end

  test "selecting template flow shows 8 role template cards", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    html = render_click(view, "choose_onboarding", %{"flow" => "template"})

    assert html =~ "Choose a Template"
    assert html =~ "Designer"
    assert html =~ "Researcher"
    assert html =~ "Architect"
    assert html =~ "Writer"
    assert html =~ "Analyst"
    assert html =~ "DevOps"
    assert html =~ "Project Manager"
    assert html =~ "Sales"
  end

  test "selecting a template shows the confirm/name step", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "template"})
    html = render_click(view, "select_template", %{"template_id" => "researcher"})

    assert html =~ "Researcher Template"
    assert html =~ "Deep research, analysis, synthesis"
    assert html =~ "template-create-form"
    assert html =~ "Agent Name"
    assert html =~ "Back"
  end

  test "back button from template confirm returns to template grid", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "template"})
    render_click(view, "select_template", %{"template_id" => "designer"})

    html = render_click(view, "back_to_templates", %{})

    assert html =~ "Choose a Template"
    assert html =~ "Designer"
    assert html =~ "Researcher"
    refute html =~ "template-create-form"
  end

  test "federate flow shows connection form fields", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    html = render_click(view, "choose_onboarding", %{"flow" => "federate"})

    assert html =~ "Federate an Agent"
    assert html =~ "Runtime ID"
    assert html =~ "Display Name"
    assert html =~ "Agent Name"
    assert html =~ "federate-form"
    assert html =~ "Federate Agent"
  end

  test "import flow with workspace configured shows agent checkboxes", %{conn: conn} do
    configure_workspace!(%{}, [{"zip", "Zip"}, {"sidecar", "Sidecar"}])
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    html = render_click(view, "choose_onboarding", %{"flow" => "import"})

    assert html =~ "Import from Workspace"
    assert html =~ "Zip"
    assert html =~ "Sidecar"
    assert html =~ "Import 0 agent(s)"
  end

  test "import flow without workspace shows empty message", %{conn: conn} do
    previous_workspace = Application.get_env(:platform, :agent_workspace_path)
    Application.put_env(:platform, :agent_workspace_path, "/tmp/does-not-exist/test-workspace")

    on_exit(fn ->
      Application.put_env(:platform, :agent_workspace_path, previous_workspace)
    end)

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    html = render_click(view, "choose_onboarding", %{"flow" => "import"})

    assert html =~ "No workspace agents found"
  end

  test "closing onboarding overlay clears the state", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    html = render_click(view, "open_onboarding_chooser", %{})
    assert html =~ "From a Template"

    html = render_click(view, "close_onboarding", %{})

    refute html =~ "From a Template"
    refute html =~ "Choose a Template"
  end

  # ── Federation / runtime management ────────────────────────────────

  test "federated agent card shows Federated badge instead of model", %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "fed_test_#{System.unique_integer([:positive])}@example.com",
        name: "Fed Test User",
        oidc_sub: "oidc-fed-test-#{System.unique_integer([:positive])}"
      })

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "test-runtime-#{System.unique_integer([:positive])}",
        display_name: "Test OpenClaw"
      })

    _agent =
      create_agent(%{
        name: "Remote Agent",
        runtime_type: "external",
        runtime_id: runtime.id
      })

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, _view, html} = live(conn, ~p"/control")

    assert html =~ "Federated"
    assert html =~ "Remote Agent"
    # External agents should not show primary model badge in card
    refute html =~ ~r/rounded-full bg-base-200.*anthropic\/claude-sonnet/
  end

  test "federated agent detail shows Federation Connection section", %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "fed_detail_#{System.unique_integer([:positive])}@example.com",
        name: "Fed Detail User",
        oidc_sub: "oidc-fed-detail-#{System.unique_integer([:positive])}"
      })

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "detail-runtime-#{System.unique_integer([:positive])}",
        display_name: "Detail OpenClaw"
      })

    {:ok, runtime, _token} = Federation.activate_runtime(runtime)

    agent =
      create_agent(%{
        name: "Fed Detail Agent",
        runtime_type: "external",
        runtime_id: runtime.id
      })

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, _view, html} = live(conn, ~p"/control/#{agent.slug}")

    assert html =~ "Federation Connection"
    assert html =~ "Identity"
    assert html =~ "Spaces"
    assert html =~ runtime.runtime_id
    assert html =~ "Suspend"
    assert html =~ "Revoke"
    assert html =~ "Regenerate Token"
  end

  test "adding agent to space via control center creates both participant and roster entries", %{
    conn: conn
  } do
    agent = create_agent(%{name: "Roster Agent"})
    {:ok, space} = Chat.create_space(%{name: "General", slug: "general-test", kind: "channel"})

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    html =
      render_submit(view, "add_agent_to_space", %{"space_id" => space.id, "role" => "principal"})

    assert html =~ "Agent added to space."

    participant =
      Repo.get_by!(Platform.Chat.Participant,
        space_id: space.id,
        participant_type: "agent",
        participant_id: agent.id
      )

    assert participant.attention_mode == "all"
    assert is_nil(participant.left_at)

    roster = Repo.get_by!(Platform.Chat.SpaceAgent, space_id: space.id, agent_id: agent.id)
    assert roster.role == "principal"
  end

  test "suspend federated runtime updates status", %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "fed_suspend_#{System.unique_integer([:positive])}@example.com",
        name: "Fed Suspend User",
        oidc_sub: "oidc-fed-suspend-#{System.unique_integer([:positive])}"
      })

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "suspend-runtime-#{System.unique_integer([:positive])}",
        display_name: "Suspend Test"
      })

    {:ok, runtime, _token} = Federation.activate_runtime(runtime)

    agent =
      create_agent(%{
        name: "Suspend Agent",
        runtime_type: "external",
        runtime_id: runtime.id
      })

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    html = render_click(view, "suspend_federated_runtime", %{})

    assert html =~ "Runtime suspended"
    updated_runtime = Repo.get!(AgentRuntime, runtime.id)
    assert updated_runtime.status == "suspended"
  end

  test "revoke federated runtime updates status", %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "fed_revoke_#{System.unique_integer([:positive])}@example.com",
        name: "Fed Revoke User",
        oidc_sub: "oidc-fed-revoke-#{System.unique_integer([:positive])}"
      })

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "revoke-runtime-#{System.unique_integer([:positive])}",
        display_name: "Revoke Test"
      })

    {:ok, runtime, _token} = Federation.activate_runtime(runtime)

    agent =
      create_agent(%{
        name: "Revoke Agent",
        runtime_type: "external",
        runtime_id: runtime.id
      })

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    html = render_click(view, "revoke_federated_runtime", %{})

    assert html =~ "Runtime revoked"
    updated_runtime = Repo.get!(AgentRuntime, runtime.id)
    assert updated_runtime.status == "revoked"
  end

  test "regenerate federated token shows new token and dismiss clears it", %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "fed_regen_#{System.unique_integer([:positive])}@example.com",
        name: "Fed Regen User",
        oidc_sub: "oidc-fed-regen-#{System.unique_integer([:positive])}"
      })

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "regen-runtime-#{System.unique_integer([:positive])}",
        display_name: "Regen Test"
      })

    {:ok, runtime, _token} = Federation.activate_runtime(runtime)

    agent =
      create_agent(%{
        name: "Regen Agent",
        runtime_type: "external",
        runtime_id: runtime.id
      })

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    html = render_click(view, "regenerate_federated_token", %{})

    assert html =~ "New token generated"
    assert html =~ "New token generated. Save it now."

    html = render_click(view, "dismiss_regenerated_token", %{})

    # The dismiss clears the regenerated_token display (not the flash)
    refute html =~ "copy-regen-token"
  end

  # ── Agent deletion ─────────────────────────────────────────────────

  test "request delete shows confirm dialog and cancel dismisses it", %{conn: conn} do
    agent = create_agent(%{slug: "delete-test", name: "Delete Test"})
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    html = render_click(view, "request_delete_agent", %{})
    assert html =~ "Confirm delete"
    assert html =~ "Cancel delete"

    html = render_click(view, "cancel_delete_agent", %{})
    refute html =~ "Confirm delete"
    refute html =~ "Cancel delete"
    assert html =~ "Delete agent"
  end

  test "delete with slug param removes agent", %{conn: conn} do
    agent = create_agent(%{slug: "slug-delete-test", name: "Slug Delete"})
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    render_click(view, "request_delete_agent", %{"slug" => agent.slug})
    html = render_click(view, "delete_agent", %{"slug" => agent.slug})

    refute Repo.get(Agent, agent.id)
    assert html =~ "Deleted Slug Delete"
  end

  # ── Memory filtering ───────────────────────────────────────────────

  test "filter memories by type narrows the list", %{conn: conn} do
    agent = create_agent()
    {:ok, _} = MemoryContext.append_memory(agent.id, :long_term, "long term note")
    {:ok, _} = MemoryContext.append_memory(agent.id, :daily, "daily note", date: Date.utc_today())

    conn = authenticated_conn(conn)
    {:ok, view, html} = live(conn, ~p"/control/#{agent.slug}")

    assert html =~ "long term note"
    assert html =~ "daily note"

    html =
      view
      |> form("#memory-filter-form", memory_filters: %{type: "long_term", query: ""})
      |> render_submit()

    assert html =~ "long term note"
    refute html =~ "daily note"
  end

  test "filter memories by search query", %{conn: conn} do
    agent = create_agent()
    {:ok, _} = MemoryContext.append_memory(agent.id, :long_term, "alpha bravo")
    {:ok, _} = MemoryContext.append_memory(agent.id, :long_term, "charlie delta")

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    html =
      view
      |> form("#memory-filter-form", memory_filters: %{type: "all", query: "alpha"})
      |> render_submit()

    assert html =~ "alpha bravo"
    refute html =~ "charlie delta"
  end

  # ── Workspace file management ──────────────────────────────────────

  test "select workspace file switches editor content", %{conn: conn} do
    agent = create_agent()
    {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "SOUL.md", "soul content")
    {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "IDENTITY.md", "identity content")

    conn = authenticated_conn(conn)
    {:ok, view, html} = live(conn, ~p"/control/#{agent.slug}")

    # First file should be selected by default
    assert html =~ "soul content" or html =~ "identity content"

    html = render_click(view, "select_workspace_file", %{"file_key" => "IDENTITY.md"})
    assert html =~ "identity content"

    html = render_click(view, "select_workspace_file", %{"file_key" => "SOUL.md"})
    assert html =~ "soul content"
  end

  test "new workspace file flow shows empty editor", %{conn: conn} do
    agent = create_agent()
    {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "SOUL.md", "soul content")

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    html = render_click(view, "new_workspace_file", %{})

    # Should show an editable file key input (not read-only)
    assert html =~ "workspace-file-form"
    assert html =~ "File key"
  end

  test "creating a new workspace file persists it", %{conn: conn} do
    agent = create_agent()

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

    render_click(view, "new_workspace_file", %{})

    html =
      view
      |> form("#workspace-file-form",
        workspace_file: %{file_key: "TOOLS.md", content: "tool definitions"}
      )
      |> render_submit()

    assert html =~ "Saved TOOLS.md"
    assert MemoryContext.get_workspace_file(agent.id, "TOOLS.md").content == "tool definitions"
  end

  # ── Creating agent from template ───────────────────────────────────

  test "creating an agent from a template persists it with template config", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "template"})
    render_click(view, "select_template", %{"template_id" => "architect"})

    html =
      view
      |> form("#template-create-form", template: %{name: "My Architect"})
      |> render_submit()

    assert html =~ "Created My Architect"

    created = Repo.get_by!(Agent, name: "My Architect")
    assert created.model_config["primary"] == "anthropic/claude-opus-4-6"
    assert created.status == "active"
  end
end
