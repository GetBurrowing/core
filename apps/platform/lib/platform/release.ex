defmodule Platform.Release do
  @moduledoc """
  Release tasks for running Ecto migrations in production.

  Usage (via release binary):

      /app/bin/platform eval "Platform.Release.migrate()"
      /app/bin/platform eval "Platform.Release.rollback(Platform.Repo, 20230101120000)"
  """

  @app :platform

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
