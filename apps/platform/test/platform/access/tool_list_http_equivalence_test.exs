defmodule Platform.Access.ToolListHttpEquivalenceTest do
  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Agents.AgentRuntime
  alias Platform.Repo
  alias Platform.RuntimeBundleSnapshot

  test "HTTP tools/list preserves every ordered production array except approved Play loss", %{
    conn: conn
  } do
    owner = root_admin!()

    for %{key: key, bundles: bundles} <- RuntimeBundleSnapshot.snapshots() do
      token = AgentRuntime.generate_token()

      Repo.insert!(%AgentRuntime{
        runtime_id: "http-equivalence-#{key}",
        owner_user_id: owner.id,
        auth_token_hash: AgentRuntime.hash_token(token),
        status: "active",
        allowed_bundles: bundles
      })

      payload = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}

      names =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/mcp", payload)
        |> json_response(200)
        |> get_in(["result", "tools"])
        |> Enum.map(& &1["name"])

      legacy = RuntimeBundleSnapshot.legacy_tool_names(bundles)

      expected =
        if key in [:c, :k, :n],
          do: Enum.reject(legacy, &String.starts_with?(&1, "play_session_")),
          else: legacy

      assert names == expected, "HTTP ordered tool list changed for snapshot #{key}"
    end
  end
end
