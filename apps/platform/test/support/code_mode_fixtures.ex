defmodule Platform.CodeModeFixtures do
  @moduledoc """
  Rows the code mode tests (task 01a114a8 stage 2) need: an agent, an
  active runtime with an explicit bundle list, and a `POST /mcp` helper.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation.ToolCallRecord
  alias Platform.Repo

  def u, do: System.unique_integer([:positive])

  def insert_agent! do
    %Agent{}
    |> Agent.changeset(%{slug: "codemode-agent-#{u()}", name: "CodeMode Agent", status: "active"})
    |> Repo.insert!()
  end

  def insert_user! do
    Repo.insert!(%Platform.Accounts.User{
      email: "codemode_#{u()}@example.com",
      name: "CodeMode User",
      oidc_sub: "oidc-codemode-#{u()}"
    })
  end

  @doc "An active runtime holding exactly `bundles`. Returns `{runtime, raw_token}`."
  def insert_runtime!(agent, bundles, owner_user_id \\ nil) do
    raw_token = AgentRuntime.generate_token()

    runtime =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "codemode-rt-#{u()}",
        owner_user_id: owner_user_id || insert_user!().id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw_token),
        status: "active",
        allowed_bundles: bundles
      })
      |> Repo.insert!()

    {runtime, raw_token}
  end

  @doc "The default bundles plus `extra`."
  def bundles(extra), do: AgentRuntime.default_allowed_bundles() ++ extra

  @doc "Ledger rows whose parent_run_id is `run_id`, oldest first."
  def inner_rows(run_id) do
    Repo.all(
      from(r in ToolCallRecord,
        where: r.parent_run_id == ^run_id,
        order_by: [asc: r.inserted_at, asc: r.id]
      )
    )
  end

  def mcp(token, method, params) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(PlatformWeb.Endpoint, :post, "/mcp", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => params
    })
    |> Phoenix.ConnTest.json_response(200)
  end

  @doc "`tools/call` over `/mcp`; returns the decoded JSON body."
  def mcp_call(token, name, args),
    do: mcp(token, "tools/call", %{"name" => name, "arguments" => args})

  @doc "The decoded first text block of a successful `tools/call` result."
  def result_json(%{"result" => %{"content" => [%{"text" => text} | _]}}), do: Jason.decode!(text)
end
