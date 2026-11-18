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

  ## Mail owner mapping (task 01a1ea5b stage 5)

  `apply_mail_owner_mapping/2` assigns owners to mail accounts from a JSON
  file, on a RUNNING node (it needs the app, not only the repo):

      /app/bin/platform rpc 'Platform.Release.apply_mail_owner_mapping("/path/mapping.json", actor_email: "admin@example.com")'
      /app/bin/platform rpc 'Platform.Release.apply_mail_owner_mapping("/path/mapping.json", actor_email: "admin@example.com", apply: true)'

  Dry-run unless `apply: true`. See the function doc for the file shape.
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

  @doc """
  Assign mail-account owners from the JSON file at `path` (task 01a1ea5b
  stage 5, Email privacy). DRY-RUN by default: nothing is written unless
  `apply: true`. `actor_email:` (required) names the org admin the writes are
  attributed to; every write goes through `Platform.Mail.Ownership.set_owner/3`
  or `grant/3`, actor-checked and audited, one audit row each.

  The file maps a mailbox ADDRESS (an account's login username,
  case-insensitive) to its ownership (`priv/mail_owner_mappings/example.json`
  is a worked example; an install's real mapping names its people and is
  kept with that install's operations, never in this repository):

      {
        "a@example.com": {"kind": "personal", "owner_email": "a@example.com"},
        "team@example.com": {"kind": "shared", "member_emails": ["a@example.com"]},
        "both@example.com": [
          {"account_name": "Both - personal", "kind": "personal", "owner_email": "b@example.com"},
          {"account_name": "Both - meetings", "kind": "shared", "member_emails": []}
        ]
      }

  A list value is for an address several accounts log in with: each entry
  must then name its account by `account_name` (exact). Archived accounts are
  ignored.

  Idempotent: an account already owned exactly as mapped is `unchanged`, and
  a shared member who already reads it is skipped. It NEVER deletes and never
  reassigns: an account already assigned to a different kind or owner is
  REFUSED (`Ownership.set_owner/3` would clear its grants), as is an unknown
  address, an ambiguous one, an unknown user, a user who is not an internal
  member of the account's org, an actor who is not its org admin, and a
  malformed entry. ANY refusal changes nothing: the checks run before any
  write, and the writes run in one transaction that rolls back whole on any
  error.

  Prints addresses and outcomes only. Returns `{:ok, %{dry_run, outcomes}}`
  or `{:error, %{refusals, outcomes}}`, each outcome `{address, text}`.
  """
  @spec apply_mail_owner_mapping(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def apply_mail_owner_mapping(path, opts \\ []) do
    load_app()
    apply? = Keyword.get(opts, :apply, false) == true

    result =
      with {:ok, mapping} <- read_mapping(path),
           {:ok, actor} <- mapping_actor(Keyword.get(opts, :actor_email)) do
        plan = mapping |> Enum.flat_map(&plan_entry(&1, actor)) |> refuse_duplicates()

        case for({:refused, address, text} <- plan, do: {address, text}) do
          [] when apply? -> apply_mapping(plan, actor)
          [] -> {:ok, %{dry_run: true, outcomes: outcomes(plan, "would ")}}
          refusals -> {:error, %{refusals: refusals, outcomes: outcomes(plan, "would ")}}
        end
      else
        {:error, text} -> {:error, %{refusals: [{path_label(path), text}], outcomes: []}}
      end

    print_mapping_result(result, apply?)
    result
  end

  # One account mapped by two entries (say "A@x" and "a@x") would be
  # assigned twice in one run, the second write reassigning the first:
  # refuse every entry naming it.
  defp refuse_duplicates(plan) do
    counts =
      plan
      |> Enum.flat_map(fn
        {:ok, _label, %{account: account}} -> [account.id]
        _ -> []
      end)
      |> Enum.frequencies()

    Enum.map(plan, fn
      {:ok, label, %{account: account}} = step ->
        if counts[account.id] > 1,
          do: {:refused, label, "refused: this account is mapped more than once"},
          else: step

      other ->
        other
    end)
  end

  defp path_label(path) when is_binary(path), do: Path.basename(path)
  defp path_label(_), do: "mapping"

  defp read_mapping(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = mapping} <- Jason.decode(body) do
      {:ok, Enum.sort_by(mapping, &elem(&1, 0))}
    else
      {:ok, _other} -> {:error, "refused: the file must hold a JSON object of address => entry"}
      {:error, %Jason.DecodeError{}} -> {:error, "refused: the file is not valid JSON"}
      {:error, reason} -> {:error, "refused: cannot read the file (#{inspect(reason)})"}
    end
  end

  defp read_mapping(_), do: {:error, "refused: no mapping path"}

  defp mapping_actor(email) when is_binary(email) and email != "" do
    case mapping_user(email) do
      nil -> {:error, "refused: actor #{email} is not a user"}
      user -> {:ok, user}
    end
  end

  defp mapping_actor(_), do: {:error, "refused: actor_email is required"}

  defp mapping_user(email) when is_binary(email) do
    import Ecto.Query

    Platform.Repo.one(
      from(u in Platform.Accounts.User,
        where: fragment("lower(?)", u.email) == ^String.downcase(String.trim(email)),
        limit: 1
      )
    )
  end

  defp mapping_accounts(address) do
    import Ecto.Query

    Platform.Repo.all(
      from(a in Platform.Mail.Account,
        where:
          fragment("lower(?)", a.username) == ^String.downcase(String.trim(address)) and
            is_nil(a.archived_at),
        order_by: [asc: a.name, asc: a.id]
      )
    )
  end

  # Each entry becomes `{:refused, address, text}` or `{:ok, address, steps}`
  # where `steps` are the writes the apply pass will make (none = unchanged).
  defp plan_entry({address, entries}, actor) when is_list(entries) do
    case mapping_accounts(address) do
      [] ->
        [{:refused, address, "refused: no mail account logs in with this address"}]

      accounts ->
        Enum.map(entries, fn
          %{"account_name" => name} = entry when is_binary(name) ->
            case Enum.filter(accounts, &(&1.name == name)) do
              [account] -> plan_account(address, account, entry, actor)
              [] -> {:refused, address, "refused: no account named #{inspect(name)}"}
              _ -> {:refused, address, "refused: several accounts are named #{inspect(name)}"}
            end

          _ ->
            {:refused, address, "refused: a list entry must name its account_name"}
        end)
    end
  end

  defp plan_entry({address, %{} = entry}, actor) do
    case mapping_accounts(address) do
      [] ->
        [{:refused, address, "refused: no mail account logs in with this address"}]

      [account] ->
        case entry do
          %{"account_name" => name} when is_binary(name) and name != account.name ->
            [{:refused, address, "refused: no account named #{inspect(name)}"}]

          _ ->
            [plan_account(address, account, entry, actor)]
        end

      _several ->
        plan_entry({address, [entry]}, actor)
    end
  end

  defp plan_entry({address, _entry}, _actor),
    do: [{:refused, address, "refused: an entry must be an object or a list of objects"}]

  defp plan_account(address, account, entry, actor) do
    label = "#{address} (#{account.name})"

    with :ok <- mapping_admin(account, actor),
         {:ok, kind, owner, members} <- mapping_target(entry, account),
         :ok <- mapping_not_reassigned(account, kind, owner) do
      owner_step =
        if account.owner_kind == kind and account.owner_user_id == (owner && owner.id),
          do: [],
          else: [{:set_owner, kind, owner}]

      existing = existing_member_ids(account)

      member_steps =
        for user <- members, not MapSet.member?(existing, user.id), do: {:grant, user}

      {:ok, label, %{account: account, steps: owner_step ++ member_steps}}
    else
      {:error, text} -> {:refused, label, text}
    end
  end

  defp mapping_admin(account, actor) do
    if Platform.Tenancy.org_admin?(actor, account.org_id),
      do: :ok,
      else: {:error, "refused: the actor is not an admin of this account's org"}
  end

  defp mapping_target(%{"kind" => "personal"} = entry, account) do
    with {:ok, owner} <- mapping_member(entry["owner_email"], account),
         [] <- List.wrap(entry["member_emails"]) do
      {:ok, "personal", owner, []}
    else
      {:error, _} = error -> error
      _members -> {:error, "refused: a personal mailbox has no members"}
    end
  end

  defp mapping_target(%{"kind" => "shared"} = entry, account) do
    emails = entry["member_emails"] || []

    cond do
      Map.has_key?(entry, "owner_email") ->
        {:error, "refused: a shared mailbox has no owner"}

      not (is_list(emails) and Enum.all?(emails, &is_binary/1)) ->
        {:error, "refused: member_emails must be a list of addresses"}

      true ->
        emails
        |> Enum.reduce_while({:ok, []}, fn email, {:ok, acc} ->
          case mapping_member(email, account) do
            {:ok, user} -> {:cont, {:ok, [user | acc]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, users} -> {:ok, "shared", nil, users |> Enum.reverse() |> Enum.uniq_by(& &1.id)}
          error -> error
        end
    end
  end

  defp mapping_target(_entry, _account),
    do: {:error, "refused: kind must be \"personal\" or \"shared\""}

  defp mapping_member(email, account) when is_binary(email) do
    case mapping_user(email) do
      nil ->
        {:error, "refused: #{email} is not a user"}

      user ->
        if Platform.Tenancy.internal_member?(user, account.org_id),
          do: {:ok, user},
          else: {:error, "refused: #{email} is not an internal member of this account's org"}
    end
  end

  defp mapping_member(_email, _account), do: {:error, "refused: owner_email is required"}

  # Never reassign: only an unassigned account, or one already exactly as
  # mapped, may proceed. `set_owner/3` clears grants on any change, and this
  # command never deletes.
  defp mapping_not_reassigned(%{owner_kind: "unassigned"}, _kind, _owner), do: :ok

  defp mapping_not_reassigned(account, kind, owner) do
    if account.owner_kind == kind and account.owner_user_id == (owner && owner.id),
      do: :ok,
      else:
        {:error,
         "refused: already assigned as #{account.owner_kind}; reassign it from Email > Accounts"}
  end

  defp existing_member_ids(account) do
    import Ecto.Query

    from(g in Platform.Mail.AccountGrant,
      where: g.account_id == ^account.id and g.principal_type == "user",
      select: g.principal_id
    )
    |> Platform.Repo.all()
    |> MapSet.new()
  end

  defp apply_mapping(plan, actor) do
    Platform.Repo.transaction(fn ->
      Enum.map(plan, fn {:ok, label, %{account: account, steps: steps}} ->
        Enum.each(steps, &apply_step!(&1, account, actor, label))
        {:ok, label, %{account: account, steps: steps}}
      end)
    end)
    |> case do
      {:ok, applied} ->
        {:ok, %{dry_run: false, outcomes: outcomes(applied, "")}}

      {:error, {label, text}} ->
        {:error, %{refusals: [{label, text}], outcomes: []}}

      {:error, other} ->
        {:error, %{refusals: [{"mapping", "refused: #{inspect(other)}"}], outcomes: []}}
    end
  end

  defp apply_step!({:set_owner, kind, owner}, account, actor, label) do
    attrs = %{kind: kind, owner_user_id: owner && owner.id}

    case Platform.Mail.Ownership.set_owner(actor, account, attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> Platform.Repo.rollback({label, "refused: set_owner #{inspect(reason)}"})
    end
  end

  defp apply_step!({:grant, user}, account, actor, label) do
    case Platform.Mail.Ownership.grant(actor, account, {:user, user.id}) do
      {:ok, _} ->
        :ok

      {:error, :already_granted} ->
        :ok

      {:error, reason} ->
        Platform.Repo.rollback({label, "refused: grant #{user.email} #{inspect(reason)}"})
    end
  end

  defp outcomes(plan, prefix) do
    Enum.map(plan, fn
      {:refused, label, text} ->
        {label, text}

      {:ok, label, %{steps: []}} ->
        {label, "unchanged"}

      {:ok, label, %{steps: steps}} ->
        {label, prefix <> Enum.map_join(steps, "; ", &step_text/1)}
    end)
  end

  defp step_text({:set_owner, "personal", owner}), do: "set personal, owner #{owner.email}"
  defp step_text({:set_owner, kind, _owner}), do: "set #{kind}"
  defp step_text({:grant, user}), do: "add member #{user.email}"

  defp print_mapping_result(result, apply?) do
    {status, %{outcomes: outcomes} = body} = result
    mode = if apply?, do: "APPLY", else: "DRY RUN (pass apply: true to write)"
    IO.puts("mail owner mapping: #{mode}")
    Enum.each(outcomes, fn {label, text} -> IO.puts("  #{label}: #{text}") end)

    case status do
      :ok ->
        IO.puts("mail owner mapping: ok")

      :error ->
        if outcomes == [],
          do: Enum.each(body.refusals, fn {label, text} -> IO.puts("  #{label}: #{text}") end)

        IO.puts("mail owner mapping: REFUSED, nothing was changed")
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
