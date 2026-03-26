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
          input_tokens: 10,
          output_tokens: 800,
          cache_read_tokens: 50_000,
          cache_write_tokens: 200,
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
    # Should show "input" label in the breakdown
    assert html =~ "input"
    # Should show "output" label in the breakdown
    assert html =~ "output"
  end

  test "summary card shows total input tokens including cache", %{conn: conn} do
    # input=10, cache_read=50000, cache_write=200 → total prompt = 50210 → "50.2K"
    create_usage_event(%{
      input_tokens: 10,
      cache_read_tokens: 50_000,
      cache_write_tokens: 200,
      output_tokens: 500
    })

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control/usage")

    # Total prompt tokens should be 50210 → displayed as "50.2K"
    assert html =~ "50.2K"
    # Should NOT display just "10" as the input (the old uncached-only value)
    # The "10" token count should appear only in the "fresh" breakdown, not as a standalone input number
    assert html =~ "fresh"
  end

  test "event log shows total input per row", %{conn: conn} do
    # Total input per row: 10 + 50000 + 200 = 50210
    create_usage_event(%{
      input_tokens: 10,
      cache_read_tokens: 50_000,
      cache_write_tokens: 200,
      output_tokens: 500
    })

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control/usage")

    # The table should show "Total In" header
    assert html =~ "Total In"
    # The row should contain the total input value (50210 → "50.2K")
    assert html =~ "50.2K"
    # Should also show "Total" column
    assert html =~ ">Total<"
  end

  test "cache efficiency stats shown when cache data exists", %{conn: conn} do
    create_usage_event(%{
      input_tokens: 10,
      cache_read_tokens: 50_000,
      cache_write_tokens: 200,
      output_tokens: 500
    })

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control/usage")

    # Should show cache hit rate and "cached" text
    assert html =~ "cached"
    assert html =~ "%"
    # Cache R/W column in the event table
    assert html =~ "Cache R/W"
  end

  test "cache stats hidden when no cache data", %{conn: conn} do
    create_usage_event(%{
      input_tokens: 1500,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      output_tokens: 800
    })

    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control/usage")

    # Should NOT show the cache efficiency line when no cache data
    refute html =~ "cached ("
    refute html =~ "% cached"
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
