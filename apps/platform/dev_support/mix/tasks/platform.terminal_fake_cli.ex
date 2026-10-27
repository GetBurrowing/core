defmodule Mix.Tasks.Platform.TerminalFakeCli do
  @shortdoc "Dev/test only: a fake terminal CLI that echoes what the relay sends it"

  @moduledoc """
  Connects to `ws://localhost:4000/runtime/ws` as a runtime and joins
  `runtime:<id>` (what the agent's channel plugin does, so the runtime reads as
  online) and `terminal:<id>` (what the CLI bridge does). With `--no-terminal`
  it joins only `runtime:<id>`, which simulates the opt-in being off. It runs
  the v1 handshake, writes
  `fake-cli ready` when a session opens, echoes what it receives as
  `echo:<text>`, one line at a time once Enter completes it (a browser sends one
  frame per key, so typing `xyz` and Enter reads `echo:xyz`) and prints `in frames received: N` on every frame and on exit.

      mix platform.terminal_fake_cli --runtime-id ID --token T [--no-terminal]
        [--url ws://localhost:4000] [--seconds N]

  The token is taken from the command line and never written anywhere. Exit
  with SIGTERM or `--seconds`.
  """
  use Mix.Task

  alias PlatformWeb.TerminalFakeCli.Client

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          runtime_id: :string,
          token: :string,
          no_terminal: :boolean,
          url: :string,
          seconds: :integer
        ]
      )

    runtime_id = opts[:runtime_id] || Mix.raise("--runtime-id is required")
    token = opts[:token] || Mix.raise("--token is required")

    Mix.Task.run("loadpaths")
    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:websockex)
    {:ok, _} = Application.ensure_all_started(:jason)

    base = opts[:url] || "ws://localhost:4000"
    query = URI.encode_query(%{"runtime_id" => runtime_id, "token" => token, "vsn" => "2.0.0"})
    url = base <> "/runtime/ws/websocket?" <> query

    {:ok, pid} = Client.start(url, runtime_id, not Keyword.get(opts, :no_terminal, false))
    ref = Process.monitor(pid)
    parent = self()

    System.trap_signal(:sigterm, fn ->
      send(parent, :stop)
      :ok
    end)

    if opts[:seconds], do: Process.send_after(parent, :stop, opts[:seconds] * 1000)

    receive do
      :stop -> :ok
      {:DOWN, ^ref, _, _, _} -> :ok
    end

    IO.puts("in frames received: #{Client.in_count()}")
  end
end
