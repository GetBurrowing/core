defmodule Platform.Meetings.CallInvites do
  @moduledoc """
  Who a call started from the native app rings (task 01a111bb): "start a
  meeting with Harper" or "call the all-hands group".

  Two steps, deliberately apart, so a refused request creates nothing:

    1. `authorize/3` resolves and checks every invitee and returns the user
       ids. It writes nothing.
    2. `invite/2` takes a meeting that already exists and writes one draft
       invite per user id.

  `PlatformWeb.AppIntentsController.create_meeting/2` runs `authorize/3`,
  then creates the meeting, then `invite/2`. This module does not know how
  the meeting was minted, so a different creation path (task 01a04e9e's
  channel-bound ad-hoc meetings) can sit in the middle unchanged.

  ## Who may be invited

  An explicit invitee must pass `Platform.Chat.dm_candidates/3`, the same
  predicate the New Conversation picker and the app's people directory use:
  an external caller can ring only the allow-listed people they could DM.
  An agent id answers `{:error, :agent_not_callable}`; agents cannot take a
  call. At most 10 explicit invitees.

  `invite_space_id` is authorized with the checks Chat itself exposes (the
  space exists and is not archived, `ExternalScope.authorized_space?/2`
  admits the caller, and the caller is a participant), not through
  `Platform.Mobile`, so the Meetings domain depends only on Chat. It
  resolves to the space's human participants other than the caller, oldest
  membership first, filtered through the same predicate.

  ## The 25-person cap is a product decision

  A space resolves to at most 25 people. `Platform.Meetings.Ringing` rings
  once per explicit invite row when the meeting starts, so calling a space
  with 25 or more other humans rings 25 phones at once. That ceiling was
  chosen deliberately at plan time; it is not an incidental limit, and the
  iOS client confirms before ringing a whole group.

  ## Draft invites

  `invite/2` calls `Meetings.invite_user/3` WITHOUT `:inviter_user_id`. These
  are draft invites: they ring on `:meeting_started` per
  `Platform.Meetings.Ringing`, not as a live invite into a running meeting.
  """

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.ExternalScope
  alias Platform.Chat.Participant
  alias Platform.Chat.Space
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Repo

  require Logger

  @max_invitees 10
  @space_invite_cap 25

  @doc "The most explicit invitees one request may name."
  def max_invitees, do: @max_invitees

  @doc "The most people an `invite_space_id` resolves to (a product choice)."
  def space_invite_cap, do: @space_invite_cap

  @doc """
  Resolve and check the invitees of a call `user` is about to start.
  Creates nothing.

  Returns `{:ok, user_ids}` (deduplicated, never the caller), or
  `{:error, :forbidden}` (a person the caller may not reach, a malformed id,
  or a space the caller cannot use), `{:error, :agent_not_callable}`, or
  `{:error, :too_many_invitees}`.
  """
  @spec authorize(map(), term(), term()) ::
          {:ok, [binary()]}
          | {:error, :forbidden | :agent_not_callable | :too_many_invitees}
  def authorize(%{id: _} = user, invitee_user_ids, invite_space_id) do
    with {:ok, explicit} <- authorize_ids(user, invitee_user_ids),
         {:ok, from_space} <- authorize_space(user, invite_space_id) do
      {:ok, Enum.uniq(explicit ++ from_space)}
    end
  end

  defp authorize_ids(_user, ids) when ids in [nil, []], do: {:ok, []}

  defp authorize_ids(_user, ids) when is_list(ids) and length(ids) > @max_invitees,
    do: {:error, :too_many_invitees}

  defp authorize_ids(user, ids) when is_list(ids) do
    ids = ids |> Enum.uniq() |> Enum.reject(&(&1 == user.id))

    cond do
      ids == [] ->
        {:ok, []}

      not Enum.all?(ids, &(is_binary(&1) and Platform.UUID.valid?(&1))) ->
        {:error, :forbidden}

      Repo.exists?(from(a in Agent, where: a.id in ^ids)) ->
        {:error, :agent_not_callable}

      true ->
        permitted = user |> Chat.dm_candidates("", ids: ids) |> MapSet.new(& &1.id)

        if Enum.all?(ids, &MapSet.member?(permitted, &1)),
          do: {:ok, ids},
          else: {:error, :forbidden}
    end
  end

  defp authorize_ids(_user, _ids), do: {:error, :forbidden}

  defp authorize_space(_user, space_id) when space_id in [nil, ""], do: {:ok, []}

  defp authorize_space(user, space_id) do
    with true <- is_binary(space_id) and Platform.UUID.valid?(space_id),
         %Space{archived_at: nil} = space <- Chat.get_space(space_id),
         true <- ExternalScope.authorized_space?(user, space),
         true <- Chat.participant?(space.id, user.id) do
      {:ok, space_humans(user, space)}
    else
      _ -> {:error, :forbidden}
    end
  end

  # The space's other humans, oldest membership first, through the same
  # predicate, then capped. Filter BEFORE the cap so a refused member does
  # not use up a slot.
  defp space_humans(user, %Space{id: space_id}) do
    member_ids =
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "user" and
            p.participant_id != ^user.id,
        order_by: [asc: p.joined_at, asc: p.id],
        select: p.participant_id
      )
      |> Repo.all()
      |> Enum.uniq()

    case member_ids do
      [] ->
        []

      ids ->
        permitted = user |> Chat.dm_candidates("", ids: ids) |> MapSet.new(& &1.id)

        ids
        |> Enum.filter(&MapSet.member?(permitted, &1))
        |> Enum.take(@space_invite_cap)
    end
  end

  @doc """
  Write one draft invite per user id on an existing meeting, with no
  `:inviter_user_id`. Returns the invites written; a failed row is skipped
  and counted in a log line (ids and counts only).
  """
  @spec invite(Meeting.t(), [binary()]) :: {:ok, [Invite.t()]}
  def invite(%Meeting{} = meeting, user_ids) when is_list(user_ids) do
    {invites, failed} =
      Enum.reduce(user_ids, {[], 0}, fn user_id, {acc, failed} ->
        case Meetings.invite_user(meeting, user_id) do
          {:ok, %Invite{} = invite} -> {[invite | acc], failed}
          {:error, _} -> {acc, failed + 1}
        end
      end)

    if failed > 0 do
      Logger.warning("[CallInvites] meeting=#{meeting.id} invites_failed=#{failed}")
    end

    {:ok, Enum.reverse(invites)}
  end
end
