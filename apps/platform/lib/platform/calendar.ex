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
      owner_transaction(owner_id, fn -> changeset |> Repo.insert() end) |> broadcast()
    end
  end

  def create_event(_, _), do: {:error, :forbidden}

  def update_event(%Scope{actor: %Accounts.User{id: owner_id}} = scope, id, attrs) do
    owner_transaction(owner_id, fn ->
      with {:ok, event} <- owned_event(scope, id) do
        event
        |> Event.changeset(attrs)
        |> Ecto.Changeset.put_change(:sequence, event.sequence + 1)
        |> then(fn changeset ->
          with :ok <- authorize_scope(scope, changeset), do: Repo.update(changeset)
        end)
      end
    end)
    |> broadcast()
  end

  def update_event(_, _, _), do: {:error, :forbidden}

  def delete_event(%Scope{actor: %Accounts.User{id: owner_id}} = scope, id) do
    owner_transaction(owner_id, fn ->
      with {:ok, event} <- owned_event(scope, id) do
        event
        |> Ecto.Changeset.change(cancelled_at: DateTime.utc_now(), sequence: event.sequence + 1)
        |> Repo.update()
      end
    end)
    |> broadcast()
  end

  def delete_event(_, _), do: {:error, :forbidden}

  defp owner_transaction(id, fun) do
    Repo.transaction(fn ->
      Repo.one!(from(u in Accounts.User, where: u.id == ^id, lock: "FOR UPDATE"))

      case fun.() do
        {:ok, event} -> event
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def get_event(%Scope{actor: %Accounts.User{}} = scope, id) do
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

  def list_events(
        %Scope{actor: %Accounts.User{}} = scope,
        %DateTime{} = from,
        %DateTime{} = to,
        opts
      ) do
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

  def list_entries(scope, from, to, opts \\ [])

  def list_entries(%Scope{actor: %Accounts.User{}} = scope, from, to, opts) do
    meetings =
      if Access.can?(scope, "calendar.read") and Access.can?(scope, "meetings.join") do
        Platform.Meetings.list_meetings_in_range_for_user(scope.actor, from, to,
          overlap: Keyword.get(opts, :meeting_overlap, false)
        )
        |> reject_cancelled_meetings(Keyword.get(opts, :cancelled_meetings, :recent))
      else
        []
      end

    {events, meetings} = project_linked(list_events(scope, from, to), meetings, scope)

    native =
      Enum.map(
        events,
        &%{
          kind: :event,
          id: &1.id,
          event: &1,
          meeting_id: &1.meeting_id,
          title: if(&1.tentative, do: "Tentative · " <> &1.title, else: &1.title),
          starts_at: &1.starts_at,
          ends_at: &1.ends_at,
          all_day: &1.all_day
        }
      )

    meetings =
      Enum.map(
        meetings,
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

    Enum.sort_by(
      native ++ meetings ++ Platform.Calendar.Subscriptions.entries(scope, from, to, opts),
      & &1.starts_at,
      DateTime
    )
  end

  def list_entries(_, _, _, _), do: []

  @doc """
  Project each native-event/meeting pair linked by `calendar_events.meeting_id`
  exactly once (task 01a1b8a5 stage 1). Every surface that lists both stores
  (the Calendar grid, booking availability, agent access and the private
  feed) goes through this one rule:

    * the event's owner sees the native event, and the meeting is dropped;
    * anyone else who can see the meeting sees the meeting, and the native
      event is dropped (so an invitee sees the call, not a "Busy" copy);
    * anyone who sees only one of the two sees that one.
  """
  @spec project_linked([Event.t()], [Platform.Meetings.Meeting.t()], Scope.t()) ::
          {[Event.t()], [Platform.Meetings.Meeting.t()]}
  def project_linked(events, meetings, %Scope{actor: %Accounts.User{id: viewer_id}}) do
    meeting_ids = MapSet.new(meetings, & &1.id)

    events =
      Enum.reject(events, fn event ->
        is_binary(event.meeting_id) and event.owner_id != viewer_id and
          MapSet.member?(meeting_ids, event.meeting_id)
      end)

    owned =
      for %{meeting_id: id, owner_id: ^viewer_id} <- events,
          is_binary(id),
          into: MapSet.new(),
          do: id

    {events, Enum.reject(meetings, &MapSet.member?(owned, &1.id))}
  end

  # A cancelled meeting is listed for 24h after `cancelled_at` and then
  # dropped (PR #51), unless the caller passes `cancelled_meetings: :keep`.
  # Only `CalendarLive.reload/1` does (task 01a19e7f stage 4): the grid keeps
  # a cancelled meeting in its slot, struck through. Agent access and
  # booking availability keep the default.
  defp reject_cancelled_meetings(meetings, :keep), do: meetings

  defp reject_cancelled_meetings(meetings, _recent) do
    Enum.reject(meetings, fn meeting ->
      meeting.status == "cancelled" and
        (is_nil(meeting.cancelled_at) or
           DateTime.diff(DateTime.utc_now(), meeting.cancelled_at) > 86_400)
    end)
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

  # Cancelled events are omitted, not sent as STATUS:CANCELLED: Outlook's
  # ICS import and many subscribers ignore STATUS and show them as live.
  # A subscriber drops a VEVENT that disappears from the feed.
  def feed_events(%Scope{actor: %Accounts.User{}} = scope) do
    if Access.can?(scope, "calendar.read") do
      visible_query(scope)
      |> where([e], is_nil(e.cancelled_at))
      |> order_by([e], asc: e.starts_at, asc: e.id)
      |> Repo.all()
      |> Enum.map(&feed_redact/1)
    else
      []
    end
  end

  def feed_events(_), do: []

  # The feed is a bearer URL that leaves Burrow (Apple, Google, Outlook and
  # whoever holds the URL), so a busy-only event is "Busy" there for EVERY
  # reader, the owner included: the editor promises "Others, agents and your
  # iCal feed just see “Busy”" (task 01a18d9f fix round). In-app reads keep
  # the owner's own titles (`redact/2`).
  defp feed_redact(%Event{visibility: "busy"} = event),
    do: %{event | title: "Busy", description: nil, owner: nil, space_id: nil, project_id: nil}

  defp feed_redact(event), do: event

  def subscribe(%Scope{actor: %Accounts.User{id: id}}),
    do: Phoenix.PubSub.subscribe(Platform.PubSub, "calendar:#{id}")

  defp owned_event(%Scope{actor: %Accounts.User{id: owner_id}} = scope, id) do
    with true <- Platform.UUID.valid?(id),
         :ok <- Access.authorize(scope, "calendar.write"),
         %Event{} = event <- Repo.get_by(Event, id: id, owner_id: owner_id),
         true <- is_nil(event.cancelled_at) and not event.tentative do
      {:ok, event}
    else
      _ -> {:error, :not_found}
    end
  end

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
