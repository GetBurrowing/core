defmodule PlatformWeb.AdminFederationLive do
  use PlatformWeb, :live_view

  import Ecto.Query

  require Logger

  alias Platform.Federation
  alias Platform.Federation.DeadLetter
  alias Platform.Federation.DeadLetterStat
  alias Platform.Federation.DeadLetters
  alias Platform.Federation.RuntimePresence
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

  # Catch-all (Burrow redesign 22 stage 4): every LiveView in the shell
  # ignores a message it does not know rather than crashing (rung 20's
  # `{:new_message}` crash).
  def handle_info(_msg, socket), do: {:noreply, socket}

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

  # ── Build and proof cells (task 01a06d01 stage 4) ────────────────────
  #
  # The design canvas attached to the task is binding here. Its argument, in
  # one line: a green dot says a socket is up and NOTHING else, so connection
  # age, build age and observed proof are three separate cells that are
  # allowed to disagree on screen. Collapsing them into one indicator is the
  # defect — an agent showed green all evening while running a build with no
  # `meeting_transcript` listener, and two people spent an hour looking at the
  # wrong layer.

  # Human labels for the capabilities the surface always reports, taken
  # verbatim from the canvas wireframe ("chat reply", "transcript",
  # "voice out"). A capability observed under a name outside this map renders
  # under its raw name rather than being hidden — `reported_capabilities/0` is
  # a floor, not an allowlist.
  @capability_labels %{
    "chat_reply" => "chat reply",
    "meeting_transcript" => "transcript",
    "meeting_voice" => "voice out"
  }

  # When a capability landed in the plugin. This is the ONLY thing that turns
  # a build cell amber, and it is deliberately much narrower than "behind
  # main": the canvas rejected amber-for-behind-main outright, because every
  # merge would make the whole fleet amber and the column would be ignored
  # inside a week.
  #
  # `meeting_transcript` landed with the plugin's `63229eb` on 3 Sep 2026 (the
  # date the canvas prints in the warning string). The build immediately
  # before it, `b238164e`, cannot hear a meeting — and both builds report
  # package.json `0.3.0` and an identical `CLIENT_FEATURES`, which is why the
  # declared list below the hairline cannot answer this and a date can.
  @capability_landed_at %{
    "meeting_transcript" => ~U[2026-09-03 00:00:00Z]
  }

  # Truncated to 7 characters per the canvas: the sha is the field an operator
  # pastes into an incident note, and it is FIRST to give up width because its
  # human-readable twin (the age) is already on the row.
  #
  # A client that never told us its build reports the literal "unknown" —
  # never a blank, never a dash, and never a borrowed `version`.
  defp build_sha(%{client_build: build}) when is_binary(build) and build != "",
    do: String.slice(build, 0, 7)

  defp build_sha(_), do: "unknown"

  # The build cell's second half, in words rather than a timestamp, because
  # this is the half that gets skimmed. Reads "6 days old" beside the
  # connection cell's "20s ago" — which is the sentence nobody could read on
  # the night this ticket was filed.
  defp build_age(%{process_started_at: %DateTime{} = started}) do
    format_uptime(DateTime.diff(DateTime.utc_now(), started, :second))
  end

  defp build_age(_), do: "age unknown"

  defp format_uptime(seconds) when seconds < 60, do: pluralise(seconds, "second")
  defp format_uptime(seconds) when seconds < 3600, do: pluralise(div(seconds, 60), "minute")
  defp format_uptime(seconds) when seconds < 86_400, do: pluralise(div(seconds, 3600), "hour")
  defp format_uptime(seconds), do: pluralise(div(seconds, 86_400), "day")

  defp pluralise(1, unit), do: "1 #{unit} old"
  defp pluralise(n, unit), do: "#{n} #{unit}s old"

  # Capabilities this runtime is expected to serve whose code CANNOT be in the
  # running process, because the process started before that code existed.
  #
  # The inference is one-way on purpose. A process that started before a
  # capability landed definitely predates it; a process that started after it
  # may still be running old code, and that case stays quiet rather than
  # guessing. False amber would destroy the column, a false quiet costs
  # nothing that the `never` in the proof cell does not already say.
  #
  # "Expected to serve" is `reported_capabilities/0` — the set core reports a
  # cell for on every runtime.
  defp predated_capabilities(%{process_started_at: %DateTime{} = started}) do
    expected = RuntimePresence.reported_capabilities()

    @capability_landed_at
    |> Enum.filter(fn {capability, landed_at} ->
      capability in expected and DateTime.compare(started, landed_at) == :lt
    end)
    |> Enum.sort_by(fn {capability, _} -> capability end)
    |> Enum.map(fn {capability, landed_at} ->
      %{capability: capability, landed_label: Calendar.strftime(landed_at, "%-d %b")}
    end)
  end

  defp predated_capabilities(_), do: []

  # One row per capability, ABOVE the hairline. Everything here is an event
  # core observed arriving from this runtime; nothing here is a setting.
  #
  # A capability core has never observed keeps its row and reads `never`. The
  # absent row is the blind spot this ticket exists to close: "transcript
  # never" beside a green dot is the line that would have ended the incident
  # in ten seconds, and it only exists because the row is not omitted.
  defp proof_rows(runtime) do
    proven = Map.get(runtime, :proven) || %{}
    expected = RuntimePresence.reported_capabilities()

    observed_elsewhere =
      proven
      |> Map.keys()
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 in expected))
      |> Enum.sort()

    Enum.map(expected ++ observed_elsewhere, fn capability ->
      %{
        capability: capability,
        label: Map.get(@capability_labels, capability, capability),
        value: proof_value(Map.get(proven, capability))
      }
    end)
  end

  defp proof_value(%DateTime{} = at), do: format_dt(at)
  defp proof_value(_), do: "never"

  # What the runtime CLAIMED, rendered BELOW the hairline in info blue. A
  # declaration is information, not a promise: it is asserted by the very
  # process whose competence is in question, and measured across the boundary
  # that motivated this ticket it does not change at all.
  defp declared_chips(%{declared_features: features}) when is_list(features) do
    Enum.filter(features, &is_binary/1)
  end

  defp declared_chips(_), do: []

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
