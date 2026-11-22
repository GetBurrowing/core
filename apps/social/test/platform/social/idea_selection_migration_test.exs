defmodule Platform.Social.IdeaSelectionMigrationTest do
  @moduledoc """
  The selection migration is additive and old-code-compatible (a waiver, not
  an irreversible-list entry), and its `down` refuses while any selected idea
  or selection event exists, so history is never discarded silently.
  """
  use Platform.DataCase, async: false

  import Platform.SocialApprovalFixtures

  alias Platform.Social.Ideas

  @version 20_261_122_090_000
  @migration Platform.Repo.Migrations.AddSocialIdeaSelection
  @path Path.expand(
          "../../../priv/repo/migrations/20261122090000_add_social_idea_selection.exs",
          __DIR__
        )
  @irreversible Path.expand(
                  "../../../../../deployment/release/irreversible-migrations.txt",
                  __DIR__
                )
  @opts [log: false, log_migrations_sql: false, migration_lock: false]

  setup_all do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@path)
    :ok
  end

  defp columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'social_ideas' AND column_name LIKE 'selected%' ORDER BY 1"
      )

    List.flatten(rows)
  end

  defp table? do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = 'social_idea_selection_events'"
      )

    n == 1
  end

  test "carries the old-code-compatible waiver and is not listed as irreversible" do
    assert File.exists?(@irreversible)
    source = File.read!(@path)
    assert source =~ ~r/^[ \t]*# old-code-compatible:[ \t]*additive/m
    assert source =~ "previous release never reads or writes any of them"
    refute "20261122090000" in (@irreversible |> File.read!() |> String.split("\n", trim: true))
  end

  test "down on an empty selection state rolls back and up restores it" do
    assert columns() == ["selected_at", "selected_by_user_id"]
    assert table?()

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @opts)
    assert columns() == []
    refute table?()

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM schema_migrations WHERE version = $1", [@version])

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @opts)
    assert columns() == ["selected_at", "selected_by_user_id"]
    assert table?()
  end

  describe "down refuses and keeps everything when history exists" do
    setup do
      ctx = approval_fixture() |> with_ideas_runtime()

      {:ok, idea} =
        Ideas.create(ctx.org_id, ctx.profile.id, %{title: "Keep me"}, {:agent, ctx.g.id})

      Map.put(ctx, :idea, idea)
    end

    test "a selected idea", ctx do
      {:ok, _, :changed} = Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})
      assert_refused()
      assert Repo.get!(Platform.Social.Idea, ctx.idea.id).selected_at
    end

    test "an event row with nothing currently selected", ctx do
      {:ok, _, :changed} = Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})

      {:ok, _, :changed} =
        Ideas.unselect_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})

      assert_refused()
      assert Repo.aggregate(Platform.Social.IdeaSelectionEvent, :count) == 2
    end

    defp assert_refused do
      assert_raise Ecto.MigrationError, ~r/refusing to roll back AddSocialIdeaSelection/, fn ->
        Ecto.Migrator.down(Repo, @version, @migration, @opts)
      end

      assert columns() == ["selected_at", "selected_by_user_id"]
      assert table?()

      assert %{rows: [[1]]} =
               Repo.query!("SELECT count(*) FROM schema_migrations WHERE version = $1", [@version])
    end
  end
end
