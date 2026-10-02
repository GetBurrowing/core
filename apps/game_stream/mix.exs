defmodule GameStream.MixProject do
  @moduledoc """
  Play (`game_stream`, task 01a0db5f) as a build-time module (ADR 0055, task
  01a0ee08 stage 3): its own Mix project, taking core as a path dependency.
  Core never depends on this project and never names a module it defines
  (`apps/platform/test/platform/extension_boundary_test.exs`).

  Run from THIS directory:

      mix deps.get && mix compile --warnings-as-errors
      mix test          # creates and migrates core's AND this module's migrations

  The test and dev config is core's, imported, plus this module's registration
  (`config/config.exs`); core's `config/runtime.exs` is evaluated in place by
  `config/runtime.exs` here
  (`docs/decisions/0055-extension-contract-and-build-time-modules.md § 8. Configuration that belongs to a module`).
  """
  use Mix.Project

  def project do
    [
      app: :game_stream,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers()
    ]
  end

  def application do
    [
      mod: {Platform.GameStream.Application, []},
      extra_applications: [:logger]
    ]
  end

  def cli, do: [preferred_envs: [precommit: :test]]

  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Compiled in the SAME env as this project, so core's `only: :test`
      # deps and its test/support (Platform.DataCase, ConnCase, ChannelCase)
      # are there under `MIX_ENV=test`.
      {:platform, path: "../platform", env: Mix.env()}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create -r Platform.Repo", &migrate_all/1],
      test: [&prepare_test_database/1, "test"]
    ]
  end

  # The repo is core's: this app owns no repo of its own, so every Ecto task
  # is told which one (`-r`).
  @repo_args ["-r", "Platform.Repo"]

  # Core's migrations and this module's, core's path first, exactly as
  # `Platform.Release.migrate/0` runs them. Compiles first: the path list
  # comes from `Platform.Release`, which reads the configured extensions.
  defp migrate_all(_args) do
    Mix.Task.run("compile")
    paths = Platform.Release.migrations_paths(Platform.Repo)

    Mix.Task.run(
      "ecto.migrate",
      ["--quiet" | @repo_args] ++ Enum.flat_map(paths, &["--migrations-path", &1])
    )
  end

  defp prepare_test_database(args) do
    Mix.Task.run("compile")
    Mix.Task.run("ecto.create", ["--quiet" | @repo_args])
    migrate_all(args)
  end
end
