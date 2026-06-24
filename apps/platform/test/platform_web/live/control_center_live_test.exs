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

  test "opening the onboarding chooser shows 5 flow options including External Agent",
       %{conn: conn} do
    create_agent()
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    html = render_click(view, "open_onboarding_chooser", %{})

    assert html =~ "Add Agent"
    assert html =~ "From a Template"
    assert html =~ "Federate"
    assert html =~ "Import"
    assert html =~ "Create Custom"
    assert html =~ "External Agent"
    # New flag pill present in the tile
    assert html =~ "New"
  end

  test "choosing the external flow transitions to the External Agent heading", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    html = render_click(view, "choose_onboarding", %{"flow" => "external"})

    # Modal heading switches to External Agent (overlay heading + flow body)
    assert html =~ "External Agent"
    # The configure preamble card still renders above the form
    assert html =~ "External Agent &middot; configure" or html =~ "External Agent · configure"
    # Stage-2: the form itself is mounted
    assert html =~ "external-agent-form"
  end

  test "external agent form renders all stage-2 fields", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    html = render_click(view, "choose_onboarding", %{"flow" => "external"})

    # Display Name + Slug inputs
    assert html =~ ~s(name="external_agent[name]")
    assert html =~ ~s(name="external_agent[slug]")
    assert html =~ "Display Name"
    assert html =~ "Slug"

    # Endpoint Kind dropdown with both options
    assert html =~ ~s(name="external_agent[endpoint_kind]")
    assert html =~ "OpenAI-compatible (Chat Completions)"
    assert html =~ "Ollama-native"
    assert html =~ ~s(value="openai_compat")
    assert html =~ ~s(value="ollama_native")

    # Base URL + Model
    assert html =~ ~s(name="external_agent[base_url]")
    assert html =~ ~s(name="external_agent[model]")
    assert html =~ "Base URL"
    assert html =~ "Model"

    # Default Behavior pill row — all three radio options
    assert html =~ ~s(name="external_agent[default_behavior]")
    assert html =~ "Chat"
    assert html =~ "Dispatch"
    assert html =~ "Dispatch + Chat"

    # Default endpoint_kind is openai_compat — help text reflects it.
    assert html =~ "vLLM, LM Studio"
    refute html =~ "local Ollama installations"
  end

  test "switching endpoint_kind to ollama_native swaps help text and placeholders",
       %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "external"})

    # Drive a phx-change with the new endpoint_kind selection.
    html =
      view
      |> form("#external-agent-form",
        external_agent: %{
          name: "",
          slug: "",
          endpoint_kind: "ollama_native",
          base_url: "",
          model: "",
          default_behavior: "chat"
        }
      )
      |> render_change()

    assert html =~ "local Ollama installations"
    refute html =~ "vLLM, LM Studio"
    # Placeholders also flip to the Ollama-native values.
    assert html =~ "localhost:11434"
    assert html =~ "llama3.2"
  end

  test "typing into the Display Name auto-derives a slug", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "external"})

    html =
      view
      |> form("#external-agent-form",
        external_agent: %{
          name: "Local Llama",
          slug: "",
          endpoint_kind: "openai_compat",
          base_url: "",
          model: "",
          default_behavior: "chat"
        }
      )
      |> render_change()

    assert html =~ ~s(value="local-llama")
  end

  # ── Stage 4: Connection Status panel + submit-flow wiring ──────────

  defp stub_external_agents_req_client(response_fn) do
    {:ok, _} = Application.ensure_all_started(:req)

    Application.put_env(
      :platform,
      :external_agents_req_client,
      Req.new(plug: {Req.Test, :external_agents_test})
    )

    Req.Test.stub(:external_agents_test, response_fn)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:platform, :external_agents_req_client)
    end)

    :ok
  end

  test "Connection Status panel renders idle placeholder before submit", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    html = render_click(view, "choose_onboarding", %{"flow" => "external"})

    assert html =~ "Connection Status"
    assert html =~ "Run probe on save"
    assert html =~ "Not connected yet"
  end

  test "submit with paste mode + save_to_vault=false stores secret in ETS and leaves vault_key nil",
       %{conn: conn} do
    stub_external_agents_req_client(fn conn ->
      Req.Test.json(conn, %{"data" => [%{"id" => "gpt-4o-mini"}]})
    end)

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "external"})

    view
    |> form("#external-agent-form",
      external_agent: %{
        name: "Ephemeral Llama",
        slug: "",
        endpoint_kind: "openai_compat",
        base_url: "https://api.openai.com/v1",
        model: "gpt-4o-mini",
        default_behavior: "chat",
        vault_mode: "paste",
        vault_key: "ephem-key",
        secret: "ephem-secret-xyz",
        save_to_vault: "false"
      }
    )
    |> render_submit()

    created = Repo.get_by!(Agent, slug: "ephemeral-llama")
    assert created.kind == "external"
    assert is_nil(created.vault_key)
    assert created.endpoint_kind == "openai_compat"
    assert created.base_url == "https://api.openai.com/v1"
    assert created.model == "gpt-4o-mini"

    # Secret landed in ETS, not in vault
    assert {:ok, "ephem-secret-xyz"} =
             Platform.ExternalAgents.EphemeralCredentials.get(created.id)

    refute Repo.get_by(Platform.Vault.Credential, slug: "ephem-key")
  end

  test "submit with paste mode + save_to_vault=true writes to Vault and references vault_key",
       %{conn: conn} do
    stub_external_agents_req_client(fn conn ->
      Req.Test.json(conn, %{"data" => [%{"id" => "model-a"}]})
    end)

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "external"})

    vault_key = "vaulted-key-#{System.unique_integer([:positive])}"

    view
    |> form("#external-agent-form",
      external_agent: %{
        name: "Vaulted Llama",
        slug: "",
        endpoint_kind: "openai_compat",
        base_url: "https://api.openai.com/v1",
        model: "gpt-4o-mini",
        default_behavior: "chat",
        vault_mode: "paste",
        vault_key: vault_key,
        secret: "sk-vault-xyz",
        save_to_vault: "true"
      }
    )
    |> render_submit()

    created = Repo.get_by!(Agent, slug: "vaulted-llama")
    assert created.vault_key == vault_key

    # Vault has the credential, ETS does NOT
    assert {:ok, "sk-vault-xyz"} =
             Platform.Vault.get(vault_key, accessor: {:agent, created.id})

    assert {:error, :not_found} =
             Platform.ExternalAgents.EphemeralCredentials.get(created.id)
  end

  test "probe failure does NOT block agent creation; warning flash + probe_result carries error",
       %{conn: conn} do
    stub_external_agents_req_client(fn conn ->
      Req.Test.transport_error(conn, :nxdomain)
    end)

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "external"})

    html =
      view
      |> form("#external-agent-form",
        external_agent: %{
          name: "Unreachable",
          slug: "",
          endpoint_kind: "openai_compat",
          base_url: "http://unreachable.invalid",
          model: "gpt-4o-mini",
          default_behavior: "chat",
          vault_mode: "paste",
          vault_key: "",
          secret: "",
          save_to_vault: "false"
        }
      )
      |> render_submit()

    created = Repo.get_by!(Agent, slug: "unreachable")
    assert created.kind == "external"
    # Probe persisted its outcome to the row
    assert Repo.get!(Agent, created.id).last_probe_status == "network_error"

    # Warning flash visible in the redirected page
    assert html =~ "Probe failed"
    assert html =~ "network_error"
    assert html =~ "saved anyway"
  end

  test "submit with from_vault mode uses existing vault_key without writing a new credential",
       %{conn: conn} do
    stub_external_agents_req_client(fn conn ->
      Req.Test.json(conn, %{"data" => []})
    end)

    existing_slug = "preexisting-key-#{System.unique_integer([:positive])}"

    {:ok, _cred} =
      Platform.Vault.put(existing_slug, :api_key, "sk-already-here",
        name: "Preexisting",
        provider: "external_agent"
      )

    initial_count =
      Platform.Vault.list(scope: {:platform, nil})
      |> Enum.count(&(&1.slug == existing_slug))

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "external"})
    # Toggle the Credentials tab into From-vault mode so the hidden
    # vault_mode input reflects "from_vault".
    render_click(view, "set_vault_mode", %{"mode" => "from_vault"})

    view
    |> form("#external-agent-form",
      external_agent: %{
        name: "Reuser",
        slug: "",
        endpoint_kind: "openai_compat",
        base_url: "https://api.openai.com/v1",
        model: "gpt-4o-mini",
        default_behavior: "chat",
        vault_key: existing_slug
      }
    )
    |> render_submit()

    created = Repo.get_by!(Agent, slug: "reuser")
    assert created.vault_key == existing_slug

    # No duplicate credential row — count for that slug stays the same
    final_count =
      Platform.Vault.list(scope: {:platform, nil})
      |> Enum.count(&(&1.slug == existing_slug))

    assert final_count == initial_count
  end

  test "successful probe renders OK pill in Connection Status panel after submit",
       %{conn: conn} do
    stub_external_agents_req_client(fn conn ->
      Req.Test.json(conn, %{
        "data" => [%{"id" => "a"}, %{"id" => "b"}, %{"id" => "c"}]
      })
    end)

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "external"})

    html =
      view
      |> form("#external-agent-form",
        external_agent: %{
          name: "Probe OK Test",
          slug: "",
          endpoint_kind: "openai_compat",
          base_url: "https://api.openai.com/v1",
          model: "gpt-4o-mini",
          default_behavior: "chat",
          vault_mode: "paste",
          vault_key: "",
          secret: "",
          save_to_vault: "false"
        }
      )
      |> render_submit()

    # The Repo row got persisted, last_probe_status == "ok"
    created = Repo.get_by!(Agent, slug: "probe-ok-test")
    assert Repo.get!(Agent, created.id).last_probe_status == "ok"

    # Success flash in the redirected page
    assert html =~ "probe OK"
  end

  test "changeset error (missing base_url) re-renders form with flash", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "external"})

    html =
      view
      |> form("#external-agent-form",
        external_agent: %{
          name: "Bad Submit",
          slug: "",
          endpoint_kind: "openai_compat",
          base_url: "",
          model: "",
          default_behavior: "chat",
          vault_mode: "paste",
          vault_key: "",
          secret: "",
          save_to_vault: "false"
        }
      )
      |> render_submit()

    # Form stays open (still rendered)
    assert html =~ "external-agent-form"
    # No agent created
    refute Repo.get_by(Agent, slug: "bad-submit")
  end

  # ── Stage 3: Vault sub-form ─────────────────────────────────────────

  test "external agent form renders Vault sub-form with tab toggle", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    html = render_click(view, "choose_onboarding", %{"flow" => "external"})

    # Credentials section heading + both tabs render
    assert html =~ "Credentials"
    assert html =~ "From vault"
    assert html =~ "+ Paste new"

    # Default mode is "paste" — secret + vault_key inputs visible
    assert html =~ ~s(name="external_agent[vault_key]")
    assert html =~ ~s(name="external_agent[secret]")
    assert html =~ ~s(name="external_agent[save_to_vault]")
    assert html =~ "Save to vault on submit"
    assert html =~ "Name in vault"

    # Tab toggle buttons fire set_vault_mode
    assert html =~ ~s(phx-click="set_vault_mode")
    assert html =~ ~s(phx-value-mode="from_vault")
    assert html =~ ~s(phx-value-mode="paste")
  end

  test "switching to From vault tab swaps to <select>; paste fields no longer rendered as labels",
       %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "external"})

    html = render_click(view, "set_vault_mode", %{"mode" => "from_vault"})

    # From-vault mode renders either the empty notice OR a select; either way
    # the "Name in vault" + "Save to vault on submit" labels disappear.
    refute html =~ "Name in vault"
    refute html =~ "Save to vault on submit"
    # Empty-state notice (no seeded vault rows in test DB)
    assert html =~ "No vault credentials yet"
    # The active-tab class lands on "From vault"
    assert html =~ "tab-active"
  end

  test "tab round-trip preserves vault_key and secret values", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "external"})

    # User fills in vault_key + secret while in paste mode
    view
    |> form("#external-agent-form",
      external_agent: %{
        name: "",
        slug: "",
        endpoint_kind: "openai_compat",
        base_url: "",
        model: "",
        default_behavior: "chat",
        vault_mode: "paste",
        vault_key: "my-test-key",
        secret: "secret-12345",
        save_to_vault: "true"
      }
    )
    |> render_change()

    # Toggle to From vault, then back to Paste new
    render_click(view, "set_vault_mode", %{"mode" => "from_vault"})
    html = render_click(view, "set_vault_mode", %{"mode" => "paste"})

    # Both values must survive the round-trip
    assert html =~ ~s(value="my-test-key")
    assert html =~ ~s(value="secret-12345")
    # save_to_vault checkbox is still checked
    assert html =~ ~s(checked)
  end

  test "From vault mode renders existing platform credentials in <select>", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    # Seed two platform-scoped credentials matching the api_key/token filter
    {:ok, _cred1} =
      Platform.Vault.put(
        "openrouter-key-#{System.unique_integer([:positive])}",
        :api_key,
        "sk-xyz",
        name: "OpenRouter Key",
        provider: "external_agent"
      )

    {:ok, _cred2} =
      Platform.Vault.put(
        "anthropic-key-#{System.unique_integer([:positive])}",
        :token,
        "sk-anth",
        name: "Anthropic Key",
        provider: "external_agent"
      )

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "external"})
    html = render_click(view, "set_vault_mode", %{"mode" => "from_vault"})

    # Both credentials should appear as <option> entries
    assert html =~ "OpenRouter Key"
    assert html =~ "Anthropic Key"
    # Empty-state notice is no longer rendered
    refute html =~ "No vault credentials yet"
    # The select is bound to vault_key
    assert html =~ ~s(name="external_agent[vault_key]")
  end

  test "unchecking Save to vault round-trips as false", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control")

    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "external"})

    # Submit a change with save_to_vault unchecked (phx-change uses the hidden
    # predecessor "false" value when the box isn't checked)
    html =
      view
      |> form("#external-agent-form",
        external_agent: %{
          name: "Ephemeral",
          slug: "",
          endpoint_kind: "openai_compat",
          base_url: "",
          model: "",
          default_behavior: "chat",
          vault_mode: "paste",
          vault_key: "ephemeral-key",
          secret: "ephem-xyz",
          save_to_vault: "false"
        }
      )
      |> render_change()

    # vault_key and secret survive; checkbox is now unchecked
    assert html =~ ~s(value="ephemeral-key")
    assert html =~ ~s(value="ephem-xyz")
    # The save_to_vault checkbox input is no longer rendered with `checked`.
    refute html =~ ~r/name="external_agent\[save_to_vault\]"\s+value="true"\s+class=[^>]*checked/
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
    # Under ADR 0038 the roster is the same row.
    assert participant.role == "principal"
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

  test "update runtime bundles persists the submitted set", %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "fed_bundles_#{System.unique_integer([:positive])}@example.com",
        name: "Fed Bundles User",
        oidc_sub: "oidc-fed-bundles-#{System.unique_integer([:positive])}"
      })

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "bundles-runtime-#{System.unique_integer([:positive])}",
        display_name: "Bundles Test"
      })

    {:ok, runtime, _token} = Federation.activate_runtime(runtime)

    agent =
      create_agent(%{
        name: "Bundles Agent",
        runtime_type: "external",
        runtime_id: runtime.id
      })

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, html} = live(conn, ~p"/control/#{agent.slug}")

    # The bundle form should render with the current bundles checked.
    assert html =~ "Allowed capability bundles"
    assert html =~ ~s(name="bundles[]")

    new_bundles = ~w(federation space task plan memory)

    html =
      view
      |> element("form[phx-submit=\"update_runtime_bundles\"]")
      |> render_submit(%{"bundles" => new_bundles})

    assert html =~ "Allowed bundles updated"

    assert Enum.sort(Repo.get!(AgentRuntime, runtime.id).allowed_bundles) ==
             Enum.sort(new_bundles)
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

  # ── Historian toggle ────────────────────────────────────────────

  describe "Historian role" do
    test "toggling on persists the canonical historian event, shows badge",
         %{conn: conn} do
      agent = create_agent(%{name: "Archive"})
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      html =
        view
        |> form("#agent-config-form",
          config: %{
            name: "Archive",
            status: "active",
            primary_model: "anthropic/claude-sonnet-4-6",
            fallback_models: "",
            thinking_default: "medium",
            max_concurrent: 1,
            sandbox_mode: "off",
            historian: "on"
          }
        )
        |> render_submit()

      updated = Repo.get!(Agent, agent.id)
      assert "historian" in updated.system_events
      refute "daily_summary" in updated.system_events
      refute "dreaming" in updated.system_events
      assert html =~ "Historian"
    end

    test "toggling off clears system_events", %{conn: conn} do
      agent =
        create_agent(%{
          name: "WasHistorian",
          system_events: ["historian"]
        })

      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/control/#{agent.slug}")

      assert html =~ "Historian"

      view
      |> form("#agent-config-form",
        config: %{
          name: "WasHistorian",
          status: "active",
          primary_model: "anthropic/claude-sonnet-4-6",
          fallback_models: "",
          thinking_default: "medium",
          max_concurrent: 1,
          sandbox_mode: "off",
          historian: "off"
        }
      )
      |> render_submit()

      updated = Repo.get!(Agent, agent.id)
      assert updated.system_events == []
    end

    test "checkbox is disabled when another agent is already Historian",
         %{conn: conn} do
      _other =
        create_agent(%{
          name: "CurrentHistorian",
          system_events: ["historian"]
        })

      target = create_agent(%{name: "Candidate"})

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/control/#{target.slug}")

      assert html =~ "Another agent is currently Historian"
      assert html =~ ~r/name="config\[historian\]"[^>]*disabled/
    end

    test "federated agent's Identity form exposes the Historian toggle",
         %{conn: conn} do
      user =
        Repo.insert!(%User{
          email: "hist_fed_#{System.unique_integer([:positive])}@example.com",
          name: "Hist Fed User",
          oidc_sub: "oidc-hist-fed-#{System.unique_integer([:positive])}"
        })

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "hist-runtime-#{System.unique_integer([:positive])}",
          display_name: "Hist OpenClaw"
        })

      {:ok, runtime, _token} = Federation.activate_runtime(runtime)

      agent =
        create_agent(%{
          name: "Federated Historian",
          runtime_type: "external",
          runtime_id: runtime.id
        })

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, html} = live(conn, ~p"/control/#{agent.slug}")

      assert html =~ ~r/name="config\[historian\]"/

      view
      |> form("#federated-identity-form",
        config: %{
          name: "Federated Historian",
          historian: "on"
        }
      )
      |> render_submit()

      updated = Repo.get!(Agent, agent.id)
      assert "historian" in updated.system_events
      refute "daily_summary" in updated.system_events
      refute "dreaming" in updated.system_events
    end
  end

  describe "Roles panel (M7 stage 5)" do
    test "GET /control with no agent selected renders 4 role rows + UNFILLED pills", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/control")

      # Tab strip + count
      assert html =~ "Roles (4)"

      # Each of the four seeded roles renders with name + icon class.
      assert html =~ "Designer"
      assert html =~ "Historian"
      assert html =~ "Meeting Scribe"
      assert html =~ "Triage Officer"
      assert html =~ "hero-paint-brush"
      assert html =~ "hero-book-open"
      assert html =~ "hero-calendar-days"
      assert html =~ "hero-clipboard-document-check"

      # Bundle keys render as <code> chips for at least one role.
      assert html =~ "design.critique"
      assert html =~ "memory.daily_summary"
      assert html =~ "meetings.summarize"
      assert html =~ "tasks.triage"

      # Every row starts UNFILLED with a Fill role button.
      assert html =~ "UNFILLED"
      assert html =~ "Fill role"

      # Cost stats stub chips render literal em-dash placeholders.
      assert html =~ "runs —"
      assert html =~ "last —"
      assert html =~ "avg —"
      assert html =~ "$/run —"

      # Show advanced footer present (stage 6 owns the toggle behaviour).
      assert html =~ "Show advanced"
    end

    test "assigning a role swaps the row to show the agent name + kind pill", %{conn: conn} do
      agent =
        create_agent(%{
          name: "Pixel Picasso",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "http://localhost:1234/v1",
          model: "gpt-4o-mini"
        })

      {:ok, _assignment} = Platform.Roles.assign_role("designer", agent.id)

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/control")

      # Designer row now shows the agent's name + EXT pill (kind == external).
      assert html =~ "Pixel Picasso"
      assert html =~ "EXT"

      # Other three roles still UNFILLED.
      assert html =~ "UNFILLED"
    end

    test "toggle_role_advanced flips the advanced label", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/control")

      assert html =~ "Show advanced"
      refute html =~ "Hide advanced"

      html = render_click(view, "toggle_role_advanced", %{})

      assert html =~ "Hide advanced"
    end

    test "open_fill_role opens the External Agent onboarding flow", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control")

      html = render_click(view, "open_fill_role", %{"role_key" => "designer"})

      # Modal opens to the External Agent flow (heading + form).
      assert html =~ "External Agent"
      assert html =~ "external-agent-form"
    end
  end

  describe "Roles advanced surface + role select (M7 stage 6)" do
    test "Show advanced toggle reveals a flat per-responsibility list", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control")

      html = render_click(view, "toggle_role_advanced", %{})

      # The advanced surface is identified by its id and an explanatory blurb.
      assert html =~ "roles-advanced-panel"
      assert html =~ "Each responsibility routes"

      # Sample one responsibility key from each seeded bundle.
      assert html =~ "design.critique"
      assert html =~ "memory.daily_summary"
      assert html =~ "meetings.summarize"
      assert html =~ "tasks.triage"

      # Every row gets an override <select> via the change-event form,
      # plus a "use role default" option for the no-override case.
      assert html =~ "set_responsibility_override"
      assert html =~ "use role default"
    end

    test "set_responsibility_override persists a ResponsibilityOverride row + assignee_for/1 resolves to it",
         %{conn: conn} do
      agent = create_agent(%{name: "Override Pal"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control")
      render_click(view, "toggle_role_advanced", %{})

      _html =
        render_change(view, "set_responsibility_override", %{
          "responsibility_key" => "design.critique",
          "agent_id" => agent.id
        })

      assert %Platform.Roles.ResponsibilityOverride{agent_id: aid} =
               Repo.get_by(
                 Platform.Roles.ResponsibilityOverride,
                 responsibility_key: "design.critique"
               )

      assert aid == agent.id
      assert %Platform.Agents.Agent{id: ^aid} = Platform.Roles.assignee_for("design.critique")
    end

    test "clear_responsibility_override removes the row and re-renders the row without OVERRIDE",
         %{conn: conn} do
      agent = create_agent(%{name: "Cleared Pal"})
      {:ok, _override} = Platform.Roles.set_override("design.critique", agent.id)

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control")
      html = render_click(view, "toggle_role_advanced", %{})

      # OVERRIDE pill visible before clear
      assert html =~ "OVERRIDE"

      html =
        render_click(view, "clear_responsibility_override", %{"key" => "design.critique"})

      refute Repo.get_by(
               Platform.Roles.ResponsibilityOverride,
               responsibility_key: "design.critique"
             )

      refute html =~ "OVERRIDE"
    end

    test "Fill role pre-binds the role_key into the External Agent form's role select",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control")

      html = render_click(view, "open_fill_role", %{"role_key" => "designer"})

      # The role <select> is present and the designer option is selected.
      assert html =~ ~s(name="external_agent[role_key]")
      # The selected designer <option> renders with selected attribute.
      assert html =~ ~r/<option[^>]*value="designer"[^>]*selected/
    end

    test "External Agent form lists taken roles as disabled options with conflict text",
         %{conn: conn} do
      taken_agent = create_agent(%{name: "Already Pinned"})
      {:ok, _assignment} = Platform.Roles.assign_role("designer", taken_agent.id)

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control")

      render_click(view, "open_onboarding_chooser", %{})
      html = render_click(view, "choose_onboarding", %{"flow" => "external"})

      # Designer option is disabled and shows the conflicting agent name.
      assert html =~ ~r/<option[^>]*value="designer"[^>]*disabled/
      assert html =~ "Already Pinned"
    end

    test "submit with role_key non-blank assigns the role to the new agent",
         %{conn: conn} do
      stub_external_agents_req_client(fn conn ->
        Req.Test.json(conn, %{"data" => [%{"id" => "gpt-4o-mini"}]})
      end)

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control")

      render_click(view, "open_onboarding_chooser", %{})
      render_click(view, "choose_onboarding", %{"flow" => "external"})

      view
      |> form("#external-agent-form",
        external_agent: %{
          name: "Role Pinned",
          slug: "",
          endpoint_kind: "openai_compat",
          base_url: "https://api.openai.com/v1",
          model: "gpt-4o-mini",
          default_behavior: "chat",
          vault_mode: "paste",
          vault_key: "rp-key",
          secret: "rp-secret",
          save_to_vault: "false",
          role_key: "designer"
        }
      )
      |> render_submit()

      created = Repo.get_by!(Platform.Agents.Agent, slug: "role-pinned")
      assert created.kind == "external"

      # Assignment row exists and resolves back to this agent.
      assignment = Repo.get_by(Platform.Roles.RoleAssignment, role_key: "designer")
      assert assignment
      assert assignment.agent_id == created.id
    end

    test "submit with a taken role_key surfaces an error flash without crashing",
         %{conn: conn} do
      stub_external_agents_req_client(fn conn ->
        Req.Test.json(conn, %{"data" => []})
      end)

      taken_agent = create_agent(%{name: "Squatter"})
      {:ok, _assignment} = Platform.Roles.assign_role("historian", taken_agent.id)

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control")

      render_click(view, "open_onboarding_chooser", %{})
      render_click(view, "choose_onboarding", %{"flow" => "external"})

      html =
        view
        |> form("#external-agent-form",
          external_agent: %{
            name: "Conflict Llama",
            slug: "",
            endpoint_kind: "openai_compat",
            base_url: "https://api.openai.com/v1",
            model: "gpt-4o-mini",
            default_behavior: "chat",
            vault_mode: "paste",
            vault_key: "",
            secret: "",
            save_to_vault: "false",
            role_key: "historian"
          }
        )
        |> render_submit()

      # Agent still created (role assignment failure is not a gate).
      assert Repo.get_by!(Platform.Agents.Agent, slug: "conflict-llama")

      # Original assignment unchanged.
      assignment = Repo.get_by(Platform.Roles.RoleAssignment, role_key: "historian")
      assert assignment.agent_id == taken_agent.id

      # Flash visible.
      assert html =~ "already filled"
    end
  end
end
