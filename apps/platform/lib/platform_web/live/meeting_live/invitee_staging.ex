defmodule PlatformWeb.MeetingLive.InviteeStaging do
  @moduledoc """
  Staged people for an event that is not saved yet: the invitee rows a call
  record already has, the ones marked removed (with undo), the ones staged
  to add, and the add-people search (task 01a1b8a5 stage 2, extracted from
  `PlatformWeb.MeetingLive.MeetingEdit`).

  ONE implementation, used by the /meetings Edit meeting form
  (`MeetingEdit`) and the Calendar event editor
  (`PlatformWeb.CalendarLive.Editor`), so both stage people the same way.

  It decides nothing about mail or permission. Whether removing a row would
  be refused is the caller's question to `Meetings.preview_meeting_edit/2`
  (`remove/3` takes that verdict as a function); who may edit is checked by
  the caller on every event.

  State keys: `invitees` (existing rows), `removed_ids`, `added`,
  `adding?`, `query`, `candidates`, `email` and `refused?`.
  """

  alias Platform.Meetings
  alias PlatformWeb.MeetingLive

  @doc "The empty staging state, for a meeting's rows (or none)."
  def init(invitees \\ []),
    do: %{
      invitees: invitees,
      removed_ids: [],
      added: [],
      adding?: false,
      query: "",
      candidates: [],
      email: nil,
      refused?: false
    }

  @doc "A meeting's people rows, agents excluded (they are not invitees here)."
  def rows(meeting), do: meeting |> MeetingLive.detail_invite_rows() |> Enum.reject(& &1.agent)

  @doc """
  Mark existing row `id` removed. `refused?` answers whether the edit with
  `id` also removed would be refused (the last-invitee rule); a refused
  removal only sets the flag. An unknown or already-removed id is a no-op.
  """
  def remove(state, id, refused?) when is_function(refused?, 1) do
    known? = Enum.any?(state.invitees, &(&1.id == id)) and id not in state.removed_ids

    cond do
      not known? -> state
      refused?.(state.removed_ids ++ [id]) -> %{state | refused?: true}
      true -> %{state | removed_ids: state.removed_ids ++ [id], refused?: false}
    end
  end

  def undo(state, id), do: %{state | removed_ids: List.delete(state.removed_ids, id)}

  def unstage(state, id),
    do: %{state | added: Enum.reject(state.added, &(&1.id == id)), refused?: false}

  def open(state), do: %{state | adding?: true}

  @doc "Run the add-people search, excluding everyone already kept or staged."
  def search(state, query) do
    query = to_string(query)

    if String.trim(query) == "" do
      %{state | query: "", candidates: [], email: nil}
    else
      kept = Enum.reject(state.invitees, &(&1.id in state.removed_ids))

      %{users: users, email: email} =
        Meetings.resolve_invite_candidates(query,
          exclude_user_ids: for(r <- kept ++ state.added, is_binary(r.user_id), do: r.user_id),
          exclude_emails: for(r <- kept ++ state.added, is_binary(r.email), do: r.email)
        )

      %{state | query: query, candidates: users, email: email, adding?: true}
    end
  end

  @doc """
  Stage the entry `params` names (InviteControl's stage payload). Returns
  `{:ok, state}` with the search cleared, or `:error` when the payload names
  nothing stageable (a user the search did not offer, a blank address).
  """
  def stage(state, params) do
    case entry(state, params) do
      nil ->
        :error

      entry ->
        added =
          if Enum.any?(state.added, &(&1.id == entry.id)),
            do: state.added,
            else: state.added ++ [entry]

        {:ok, %{state | added: added, query: "", candidates: [], email: nil, refused?: false}}
    end
  end

  @doc """
  Enter in the search box: search for `value`, then stage what it resolves
  to. `{:ok, state}` when something was staged, `{:searched, state}` when
  nothing matched.
  """
  def commit(state, value) do
    state = search(state, value)

    case MeetingLive.LiveInvites.commit_params(state.candidates, state.email, to_string(value)) do
      nil ->
        {:searched, state}

      params ->
        case stage(state, params) do
          {:ok, state} -> {:ok, state}
          :error -> {:searched, state}
        end
    end
  end

  @doc "The staged additions in the Meetings create/edit entry shape."
  def additions(state),
    do: Enum.map(state.added, &Map.take(&1, [:kind, :user_id, :email, :display_name]))

  # A user must be one of the candidates the search offered; an address or
  # a guest name is whatever was typed. Anything else stages nothing.
  defp entry(state, %{"kind" => "user", "id" => user_id}) do
    case Enum.find(state.candidates, &(&1.id == user_id)) do
      nil ->
        nil

      user ->
        %{
          id: "user:" <> user.id,
          kind: :user,
          user_id: user.id,
          email: user.email,
          display_name: user.name || user.email,
          subtitle: user.name && user.email
        }
    end
  end

  defp entry(_state, %{"kind" => kind, "email" => email}) when kind in ["guest", "external"] do
    case trim(email) do
      "" ->
        nil

      address ->
        %{
          id: kind <> ":" <> address,
          kind: if(kind == "guest", do: :guest, else: :external),
          user_id: nil,
          email: address,
          display_name: address,
          subtitle: if(kind == "guest", do: "guest link", else: "external member")
        }
    end
  end

  defp entry(_state, %{"kind" => "guest", "name" => name}) do
    case trim(name) do
      "" ->
        nil

      trimmed ->
        %{
          id: "guest-name:" <> trimmed,
          kind: :guest,
          user_id: nil,
          email: nil,
          display_name: trimmed,
          subtitle: "guest link"
        }
    end
  end

  defp entry(_state, _params), do: nil

  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
