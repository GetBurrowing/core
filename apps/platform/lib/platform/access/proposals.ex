defmodule Platform.Access.Proposals do
  @moduledoc "Human-only access consent over the existing undo ledger (task 01a1386e-72e1)."
  import Ecto.Query
  alias Platform.Access.{Change, ChangeCard, Changes, Grant, Grants, Impact, Proposal, Scope}
  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.{Canvas, CanvasAccess}
  alias Platform.{Accounts, Chat, Repo}

  @doc "Proposing agents must pass the ledger's delegation check before any impact is disclosed."
  def propose(%AgentRuntime{} = runtime, %{kind: "undo", undoes_change_id: change_id} = attrs) do
    scope = Scope.for_runtime(runtime)

    with {:ok, impact} <- Impact.diff(scope, change_id),
         %Change{} = change <- Repo.get(Change, change_id),
         %Canvas{} = canvas <- Repo.get(Canvas, attrs[:canvas_id]) do
      %Proposal{}
      |> Proposal.changeset(%{
        org_id: change.org_id,
        proposer_runtime_id: runtime.id,
        space_id: canvas.space_id,
        canvas_id: canvas.id,
        kind: "undo",
        action: "undo",
        options: [json(%{key: "default", label: undo_label(change), ops: [], impact: impact})],
        selected_option: "default",
        tuple_keys: change.tuple_keys,
        base_state_hash: state_hash(),
        card_digest: digest(canvas.document),
        undoes_change_id: change.id,
        expires_at: DateTime.add(DateTime.utc_now(), 86_400)
      })
      |> Repo.insert()
      |> render_result()
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

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

        %Proposal{}
        |> Proposal.changeset(attrs)
        |> Repo.insert()
        |> render_result()
      end
    end
  end

  def propose(_, _), do: {:error, :invalid_actor}

  defp prepare_options(options, scope) do
    Enum.reduce_while(options, {:ok, []}, fn option, {:ok, acc} ->
      case Impact.diff(scope, option.ops) do
        {:ok, impact} ->
          {:ok, prepared} = Grants.prepare_ops(option.ops, scope)

          labels =
            Enum.map(prepared, fn {op, row} ->
              verb =
                if op.action == "grant" or (op.action == "revoke" and row.effect == "deny"),
                  do: "Gain access",
                  else: "Lose access"

              factual_label(row, verb)
            end)

          entry = %{
            key: option.key,
            label: Enum.join(labels, "; "),
            ops: encode_ops(option.ops),
            impact: impact
          }

          {:cont, {:ok, acc ++ [json(entry)]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp undo_label(change) do
    restored = Enum.map(change.before -- change.after, &{&1, "Restore #{&1["effect"]}"})
    removed = Enum.map(change.after -- change.before, &{&1, "Remove #{&1["effect"]}"})

    (restored ++ removed)
    |> Enum.map_join("; ", fn {snapshot, verb} ->
      snapshot |> Grant.from_snapshot() |> then(&struct(Grant, &1)) |> factual_label(verb)
    end)
  end

  defp factual_label(row, verb) do
    schema = case row.resource_type do
      "project" -> Platform.Tasks.Project
      "space" -> Chat.Space
      "canvas" -> Canvas
      "memory_node" -> Platform.Org.Wiki.Node
    end
    resource = Repo.get!(schema, row.resource_id)
    name = Map.get(resource, :name) || Map.get(resource, :title) || row.resource_id
    "#{verb}: #{row.permission} · #{name} · #{principal_label(row)}"
  end

  defp principal_label(%Grant{principal_type: "role", principal_role_key: key}),
    do: "role " <> key

  defp principal_label(%Grant{principal_type: type, principal_id: id}) do
    principal =
      if type == "user", do: Accounts.get_user(id), else: Repo.get(Platform.Agents.Agent, id)

    name =
      if principal, do: Map.get(principal, :name) || Map.get(principal, :email) || id, else: id

    "#{type} #{name}"
  end

  @doc "The authenticated click process supplies the human; no agent or approval token can commit."
  def apply(id, human, opts \\ [])

  def apply(id, %Scope{actor: %User{id: user_id}}, _opts) do
    # Reload memberships and scope at the moment of consent.
    result =
      Repo.transaction(fn ->
        Changes.lock_for_consent()
        human = Scope.for_user(Accounts.get_user(user_id))
        row = locked!(id)
        readable!(row, human)
        require_proposed!(row)

        option =
          Enum.find(row.options, &(&1["key"] == row.selected_option)) ||
            Repo.rollback(:choose_option)

        ops = decode_ops(option["ops"])

        with {:ok, impact} <-
               Impact.diff(human, if(row.kind == "undo", do: row.undoes_change_id, else: ops)) do
          if json(impact) != option["impact"], do: Repo.rollback(:stale)
        else
          {:error, :not_found} ->
            Repo.rollback(if(state_hash() != row.base_state_hash, do: :stale, else: :not_found))

          {:error, reason} ->
            Repo.rollback(reason)
        end

        if state_hash() != row.base_state_hash, do: Repo.rollback(:stale)

        row =
          update!(row, %{
            state: "applying",
            approval_id: Ecto.UUID.generate(),
            approved_by_user_id: user_id,
            approved_at: DateTime.utc_now()
          })

        commit_opts = [
          via_agent_id: row.proposer_runtime_id,
          defer_notifications: true,
          precondition: fn ->
            if state_hash() == row.base_state_hash, do: :ok, else: {:error, :stale}
          end
        ]

        result =
          if row.kind == "undo",
            do: Changes.undo(row.undoes_change_id, human, commit_opts),
            else: Grants.apply_ops(ops, Keyword.put(commit_opts, :actor, human))

        case result do
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
        render_result(result)

      {:error, reason} when reason in [:stale, :card_changed, :expired] ->
        Repo.update_all(from(p in Proposal, where: p.id == ^id and p.state == "proposed"),
          set: [state: "stale", failure: %{reason: Atom.to_string(reason)}]
        )

        render_card(Repo.get!(Proposal, id))
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

  defp mutate(id, %Scope{actor: %User{id: uid}}, fun) do
    with %Proposal{} = initial <- valid_get(id),
         {:ok, _} <- Platform.Chat.Canvas.Server.start_server(initial.canvas_id) do
      Repo.transaction(fn ->
        human = Scope.for_user(Accounts.get_user(uid))
        row = locked!(id)
        readable!(row, human)
        fun.(row) |> persist_card!()
      end)
      |> publish_result()
    else
      nil -> {:error, :not_found}
      error -> error
    end
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
    document =
      case Platform.Chat.Canvas.Server.whereis(canvas.id) do
        nil ->
          canvas.document

        _ ->
          case Platform.Chat.Canvas.Server.describe(canvas.id) do
            {:ok, %{document: document}} -> document
            _ -> Repo.rollback(:not_found)
          end
      end

    if digest(document) != row.card_digest or digest(canvas.document) != row.card_digest,
      do: Repo.rollback(:card_changed)
  end

  defp require_proposed!(row) do
    unless row.state == "proposed", do: Repo.rollback(:not_proposed)
    if DateTime.compare(row.expires_at, DateTime.utc_now()) != :gt, do: Repo.rollback(:expired)
  end

  defp update!(row, attrs), do: row |> Proposal.changeset(attrs) |> Repo.update!()

  @doc "Rebuild the complete consent surface from server-computed facts."
  def render_card(%Proposal{} = row) do
    with {:ok, _pid} <- Platform.Chat.Canvas.Server.start_server(row.canvas_id) do
      Repo.transaction(fn -> locked!(row.id) |> persist_card!() end)
      |> publish_result()
    end
  end

  # The selected option, stored canvas and consent digest commit together.
  # Publish through the canonical server after commit: synchronous canvas
  # persistence cannot check out a sandbox connection held by its caller.
  defp persist_card!(row) do
    document = card_document(row)
    Repo.update_all(from(c in Canvas, where: c.id == ^row.canvas_id), set: [document: document])
    update!(row, %{card_digest: digest(document)})
  end

  defp card_document(row) do
    name =
      case row.approved_by_user_id && Accounts.get_user(row.approved_by_user_id) do
        nil -> nil
        user -> user.name || user.email
      end

    ChangeCard.document(%{row | approved_by_name: name})
  end

  defp publish_result({:ok, row}), do: publish_card(row, 3)
  defp publish_result(error), do: error
  defp publish_card(_row, 0), do: {:error, :card_changed}

  defp publish_card(row, remaining) do
    row = Repo.get!(Proposal, row.id)
    document = card_document(row)
    canvas = Repo.get!(Canvas, row.canvas_id)

    case Chat.patch_canvas(:system, canvas, [{:replace_document, document}]) do
      {:ok, _} ->
        current = Repo.get!(Proposal, row.id)

        if current.card_digest == digest(document),
          do: {:ok, current},
          else: publish_card(current, remaining - 1)

      error ->
        error
    end
  end

  defp render_result({:ok, %Proposal{} = row}), do: render_card(row)
  defp render_result(error), do: error

  @doc "Bind consent to document content, ignoring only the transport revision."
  def digest(document), do: hash(Map.drop(document, ["revision", :revision]))

  @doc "Conservative snapshot: concurrent membership, role, runtime or grant edits invalidate consent."
  def state_hash do
    tables =
      ~w(access_grants org_memberships access_roles access_role_assignments access_space_restrictions agent_runtimes access_runtime_profiles chat_participants orgs projects chat_spaces)

    values =
      Enum.map(tables, fn table ->
        # Viewing a card advances read cursors; runtime connections update
        # heartbeats. Neither changes access or the displayed loss list.
        omitted =
          case table do
            "chat_participants" ->
              ~w(last_read_message_id attention_mode attention_config avatar_url)

            "agent_runtimes" ->
              ~w(last_connected_at updated_at)

            _ ->
              []
          end

        %{rows: rows} =
          Repo.query!(
            "SELECT (to_jsonb(t) - $1::text[])::text FROM " <>
              table <>
              " t ORDER BY (to_jsonb(t) - $1::text[])::text",
            [omitted]
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
