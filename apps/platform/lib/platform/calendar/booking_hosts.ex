defmodule Platform.Calendar.BookingHosts do
  @moduledoc """
  The single owner of a booking link's host set (task 01a1eff0-6880 stage 1).

  A link's hosts are its owner plus every `BookingLinkHost` row. The owner
  invites; the invited user accepts, declines or later leaves; the owner can
  remove or re-invite. The invite is an in-app Inbox row only
  (`booking_cohost_invite`): nothing here writes to an external calendar,
  sends mail or builds an .ics.

  ## The readiness rule

  `hosts_ready/1` decides whether a link may offer times, and every caller
  uses it. A link with zero co-host rows is a single-owner link and is ready
  exactly as it was before co-hosts existed. Otherwise EVERY row must be
  `accepted`, and every co-host must be unarchived, hold `calendar.read` and
  `calendar.write`, and still share a non-external org membership with the
  owner. Anything else (a pending, declined or left row, or any failed check)
  means the link offers nothing, and the error is the opaque
  `:hosts_not_ready`: it never says which host failed.

  ## Lock order

  Every host-set write locks the affected users' rows through
  `lock_hosts/1`: ids de-duplicated and sorted, one `SELECT ... FOR UPDATE`
  each, in that order. Bookings lock the same rows the same way, so host-set
  writes and reservations serialise in one global order and cannot deadlock
  on each other.
  """
  import Ecto.Query
  alias Platform.{Access, Accounts, Inbox, Repo, Tenancy}
  alias Platform.Access.Scope
  alias Platform.Calendar.{BookingLink, BookingLinkHost}
  alias Platform.Tenancy.OrgMembership

  @kind "booking_cohost_invite"
  @source_type "booking_link_host"

  @doc "The Inbox kind an invite emits."
  def inbox_kind, do: @kind

  @doc "The Inbox source type an invite row points at."
  def inbox_source_type, do: @source_type

  # ── Owner actions ───────────────────────────────────────────────────────

  @doc """
  Invite `user_id` to co-host the owner's link.

  Refuses the owner themself (`:owner_cannot_cohost`), a user who shares no
  non-external org with the owner (`:not_org_member`), a revoked link
  (`:revoked`) and a user already pending or accepted (`:already_invited`).
  A declined or left row is set back to pending. Emits the invite Inbox row
  after the write commits.
  """
  def invite(%Scope{actor: %Accounts.User{id: owner_id} = owner} = scope, link_id, user_id) do
    with :ok <- Access.authorize(scope, "calendar.write"),
         {:ok, link} <- owned_link(owner_id, link_id),
         :ok <- not_revoked(link),
         {:ok, invitee} <- invitee(user_id),
         :ok <- not_owner(owner_id, invitee.id),
         :ok <- shared_org(owner_id, invitee.id),
         {:ok, host} <- write_invite(link, owner_id, invitee.id, [:none, "declined", "left"]) do
      notify_invite(host, link, owner)
    end
  end

  def invite(_, _, _), do: {:error, :forbidden}

  @doc """
  Set a declined or left co-host back to pending and send them a fresh
  invite. A pending or accepted row is refused (`:already_invited`), a
  missing row is `:not_found`. Same refusals as `invite/3` otherwise.
  """
  def reinvite(%Scope{actor: %Accounts.User{id: owner_id} = owner} = scope, link_id, user_id) do
    with :ok <- Access.authorize(scope, "calendar.write"),
         {:ok, link} <- owned_link(owner_id, link_id),
         :ok <- not_revoked(link),
         {:ok, invitee} <- invitee(user_id),
         :ok <- not_owner(owner_id, invitee.id),
         :ok <- shared_org(owner_id, invitee.id),
         {:ok, host} <- write_invite(link, owner_id, invitee.id, ["declined", "left"]) do
      notify_invite(host, link, owner)
    end
  end

  def reinvite(_, _, _), do: {:error, :forbidden}

  @doc "Remove a co-host row from the owner's link and dismiss its invite row."
  def remove(%Scope{actor: %Accounts.User{id: owner_id}} = scope, link_id, user_id) do
    with :ok <- Access.authorize(scope, "calendar.write"),
         {:ok, link} <- owned_link(owner_id, link_id),
         true <- Platform.UUID.valid?(user_id) || {:error, :not_found},
         %BookingLinkHost{} <-
           Repo.get_by(BookingLinkHost, link_id: link.id, user_id: user_id) ||
             {:error, :not_found} do
      Repo.transaction(fn ->
        lock_hosts([owner_id, user_id])

        case Repo.get_by(BookingLinkHost, link_id: link.id, user_id: user_id) do
          nil -> Repo.rollback(:not_found)
          host -> Repo.delete!(host)
        end
      end)
      |> tap(fn
        {:ok, host} -> dismiss_invite(host)
        _ -> :ok
      end)
    end
  end

  def remove(_, _, _), do: {:error, :forbidden}

  # ── Co-host actions ─────────────────────────────────────────────────────

  @doc "Accept a pending invite addressed to the caller."
  def accept(scope, host_id) do
    with :ok <- Access.authorize(scope, "calendar.write") do
      respond(scope, host_id, ["pending"], "accepted")
    end
  end

  @doc "Decline a pending invite addressed to the caller."
  def decline(scope, host_id), do: respond(scope, host_id, ["pending"], "declined")

  @doc "Stop co-hosting a link the caller had accepted."
  def leave(scope, host_id), do: respond(scope, host_id, ["accepted"], "left")

  # ── Reads ───────────────────────────────────────────────────────────────

  @doc "Every co-host row of a link, oldest first, with `:user` preloaded."
  def list_for_link(%BookingLink{id: id}), do: list_for_link(id)

  def list_for_link(link_id) when is_binary(link_id) do
    Repo.all(
      from(h in BookingLinkHost,
        where: h.link_id == ^link_id,
        order_by: [asc: h.inserted_at, asc: h.id],
        preload: [:user]
      )
    )
  end

  @doc """
  The live links a user co-hosts or is invited to co-host (pending or
  accepted rows on unrevoked links), newest first, `:link` and its `:owner`
  preloaded.
  """
  def list_for_user(%Scope{actor: %Accounts.User{id: id}}), do: list_for_user(id)
  def list_for_user(%Accounts.User{id: id}), do: list_for_user(id)

  def list_for_user(user_id) when is_binary(user_id) do
    Repo.all(
      from(h in BookingLinkHost,
        join: l in assoc(h, :link),
        where: h.user_id == ^user_id and h.status in ["pending", "accepted"],
        where: is_nil(l.revoked_at),
        order_by: [desc: h.inserted_at, desc: h.id],
        preload: [link: {l, :owner}]
      )
    )
  end

  def list_for_user(_), do: []

  @doc """
  The users whose calendars a link books against: `{:ok, [owner | accepted
  co-hosts]}` when every co-host passes the readiness rule (see the
  moduledoc), `{:error, :hosts_not_ready}` otherwise. The error never names
  the host that failed.
  """
  def hosts_ready(%BookingLink{} = link) do
    with %Accounts.User{} = owner <- Accounts.get_user(link.owner_id),
         {:ok, cohosts} <- ready_cohosts(link, owner) do
      {:ok, [owner | cohosts]}
    else
      _ -> {:error, :hosts_not_ready}
    end
  end

  def hosts_ready(_), do: {:error, :hosts_not_ready}

  @doc """
  Lock the given users' rows in one global order: de-duplicated, sorted,
  then one `SELECT ... FOR UPDATE` per id. Must run inside a transaction.
  Mirrors `BookingLinks`' owner lock, widened to a host set.
  """
  def lock_hosts(user_ids) when is_list(user_ids) do
    user_ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn id ->
      Repo.one!(from(u in Accounts.User, where: u.id == ^id, lock: "FOR UPDATE"))
    end)
  end

  # ── Internals ───────────────────────────────────────────────────────────

  defp ready_cohosts(link, owner) do
    link
    |> list_for_link()
    |> Enum.reduce_while({:ok, []}, fn host, {:ok, acc} ->
      if ready?(host, owner),
        do: {:cont, {:ok, [host.user | acc]}},
        else: {:halt, :not_ready}
    end)
    |> case do
      {:ok, users} -> {:ok, Enum.reverse(users)}
      other -> other
    end
  end

  defp ready?(%BookingLinkHost{status: "accepted", user: %Accounts.User{} = user}, owner) do
    scope = Scope.for_user(user)

    is_nil(user.archived_at) and Access.can?(scope, "calendar.read") and
      Access.can?(scope, "calendar.write") and shared_org(owner.id, user.id) == :ok
  end

  defp ready?(_host, _owner), do: false

  defp respond(%Scope{actor: %Accounts.User{id: user_id}}, host_id, from, to) do
    with true <- Platform.UUID.valid?(host_id) || {:error, :not_found},
         %BookingLinkHost{} = host <- Repo.get_by(BookingLinkHost, id: host_id, user_id: user_id),
         %BookingLink{} = link <- Repo.get(BookingLink, host.link_id) do
      Repo.transaction(fn ->
        lock_hosts([link.owner_id, user_id])
        current = Repo.get!(BookingLinkHost, host.id)

        if current.status in from do
          current
          |> BookingLinkHost.changeset(%{status: to, responded_at: DateTime.utc_now()})
          |> Repo.update!()
        else
          Repo.rollback(:invalid_transition)
        end
      end)
      |> tap(fn
        {:ok, updated} -> dismiss_invite(updated)
        _ -> :ok
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  defp respond(_, _, _, _), do: {:error, :forbidden}

  # `allowed` lists the existing statuses this write may move to pending;
  # `:none` means a fresh row may be inserted.
  defp write_invite(link, owner_id, user_id, allowed) do
    Repo.transaction(fn ->
      lock_hosts([owner_id, user_id])
      current = Repo.get!(BookingLink, link.id)
      if current.revoked_at, do: Repo.rollback(:revoked)

      case Repo.get_by(BookingLinkHost, link_id: link.id, user_id: user_id) do
        nil ->
          if :none in allowed,
            do: insert_host(link.id, owner_id, user_id),
            else: Repo.rollback(:not_found)

        %BookingLinkHost{status: status} = host ->
          if status in allowed,
            do: repend(host, owner_id),
            else: Repo.rollback(:already_invited)
      end
    end)
  end

  defp insert_host(link_id, owner_id, user_id) do
    %BookingLinkHost{}
    |> BookingLinkHost.changeset(%{
      link_id: link_id,
      user_id: user_id,
      invited_by_id: owner_id,
      status: "pending"
    })
    |> Repo.insert()
    |> case do
      {:ok, host} -> host
      {:error, cs} -> Repo.rollback(cs)
    end
  end

  defp repend(host, owner_id) do
    host
    |> BookingLinkHost.changeset(%{status: "pending", responded_at: nil, invited_by_id: owner_id})
    |> Repo.update!()
  end

  defp notify_invite(host, link, owner) do
    dismiss_invite(host)

    case Inbox.emit(%{
           user_id: host.user_id,
           kind: @kind,
           source_type: @source_type,
           source_id: host.id,
           title: "#{first_name(owner)} invited you to co-host \"#{link.title}\"",
           body:
             "Your free/busy times will be used to offer slots on #{first_name(owner)}'s link. " <>
               "Guests never see your calendar.",
           url: "/calendar/booking?cohost=#{host.id}"
         }) do
      {:ok, _item} -> {:ok, host}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dismiss_invite(%BookingLinkHost{id: id, user_id: user_id}) do
    {:ok, _} = Inbox.dismiss_by_source(user_id, @source_type, id, kind: @kind)
    :ok
  end

  defp owned_link(owner_id, link_id) do
    with true <- Platform.UUID.valid?(link_id),
         %BookingLink{} = link <- Repo.get_by(BookingLink, id: link_id, owner_id: owner_id) do
      {:ok, link}
    else
      _ -> {:error, :not_found}
    end
  end

  defp not_revoked(%BookingLink{revoked_at: nil}), do: :ok
  defp not_revoked(_), do: {:error, :revoked}

  defp invitee(user_id) do
    case Accounts.get_user(user_id) do
      %Accounts.User{archived_at: nil} = user -> {:ok, user}
      _ -> {:error, :not_found}
    end
  end

  defp not_owner(id, id), do: {:error, :owner_cannot_cohost}
  defp not_owner(_, _), do: :ok

  # True when some org holds both users and neither is an external member
  # of it.
  defp shared_org(owner_id, user_id) do
    org_ids =
      Repo.all(
        from(m in OrgMembership,
          where: m.user_id == ^user_id,
          where: m.org_id in subquery(Tenancy.viewer_org_ids_query(owner_id)),
          select: m.org_id,
          distinct: true
        )
      )

    if Enum.any?(
         org_ids,
         &(MapSet.size(Tenancy.external_member_ids(&1, [owner_id, user_id])) == 0)
       ),
       do: :ok,
       else: {:error, :not_org_member}
  end

  defp first_name(%Accounts.User{name: name}) when is_binary(name) do
    case String.split(name) do
      [first | _] -> first
      [] -> "Someone"
    end
  end

  defp first_name(_), do: "Someone"
end
