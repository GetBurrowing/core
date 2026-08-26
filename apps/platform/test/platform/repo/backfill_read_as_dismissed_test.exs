defmodule Platform.Repo.BackfillReadAsDismissedTest do
  @moduledoc """
  The regression guard for migration
  `20260817120000_backfill_read_as_dismissed_inbox_items.exs` (task `01a00108`
  stage 4).

  ## Why this file exists, and why it loads the migration off disk

  Stage 4 moved "cleared" from `read_at OR dismissed_at` to `dismissed_at`
  alone. Before it, opening a row WAS clearing it, and the inbox has been live
  since `20260723185711` — so without the backfill, every row every user ever
  opened and never explicitly dismissed reappears at once as new work. The
  predicate change and the backfill are one change; shipping either alone is a
  defect, and only the backfill half has no other test that would notice.

  Nothing else can notice it, either. Test databases are built by running the
  migrations against an EMPTY schema, so the backfill sweeps zero rows in CI
  and every assertion downstream of it passes whether or not it exists. That is
  the vacuity this file is built to avoid: it locates the migration on disk,
  loads it, and executes the EXACT statement the migration executes
  (`backfill_sql/0` — the same module attribute, not a copy that could drift)
  against rows seeded to look like production history.

  Delete or empty the migration and these tests fail rather than silently
  passing, which is the property being bought. That was verified by doing it,
  not by assuming it.
  """
  use Platform.DataCase, async: true

  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Repo

  @migration_module Platform.Repo.Migrations.BackfillReadAsDismissedInboxItems
  @migration_glob "*_backfill_read_as_dismissed_inbox_items.exs"

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "User #{n}",
      email: "user-#{n}@example.com",
      oidc_sub: "sub-#{n}"
    })
  end

  # A row as it existed BEFORE stage 4: the user opened it (so `read_at` is
  # set), and never dismissed it, because dismissing was not how you cleared
  # things. Timestamps are set explicitly rather than via `mark_read/2` so the
  # "carried over, not stamped with now()" assertion has something exact to
  # compare against.
  defp emit_row!(user, attrs \\ %{}) do
    {:ok, item} =
      Inbox.emit(%{
        user_id: user.id,
        kind: "chat_mention",
        source_type: "chat_message",
        source_id: Ecto.UUID.generate(),
        title: "You were mentioned",
        url: "/chat/123"
      })

    case attrs do
      empty when empty == %{} -> item
      _ -> item |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end
  end

  defp long_ago(seconds_back) do
    DateTime.utc_now() |> DateTime.add(-seconds_back, :second)
  end

  # Locate the migration on disk and run its statement. `app_dir/2` resolves
  # through the build symlink to the source `priv`, so a deleted migration is a
  # failed lookup here rather than a silently skipped backfill.
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
        flunk("""
        The backfill migration is missing.

        Expected exactly one file matching #{@migration_glob} in the platform
        app's priv/repo/migrations. Without it, the stage-4 predicate change
        (`unread_scope/1` keying on `dismissed_at` alone) resurfaces every inbox
        row any user has ever opened and not dismissed. The two ship together.
        """)

      many ->
        flunk("Expected exactly one backfill migration, found: #{inspect(many)}")
    end
  end

  describe "the backfill preserves historical clears" do
    test "a previously-OPENED item does not resurface" do
      # THE assertion of stage 4. Under the old semantics this row was cleared —
      # the user opened it and it left their list. After the predicate change,
      # `dismissed_at` alone decides, and this row has none. The backfill is the
      # only thing standing between that and a user's whole history landing back
      # in their inbox as unfinished work.
      user = insert_user()
      read_at = long_ago(86_400)
      opened = emit_row!(user, %{read_at: read_at})

      # Precondition: without the backfill it IS back on the list. If this
      # assertion ever fails, the predicate change was reverted and the rest of
      # this test proves nothing.
      assert Inbox.unread_count(user.id) == 1,
             "expected the opened row to be visible pre-backfill — is unread_scope/1 " <>
               "still keyed on dismissed_at alone?"

      assert run_backfill!() == 1

      # Cleared, and cleared AS OF WHEN THEY OPENED IT — not stamped with the
      # deploy's now(), which would misreport everyone's history.
      row = Repo.get!(Item, opened.id)
      assert row.dismissed_at == read_at
      assert row.read_at == read_at

      # Gone from both sides, which are the same query.
      assert Inbox.unread_count(user.id) == 0
      assert user.id |> Inbox.unread_scope() |> Repo.all() == []
    end

    test "a row the user never opened is left alone — the backfill clears nothing new" do
      # The over-reach guard. A backfill that cleared unopened rows would erase
      # real outstanding work under cover of a data migration, which is worse
      # than the bug it fixes and would look identical in the counts.
      user = insert_user()
      untouched = emit_row!(user)

      assert run_backfill!() == 0

      assert %Item{dismissed_at: nil, read_at: nil} = Repo.get!(Item, untouched.id)
      assert Inbox.unread_count(user.id) == 1
    end

    test "an explicit dismissal keeps its own timestamp, even when the row was also read" do
      # `dismissed_at` is the truthful record of when the user actually cleared
      # it. The backfill must not overwrite it with an older `read_at`.
      user = insert_user()
      read_at = long_ago(86_400)
      dismissed_at = long_ago(3_600)
      row = emit_row!(user, %{read_at: read_at, dismissed_at: dismissed_at})

      assert run_backfill!() == 0

      reloaded = Repo.get!(Item, row.id)
      assert reloaded.dismissed_at == dismissed_at
      refute reloaded.dismissed_at == read_at
    end
  end

  describe "running it twice" do
    test "is a no-op on an unchanged database" do
      user = insert_user()
      _opened = emit_row!(user, %{read_at: long_ago(86_400)})

      assert run_backfill!() == 1
      assert run_backfill!() == 0
    end

    test "does not overwrite a dismissal that landed after the first run" do
      # The interleaving worth pinning: first run clears the row, the user
      # restores it (undo) and later dismisses it for real. A second run must
      # not drag the timestamp back to `read_at`.
      user = insert_user()
      read_at = long_ago(86_400)
      row = emit_row!(user, %{read_at: read_at})

      assert run_backfill!() == 1

      {:ok, _} = Inbox.restore_many(user.id, [row.id])
      {:ok, _} = Inbox.mark_dismissed(row.id, user.id)
      real_dismissal = Repo.get!(Item, row.id).dismissed_at

      assert run_backfill!() == 0
      assert Repo.get!(Item, row.id).dismissed_at == real_dismissal
    end
  end

  describe "scope" do
    test "sweeps every user's history, not just one" do
      # A data migration has no current_user. Pinned because the surrounding
      # context functions are all user-scoped and it would be an easy reflex to
      # write this one the same way.
      u1 = insert_user()
      u2 = insert_user()
      emit_row!(u1, %{read_at: long_ago(86_400)})
      emit_row!(u2, %{read_at: long_ago(86_400)})

      assert run_backfill!() == 2

      assert Inbox.unread_count(u1.id) == 0
      assert Inbox.unread_count(u2.id) == 0
    end
  end
end
