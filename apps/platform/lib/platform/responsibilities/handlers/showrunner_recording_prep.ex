defmodule Platform.Responsibilities.Handlers.ShowrunnerRecordingPrep do
  @moduledoc """
  `showrunner.recording_prep`: logistics and recording day for How to
  Computer (task 01a1eaf6 stage 4). One key in the `showrunner` bundle.

  Server-side: `gather_context/2` does the whole job and returns
  `{:handled, summary}`, so the Router dispatches nothing. Calendar and
  Meetings are core and are called directly; nothing here reads Social.

  ## Trigger

  A daily Router cron, default `0 15 * * *` UTC (operator-settable through
  `Platform.Showrunner.Config`, kept across boots by `"operator_set"`). Each
  fire does what is due for the newest episode board and nothing else, so a
  second fire on the same day is a no-op.

  ## What is due

    1. **Run sheet -> Logistics.** A board at Run sheet with a run sheet and
       no open decision moves to Logistics.
    2. **The slot.** The default slot is the next `record_weekday` at
       `record_time` in `record_time_zone`. The hosts' calendars
       (`host_user_ids`, else the escalate user) are read through
       `Platform.Calendar.AgentAccess.read/4` with the agent's runtime scope,
       ignoring the showrunner's own holds. On a clash the recording moves
       to the next free 30-minute step within `window_hours`; the chosen
       slot is proposed on every host calendar with
       `Platform.Calendar.AgentAccess.propose/6` (the `calendar_propose`
       context) and becomes the episode's `records_at`. ONLY when no step is
       free is a person asked: one Needs-you item and one inbox row. Every
       fire re-checks the slot, so a calendar that fills up later is caught.
    3. **The room.** One meeting through `Platform.Meetings.create_meeting/1`
       (the `meeting_create` context) in the configured project, recorded on
       the board as `room_status: "room ready"`. Never a second room.
    4. **The day before:** the pre-show checklist (mic, room, links) is
       posted in the show's space, once.
    5. **Recording day:** the showrunner agent joins the meeting's space and
       posts the run sheet there (template `showrunner.recording_prep.v1`),
       which seeds the existing meeting voice agent's context so the
       showrunner cohosts through `meeting_say`. The rail moves to Record.

  Bookkeeping lives in the board document under `meta["showrunner_logistics"]`
  (`meeting_id`, `hold_ids`, `slot`, `checklist_posted_at`, `attached_at`).

  ## Seams

  `run/3` takes `opts`: `:now` (a `DateTime`, else `trigger_meta[:fired_at]`,
  else now) and `:busy`, a `fn owner_ids, from, to -> {:ok, [{starts, ends}]}
  | {:error, reason} end` standing in for the calendar read. Both are
  arguments, never application config.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Access.Scope
  alias Platform.Agents.Agent
  alias Platform.Calendar.AgentAccess
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Responsibilities.Responsibility
  alias Platform.Showrunner.Board
  alias Platform.Showrunner.Episode
  alias Platform.Showrunner.Memory
  alias Platform.Showrunner.Runtime

  @key "showrunner.recording_prep"
  @feature "showrunner"
  @template_slug "showrunner.recording_prep.v1"
  @cron_expression "0 15 * * *"
  @meta_key "showrunner_logistics"
  @step_minutes 30
  @room_ready "room ready"

  @slot_item %{
    id: "recording-time",
    question: "No free recording slot this week. When should we record?",
    options: ["Pick a time by hand", "Skip this week"]
  }

  @calendar_item %{
    id: "calendar-access",
    question: "The showrunner can't read or book the hosts' calendars: grant it Calendar access",
    options: ["Granted"]
  }

  @project_item %{
    id: "show-project",
    question: "The showrunner has no project to hold the recording room: set one",
    options: ["Set"]
  }

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "The Needs-you item raised when no slot in the window is free."
  @spec slot_item() :: map()
  def slot_item, do: @slot_item

  @doc "The board meta key logistics bookkeeping lives under."
  @spec meta_key() :: String.t()
  def meta_key, do: @meta_key

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "cron",
        trigger_config: %{"expression" => @cron_expression},
        scope: "per_space",
        context_provided: ["run_sheet", "host_calendars"],
        output_contract: %{},
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.showrunner",
          "status" => "active",
          "role" => "showrunner",
          "task" => "01a1eaf6",
          "server_side" => true
        }
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{} = responsibility, trigger_meta),
    do: run(responsibility, trigger_meta, [])

  @doc """
  One fire: does what is due (see the moduledoc) and returns
  `{:handled, summary}`, or `{:error, reason}` when the row is not configured
  (no space, nobody in the role, the agent not in the space). Never raises.
  """
  @spec run(Responsibility.t(), map() | nil, keyword()) :: {:handled, map()} | {:error, term()}
  def run(%Responsibility{} = responsibility, trigger_meta, opts) do
    now = now(trigger_meta, opts)

    with {:ok, ctx, config} <- Runtime.context(responsibility) do
      case Runtime.board(ctx.space_id, trigger_meta) do
        %Canvas{} = canvas -> {:handled, prep(ctx, config, canvas, now, opts)}
        nil -> {:handled, %{skipped: :no_board}}
      end
    end
  rescue
    error ->
      Logger.warning("[showrunner.recording_prep] raised: #{Exception.message(error)}")
      {:handled, %{error: :raised}}
  end

  @doc """
  The recording-day seed as a prompt. The Router never calls this
  (`gather_context/2` always handles the fire server-side); it exists so the
  key has a real builder rather than falling back to a template render.
  """
  @impl true
  def build_prompt(context) when is_map(context) do
    assigns =
      Map.new(
        ~w(episode_number title records_at host_roles run_sheet)a,
        &{&1, to_string(Map.get(context, &1, ""))}
      )

    case Runtime.render(@template_slug, @template_slug, assigns) do
      {:ok, user} -> {:ok, %{system: "You are the showrunner for How to Computer.", user: user}}
      {:error, _} -> {:error, :template_missing}
    end
  end

  @impl true
  def handle_output(_responsibility, _output), do: :ok

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta), do: :ok

  @impl true
  def handle_refusal(%Responsibility{} = responsibility, refusal, _trigger_meta),
    do: Runtime.refused(responsibility, refusal)

  # ── slot arithmetic (public for tests) ──

  @doc """
  The default slot after `now`: the next `recording.weekday` at
  `recording.time` in `recording.time_zone`, as a UTC `DateTime`.
  """
  @spec default_slot(map(), DateTime.t()) :: DateTime.t()
  def default_slot(recording, %DateTime{} = now) do
    tz = recording.time_zone
    local_today = now |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    ahead = Integer.mod(recording.weekday - Date.day_of_week(local_today), 7)
    time = Time.from_iso8601!(recording.time <> ":00")
    slot = at(Date.add(local_today, ahead), time, tz)

    if DateTime.compare(slot, now) == :gt,
      do: slot,
      else: at(Date.add(local_today, ahead + 7), time, tz)
  end

  @doc "Every candidate start in the window, default slot first, 30 minutes apart."
  @spec candidates(map(), DateTime.t()) :: [DateTime.t()]
  def candidates(recording, %DateTime{} = now) do
    first = default_slot(recording, now)
    steps = div(recording.window_hours * 60, @step_minutes)
    for k <- 0..steps, do: DateTime.add(first, k * @step_minutes * 60, :second)
  end

  @doc "The first candidate whose `minutes` overlap no busy interval, or nil."
  @spec first_free([DateTime.t()], pos_integer(), [{DateTime.t(), DateTime.t()}]) ::
          DateTime.t() | nil
  def first_free(candidates, minutes, busy) do
    Enum.find(candidates, &free?(&1, minutes, busy))
  end

  @doc "True when `[start, start + minutes)` overlaps no busy interval."
  @spec free?(DateTime.t(), pos_integer(), [{DateTime.t(), DateTime.t()}]) :: boolean()
  def free?(start, minutes, busy) do
    stop = DateTime.add(start, minutes * 60, :second)

    not Enum.any?(busy, fn {b_start, b_end} ->
      DateTime.compare(b_start, stop) == :lt and DateTime.compare(b_end, start) == :gt
    end)
  end

  # ── the fire ──

  defp prep(ctx, config, canvas, now, opts) do
    case Board.read(canvas) do
      {:ok, episode, document} ->
        prep_episode(ctx, config, canvas, document, episode, now, opts)

      {:error, reason} ->
        Board.unreadable(ctx, canvas, reason)
        %{board: :unreadable}
    end
  end

  defp prep_episode(
         ctx,
         config,
         canvas,
         document,
         %Episode{stage: :run_sheet} = episode,
         now,
         opts
       ) do
    with [_ | _] <- episode.run_sheet,
         {:ok, advanced} <- Episode.advance(episode, :logistics),
         {:ok, canvas} <- Board.write(ctx, canvas, document, advanced),
         {:ok, episode, document} <- Board.read(canvas) do
      prep_episode(ctx, config, canvas, document, episode, now, opts)
    else
      _ -> %{skipped: {:not_due, :run_sheet}}
    end
  end

  defp prep_episode(
         ctx,
         config,
         canvas,
         document,
         %Episode{stage: :logistics} = episode,
         now,
         opts
       ) do
    logistics = Board.meta(document, @meta_key)

    with {:ok, episode, document} <- schedule(ctx, config, canvas, document, episode, now, opts),
         {:ok, episode, document} <- room(ctx, config, canvas, document, episode),
         {:ok, document} <- checklist(ctx, config, document, episode, now),
         {:ok, episode, document} <- recording_day(ctx, config, document, episode, now),
         {:ok, _canvas} <- Board.write(ctx, canvas, document, episode) do
      after_logistics = Board.meta(document, @meta_key)

      %{
        stage: episode.stage,
        records_at: episode.records_at,
        room_status: episode.room_status,
        meeting_id: after_logistics["meeting_id"],
        proposed: after_logistics["slot"] != logistics["slot"],
        checklist_posted:
          is_nil(logistics["checklist_posted_at"]) and
            not is_nil(after_logistics["checklist_posted_at"]),
        attached: is_nil(logistics["attached_at"]) and not is_nil(after_logistics["attached_at"])
      }
    else
      {:parked, item_id} -> %{parked: item_id}
      {:error, reason} -> %{error: reason}
    end
  end

  defp prep_episode(_ctx, _config, _canvas, _document, %Episode{stage: stage}, _now, _opts),
    do: %{skipped: {:not_due, stage}}

  # The slot: keep it while it stays free, else move to the next free step,
  # else ask a person (once).
  defp schedule(ctx, config, canvas, document, episode, now, opts) do
    logistics = Board.meta(document, @meta_key)
    recording = config.recording
    owners = owners(config)
    candidates = candidates(recording, now)
    from = List.first(candidates)
    to = DateTime.add(List.last(candidates), recording.minutes * 60, :second)

    # The episode's own calendar holds and its own meeting room are not
    # clashes: counting them made a second fire move the slot away from the
    # room it had already booked (task 01a1eaf6 stage 4 review).
    own = Enum.reject((logistics["hold_ids"] || []) ++ [logistics["meeting_id"]], &is_nil/1)

    case busy(ctx, owners, from, to, own, opts) do
      {:ok, busy} ->
        current = parse_time(logistics["slot"])

        cond do
          current && DateTime.compare(current, now) == :gt &&
              free?(current, recording.minutes, busy) ->
            {:ok, episode, document}

          slot = first_free(candidates, recording.minutes, busy) ->
            propose(ctx, config, canvas, document, episode, slot, owners)

          true ->
            park(ctx, canvas, document, episode, @slot_item,
              detail: "Window checked: #{iso(from)} to #{iso(to)} (#{recording.time_zone})."
            )
        end

      {:error, reason} ->
        Logger.warning("[showrunner.recording_prep] calendar read refused: #{inspect(reason)}")
        park(ctx, canvas, document, episode, @calendar_item, [])
    end
  end

  defp propose(ctx, config, canvas, document, episode, slot, owners) do
    stop = DateTime.add(slot, config.recording.minutes * 60, :second)

    attrs = %{
      "title" => "Recording: #{canvas.title || "Episode #{episode.number}"}",
      "starts_at" => DateTime.to_iso8601(slot),
      "ends_at" => DateTime.to_iso8601(stop),
      "time_zone" => config.recording.time_zone
    }

    request_key = "showrunner:#{canvas.id}:#{DateTime.to_unix(slot)}"

    results =
      Enum.map(owners, fn owner ->
        with {:ok, scope} <- runtime_scope(ctx.agent_id) do
          AgentAccess.propose(scope, owner, "create", attrs, request_key)
        end
      end)

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      hold_ids = Enum.map(results, fn {:ok, consent} -> consent.hold_id end)
      logistics = Board.meta(document, @meta_key)

      document =
        Board.put_meta(document, @meta_key, %{
          "slot" => DateTime.to_iso8601(slot),
          "hold_ids" => Enum.uniq((logistics["hold_ids"] || []) ++ hold_ids)
        })

      {:ok, %{episode | records_at: DateTime.truncate(slot, :second)}, document}
    else
      Logger.warning("[showrunner.recording_prep] proposal refused: #{inspect(results)}")
      park(ctx, canvas, document, episode, @calendar_item, [])
    end
  end

  defp room(ctx, config, canvas, document, episode) do
    logistics = Board.meta(document, @meta_key)

    case meeting(logistics["meeting_id"]) do
      %Meeting{} ->
        {:ok, %{episode | room_status: @room_ready}, document}

      nil when is_binary(config.project_id) ->
        starts = episode.records_at
        stops = starts && DateTime.add(starts, config.recording.minutes * 60, :second)

        attrs =
          %{
            project_id: config.project_id,
            name: canvas.title || "Episode #{episode.number}",
            scheduled_start_at: starts,
            scheduled_end_at: stops
          }
          |> Map.reject(fn {_k, v} -> is_nil(v) end)

        case Meetings.create_meeting(attrs) do
          {:ok, meeting} ->
            document =
              Board.put_meta(document, @meta_key, %{
                "meeting_id" => meeting.id,
                "meeting_space_id" => meeting.chat_space_id,
                "room_name" => meeting.livekit_room_name,
                "meeting_slug" => meeting.slug
              })

            {:ok, %{episode | room_status: @room_ready}, document}

          {:error, reason} ->
            Logger.warning("[showrunner.recording_prep] meeting refused: #{inspect(reason)}")
            {:error, {:meeting_refused, reason}}
        end

      nil ->
        park(ctx, canvas, document, episode, @project_item, [])
    end
  end

  defp checklist(ctx, config, document, episode, now) do
    logistics = Board.meta(document, @meta_key)

    if is_nil(logistics["checklist_posted_at"]) and day_before_or_later?(episode, config, now) do
      content =
        "Pre-show checklist, Episode #{episode.number} (records #{local(episode.records_at, config)}):\n" <>
          "- Mic: plugged in, levels checked, headphones on\n" <>
          "- Room: #{room_link(logistics)}\n" <>
          "- Links: the run sheet on the episode board, and the brief's sources open in a tab"

      case post(ctx.space_id, ctx.participant_id, content) do
        {:ok, _} ->
          {:ok,
           Board.put_meta(document, @meta_key, %{
             "checklist_posted_at" => DateTime.to_iso8601(now)
           })}

        {:error, reason} ->
          {:error, {:checklist_refused, reason}}
      end
    else
      {:ok, document}
    end
  end

  defp recording_day(ctx, config, document, episode, now) do
    logistics = Board.meta(document, @meta_key)

    with true <- is_nil(logistics["attached_at"]),
         true <- recording_day?(episode, config, now),
         %Meeting{} = meeting <- meeting(logistics["meeting_id"]),
         {:ok, participant_id} <- join(meeting.chat_space_id, ctx.agent_id),
         {:ok, _} <- post(meeting.chat_space_id, participant_id, cohost_seed(config, episode)) do
      document =
        Board.put_meta(document, @meta_key, %{"attached_at" => DateTime.to_iso8601(now)})

      episode =
        case Episode.advance(episode, :record) do
          {:ok, advanced} -> advanced
          {:error, _} -> episode
        end

      Memory.append_journal(
        ctx.space_id,
        Memory.episode_entry(episode.number, "recording day; showrunner seated in the room")
      )

      {:ok, episode, document}
    else
      {:error, reason} -> {:error, {:attach_refused, reason}}
      _ -> {:ok, episode, document}
    end
  end

  defp park(ctx, canvas, document, episode, item, escalate_opts) do
    case Board.raise_needs_you(ctx, canvas, document, episode, item, escalate_opts) do
      {:ok, _} -> {:parked, item.id}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── calendar ──

  defp owners(%{host_user_ids: [_ | _] = ids}), do: ids
  defp owners(%{escalate_user_id: id}) when is_binary(id), do: [id]
  defp owners(_config), do: []

  defp busy(_ctx, [], _from, _to, _own, _opts), do: {:error, :no_calendar_owner}

  defp busy(ctx, owners, from, to, own_ids, opts) do
    case Keyword.get(opts, :busy) do
      fun when is_function(fun, 3) ->
        fun.(owners, from, to)

      _ ->
        with {:ok, scope} <- runtime_scope(ctx.agent_id) do
          Enum.reduce_while(owners, {:ok, []}, fn owner, {:ok, acc} ->
            case AgentAccess.read(scope, owner, from, to) do
              {:ok, events} ->
                intervals =
                  events
                  |> Enum.reject(&(Map.get(&1, :id) in own_ids))
                  |> Enum.filter(
                    &(match?(%DateTime{}, &1.starts_at) and match?(%DateTime{}, &1.ends_at))
                  )
                  |> Enum.map(&{&1.starts_at, &1.ends_at})

                {:cont, {:ok, acc ++ intervals}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end)
        end
    end
  end

  defp runtime_scope(agent_id) do
    with %Agent{runtime_id: runtime_id} when is_binary(runtime_id) <- Repo.get(Agent, agent_id),
         %{} = runtime <- Federation.get_runtime(runtime_id) do
      {:ok, Scope.for_runtime(runtime)}
    else
      _ -> {:error, :no_runtime}
    end
  end

  # ── meeting ──

  defp meeting(id) when is_binary(id), do: Meetings.get_meeting(id)
  defp meeting(_), do: nil

  defp join(space_id, agent_id) do
    case Chat.get_agent_participant(space_id, agent_id) do
      %{id: id} ->
        {:ok, id}

      nil ->
        case Chat.add_participant(space_id, %{
               participant_type: "agent",
               participant_id: agent_id,
               joined_at: DateTime.utc_now()
             }) do
          {:ok, %{id: id}} -> {:ok, id}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp cohost_seed(config, episode) do
    assigns = %{
      episode_number: to_string(episode.number),
      title: episode.title,
      records_at: local(episode.records_at, config),
      host_roles: Enum.join(config.host_roles, ", "),
      run_sheet: run_sheet_text(episode)
    }

    case Runtime.render(@template_slug, @template_slug, assigns) do
      {:ok, body} ->
        body

      {:error, _} ->
        "Run sheet for Episode #{episode.number}: #{episode.title}\n\n" <> assigns.run_sheet
    end
  end

  @doc "The run sheet as plain text, one segment per line block."
  @spec run_sheet_text(Episode.t()) :: String.t()
  def run_sheet_text(%Episode{run_sheet: segments}) do
    Enum.map_join(segments, "\n\n", fn s ->
      points = Enum.map_join(s.talking_points, "\n", fn {role, text} -> "  #{role}: #{text}" end)

      stats =
        Enum.map_join(s.stat_cards, "\n", fn card ->
          "  stat: #{card.text} (#{card.source_url})"
        end)

      callback = if s.callback_episode, do: " (callback Ep #{s.callback_episode})", else: ""

      ["#{clock(s.starts_at_s)}-#{clock(s.ends_at_s)} #{s.name}#{callback}", points, stats]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end)
  end

  defp clock(seconds) do
    m = div(seconds, 60) |> Integer.to_string() |> String.pad_leading(2, "0")
    s = rem(seconds, 60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{m}:#{s}"
  end

  defp room_link(%{"meeting_slug" => slug}) when is_binary(slug), do: "/meetings/#{slug}"
  defp room_link(_), do: "the meeting on the episode board"

  defp post(space_id, participant_id, content) do
    Chat.post_message(%{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: content,
      metadata: %{"source" => "showrunner", "skip_mention_scan" => true}
    })
  end

  # ── time ──

  defp day_before_or_later?(%Episode{records_at: %DateTime{} = at}, config, now) do
    tz = config.recording.time_zone
    record_day = at |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    today = now |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    Date.compare(today, Date.add(record_day, -1)) != :lt
  end

  defp day_before_or_later?(_episode, _config, _now), do: false

  defp recording_day?(%Episode{records_at: %DateTime{} = at}, config, now) do
    tz = config.recording.time_zone
    record_day = at |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    today = now |> DateTime.shift_zone!(tz) |> DateTime.to_date()
    Date.compare(today, record_day) != :lt
  end

  defp recording_day?(_episode, _config, _now), do: false

  defp local(%DateTime{} = at, config) do
    local = DateTime.shift_zone!(at, config.recording.time_zone)
    Calendar.strftime(local, "%a %d %b %H:%M ") <> config.recording.time_zone
  end

  defp local(_at, _config), do: "time to be set"

  defp at(date, time, tz) do
    case DateTime.new(date, time, tz) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _before, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC")
      {:error, _} -> DateTime.new!(date, time, "Etc/UTC")
    end
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp now(meta, opts) do
    case Keyword.get(opts, :now) || Runtime.meta(meta, :fired_at) do
      %DateTime{} = at -> at
      _ -> DateTime.utc_now()
    end
  end
end
