defmodule PlatformWeb.ControlCenterLiveTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentServer, MemoryContext}
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
end
