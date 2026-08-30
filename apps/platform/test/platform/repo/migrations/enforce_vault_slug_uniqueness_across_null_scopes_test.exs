defmodule Platform.Repo.Migrations.EnforceVaultSlugUniquenessAcrossNullScopesTest do
  @moduledoc """
  Task `01a04e18` — behavioural coverage for
  `20260829140000_enforce_vault_slug_uniqueness_across_null_scopes`.

  ## THE DEDUPE PASS IS INVISIBLE TO CI, WHICH IS WHY THIS FILE EXISTS

  The suite runs against a freshly created, freshly migrated, EMPTY database.
  The parking pass matches zero rows there and does exactly what a correct one
  does: nothing. `mix ecto.migrate` is green whether that pass is present,
  broken, or deleted — and deleting it is not a harmless mutation, it is the
  difference between a clean production migration and one that aborts on
  `ERROR 23505 could not create unique index`.

  So the evidence has to be seeded duplicates, the migration run, and
  assertions read back off the rows.

  ## It drives the shipped `up/0`, not a copy of its SQL

  Copying the SQL into the test would prove the SQL is correct but not that the
  shipped migration contains it, so gutting `up/0` would leave it green. This
  file runs `up/0` and `down/0` themselves through `Ecto.Migration.Runner`,
  which is also the only way to test the thing that matters most here: the
  ORDER of the two steps. Parking has to happen before the index build, and a
  helper that ran only the parking pass could never tell you that.

  `down/0` restores the permissive `NULLS DISTINCT` index. That is what lets
  `setup` insert duplicate rows at all, and what makes `up/0` re-runnable
  inside the sandbox transaction, which rolls everything back with the test.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Vault.AccessGrant
  alias Platform.Vault.Credential

  @migration Platform.Repo.Migrations.EnforceVaultSlugUniquenessAcrossNullScopes

  # The public migrator API runs a migration inside a Task with its own
  # checkout, which the SQL sandbox refuses — the test process is already
  # holding the one shared connection. Driving `Ecto.Migration.Runner`
  # directly keeps every statement on the test process's connection, so the
  # whole thing still rolls back with the test. `:forward` in both directions
  # because this migration issues plain `execute/1` strings, which the runner
  # refuses to replay in `:backward`.
  defp run_migration!(operation) when operation in [:up, :down] do
    {:ok, runner} =
      Ecto.Migration.Runner.start_link(
        {self(), Repo, Repo.config(), @migration, :forward, operation,
         %{level: false, sql: false}}
      )

    Ecto.Migration.Runner.metadata(runner, [])
    apply(@migration, operation, [])
    Ecto.Migration.Runner.flush()
    Ecto.Migration.Runner.stop()
    :ok
  end

  # Migration source lives under `priv/repo/migrations/` and is not on the
  # compile path — walk up from `test/platform/repo/migrations/<this>.exs` to
  # `apps/platform/` and back down into `priv/repo/migrations/`.
  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/" <>
                      "20260829140000_enforce_vault_slug_uniqueness_across_null_scopes.exs",
                    __DIR__
                  )

  setup_all do
    # `mix test` migrates in the same VM, so the module is usually already
    # loaded; requiring it again would only emit a redefinition warning.
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@migration_path)
    :ok
  end

  defp insert_raw!(slug, opts) do
    now = DateTime.utc_now()

    Repo.insert!(%Credential{
      workspace_id: Keyword.get(opts, :workspace_id),
      slug: slug,
      name: slug,
      credential_type: "api_key",
      encrypted_data: Keyword.fetch!(opts, :value),
      scope_type: Keyword.get(opts, :scope_type, "platform"),
      scope_id: Keyword.get(opts, :scope_id),
      rotated_at: Keyword.get(opts, :rotated_at),
      inserted_at: Keyword.get(opts, :inserted_at, now),
      updated_at: Keyword.get(opts, :inserted_at, now)
    })
  end

  defp reload(%Credential{id: id}), do: Repo.get!(Credential, id)

  defp index_definition do
    %{rows: [[definition]]} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE indexname = 'vault_credentials_unique_slug_per_scope'"
      )

    definition
  end

  describe "the dedupe pass" do
    setup do
      # Restores the shipped NULLS DISTINCT index, which is what lets the
      # duplicates below be inserted at all. Everything here runs inside the
      # sandbox transaction and is rolled back with the test.
      :ok = run_migration!(:down)

      # CONTROL for the whole file. If `down/0` did not actually relax the
      # index, every "duplicates were parked" assertion below would be
      # measuring an empty setup.
      refute index_definition() =~ "NULLS NOT DISTINCT",
             "expected down/0 to restore the permissive index"

      :ok
    end

    test "keeps the most recently rotated row and parks the rest under __dup_ slugs" do
      slug = "dedupe-#{System.unique_integer([:positive])}"
      t0 = ~U[2026-01-01 00:00:00.000000Z]

      oldest =
        insert_raw!(slug, value: "OLDEST", rotated_at: t0, inserted_at: t0)

      newest =
        insert_raw!(slug,
          value: "NEWEST",
          rotated_at: DateTime.add(t0, 200, :second),
          inserted_at: DateTime.add(t0, 1, :second)
        )

      middle =
        insert_raw!(slug,
          value: "MIDDLE",
          rotated_at: DateTime.add(t0, 100, :second),
          inserted_at: DateTime.add(t0, 2, :second)
        )

      # The bug, reproduced: three rows share one slug at one scope.
      assert Repo.one(from(c in Credential, where: c.slug == ^slug, select: count(c.id))) == 3

      :ok = run_migration!(:up)

      # The winner keeps the slug. Note it is neither the first- nor the
      # last-inserted row, so this cannot pass by accident on insertion order.
      assert reload(newest).slug == slug
      assert reload(oldest).slug == "#{slug}__dup_#{oldest.id}"
      assert reload(middle).slug == "#{slug}__dup_#{middle.id}"

      assert Repo.one(from(c in Credential, where: c.slug == ^slug, select: count(c.id))) == 1
    end

    test "falls back to inserted_at when no row has ever been rotated" do
      slug = "dedupe-norotate-#{System.unique_integer([:positive])}"
      t0 = ~U[2026-01-01 00:00:00.000000Z]

      first = insert_raw!(slug, value: "FIRST", inserted_at: t0)
      last = insert_raw!(slug, value: "LAST", inserted_at: DateTime.add(t0, 60, :second))

      :ok = run_migration!(:up)

      assert reload(last).slug == slug
      assert reload(first).slug == "#{slug}__dup_#{first.id}"
    end

    test "a parked row keeps its value, its grants and its id" do
      # The ticket's specific worry: `Platform.Vault.do_delete/3` deletes grants,
      # and `vault_access_grants.credential_id` is ON DELETE CASCADE, so a
      # dedupe that DELETED the loser would drop its grants silently. This one
      # renames instead, so there is nothing to merge and nothing to lose.
      slug = "dedupe-grants-#{System.unique_integer([:positive])}"
      t0 = ~U[2026-01-01 00:00:00.000000Z]
      grantee = Ecto.UUID.generate()

      loser = insert_raw!(slug, value: "LOSER-VALUE", rotated_at: t0, inserted_at: t0)

      _winner =
        insert_raw!(slug,
          value: "WINNER-VALUE",
          rotated_at: DateTime.add(t0, 60, :second),
          inserted_at: DateTime.add(t0, 1, :second)
        )

      grant =
        Repo.insert!(%AccessGrant{
          credential_id: loser.id,
          grantee_type: "agent",
          grantee_id: grantee,
          permissions: ["use", "rotate"]
        })

      :ok = run_migration!(:up)

      parked = reload(loser)
      assert parked.id == loser.id
      assert parked.encrypted_data == "LOSER-VALUE", "the parked row's value must survive"

      reloaded_grant = Repo.get!(AccessGrant, grant.id)
      assert reloaded_grant.credential_id == loser.id, "the grant must still point at its own row"
      assert reloaded_grant.permissions == ["use", "rotate"]
    end

    test "parks duplicates at every scope shape the NULLS DISTINCT index let through" do
      stamp = System.unique_integer([:positive])
      t0 = ~U[2026-01-01 00:00:00.000000Z]
      agent_id = Ecto.UUID.generate()
      workspace_id = Ecto.UUID.generate()

      shapes = [
        {"platform-#{stamp}", [scope_type: "platform"]},
        {"agent-#{stamp}", [scope_type: "agent", scope_id: agent_id]},
        {"wsplatform-#{stamp}", [scope_type: "platform", workspace_id: workspace_id]}
      ]

      pairs =
        for {slug, opts} <- shapes do
          loser = insert_raw!(slug, [value: "A", rotated_at: t0, inserted_at: t0] ++ opts)

          winner =
            insert_raw!(
              slug,
              [
                value: "B",
                rotated_at: DateTime.add(t0, 60, :second),
                inserted_at: DateTime.add(t0, 1, :second)
              ] ++ opts
            )

          {slug, loser, winner}
        end

      # CONTROL: all three shapes really did duplicate under the old index.
      assert length(pairs) == 3

      for {slug, _loser, _winner} <- pairs do
        assert Repo.one(from(c in Credential, where: c.slug == ^slug, select: count(c.id))) == 2
      end

      :ok = run_migration!(:up)

      for {slug, loser, winner} <- pairs do
        assert reload(winner).slug == slug
        assert reload(loser).slug == "#{slug}__dup_#{loser.id}"
      end
    end

    test "leaves legitimate cross-scope rows with the same slug alone" do
      slug = "dedupe-crossscope-#{System.unique_integer([:positive])}"

      platform = insert_raw!(slug, value: "P", scope_type: "platform")
      agent = insert_raw!(slug, value: "A", scope_type: "agent", scope_id: Ecto.UUID.generate())

      :ok = run_migration!(:up)

      assert reload(platform).slug == slug
      assert reload(agent).slug == slug
    end

    test "the migration makes a duplicated platform credential rotatable again" do
      # The operational damage the ticket describes, end to end. Since #871
      # `rotate/3` refuses an ambiguous slug rather than rotating a coin-flip
      # row — correct, but it leaves a duplicated platform credential
      # unrotatable. This is the pre-migration shape, and the assertion that
      # `up/0` is what clears it.
      #
      # It is also where the #871 refusal branch stays covered now that `put/4`
      # can no longer build a same-scope pair: these rows are inserted under
      # the deliberately relaxed index from `setup`.
      slug = "legacy-ambiguous-#{System.unique_integer([:positive])}"
      t0 = ~U[2026-01-01 00:00:00.000000Z]

      loser = insert_raw!(slug, value: "STALE", rotated_at: t0, inserted_at: t0)

      winner =
        insert_raw!(slug,
          value: "LIVE",
          rotated_at: DateTime.add(t0, 60, :second),
          inserted_at: DateTime.add(t0, 1, :second)
        )

      assert {:error, :ambiguous_slug} =
               Platform.Vault.rotate(slug, "SHOULD-NOT-LAND",
                 scope: {:platform, nil},
                 accessor: {:system, nil}
               )

      # Nothing moved.
      assert reload(loser).encrypted_data == "STALE"
      assert reload(winner).encrypted_data == "LIVE"

      :ok = run_migration!(:up)

      # The same call now lands, on the row that was most recently rotated.
      assert {:ok, _} =
               Platform.Vault.rotate(slug, "ROTATED",
                 scope: {:platform, nil},
                 accessor: {:system, nil}
               )

      assert reload(winner).encrypted_data == "ROTATED"
      assert reload(loser).encrypted_data == "STALE", "the parked row must not be rotated"
    end

    test "up/0 is a no-op on a table with no duplicates, and installs the strict index" do
      slug = "dedupe-clean-#{System.unique_integer([:positive])}"
      only = insert_raw!(slug, value: "ONLY")

      :ok = run_migration!(:up)

      assert reload(only).slug == slug
      assert index_definition() =~ "NULLS NOT DISTINCT"
    end
  end
end
