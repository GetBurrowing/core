defmodule Platform.Calendar.AgentAccess do
  @moduledoc """
  Calendar delegation boundary. Runtime identity is reloaded, never supplied in
  event attributes. All intent/grant changes serialize on the same owner row as
  public bookings. Tentative events reserve availability until a decision.
  """
  import Ecto.Query
  alias Ecto.Changeset, as: CS
  alias Platform.{Access, Accounts, Repo}
  alias Platform.Access.Scope
  alias Platform.Agents.AgentRuntime
  alias Platform.Calendar.{AgentGrant, Consent, Event, Booking}
  alias Platform.Memory.Briefing

  @event_fields ~w(title description starts_at ends_at time_zone all_day start_date end_date visibility space_id project_id recurrence exception_dates)a

  def list(%Scope{actor: %Accounts.User{id: id}} = scope) do
    if Access.can?(scope, "calendar.write"),
      do: Repo.all(from(g in AgentGrant, where: g.owner_id == ^id)),
      else: []
  end

  def list(_), do: []

  def agents(%Scope{actor: %Accounts.User{id: id}} = scope) do
    if Access.can?(scope, "calendar.write") do
      Repo.all(
        from(r in AgentRuntime,
          where: r.owner_user_id == ^id and r.status == "active" and not is_nil(r.agent_id),
          select: %{id: r.agent_id, name: r.display_name},
          distinct: true
        )
      )
    else
      []
    end
  end

  def agents(_), do: []

  def grant(%Scope{actor: %Accounts.User{id: id}} = scope, agent_id, attrs) do
    with :ok <- Access.authorize(scope, "calendar.write"),
         true <- Enum.any?(agents(scope), &(&1.id == agent_id)) do
      transaction(id, fn ->
        row =
          Repo.get_by(AgentGrant, owner_id: id, agent_id: agent_id) ||
            %AgentGrant{owner_id: id, agent_id: agent_id}

        row
        |> AgentGrant.changeset(attrs)
        |> CS.put_change(:revoked_at, nil)
        |> Repo.insert_or_update()
        |> unwrap()
      end)
    else
      _ -> {:error, :forbidden}
    end
  end

  def grant(_, _, _), do: {:error, :forbidden}

  def revoke(%Scope{actor: %Accounts.User{id: id}} = scope, agent_id) do
    with :ok <- Access.authorize(scope, "calendar.write"),
         true <- Platform.UUID.valid?(agent_id) do
      transaction(id, fn ->
        grant =
          Repo.get_by(AgentGrant, owner_id: id, agent_id: agent_id) || Repo.rollback(:not_found)

        grant |> CS.change(revoked_at: DateTime.utc_now()) |> Repo.update!()

        for consent <-
              Repo.all(
                from(c in Consent, where: c.grant_id == ^grant.id and c.state == "pending")
              ) do
          cancel_hold(consent)
          consent = consent |> CS.change(state: "revoked") |> Repo.update!()
          receipt(consent, "revoked")
        end

        grant
      end)
    else
      _ -> {:error, :forbidden}
    end
  end

  def revoke(_, _), do: {:error, :forbidden}

  def read(%Scope{} = runtime_scope, owner_id, from, to) do
    with {:ok, owner_scope, grant} <- authority(runtime_scope, owner_id, :read),
         %DateTime{} <- from,
         %DateTime{} <- to,
         true <- DateTime.diff(to, from) in 1..(366 * 86400) do
      events =
        Platform.Calendar.list_events(owner_scope, from, to)
        |> Enum.filter(&(&1.owner_id == owner_id))

      events =
        if grant.read_private,
          do: events,
          else: Enum.reject(events, &(is_nil(&1.space_id) and is_nil(&1.project_id)))

      {:ok,
       Enum.map(
         events,
         &Map.take(&1, [
           :id,
           :title,
           :description,
           :starts_at,
           :ends_at,
           :time_zone,
           :tentative,
           :sequence
         ])
       )}
    else
      _ -> {:error, :forbidden}
    end
  end

  def read(_, _, _, _), do: {:error, :forbidden}

  def propose(scope, owner_id, operation, attrs, request_key, event_id \\ nil)

  def propose(%Scope{} = scope, owner_id, operation, attrs, request_key, event_id)
      when operation in ["create", "move"] and is_map(attrs) and is_binary(request_key) and
             byte_size(request_key) in 1..128 do
    with {:ok, _, _} <- authority(scope, owner_id, permission(operation)) do
      transaction(owner_id, fn ->
        {owner_scope, grant} =
          case authority(scope, owner_id, permission(operation)) do
            {:ok, s, g} -> {s, g}
            _ -> Repo.rollback(:forbidden)
          end

        case Repo.get_by(Consent,
               owner_id: owner_id,
               agent_id: grant.agent_id,
               request_key: request_key
             ) do
          %Consent{} = existing ->
            existing

          nil ->
            original = target(owner_id, operation, event_id, grant)
            # Requests cannot alter scope, recurrence, identity or a booked reservation.
            # A move changes only its time window, preserving every other attribute.
            event_attrs =
              if original do
                Map.merge(
                  snapshot(original),
                  Map.take(stringify(attrs), ~w(starts_at ends_at time_zone))
                )
              else
                Map.take(
                  stringify(attrs),
                  ~w(title description starts_at ends_at time_zone all_day start_date end_date visibility)
                )
              end

            hold = Platform.Calendar.create_event(owner_scope, event_attrs) |> unwrap()
            hold = hold |> CS.change(tentative: true) |> Repo.update!()
            briefing = briefing(owner_id)

            consent =
              Repo.insert!(%Consent{
                owner_id: owner_id,
                agent_id: grant.agent_id,
                grant_id: grant.id,
                briefing_id: briefing.id,
                event_id: original && original.id,
                hold_id: hold.id,
                request_key: request_key,
                operation: operation,
                prior: if(original, do: snapshot(original), else: %{}),
                target_sequence: original && original.sequence
              })

            key = key(consent)

            briefing
            |> CS.change(items: Map.put(briefing.items, key, "calendar:" <> consent.id))
            |> Repo.update!()

            Platform.Inbox.upsert_briefing_item(Repo.get!(Briefing, briefing.id))
            |> unwrap_inbox()

            if grant.preapprove, do: approve(consent, grant, true), else: consent
        end
      end)
    end
  end

  def propose(_, _, _, _, _, _), do: {:error, :forbidden}

  def handle(
        %Briefing{id: briefing_id},
        key,
        verb,
        %Scope{actor: %Accounts.User{id: owner_id}} = scope
      )
      when verb in ["approve", "revert"] do
    with :ok <- Access.authorize(scope, "calendar.write"), true <- is_binary(key) do
      transaction(owner_id, fn ->
        briefing = locked_briefing(briefing_id, owner_id)

        consent_id =
          case Map.get(briefing.items, key) do
            "calendar:" <> id -> id
            _ -> Repo.rollback(:not_found)
          end

        consent =
          Repo.get_by(Consent, id: consent_id, owner_id: owner_id, briefing_id: briefing.id) ||
            Repo.rollback(:not_found)

        grant = Repo.get!(AgentGrant, consent.grant_id)

        cond do
          verb == "approve" and consent.state == "pending" ->
            if grant.revoked_at || not Map.get(grant, permission(consent.operation)),
              do: Repo.rollback(:revoked)

            approve(consent, grant)

          verb == "revert" and consent.state == "pending" ->
            cancel_hold(consent)
            consent |> CS.change(state: "reverted") |> Repo.update!() |> receipt("revert")

          verb == "revert" and consent.state == "approved" ->
            revert_approved(consent, scope)

          consent.state in ["approved", "reverted", "revoked"] ->
            # Repeat actions are harmless; an approve after revoke never commits.
            if verb == "approve" and consent.state != "approved",
              do: Repo.rollback(:already_resolved)

          true ->
            Repo.rollback(:already_resolved)
        end

        Repo.get!(Briefing, briefing.id)
      end)
    else
      _ -> {:error, :forbidden}
    end
  end

  def handle(_, _, _, _), do: {:error, :forbidden}

  def view(%Briefing{user_id: id} = briefing, %Scope{actor: %Accounts.User{id: id}} = scope) do
    if Access.can?(scope, "calendar.read") do
      Repo.all(
        from(c in Consent,
          where: c.briefing_id == ^briefing.id and c.owner_id == ^id,
          order_by: c.inserted_at
        )
      )
      |> Enum.map(fn c ->
        event = Repo.get!(Event, c.hold_id)
        stored = Map.get(briefing.receipts, key(c))

        %{
          key: key(c),
          kind: :calendar,
          insight: nil,
          filed_task_id: nil,
          meeting_card: nil,
          project: nil,
          email: nil,
          draft: nil,
          may_handle?: Access.can?(scope, "calendar.write"),
          actions: [],
          section: if(c.state == "pending", do: :needs_call, else: :done),
          title: event.title,
          starts_at: event.starts_at,
          operation: c.operation,
          state: c.state,
          receipt:
            if(stored,
              do: %{
                verb: stored["verb"],
                at: stored["at"],
                by: id,
                ref: nil,
                undo: nil,
                auto?: stored["auto"],
                detail: %{}
              },
              else: nil
            )
        }
      end)
    else
      []
    end
  end

  def view(_, _), do: []

  defp authority(%Scope{actor: %AgentRuntime{id: runtime_id}} = _scope, owner_id, permission) do
    with true <- Platform.UUID.valid?(owner_id),
         %AgentRuntime{status: "active", agent_id: agent_id, owner_user_id: ^owner_id} = runtime <-
           Repo.get(AgentRuntime, runtime_id),
         scope <- Scope.for_runtime(runtime),
         true <- is_binary(agent_id),
         %AgentGrant{revoked_at: nil} = grant <-
           Repo.get_by(AgentGrant, owner_id: owner_id, agent_id: agent_id),
         true <- Map.get(grant, permission) == true,
         true <-
           Access.can?(
             scope,
             if(permission == :read, do: "calendar.read", else: "calendar.write")
           ),
         %Accounts.User{} = user <- Accounts.get_user(owner_id),
         owner_scope <- Scope.for_user(user),
         true <-
           Access.can?(
             owner_scope,
             if(permission == :read, do: "calendar.read", else: "calendar.write")
           ) do
      {:ok, owner_scope, grant}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp authority(_, _, _), do: {:error, :forbidden}
  defp permission("create"), do: :create
  defp permission("move"), do: :move

  defp target(_, "create", _, _), do: nil

  defp target(owner_id, "move", id, grant) do
    if not Platform.UUID.valid?(id), do: Repo.rollback(:not_found)

    event =
      Repo.one(
        from(e in Event, where: e.id == ^id and e.owner_id == ^owner_id, lock: "FOR UPDATE")
      ) || Repo.rollback(:not_found)

    if event.tentative || event.cancelled_at || event.recurrence || event.all_day ||
         (not grant.read_private and is_nil(event.space_id) and is_nil(event.project_id)) or
         Repo.exists?(from(b in Booking, where: b.event_id == ^id)),
       do: Repo.rollback(:unsupported_move)

    event
  end

  defp approve(consent, grant, auto \\ false) do
    hold = Repo.get!(Event, consent.hold_id)
    if hold.cancelled_at || not hold.tentative, do: Repo.rollback(:stale)

    {event_id, sequence} =
      if consent.operation == "move" do
        event = target(consent.owner_id, "move", consent.event_id, grant)
        if event.sequence != consent.target_sequence, do: Repo.rollback(:stale)

        updated =
          event
          |> Event.changeset(Map.take(snapshot(hold), ~w(starts_at ends_at time_zone)))
          |> CS.change(sequence: event.sequence + 1)
          |> Repo.update!()

        cancel_hold(consent)
        {updated.id, updated.sequence}
      else
        updated =
          hold |> CS.change(tentative: false, sequence: hold.sequence + 1) |> Repo.update!()

        {updated.id, updated.sequence}
      end

    consent =
      consent
      |> CS.change(state: "approved", event_id: event_id, committed_sequence: sequence)
      |> Repo.update!()

    receipt(consent, "approve", auto)
    consent
  end

  defp revert_approved(consent, scope) do
    event = Repo.get_by!(Event, id: consent.event_id, owner_id: consent.owner_id)

    if event.sequence != consent.committed_sequence or event.cancelled_at,
      do: Repo.rollback(:stale)

    if Repo.exists?(from(b in Booking, where: b.event_id == ^event.id)),
      do: Repo.rollback(:unsupported_move)

    if consent.operation == "create" do
      Platform.Calendar.delete_event(scope, event.id) |> unwrap()
    else
      Platform.Calendar.update_event(scope, event.id, consent.prior) |> unwrap()
    end

    consent |> CS.change(state: "reverted") |> Repo.update!() |> receipt("revert")
  end

  defp cancel_hold(consent) do
    Repo.get!(Event, consent.hold_id)
    |> CS.change(cancelled_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp receipt(consent, verb, auto \\ false) do
    row = locked_briefing(consent.briefing_id, consent.owner_id)

    receipt = %{
      "kind" => "calendar",
      "verb" => verb,
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "by" => consent.owner_id,
      "auto" => auto
    }

    row |> CS.change(receipts: Map.put(row.receipts, key(consent), receipt)) |> Repo.update!()
    consent
  end

  defp briefing(owner_id) do
    date = DateTime.utc_now() |> DateTime.shift_zone!("America/Chicago") |> DateTime.to_date()

    Repo.insert!(
      Briefing.changeset(%Briefing{}, %{user_id: owner_id, digest_date: date, items: %{}}),
      on_conflict: :nothing
    )

    Repo.one!(
      from(b in Briefing,
        where: b.user_id == ^owner_id and b.digest_date == ^date,
        lock: "FOR UPDATE"
      )
    )
  end

  defp locked_briefing(id, owner_id),
    do:
      Repo.one(
        from(b in Briefing, where: b.id == ^id and b.user_id == ^owner_id, lock: "FOR UPDATE")
      ) || Repo.rollback(:not_found)

  defp key(c), do: "calendar:" <> c.id
  defp snapshot(event), do: event |> Map.take(@event_fields) |> Jason.encode!() |> Jason.decode!()
  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  defp unwrap({:ok, row}), do: row
  defp unwrap({:error, error}), do: Repo.rollback(error)
  defp unwrap_inbox({:ok, row, _}), do: row
  defp unwrap_inbox({:error, error}), do: Repo.rollback(error)

  defp transaction(owner_id, fun) do
    result =
      Repo.transaction(fn ->
        Repo.one(from(u in Accounts.User, where: u.id == ^owner_id, lock: "FOR UPDATE")) ||
          Repo.rollback(:not_found)

        fun.()
      end)

    if match?({:ok, _}, result) do
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        "calendar:#{owner_id}",
        {:calendar_changed, owner_id}
      )

      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        Platform.Inbox.topic(owner_id),
        {:inbox_changed, owner_id}
      )
    end

    result
  end
end
