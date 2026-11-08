defmodule Platform.Calendar.Authoring do
  @moduledoc """
  The one save boundary for Calendar events (task 01a1b8a5 stage 1): a thin
  coordinator over two existing stores, never a third.

    * Native event attributes go through `Platform.Calendar`'s own
      `create_event/2`, `update_event/3` and `delete_event/2`, with their
      owner and scope checks.
    * Anything call-backed goes through `Platform.Meetings`:
      `Meetings.Scheduling.create_with_invites/2` (the scheduling sheet's
      create path) to create, `Meetings.update_meeting_for_user/3` to save,
      `Meetings.preview_meeting_edit/2` to preview,
      `Meetings.delete_meeting_for_user/2` to delete and
      `Meetings.can_edit_meeting?/3` to say whether the viewer may edit.

  This module has NO authorization policy, update planner, recipient
  classifier, invite reconciliation or mail sender of its own. Who may edit a
  call, who is told and with what SEQUENCE are all Meetings' answers, so a
  Calendar save and a Meetings-page save cannot disagree.

  ## Shapes

    * A plain native event: a `calendar_events` row, `meeting_id` nil. Call OFF.
    * A call-backed event authored here: a native row linked by
      `calendar_events.meeting_id` (unique) to one `meetings` row, which holds
      people, guests, notes and `call_enabled`. The meeting's sync keeps the
      native title and window in step whichever surface edits it.
    * A legacy meeting: a `meetings` row with no native row. Edited directly
      through Meetings; it gains a linked native row only when the draft sets
      something a meeting cannot hold (a preset, busy visibility, all-day).

  Every write that touches both stores runs in one transaction with the
  Meetings step LAST, so a refusal from Meetings (forbidden, not editable,
  last invitee, invalid) rolls the native write back, and nothing that can
  fail runs after Meetings has broadcast the edit its notifier mails from.

  ## Not shims

  The direct-call APIs this composes (`/meetings/:slug`, `/g/*` guest links,
  `invite.ics`, the Meetings edit functions) are durable supported APIs, not
  temporary parallel-UI paths, so nothing here is registered with
  `Platform.ParallelUI`.
  """

  import Ecto.Query

  alias Platform.{Access, Calendar, Meetings, Repo}
  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Calendar.{Event, EventDraft}
  alias Platform.Meetings.{Meeting, Scheduling}

  @type result :: %{
          event: Event.t() | nil,
          meeting: Meeting.t() | nil,
          undelivered: [map()],
          failed: [map()]
        }

  @doc "May this viewer turn a Burrow call on? Install switch plus `meetings.join`."
  @spec call_available?(Scope.t() | term()) :: boolean()
  def call_available?(%Scope{actor: %User{}} = scope),
    do: Meetings.Config.enabled?() and Access.can?(scope, "meetings.join")

  def call_available?(_scope), do: false

  @doc """
  A new draft. An ordinary event defaults the call ON only when
  `call_available?/1`; a preset never does. `attrs` prefill the draft (a
  selected range, a project) and cannot switch a call on for a viewer who
  may not have one.
  """
  @spec new_draft(Scope.t(), map()) :: EventDraft.t()
  def new_draft(scope, attrs \\ %{}) do
    draft = EventDraft.prefill(%EventDraft{call_enabled: true}, attrs)

    %{
      draft
      | source: "new",
        event_id: nil,
        meeting_id: nil,
        call_enabled: draft.call_enabled and draft.preset == "event" and call_available?(scope)
    }
  end

  @doc """
  Load an existing event or meeting into a draft. `{:meeting, id}` for a
  meeting linked to the viewer's own native event loads that event, so both
  doors open the same draft.
  """
  @spec load_draft(Scope.t(), {:event | :meeting, binary()}) ::
          {:ok, EventDraft.t()} | {:error, :not_found}
  def load_draft(%Scope{actor: %User{id: user_id} = user} = scope, {:event, id}) do
    with {:ok, %Event{owner_id: ^user_id, tentative: false, cancelled_at: nil} = event} <-
           Calendar.get_event(scope, id) do
      meeting = linked_meeting(event, user)

      {:ok,
       %EventDraft{
         source: "event",
         event_id: event.id,
         meeting_id: meeting && meeting.id,
         project_id: event.project_id,
         space_id: event.space_id,
         title: event.title,
         notes: if(meeting, do: meeting.description, else: event.description),
         starts_at: event.starts_at,
         ends_at: event.ends_at,
         time_zone: event.time_zone,
         all_day: event.all_day,
         start_date: event.start_date,
         end_date: event.end_date,
         recurrence: event.recurrence,
         visibility: event.visibility,
         preset: event.preset,
         call_enabled: (meeting && meeting.call_enabled) || false,
         editable: is_nil(meeting) or Meetings.can_edit_meeting?(meeting, user)
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def load_draft(%Scope{actor: %User{id: user_id} = user} = scope, {:meeting, id}) do
    with {:ok, meeting} <- Meetings.get_meeting_for_user(user, id) do
      case linked_event(meeting.id) do
        %Event{owner_id: ^user_id, id: event_id} ->
          load_draft(scope, {:event, event_id})

        _ ->
          {:ok,
           %EventDraft{
             source: "meeting",
             meeting_id: meeting.id,
             project_id: meeting.project_id,
             title: meeting.name,
             notes: meeting.description,
             starts_at: meeting.scheduled_start_at,
             ends_at: meeting.scheduled_end_at,
             call_enabled: meeting.call_enabled,
             editable: Meetings.can_edit_meeting?(meeting, user)
           }}
      end
    end
  end

  def load_draft(_scope, _ref), do: {:error, :not_found}

  @doc """
  What saving `attrs` would do. For a call-backed draft this is exactly
  `Meetings.preview_meeting_edit/2`'s answer; a draft with no existing call
  record has nobody to tell yet and previews as `nil`.
  """
  @spec preview(Scope.t(), EventDraft.t(), map()) ::
          {:ok, map() | nil} | {:error, Ecto.Changeset.t() | :not_found}
  def preview(%Scope{actor: %User{} = user} = scope, %EventDraft{} = base, attrs) do
    with {:ok, draft} <- apply_draft(scope, base, attrs),
         {:ok, window} <- window(draft) do
      case draft.meeting_id do
        nil ->
          {:ok, nil}

        meeting_id ->
          with {:ok, meeting} <- Meetings.get_meeting_for_user(user, meeting_id) do
            {:ok, Meetings.preview_meeting_edit(meeting, meeting_edit_attrs(draft, window))}
          end
      end
    end
  end

  def preview(_scope, _base, _attrs), do: {:error, :not_found}

  @doc """
  Save `attrs` over `base` (a `new_draft/2` or `load_draft/2` result).

  Returns `{:ok, %{event, meeting, undelivered, failed}}`: `event` is the
  native row (nil for a legacy meeting edited in place), `meeting` the call
  record (nil for a plain event), `undelivered` the staged invitees a create
  could not invite and `failed` the ones an edit could not add.
  """
  @spec save(Scope.t(), EventDraft.t(), map()) :: {:ok, result()} | {:error, term()}
  def save(%Scope{actor: %User{}} = scope, %EventDraft{} = base, attrs) when is_map(attrs) do
    with {:ok, draft} <- apply_draft(scope, base, attrs),
         {:ok, window} <- window(draft) do
      do_save(scope, draft, window)
    end
  end

  def save(_scope, _base, _attrs), do: {:error, :forbidden}

  @doc """
  Delete the draft's event. A call record is deleted only by
  `Meetings.delete_meeting_for_user/2`, under its lifecycle rule (an upcoming
  call is `:not_deletable`; cancel it first), and a refusal leaves the native
  event in place.
  """
  @spec delete(Scope.t(), EventDraft.t()) :: {:ok, result()} | {:error, term()}
  def delete(%Scope{actor: %User{} = user} = scope, %EventDraft{} = draft) do
    case {draft.event_id, draft.meeting_id} do
      {nil, nil} ->
        {:error, :not_found}

      {event_id, nil} ->
        with {:ok, event} <- Calendar.delete_event(scope, event_id),
             do: {:ok, result(event, nil)}

      {event_id, meeting_id} ->
        transaction(fn ->
          with {:ok, event} <- maybe_delete_event(scope, event_id),
               {:ok, meeting} <- Meetings.delete_meeting_for_user(meeting_id, user) do
            {:ok, result(event, meeting)}
          end
        end)
    end
  end

  def delete(_scope, _draft), do: {:error, :not_found}

  # ── Save paths ───────────────────────────────────────────────────────────

  # New draft.
  defp do_save(scope, %EventDraft{event_id: nil, meeting_id: nil} = draft, window) do
    if EventDraft.call_record?(draft) do
      transaction(fn ->
        with {:ok, event} <- Calendar.create_event(scope, event_attrs(draft, :call)),
             {:ok, meeting, undelivered} <- create_call(scope, draft, window),
             {:ok, event} <- link(event, meeting) do
          {:ok, %{result(event, meeting) | undelivered: undelivered}}
        end
      end)
    else
      with {:ok, event} <- Calendar.create_event(scope, event_attrs(draft, :native)),
           do: {:ok, result(event, nil)}
    end
  end

  # Plain native event: stays plain, or gains its first call record.
  defp do_save(scope, %EventDraft{event_id: event_id, meeting_id: nil} = draft, window) do
    if EventDraft.call_record?(draft) do
      transaction(fn ->
        with {:ok, event} <- Calendar.update_event(scope, event_id, event_attrs(draft, :call)),
             {:ok, meeting, undelivered} <- create_call(scope, draft, window),
             {:ok, event} <- link(event, meeting) do
          {:ok, %{result(event, meeting) | undelivered: undelivered}}
        end
      end)
    else
      with {:ok, event} <- Calendar.update_event(scope, event_id, event_attrs(draft, :native)),
           do: {:ok, result(event, nil)}
    end
  end

  # Native event with its call record.
  defp do_save(%Scope{actor: user} = scope, %EventDraft{event_id: event_id} = draft, window)
       when is_binary(event_id) do
    transaction(fn ->
      with {:ok, _event} <- Calendar.update_event(scope, event_id, event_attrs(draft, :call)),
           {:ok, edit} <- edit_call(draft, window, user) do
        {:ok, %{result(Repo.get(Event, event_id), edit.meeting) | failed: edit.failed}}
      end
    end)
  end

  # Legacy meeting (no native row of the viewer's). A native attribute gives
  # it a linked native row; anything else is a meeting edit and nothing more.
  defp do_save(%Scope{actor: user} = scope, %EventDraft{meeting_id: meeting_id} = draft, window) do
    cond do
      not EventDraft.native_attributes?(draft) ->
        with {:ok, edit} <- edit_call(draft, window, user),
             do: {:ok, %{result(nil, edit.meeting) | failed: edit.failed}}

      linked_event(meeting_id) ->
        {:error, :forbidden}

      true ->
        transaction(fn ->
          with {:ok, event} <-
                 Calendar.create_event(scope, %{event_attrs(draft, :call) | project_id: nil}),
               {:ok, event} <- link(event, %Meeting{id: meeting_id}),
               {:ok, edit} <- edit_call(draft, window, user) do
            {:ok, %{result(Repo.get(Event, event.id), edit.meeting) | failed: edit.failed}}
          end
        end)
    end
  end

  defp create_call(%Scope{actor: %User{id: user_id}}, draft, {starts_at, ends_at}) do
    Scheduling.create_with_invites(
      %{
        project_id: draft.project_id,
        created_by_user_id: user_id,
        name: draft.title,
        scheduled_start_at: starts_at,
        scheduled_end_at: ends_at,
        description: draft.notes,
        call_enabled: draft.call_enabled
      },
      Enum.flat_map(draft.add_invitees, &sheet_entry/1)
    )
  end

  defp edit_call(draft, window, user),
    do:
      Meetings.update_meeting_for_user(draft.meeting_id, meeting_edit_attrs(draft, window), user)

  defp link(%Event{} = event, %Meeting{id: meeting_id}) do
    event |> Event.meeting_link_changeset(meeting_id) |> Repo.update()
  end

  defp maybe_delete_event(_scope, nil), do: {:ok, nil}
  defp maybe_delete_event(scope, event_id), do: Calendar.delete_event(scope, event_id)

  # ── Mapping ──────────────────────────────────────────────────────────────

  # Notes live on the call record when there is one, else on the event.
  defp event_attrs(draft, store) do
    %{
      title: draft.title,
      description: if(store == :native, do: draft.notes),
      starts_at: draft.starts_at,
      ends_at: draft.ends_at,
      time_zone: draft.time_zone,
      all_day: draft.all_day,
      start_date: draft.start_date,
      end_date: draft.end_date,
      visibility: draft.visibility,
      recurrence: draft.recurrence,
      preset: draft.preset,
      space_id: draft.space_id,
      project_id: draft.project_id
    }
  end

  defp meeting_edit_attrs(draft, {starts_at, ends_at}) do
    %{
      name: draft.title,
      description: draft.notes,
      scheduled_start_at: starts_at,
      scheduled_end_at: ends_at,
      call_enabled: draft.call_enabled,
      add_invitees: draft.add_invitees,
      remove_invite_ids: draft.remove_invite_ids
    }
  end

  # The window the draft describes, normalized by the native event changeset
  # (time zone, all-day dates), so a meeting and its event get one window.
  defp window(draft) do
    changeset = Calendar.change_event(%Event{}, event_attrs(draft, :native))

    if changeset.valid? do
      event = Ecto.Changeset.apply_changes(changeset)
      {:ok, {event.starts_at, event.ends_at}}
    else
      {:error, changeset}
    end
  end

  defp apply_draft(scope, base, attrs) do
    base
    |> EventDraft.changeset(attrs, call_available?: call_available?(scope))
    |> Ecto.Changeset.apply_action(:save)
  end

  # The scheduling sheet's staged-entry shape (atom keys, atom kind).
  defp sheet_entry(entry) when is_map(entry) do
    get = fn key -> Map.get(entry, key) || Map.get(entry, Atom.to_string(key)) end

    case get.(:kind) do
      k when k in [:user, "user"] ->
        [%{kind: :user, user_id: get.(:user_id), display_name: get.(:display_name)}]

      k when k in [:guest, "guest"] ->
        [%{kind: :guest, display_name: get.(:display_name), email: get.(:email)}]

      k when k in [:external, "external"] ->
        [%{kind: :external, email: get.(:email), display_name: get.(:display_name)}]

      _ ->
        [entry]
    end
  end

  defp linked_meeting(%Event{meeting_id: nil}, _user), do: nil

  defp linked_meeting(%Event{meeting_id: meeting_id}, user) do
    case Meetings.get_meeting_for_user(user, meeting_id) do
      {:ok, meeting} -> meeting
      {:error, _} -> nil
    end
  end

  defp linked_event(meeting_id) do
    if Platform.UUID.valid?(meeting_id),
      do:
        Repo.one(from(e in Event, where: e.meeting_id == ^meeting_id and is_nil(e.cancelled_at)))
  end

  defp result(event, meeting), do: %{event: event, meeting: meeting, undelivered: [], failed: []}

  defp transaction(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
