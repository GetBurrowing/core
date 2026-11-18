defmodule Platform.Goals.MigrationTest do
  use Platform.DataCase, async: false

  import Platform.Goals.OutcomeFixtures
  alias Platform.Goals
  @retro_version 20_261_115_164_425
  @retro_migration Platform.Repo.Migrations.AddGoalRetroAndPacing
  @opts [log: false, log_migrations_sql: false, migration_lock: false]

  setup_all do
    path =
      Path.expand(
        "../../../priv/repo/migrations/20261115164425_add_goal_retro_and_pacing.exs",
        __DIR__
      )

    unless Code.ensure_loaded?(@retro_migration), do: Code.require_file(path)
    :ok
  end

  @version "20261115152203"
  @migration Path.expand(
               "../../../priv/repo/migrations/#{@version}_create_goal_tables.exs",
               __DIR__
             )
  @irreversible Path.expand(
                  "../../../../../deployment/release/irreversible-migrations.txt",
                  __DIR__
                )

  @tables ~w(goals goal_stops goal_grants goal_entries goal_readings goal_clocks goal_wake_ups goal_asks goal_ask_answers goal_task_links goal_proposals)

  test "the four goal tables exist after the module's test alias migrates" do
    %{rows: rows} =
      Platform.Repo.query!(
        "SELECT table_name FROM information_schema.tables " <>
          "WHERE table_schema = current_schema() AND table_name = ANY($1)",
        [@tables]
      )

    assert Enum.sort(List.flatten(rows)) == Enum.sort(@tables)
  end

  test "the migration ran as this version" do
    %{rows: rows} =
      Platform.Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [
        String.to_integer(@version)
      ])

    assert rows == [[String.to_integer(@version)]]
  end

  test "the migration file carries the old-code-compatible waiver as a comment line" do
    source = File.read!(@migration)

    assert source =~
             ~r/^[ \t]*# old-code-compatible: creates four new goal tables only; no existing table changes and the previous release reads none of them$/m
  end

  test "its version is not listed as irreversible" do
    # Positive control: the list is real and is read line by line.
    assert File.exists?(@irreversible)

    listed =
      @irreversible
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)

    refute @version in listed
  end

  test "readings migration carries the waiver and is absent from the irreversible list" do
    version = "20261115152816"

    source =
      File.read!(
        Path.expand("../../../priv/repo/migrations/#{version}_create_goal_readings.exs", __DIR__)
      )

    assert source =~ ~r/^  # old-code-compatible: creates the new goal_readings table/m
    refute version in String.split(File.read!(@irreversible), "\n", trim: true)
  end

  test "clock migration is compatible and not irreversible" do
    version = "20261115155529"

    source =
      File.read!(
        Path.expand(
          "../../../priv/repo/migrations/#{version}_create_goal_clock_tables.exs",
          __DIR__
        )
      )

    assert source =~ ~r/^  # old-code-compatible: creates five new goal tables only;/m
    refute version in String.split(File.read!(@irreversible), "\n", trim: true)
  end

  test "retro migration carries waiver and is absent from irreversible list" do
    version = "20261115164425"

    source =
      File.read!(
        Path.expand(
          "../../../priv/repo/migrations/#{version}_add_goal_retro_and_pacing.exs",
          __DIR__
        )
      )

    assert Regex.match?(~r/^\s*# old-code-compatible:/m, source)
    refute version in String.split(File.read!(@irreversible), "\n", trim: true)
  end

  test "proposals migration carries the waiver, is absent from the irreversible list and alters nothing" do
    version = "20261115161001"

    source =
      File.read!(
        Path.expand(
          "../../../priv/repo/migrations/#{version}_create_goal_proposals.exs",
          __DIR__
        )
      )

    assert source =~
             ~r/^  # old-code-compatible: creates the new goal_proposals table only; no existing table changes and the previous release does not read it$/m

    refute version in String.split(File.read!(@irreversible), "\n", trim: true)
    refute source =~ ~r/alter table|alter\(/

    assert %{rows: [[_]]} =
             Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [
               String.to_integer(version)
             ])

    %{rows: checks} =
      Repo.query!(
        "SELECT conname FROM pg_constraint WHERE conrelid = 'goal_proposals'::regclass AND contype = 'c' ORDER BY conname"
      )

    assert List.flatten(checks) == ["goal_proposals_delivery", "goal_proposals_status"]

    %{rows: [[index]]} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = 'goal_proposals_one_open'")

    assert index =~ "UNIQUE"
    assert index =~ "WHERE"
    assert index =~ "'open'"
  end

  test "hand-off migration carries the waiver and is absent from the irreversible list" do
    version = "20261115210000"
    dir = Path.expand("../../../priv/repo/migrations", __DIR__)
    source = File.read!(Path.join(dir, "#{version}_add_goal_grant_handoff.exs"))

    assert source =~
             ~r/^[ \t]*# old-code-compatible: adds nullable columns and one check to goal_grants, a Goals table; no core table changes and the previous release reads none of them$/m

    refute version in String.split(File.read!(@irreversible), "\n", trim: true)

    %{rows: rows} =
      Platform.Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = current_schema() AND table_name = 'goal_grants'"
      )

    for column <-
          ~w(handed_at handed_by_user_id card_canvas_id last_update_wake_up_id last_update_at last_update_number),
        do: assert([column] in rows, "goal_grants.#{column} is missing")
  end

  for notes? <- [true, false] do
    @notes? notes?
    test "retro migration rolls down and up with closed retro rows (notes: #{notes?})" do
      c = setup_outcome()
      {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{retro_every: 2})
      check_in = fire(goal)
      {:ok, _} = Goals.close_wake_up(c.coach, check_in.id, "wait", %{reason: "Wait"})
      wake = fire(goal)

      {:ok, %{entry: entry}} =
        Goals.close_retro(c.coach, wake.id, %{
          title: "Looking back",
          summary: "Keep the useful work"
        })

      if @notes? do
        assert {:ok, _} = Goals.prepare_brief(c.owner, DateTime.to_date(Goals.Clock.now()))

        assert Repo.exists?(
                 from(b in Goals.BriefItem, where: b.entry_id == ^entry.id and b.kind == "note")
               )
      end

      # Every inbound wake-up FK nilifies rather than cascading into the notebook.
      %{rows: fks} =
        Repo.query!(
          "SELECT conname, confdeltype::text FROM pg_constraint WHERE contype = 'f' AND confrelid = 'goal_wake_ups'::regclass ORDER BY conname"
        )

      # Goals 7/8 adds the fourth: goal_grants.last_update_wake_up_id.
      assert length(fks) == 4
      assert Enum.all?(fks, fn [_, action] -> action == "n" end)

      assert :ok = Ecto.Migrator.down(Repo, @retro_version, @retro_migration, @opts)

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM schema_migrations WHERE version = $1", [
                 @retro_version
               ])

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM goal_brief_items WHERE kind = 'note'")

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM goal_wake_ups WHERE outcome = 'retro'")

      assert Repo.exists?(from(e in Goals.Entry, where: e.id == ^entry.id and e.kind == "retro"))

      assert Repo.exists?(
               from(w in Goals.WakeUp, where: w.id == ^check_in.id and w.outcome == "wait")
             )

      assert :ok = Ecto.Migrator.up(Repo, @retro_version, @retro_migration, @opts)

      assert %{rows: [[@retro_version]]} =
               Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [
                 @retro_version
               ])

      assert Repo.exists?(from(e in Goals.Entry, where: e.id == ^entry.id and e.kind == "retro"))
    end
  end
end
