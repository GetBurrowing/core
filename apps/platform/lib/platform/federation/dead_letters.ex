defmodule Platform.Federation.DeadLetters do
  @moduledoc """
  Context for the durable federation dead-letter ledger (task 019fa56b-ca2d).

  Replaces `Platform.Federation.DeadLetterBuffer`, a 50-entry in-process list
  that lost its contents on every BEAM restart and — because responsibility
  drops shared it with chat drops — had already partially overwritten the
  2026-07-27 evidence by the time that day's audit read it.

  ## What a row is for

  This ledger is a WORK QUEUE, not a log. `pending` rows are the replay backlog
  stage 3 drains; the terminal dispositions record where each loss went. Two
  consequences follow and both are deliberate:

    * `record/1` DEDUPES pending fires for the same `{runtime_id,
      responsibility_key, subject_id}` via the table's partial unique index.
      Queueing the same stage's audit twice would replay it twice.
    * `prune/1` deletes old TERMINAL rows and never touches `pending` /
      `replaying`.

  Both are correct for a queue and both destroy a cumulative measure, which is
  exactly why stage 4 adds a separate counter table rather than counting rows
  here. Counting off this ledger would reproduce the shrinking-number defect
  this ticket exists to correct, one level down.

  ## The cumulative counters (stage 4)

  `federation_dead_letter_stats` is incremented from `record/1` and `mark/3`
  and is never pruned. `recorded` counts ARRIVALS — every `record/1` attempt,
  including the ones the index above collapsed — and the terminal-disposition
  counters record where those losses went, so:

      recorded == replayed + dropped_policy + dropped_stale
                + superseded_duplicate + abandoned + <live ledger rows>

  `loss_summary/0` returns those terms and asserts the balance in its
  `:balanced` field, which is what makes the invariant checkable by a human
  rather than only by a test.

  Two consequences of that shape are worth naming, because both are the sort of
  thing a later reader "simplifies" back:

    * A DEDUPED `record/1` bumps `superseded_duplicate`. The second fire was
      real and was collapsed into an existing pending row; `superseded_duplicate`
      is the vocabulary word for exactly that, and without it the loss would be
      counted in `recorded` with nowhere to land, unbalancing the books.
    * A mark to a LIVE disposition bumps nothing. Stage 3's drain reverts a
      claim to `pending` whenever a runtime vanishes mid-delivery, so a
      cumulative `pending`/`replaying` would count flaps. The live term is read
      from the ledger instead — sound precisely because `prune/1` cannot delete
      a live row.

  ## The jsonb atom round-trip

  The live signal carries ATOM values — `reason: :system_event`,
  `trigger_kind: :cron` — and atom keys. Postgres jsonb gives back strings for
  both. `to_envelope/1` restores them through `String.to_existing_atom/1` over
  fixed whitelists (`@signal_keys`, `@metadata_keys`, `@reason_values`,
  `@trigger_kind_values`). Never `String.to_atom/1`: this data crossed a
  serialization boundary and an unbounded atom table is a denial-of-service
  surface, not a convenience. Anything outside a whitelist is left as the
  string it arrived as rather than guessed at.
  """

  import Ecto.Query

  require Logger

  alias Platform.Federation.DeadLetter
  alias Platform.Federation.DeadLetterStat
  alias Platform.Repo

  # Arbiter for the table's partial unique index. Must restate the index
  # predicate verbatim so Postgres can infer it; rows whose disposition is not
  # `pending` (chat drops, for instance) simply never match it.
  @pending_conflict_target {:unsafe_fragment,
                            "(runtime_id, responsibility_key, subject_id) " <>
                              "WHERE disposition = 'pending' AND subject_id IS NOT NULL"}

  # ── Atom-restoration whitelists ─────────────────────────────────────
  #
  # Keys `AgentResponder.build_system_event_signal/2` can emit, and the
  # correlation scalars `Router.put_trigger_scalars/2` whitelists into metadata
  # (`@native_trigger_scalar_keys`). Anything not listed stays a string key.
  @signal_keys ~w(reason agent_id agent_slug responsibility_key feature trigger_kind prompt metadata)a
  @signal_key_strings Enum.map(@signal_keys, &Atom.to_string/1)

  @metadata_keys ~w(responsibility_key feature trigger_kind agent_id agent_slug
                    task_id plan_id stage_id project_id prompt)a
  @metadata_key_strings Enum.map(@metadata_keys, &Atom.to_string/1)

  # `Router.native_reason_for/1` maps every trigger kind to one of these.
  @reason_values ~w(system_event mention)a
  @reason_value_strings Enum.map(@reason_values, &Atom.to_string/1)

  # `Platform.Responsibilities` trigger kinds.
  @trigger_kind_values ~w(cron event_topic webhook chat_pattern)a
  @trigger_kind_value_strings Enum.map(@trigger_kind_values, &Atom.to_string/1)

  # Subject precedence: the narrowest correlation scalar present wins. A fire
  # about a stage is about that stage even though it also names the plan and
  # task; deduping on the task id would collapse unrelated fires.
  @subject_precedence [{:stage_id, "stage"}, {:plan_id, "plan"}, {:task_id, "task"}]

  @default_prune_days 30
  @default_recent_limit 50

  @doc "The closed disposition vocabulary (delegates to the schema)."
  @spec dispositions() :: [String.t()]
  defdelegate dispositions(), to: DeadLetter

  @doc """
  Record a delivery failure.

  Expects atom-keyed attrs. `disposition` defaults to `"pending"`;
  `occurred_at` defaults to now. Atom values for `:source`, `:reason`,
  `:trigger_kind` and `:disposition` are stringified here so callers can pass
  the live atoms straight through.

  A terminal disposition supplied at write time (the chat path writes
  `dropped_policy` immediately) gets its `dispositioned_at` stamped in the same
  insert — a terminal row with no dispositioned_at would be a lie about when the
  decision was made.

  Duplicate PENDING fires for the same `{runtime_id, responsibility_key,
  subject_id}` collapse into the existing row (`on_conflict: :nothing`).

  Either way the CUMULATIVE counters move: `recorded` always, plus
  `superseded_duplicate` when the ledger deduped, plus the disposition itself
  when the row was written terminal (the chat path). A loss that the queue
  collapses is still a loss.
  """
  @spec record(map()) :: {:ok, DeadLetter.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) when is_map(attrs) do
    changeset = DeadLetter.changeset(%DeadLetter{}, normalize(attrs))

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: @pending_conflict_target) do
      {:ok, row} ->
        count_arrival(row, inserted?(row))
        {:ok, row}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # `Repo.insert(on_conflict: :nothing)` cannot tell a caller whether the row
  # landed: ecto_sql maps both "inserted, nothing returned" and "conflicted,
  # zero rows" to `{:ok, []}` (adapters/sql.ex:1186-1189), and the UUIDv7 pk is
  # generated client-side so the struct carries an id regardless. An explicit
  # pk lookup is the only honest answer, and this path only runs when a
  # delivery has ALREADY failed, so one extra index hit is free.
  defp inserted?(%DeadLetter{id: id}) do
    Repo.exists?(from(d in DeadLetter, where: d.id == ^id))
  end

  @doc """
  Derive the correlation subject from a fire's metadata.

  Returns `%{subject_type: type, subject_id: id}` with both `nil` when the fire
  names no subject — which is the normal case for cron, whose content is "it is
  now T", not "act on X". Accepts atom- or string-keyed metadata so it works
  equally on a live signal and on one rebuilt from jsonb.
  """
  @spec derive_subject(map() | nil) :: %{
          subject_type: String.t() | nil,
          subject_id: String.t() | nil
        }
  def derive_subject(metadata) when is_map(metadata) do
    Enum.find_value(@subject_precedence, %{subject_type: nil, subject_id: nil}, fn {key, type} ->
      case fetch_either(metadata, key) do
        value when is_binary(value) and value != "" -> %{subject_type: type, subject_id: value}
        _ -> nil
      end
    end)
  end

  def derive_subject(_), do: %{subject_type: nil, subject_id: nil}

  @doc """
  Rebuild the broadcast envelope from a row's stored jsonb payload.

  Returns `nil` when the row carries no replayable payload (every `source:
  "chat"` row, by construction). See the moduledoc for the atom-restoration
  rules — the invariant this function owes its callers is
  `to_envelope(record(envelope)) == envelope` for a system_event fire.
  """
  @spec to_envelope(DeadLetter.t()) :: map() | nil
  def to_envelope(%DeadLetter{payload: nil}), do: nil

  def to_envelope(%DeadLetter{payload: payload}) when is_map(payload) do
    case fetch_either(payload, :signal) do
      signal when is_map(signal) -> %{signal: restore_signal(signal)}
      _ -> nil
    end
  end

  def to_envelope(_), do: nil

  @doc """
  Pending rows for one runtime, OLDEST FIRST — replay order is arrival order.

  Options: `:limit` (default unbounded).
  """
  @spec pending_for_runtime(String.t(), keyword()) :: [DeadLetter.t()]
  def pending_for_runtime(runtime_id, opts \\ []) when is_binary(runtime_id) do
    DeadLetter
    |> where([d], d.runtime_id == ^runtime_id and d.disposition == "pending")
    |> order_by([d], asc: d.occurred_at, asc: d.id)
    |> maybe_limit(Keyword.get(opts, :limit))
    |> Repo.all()
  end

  @doc "Most recent rows across all runtimes and dispositions, newest first."
  @spec recent(pos_integer()) :: [DeadLetter.t()]
  def recent(limit \\ @default_recent_limit) do
    DeadLetter
    |> order_by([d], desc: d.occurred_at, desc: d.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Move a row to a new disposition.

  Options: `:reason` (why), `:last_error` (transport detail),
  `:bump_attempts` (increment the DELIVERY counter — marks alone are not
  attempts, so this is opt-in rather than automatic).

  Moving BACK to a live disposition clears `dispositioned_at` rather than
  stamping it, mirroring `record/1`'s rule. Stage 3's drain reverts a claimed
  row to `pending` when a runtime vanishes mid-delivery, and a pending row
  carrying a dispositioned_at would claim a decision that was explicitly
  un-made.
  """
  @spec mark(DeadLetter.t(), String.t() | atom(), keyword()) ::
          {:ok, DeadLetter.t()} | {:error, Ecto.Changeset.t()}
  def mark(%DeadLetter{} = row, disposition, opts \\ []) do
    disposition = stringify(disposition)

    dispositioned_at =
      if disposition in DeadLetter.live_dispositions(), do: nil, else: DateTime.utc_now()

    attrs =
      %{disposition: disposition, dispositioned_at: dispositioned_at}
      |> put_unless_nil(:reason, stringify(Keyword.get(opts, :reason)))
      |> put_unless_nil(:last_error, stringify(Keyword.get(opts, :last_error)))
      |> then(fn attrs ->
        if Keyword.get(opts, :bump_attempts, false) do
          Map.put(attrs, :attempts, (row.attempts || 0) + 1)
        else
          attrs
        end
      end)

    case row |> DeadLetter.changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        count_disposition(row, updated)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Delete TERMINAL rows older than `:days` (default 30).

  Never deletes `pending` or `replaying` — those are the live queue, and a
  cleanup timer that ate them would become the loss it was meant to bound.
  """
  @spec prune(keyword()) :: {:ok, non_neg_integer()}
  def prune(opts \\ []) do
    days = Keyword.get(opts, :days, @default_prune_days)
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    {count, _} =
      DeadLetter
      |> where([d], d.disposition in ^DeadLetter.terminal_dispositions())
      |> where([d], d.occurred_at < ^cutoff)
      |> Repo.delete_all()

    {:ok, count}
  end

  # ── Cumulative counters ─────────────────────────────────────────────

  @doc """
  Every counter row, heaviest first.

  A row is `{runtime_id, responsibility_key, trigger_kind, disposition} ->
  count` with `first_at` / `last_at`. Cardinality is bounded by design (see the
  migration), which is what makes loading the whole table the honest
  implementation rather than a lazy one.
  """
  @spec stats() :: [counter_row()]
  def stats do
    DeadLetterStat
    |> order_by([s], desc: s.count, asc: s.disposition, asc: s.responsibility_key)
    |> Repo.all()
    |> Enum.map(&counter_row/1)
  end

  @doc "Counter rows for one responsibility key."
  @spec stats_for_key(String.t()) :: [counter_row()]
  def stats_for_key(responsibility_key) when is_binary(responsibility_key) do
    DeadLetterStat
    |> where([s], s.responsibility_key == ^responsibility_key)
    |> order_by([s], desc: s.count, asc: s.disposition)
    |> Repo.all()
    |> Enum.map(&counter_row/1)
  end

  @doc """
  Totals per counter, across every runtime and key.

  Every counter in `DeadLetterStat.counters/0` is present, defaulting to 0, so
  a caller never has to distinguish "zero" from "no row yet". The live
  dispositions are deliberately absent — see the moduledoc.
  """
  @spec counter_totals() :: %{String.t() => non_neg_integer()}
  def counter_totals do
    base = Map.new(DeadLetterStat.counters(), &{&1, 0})

    DeadLetterStat
    |> select([s], {s.disposition, s.count})
    |> Repo.all()
    |> Enum.reduce(base, fn {disposition, count}, acc ->
      Map.update(acc, disposition, count, &(&1 + count))
    end)
  end

  @doc """
  How many ledger rows are still LIVE (`pending` or `replaying`).

  Read from the ledger rather than a counter on purpose: this is a state, not
  an outcome, and `prune/1` cannot delete a live row, so the ledger's answer
  here neither shrinks nor drifts.
  """
  @spec outstanding_count() :: non_neg_integer()
  def outstanding_count do
    DeadLetter
    |> where([d], d.disposition in ^DeadLetter.live_dispositions())
    |> Repo.aggregate(:count)
  end

  @doc """
  The cumulative loss picture, with its own accounting check.

  `:balanced` asserts the stage's invariant —

      recorded == replayed + dropped_policy + dropped_stale
                + superseded_duplicate + abandoned + pending

  — so the number a human reads carries its own audit. A `false` here means
  either a counter write was lost or a ledger row moved between dispositions by
  a path that did not go through `mark/3`; both are real defects and neither is
  visible in any single total.

  `:replay_rate` is `replayed / recorded`: of everything ever lost, the share
  that was actually delivered later. It is the one number that answers "is this
  system doing its job", and its denominator is the cumulative arrival count
  precisely so that dropping more fires can never improve it.
  """
  @spec loss_summary() :: %{
          recorded: non_neg_integer(),
          replayed: non_neg_integer(),
          dropped: non_neg_integer(),
          dropped_policy: non_neg_integer(),
          dropped_stale: non_neg_integer(),
          superseded_duplicate: non_neg_integer(),
          abandoned: non_neg_integer(),
          pending: non_neg_integer(),
          accounted: non_neg_integer(),
          balanced: boolean(),
          replay_rate: float()
        }
  def loss_summary do
    totals = counter_totals()
    pending = outstanding_count()

    recorded = totals["recorded"]
    replayed = totals["replayed"]
    dropped_policy = totals["dropped_policy"]
    dropped_stale = totals["dropped_stale"]
    superseded = totals["superseded_duplicate"]
    abandoned = totals["abandoned"]

    accounted = replayed + dropped_policy + dropped_stale + superseded + abandoned + pending

    %{
      recorded: recorded,
      replayed: replayed,
      dropped: dropped_policy + dropped_stale,
      dropped_policy: dropped_policy,
      dropped_stale: dropped_stale,
      superseded_duplicate: superseded,
      abandoned: abandoned,
      pending: pending,
      accounted: accounted,
      balanced: recorded == accounted,
      replay_rate: replay_rate(replayed, recorded)
    }
  end

  @doc """
  The standing operator line, logged daily by `DeadLetterReplay`.

  CUMULATIVE, not windowed, and labelled as such. A windowed figure is what
  failed on 2026-07-27 — an instantaneous read of a time-varying class — and a
  24h window is not recoverable from monotonic counters without storing
  snapshots, while deriving one from the ledger would reinherit both defects
  the counters exist to escape (dedupe undercounts, pruning shrinks). Two
  consecutive daily lines in journald subtract to give the window, which is
  what a monotonic counter is for.
  """
  @spec rollup_line() :: String.t()
  def rollup_line do
    summary = loss_summary()

    "[DeadLetters] cumulative recorded=#{summary.recorded} replayed=#{summary.replayed} " <>
      "dropped_policy=#{summary.dropped_policy} dropped_stale=#{summary.dropped_stale} " <>
      "superseded_duplicate=#{summary.superseded_duplicate} abandoned=#{summary.abandoned} " <>
      "pending=#{summary.pending} top_key=#{top_key()} balanced=#{summary.balanced} " <>
      "(since inception — diff consecutive lines for a window)"
  end

  @typedoc "One cumulative counter row."
  @type counter_row :: %{
          runtime_id: String.t(),
          responsibility_key: String.t() | nil,
          trigger_kind: String.t() | nil,
          disposition: String.t(),
          count: non_neg_integer(),
          first_at: DateTime.t(),
          last_at: DateTime.t()
        }

  defp counter_row(%DeadLetterStat{} = stat) do
    Map.take(stat, [
      :runtime_id,
      :responsibility_key,
      :trigger_kind,
      :disposition,
      :count,
      :first_at,
      :last_at
    ])
  end

  defp replay_rate(_replayed, 0), do: 0.0
  defp replay_rate(replayed, recorded), do: Float.round(replayed / recorded, 4)

  # The responsibility key with the most ARRIVALS. Unkeyed rows are excluded
  # rather than lumped together: "nil" is not a key an operator can go look at.
  defp top_key do
    recorded = DeadLetterStat.recorded()

    DeadLetterStat
    |> where([s], s.disposition == ^recorded and not is_nil(s.responsibility_key))
    |> select([s], {s.responsibility_key, s.count})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {key, count}, acc -> Map.update(acc, key, count, &(&1 + count)) end)
    |> Enum.max_by(fn {_key, count} -> count end, fn -> nil end)
    |> case do
      {key, _count} -> key
      nil -> "none"
    end
  end

  # ── Counter writes ──────────────────────────────────────────────────

  # Bare column list, NOT an `{:unsafe_fragment, ...}`. The counter index has
  # no predicate, so Postgres infers it from the columns alone — the
  # restatement the pending index needs is a consequence of that index being
  # PARTIAL, not of it being unique. Verified against Postgres 16 (CI's
  # `postgres:16-alpine`) that inference also resolves a NULLS NOT DISTINCT
  # index this way.
  @counter_conflict_target [:runtime_id, :responsibility_key, :trigger_kind, :disposition]

  defp count_arrival(%DeadLetter{} = row, inserted?) do
    bump(row, DeadLetterStat.recorded())

    cond do
      # The ledger collapsed this fire into an existing pending row. It still
      # happened, and `superseded_duplicate` is the vocabulary word for a fire
      # folded into another — stage 3 left it unwritten because the partial
      # index makes the drain-time collapse unreachable, and this is where it
      # actually occurs.
      not inserted? ->
        bump(row, "superseded_duplicate")

      # Written terminal at capture time — the chat path's
      # `dropped_policy` / `chat_payload_not_replayable`. It never becomes a
      # ledger row `mark/3` will see, so it must be counted here or its loss
      # would have no outcome and the books would not balance.
      row.disposition in DeadLetter.terminal_dispositions() ->
        bump(row, row.disposition)

      true ->
        :ok
    end

    :telemetry.execute(
      [:platform, :federation, :dead_letter, :recorded],
      %{count: 1},
      %{
        runtime_id: row.runtime_id,
        responsibility_key: row.responsibility_key,
        trigger_kind: row.trigger_kind,
        disposition: row.disposition,
        deduped: not inserted?
      }
    )
  end

  # A counter moves only on the FIRST live -> terminal transition. That guard
  # is what survives a re-mark of a settled row and what keeps stage 3's
  # claim/revert cycle (`pending` -> `replaying` -> `pending`) from inflating
  # anything.
  defp count_disposition(%DeadLetter{disposition: from}, %DeadLetter{disposition: to} = updated) do
    if from in DeadLetter.live_dispositions() and to in DeadLetter.terminal_dispositions() do
      bump(updated, to)

      :telemetry.execute(
        [:platform, :federation, :dead_letter, :dispositioned],
        %{count: 1},
        %{
          runtime_id: updated.runtime_id,
          responsibility_key: updated.responsibility_key,
          trigger_kind: updated.trigger_kind,
          disposition: to
        }
      )
    end

    :ok
  end

  defp bump(%DeadLetter{} = row, counter) do
    if counter in DeadLetterStat.counters() do
      now = DateTime.utc_now()

      %DeadLetterStat{
        runtime_id: row.runtime_id,
        responsibility_key: row.responsibility_key,
        trigger_kind: row.trigger_kind,
        disposition: counter,
        count: 1,
        first_at: now,
        last_at: now
      }
      |> Repo.insert(
        # `first_at` is deliberately NOT in `set:` — it records when this class
        # of loss was first seen and must not follow the latest one.
        on_conflict: [inc: [count: 1], set: [last_at: now, updated_at: now]],
        conflict_target: @counter_conflict_target
      )

      :ok
    else
      Logger.error("[DeadLetters] refusing to bump unknown counter #{inspect(counter)}")
      :ok
    end
  rescue
    # The measure must never take down the capture. A dead letter that was
    # recorded but not counted is a bookkeeping hole (`loss_summary/0` will
    # report `balanced: false`); a counter write that propagated out of
    # `record/1` would crash `AgentResponder`'s offline branch and lose the
    # fire itself, which is strictly worse and is the failure this whole task
    # exists to end.
    exception ->
      Logger.error(
        "[DeadLetters] counter bump failed for #{counter}: #{Exception.message(exception)}"
      )

      :ok
  end

  # ── Internals ───────────────────────────────────────────────────────

  defp normalize(attrs) do
    disposition = stringify(Map.get(attrs, :disposition)) || "pending"
    occurred_at = Map.get(attrs, :occurred_at) || DateTime.utc_now()

    attrs = Map.merge(attrs, derive_subject_defaults(attrs))

    attrs
    |> Map.put(:disposition, disposition)
    |> Map.put(:occurred_at, occurred_at)
    |> Map.put(:source, stringify(Map.get(attrs, :source)))
    |> Map.put(:reason, stringify(Map.get(attrs, :reason)))
    |> Map.put(:trigger_kind, stringify(Map.get(attrs, :trigger_kind)))
    |> Map.put(:subject_type, stringify(Map.get(attrs, :subject_type)))
    |> Map.put(:dispositioned_at, dispositioned_at(disposition, attrs, occurred_at))
  end

  # Callers may pass an explicit subject (the AgentResponder does, from the
  # fire's metadata). Only fall back to deriving when neither key is present at
  # all — an explicit `subject_type: nil` is a statement, not an omission.
  defp derive_subject_defaults(attrs) do
    if Map.has_key?(attrs, :subject_type) or Map.has_key?(attrs, :subject_id) do
      %{}
    else
      derive_subject(Map.get(attrs, :metadata))
    end
  end

  defp dispositioned_at(disposition, attrs, occurred_at) do
    cond do
      value = Map.get(attrs, :dispositioned_at) -> value
      disposition in DeadLetter.live_dispositions() -> nil
      disposition in DeadLetter.dispositions() -> occurred_at
      true -> nil
    end
  end

  defp restore_signal(signal) do
    signal
    |> atomize_keys(@signal_key_strings)
    |> update_existing(:reason, &restore_atom(&1, @reason_value_strings))
    |> update_existing(:trigger_kind, &restore_atom(&1, @trigger_kind_value_strings))
    |> update_existing(:metadata, &restore_metadata/1)
  end

  defp restore_metadata(metadata) when is_map(metadata) do
    metadata
    |> atomize_keys(@metadata_key_strings)
    |> update_existing(:trigger_kind, &restore_atom(&1, @trigger_kind_value_strings))
  end

  defp restore_metadata(other), do: other

  defp atomize_keys(map, allowed_strings) do
    Map.new(map, fn {key, value} -> {restore_key(key, allowed_strings), value} end)
  end

  defp restore_key(key, _allowed) when is_atom(key), do: key

  defp restore_key(key, allowed) when is_binary(key) do
    if key in allowed, do: String.to_existing_atom(key), else: key
  end

  defp restore_key(key, _allowed), do: key

  defp restore_atom(value, allowed) when is_binary(value) do
    if value in allowed, do: String.to_existing_atom(value), else: value
  end

  defp restore_atom(value, _allowed), do: value

  defp update_existing(map, key, fun) do
    case Map.fetch(map, key) do
      {:ok, value} -> Map.put(map, key, fun.(value))
      :error -> map
    end
  end

  defp fetch_either(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, value) when is_integer(value), do: limit(query, ^value)

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)
end
