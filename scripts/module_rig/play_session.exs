# Module rig (ADR 0055 stage 4, task 01a0ee08): a play session, end to end,
# inside a booted WITH-Play release (`bin/platform rpc`), over the real
# transports:
#
#   * the agent calls the `play_session_*` tools over HTTP `POST /mcp` with
#     its runtime bearer token, exactly as a federated agent does;
#   * the play host is a scripted fake: a real WebSocket client (websockex,
#     already in the release) joined to `runtime:<id>` on `/runtime/ws`,
#     declaring `game_stream_host`. It is the same proxy
#     runtime_channel_game_stream_test drives through Phoenix.ChannelTest,
#     except over a real socket, because ChannelTest needs ExUnit.
#
# The one stub: the review build's branch head. Resolving it asks the
# project's git remote, so the rig pins `:branch_provisioner, :runner` to a
# module answering a fixed sha, and restores the setting afterwards.
#
# Prints `RIG key=value` lines; every check that fails raises.
alias Platform.Accounts.User
alias Platform.Federation
alias Platform.Repo
alias Platform.Tasks

defmodule Rig.StubRunner do
  @moduledoc false
  def branch_head_sha(_), do: {:ok, "0123456789abcdef0123456789abcdef01234567"}
end

defmodule Rig.FakeHost do
  @moduledoc false
  use WebSockex

  def start(url, parent), do: WebSockex.start(url, __MODULE__, parent)

  @impl true
  def handle_frame({:text, text}, parent) do
    send(parent, {:rig_frame, Jason.decode!(text)})
    {:ok, parent}
  end
end

defmodule Rig do
  @moduledoc false
  def check!(true, what), do: IO.puts("RIG ok #{what}")
  def check!(other, what), do: raise("RIG check failed: #{what} (got #{inspect(other)})")

  def await_frame(event, timeout \\ 10_000) do
    receive do
      {:rig_frame, [_join_ref, _ref, _topic, ^event, payload]} -> payload
      {:rig_frame, _other} -> await_frame(event, timeout)
    after
      timeout -> raise "RIG no #{event} frame within #{timeout} ms"
    end
  end

  def await(fun, what, tries \\ 50) do
    case fun.() do
      {:ok, value} ->
        value

      _ when tries > 0 ->
        Process.sleep(200)
        await(fun, what, tries - 1)

      other ->
        raise "RIG #{what} never held: #{inspect(other)}"
    end
  end
end

previous_provisioner = Application.get_env(:platform, :branch_provisioner, [])

Application.put_env(
  :platform,
  :branch_provisioner,
  Keyword.put(previous_provisioner, :runner, Rig.StubRunner)
)

try do
  u = System.unique_integer([:positive])

  user =
    Repo.insert!(%User{
      email: "rig-#{u}@example.com",
      name: "Rig #{u}",
      oidc_sub: "rig-01a0ee08-#{u}"
    })

  {:ok, agent} =
    Federation.register_runtime(user.id, %{
      runtime_id: "rig-agent-#{u}",
      allowed_bundles: ["play"]
    })

  {:ok, _agent, agent_token} = Federation.activate_runtime(agent)

  {:ok, host} =
    Federation.register_runtime(user.id, %{runtime_id: "rig-host-#{u}", allowed_bundles: []})

  {:ok, host, host_token} = Federation.activate_runtime(host)

  {:ok, project} =
    Tasks.create_project(%{name: "Rig #{u}", repo_url: "https://github.com/example/rig-01a0ee08"})

  {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Rig play #{u}"})
  task = task |> Ecto.Changeset.change(status: "in_review") |> Repo.update!()

  # ── the fake play host joins over a real WebSocket ──────────────────────
  topic = "runtime:#{host.runtime_id}"

  url =
    "ws://127.0.0.1:4000/runtime/ws/websocket?vsn=2.0.0&" <>
      URI.encode_query(%{"runtime_id" => host.runtime_id, "token" => host_token})

  {:ok, ws} = Rig.FakeHost.start(url, self())

  push = fn ref, event, payload ->
    WebSockex.send_frame(ws, {:text, Jason.encode!(["1", to_string(ref), topic, event, payload])})
  end

  :ok =
    push.(1, "phx_join", %{
      "client_info" => %{"product" => "play_host", "features" => ["game_stream_host"]}
    })

  join = Rig.await_frame("phx_reply")
  Rig.check!(join["status"] == "ok", "the fake host joined #{topic}")

  # ── the agent, over MCP ─────────────────────────────────────────────────
  mcp = fn method, params ->
    Req.post!("http://127.0.0.1:4000/mcp",
      json: %{jsonrpc: "2.0", id: System.unique_integer([:positive]), method: method, params: params},
      headers: [{"authorization", "Bearer " <> agent_token}],
      retry: false
    ).body
  end

  call = fn name, args ->
    %{"result" => %{"content" => [%{"text" => text} | _], "isError" => is_error}} =
      mcp.("tools/call", %{"name" => name, "arguments" => args})

    {is_error, Jason.decode!(text)}
  end

  names = for %{"name" => n} <- mcp.("tools/list", %{})["result"]["tools"], do: n
  play_names = names |> Enum.filter(&String.starts_with?(&1, "play_session_")) |> Enum.sort()
  IO.puts("RIG tools_list_play=#{Enum.join(play_names, ",")}")
  Rig.check!("play_session_start" in play_names, "tools/list carries play_session_start")

  {false, started} = call.("play_session_start", %{"task_id" => task.id})
  session_id = started["session_id"]
  IO.puts("RIG session_id=#{session_id}")
  IO.puts("RIG start_state=#{started["state"]}")

  start_frame = Rig.await_frame("play_session_start")
  Rig.check!(start_frame["session_id"] == session_id, "the host received play_session_start")

  :ok =
    push.(2, "play_session_status", %{
      "session_id" => session_id,
      "state" => "live",
      "detail" => "Streaming (rig)",
      "elapsed_ms" => 100
    })

  live =
    Rig.await(
      fn ->
        case call.("play_session_status", %{"session_id" => session_id}) do
          {false, %{"state" => "live"} = status} -> {:ok, status}
          other -> other
        end
      end,
      "play_session_status reports live"
    )

  IO.puts("RIG status_state=#{live["state"]}")
  Rig.check!(live["state"] == "live", "the session reached live")

  {false, stopped} = call.("play_session_stop", %{"session_id" => session_id})
  IO.puts("RIG stop_state=#{stopped["state"]}")

  rows =
    Rig.await(
      fn ->
        %{rows: [[count]]} =
          Repo.query!("SELECT count(*) FROM game_stream_sessions WHERE id = $1", [
            Ecto.UUID.dump!(session_id)
          ])

        if count == 1, do: {:ok, count}, else: {:waiting, count}
      end,
      "one game_stream_sessions row for the ended session"
    )

  IO.puts("RIG session_rows=#{rows}")
  Process.exit(ws, :kill)
after
  Application.put_env(:platform, :branch_provisioner, previous_provisioner)
end
