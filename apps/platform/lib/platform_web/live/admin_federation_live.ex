defmodule PlatformWeb.AdminFederationLive do
  use PlatformWeb, :live_view

  import Ecto.Query

  require Logger

  alias Platform.Federation
  alias Platform.Federation.DeadLetter
  alias Platform.Federation.DeadLetterStat
  alias Platform.Federation.DeadLetters
  alias Platform.Repo
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stage

  @refresh_interval_ms 5_000
  @dead_letter_limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval_ms, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, "Admin · Federation")
     |> assign(:runtimes, federation_status())
     |> assign(:ping_results, %{})
     |> assign_dead_letters()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply,
     socket
     |> assign(:runtimes, federation_status())
     |> assign_dead_letters()}
  end

  def handle_info({:clear_ping, runtime_id}, socket) do
    ping_results = Map.delete(socket.assigns.ping_results, runtime_id)
    {:noreply, assign(socket, :ping_results, ping_results)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:runtimes, federation_status())
     |> assign_dead_letters()}
  end

  def handle_event("ping", %{"runtime-id" => runtime_id}, socket) do
    case Federation.ping_runtime(runtime_id) do
      :ok ->
        ping_results = Map.put(socket.assigns.ping_results, runtime_id, :sent)
        # Clear the result after 5 seconds
        Process.send_after(self(), {:clear_ping, runtime_id}, 5_000)
        {:noreply, assign(socket, :ping_results, ping_results)}

      {:error, reason} ->
        ping_results =
          Map.put(socket.assigns.ping_results, runtime_id, {:error, inspect(reason)})

        {:noreply, assign(socket, :ping_results, ping_results)}
    end
  end

  # Prunes TERMINAL rows only. The old in-memory buffer's `clear/0` dropped
  # everything because nothing in it was actionable; the ledger's `pending`
  # rows ARE the replay queue, so a button that could delete them would turn
  # an admin convenience into the loss this table exists to stop. The name says
  # prune rather than clear because that is what it does — `DeadLetters.prune/1`
  # filters on `terminal_dispositions/0`, so the live rows are unreachable from
  # here no matter what an operator clicks.
  #
  # The cumulative panel is deliberately re-read after the delete: it must come
  # back with the SAME totals, which is the visible proof that the counters do
  # not live on these rows.
  def handle_event("prune_dead_letters", _params, socket) do
    {:ok, pruned} = DeadLetters.prune(days: 0)

    Logger.info("[AdminFederation] pruned #{pruned} terminal dead letters (live queue untouched)")

    {:noreply, assign_dead_letters(socket)}
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp federation_status do
    try do
      Federation.federation_status()
    rescue
      _ -> []
    end
  end

  # The ledger rows and the cumulative counters are loaded together but come
  # from DIFFERENT places on purpose. `@dead_letters` is the live ledger — it
  # dedupes on write and prunes on cleanup, so it shrinks. `@loss_summary` and
  # `@key_breakdown` come from `federation_dead_letter_stats`, which is
  # monotonic and never pruned. Deriving the panel from `@dead_letters` (the
  # header badge used to be exactly `length(@dead_letters)`) would reproduce
  # the 2026-07-27 misreading: an instantaneous count read as a total.
  defp assign_dead_letters(socket) do
    socket
    |> assign(:dead_letters, dead_letters())
    |> assign(:loss_summary, loss_summary())
    |> assign(:key_breakdown, key_breakdown())
  end

  defp dead_letters do
    rows = DeadLetters.recent(@dead_letter_limit)
    subjects = subject_task_ids(rows)
    Enum.map(rows, &row_view_model(&1, subjects))
  rescue
    _ -> []
  end

  defp row_view_model(%DeadLetter{} = letter, subjects) do
    %{
      id: letter.id,
      occurred_at: letter.occurred_at,
      disposition: letter.disposition,
      responsibility_key: letter.responsibility_key,
      trigger_kind: letter.trigger_kind,
      agent_slug: letter.agent_slug || letter.agent_id,
      runtime_id: letter.runtime_id,
      reason: letter.reason,
      attempts: letter.attempts || 0,
      subject_type: letter.subject_type,
      subject_id: letter.subject_id,
      subject_short: short_id(letter.subject_id),
      subject_task_id: subjects[letter.subject_id]
    }
  end

  # Resolves each visible subject to the task it hangs off, so the id can be a
  # link rather than a string an operator has to paste somewhere. One query per
  # subject TYPE actually present among the ≤50 visible rows, each an
  # `id IN (...)` on a primary key — and zero queries in the common case, since
  # cron fires name no subject at all ("it is now T" is about nothing).
  defp subject_task_ids(rows) do
    rows
    |> Enum.reject(&is_nil(&1.subject_id))
    |> Enum.group_by(& &1.subject_type, & &1.subject_id)
    |> Enum.reduce(%{}, fn {type, ids}, acc ->
      Map.merge(acc, lookup_subjects(type, Enum.uniq(ids)))
    end)
  end

  defp lookup_subjects("task", ids) do
    Platform.Tasks.Task
    |> where([t], t.id in ^ids)
    |> select([t], {t.id, t.id})
    |> Repo.all()
    |> Map.new()
  end

  defp lookup_subjects("plan", ids) do
    Plan
    |> where([p], p.id in ^ids)
    |> select([p], {p.id, p.task_id})
    |> Repo.all()
    |> Map.new()
  end

  defp lookup_subjects("stage", ids) do
    from(s in Stage,
      join: p in Plan,
      on: p.id == s.plan_id,
      where: s.id in ^ids,
      select: {s.id, p.task_id}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp lookup_subjects(_type, _ids), do: %{}

  defp loss_summary do
    DeadLetters.loss_summary()
  rescue
    _ -> empty_loss_summary()
  end

  defp empty_loss_summary do
    %{
      recorded: 0,
      replayed: 0,
      dropped: 0,
      dropped_policy: 0,
      dropped_stale: 0,
      superseded_duplicate: 0,
      abandoned: 0,
      pending: 0,
      accounted: 0,
      balanced: true,
      replay_rate: 0.0
    }
  end

  # Arrivals and outcomes per responsibility key, folded across runtimes.
  # `recorded` is the ordering key because that is the "how much of this
  # responsibility was lost" number; the outcome columns say where it went.
  defp key_breakdown do
    recorded = DeadLetterStat.recorded()

    DeadLetters.stats()
    |> Enum.group_by(& &1.responsibility_key)
    |> Enum.map(fn {key, rows} ->
      counts =
        Enum.reduce(rows, %{}, fn row, acc ->
          Map.update(acc, row.disposition, row.count, &(&1 + row.count))
        end)

      %{
        key: key,
        label: key || "(unkeyed)",
        dom_id: key_dom_id(key),
        recorded: Map.get(counts, recorded, 0),
        replayed: Map.get(counts, "replayed", 0),
        dropped: Map.get(counts, "dropped_policy", 0) + Map.get(counts, "dropped_stale", 0),
        abandoned: Map.get(counts, "abandoned", 0)
      }
    end)
    |> Enum.sort_by(& &1.recorded, :desc)
  rescue
    _ -> []
  end

  defp key_dom_id(nil), do: "dead-letter-key-unkeyed"

  defp key_dom_id(key) when is_binary(key) do
    "dead-letter-key-" <> String.replace(key, ~r/[^A-Za-z0-9_-]/, "-")
  end

  # Disposition drives badge colour. Terminal DROPS are ghost rather than error
  # on purpose: a policy drop is a decision the system made correctly, and
  # colouring it as a failure would train an operator to ignore the colour that
  # marks the one disposition that IS a failure — `abandoned`.
  defp disposition_badge("pending"), do: "badge-warning"
  defp disposition_badge("replaying"), do: "badge-info"
  defp disposition_badge("replayed"), do: "badge-success"
  defp disposition_badge("abandoned"), do: "badge-error"
  defp disposition_badge(_terminal_drop), do: "badge-ghost"

  defp short_id(nil), do: nil
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp format_dt(nil), do: "—"

  defp format_dt(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> Calendar.strftime(dt, "%b %d %H:%M")
    end
  end
end
