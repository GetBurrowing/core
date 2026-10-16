defmodule Platform.Access.Changes do
  @moduledoc """
  The access change ledger (task 01a1386e-30bd stage 1, RBAC stack member 6).

  **`commit/4` is the one writer to `access_grants`.** `Platform.Access.Grants`
  routes `grant`, `deny`, `revoke` and the memory-node re-point through it,
  and nothing else in `lib/` writes the table (pinned by
  `test/platform/access/grant_writer_guard_test.exs`). Inside ONE
  transaction it:

    1. takes a transaction-scoped advisory lock per affected tuple key, so
       two changes to one tuple (including an undo racing a change)
       serialize; then `SELECT … FOR UPDATE`s the affected rows;
    2. snapshots them as `before` (`Platform.Access.Grant.snapshot/1`);
    3. runs the mutation;
    4. snapshots the same rows as `after`;
    5. asks `Platform.Access.Delegation` whether the actor may make exactly
       that diff (stage 2), and whether every resource that had an
       `access.manage` holder before still has one;
    6. inserts the `Platform.Access.Change` row.

  A delegation refusal rolls everything back and returns
  `{:error, %{missing:, resource:, rule:}}`: no grant row and no change row.
  A root admin's change is recorded `bypass: "root_admin"`. `Scope.system/0`
  (the arity-1 `Grants` forms and the wiki re-point) is the operator path
  and skips step 5.

  A failure anywhere rolls back all of it: no grant changes without its
  ledger row, and no ledger row without its change. A mutation that leaves
  the rows as they were (`before == after`, e.g. a re-point with no grants on
  either node) writes no change row.

  After the transaction commits, `[:platform, :access, :grant_changed]` is
  emitted for the audit stream (`Platform.Audit.TelemetryHandler`). That
  event is a mirror for the platform stream, not a second source: undo reads
  the ledger only.

  ## Why a ledger and not `audit_events`

  `Platform.Audit.record/1` is fed by telemetry after the fact and its
  metadata is untyped, so it cannot be atomic with the mutation. Undo needs
  the exact before-set written in the same transaction as the change.

  ## Undo

  `undo/3` deletes the rows in the change's `after`, re-inserts its `before`
  rows verbatim (original id, effect, `granted_by`, `inserted_at`) and records
  an `undo` change whose `undoes_change_id` is the original. It refuses,
  changing nothing, when a LATER change shares a tuple key
  (`{:error, {:superseded, later_ids}}`) or when the change was already
  undone (`{:error, :already_undone}`). An undo is itself a change, so
  undoing it (a redo) is allowed on the same terms.

  This module compares no effects. Precedence lives only in `Platform.Access`.
  """

  import Ecto.Query

  alias Platform.Access.{Change, Delegation, Grant, Live, Scope}
  alias Platform.Agents.AgentRuntime
  alias Platform.Repo

  @typedoc "What `commit/4` and `undo/3` return on success."
  @type committed :: %{result: term(), change: Change.t() | nil}

  # ── commit ──────────────────────────────────────────────────────────────

  @doc """
  Run `mutation_fun` (a 0-arity function returning `{:ok, result}` or
  `{:error, reason}`) as one ledgered change by `actor` (a `%Scope{}`).

  Options:

    * `:query` (required) — an `Ecto.Query` over `Platform.Access.Grant`
      selecting every row the mutation may touch, before AND after. It is
      read for `before` (locked) and again for `after`.
    * `:keys` — tuple keys (`Grant.tuple_key/1`) to lock up front, for rows
      that do not exist yet (a grant's new tuple).
    * `:org_id` — the change's org. Defaults to the org of the first
      affected row.
    * `:via_agent_id`, `:bypass`, `:undoes_change_id` — recorded on the row.

  Returns `{:ok, %{result: result, change: change}}` (`change` is nil when
  the mutation changed nothing) or `{:error, reason}`, with nothing written.
  """
  @spec commit(Scope.t(), String.t(), (-> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, committed()} | {:error, term()}
  def commit(%Scope{} = actor, action, mutation_fun, opts)
      when is_binary(action) and is_function(mutation_fun, 0) do
    query = Keyword.fetch!(opts, :query)

    with {:ok, {actor_type, actor_id}} <- actor_fields(actor) do
      transaction(
        fn ->
          Repo.query!("LOCK TABLE access_grants IN ROW EXCLUSIVE MODE")
          pre = Repo.all(query)
          lock_keys(Keyword.get(opts, :keys, []) ++ Enum.map(pre, &Grant.tuple_key/1))

          before = snapshot(query, lock: true)
          baseline = baseline(actor, before ++ key_resources(Keyword.get(opts, :keys, [])))

          precondition!(opts)
          inspected_before = inspect_state(opts, :inspect_before)

          result =
            case mutation_fun.() do
              {:ok, result} -> result
              {:error, reason} -> Repo.rollback(reason)
            end

          after_rows = snapshot(query)
          bypass = delegate!(actor, before, after_rows, baseline)

          inspected_after = inspect_state(opts, :inspect_after)

          if opts[:dry_run] do
            Repo.rollback(
              {:dry_run,
               %{result: result, change: nil, before: inspected_before, after: inspected_after}}
            )
          end

          change =
            record!(before, after_rows, %{
              org_id: Keyword.get(opts, :org_id),
              actor_type: actor_type,
              actor_id: actor_id,
              via_agent_id: Keyword.get(opts, :via_agent_id),
              bypass: bypass || Keyword.get(opts, :bypass),
              action: action,
              undoes_change_id: Keyword.get(opts, :undoes_change_id)
            })

          %{result: result, change: change}
        end,
        opts
      )
      |> finish(opts)
    end
  end

  def commit(_actor, _action, _mutation_fun, _opts), do: {:error, :invalid_actor}

  # ── undo ────────────────────────────────────────────────────────────────

  @doc """
  Reverse change `change_id` exactly, as `actor`. See the moduledoc.

  Returns `{:ok, %{result: restored_grants, change: undo_change}}`, or
  `{:error, :not_found | :already_undone | {:superseded, [id]} | term()}`
  with nothing written. `opts` takes `:via_agent_id` and `:bypass`.
  """
  @spec undo(binary(), Scope.t(), keyword()) :: {:ok, committed()} | {:error, term()}
  def undo(change_id, actor, opts \\ [])

  def undo(change_id, %Scope{} = actor, opts) when is_binary(change_id) do
    with true <- Platform.UUID.valid?(change_id) || {:error, :not_found},
         %Change{} = change <- Repo.get(Change, change_id) || {:error, :not_found},
         {:ok, {actor_type, actor_id}} <- actor_fields(actor) do
      transaction(fn -> do_undo(change, actor, actor_type, actor_id, opts) end, opts)
      |> finish(opts)
    end
  end

  def undo(_change_id, _actor, _opts), do: {:error, :invalid_actor}

  defp do_undo(%Change{} = change, actor, actor_type, actor_id, opts) do
    Repo.query!("LOCK TABLE access_grants IN ROW EXCLUSIVE MODE")
    lock_keys(change.tuple_keys)

    # Re-read under the locks: a concurrent undo of the same change, or a
    # change to one of its tuples, has committed or is waiting on us.
    if Repo.exists?(from(c in Change, where: c.undoes_change_id == ^change.id)) do
      Repo.rollback(:already_undone)
    end

    case superseding_ids(change) do
      [] -> :ok
      later -> Repo.rollback({:superseded, later})
    end

    query = rows_query(change)
    before = snapshot(query, lock: true)
    baseline = baseline(actor, before ++ change.before)

    precondition!(opts)
    inspected_before = inspect_state(opts, :inspect_before)
    after_ids = Enum.map(change.after, & &1["id"])
    Repo.delete_all(from(g in Grant, where: g.id in ^after_ids))

    restored = restore!(change.before)

    after_rows = snapshot(query)
    bypass = delegate!(actor, before, after_rows, baseline)

    inspected_after = inspect_state(opts, :inspect_after)

    if opts[:dry_run] do
      Repo.rollback(
        {:dry_run,
         %{result: restored, change: nil, before: inspected_before, after: inspected_after}}
      )
    end

    undo_change =
      record!(before, after_rows, %{
        org_id: change.org_id,
        actor_type: actor_type,
        actor_id: actor_id,
        via_agent_id: Keyword.get(opts, :via_agent_id),
        bypass: bypass || Keyword.get(opts, :bypass),
        action: "undo",
        undoes_change_id: change.id
      })

    %{result: restored, change: undo_change}
  end

  defp superseding_ids(%Change{id: id, tuple_keys: keys}) do
    Repo.all(
      from(c in Change,
        where: c.id > ^id and fragment("? && ?", c.tuple_keys, ^keys),
        order_by: [asc: c.id],
        select: c.id
      )
    )
  end

  # Every row the undone change touched, by id or by tuple, restricted to
  # its resources so the tuple expression rides the resource index.
  defp rows_query(%Change{before: before, after: after_rows, tuple_keys: keys}) do
    snaps = before ++ after_rows
    ids = Enum.map(snaps, & &1["id"])
    resource_ids = snaps |> Enum.map(& &1["resource_id"]) |> Enum.uniq()

    from(g in Grant,
      where: g.resource_id in ^resource_ids,
      where:
        g.id in ^ids or
          fragment(
            "concat_ws('|', ?, coalesce(?::text, ?), ?, ?, ?::text) = ANY(?)",
            g.principal_type,
            g.principal_id,
            g.principal_role_key,
            g.permission,
            g.resource_type,
            g.resource_id,
            type(^keys, {:array, :string})
          )
    )
  end

  defp restore!([]), do: []

  defp restore!(snapshots) do
    rows = Enum.map(snapshots, &Grant.from_snapshot/1)

    try do
      {_, grants} = Repo.insert_all(Grant, rows, returning: true)
      grants
    rescue
      e in Postgrex.Error -> Repo.rollback({:restore_failed, Exception.message(e)})
    end
  end

  # ── list ────────────────────────────────────────────────────────────────

  @doc """
  The org's changes, oldest first, with keyset pagination mirroring
  `Platform.Audit.list/1`.

    * `:limit` — max results (default 50);
    * `:cursor` — the `id` of the last change seen (exclusive lower bound);
    * `:action` — exact match;
    * `:tuple_key` — only changes that touched this tuple.
  """
  @spec list_changes(binary(), keyword()) :: [Change.t()]
  def list_changes(org_id, opts \\ []) when is_binary(org_id) do
    limit = Keyword.get(opts, :limit, 50)

    Enum.reduce(opts, from(c in Change, where: c.org_id == ^org_id, order_by: [asc: c.id]), fn
      {:cursor, nil}, q -> q
      {:cursor, cursor}, q -> where(q, [c], c.id > ^cursor)
      {:action, action}, q -> where(q, [c], c.action == ^action)
      {:tuple_key, key}, q -> where(q, [c], ^key in c.tuple_keys)
      _other, q -> q
    end)
    |> limit(^limit)
    |> Repo.all()
  end

  # ── delegation (stage 2) ────────────────────────────────────────────────
  #
  # `Platform.Access.Delegation` decides who may make the change; this module
  # only hands it the change's actual row diff. The system actor is the
  # operator path (the arity-1 `Grants` forms and the wiki re-point) and is
  # neither authorized nor last-manager guarded.

  defp baseline(%Scope{actor: :system}, _rows), do: []
  defp baseline(%Scope{}, rows), do: Delegation.manager_baseline(rows)

  # Authorize the diff, then run the last-manager guard. Returns the bypass
  # to record (`"root_admin"` or nil); a refusal rolls the transaction back
  # with the denial, so no grant row and no change row is written.
  defp delegate!(actor, before, after_rows, baseline) do
    added = after_rows -- before
    removed = before -- after_rows

    bypass =
      case Delegation.authorize(actor, %{added: added, removed: removed}) do
        :ok -> nil
        {:ok, :root_admin_bypass} -> "root_admin"
        {:error, denial} -> Repo.rollback(denial)
      end

    case Delegation.ensure_manager_remains(baseline) do
      :ok -> bypass
      {:error, denial} -> Repo.rollback(denial)
    end
  end

  # The resources named by tuple keys (`Grant.tuple_key/1`) of rows that may
  # not exist yet. Only `access.manage` tuples matter to the guard. Every
  # field but the role key is a UUID, a registry type or a `module.action`
  # name, none of which contains `|`.
  defp key_resources(keys) do
    for key <- keys,
        [_type, _principal, "access.manage", rtype, rid] <- [String.split(key, "|")],
        rtype in Grant.resource_types(),
        do: {String.to_existing_atom(rtype), rid}
  end

  @doc "Serialize consent against grant and principal changes for its transaction."
  def lock_for_consent do
    tables =
      ~w(access_grants access_role_assignments access_roles access_runtime_profiles access_space_restrictions agent_runtimes chat_participants chat_spaces org_memberships orgs projects chat_canvases tasks task_stacks task_canvas_attachments org_memory_nodes org_memory_node_paths)

    Repo.query!(
      "LOCK TABLE " <> Enum.join(Enum.sort(tables), ", ") <> " IN SHARE ROW EXCLUSIVE MODE"
    )

    :ok
  end

  # ── internals ───────────────────────────────────────────────────────────

  defp snapshot(query, opts \\ []) do
    query = from(g in exclude(query, :order_by), order_by: [asc: g.id])
    query = if opts[:lock], do: lock(query, "FOR UPDATE"), else: query
    query |> Repo.all() |> Enum.map(&Grant.snapshot/1)
  end

  # Advisory locks are taken in sorted order so two transactions locking
  # overlapping key sets cannot deadlock on each other.
  defp lock_keys(keys) do
    keys
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn key ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "access_grant:" <> key
      ])
    end)
  end

  defp record!(before, before, _attrs), do: nil

  defp record!(before, after_rows, attrs) do
    keys = (before ++ after_rows) |> Enum.map(&Grant.tuple_key/1) |> Enum.uniq() |> Enum.sort()
    org_id = attrs.org_id || first_org(before ++ after_rows)

    attrs =
      Map.merge(attrs, %{org_id: org_id, before: before, after: after_rows, tuple_keys: keys})

    case %Change{} |> Change.changeset(attrs) |> Repo.insert() do
      {:ok, change} -> change
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp first_org([%{"org_id" => org_id} | _]), do: org_id
  defp first_org([]), do: nil

  defp actor_fields(%Scope{actor: :system}), do: {:ok, {"system", nil}}

  defp actor_fields(%Scope{actor: %AgentRuntime{agent_id: id}}) when is_binary(id),
    do: {:ok, {"agent", id}}

  defp actor_fields(%Scope{actor: %Platform.Accounts.User{id: id}}) when is_binary(id),
    do: {:ok, {"user", id}}

  defp actor_fields(_), do: {:error, :invalid_actor}

  # Ecto nested rollback poisons the enclosing transaction. A dry run inside
  # human consent therefore needs its own SQL savepoint and must intercept
  # the rollback before DBConnection marks the outer transaction failed.
  defp transaction(fun, opts) do
    if opts[:dry_run] == true and Repo.in_transaction?() do
      name = "access_preview_" <> Integer.to_string(System.unique_integer([:positive]))
      Repo.query!("SAVEPOINT " <> name)

      try do
        {:ok, fun.()}
      catch
        :throw, {DBConnection, _ref, reason} ->
          Repo.query!("ROLLBACK TO SAVEPOINT " <> name)
          {:error, reason}

        kind, reason ->
          Repo.query!("ROLLBACK TO SAVEPOINT " <> name)
          :erlang.raise(kind, reason, __STACKTRACE__)
      after
        Repo.query!("RELEASE SAVEPOINT " <> name)
      end
    else
      Repo.transaction(fun)
    end
  end

  defp precondition!(opts) do
    case Keyword.get(opts, :precondition, fn -> :ok end).() do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp inspect_state(opts, key) do
    case opts[key] do
      fun when is_function(fun, 0) -> fun.()
      nil -> nil
    end
  end

  defp finish(result, opts) do
    if opts[:defer_notifications], do: result, else: after_commit(result)
  end

  @doc "Publish a ledger change after an enclosing transaction commits."
  def notify_committed(%Change{} = change), do: after_commit({:ok, %{change: change}})

  defp after_commit({:error, {:dry_run, result}}), do: {:ok, result}

  defp after_commit({:ok, %{change: %Change{} = change}} = ok) do
    emit(change)
    Live.broadcast_changed(change)
    ok
  end

  defp after_commit(other), do: other

  defp emit(%Change{} = change) do
    :telemetry.execute(
      [:platform, :access, :grant_changed],
      %{system_time: System.system_time()},
      %{
        actor_id: change.actor_id,
        actor_type: change.actor_type,
        resource_type: "access_grant_change",
        resource_id: change.id,
        action: change.action,
        via_agent_id: change.via_agent_id,
        bypass: change.bypass,
        org_id: change.org_id,
        undoes_change_id: change.undoes_change_id,
        tuple_keys: change.tuple_keys
      }
    )
  end
end
