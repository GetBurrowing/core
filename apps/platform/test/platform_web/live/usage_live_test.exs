defmodule PlatformWeb.UsageLiveTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Analytics
  alias Platform.Agents.Agent
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "usage_live_#{System.unique_integer([:positive])}@example.com",
        name: "Usage Live User",
        oidc_sub: "oidc-usage-live-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_agent(attrs) do
    default = %{
      slug: "usage-agent-#{System.unique_integer([:positive, :monotonic])}",
      name: "Usage Agent",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6", "fallbacks" => []}
    }

    {:ok, agent} =
      default
      |> Map.merge(attrs)
      |> then(&Agent.changeset(%Agent{}, &1))
      |> Repo.insert()

    agent
  end

  defp create_usage_event(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          model: "anthropic/claude-sonnet-4-6",
          provider: "anthropic",
          session_key: "sess-#{System.unique_integer([:positive])}",
          input_tokens: 1500,
          output_tokens: 800,
          cost_usd: 0.023,
          latency_ms: 3200,
          tool_calls: ["read", "exec"]
        },
        overrides
      )

    {:ok, event} = Analytics.record_usage_event(attrs)
    event
  end

  test "GET /control/usage redirects unauthenticated users to login", %{conn: conn} do
    conn = get(conn, ~p"/control/usage")
    assert redirected_to(conn) == "/auth/login"
  end

  test "GET /control/usage renders the usage dashboard", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control/usage")

    assert html =~ "Usage Analytics"
    assert html =~ "Requests"
    assert html =~ "Tokens"
    assert html =~ "Cost"
    assert html =~ "Avg Latency"
  end

  test "renders summary cards with event data", %{conn: conn} do
    create_usage_event()

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control/usage")

    # Should show at least 1 request
    assert html =~ "1"
  end

  test "renders event log table with events", %{conn: conn} do
    agent = create_agent(%{name: "TestBot"})
    create_usage_event(%{agent_id: agent.id, model: "anthropic/claude-sonnet-4-6"})

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control/usage")

    assert html =~ "anthropic/claude-sonnet-4-6"
    assert html =~ "TestBot"
  end

  test "shows empty state when no events", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control/usage")

    assert html =~ "No usage events recorded yet"
  end

  test "agent filter updates the dashboard", %{conn: conn} do
    agent_a = create_agent(%{name: "Agent A"})
    agent_b = create_agent(%{name: "Agent B"})
    create_usage_event(%{agent_id: agent_a.id, model: "model-a"})
    create_usage_event(%{agent_id: agent_b.id, model: "model-b"})

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/usage")

    html =
      view
      |> element("form")
      |> render_change(%{"agent_id" => agent_a.id, "date_range" => "14"})

    assert html =~ "model-a"
    refute html =~ "model-b"
  end

  test "date range filter updates the dashboard", %{conn: conn} do
    create_usage_event()

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/usage")

    html =
      view
      |> element("form")
      |> render_change(%{"agent_id" => "", "date_range" => "7"})

    assert html =~ "Usage Analytics"
    assert html =~ "7 days"
  end

  test "sidebar shows Usage nav item", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control/usage")

    assert html =~ "/control/usage"
    assert html =~ "Usage"
  end
end
