defmodule Platform.Role.BootGateTest do
  @moduledoc """
  The web role's boot gate (task 01a155a6 stage 2).

  The migrations source and the vault key reader are injected, so the
  refusals run inside the SQL sandbox. Two cases use the REAL
  `Ecto.Migrator.migrations/3` against the sandboxed repo and watch the SQL
  it sends through the repo's query telemetry: one with the gate's options
  (no CREATE, no LOCK) and its positive control with ecto_sql's defaults
  (CREATE and LOCK both seen), which shows the observer can fire.

  NOT async: the runtime.exs cases set OS environment variables, restored
  on exit.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Role.BootGate
  alias Platform.Vault.Credential

  @runtime_exs Path.expand("../../../config/runtime.exs", __DIR__)
  @key Base.encode64(:crypto.strong_rand_bytes(32))

  defp migrations_returning(statuses) do
    test = self()

    fn repo, paths, opts ->
      send(test, {:migrations_called, repo, paths, opts})
      statuses
    end
  end

  defp gate(statuses, key \\ @key) do
    BootGate.init(migrations: migrations_returning(statuses), vault_key: fn -> key end)
  end

  defp insert_credential! do
    %Credential{}
    |> Credential.changeset(%{
      slug: "boot-gate-probe-#{System.unique_integer([:positive])}",
      name: "boot gate probe",
      credential_type: "api_key",
      scope_type: "platform",
      encrypted_data: "probe plaintext"
    })
    |> Repo.insert!()
  end

  setup do
    # One row at most, so the probe's `limit: 1` reads the row the case wrote.
    Repo.delete_all("vault_credentials")
    :ok
  end

  describe "migrations" do
    test "a pending migration refuses, naming its version and name" do
      statuses = [
        {:up, 20_260_101_000_000, "create_things"},
        {:down, 20_261_019_000_001, "add_preview_column"},
        {:down, 20_261_019_000_002, "add_other_column"}
      ]

      assert {{:stop, message}, _log} = with_log(fn -> gate(statuses) end)
      assert message =~ "20261019000001 add_preview_column"
      assert message =~ "20261019000002 add_other_column"
      refute message =~ "create_things"
    end

    test "no pending migration passes" do
      assert gate([{:up, 20_260_101_000_000, "create_things"}]) == :ignore
    end

    test "a FILE NOT FOUND entry (branch behind prod) warns and passes" do
      statuses = [
        {:up, 20_260_101_000_000, "create_things"},
        {:up, 20_261_020_000_000, "** FILE NOT FOUND **"}
      ]

      {result, log} = with_log(fn -> gate(statuses) end)
      assert result == :ignore
      assert log =~ "20261020000000"
      assert log =~ "behind prod"
    end

    test "the status read passes skip_table_creation: true and migration_lock: false over Release's paths" do
      assert gate([]) == :ignore
      assert_received {:migrations_called, Platform.Repo, paths, opts}

      assert opts[:skip_table_creation] == true
      assert opts[:migration_lock] == false
      assert paths == Platform.Release.migrations_paths(Platform.Repo)
    end
  end

  describe "the real migrator against the sandbox" do
    defp capture_sql(fun) do
      test = self()
      handler = "boot-gate-sql-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:platform, :repo, :query],
        fn _event, _measurements, %{query: query}, _ -> send(test, {:sql, query}) end,
        nil
      )

      try do
        result = fun.()
        {result, collect_sql([])}
      after
        :telemetry.detach(handler)
      end
    end

    defp collect_sql(acc) do
      receive do
        {:sql, query} -> collect_sql([query | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp ddl_or_lock(statements),
      do: Enum.filter(statements, &(&1 =~ ~r/\bCREATE\b|\bLOCK\b|advisory_lock/i))

    test "the gate's options send no CREATE and no LOCK to schema_migrations" do
      paths = Platform.Release.migrations_paths(Platform.Repo)

      {statuses, sql} =
        capture_sql(fn ->
          Ecto.Migrator.migrations(Platform.Repo, paths, BootGate.migrator_opts())
        end)

      assert statuses != []
      assert Enum.any?(sql, &(&1 =~ "schema_migrations")), "the status read was not observed"
      assert ddl_or_lock(sql) == []
    end

    test "positive control: ecto_sql's defaults DO send CREATE and LOCK, so the observer can fire" do
      paths = Platform.Release.migrations_paths(Platform.Repo)
      {_statuses, sql} = capture_sql(fn -> Ecto.Migrator.migrations(Platform.Repo, paths) end)

      found = ddl_or_lock(sql)
      assert Enum.any?(found, &(&1 =~ ~r/\bCREATE\b/i)), "no CREATE seen in #{inspect(sql)}"
      assert Enum.any?(found, &(&1 =~ ~r/LOCK/i)), "no LOCK seen in #{inspect(sql)}"
    end

    test "the gate itself, unmocked, passes on the fully migrated test database" do
      assert BootGate.init(vault_key: fn -> @key end) == :ignore
    end
  end

  describe "vault key" do
    test "a missing VAULT_MASTER_KEY refuses" do
      for missing <- [nil, ""] do
        assert {{:stop, message}, _log} = with_log(fn -> gate([], missing) end)
        assert message =~ "VAULT_MASTER_KEY is not set"
      end
    end

    test "a credential row under this node's key passes" do
      insert_credential!()
      assert gate([]) == :ignore
    end

    test "no credential rows passes" do
      assert gate([]) == :ignore
    end

    test "a credential row encrypted with a different key refuses" do
      credential = insert_credential!()

      {:ok, foreign} =
        Cloak.Ciphers.AES.GCM.encrypt("probe plaintext",
          tag: "AES.GCM.V1",
          key: :crypto.strong_rand_bytes(32),
          iv_length: 12
        )

      # Schemaless, so the foreign ciphertext is written as-is, not re-encrypted.
      {1, _} =
        from(c in "vault_credentials", where: c.id == type(^credential.id, Ecto.UUID))
        |> Repo.update_all(set: [encrypted_data: foreign])

      assert {{:stop, message}, _log} = with_log(fn -> gate([]) end)
      assert message =~ "does not decrypt a vault_credentials row"
      refute message =~ "probe plaintext"
    end

    test "every failure is reported in one refusal" do
      assert {{:stop, message}, _log} =
               with_log(fn -> gate([{:down, 20_261_019_000_001, "add_preview_column"}], nil) end)

      assert message =~ "20261019000001 add_preview_column"
      assert message =~ "VAULT_MASTER_KEY is not set"
    end
  end

  describe "runtime.exs: the web role's signing secrets" do
    # Stage 1 confines PLATFORM_ROLE=web to MIX_ENV=prod (Platform.Role.validate!/2),
    # so web+dev raises that refusal before any secret is read. These cases
    # therefore drive web+prod with exactly one key missing.
    @secrets ~w(SECRET_KEY_BASE ATTACHMENT_SIGNING_KEY MEETING_GUEST_SIGNING_KEY MEETING_CALENDAR_SIGNING_KEY)
    @env ~w(PLATFORM_ROLE DATABASE_URL VAULT_MASTER_KEY) ++ @secrets

    setup do
      prev = Map.new(@env, &{&1, System.get_env(&1)})

      on_exit(fn ->
        for {name, value} <- prev do
          if value, do: System.put_env(name, value), else: System.delete_env(name)
        end
      end)

      System.put_env("PLATFORM_ROLE", "web")
      System.put_env("DATABASE_URL", "ecto://web:web@localhost/platform_unused")
      System.put_env("VAULT_MASTER_KEY", @key)
      for name <- @secrets, do: System.put_env(name, "#{name}-value-from-env-0123456789abcdef")
      :ok
    end

    test "web+prod with every secret set reads each one from the environment" do
      config = Config.Reader.read!(@runtime_exs, env: :prod)

      assert get_in(config, [:platform, :role]) == :web

      assert get_in(config, [:platform, PlatformWeb.Endpoint, :secret_key_base]) ==
               "SECRET_KEY_BASE-value-from-env-0123456789abcdef"

      for {key, name} <- [
            attachment_signing_key: "ATTACHMENT_SIGNING_KEY",
            meeting_guest_signing_key: "MEETING_GUEST_SIGNING_KEY",
            meeting_calendar_signing_key: "MEETING_CALENDAR_SIGNING_KEY"
          ] do
        assert get_in(config, [:platform, key]) == "#{name}-value-from-env-0123456789abcdef"
      end
    end

    test "web+prod with any one secret missing raises naming it" do
      for name <- @secrets do
        System.delete_env(name)

        assert_raise RuntimeError, ~r/#{name}/, fn ->
          Config.Reader.read!(@runtime_exs, env: :prod)
        end

        System.put_env(name, "#{name}-value-from-env-0123456789abcdef")
      end
    end
  end
end
