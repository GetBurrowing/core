defmodule Platform.Release do
  @moduledoc """
  Release tasks for running Ecto migrations in production.

  Usage (via release binary):

      /app/bin/platform eval "Platform.Release.migrate()"
      /app/bin/platform eval "Platform.Release.rollback(Platform.Repo, 20230101120000)"

  ## Build-time modules (ADR 0055)

  Both run over core's migrations path first, then every configured module's
  (`migrations_paths/1`). A rollback that would undo a MODULE's migration is
  refused unless explicitly allowed: rolling back across a module's versions
  is the module's decision, not a side effect of rolling back core
  (`0055-extension-contract-and-build-time-modules.md § 6. Migrations`).
  Allow it with `allow_module_rollback: true`, or with
  `ALLOW_MODULE_ROLLBACK=true` in the environment for a `bin/platform eval`.
  """

  require Logger

  @app :platform

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          &Ecto.Migrator.run(&1, migrations_paths(&1), :up, all: true)
        )
    end
  end

  @doc """
  Core's migrations path first, then every build-time module's (ADR 0055
  section 6). Versions are unique across all of them; a module's may run out
  of order on a database that gains the module later, which is intended.
  """
  @spec migrations_paths(module()) :: [String.t()]
  def migrations_paths(repo),
    do: [Ecto.Migrator.migrations_path(repo) | Platform.Extensions.migrations_paths()]

  @doc """
  Rolls `repo` back down to (and including) `version`, over every path in
  `migrations_paths/1`.

  Refuses, running nothing, when that would undo a migration a build-time
  module owns, and returns `{:error, {:crosses_module_migrations, versions}}`
  naming each one. Pass `allow_module_rollback: true` (or set
  `ALLOW_MODULE_ROLLBACK=true`) to roll them back too.
  """
  def rollback(repo, version, opts \\ []) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        paths = migrations_paths(repo)

        crossed =
          module_versions_crossed(
            version,
            applied_versions(repo, Platform.Extensions.migrations_paths())
          )

        if crossed == [] or allow_module_rollback?(opts) do
          Ecto.Migrator.run(repo, paths, :down, to: version)
        else
          Logger.error(
            "[Release] refusing to roll #{inspect(repo)} back to #{version}: it would " <>
              "undo module migration(s) #{inspect(crossed)}. Pass " <>
              "allow_module_rollback: true or set ALLOW_MODULE_ROLLBACK=true to allow it."
          )

          {:error, {:crosses_module_migrations, crossed}}
        end
      end)

    result
  end

  @doc """
  The module-owned versions a rollback to `version` would undo: those in
  `module_versions` (applied module migrations) at or above `version`,
  ascending. `[]` means the rollback touches core only.
  """
  @spec module_versions_crossed(integer(), [integer()]) :: [integer()]
  def module_versions_crossed(version, module_versions) when is_integer(version),
    do: module_versions |> Enum.filter(&(&1 >= version)) |> Enum.sort()

  @doc false
  @spec allow_module_rollback?(keyword()) :: boolean()
  def allow_module_rollback?(opts) do
    Keyword.get_lazy(opts, :allow_module_rollback, fn ->
      System.get_env("ALLOW_MODULE_ROLLBACK") in ["true", "1"]
    end) == true
  end

  # The versions of the migration FILES in `paths` that `repo` has applied.
  # Not `Ecto.Migrator.migrations(repo, paths)`'s `:up` rows: that lists every
  # applied version in the database, file or no file, so it would count every
  # core migration as a module's. `[]` for no paths, so a without-modules
  # install never queries.
  defp applied_versions(_repo, []), do: []

  defp applied_versions(repo, paths) do
    applied = MapSet.new(Ecto.Migrator.migrated_versions(repo))
    Enum.filter(file_versions(paths), &MapSet.member?(applied, &1))
  end

  @doc false
  @spec file_versions([String.t()]) :: [integer()]
  def file_versions(paths) do
    for path <- paths,
        file <- Path.wildcard(Path.join(path, "*.exs")),
        {version, "_" <> _} <- [Integer.parse(Path.basename(file))],
        do: version
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
