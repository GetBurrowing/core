defmodule Platform.Calendar do
  @moduledoc "Native calendar events and private subscriptions, with meetings projected from Meetings."
  import Ecto.Query
  alias Platform.{Access, Accounts, Repo, Tenancy}
  alias Platform.Access.Scope
  alias Platform.Calendar.{Event, FeedToken, Recurrence}

  def change_event(event \\ %Event{}, attrs \\ %{}), do: Event.changeset(event, attrs)

  def create_event(%Scope{actor: %Accounts.User{id: owner_id}} = scope, attrs) do
    changeset = Event.changeset(%Event{owner_id: owner_id}, attrs)

    with :ok <- Access.authorize(scope, "calendar.write"),
         :ok <- authorize_scope(scope, changeset) do
      changeset |> Repo.insert() |> broadcast()
    end
  end

  def create_event(_, _), do: {:error, :forbidden}

  def update_event(scope, id, attrs) do
    with {:ok, event} <- owned_event(scope, id) do
      event
      |> Event.changeset(attrs)
      |> Ecto.Changeset.put_change(:sequence, event.sequence + 1)
      |> then(fn changeset ->
        with :ok <- authorize_scope(scope, changeset), do: Repo.update(changeset)
      end)
      |> broadcast()
    end
  end

  def delete_event(scope, id) do
    with {:ok, event} <- owned_event(scope, id) do
      event
      |> Ecto.Changeset.change(cancelled_at: DateTime.utc_now(), sequence: event.sequence + 1)
      |> Repo.update()
      |> broadcast()
    end
  end

  def get_event(%Scope{} = scope, id) do
    with true <- Platform.UUID.valid?(id),
         :ok <- Access.authorize(scope, "calendar.read"),
         %Event{} = event <- Repo.one(where(visible_query(scope), [e], e.id == ^id)) do
      {:ok, redact(event, scope)}
    else
      _ -> {:error, :not_found}
    end
  end

  def get_event(_, _), do: {:error, :not_found}

  def list_events(scope, from, to, opts \\ [])

  def list_events(%Scope{} = scope, %DateTime{} = from, %DateTime{} = to, opts) do
    if Access.can?(scope, "calendar.read") and DateTime.compare(from, to) == :lt do
      query = visible_query(scope)

      query =
        if Keyword.get(opts, :include_cancelled, false),
          do: query,
          else: where(query, [e], is_nil(e.cancelled_at))

      query
      |> where([e], e.starts_at < ^to and (e.ends_at > ^from or not is_nil(e.recurrence)))
      |> order_by([e], asc: e.starts_at, asc: e.id)
      |> Repo.all()
      |> Enum.flat_map(&Recurrence.occurrences(&1, from, to))
      |> Enum.map(&redact(&1, scope))
      |> Enum.sort_by(& &1.starts_at, DateTime)
    else
      []
    end
  end

  def list_events(_, _, _, _), do: []

  def list_entries(scope, from, to) do
    native =
      Enum.map(
        list_events(scope, from, to),
        &%{
          kind: :event,
          id: &1.id,
          event: &1,
          title: &1.title,
          starts_at: &1.starts_at,
          ends_at: &1.ends_at,
          all_day: &1.all_day
        }
      )

    meetings =
      if Access.can?(scope, "calendar.read") and Access.can?(scope, "meetings.join") do
        Platform.Meetings.list_meetings_in_range_for_user(scope.actor, from, to)
        |> Enum.reject(fn meeting ->
          meeting.status == "cancelled" and
            (is_nil(meeting.cancelled_at) or
               DateTime.diff(DateTime.utc_now(), meeting.cancelled_at) > 86_400)
        end)
        |> Enum.map(
          &%{
            kind: :meeting,
            id: &1.id,
            meeting: &1,
            title: &1.name,
            starts_at: &1.scheduled_start_at,
            ends_at: &1.scheduled_end_at,
            all_day: false
          }
        )
      else
        []
      end

    Enum.sort_by(native ++ meetings, & &1.starts_at, DateTime)
  end

  def rotate_feed(%Scope{actor: %Accounts.User{id: id}} = scope) do
    with :ok <- Access.authorize(scope, "calendar.read") do
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      hash = :crypto.hash(:sha256, token)
      changeset = Ecto.Changeset.change(%FeedToken{owner_id: id, token_hash: hash})

      case Repo.insert(changeset,
             conflict_target: :owner_id,
             on_conflict: [set: [token_hash: hash, updated_at: DateTime.utc_now()]]
           ) do
        {:ok, _} -> {:ok, token}
        error -> error
      end
    end
  end

  def rotate_feed(_), do: {:error, :forbidden}

  def revoke_feed(%Scope{actor: %Accounts.User{id: id}}) do
    Repo.delete_all(from(f in FeedToken, where: f.owner_id == ^id))
    :ok
  end

  def revoke_feed(_), do: {:error, :forbidden}

  def feed_scope(token) when is_binary(token) and byte_size(token) == 43 do
    hash = :crypto.hash(:sha256, token)

    with %FeedToken{owner_id: id} <- Repo.get_by(FeedToken, token_hash: hash),
         %Accounts.User{} = user <- Accounts.get_user(id),
         scope <- Scope.for_user(user),
         true <- Access.can?(scope, "calendar.read") do
      {:ok, scope}
    else
      _ -> {:error, :not_found}
    end
  end

  def feed_scope(_), do: {:error, :not_found}

  def feed_events(scope) do
    if Access.can?(scope, "calendar.read") do
      visible_query(scope)
      |> order_by([e], asc: e.starts_at, asc: e.id)
      |> Repo.all()
      |> Enum.map(&redact(&1, scope))
    else
      []
    end
  end

  def subscribe(%Scope{actor: %Accounts.User{id: id}}),
    do: Phoenix.PubSub.subscribe(Platform.PubSub, "calendar:#{id}")

  defp owned_event(%Scope{actor: %Accounts.User{id: owner_id}} = scope, id) do
    with true <- Platform.UUID.valid?(id),
         :ok <- Access.authorize(scope, "calendar.write"),
         %Event{} = event <- Repo.get_by(Event, id: id, owner_id: owner_id),
         true <- is_nil(event.cancelled_at) do
      {:ok, event}
    else
      _ -> {:error, :not_found}
    end
  end

  defp owned_event(_, _), do: {:error, :not_found}

  defp authorize_scope(scope, changeset) do
    space = Ecto.Changeset.get_field(changeset, :space_id)
    project = Ecto.Changeset.get_field(changeset, :project_id)

    cond do
      space && project ->
        {:error, :invalid_scope}

      space ->
        with true <- Platform.UUID.valid?(space),
             :ok <- Access.authorize(scope, "chat.write", Repo.get(Platform.Chat.Space, space)),
             {:ok, _} <- Platform.Chat.SpaceAccess.authorize_writer(space, scope.actor) do
          :ok
        else
          _ -> {:error, :forbidden}
        end

      project ->
        if Platform.UUID.valid?(project) and
             Repo.exists?(member_projects_query(scope.actor.id) |> where([p], p.id == ^project)),
           do: :ok,
           else: {:error, :forbidden}

      true ->
        :ok
    end
  end

  def list_spaces(%Scope{actor: %Accounts.User{id: id}} = scope) do
    member_ids = Platform.Chat.list_member_space_ids(id)

    Platform.Chat.list_spaces(scope: scope)
    |> Enum.filter(&(&1.id in member_ids and is_binary(&1.name)))
  end

  def list_spaces(_), do: []

  defp visible_query(%Scope{actor: %Accounts.User{id: id}} = scope) do
    projects = member_projects_query(id) |> select([p], p.id)

    member_spaces = Platform.Chat.ExternalScope.member_space_ids(scope)

    spaces =
      Platform.Chat.Space
      |> Platform.Chat.ExternalScope.scope_spaces(scope)
      |> where([s], s.id in subquery(member_spaces) and is_nil(s.archived_at))
      |> select([s], s.id)

    from(e in Event,
      where:
        e.owner_id == ^id or e.space_id in subquery(spaces) or e.project_id in subquery(projects)
    )
  end

  defp visible_query(_), do: from(e in Event, where: false)

  # Preserve Calendar's membership-only project boundary, including for root
  # members, while composing the shared org predicate instead of copying it.
  defp member_projects_query(user_id) do
    ids = Tenancy.viewer_org_ids_query(user_id) |> Repo.all()
    Platform.Tasks.Project |> Tenancy.scope({:orgs, ids})
  end

  defp redact(%Event{owner_id: id} = event, %Scope{actor: %{id: id}}), do: event

  defp redact(%Event{visibility: "busy"} = event, _),
    do: %{event | title: "Busy", description: nil, owner: nil, space_id: nil, project_id: nil}

  defp redact(event, _), do: event

  defp broadcast({:ok, event} = result) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      "calendar:#{event.owner_id}",
      {:calendar_changed, event.id}
    )

    result
  end

  defp broadcast(error), do: error
end
