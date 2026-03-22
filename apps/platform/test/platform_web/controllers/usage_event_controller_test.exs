defmodule PlatformWeb.UsageEventControllerTest do
  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
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

  defp create_runtime_with_token do
    user =
      Repo.insert!(%User{
        email: "usage_test_#{System.unique_integer([:positive])}@example.com",
        name: "Usage Test User",
        oidc_sub: "oidc-usage-test-#{System.unique_integer([:positive])}"
      })

    raw_token = AgentRuntime.generate_token()
    hashed = AgentRuntime.hash_token(raw_token)

    {:ok, _runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "usage-rt-#{System.unique_integer([:positive])}",
        owner_user_id: user.id,
        auth_token_hash: hashed,
        status: "active"
      })
      |> Repo.insert()

    raw_token
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
