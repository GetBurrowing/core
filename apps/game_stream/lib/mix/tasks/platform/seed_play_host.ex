defmodule Mix.Tasks.Platform.SeedPlayHost do
  @moduledoc """
  Seed the play host's agent and runtime row (task 01a0db5f stage 2). A thin
  CLI over `Platform.GameStream.Seed.run/1` — see that module for exactly
  what is written.

  ## Usage

      mix platform.seed_play_host --owner <email> --token-file <path> [--runtime-id <id>] [--rotate]

  The runtime token is written ONLY to `--token-file` (mode 0600) and is
  never printed. It is minted when the row is created, or again with
  `--rotate`; a plain rerun reuses the row and leaves the file alone.
  """

  use Mix.Task

  @shortdoc "Seed the play host runtime (token written to a file only)"

  @usage "Usage: mix platform.seed_play_host --owner <email> --token-file <path> [--runtime-id <id>] [--rotate]"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [owner: :string, token_file: :string, runtime_id: :string, rotate: :boolean]
      )

    if rest != [] or invalid != [], do: Mix.raise("unrecognised arguments\n\n#{@usage}")

    owner = opts[:owner] || Mix.raise("--owner is required\n\n#{@usage}")
    token_path = opts[:token_file] || Mix.raise("--token-file is required\n\n#{@usage}")

    Mix.Task.run("app.start")

    seed_opts =
      [owner_email: owner, token_path: Path.expand(token_path), rotate: opts[:rotate] || false]
      |> then(fn o ->
        if opts[:runtime_id], do: [{:runtime_id, opts[:runtime_id]} | o], else: o
      end)

    case Platform.GameStream.Seed.run(seed_opts) do
      {:ok, %{runtime: runtime, token_written: written?}} ->
        Mix.shell().info(
          "play host seeded: runtime_id=#{runtime.runtime_id} features=game_stream_host " <>
            "tool_profile=[] " <>
            if(written?,
              do: "token written to #{Path.expand(token_path)}",
              else: "existing row reused; no token minted (pass --rotate to mint one)"
            )
        )

      {:error, reason} ->
        Mix.raise("could not seed the play host: #{inspect(reason)}")
    end
  end
end
