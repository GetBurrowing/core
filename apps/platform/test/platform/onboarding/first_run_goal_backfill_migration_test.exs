defmodule Platform.Onboarding.FirstRunGoalBackfillMigrationTest do
  @moduledoc """
  Runs the real `20261101050000_backfill_first_run_goal_for_existing_users`
  migration (task 01a19554-fd07 stage 1), not a copy of its SQL.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Repo

  @version 20_261_101_050_000
  @migration Platform.Repo.Migrations.BackfillFirstRunGoalForExistingUsers
  @opts [log: false, log_migrations_sql: false, migration_lock: false]

  setup_all do
    [path] =
      Path.wildcard(Path.join(:code.priv_dir(:platform), "repo/migrations/#{@version}_*.exs"))

    unless Code.ensure_loaded?(@migration), do: Code.require_file(path)
    :ok
  end

  defp user!(prefs) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "frg-mig-#{n}@example.com",
      name: "FRG mig #{n}",
      oidc_sub: "oidc-frg-mig-#{n}",
      preferences: prefs
    })
  end

  defp prefs(user), do: Repo.get!(User, user.id).preferences

  test "up marks every user without the key as existing and keeps everything else" do
    :ok = Ecto.Migrator.down(Repo, @version, @migration, @opts)

    empty = user!(%{})
    themed = user!(%{"theme" => %{"preset" => "sage", "mode" => "dark"}})
    skipped = user!(%{"first_run_goal" => "skipped", "theme" => %{"preset" => "default"}})

    :ok = Ecto.Migrator.up(Repo, @version, @migration, @opts)

    assert prefs(empty) == %{"first_run_goal" => "existing"}

    assert prefs(themed) == %{
             "theme" => %{"preset" => "sage", "mode" => "dark"},
             "first_run_goal" => "existing"
           }

    assert prefs(skipped) == %{"first_run_goal" => "skipped", "theme" => %{"preset" => "default"}}
  end

  test "a user created after the backfill is still pending" do
    :ok = Ecto.Migrator.down(Repo, @version, @migration, @opts)
    :ok = Ecto.Migrator.up(Repo, @version, @migration, @opts)

    fresh = user!(%{})
    assert Platform.Onboarding.FirstRunGoal.pending?(fresh)
  end
end
