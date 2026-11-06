defmodule PlatformWeb.MeetingLive.MeetingEdit do
  @moduledoc """
  The Edit meeting form's state and events (task 01a1b281 stage 3), shared
  by `PlatformWeb.MeetingLive` (the /meetings detail) and
  `PlatformWeb.CalendarLive` (the calendar details panel), which render the
  same `PlatformWeb.Components.Meetings.EditMeeting.edit_meeting/1`.

  ## Where the meeting comes from

  The caller opens the form with the id of its own SELECTION (a row the
  viewer-scoped list drew), never a payload value. That id is kept in the
  `:meeting_edit` assign, and EVERY later event reloads the row through
  `Meetings.get_meeting_for_user/2` and re-checks
  `Meetings.can_edit_meeting?/2` before it does anything. Saving goes
  through `Meetings.update_meeting_for_user/3`, which loads through the
  viewer scope and checks the same rule a third time. No event reads a
  meeting id from its params, so a forged `meeting_edit_save` from someone
  who may not edit has nothing to point at and changes nothing.

  ## The summary is the context's answer

  The "When you save" summary is `Meetings.preview_meeting_edit/2`, called
  with exactly the attrs Save would send. This module never decides who is
  emailed; it only builds the attrs. The per-field "was ..." markers are a
  comparison of the form against its own prefill, which is a fact about
  the form, not about mail.

  ## State

  `:meeting_edit` is nil when the form is shut, otherwise a map with the
  meeting id and slug, the viewer's zone, the prefill (`original`), the
  current params and `form`, the invitee rows, removed invite ids, staged
  additions, the add-people search, the last-invitee refusal flag, the
  preview, and an inline error.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3]

  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias PlatformWeb.MeetingLive
  alias PlatformWeb.TimeEntry

  @fields ~w(name date start_time duration_minutes description)

  @pair_error "Pick both a date and a start time, or clear both."
  @date_error "That date is incomplete."
  @time_error "That time doesn't exist in your time zone."

  @doc "Shut form."
  def seed(socket), do: assign(socket, :meeting_edit, nil)

  @doc """
  Open the form on `meeting_id`, the caller's own selection. Refuses
  silently (the form stays shut) unless the viewer may edit it.
  """
  def open(socket, meeting_id, viewer, time_zone) when is_binary(time_zone) do
    with id when is_binary(id) <- meeting_id,
         {:ok, meeting} <- editable(id, viewer) do
      original = prefill(meeting, time_zone)

      state = %{
        meeting_id: meeting.id,
        slug: meeting.slug,
        time_zone: time_zone,
        original: original,
        params: original,
        invitees: invitee_rows(meeting),
        removed_ids: [],
        added: [],
        adding?: false,
        query: "",
        candidates: [],
        email: nil,
        refused?: false,
        error: nil,
        saving?: false
      }

      assign(socket, :meeting_edit, recompute(state, meeting))
    else
      _ -> seed(socket)
    end
  end

  def open(socket, _meeting_id, _viewer, _time_zone), do: seed(socket)

  @doc """
  Handle one `meeting_edit_*` event. Returns `{:noreply, socket}`,
  `{:reply, map, socket}`, or `{:saved, meeting, socket}` after a
  successful save so the caller can refresh its lists.
  """
  def handle(socket, "meeting_edit_close", _params, _viewer), do: {:noreply, seed(socket)}

  def handle(socket, event, params, viewer) do
    case socket.assigns[:meeting_edit] do
      %{meeting_id: id} = state ->
        case editable(id, viewer) do
          {:ok, meeting} ->
            dispatch(socket, state, meeting, event, params, viewer)

          _refused ->
            {:noreply, socket |> seed() |> put_flash(:error, "You can't edit this meeting.")}
        end

      _shut ->
        {:noreply, socket}
    end
  end

  defp dispatch(socket, state, meeting, "meeting_edit_change", %{"meeting_edit" => params}, _v) do
    params = Map.merge(state.params, Map.take(params, @fields ++ ["date_incomplete"]))
    put(socket, recompute(%{state | params: params, refused?: false}, meeting))
  end

  defp dispatch(socket, state, meeting, "meeting_edit_remove", %{"id" => id}, _viewer) do
    known? = Enum.any?(state.invitees, &(&1.id == id)) and id not in state.removed_ids

    cond do
      not known? ->
        {:noreply, socket}

      # The context's own verdict decides the refusal: remove it in a
      # trial preview and ask whether that edit would be refused.
      trial_refused?(state, meeting, id) ->
        put(socket, recompute(%{state | refused?: true}, meeting))

      true ->
        put(
          socket,
          recompute(%{state | removed_ids: state.removed_ids ++ [id], refused?: false}, meeting)
        )
    end
  end

  defp dispatch(socket, state, meeting, "meeting_edit_undo", %{"id" => id}, _viewer) do
    put(socket, recompute(%{state | removed_ids: List.delete(state.removed_ids, id)}, meeting))
  end

  defp dispatch(socket, state, meeting, "meeting_edit_unstage", %{"id" => id}, _viewer) do
    added = Enum.reject(state.added, &(&1.id == id))
    put(socket, recompute(%{state | added: added, refused?: false}, meeting))
  end

  defp dispatch(socket, state, _meeting, "meeting_edit_add_people", _params, _viewer) do
    put(socket, %{state | adding?: true})
  end

  defp dispatch(socket, state, _meeting, "meeting_edit_invite_search", %{"value" => q}, _v) do
    put(socket, search(state, to_string(q)))
  end

  defp dispatch(socket, state, meeting, "meeting_edit_invite_stage", %{"kind" => _} = params, _v) do
    case stage_entry(state, params) do
      nil ->
        {:noreply, socket}

      entry ->
        added =
          if Enum.any?(state.added, &(&1.id == entry.id)),
            do: state.added,
            else: state.added ++ [entry]

        state = %{state | added: added, query: "", candidates: [], email: nil, refused?: false}

        {:noreply,
         socket
         |> assign(:meeting_edit, recompute(state, meeting))
         |> push_event("invite-search:clear", %{id: "meeting-edit-invite-search"})}
    end
  end

  defp dispatch(socket, state, meeting, "meeting_edit_invite_commit", %{"value" => value}, viewer) do
    value = to_string(value)

    if String.trim(value) == "" do
      {:noreply, socket}
    else
      state = search(state, value)

      case PlatformWeb.MeetingLive.LiveInvites.commit_params(state.candidates, state.email, value) do
        nil ->
          put(socket, state)

        params ->
          socket = assign(socket, :meeting_edit, state)

          {:noreply, socket} =
            dispatch(socket, state, meeting, "meeting_edit_invite_stage", params, viewer)

          {:reply, %{staged: true}, socket}
      end
    end
  end

  defp dispatch(socket, state, meeting, "meeting_edit_save", params, viewer) do
    state =
      case params do
        %{"meeting_edit" => form} ->
          recompute(%{state | params: Map.merge(state.params, Map.take(form, @fields))}, meeting)

        _ ->
          state
      end

    cond do
      state.error != nil or state.preview.changed == [] ->
        put(socket, state)

      true ->
        save(socket, state, viewer)
    end
  end

  defp dispatch(socket, _state, _meeting, _event, _params, _viewer), do: {:noreply, socket}

  defp save(socket, state, viewer) do
    case Meetings.update_meeting_for_user(state.meeting_id, attrs(state), viewer) do
      {:ok, %{meeting: meeting, failed: []}} ->
        {:saved, meeting, seed(socket)}

      {:ok, %{meeting: meeting, failed: failed}} ->
        {:saved, meeting,
         socket
         |> seed()
         |> put_flash(:error, "Saved, but #{length(failed)} invite(s) could not be added.")}

      {:error, :last_invitee} ->
        put(socket, %{state | refused?: true})

      {:error, %Ecto.Changeset{} = changeset} ->
        put(socket, %{state | error: changeset_error(changeset)})

      {:error, _refused} ->
        {:noreply, socket |> seed() |> put_flash(:error, "You can't edit this meeting.")}
    end
  end

  defp put(socket, state), do: {:noreply, assign(socket, :meeting_edit, state)}

  # The viewer-scoped reload every event goes through.
  defp editable(id, viewer) do
    with {:ok, %Meeting{} = meeting} <- Meetings.get_meeting_for_user(viewer, id),
         true <- Meetings.can_edit_meeting?(meeting, viewer) do
      {:ok, meeting}
    else
      _ -> {:error, :forbidden}
    end
  end

  # ── prefill and attrs ──────────────────────────────────────────────────

  @doc false
  def prefill(%Meeting{} = meeting, time_zone) do
    base = %{
      "name" => meeting.name || "",
      "description" => meeting.description || "",
      "date_incomplete" => ""
    }

    case meeting do
      %Meeting{
        scheduled_start_at: %DateTime{} = starts_at,
        scheduled_end_at: %DateTime{} = ends_at
      } ->
        local = DateTime.shift_zone!(starts_at, time_zone)

        Map.merge(base, %{
          "date" => local |> DateTime.to_date() |> Date.to_iso8601(),
          "start_time" => local |> DateTime.to_time() |> TimeEntry.format(),
          "duration_minutes" => Integer.to_string(div(DateTime.diff(ends_at, starts_at), 60))
        })

      _unscheduled ->
        Map.merge(base, %{"date" => "", "start_time" => "", "duration_minutes" => "30"})
    end
  end

  @doc """
  The duration choices for this form: the create sheet's, plus the
  meeting's own length when it is not one of them, so a 50-minute meeting
  is not silently re-timed by opening and saving the form.
  """
  def duration_options(%{original: %{"duration_minutes" => raw}}) do
    options = MeetingLive.duration_options()

    case Integer.parse(raw || "") do
      {minutes, ""} when minutes > 0 -> Enum.sort(Enum.uniq(options ++ [minutes]))
      _ -> options
    end
  end

  @doc "Which form fields differ from the prefill (the muted 'was ...' markers)."
  def changed_fields(%{params: params, original: original}) do
    %{
      name: trim(params["name"]) != trim(original["name"]),
      date: trim(params["date"]) != trim(original["date"]),
      start_time: start_changed?(params["start_time"], original["start_time"]),
      duration_minutes: trim(params["duration_minutes"]) != trim(original["duration_minutes"]),
      description: trim(params["description"]) != trim(original["description"])
    }
  end

  defp start_changed?(now, before) do
    case {TimeEntry.parse(trim(now)), TimeEntry.parse(trim(before))} do
      {{:ok, a}, {:ok, b}} -> Time.compare(a, b) != :eq
      _ -> trim(now) != trim(before)
    end
  end

  # Only what changed, so an untouched field is "unchanged", never "cleared".
  defp attrs(state) do
    changed = changed_fields(state)

    %{}
    |> put_if(changed.name, :name, trim(state.params["name"]))
    |> put_if(changed.description, :description, blank_to_nil(trim(state.params["description"])))
    |> Map.merge(time_attrs(state, changed))
    |> Map.put(:remove_invite_ids, state.removed_ids)
    |> Map.put(
      :add_invitees,
      Enum.map(state.added, &Map.take(&1, [:kind, :user_id, :email, :display_name]))
    )
  end

  defp time_attrs(state, changed) do
    if changed.date or changed.start_time or changed.duration_minutes do
      case window(state) do
        {:ok, nil, nil} -> %{}
        {:ok, starts_at, ends_at} -> %{scheduled_start_at: starts_at, scheduled_end_at: ends_at}
        {:error, _message} -> %{}
      end
    else
      %{}
    end
  end

  defp window(%{params: params, time_zone: zone} = state) do
    date = trim(params["date"])
    start = trim(params["start_time"])

    cond do
      params["date_incomplete"] == "true" ->
        {:error, @date_error}

      true ->
        with {:ok, time} <- parse_start(start) do
          case {date, time} do
            {"", nil} -> {:ok, nil, nil}
            {"", _} -> {:error, @pair_error}
            {_, nil} -> {:error, @pair_error}
            {date, time} -> local_window(date, time, minutes(state), zone)
          end
        end
    end
  end

  defp parse_start(""), do: {:ok, nil}

  defp parse_start(text) do
    case TimeEntry.parse(text) do
      {:ok, time} -> {:ok, time}
      {:error, :blank} -> {:ok, nil}
      {:error, reason} -> {:error, TimeEntry.message(:start, reason)}
    end
  end

  defp minutes(state) do
    case Integer.parse(trim(state.params["duration_minutes"])) do
      {minutes, ""} -> if minutes in duration_options(state), do: {:ok, minutes}, else: :error
      _ -> :error
    end
  end

  defp local_window(_date, _time, :error, _zone), do: {:error, "Pick a duration from the list."}

  defp local_window(date, time, {:ok, minutes}, zone) do
    with {:ok, date} <- Date.from_iso8601(date),
         {:ok, local} <- local_datetime(date, time, zone) do
      starts_at = DateTime.shift_zone!(local, "Etc/UTC")
      {:ok, starts_at, DateTime.add(starts_at, minutes * 60, :second)}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, @date_error}
    end
  end

  defp local_datetime(date, time, zone) do
    case DateTime.new(date, time, zone) do
      {:ok, at} -> {:ok, at}
      {:ambiguous, first, _second} -> {:ok, first}
      {:gap, _before, _after} -> {:error, @time_error}
      {:error, _} -> {:error, @date_error}
    end
  end

  # ── preview ────────────────────────────────────────────────────────────

  defp recompute(state, %Meeting{} = meeting) do
    error =
      case window(state) do
        {:error, message} -> message
        _ -> if trim(state.params["name"]) == "", do: "Name is required."
      end

    preview = Meetings.preview_meeting_edit(meeting, attrs(state))

    state
    |> Map.put(:error, error)
    |> Map.put(:preview, preview)
    |> Map.put(:changed, changed_fields(state))
    |> Map.put(:form, to_form(state.params, as: :meeting_edit))
  end

  defp trial_refused?(state, meeting, id) do
    trial = %{state | removed_ids: state.removed_ids ++ [id]}
    Meetings.preview_meeting_edit(meeting, attrs(trial)).refusal == :last_invitee
  end

  # ── invitees ───────────────────────────────────────────────────────────

  defp invitee_rows(meeting),
    do: meeting |> MeetingLive.detail_invite_rows() |> Enum.reject(& &1.agent)

  defp search(state, query) do
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

  # A user must be one of the candidates the search offered; an address or
  # a guest name is whatever was typed. Anything else stages nothing.
  defp stage_entry(state, %{"kind" => "user", "id" => user_id}) do
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

  defp stage_entry(_state, %{"kind" => kind, "email" => email})
       when kind in ["guest", "external"] do
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

  defp stage_entry(_state, %{"kind" => "guest", "name" => name}) do
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

  defp stage_entry(_state, _params), do: nil

  # ── helpers ────────────────────────────────────────────────────────────

  defp changeset_error(%Ecto.Changeset{errors: errors}) do
    case errors do
      [{:name, _} | _] ->
        "Name is required."

      [{field, {message, _}} | _] when field in [:scheduled_start_at, :scheduled_end_at] ->
        "The time " <> message <> "."

      _ ->
        "That didn't save. Try again."
    end
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
