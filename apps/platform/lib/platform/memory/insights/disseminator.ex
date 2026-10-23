defmodule Platform.Memory.Insights.Disseminator do
  @moduledoc """
  Daily delivery of dreaming insights as ONE Inbox row per person per day.
  Task `01a13867-3213-7001-a128-6b4c6b34283f`, stage 3; delivery moved from
  a DM canvas to the Inbox by task `01a15ee1-48c8-7000-a8f1-33a5586cb458`,
  stage 1.

  A GenServer that fires at 07:00 America/Chicago (two hours after the 05:00
  dreaming run, `Platform.Responsibilities.Handlers.Dreaming`), plus a
  synchronous `run/1` that tests and operators call directly. Disabled in
  `config/test.exs` (`:start_insight_disseminator false`).

  ## One run

  1. `Platform.Memory.Insights.Digest.select/2` decides who gets what. While
     `dissemination_enabled` is off it selects nothing, so a run delivers
     nothing and writes nothing.
  2. The agent holding the `memory.dreaming` responsibility
     (`Platform.Roles.assignee_for/1`) is still required: it is the
     unattended actor that applies page edits and files tasks. With no such
     agent the run logs and delivers nothing.
  3. Per person, in one transaction:
     * the `memory_briefings` row for `(user_id, digest_date)` is created,
       or the new items are merged into it; an item already in the day's
       row (same `BriefingCard.node_key/1`) is not added twice. The row has
       no canvas (`canvas_id` and `space_id` nil);
     * `Platform.Inbox.upsert_briefing_item/2` writes the day's ONE Inbox
       row (kind `briefing`), or refreshes its subtitle and re-marks it
       unread when new items arrived;
     * each new insight gets `delivered_at` and a `delivered` signal
       (`Platform.Memory.Insights.mark_delivered/2`).
  4. ONE push per person per day, when the day's Inbox row is first created
     (kind `insight_briefing`, url `/inbox/briefing/<digest_date>`,
     `Platform.Notifications.fan_out_to_user/2`, the transport
     `Platform.Inbox` uses). A same-day re-run that adds items does not
     push again; the row going unread is the signal.

  No DM space and no canvas is created on any path. A guest (an external
  member) is refused with `{:error, :guest_addressee}` and nothing is
  written, because the Inbox shows an external viewer no briefing row.
  Briefings only ever go to
  internal people (`Digest.route/5` targets internal addressees and internal
  root admins), and the Inbox reaches every internal member, so there is no
  case left for the DM. `BriefingCard` and the canvas hooks stay so that
  briefings delivered as canvases before this change still render and act.

  `digest_date` is the America/Chicago calendar date of the run, so the
  07:00 run and any manual run later that day share one row.

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
    * `{:error, :no_project}` for a `task` (task 01a15ee1 stage 2: no
      project was inferred, `Platform.Memory.Insights.ProjectInference`) —
      nothing filed, but the insight IS rendered and delivered, marked
      `needs_project: true` in memory, so the briefing asks the person to
      pick a project. It stays `open`.
    * any other `{:error, reason}` — nothing written, NOT rendered, the
      insight stays open and undelivered; a warning names the insight and
      the reason.

  One apply that raises or exits is logged and treated as an error, so the
  rest of the person's briefing is still delivered. A same-day re-run never
  applies an insight twice: the first apply leaves it `done`, which the
  digest does not select and `apply_unattended/2` refuses (`:not_open`).
  Applying happens only on the `run/1` path; `deliver_now/3` (a person
  asked) is unchanged and never applies anything.

  ## Outside messages are drafted, never sent (task 01a15ee1 stage 3)

  An insight whose addressee is an email outside the org
  (`Platform.Memory.Insights.Outside.outside?/1`) is tiered `needs_call` and
  routed to root admins as before. Before delivery, each such selected
  insight is saved as ONE email draft (`Outside.draft/3`, which stores
  `action["mail_draft_id"]`, so a re-run drafts nothing). With the Email
  module off or no mail account, nothing is drafted and the insight still
  renders. An outside `page_edit` or `task` is passed through to the
  briefing as it is, never applied unattended. `Platform.Mail.Dispatch` is
  never called.

  ## Only `reversible` page edits and tasks are applied (task 01a15ee1 stage 5)

  A `needs_call` page_edit or task (Digest routes it to the root admins) is
  NEVER run through `apply_unattended/2`: it is passed through to the
  briefing as it is, open, and the Inbox lists it under "Needs your call".
  Before this, the apply was tried, refused as unauthorized, and the
  insight dropped, so the items that most needed a call never reached one.
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Inbox
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.Actions
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Memory.Insights.Digest
  alias Platform.Memory.Insights.Outside
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
    * `:notifications_module` — the module whose `fan_out_to_user/2` sends
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
    draft_outside(digest, agent)

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
  #
  # Only a `reversible` one is applied (task 01a15ee1 stage 5). Digest routes
  # a `needs_call` page_edit / task to the root admins; applying it as the
  # acting agent is refused, and dropping the refusal kept exactly the items
  # that need a call off the briefing. It passes straight through, so the
  # admin sees it under "Needs your call" and decides. `tier` is Digest's
  # re-check of now, not the ingest-time label.
  defp apply_unattended(user_id, insights, settings, now) do
    Enum.flat_map(insights, fn
      %Insight{action_type: type, tier: "reversible"} = insight when type in @unattended_types ->
        if Outside.outside?(insight),
          do: [insight],
          else: apply_one(insight, type, user_id, settings, now)

      insight ->
        [insight]
    end)
  end

  defp apply_one(insight, type, user_id, settings, now) do
    case safe_apply(insight, now) do
      {:ok, %Insight{} = acted} ->
        [%{acted | tier: "reversible"}]

      {:ok, :downgraded, %Insight{} = question} ->
        if settings.deliver_questions and question.tier == "reversible" and
             question.addressee_user_id == user_id,
           do: [question],
           else: []

      # Task 01a15ee1 stage 2: no project could be inferred. Nothing was
      # filed; the person is asked to pick one, so the insight is KEPT
      # for rendering, marked in memory.
      {:error, :no_project} when type == "task" ->
        [%{insight | needs_project: true}]

      {:error, reason} ->
        Logger.warning(
          "[insight_disseminator] insight #{insight.id} (#{type}) not applied: " <>
            inspect(reason)
        )

        []
    end
  end

  # ── Outside messages (task 01a15ee1 stage 3) ─────────────────────────

  # Every selected insight that proposes a message to someone outside the
  # org is saved as ONE email draft (`Platform.Memory.Insights.Outside`),
  # once per insight however many root admins it is routed to; a re-run
  # finds the stored `mail_draft_id` and drafts nothing. Never sent.
  defp draft_outside(digest, agent) do
    digest
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(&Outside.outside?/1)
    |> Enum.each(fn insight ->
      try do
        Outside.draft(insight, agent)
      rescue
        error ->
          Logger.warning(
            "[insight_disseminator] outside draft for #{insight.id} raised: " <>
              Exception.message(error)
          )
      end
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

  # Task 01a15ee1 stage 1: the briefing is ONE Inbox row per person per day.
  # No DM, no canvas. The `memory_briefings` row for `(user_id, date)` is
  # written or merged first (node-key dedupe), then the Inbox row, then each
  # new insight is marked delivered, all in one transaction so a failed
  # Inbox write leaves the insights undelivered for the next run.
  #
  # A guest (an external member, `Platform.Tenancy.external_user?/1`) is
  # refused with `{:error, :guest_addressee}` before anything is written: the
  # Inbox lists only `chat_mention` rows to an external viewer, so a briefing
  # written for a guest would read as delivered while nobody could see it.
  # No briefing, no Inbox row, and `delivered_at` stays nil.
  defp deliver(user_id, insights, agent, date, now, notifications) do
    if Platform.Tenancy.external_user?(%{id: user_id}) do
      Logger.warning(
        "[insight_disseminator] briefing for user #{user_id} not delivered: :guest_addressee"
      )

      {:error, :guest_addressee}
    else
      deliver_to_member(user_id, insights, agent, date, now, notifications)
    end
  end

  defp deliver_to_member(user_id, insights, agent, date, now, notifications) do
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

      result =
        Repo.transaction(fn ->
          with {:ok, briefing} <- write_briefing(existing, user_id, date, items),
               {:ok, item, outcome} <-
                 Inbox.upsert_briefing_item(briefing, %{
                   total: map_size(items),
                   calls: calls(items),
                   new_items?: true
                 }) do
            Enum.each(new, fn {_key, insight} -> Insights.mark_delivered(insight, now: now) end)
            {item, outcome}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, {_item, outcome}} ->
          if outcome == :created, do: push(notifications, user_id, agent, date, length(new))
          {:ok, length(new)}

        {:error, reason} = error ->
          Logger.warning(
            "[insight_disseminator] briefing for user #{user_id} not delivered: " <>
              inspect(reason)
          )

          error
      end
    end
  end

  defp write_briefing(nil, user_id, date, items) do
    %Briefing{}
    |> Briefing.changeset(%{user_id: user_id, digest_date: date, items: items})
    |> Repo.insert()
  end

  defp write_briefing(%Briefing{} = briefing, _user_id, _date, items),
    do: briefing |> Briefing.changeset(%{items: items}) |> Repo.update()

  # How many of the day's items still ask for the person's call: open
  # questions, open needs_call items, and open page edits / tasks (applied
  # ones are `done`). The Inbox view recomputes this live (stage 4); this is
  # the row's subtitle at delivery time. A purged insight counts as handled.
  defp calls(items) do
    ids = Map.values(items)

    from(i in Insight,
      where:
        i.id in ^ids and i.state == "open" and
          (i.tier == "needs_call" or i.action_type in ["question", "page_edit", "task"]),
      select: count(i.id)
    )
    |> Repo.one()
  end

  # ── Manual delivery (stage 4) ────────────────────────────────────────

  @doc """
  Deliver `insights` into `user_id`'s briefing for today NOW, creating the
  day's briefing and Inbox row or adding to them, whatever
  `dissemination_enabled` says: a
  person asked for it (`Platform.Memory.Insights.act/3` on a `question` or a
  `briefing`). The caller has already decided the actor may; the items are
  rendered as executable (`tier: "reversible"`), because the person who
  acted made the call.

  Returns `{:ok, n}` with the number of items added (0 when every item is
  already in today's briefing), `{:error, :no_agent}` when nobody holds
  `memory.dreaming`, `{:error, :opted_out}` when the person opted out of
  insight delivery, `{:error, :guest_addressee}` when the person is a guest
  (an external member, who has no Inbox briefing to read), or the delivery
  error.

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

  # ONE push per person per day, sent when the day's Inbox row is first
  # created; the same transport `Platform.Inbox` uses for its pushed kinds.
  defp push(notifications, user_id, agent, date, count) do
    notification =
      Notification.new(%{
        kind: "insight_briefing",
        title: "Your briefing",
        body: "#{count} new #{if count == 1, do: "item", else: "items"} from #{agent.name}",
        url: Inbox.briefing_url(date)
      })

    notifications.fan_out_to_user(user_id, notification)
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
