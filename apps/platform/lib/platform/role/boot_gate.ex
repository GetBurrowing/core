defmodule Platform.Role.BootGate do
  @moduledoc """
  The web role's boot gate (task 01a155a6 stage 2). A one-shot child that
  `Platform.Application.children/2` places directly after `Platform.Vault.Encryption`
  and `Platform.Repo` under `:web` only. `init/1` runs three checks and
  returns `:ignore` when they pass, or `{:stop, message}` when any fails. A
  stop fails `Platform.Supervisor`'s start, so the Endpoint never binds and a
  web node that would misread or corrupt prod's data never serves a request.

  The full role has no gate: it migrates in the entrypoint and
  `Platform.Release.migrate/0`, exactly as before.

  ## 1. Migrations

  A web node never migrates. It refuses to boot when the branch carries a
  migration the database has not applied (`{:down, version, name}`), and the
  message lists every one as `version name`. A rung that needs schema ships
  its expand-only migration to main first; see `Platform.Role`.

  The check is read-only on prod's `schema_migrations`, under a DML-only DB
  role. `Ecto.Migrator.migrations/3` is called with BOTH
  `skip_table_creation: true` and `migration_lock: false`: in ecto_sql
  3.13.5, `migrated_versions/2` otherwise runs `CREATE TABLE IF NOT EXISTS
  schema_migrations` (which fails without CREATE on the schema) and takes
  `LOCK TABLE schema_migrations IN SHARE UPDATE EXCLUSIVE MODE` (which would
  serialise against a concurrent prod migrate). The paths are
  `Platform.Release.migrations_paths/1`, so build-time module migrations
  count.

  A version the database has applied but this branch has no file for
  (`{:up, version, "** FILE NOT FOUND **"}`, the branch is behind prod) is
  logged as a warning listing them, and does not refuse.

  ## 2. Vault key

  `VAULT_MASTER_KEY` must be set. A generated key would encrypt every write
  from this node with a key prod cannot read. (`config/runtime.exs` already
  raises on a missing key under `MIX_ENV=prod`, and `Platform.Role.validate!/2`
  confines the web role to prod, so this is the second line, kept because the
  gate is the check that names the role.)

  Then one `vault_credentials.encrypted_data` value, if any row exists, is
  decrypted with `Platform.Vault.Encryption`. A failure means this node's key
  is not prod's key. Note the shape: Cloak's AES-GCM cipher returns
  `{:ok, :error}` for a ciphertext under a different key (the `:crypto` AEAD
  failure atom wrapped as plaintext), so only `{:ok, binary}` counts as a
  decrypt.

  ## Injection

  `init/1` takes `:migrations` (`Ecto.Migrator.migrations/3`'s shape),
  `:vault_key` (a zero-arity reader) and `:repo`, so the checks run in the SQL
  sandbox without a real web boot.
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  @file_not_found "** FILE NOT FOUND **"

  @migrator_opts [skip_table_creation: true, migration_lock: false]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "The options every migration status read passes to `Ecto.Migrator.migrations/3`."
  @spec migrator_opts() :: keyword()
  def migrator_opts, do: @migrator_opts

  @impl true
  def init(opts) do
    repo = Keyword.get(opts, :repo, Platform.Repo)
    migrations = Keyword.get(opts, :migrations, &Ecto.Migrator.migrations/3)
    vault_key = Keyword.get(opts, :vault_key, fn -> System.get_env("VAULT_MASTER_KEY") end)

    failures =
      [check_migrations(repo, migrations), check_vault(repo, vault_key)]
      |> Enum.reject(&(&1 == :ok))
      |> Enum.map(fn {:error, message} -> message end)

    case failures do
      [] ->
        :ignore

      failures ->
        message =
          "PLATFORM_ROLE=web refuses to boot:\n\n" <> Enum.join(failures, "\n\n")

        Logger.error("[role.boot_gate] " <> message)
        {:stop, message}
    end
  end

  @doc false
  @spec check_migrations(module(), function()) :: :ok | {:error, String.t()}
  def check_migrations(repo, migrations) do
    statuses = migrations.(repo, Platform.Release.migrations_paths(repo), @migrator_opts)

    missing_files = for {:up, version, @file_not_found} <- statuses, do: version

    if missing_files != [] do
      Logger.warning(
        "[role.boot_gate] the database has applied #{length(missing_files)} migration(s) " <>
          "this branch has no file for (the branch is behind prod): " <>
          Enum.map_join(missing_files, ", ", &to_string/1)
      )
    end

    case for {:down, version, name} <- statuses, do: "  #{version} #{name}" do
      [] ->
        :ok

      pending ->
        {:error,
         "#{length(pending)} migration(s) on this branch are not applied to the database. " <>
           "A web node never migrates: merge the migration to main and let prod apply it " <>
           "first.\n" <> Enum.join(pending, "\n")}
    end
  end

  @doc false
  @spec check_vault(module(), (-> String.t() | nil)) :: :ok | {:error, String.t()}
  def check_vault(repo, vault_key) do
    case vault_key.() do
      key when key in [nil, ""] ->
        {:error,
         "VAULT_MASTER_KEY is not set. A web node must run with prod's key, or every " <>
           "credential it writes is unreadable by prod."}

      _key ->
        probe_decrypt(repo)
    end
  end

  defp probe_decrypt(repo) do
    sample = repo.one(from(c in "vault_credentials", select: c.encrypted_data, limit: 1))

    case sample do
      nil ->
        :ok

      ciphertext ->
        case decrypt(ciphertext) do
          {:ok, plaintext} when is_binary(plaintext) ->
            :ok

          other ->
            {:error,
             "VAULT_MASTER_KEY does not decrypt a vault_credentials row " <>
               "(#{inspect(failure_kind(other))}): this node's key is not the database's key."}
        end
    end
  end

  defp decrypt(ciphertext) do
    Platform.Vault.Encryption.decrypt(ciphertext)
  rescue
    error -> {:error, error}
  end

  # Never the plaintext or the ciphertext: only what kind of failure it was.
  defp failure_kind({:ok, :error}), do: :aead_tag_mismatch
  defp failure_kind({:error, %{__struct__: struct}}), do: struct
  defp failure_kind(:error), do: :error
  defp failure_kind(_other), do: :unexpected
end
