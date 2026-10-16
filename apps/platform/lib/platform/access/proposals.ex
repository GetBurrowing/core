defmodule Platform.Access.Proposals do
  @moduledoc "Human-only access consent over the existing undo ledger (task 01a1386e-72e1)."
  import Ecto.Query
  alias Platform.Access.{Change, Changes, Grant, Grants, Impact, Proposal, Scope}
  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.{Canvas, CanvasAccess}
  alias Platform.{Accounts, Chat, Repo}

  @doc "Proposing agents must pass the ledger's delegation check before any impact is disclosed."
  def propose(%AgentRuntime{} = runtime, attrs) do
    scope = Scope.for_runtime(runtime)
    options = attrs[:options] || [%{key: "default", label: "Apply change", ops: attrs[:ops]}]

    with true <- length(options) in 1..3 || {:error, :invalid_options},
         %Canvas{} = canvas <- Repo.get(Canvas, attrs[:canvas_id]) || {:error, :not_found},
         true <- canvas.space_id == attrs[:space_id] || {:error, :wrong_space},
         {:ok, prepared} <- prepare_options(options, scope) do
      first = hd(prepared)
      ops = decode_ops(first["ops"])

      with {:ok, tuples} <- Grants.prepare_ops(ops, scope) do
        attrs = %{
          org_id: hd(tuples) |> elem(1) |> Map.fetch!(:org_id),
          proposer_runtime_id: runtime.id,
          space_id: canvas.space_id,
          canvas_id: canvas.id,
          kind: attrs[:kind] || "change",
          action: hd(ops).action,
          options: prepared,
          selected_option: if(length(prepared) == 1, do: first["key"]),
          tuple_keys: tuples |> Enum.map(fn {_, row} -> Grant.tuple_key(row) end) |> Enum.sort(),
          base_state_hash: state_hash(),
          card_digest: digest(canvas.document),
          expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
        }

        %Proposal{} |> Proposal.changeset(attrs) |> Repo.insert()
      end
    end
  end

  def propose(_, _), do: {:error, :invalid_actor}

  defp prepare_options(options, scope) do
    Enum.reduce_while(options, {:ok, []}, fn option, {:ok, acc} ->
      case Impact.diff(scope, option.ops) do
        {:ok, impact} ->
          entry = %{
            key: option.key,
            label: option.label,
            ops: encode_ops(option.ops),
            impact: impact
          }

          {:cont, {:ok, acc ++ [json(entry)]}}

        error ->
          {:halt, error}
      end
    end)
  end

  @doc "The authenticated click process supplies the human; no agent or approval token can commit."
  def apply(id, human, opts \\ [])

  def apply(id, %Scope{actor: %User{id: user_id}}, _opts) do
    # Reload memberships and scope at the moment of consent.
    human = Scope.for_user(Accounts.get_user(user_id))

    result =
      Repo.transaction(fn ->
        row = locked!(id)
        readable!(row, human)
        require_proposed!(row)

        option =
          Enum.find(row.options, &(&1["key"] == row.selected_option)) ||
            Repo.rollback(:choose_option)

        ops = decode_ops(option["ops"])

        with {:ok, impact} <- Impact.diff(human, ops) do
          if json(impact) != option["impact"], do: Repo.rollback(:stale)
        else
          {:error, reason} -> Repo.rollback(reason)
        end

        if state_hash() != row.base_state_hash, do: Repo.rollback(:stale)

        row =
          update!(row, %{
            state: "applying",
            approval_id: Ecto.UUID.generate(),
            approved_by_user_id: user_id,
            approved_at: DateTime.utc_now()
          })

        case Grants.apply_ops(ops,
               actor: human,
               via_agent_id: row.proposer_runtime_id,
               defer_notifications: true,
               precondition: fn ->
                 if state_hash() == row.base_state_hash, do: :ok, else: {:error, :stale}
               end
             ) do
          {:ok, %{change: %Change{} = change}} ->
            update!(row, %{state: "applied", change_id: change.id})

          {:ok, %{change: nil}} ->
            Repo.rollback(:no_change)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %Proposal{change_id: change_id}} ->
        Changes.notify_committed(Repo.get!(Change, change_id))
        result

      {:error, reason} when reason in [:stale, :card_changed] ->
        Repo.update_all(from(p in Proposal, where: p.id == ^id and p.state == "proposed"),
          set: [state: "stale", failure: %{reason: Atom.to_string(reason)}]
        )

        result

      other ->
        other
    end
  end

  def apply(_, _, _), do: {:error, :human_required}

  def cancel(id, %Scope{actor: %User{}} = human) do
    mutate(id, human, fn row ->
      require_proposed!(row)
      update!(row, %{state: "cancelled"})
    end)
  end

  def cancel(_, _), do: {:error, :human_required}

  def choose(id, key, %Scope{actor: %User{}} = human) do
    mutate(id, human, fn row ->
      require_proposed!(row)
      unless Enum.any?(row.options, &(&1["key"] == key)), do: Repo.rollback(:invalid_option)
      update!(row, %{selected_option: key})
    end)
  end

  def choose(_, _, _), do: {:error, :human_required}

  def undo_applied(id, %Scope{actor: %User{id: uid}}) do
    human = Scope.for_user(Accounts.get_user(uid))

    result =
      mutate(id, human, fn row ->
        unless row.state == "applied", do: Repo.rollback(:not_applied)

        case Changes.undo(row.change_id, human,
               via_agent_id: row.proposer_runtime_id,
               defer_notifications: true
             ) do
          {:ok, _} -> update!(row, %{state: "undone"})
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, row} ->
        change = Repo.one!(from(c in Change, where: c.undoes_change_id == ^row.change_id))
        Changes.notify_committed(change)
        result

      error ->
        error
    end
  end

  def undo_applied(_, _), do: {:error, :human_required}

  @doc "Status is readable only by the proposing runtime or a human who can read the card."
  def status(id, %AgentRuntime{id: runtime_id}) do
    case valid_get(id) do
      %Proposal{proposer_runtime_id: ^runtime_id} = row -> {:ok, row}
      _ -> {:error, :not_found}
    end
  end

  def status(id, %Scope{actor: %User{}} = human) do
    Repo.transaction(fn ->
      row = locked!(id)
      readable!(row, human)
      row
    end)
  end

  def status(_, _), do: {:error, :not_found}

  defp mutate(id, human, fun) do
    Repo.transaction(fn ->
      row = locked!(id)
      readable!(row, human)
      fun.(row)
    end)
  end

  defp valid_get(id), do: if(Platform.UUID.valid?(id), do: Repo.get(Proposal, id))

  defp locked!(id) do
    unless Platform.UUID.valid?(id), do: Repo.rollback(:not_found)

    Repo.one(from(p in Proposal, where: p.id == ^id, lock: "FOR UPDATE")) ||
      Repo.rollback(:not_found)
  end

  defp readable!(row, %Scope{actor: %User{id: uid}} = scope) do
    unless Chat.participant?(row.space_id, uid), do: Repo.rollback(:not_found)

    case CanvasAccess.fetch_for_viewer(row.canvas_id, {:user, uid},
           access_scope: scope,
           audit: false
         ) do
      {:ok, canvas, _grant} -> verify_digest!(row, canvas)
      _ -> Repo.rollback(:not_found)
    end
  end

  defp verify_digest!(row, canvas) do
    if digest(canvas.document) != row.card_digest, do: Repo.rollback(:card_changed)
  end

  defp require_proposed!(row) do
    unless row.state == "proposed", do: Repo.rollback(:not_proposed)
    if DateTime.compare(row.expires_at, DateTime.utc_now()) != :gt, do: Repo.rollback(:expired)
  end

  defp update!(row, attrs), do: row |> Proposal.changeset(attrs) |> Repo.update!()

  @doc "Bind consent to document content, ignoring only the transport revision."
  def digest(document), do: hash(Map.drop(document, ["revision", :revision]))

  @doc "Conservative snapshot: concurrent membership, role, runtime or grant edits invalidate consent."
  def state_hash do
    tables =
      ~w(access_grants org_memberships access_roles access_role_assignments access_space_restrictions agent_runtimes access_runtime_profiles)

    values =
      Enum.map(tables, fn table ->
        %{rows: rows} =
          Repo.query!(
            "SELECT row_to_json(t)::text FROM " <> table <> " t ORDER BY row_to_json(t)::text"
          )

        {table, rows}
      end)

    hash(values)
  end

  defp hash(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()

  @doc false
  def encode_ops(ops) do
    Enum.map(ops, fn op ->
      op
      |> Map.new(fn
        {:principal, tuple} -> {:principal, Tuple.to_list(tuple)}
        {:resource, tuple} -> {:resource, Tuple.to_list(tuple)}
        entry -> entry
      end)
      |> json()
    end)
  end

  @doc false
  def decode_ops(ops) do
    Enum.map(ops, fn op ->
      Enum.reduce(~w(action id permission org_id)a, %{}, fn key, acc ->
        case Map.fetch(op, Atom.to_string(key)) do
          {:ok, value} -> Map.put(acc, key, value)
          :error -> acc
        end
      end)
      |> decode_tuple(op, :principal)
      |> decode_tuple(op, :resource)
    end)
  end

  defp decode_tuple(acc, op, key) do
    case op[Atom.to_string(key)] do
      [type, id] when type in ~w(user agent role project space canvas memory_node memory) ->
        Map.put(acc, key, {String.to_existing_atom(type), id})

      nil ->
        acc
    end
  end
end
