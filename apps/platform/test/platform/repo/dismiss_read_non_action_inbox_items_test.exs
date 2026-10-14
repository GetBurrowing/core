defmodule Platform.Repo.DismissReadNonActionInboxItemsTest do
  @moduledoc """
  The regression guard for migration
  `20261007160000_dismiss_read_non_action_inbox_items.exs` (task `01a11703`
  stage 1).

  Test databases are built by running the migrations against an EMPTY schema,
  so the backfill sweeps zero rows in CI and nothing downstream notices whether
  it exists. Like `backfill_read_as_dismissed_test.exs`, this file locates the
  migration on disk, loads it, and executes the EXACT statement it runs
  (`backfill_sql/0`, the same module attribute) against seeded rows. Deleting
  the migration fails the lookup instead of silently passing.
  """
  use Platform.DataCase, async: true

  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Repo

  @migration_module Platform.Repo.Migrations.DismissReadNonActionInboxItems
  @migration_glob "*_dismiss_read_non_action_inbox_items.exs"

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "User #{n}",
      email: "user-#{n}@example.com",
      oidc_sub: "sub-#{n}"
    })
  end

  defp emit_row!(user, kind, source_type, attrs) do
    {:ok, item} =
      Inbox.emit(%{
        user_id: user.id,
        kind: kind,
        source_type: source_type,
        source_id: Ecto.UUID.generate(),
        title: "row",
        url: "/inbox"
      })

    item |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp long_ago(seconds_back) do
    DateTime.utc_now() |> DateTime.add(-seconds_back, :second)
  end

  defp run_backfill! do
    sql = apply(load_migration!(), :backfill_sql, [])
    %Postgrex.Result{num_rows: n} = Repo.query!(sql)
    n
  end

  defp load_migration! do
    paths =
      :platform
      |> Application.app_dir("priv/repo/migrations")
      |> Path.join(@migration_glob)
      |> Path.wildcard()

    case paths do
      [path] ->
        unless Code.ensure_loaded?(@migration_module), do: Code.require_file(path)
        @migration_module

      [] ->
        flunk("Expected one migration matching #{@migration_glob}; found none.")

      many ->
        flunk("Expected exactly one migration, found: #{inspect(many)}")
    end
  end

  test "a read chat_mention is dismissed as of when it was read" do
    user = insert_user()
    read_at = long_ago(86_400)
    mention = emit_row!(user, "chat_mention", "chat_message", %{read_at: read_at})

    # Precondition: listed before the backfill.
    assert [%Item{}] = user.id |> Inbox.unread_scope() |> Repo.all()

    assert run_backfill!() == 1

    row = Repo.get!(Item, mention.id)
    assert row.dismissed_at == read_at
    assert row.read_at == read_at
    assert user.id |> Inbox.unread_scope() |> Repo.all() == []
  end

  test "a read task_plan_review keeps dismissed_at nil" do
    user = insert_user()
    review = emit_row!(user, "task_plan_review", "task", %{read_at: long_ago(86_400)})

    assert run_backfill!() == 0
    assert %Item{dismissed_at: nil} = Repo.get!(Item, review.id)
  end

  test "an unread non-action row and an already-dismissed row are left alone" do
    user = insert_user()
    unread = emit_row!(user, "meeting_invited", "meeting", %{})
    dismissed_at = long_ago(3_600)

    dismissed =
      emit_row!(user, "chat_mention", "chat_message", %{
        read_at: long_ago(86_400),
        dismissed_at: dismissed_at
      })

    assert run_backfill!() == 0
    assert %Item{dismissed_at: nil, read_at: nil} = Repo.get!(Item, unread.id)
    assert Repo.get!(Item, dismissed.id).dismissed_at == dismissed_at
  end

  test "a second run touches 0 rows" do
    user = insert_user()
    emit_row!(user, "lifecycle_step_failed", "task", %{read_at: long_ago(86_400)})

    assert run_backfill!() == 1
    assert run_backfill!() == 0
  end
end
