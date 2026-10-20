defmodule Platform.Memory.Insights.Disseminator do
  @moduledoc """
  Daily delivery of dreaming insights as a briefing canvas. Task
  `01a13867-3213-7001-a128-6b4c6b34283f`, stage 3.

  A GenServer that fires at 07:00 America/Chicago (two hours after the 05:00
  dreaming run, `Platform.Responsibilities.Handlers.Dreaming`), plus a
  synchronous `run/1` that tests and operators call directly. Disabled in
  `config/test.exs` (`:start_insight_disseminator false`).

  ## One run

  1. `Platform.Memory.Insights.Digest.select/2` decides who gets what. While
     `dissemination_enabled` is off it selects nothing, so a run delivers
     nothing and writes nothing.
  2. The sender is the agent holding the `memory.dreaming` responsibility
     (`Platform.Roles.assignee_for/1`). With no such agent the run logs and
     delivers nothing.
  3. Per person, in the DM `Platform.Chat.find_or_create_dm(user_id, "agent",
     agent_id)` returns:
     * the day's canvas is created (`Chat.create_canvas_with_message/3`,
       posted by the agent) together with its `memory_briefings` row, or,
       when a row already exists for `(user_id, digest_date)`, that canvas
       is re-rendered with the new items appended (`replace_document`);
     * an item already on the day's canvas (same node key) is not added
       twice;
     * each newly rendered insight gets `delivered_at` and a `delivered`
       signal (`Platform.Memory.Insights.mark_delivered/2`);
     * one push goes to the person's DM participant
       (`Platform.Notifications.fan_out_to_humans/3`).

  `digest_date` is the America/Chicago calendar date of the run, so the
  07:00 run and any manual run later that day share one canvas.

  ## Page edits and tasks are applied before they are rendered

  Task `01a15587-afc8-7000-b76d-4e1c48eee5ed`, stage 3. The digest selects a
  `page_edit` or `task` only when its toggle is on and it is eligible for
  unattended action (see `Platform.Memory.Insights.Digest`). Before a
  person's briefing is rendered, each such insight is run through
  `Platform.Memory.Insights.Actions.apply_unattended/2`:

    * `{:ok, acted}` — the edit or task exists; the insight is rendered under
      "Already done" and marked delivered.
    * `{:ok, :downgraded, question}` — the source no longer resolves and
      nothing was written; the question is rendered under "Questions" only
      when `deliver_questions` is on and it still routes `reversible` to this
      person, else it waits, open and undelivered, for a later run.
    * `{:error, reason}` — nothing written, NOT rendered, the insight stays
      open and undelivered; a warning names the insight and the reason.

  One apply that raises or exits is logged and treated as an error, so the
  rest of the person's briefing is still delivered. A same-day re-run never
  applies an insight twice: the first apply leaves it `done`, which the
  digest does not select and `apply_unattended/2` refuses (`:not_open`).
  Applying happens only on the `run/1` path; `deliver_now/3` (a person
  asked) is unchanged and never applies anything.
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.CanvasDocument
  alias Platform.Chat.Participant
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.Actions
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Memory.Insights.Briefings
  alias Platform.Memory.Insights.Digest
  alias Platform.Memory.Insights.Settings
  alias Platform.Push.Notification
  alias Platform.Repo
  alias Platform.Responsibilities.Cron
  alias Platform.Responsibilities.Handlers.Dreaming

  @expression "0 7 * * *"
  @timezone "America/Chicago"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The zone the daily fire time and `digest_date` are read in."
  @spec timezone() :: String.t()
  def timezone, do: @timezone

  @doc """
  Run one delivery synchronously. Returns `{:ok, %{users: n, items: m}}`,
  with `reason: :no_agent` added when nobody holds `memory.dreaming`.

  Options:
    * `:now` — a `DateTime` (default now).
    * `:notifications_module` — the module whose `fan_out_to_humans/3` sends
      the push (default `Platform.Notifications`).
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    digest = Digest.select(now)

    cond do
      digest == %{} ->
        {:ok, %{users: 0, items: 0}}

      true ->
        case Platform.Roles.assignee_for(Dreaming.key()) do
          nil ->
            Logger.warning(
              "[insight_disseminator] no agent holds #{Dreaming.key()}; " <>
                "#{map_size(digest)} digest(s) not delivered"
            )

            {:ok, %{users: 0, items: 0, reason: :no_agent}}

          agent ->
            deliver_all(digest, agent, now, opts)
        end
    end
  end

  defp deliver_all(digest, agent, now, opts) do
    date = local_date(now)
    notifications = Keyword.get(opts, :notifications_module, Platform.Notifications)

    settings = Settings.get()

    digest
    |> Enum.map(fn {user_id, insights} ->
      case apply_unattended(user_id, insights, settings, now) do
        [] -> {:ok, 0}
        insights -> deliver(user_id, insights, agent, date, now, notifications)
      end
    end)
    |> Enum.reduce({:ok, %{users: 0, items: 0}}, fn
      {:ok, 0}, acc ->
        acc

      {:ok, n}, {:ok, %{users: u, items: i}} ->
        {:ok, %{users: u + 1, items: i + n}}

      {:error, _}, acc ->
        acc
    end)
  end

  # ── Unattended page edits and tasks (task 01a15587 stage 3) ──────────

  @unattended_types ["page_edit", "task"]

  # Apply each selected page_edit / task (see the moduledoc) and keep what
  # is to be rendered, in order. Every other insight passes through.
  defp apply_unattended(user_id, insights, settings, now) do
    Enum.flat_map(insights, fn
      %Insight{action_type: type} = insight when type in @unattended_types ->
        case safe_apply(insight, now) do
          {:ok, %Insight{} = acted} ->
            [%{acted | tier: "reversible"}]

          {:ok, :downgraded, %Insight{} = question} ->
            if settings.deliver_questions and question.tier == "reversible" and
                 question.addressee_user_id == user_id,
               do: [question],
               else: []

          {:error, reason} ->
            Logger.warning(
              "[insight_disseminator] insight #{insight.id} (#{type}) not applied: " <>
                inspect(reason)
            )

            []
        end

      insight ->
        [insight]
    end)
  end

  defp safe_apply(insight, now) do
    Actions.apply_unattended(insight, now: now)
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "The America/Chicago calendar date of `now`."
  @spec local_date(DateTime.t()) :: Date.t()
  def local_date(%DateTime{} = now) do
    case DateTime.shift_zone(now, @timezone) do
      {:ok, local} -> DateTime.to_date(local)
      _ -> DateTime.to_date(now)
    end
  end

  # ── Per person ───────────────────────────────────────────────────────

  defp deliver(user_id, insights, agent, date, now, notifications) do
    with {:ok, dm} <- Chat.find_or_create_dm(user_id, "agent", agent.id),
         %Participant{} = agent_p <- participant(dm.id, "agent", agent.id),
         %Participant{} = user_p <- participant(dm.id, "user", user_id) do
      existing = Repo.get_by(Briefing, user_id: user_id, digest_date: date)
      existing_items = (existing && existing.items) || %{}

      new =
        insights
        |> Enum.map(&{BriefingCard.node_key(&1), &1})
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.reject(fn {key, _insight} -> Map.has_key?(existing_items, key) end)

      if new == [] do
        {:ok, 0}
      else
        items = Map.merge(existing_items, Map.new(new, fn {key, i} -> {key, i.id} end))
        stored = stored_document(existing)
        entries = previous_entries(existing, stored) ++ new

        document =
          BriefingCard.document(date, entries,
            admin?: Platform.Tenancy.root_admin?(%{id: user_id}),
            settled: settled(existing, stored)
          )

        result =
          case existing do
            nil -> create(dm, agent_p, user_id, date, document, items)
            %Briefing{} -> update(existing, document, items)
          end

        case result do
          {:ok, _briefing} ->
            Enum.each(new, fn {_key, insight} -> Insights.mark_delivered(insight, now: now) end)
            push(notifications, dm, user_p, agent, length(new))
            {:ok, length(new)}

          {:error, reason} = error ->
            Logger.warning(
              "[insight_disseminator] briefing for user #{user_id} not delivered: " <>
                inspect(reason)
            )

            error
        end
      end
    else
      other ->
        Logger.warning(
          "[insight_disseminator] no DM for user #{user_id} with agent #{agent.id}: " <>
            inspect(other)
        )

        {:error, :no_dm}
    end
  end

  defp participant(space_id, type, id) do
    Repo.one(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == ^type and p.participant_id == ^id,
        limit: 1
      )
    )
  end

  # The items already on the day's canvas, in display order, each keeping
  # the section it was rendered in (a "Needs your call" line stays one even
  # if its tier has changed since). A purged insight is dropped from the
  # render; its key stays in `items`.
  defp previous_entries(nil, _document), do: []

  defp previous_entries(%Briefing{items: items}, document) when map_size(items) > 0 do
    ids = Map.values(items)
    key_by_id = Map.new(items, fn {key, id} -> {id, key} end)

    from(i in Insight, where: i.id in ^ids, order_by: [asc: i.inserted_at, asc: i.id])
    |> Repo.all()
    |> Enum.map(fn insight ->
      key = Map.fetch!(key_by_id, insight.id)

      tier =
        if CanvasDocument.get_node(document, "call-" <> key), do: "needs_call", else: "reversible"

      {key, %{insight | tier: tier}}
    end)
  end

  defp previous_entries(_briefing, _document), do: []

  # The day's canvas as it stands: the canvas server's live document when it
  # answers (a click may have patched it moments ago and the persist is
  # async), else the persisted row.
  defp stored_document(nil), do: %{}

  defp stored_document(%Briefing{canvas_id: canvas_id}) do
    case Platform.Chat.Canvas.Server.describe(canvas_id) do
      {:ok, %{document: %{} = document}} ->
        document

      _ ->
        case Repo.get(Canvas, canvas_id) do
          %Canvas{document: %{} = document} -> document
          _ -> %{}
        end
    end
  rescue
    _ -> %{}
  end

  # Items already settled on the day's canvas (stage 4: Looks right, Flag,
  # Answer) keep the nodes they were settled with.
  defp settled(nil, _document), do: %{}

  defp settled(%Briefing{items: items}, document) do
    Enum.reduce(items, %{}, fn {key, _id}, acc ->
      case Briefings.settled_nodes(document, key) do
        [_ | _] = nodes -> Map.put(acc, key, nodes)
        _ -> acc
      end
    end)
  end

  # ── Manual delivery (stage 4) ────────────────────────────────────────

  @doc """
  Deliver `insights` into `user_id`'s briefing for today NOW, creating the
  day's canvas or adding to it, whatever `dissemination_enabled` says: a
  person asked for it (`Platform.Memory.Insights.act/3` on a `question` or a
  `briefing`). The caller has already decided the actor may; the items are
  rendered as executable (`tier: "reversible"`), because the person who
  acted made the call.

  Returns `{:ok, n}` with the number of items added (0 when every item is
  already on today's canvas), `{:error, :no_agent}` when nobody holds
  `memory.dreaming`, `{:error, :opted_out}` when the person opted out of
  insight delivery, or the delivery error.

  Options: `:now`, `:notifications_module` (as `run/1`).
  """
  @spec deliver_now(binary(), [Insight.t()], keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def deliver_now(user_id, insights, opts \\ []) when is_binary(user_id) and is_list(insights) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    notifications = Keyword.get(opts, :notifications_module, Platform.Notifications)

    cond do
      Platform.Accounts.insight_delivery_opted_out?(user_id) ->
        {:error, :opted_out}

      true ->
        case Platform.Roles.assignee_for(Dreaming.key()) do
          nil ->
            {:error, :no_agent}

          agent ->
            insights = Enum.map(insights, &%{&1 | tier: "reversible"})
            deliver(user_id, insights, agent, local_date(now), now, notifications)
        end
    end
  end

  defp create(dm, agent_p, user_id, date, document, items) do
    Repo.transaction(fn ->
      with {:ok, canvas, _message} <-
             Chat.create_canvas_with_message(dm.id, agent_p.id, %{
               "title" => "Briefing " <> Date.to_iso8601(date),
               "document" => document,
               "message_content" => "Your briefing for " <> Date.to_iso8601(date)
             }),
           {:ok, briefing} <-
             %Briefing{}
             |> Briefing.changeset(%{
               user_id: user_id,
               space_id: dm.id,
               canvas_id: canvas.id,
               digest_date: date,
               items: items
             })
             |> Repo.insert() do
        briefing
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp update(%Briefing{} = briefing, document, items) do
    with %Canvas{} = canvas <- Chat.get_canvas(briefing.canvas_id) || {:error, :canvas_not_found},
         {:ok, _canvas} <- Chat.patch_canvas(:system, canvas, [{:replace_document, document}]) do
      briefing |> Briefing.changeset(%{items: items}) |> Repo.update()
    else
      {:conflict, payload} -> {:error, {:conflict, payload}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp push(notifications, dm, user_p, agent, count) do
    notification =
      Notification.new(%{
        kind: "insight_briefing",
        title: "Your briefing",
        body: "#{count} new #{if count == 1, do: "item", else: "items"} from #{agent.name}",
        url: "/chat/#{Chat.space_path_segment(dm)}",
        space_id: dm.id
      })

    notifications.fan_out_to_humans([user_p.id], notification, [])
  rescue
    error ->
      Logger.warning("[insight_disseminator] push failed: " <> Exception.message(error))
      :ok
  end

  # ── Schedule ─────────────────────────────────────────────────────────

  @doc "Milliseconds from `now` to the next 07:00 America/Chicago."
  @spec ms_until_next_fire(DateTime.t()) :: pos_integer()
  def ms_until_next_fire(%DateTime{} = now) do
    with {:ok, spec} <- Cron.parse(@expression),
         {:ok, next} <- Cron.next_fire_after(now, spec, timezone: @timezone) do
      max(DateTime.diff(next, now, :millisecond), 1_000)
    else
      _ -> 24 * 60 * 60 * 1000
    end
  end

  @impl true
  def init(_opts) do
    schedule_next()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      {:ok, summary} = run()
      Logger.info("[insight_disseminator] run: #{inspect(summary)}")
    rescue
      error ->
        Logger.error(
          "[insight_disseminator] run crashed: " <>
            Exception.format(:error, error, __STACKTRACE__)
        )
    end

    schedule_next()
    {:noreply, state}
  end

  defp schedule_next,
    do: Process.send_after(self(), :tick, ms_until_next_fire(DateTime.utc_now()))
end
