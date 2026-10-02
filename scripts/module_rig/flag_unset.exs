# Module rig (ADR 0055 stage 4, task 01a0ee08), prod-like case: the
# with-Play image with GAME_STREAM_ENABLED unset, which is what Milhouse and
# Red Star run after the merge, behaves as main does with the flag unset
# (ADR 0055 § 9 step 1): the `play` bundle stays grantable, lists no tools, and
# a direct call is refused as disabled. Over HTTP `POST /mcp`. The rig runs it
# on the base image (main) too and requires the two answers to be identical.
alias Platform.Accounts.User
alias Platform.Federation
alias Platform.Repo

u = System.unique_integer([:positive])

user =
  Repo.insert!(%User{
    email: "rig-flag-#{u}@example.com",
    name: "Rig #{u}",
    oidc_sub: "rig-01a0ee08-flag-#{u}"
  })

{:ok, agent} =
  Federation.register_runtime(user.id, %{runtime_id: "rig-flag-#{u}", allowed_bundles: ["play"]})

{:ok, _agent, token} = Federation.activate_runtime(agent)

mcp = fn method, params ->
  Req.post!("http://127.0.0.1:4000/mcp",
    json: %{jsonrpc: "2.0", id: u, method: method, params: params},
    headers: [{"authorization", "Bearer " <> token}],
    retry: false
  ).body
end

names = for %{"name" => n} <- mcp.("tools/list", %{})["result"]["tools"], do: n
play = Enum.filter(names, &String.starts_with?(&1, "play_session_"))
IO.puts("RIG flag_unset_tools_total=#{length(names)}")
IO.puts("RIG flag_unset_play_tools=#{length(play)}")

case mcp.("tools/call", %{
       "name" => "play_session_start",
       "arguments" => %{"task_id" => Ecto.UUID.generate()}
     }) do
  %{"result" => %{"content" => [%{"text" => text} | _], "isError" => is_error}} ->
    IO.puts("RIG flag_unset_call_is_error=#{is_error}")
    IO.puts("RIG flag_unset_call_code=#{Jason.decode!(text)["code"]}")

  %{"error" => %{"code" => code, "message" => message}} ->
    IO.puts("RIG flag_unset_call_rpc_error=#{code} #{message}")
end
