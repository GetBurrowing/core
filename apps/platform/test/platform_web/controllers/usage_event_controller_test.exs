defmodule PlatformWeb.UsageEventControllerTest do
  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Repo

  @valid_body %{
    "model" => "anthropic/claude-sonnet-4-6",
    "provider" => "anthropic",
    "session_key" => "sess-test-001",
    "input_tokens" => 1500,
    "output_tokens" => 800,
    "cost_usd" => 0.023,
    "latency_ms" => 3200,
    "tool_calls" => ["read", "exec"]
  }

  # An active runtime bound to an agent, unless `attrs` says otherwise
  # (`status:`, or `agent: false` for an agentless row).
  defp create_runtime_with_token(attrs \\ []) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "usage_test_#{n}@example.com",
        name: "Usage Test User",
        oidc_sub: "oidc-usage-test-#{n}"
      })

    agent_id =
      if Keyword.get(attrs, :agent, true) do
        %Agent{}
        |> Agent.changeset(%{
          slug: "usage-agent-#{n}",
          name: "Usage Agent #{n}",
          status: "active"
        })
        |> Repo.insert!()
        |> Map.fetch!(:id)
      end

    raw_token = AgentRuntime.generate_token()
    hashed = AgentRuntime.hash_token(raw_token)

    {:ok, _runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "usage-rt-#{n}",
        owner_user_id: user.id,
        agent_id: agent_id,
        auth_token_hash: hashed,
        status: Keyword.get(attrs, :status, "active")
      })
      |> Repo.insert()

    raw_token
  end

  defp post_usage(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/internal/usage-events", @valid_body)
  end

  describe "POST /api/internal/usage-events" do
    test "returns 201 with valid token and data", %{conn: conn} do
      token = create_runtime_with_token()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/internal/usage-events", @valid_body)

      assert %{"id" => id} = json_response(conn, 201)
      assert is_binary(id)
    end

    test "returns 401 with missing authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/internal/usage-events", @valid_body)

      assert %{"error" => "missing authorization header"} = json_response(conn, 401)
    end

    test "returns 401 with invalid token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid-token-value")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/internal/usage-events", @valid_body)

      assert %{"error" => "invalid token"} = json_response(conn, 401)
    end

    # Scope added by Dalton (task 01a1b34b stage 4): the token must belong to
    # an active runtime bound to an agent, as on every other runtime auth path.
    test "returns 401 for a suspended runtime's token", %{conn: conn} do
      token = create_runtime_with_token(status: "suspended")
      assert %{"error" => "invalid token"} = json_response(post_usage(conn, token), 401)
    end

    test "returns 401 for a revoked runtime's token", %{conn: conn} do
      # Inserted directly with its hash kept: revoke_runtime/1 clears the hash,
      # so this is the row a status check alone must refuse.
      token = create_runtime_with_token(status: "revoked")
      assert %{"error" => "invalid token"} = json_response(post_usage(conn, token), 401)
    end

    test "returns 401 for an active runtime with no agent", %{conn: conn} do
      token = create_runtime_with_token(agent: false)
      assert %{"error" => "invalid token"} = json_response(post_usage(conn, token), 401)
    end

    test "returns 201 for an active runtime bound to an agent", %{conn: conn} do
      token = create_runtime_with_token()
      assert %{"id" => _} = json_response(post_usage(conn, token), 201)
    end

    test "returns 422 with invalid data", %{conn: conn} do
      token = create_runtime_with_token()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/internal/usage-events", %{})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "model")
      assert Map.has_key?(errors, "provider")
      assert Map.has_key?(errors, "session_key")
    end
  end
end
