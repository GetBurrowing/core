defmodule Platform.Calendar.BookingLinks do
  @moduledoc "Public reservations recheck owner availability under a shared owner row lock."
  import Ecto.Query
  alias Platform.{Access, Accounts, Repo}
  alias Platform.Access.Scope
  alias Platform.Calendar.{Booking, BookingLink, Subscriptions}
  alias PlatformWeb.MeetingLive.CalendarWindow

  def list(%Scope{actor: %Accounts.User{id: id}} = scope) do
    if Access.can?(scope, "calendar.read"),
      do:
        Repo.all(
          from(l in BookingLink, where: l.owner_id == ^id, order_by: [desc: l.inserted_at])
        ),
      else: []
  end

  def list(_), do: []

  def create(%Scope{actor: %Accounts.User{id: id}} = scope, attrs) do
    cs = BookingLink.changeset(%BookingLink{owner_id: id, token: token()}, attrs)

    with :ok <- Access.authorize(scope, "calendar.write"),
         :ok <- meeting_policy(scope, Ecto.Changeset.apply_changes(cs)),
         do: Repo.insert(cs)
  end

  def create(_, _), do: {:error, :forbidden}

  def update(scope, id, attrs) do
    with :ok <- Access.authorize(scope, "calendar.write"),
         %BookingLink{} = link <- Enum.find(list(scope), &(&1.id == id)) do
      Repo.transaction(fn ->
        lock_owner(link.owner_id)
        current = Repo.get!(BookingLink, link.id)
        cs = BookingLink.changeset(current, attrs)

        with :ok <- meeting_policy(scope, Ecto.Changeset.apply_changes(cs)),
             {:ok, updated} <- Repo.update(cs) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  def revoke(scope, id) do
    with :ok <- Access.authorize(scope, "calendar.write"),
         %BookingLink{} = link <- Enum.find(list(scope), &(&1.id == id)) do
      # Same lock ordering as book: owner before link. A completed revoke
      # cannot be followed by a reservation admitted from an old link read.
      Repo.transaction(fn ->
        lock_owner(link.owner_id)
        link |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update!()
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  def receipts(scope) do
    link_ids = Enum.map(list(scope), & &1.id)

    Repo.all(
      from(b in Booking,
        where: b.link_id in ^link_ids,
        order_by: [desc: b.inserted_at],
        limit: 100
      )
    )
    |> Repo.preload(:delivery)
    |> Enum.map(fn receipt ->
      case receipt.delivery do
        %{status: status} when status in ["failed", "refused"] ->
          %{
            receipt
            | delivery_error:
                "Confirmation email delivery failed; owner must share the guest invite"
          }

        _ ->
          receipt
      end
    end)
  end

  @doc """
  What a guest may see about a link before booking. Task 01a18d9f stage 3
  adds the v4 guest card's host column (title, length, owner name and org,
  whether a meeting is created) alongside the original zone/email policy.
  """
  def public_policy(token) do
    with {:ok, link, scope} <- resolve(token),
         :ok <- meeting_policy(scope, link) do
      org =
        case Platform.Tenancy.list_user_memberships(scope.actor) do
          [%{org: %{name: name}} | _] -> name
          _ -> nil
        end

      {:ok,
       %{
         time_zone: link.time_zone,
         requires_email: link.create_meeting,
         title: link.title,
         duration_minutes: link.duration_minutes,
         create_meeting: link.create_meeting,
         owner_name: scope.actor.name,
         org_name: org
       }}
    end
  end

  def slots(token, date) when is_binary(date) do
    with {:ok, date} <- Date.from_iso8601(date), do: slots(token, date)
  end

  def slots(token, %Date{} = date) do
    with {:ok, link, scope} <- resolve(token),
         :ok <- rate_limit(token, "slots", 120),
         :ok <- meeting_policy(scope, link) do
      available(link, scope, date, date)
    end
  end

  def slots(_, _), do: {:error, :invalid_date}

  @doc """
  Open-slot counts per local date for the month containing `month`, for the
  v4 guest picker's highlighted days (task 01a18d9f stage 3). One public
  rate-limit unit for the whole month, where calling `slots/2` per day would
  spend 28-31.
  """
  def open_days(token, %Date{} = month) do
    with {:ok, link, scope} <- resolve(token),
         :ok <- rate_limit(token, "slots", 120),
         :ok <- meeting_policy(scope, link),
         {:ok, rows} <-
           available(link, scope, Date.beginning_of_month(month), Date.end_of_month(month)) do
      {:ok,
       rows
       |> Enum.group_by(
         &(&1.starts_at
           |> DateTime.shift_zone!(link.time_zone)
           |> DateTime.to_date())
       )
       |> Map.new(fn {date, slots} -> {date, length(slots)} end)}
    end
  end

  def open_days(_, _), do: {:error, :invalid_date}

  @doc """
  The owner's preview of what a guest sees: open slots of the owner's own,
  unrevoked link `link_id` over `days` days from `from` (v4 "Next open slots").
  Task 01a18d9f stage 3. Owner-scoped, so it skips the public token rate
  limit that `slots/2` spends per call.
  """
  def preview(%Scope{actor: %Accounts.User{}} = scope, link_id, %Date{} = from, days)
      when is_integer(days) and days in 1..62 do
    case Enum.find(list(scope), &(&1.id == link_id and is_nil(&1.revoked_at))) do
      %BookingLink{} = link -> available(link, scope, from, Date.add(from, days - 1))
      nil -> {:error, :not_found}
    end
  end

  def preview(_, _, _, _), do: {:error, :not_found}

  # Candidate starts on every date in first..last, minus busy time and
  # existing reservations (each widened by the link's buffers).
  defp available(link, scope, first, last) do
    candidates =
      Date.range(first, last)
      |> Enum.flat_map(fn date ->
        {:ok, rows} = candidates(link, date)
        rows
      end)

    {from, _} = CalendarWindow.day_bounds(first, link.time_zone)
    {_, to} = CalendarWindow.day_bounds(last, link.time_zone)
    reserved_from = DateTime.add(from, -86400)
    reserved_to = DateTime.add(to, 86400)

    with {:ok, busy} <-
           Subscriptions.availability(scope, reserved_from, reserved_to,
             time_zone: link.time_zone
           ) do
      reservations =
        Repo.all(
          from(b in Booking,
            where:
              b.owner_id == ^link.owner_id and b.reserved_start < ^reserved_to and
                b.reserved_end > ^reserved_from
          )
        )

      busy =
        busy ++ Enum.map(reservations, &%{starts_at: &1.reserved_start, ends_at: &1.reserved_end})

      {:ok, Enum.filter(candidates, &free?(&1, busy, link))}
    end
  end

  def book(token, attrs, key)
      when is_map(attrs) and is_binary(key) and byte_size(key) in 16..128 do
    with {:ok, link, _} <- resolve(token),
         :ok <- rate_limit(token, "book", 30),
         start_text when is_binary(start_text) <- Map.get(attrs, "starts_at", ""),
         {:ok, start, _} <- DateTime.from_iso8601(start_text),
         :ok <- validate_guest(attrs) do
      Repo.transaction(fn ->
        lock_owner(link.owner_id)
        # Re-resolve under lock: revocation, owner grants and module switches
        # can change between rendering a slot and submitting it.
        {link, scope} =
          case resolve(token) do
            {:ok, l, s} -> {l, s}
            _ -> Repo.rollback(:not_found)
          end

        existing = Repo.get_by(Booking, link_id: link.id, idempotency_key: key)

        if existing do
          if DateTime.compare(existing.starts_at, start) == :eq and existing.name == attrs["name"] and
               existing.email == blank_nil(attrs["email"]),
             do: existing,
             else: Repo.rollback(:idempotency_conflict)
        else
          cutoff = DateTime.add(DateTime.utc_now(), -3600)

          count =
            Repo.aggregate(
              from(b in Booking, where: b.owner_id == ^link.owner_id and b.inserted_at > ^cutoff),
              :count
            )

          if count >= 20, do: Repo.rollback(:rate_limited)
          date = start |> DateTime.shift_zone!(link.time_zone) |> DateTime.to_date()

          available =
            case slots(token, date) do
              {:ok, rows} -> Enum.find(rows, &(DateTime.compare(&1.starts_at, start) == :eq))
              {:error, reason} -> Repo.rollback(reason)
            end

          if is_nil(available), do: Repo.rollback(:slot_unavailable)

          case meeting_policy(scope, link) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          {event_id, meeting_id, delivery_id, delivery_error} =
            create_destination(scope, link, available, attrs)

          Repo.insert!(%Booking{
            owner_id: link.owner_id,
            link_id: link.id,
            idempotency_key: key,
            name: attrs["name"],
            email: blank_nil(attrs["email"]),
            starts_at: available.starts_at,
            ends_at: available.ends_at,
            reserved_start: DateTime.add(available.starts_at, -60 * link.buffer_before_minutes),
            reserved_end: DateTime.add(available.ends_at, 60 * link.buffer_after_minutes),
            event_id: event_id,
            meeting_id: meeting_id,
            delivery_id: delivery_id,
            delivery_error: delivery_error
          })
        end
      end)
      |> notify_mail()
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_booking}
    end
  end

  def book(_, _, _), do: {:error, :invalid_booking}

  defp create_destination(scope, %{create_meeting: false} = link, slot, attrs) do
    case Platform.Calendar.create_event(scope, %{
           title: link.title <> " · " <> attrs["name"],
           starts_at: slot.starts_at,
           ends_at: slot.ends_at,
           time_zone: link.time_zone,
           visibility: "busy"
         }) do
      {:ok, event} -> {event.id, nil, nil, nil}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp create_destination(scope, link, slot, attrs) do
    if is_nil(blank_nil(attrs["email"])), do: Repo.rollback(:email_required)

    with {:ok, meeting} <-
           Platform.Meetings.create_meeting(%{
             project_id: link.project_id,
             name: link.title,
             scheduled_start_at: slot.starts_at,
             scheduled_end_at: slot.ends_at
           }),
         {:ok, host} <-
           Platform.Chat.add_participant(meeting.chat_space_id, %{
             participant_type: "user",
             participant_id: scope.actor.id,
             role: "admin",
             joined_at: DateTime.utc_now()
           }),
         {:ok, meeting} <-
           Repo.update(Ecto.Changeset.change(meeting, host_participant_id: host.id)),
         {:ok, _owner_invite} <- Platform.Meetings.invite_user(meeting, scope.actor.id),
         {:ok, bundle} <-
           Platform.Meetings.invite_guest(meeting, %{
             display_name: attrs["name"],
             email: attrs["email"],
             host_user_id: scope.actor.id,
             expires_in_hours:
               max(24, div(DateTime.diff(slot.ends_at, DateTime.utc_now()), 3600) + 24)
           }) do
      {delivery_id, error} =
        Platform.Calendar.BookingConfirmation.enqueue(
          meeting,
          scope.actor.id,
          attrs,
          slot,
          bundle.url
        )

      {nil, meeting.id, delivery_id, error}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resolve(token) when is_binary(token) and byte_size(token) == 43 do
    with %BookingLink{revoked_at: nil} = link <- Repo.get_by(BookingLink, token: token),
         %Accounts.User{archived_at: nil} = user <- Accounts.get_user(link.owner_id),
         scope <- Scope.for_user(user),
         true <- Access.can?(scope, "calendar.write") do
      {:ok, link, scope}
    else
      _ -> {:error, :not_found}
    end
  end

  defp resolve(_), do: {:error, :not_found}

  defp meeting_policy(scope, %{create_meeting: true, project_id: id}) do
    if Platform.Meetings.Config.enabled?() and Access.can?(scope, "meetings.join") and
         Enum.any?(
           Platform.Tasks.list_projects_for_user(scope.actor),
           &(&1.id == id and is_nil(&1.archived_at))
         ), do: :ok, else: {:error, :meetings_unavailable}
  end

  defp meeting_policy(_, _), do: :ok

  defp candidates(link, date) do
    if Date.compare(date, link.start_date) != :lt and Date.compare(date, link.end_date) != :gt do
      windows = Enum.filter(link.windows, &(&1["weekday"] == Date.day_of_week(date)))

      slots =
        Enum.flat_map(windows, fn window ->
          {:ok, first} = BookingLink.parse_time(window["start"])
          {:ok, last} = BookingLink.parse_time(window["end"])
          first = NaiveDateTime.new!(date, first)
          last = NaiveDateTime.new!(date, last)

          Stream.iterate(first, &NaiveDateTime.add(&1, link.duration_minutes * 60))
          |> Enum.take_while(
            &(NaiveDateTime.compare(NaiveDateTime.add(&1, link.duration_minutes * 60), last) !=
                :gt)
          )
          |> Enum.flat_map(fn naive ->
            # Ambiguous and missing local times at DST transitions are omitted.
            with {:ok, start} <- DateTime.from_naive(naive, link.time_zone),
                 finish_naive <- NaiveDateTime.add(naive, link.duration_minutes * 60),
                 {:ok, finish} <- DateTime.from_naive(finish_naive, link.time_zone),
                 true <- DateTime.diff(finish, start) == link.duration_minutes * 60,
                 true <- DateTime.compare(start, earliest_start(link)) == :gt do
              [
                %{
                  starts_at: utc_usec(start),
                  ends_at: utc_usec(finish)
                }
              ]
            else
              _ -> []
            end
          end)
        end)

      {:ok, Enum.uniq_by(slots, & &1.starts_at) |> Enum.sort_by(& &1.starts_at, DateTime)}
    else
      {:ok, []}
    end
  end

  # Minimum notice (task 01a18d9f stage 3): a start must lie further ahead
  # than the link's notice; 0 keeps "any future start".
  defp earliest_start(link),
    do: DateTime.add(DateTime.utc_now(), 60 * (link.minimum_notice_minutes || 0))

  defp free?(slot, busy, link) do
    first = DateTime.add(slot.starts_at, -60 * link.buffer_before_minutes)
    last = DateTime.add(slot.ends_at, 60 * link.buffer_after_minutes)

    not Enum.any?(
      busy,
      &(DateTime.compare(&1.starts_at, last) == :lt and DateTime.compare(&1.ends_at, first) == :gt)
    )
  end

  defp validate_guest(attrs) do
    name = attrs["name"]
    email = blank_nil(attrs["email"])

    if is_binary(name) and byte_size(name) in 1..120 and String.trim(name) != "" and
         (is_nil(email) or
            (is_binary(email) and byte_size(email) <= 254 and
               Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, email))),
       do: :ok,
       else: {:error, :invalid_guest}
  end

  defp utc_usec(value) do
    value = DateTime.shift_zone!(value, "Etc/UTC")
    %{value | microsecond: {elem(value.microsecond, 0), 6}}
  end

  defp rate_limit(token, action, limit) when is_binary(token) and byte_size(token) == 43,
    do: Platform.Calendar.BookingRateLimit.check({action, :crypto.hash(:sha256, token)}, 1, limit)

  defp rate_limit(_, _, _), do: {:error, :not_found}

  defp notify_mail({:ok, %Booking{delivery_id: id}} = result) when not is_nil(id) do
    Platform.Mail.Outbox.nudge()
    result
  end

  defp notify_mail(result), do: result
  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value

  defp lock_owner(id),
    do: Repo.one!(from(u in Accounts.User, where: u.id == ^id, lock: "FOR UPDATE"))

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
