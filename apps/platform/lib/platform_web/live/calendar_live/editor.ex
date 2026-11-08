defmodule PlatformWeb.CalendarLive.Editor do
  @moduledoc """
  Calendar's ONE event editor (task 01a1b8a5 stage 2): state and events for
  `PlatformWeb.CalendarLive.Components.event_editor/1`.

  Every way in loads the same form from a `Platform.Calendar.EventDraft`:
  New / `+ New event`, a slot click, a drag-selected range
  (`calendar_selection.js`), `?new=1`, Edit on a native event's details,
  Edit on a meeting's details and (stage 3) an agent's draft through
  `open_agent_draft/2`, which adds the agent's open questions and saves with
  `Authoring.save/4` so the draft is spent once. Every save, delete and preview goes through
  `Platform.Calendar.Authoring`, so a native event and its call record are
  never written apart, and nothing is written before Save.

  ## What this module does not decide

  Who may edit a call, who is emailed and whether removing someone is
  refused are `Platform.Meetings`' answers, reached through Authoring:
  `Authoring.load_draft/2` carries `Meetings.can_edit_meeting?/3`, the
  "When you save" summary is `Authoring.preview/3` (exactly
  `Meetings.preview_meeting_edit/2`), and the last-invitee refusal is that
  preview's `refusal`. Staged people use the same
  `PlatformWeb.MeetingLive.InviteeStaging` as the /meetings Edit meeting
  form. For a call-backed draft every editor event first re-checks the
  viewer against the call record (`authorized?/2`); a refusal closes the
  editor and writes nothing.

  ## The call checkbox

    * A new ordinary event starts with the call ON only when
      `Authoring.call_available?/1` (install switch plus `meetings.join`,
      server-side) and the viewer has a project to hold the call record.
    * An existing event shows its own call state; an explicit OFF stays OFF.
    * Focus time and Out of office disable the call and people. The
      checkbox's own value is kept while a preset is chosen, so switching
      back to Event restores what the viewer had; the SAVED draft has the
      call off and no people added.

  ## State (`:editor`, nil when shut)

  `base` (the draft the form was loaded from), `new?`, `original` and
  `params` (form params at load and now), `form`, `error`/`invalid`,
  `call_available?`, `preview` (call-backed edits only) and the
  `InviteeStaging` keys.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3]

  alias Platform.Calendar, as: Events
  alias Platform.Calendar.{Authoring, Draft, Event, EventDraft, Recurrence}
  alias Platform.Meetings
  alias PlatformWeb.MeetingLive.InviteeStaging
  alias PlatformWeb.TimeEntry

  @presets ~w(event focus ooo)

  @doc "The editor is shut."
  def seed(socket), do: assign(socket, :editor, nil)

  def open?(%{assigns: %{editor: %{}}}), do: true
  def open?(_socket), do: false

  @doc """
  A new draft on `date` from `start` to `finish` (local minutes in the
  viewer's zone). A slot inside a DST change takes the instant on either
  side of it, as the slot click always has.
  """
  def open_new(socket, %Date{} = date, start, finish)
      when is_integer(start) and is_integer(finish) do
    zone = socket.assigns.zone
    starts_at = local_at(date, start, zone)

    ends_at =
      if finish >= 1440,
        do: local_at(Date.add(date, 1), 0, zone),
        else: local_at(date, finish, zone)

    attrs = %{
      "starts_at" => starts_at,
      "ends_at" => ends_at,
      "time_zone" => zone,
      # No project, no call record: the call starts OFF rather than default
      # ON into a save that cannot succeed.
      "call_enabled" => projects(socket) != []
    }

    open_draft(socket, Authoring.new_draft(socket.assigns.access_scope, attrs))
  end

  @doc """
  Open the form on any draft (`Authoring.new_draft/2`, `load_draft/2`, or a
  stage-3 agent draft). Nothing is written.
  """
  def open_draft(socket, %EventDraft{} = draft) do
    scope = socket.assigns.access_scope

    staging =
      case draft.meeting_id && call_record(draft, socket) do
        {:ok, meeting} -> InviteeStaging.init(InviteeStaging.rows(meeting))
        _ -> InviteeStaging.init()
      end

    params = params(draft, socket)

    state =
      Map.merge(staging, %{
        base: draft,
        new?: is_nil(draft.event_id) and is_nil(draft.meeting_id),
        original: params,
        params: params,
        error: nil,
        invalid: [],
        preview: nil,
        call_available?: Authoring.call_available?(scope),
        agent: nil
      })

    state = Map.put(state, :deletable?, deletable?(state, socket.assigns.current_user_record))

    assign(socket, :editor, recompute(state, socket))
  end

  @doc """
  Edit an existing `{:event, id}` or `{:meeting, id}`. `{:error, socket}`
  (editor shut) when the viewer cannot load it, or may not edit its call.
  """
  def open_existing(socket, ref) do
    case Authoring.load_draft(socket.assigns.access_scope, ref) do
      {:ok, %EventDraft{editable: true} = draft} -> {:ok, open_draft(socket, draft)}
      _ -> {:error, seed(socket)}
    end
  end

  @doc """
  Open the form on a draft an agent left (`Platform.Calendar.Draft`, task
  01a1b8a5 stage 3): the same form as New event, prefilled with the
  draft's resolved fields and staged people, plus the agent's open
  questions. Nothing is written; Create event saves through
  `Authoring.save/4` with the draft, once.

  A time the agent could not resolve stays blank (the draft keeps its day),
  so the editor's own "Pick a date, start and end." asks for it. A Burrow
  call's project goes in the call's Project choice, not in Where, so the
  event stays private as a New event does.
  """
  def open_agent_draft(socket, %Draft{} = draft) do
    socket = open_draft(socket, Draft.event_draft(draft, socket.assigns.access_scope))
    state = socket.assigns.editor
    project_id = draft.attrs["project_id"]

    params =
      state.params
      |> then(fn params ->
        if params["date"] == "" and is_binary(Draft.local_date(draft)),
          do: Map.put(params, "date", Draft.local_date(draft)),
          else: params
      end)
      |> then(fn params ->
        if is_binary(project_id) and Enum.any?(projects(socket), &(&1.id == project_id)),
          do: Map.put(params, "call_project", project_id),
          else: params
      end)

    state = %{
      state
      | original: params,
        params: params,
        added: Enum.map(state.base.add_invitees, &staged_entry/1),
        agent: %{
          id: draft.id,
          name: Draft.agent_name(draft),
          clarifications: draft.clarifications,
          issues: draft.issues,
          resolved: []
        }
    }

    assign(socket, :editor, recompute(state, socket))
  end

  @doc """
  Answer one of the agent's attendee questions: `choice` is a candidate's
  user id (staged as that person) or `"skip"` (leave them out). Only a
  candidate the draft itself listed can be staged.
  """
  def resolve(socket, %{"id" => id, "choice" => choice}) do
    with_state(socket, fn
      %{agent: %{} = agent} = state ->
        question =
          Enum.find(
            agent.clarifications,
            &(&1["kind"] == "attendee" and &1["id"] == id and id not in agent.resolved)
          )

        candidate =
          question && Enum.find(question["candidates"] || [], &(&1["user_id"] == choice))

        cond do
          is_nil(question) ->
            {:noreply, socket}

          choice == "skip" ->
            {:noreply, put(socket, recompute(answered(state, id), socket))}

          candidate && people_enabled?(state) ->
            entry =
              staged_entry(%{
                "kind" => "user",
                "user_id" => candidate["user_id"],
                "email" => candidate["email"],
                "display_name" => candidate["name"]
              })

            added =
              if Enum.any?(state.added, &(&1.id == entry.id)),
                do: state.added,
                else: state.added ++ [entry]

            {:noreply, put(socket, recompute(%{answered(state, id) | added: added}, socket))}

          true ->
            {:noreply, socket}
        end

      _state ->
        {:noreply, socket}
    end)
  end

  def resolve(socket, _params), do: {:noreply, socket}

  defp answered(%{agent: agent} = state, id),
    do: %{state | agent: %{agent | resolved: agent.resolved ++ [id]}}

  @doc "The agent's attendee questions not answered yet (none for other drafts)."
  def unresolved(%{agent: %{clarifications: questions, resolved: resolved}}),
    do: Enum.filter(questions, &(&1["kind"] == "attendee" and &1["id"] not in resolved))

  def unresolved(_state), do: []

  defp staged_entry(entry) do
    get = fn key -> Map.get(entry, key) || Map.get(entry, String.to_existing_atom(key)) end

    case to_string(get.("kind")) do
      "user" ->
        %{
          id: "user:" <> get.("user_id"),
          kind: :user,
          user_id: get.("user_id"),
          email: get.("email"),
          display_name: get.("display_name") || get.("email"),
          subtitle: get.("display_name") && get.("email")
        }

      kind ->
        %{
          id: kind <> ":" <> get.("email"),
          kind: if(kind == "external", do: :external, else: :guest),
          user_id: nil,
          email: get.("email"),
          display_name: get.("display_name") || get.("email"),
          subtitle: if(kind == "external", do: "external member", else: "guest link")
        }
    end
  end

  @doc "The form changed: keep what was typed, refresh the summary."
  def change(socket, params) do
    with_state(socket, fn state ->
      params = Map.merge(state.params, Map.take(params, fields()))
      {:noreply, put(socket, recompute(%{state | params: params}, socket))}
    end)
  end

  @doc """
  The staged-people events (`meeting_edit_remove`, `_undo`, `_unstage`,
  `_add_people` and InviteControl's `meeting_edit_invite_*`).
  """
  def people(socket, event, params) do
    with_state(socket, fn state -> people_event(socket, state, event, params) end)
  end

  defp people_event(socket, state, "meeting_edit_remove", %{"id" => id}) do
    state = InviteeStaging.remove(state, id, &last_invitee?(state, socket, &1))
    {:noreply, put(socket, recompute(state, socket))}
  end

  defp people_event(socket, state, "meeting_edit_undo", %{"id" => id}),
    do: {:noreply, put(socket, recompute(InviteeStaging.undo(state, id), socket))}

  defp people_event(socket, state, "meeting_edit_unstage", %{"id" => id}),
    do: {:noreply, put(socket, recompute(InviteeStaging.unstage(state, id), socket))}

  defp people_event(socket, state, "meeting_edit_add_people", _params),
    do: {:noreply, put(socket, InviteeStaging.open(state))}

  defp people_event(socket, state, "meeting_edit_invite_search", %{"value" => query}),
    do: {:noreply, put(socket, InviteeStaging.search(state, query))}

  defp people_event(socket, state, "meeting_edit_invite_stage", %{"kind" => _} = params) do
    case people_enabled?(state) && InviteeStaging.stage(state, params) do
      {:ok, state} ->
        {:noreply, socket |> put(recompute(state, socket)) |> clear_search()}

      _ ->
        {:noreply, socket}
    end
  end

  defp people_event(socket, state, "meeting_edit_invite_commit", %{"value" => value}) do
    cond do
      not people_enabled?(state) or String.trim(to_string(value)) == "" ->
        {:noreply, socket}

      true ->
        case InviteeStaging.commit(state, value) do
          {:ok, state} ->
            {:reply, %{staged: true}, socket |> put(recompute(state, socket)) |> clear_search()}

          {:searched, state} ->
            {:noreply, put(socket, state)}
        end
    end
  end

  defp people_event(socket, _state, _event, _params), do: {:noreply, socket}

  @doc """
  Save. `{:saved, result, socket}` (editor shut) on success, where `result`
  is `Authoring.save/3`'s; otherwise `{:noreply, socket}` with the editor
  open, the input kept and the reason shown.
  """
  def save(socket, params) do
    with_state(socket, fn state ->
      state = %{state | params: Map.merge(state.params, Map.take(params, fields()))}

      case validate(state, socket) do
        {:error, message, invalid} ->
          {:noreply, put(socket, %{recompute(state, socket) | error: message, invalid: invalid})}

        {:ok, attrs} ->
          case save_through_authoring(socket, state, attrs) do
            {:ok, result} ->
              {:saved, result, seed(socket)}

            {:error, :unresolved} ->
              {:noreply,
               put(socket, %{
                 recompute(state, socket)
                 | error: "Answer the question above before saving.",
                   invalid: []
               })}

            {:error, :saved} ->
              {:noreply, socket |> seed() |> put_flash(:error, "This draft was already saved.")}

            {:error, :expired} ->
              {:noreply,
               socket
               |> seed()
               |> put_flash(
                 :error,
                 "This draft has expired. Ask again, or add the event yourself with + New."
               )}

            {:error, :last_invitee} ->
              {:noreply, put(socket, %{recompute(state, socket) | refused?: true})}

            {:error, %Ecto.Changeset{} = changeset} ->
              {message, invalid} = changeset_error(changeset)

              {:noreply,
               put(socket, %{recompute(state, socket) | error: message, invalid: invalid})}

            {:error, _refused} ->
              {:noreply, socket |> seed() |> put_flash(:error, "You can't edit this meeting.")}
          end
      end
    end)
  end

  # An agent draft saves with its id and the questions answered here, so
  # Authoring spends it in the same transaction; every other draft is the
  # plain `save/3`.
  defp save_through_authoring(socket, %{agent: %{id: id, resolved: resolved}} = state, attrs) do
    if unresolved(state) == [],
      do:
        Authoring.save(socket.assigns.access_scope, state.base, attrs,
          agent_draft: id,
          resolved: resolved
        ),
      else: {:error, :unresolved}
  end

  defp save_through_authoring(socket, state, attrs),
    do: Authoring.save(socket.assigns.access_scope, state.base, attrs)

  @doc """
  Delete the draft's event (Edit event footer). `{:deleted, socket}` or
  `{:error, socket}`; a call record is deleted only under Meetings'
  lifecycle rule, and a refusal leaves everything in place.
  """
  def delete(socket) do
    case socket.assigns[:editor] do
      %{new?: false, base: base} = state ->
        if authorized?(state, socket) do
          case Authoring.delete(socket.assigns.access_scope, base) do
            {:ok, _} -> {:deleted, seed(socket)}
            _ -> {:error, socket}
          end
        else
          {:error, seed(socket)}
        end

      _ ->
        {:error, socket}
    end
  end

  @doc "May the editor offer Delete? A plain native event yes; a call record per Meetings."
  def deletable?(%{new?: true}, _user), do: false
  def deletable?(%{base: %EventDraft{meeting_id: nil}}, _user), do: true

  def deletable?(%{base: %EventDraft{meeting_id: id}}, user) do
    case Meetings.get_meeting_for_user(user, id) do
      {:ok, meeting} -> Meetings.can_delete_meeting?(meeting, user)
      _ -> false
    end
  end

  # ── derived state ─────────────────────────────────────────────────────

  @doc "The selected preset (event, focus or ooo)."
  def preset(%{params: params}),
    do: if(params["preset"] in @presets, do: params["preset"], else: "event")

  @doc "People and the call are only for an ordinary Event."
  def people_enabled?(state), do: preset(state) == "event"

  @doc "The call checkbox as the viewer last left it (kept across a preset)."
  def call_checked?(%{params: params}), do: params["call_enabled"] in [true, "true"]

  @doc """
  Whether the call checkbox is drawn at all: always for a draft that has a
  call record or the call on, otherwise only when the viewer may add one.
  """
  def call_shown?(state),
    do: state.call_available? or is_binary(state.base.meeting_id) or call_checked?(state)

  @doc "Whether the call checkbox can be ticked (not a preset, a call holder exists)."
  def call_enabled?(state, projects),
    do: people_enabled?(state) and (is_binary(state.base.meeting_id) or projects != [])

  @doc "A new call record needs a project; this asks for one when `where` does not say."
  def project_needed?(state) do
    is_nil(state.base.meeting_id) and people_enabled?(state) and
      (call_checked?(state) or state.added != []) and where_project(state.params) == nil
  end

  @doc "The per-field 'was ...' markers of a call-backed edit (MeetingEdit's)."
  def changed(%{base: %EventDraft{meeting_id: id}, params: now, original: before})
      when is_binary(id) do
    for field <- ~w(title date start end description),
        trim(now[field]) != trim(before[field]),
        into: %{},
        do: {field, before[field]}
  end

  def changed(_state), do: %{}

  @doc "Existing rows still kept, and rows marked removed."
  def kept(state), do: Enum.reject(state.invitees, &(&1.id in state.removed_ids))
  def removed(state), do: Enum.filter(state.invitees, &(&1.id in state.removed_ids))

  # ── internals ────────────────────────────────────────────────────────

  defp with_state(socket, fun) do
    case socket.assigns[:editor] do
      %{} = state ->
        if authorized?(state, socket),
          do: fun.(state),
          else: {:noreply, socket |> seed() |> put_flash(:error, "You can't edit this meeting.")}

      _ ->
        {:noreply, socket}
    end
  end

  # A call-backed draft is re-checked against Meetings on EVERY event; a
  # plain native draft is checked by Calendar's own owner rule at save.
  defp authorized?(%{base: %EventDraft{meeting_id: nil}}, _socket), do: true

  defp authorized?(%{base: base}, socket) do
    user = socket.assigns.current_user_record

    case call_record(base, socket) do
      {:ok, meeting} -> Meetings.can_edit_meeting?(meeting, user)
      _ -> false
    end
  end

  defp call_record(%EventDraft{meeting_id: id}, socket),
    do: Meetings.get_meeting_for_user(socket.assigns.current_user_record, id)

  defp put(socket, state), do: assign(socket, :editor, state)

  defp clear_search(socket),
    do: push_event(socket, "invite-search:clear", %{id: "calendar-editor-people-search"})

  defp recompute(state, socket) do
    state
    |> Map.put(:form, to_form(state.params, as: :event))
    |> Map.put(:preview, preview(state, socket) || state.preview)
  end

  # Authoring's preview, i.e. Meetings' own; nil for a draft with no call
  # record yet (nobody to tell) and kept as it was while the form does not
  # parse.
  defp preview(%{base: %EventDraft{meeting_id: nil}}, _socket), do: nil

  defp preview(state, socket) do
    with {:ok, attrs} <- validate(state, socket),
         {:ok, preview} <- Authoring.preview(socket.assigns.access_scope, state.base, attrs) do
      preview
    else
      _ -> nil
    end
  end

  defp last_invitee?(state, socket, removed_ids) do
    case validate(%{state | removed_ids: removed_ids}, socket) do
      {:ok, attrs} ->
        match?(
          {:ok, %{refusal: :last_invitee}},
          Authoring.preview(socket.assigns.access_scope, state.base, attrs)
        )

      _ ->
        # The form does not parse yet: ask with the draft as loaded.
        match?(
          {:ok, %{refusal: :last_invitee}},
          Authoring.preview(socket.assigns.access_scope, state.base, %{
            "remove_invite_ids" => removed_ids,
            "add_invitees" => InviteeStaging.additions(state)
          })
        )
    end
  end

  # ── params <-> draft ─────────────────────────────────────────────────

  defp fields,
    do: ~w(title description time_zone all_day date start end end_date visibility repeat
         custom_frequency custom_interval custom_count custom_until where preset
         call_enabled call_project)

  # The form's params for a draft, in the draft's zone (a legacy meeting
  # has none of its own and reads in the viewer's).
  defp params(%EventDraft{} = draft, socket) do
    zone =
      if draft.source == "meeting" or draft.time_zone in [nil, ""],
        do: socket.assigns.zone,
        else: draft.time_zone

    rule =
      case Recurrence.parse(draft.recurrence) do
        {:ok, %{} = rule} -> rule
        _ -> %{frequency: "WEEKLY", interval: 1, count: nil, until: nil}
      end

    local = fn at -> at && DateTime.shift_zone!(at, zone) end
    starts = local.(draft.starts_at)
    ends = local.(draft.ends_at)

    %{
      "title" => draft.title || "",
      "description" => draft.notes || "",
      "time_zone" => zone,
      "all_day" => draft.all_day == true,
      "date" =>
        cond do
          draft.all_day && draft.start_date -> Date.to_iso8601(draft.start_date)
          starts -> starts |> DateTime.to_date() |> Date.to_iso8601()
          true -> ""
        end,
      # 12-hour text, so a re-saved event round-trips through
      # `TimeEntry.parse/1` unambiguously ("10:07 AM", never "10:07").
      "start" => if(starts, do: TimeEntry.format(DateTime.to_time(starts)), else: ""),
      "end" => if(ends, do: TimeEntry.format(DateTime.to_time(ends)), else: ""),
      "end_date" =>
        if(draft.all_day && draft.end_date,
          do: draft.end_date |> Date.add(-1) |> Date.to_iso8601(),
          else: ""
        ),
      "visibility" => draft.visibility || "details",
      "custom_frequency" => rule.frequency,
      "custom_interval" => rule.interval,
      "custom_count" => rule.count,
      "custom_until" => rule.until,
      "repeat" =>
        if(draft.recurrence in [nil, "", "FREQ=DAILY", "FREQ=WEEKLY", "FREQ=MONTHLY"],
          do: draft.recurrence || "",
          else: "custom"
        ),
      "where" =>
        cond do
          draft.space_id -> "space:" <> draft.space_id
          draft.project_id -> "project:" <> draft.project_id
          true -> "private"
        end,
      "preset" => draft.preset || "event",
      "call_enabled" => to_string(draft.call_enabled == true),
      "call_project" =>
        case projects(socket) do
          [%{id: id} | _] -> id
          [] -> ""
        end
    }
  end

  # Params -> the draft attrs Authoring saves, or the editor's message. The
  # v4 messages come first (title, a missing date/start/end, end after
  # start) from `Calendar.change_event/2`, after a typed Start/End that
  # does not parse, which is answered in its own words (task 01a192d6).
  defp validate(state, _socket) do
    params = state.params
    {native, time_errors} = parse_event(params)

    case time_errors do
      [{field, reason} | _] ->
        {:error, TimeEntry.message(field, reason), Keyword.keys(time_errors)}

      [] ->
        case editor_errors(Events.change_event(%Event{}, native)) do
          {message, fields} -> {:error, message, fields}
          nil -> {:ok, draft_attrs(state, native)}
        end
    end
  end

  defp draft_attrs(state, native) do
    preset = preset(state)
    ordinary? = preset == "event"

    project_id =
      cond do
        native["project_id"] -> native["project_id"]
        project_needed?(state) -> blank_nil(state.params["call_project"])
        true -> nil
      end

    %{
      "title" => native["title"],
      "notes" => native["description"],
      "time_zone" => native["time_zone"],
      "all_day" => native["all_day"],
      "starts_at" => native["starts_at"],
      "ends_at" => native["ends_at"],
      "start_date" => native["start_date"],
      "end_date" => native["end_date"],
      "recurrence" => native["recurrence"],
      "visibility" => native["visibility"],
      "preset" => preset,
      "space_id" => native["space_id"],
      "project_id" => project_id || state.base.project_id,
      "call_enabled" => ordinary? and call_checked?(state),
      "add_invitees" => if(ordinary?, do: InviteeStaging.additions(state), else: []),
      "remove_invite_ids" => state.removed_ids
    }
  end

  defp where_project(params) do
    case String.split(params["where"] || "private", ":", parts: 2) do
      ["project", id] -> id
      _ -> nil
    end
  end

  @doc false
  # The v4 editor submits a Date plus Start/End times in the event's zone;
  # an all-day event submits its first and last day (PR #51 stores an
  # exclusive end date). Returns `{attrs, time_errors}`.
  def parse_event(params) do
    zone = params["time_zone"] || "Etc/UTC"
    all_day? = params["all_day"] in [true, "true"]
    date = blank_nil(params["date"])

    attrs = %{
      "title" => params["title"],
      "description" => params["description"],
      "time_zone" => zone,
      "visibility" => params["visibility"],
      "all_day" => all_day?,
      "recurrence" =>
        blank_nil(
          if(params["repeat"] == "custom", do: custom_rule(params), else: params["repeat"])
        ),
      "space_id" => nil,
      "project_id" => nil
    }

    {attrs, time_errors} =
      if all_day? do
        last = blank_nil(params["end_date"]) || date

        {Map.merge(attrs, %{
           "start_date" => date,
           "end_date" =>
             case Date.from_iso8601(last || "") do
               {:ok, day} -> Date.add(day, 1)
               _ -> nil
             end
         }), []}
      else
        # A blank field stays nil, so the changeset's "Pick a date, start and
        # end." still answers it; a typed one that does not parse is an
        # error of its own.
        at = fn time ->
          case TimeEntry.parse(time) do
            {:ok, %Time{} = parsed} -> {:ok, date && local_instant(date, parsed, zone)}
            {:error, :blank} -> {:ok, nil}
            {:error, reason} -> {:error, reason}
          end
        end

        {starts_at, start_error} = time_result(at.(params["start"]), :start)
        {ends_at, end_error} = time_result(at.(params["end"]), :end)

        {Map.merge(attrs, %{
           "starts_at" => starts_at,
           "ends_at" => ends_at,
           "start_date" => nil,
           "end_date" => nil
         }), Enum.reject([start_error, end_error], &is_nil/1)}
      end

    attrs =
      case String.split(params["where"] || "private", ":", parts: 2) do
        ["space", id] -> Map.put(attrs, "space_id", id)
        ["project", id] -> Map.put(attrs, "project_id", id)
        _ -> attrs
      end

    {attrs, time_errors}
  end

  defp time_result({:ok, at}, _field), do: {at, nil}
  defp time_result({:error, reason}, field), do: {nil, {field, reason}}

  # Date + wall-clock time in `zone`, as UTC. A time inside a DST change
  # has no single instant, so it is nil (the changeset then refuses it).
  defp local_instant(date, %Time{} = time, zone) do
    with {:ok, day} <- Date.from_iso8601(date),
         {:ok, at} <- DateTime.new(day, time, zone) do
      DateTime.shift_zone!(at, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp local_at(date, minute, zone) do
    case DateTime.new(date, Time.new!(div(minute, 60), rem(minute, 60), 0), zone) do
      {:ok, at} -> at
      {:ambiguous, first, _} -> first
      {:gap, _, after_gap} -> after_gap
    end
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp custom_rule(params) do
    base = "FREQ=#{params["custom_frequency"]};INTERVAL=#{params["custom_interval"]}"

    base =
      if params["custom_count"] not in [nil, ""],
        do: base <> ";COUNT=#{params["custom_count"]}",
        else: base

    if params["custom_until"] not in [nil, ""],
      do: base <> ";UNTIL=" <> String.replace(params["custom_until"], "-", ""),
      else: base
  end

  @doc false
  # app.js `#f-save` order: title, then a missing date/start/end, then end
  # not after start. Returns `{message, invalid_fields}` or nil.
  def editor_errors(%Ecto.Changeset{} = changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {message, _} -> message end)
    blank? = fn field -> "can't be blank" in Map.get(errors, field, []) end

    cond do
      errors == %{} ->
        nil

      Map.has_key?(errors, :title) ->
        {"Give the event a title.", [:title]}

      Enum.any?(~w(starts_at ends_at start_date end_date)a, blank?) ->
        fields =
          [date: [:starts_at, :start_date], start: [:starts_at], end: [:ends_at, :end_date]]
          |> Enum.filter(fn {_, keys} -> Enum.any?(keys, blank?) end)
          |> Enum.map(&elem(&1, 0))

        {"Pick a date, start and end.", fields}

      Map.has_key?(errors, :ends_at) or Map.has_key?(errors, :end_date) ->
        {"End has to be after the start.", [:end]}

      true ->
        {Enum.map_join(errors, ". ", fn {field, messages} ->
           "#{Phoenix.Naming.humanize(field)} #{Enum.join(messages, ", ")}"
         end), []}
    end
  end

  # The draft's own refusals (EventDraft), in the editor's words.
  defp changeset_error(%Ecto.Changeset{data: %EventDraft{}, errors: errors}) do
    cond do
      Keyword.has_key?(errors, :recurrence) ->
        {"A repeating event can’t have people or a Burrow call.", [:repeat]}

      Keyword.has_key?(errors, :project_id) ->
        {"Pick a project for the call.", [:call_project]}

      Keyword.has_key?(errors, :call_enabled) ->
        {"You can’t add a Burrow call to this event.", [:call_enabled]}

      Keyword.has_key?(errors, :add_invitees) ->
        {"Focus time and Out of office can’t have people.", []}

      true ->
        {Enum.map_join(errors, ". ", fn {field, {message, _}} ->
           "#{Phoenix.Naming.humanize(field)} #{message}"
         end), []}
    end
  end

  defp changeset_error(%Ecto.Changeset{} = changeset),
    do: editor_errors(changeset) || {"You cannot save this event.", []}

  defp projects(socket), do: socket.assigns[:projects] || []

  defp blank_nil(value) when value in [nil, ""], do: nil
  defp blank_nil(value), do: value

  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
