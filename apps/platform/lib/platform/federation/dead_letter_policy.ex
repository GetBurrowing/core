defmodule Platform.Federation.DeadLetterPolicy do
  @moduledoc """
  Decides whether a dead-lettered fire may be replayed (task 019fa56b-ca2d).

  A pure decision layer: it reads a `Platform.Federation.DeadLetter` row and
  the state of that row's SUBJECT in Postgres, and returns a verdict. It
  broadcasts nothing, writes nothing, and moves no disposition — stage 3's
  `DeadLetterReplay` consumes this and owns every side effect. The split is
  deliberate: the per-`trigger_kind` ruling is the contested part of this
  ticket and it should be reviewable as a table of rules with tests rather
  than buried inside a GenServer's drain loop.

  ## Default is DENY

  An unrecognised or `nil` `trigger_kind` is `{:drop, :unclassified}`. One
  rule for all kinds is wrong in both directions — replay-everything
  re-audits superseded work and produces a confident verdict about the wrong
  thing, while drop-everything keeps losing the 34 `architecture.audit_diff`
  fires that are the actual complaint.

  ## The ruling

    * `cron` -> `{:drop, :stale_by_wall_clock}`. A cron fire's content is
      "it is now T, do the thing for T". `memory.daily_summary` replayed six
      hours late writes a journal entry dated wrong; `architecture.cron_sweep`
      replayed mid-week is not the weekly sweep. Decisively, cron is
      SELF-HEALING in a way `event_topic` is not: the Router's tick
      (`cron_next_fire` / `cron_last_fire`) refires the same responsibility on
      its own schedule, so the work is late, not lost, and a replay would
      duplicate a fire that is already coming.

    * `event_topic` -> `:replay`, but only when a freshness predicate is
      registered for the row's `responsibility_key` AND that predicate passes.
      These fires are subject-bound (`stage_id`, `plan_id`) and the subject
      persists in Postgres, which is what makes "is this still worth doing?"
      an answerable question. A key with no registered predicate is
      `{:drop, :no_freshness_predicate}` — replaying blind is precisely the
      failure the freshness rule exists to prevent, and an unregistered key is
      one nobody has reasoned about yet.

    * `webhook` -> `{:drop, :unvalidated_kind}`. Production has ZERO
      webhook-triggered responsibility rows, so there is no real subject shape
      to write a predicate against and no way to exercise a replay path for
      it. Shipping replay for a kind that cannot be tested is how a
      confident-but-wrong replay gets built. Counted and visible; revisit when
      the first webhook row exists.

    * `chat_pattern`, and ANY row with `source == "chat"` ->
      `{:drop, :chat_payload_not_replayable}`. The chat envelope is DERIVED
      (ContextPlane bundle + message history + the live tool surface), not
      scalar; replaying a stored copy would replay a stale context bundle. The
      correct fix is to rebuild from the persisted `message_id` at replay
      time, which is a different design and a different task. Note
      `Router.native_reason_for(:chat_pattern)` returns `:mention`, so these
      never reach `broadcast_system_event/3` at all — they arrive through
      `dispatch_to_external/2` and carry no stored payload by construction.

  ## `:no_replayable_payload` is an addition to the planned vocabulary

  The plan's table does not name it. It exists because `classify/1` is the
  only place that can answer "is there anything to send?" without the drain
  loop learning the payload's shape: a row whose jsonb cannot rebuild an
  envelope (`DeadLetters.to_envelope/1` returns `nil`) has nothing to
  broadcast no matter how fresh its subject is. Without this clause stage 3
  would classify `:replay` and then broadcast `nil`.

  ## Two drop CLASSES, because they are different facts

  `drop_reasons/0` partitions into `policy_drop_reasons/0` — "we never replay
  this kind" — and `stale_drop_reasons/0` — "we would have, but this one fire
  aged out". `disposition_for/1` maps a reason to the `dropped_policy` /
  `dropped_stale` disposition stage 3 records, so the drain loop never
  hardcodes its own copy of the split (a guard that re-declares a closed list
  is how the class comes back; same argument as
  `Plan.architecture_gate_states/0`).
  """

  alias Platform.Federation.DeadLetter
  alias Platform.Federation.DeadLetters
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stage

  # The kind or key is refused outright. Nothing about the individual fire
  # could have made it replayable.
  @policy_drop_reasons ~w(stale_by_wall_clock unvalidated_kind chat_payload_not_replayable
                          no_freshness_predicate no_replayable_payload unclassified)a

  # The kind IS replayable; this particular fire's subject moved on.
  @stale_drop_reasons ~w(subject_superseded gate_already_settled)a

  @drop_reasons @policy_drop_reasons ++ @stale_drop_reasons

  # The registry IS the dispatch table — a `{module, function}` tuple rather
  # than a captured fun so it survives as a module attribute, and so a key
  # listed here cannot drift away from the predicate that serves it.
  @freshness_predicates %{
    "architecture.audit_diff" => {__MODULE__, :audit_diff_freshness},
    "architecture.review_plan" => {__MODULE__, :review_plan_freshness}
  }

  @type drop_reason ::
          :stale_by_wall_clock
          | :unvalidated_kind
          | :chat_payload_not_replayable
          | :no_freshness_predicate
          | :no_replayable_payload
          | :unclassified
          | :subject_superseded
          | :gate_already_settled

  @type verdict :: :replay | {:drop, drop_reason()}

  @type freshness :: :ok | {:stale, drop_reason()}

  @doc "The closed drop vocabulary. Read this; never re-declare it."
  @spec drop_reasons() :: [drop_reason()]
  def drop_reasons, do: @drop_reasons

  @doc "Drops that refuse the KIND of fire, regardless of the individual row."
  @spec policy_drop_reasons() :: [drop_reason()]
  def policy_drop_reasons, do: @policy_drop_reasons

  @doc "Drops where a freshness predicate found the subject had moved on."
  @spec stale_drop_reasons() :: [drop_reason()]
  def stale_drop_reasons, do: @stale_drop_reasons

  @doc """
  The disposition stage 3 records for a drop reason.

  `"dropped_policy"` for a refused kind, `"dropped_stale"` for an aged-out
  subject. Both are in `DeadLetter.dispositions/0`.
  """
  @spec disposition_for(drop_reason()) :: String.t()
  def disposition_for(reason) when reason in @stale_drop_reasons, do: "dropped_stale"
  def disposition_for(reason) when reason in @policy_drop_reasons, do: "dropped_policy"

  @doc "Responsibility keys with a registered freshness predicate."
  @spec freshness_predicate_keys() :: [String.t()]
  def freshness_predicate_keys, do: Map.keys(@freshness_predicates)

  @doc """
  Rule on one dead-lettered fire.

  Returns `:replay` or `{:drop, reason}` where `reason` is in
  `drop_reasons/0`. Reads the subject from Postgres for the `event_topic`
  path; every other path is a pure function of the row.
  """
  @spec classify(DeadLetter.t()) :: verdict()
  def classify(%DeadLetter{source: "chat"}), do: {:drop, :chat_payload_not_replayable}

  def classify(%DeadLetter{} = row) do
    case normalize_kind(row.trigger_kind) do
      "cron" -> {:drop, :stale_by_wall_clock}
      "webhook" -> {:drop, :unvalidated_kind}
      "chat_pattern" -> {:drop, :chat_payload_not_replayable}
      "event_topic" -> classify_event_topic(row)
      _other -> {:drop, :unclassified}
    end
  end

  defp normalize_kind(kind) when is_atom(kind) and not is_nil(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind
  defp normalize_kind(_), do: nil

  defp classify_event_topic(%DeadLetter{} = row) do
    cond do
      is_nil(DeadLetters.to_envelope(row)) ->
        {:drop, :no_replayable_payload}

      predicate = Map.get(@freshness_predicates, row.responsibility_key) ->
        {module, function} = predicate

        case apply(module, function, [row]) do
          :ok -> :replay
          {:stale, reason} -> {:drop, reason}
        end

      true ->
        {:drop, :no_freshness_predicate}
    end
  end

  # ── Freshness predicates ─────────────────────────────────────────────
  #
  # Public with `@doc false` so the registry above can dispatch to them; they
  # are not part of this module's contract. Each answers exactly one question:
  # would the work this fire asked for still be about the thing it named?
  #
  # Every predicate FAILS CLOSED. A subject that cannot be resolved is
  # `{:stale, :subject_superseded}` rather than a replay, because "we cannot
  # prove this is current" and "this is current" must not produce the same
  # action — a replay on an unprovable subject is the confident-verdict-about-
  # the-wrong-thing outcome the whole policy exists to prevent.
  #
  # `subject_id` is guarded with `Platform.UUID.valid?/1` before its lookup
  # even though the column is a `:binary_id`: `classify/1` takes a STRUCT, and
  # a caller holding a hand-built one would otherwise turn a malformed id into
  # an `Ecto.Query.CastError` raised out of stage 3's drain loop — which aborts
  # the drain for that runtime, so one bad row would withhold every good one.
  # `stage.plan_id` and `plan.task_id` need no guard: both are NOT NULL uuid
  # FK columns read off a row Postgres just returned.

  @doc false
  @spec audit_diff_freshness(DeadLetter.t()) :: freshness()
  def audit_diff_freshness(%DeadLetter{subject_type: "stage", subject_id: id})
      when is_binary(id) do
    with true <- Platform.UUID.valid?(id),
         %Stage{} = stage <- Repo.get(Stage, id),
         # A stage since reset to `running` is being re-executed, and the diff
         # the fire was about is no longer the diff that stage produces.
         "passed" <- stage.status,
         %Plan{} = plan <- Repo.get(Plan, stage.plan_id),
         # The same currency check commit ca2d183c landed for the rollup merge
         # gate: `current_plan/1` rather than a hand-rolled status filter,
         # which is what catches a plan replaced after a rejection.
         %Plan{id: current_id} <- Tasks.current_plan(plan.task_id),
         true <- current_id == stage.plan_id,
         %Tasks.Task{} = task <- Repo.get(Tasks.Task, plan.task_id),
         false <- task.status == "cancelled" do
      :ok
    else
      _ -> {:stale, :subject_superseded}
    end
  end

  def audit_diff_freshness(%DeadLetter{}), do: {:stale, :subject_superseded}

  @doc false
  @spec review_plan_freshness(DeadLetter.t()) :: freshness()
  def review_plan_freshness(%DeadLetter{subject_type: "plan", subject_id: id})
      when is_binary(id) do
    if Platform.UUID.valid?(id) do
      case Repo.get(Plan, id) do
        nil -> {:stale, :subject_superseded}
        %Plan{} = plan -> review_plan_freshness_for(plan)
      end
    else
      {:stale, :subject_superseded}
    end
  end

  def review_plan_freshness(%DeadLetter{}), do: {:stale, :subject_superseded}

  # Order matters, and it is by SPECIFICITY of the fact reported. A newer
  # version existing is the coarser statement, so it is checked first; a
  # settled gate is checked before the plan's own status because when both
  # apply ("approved after the architect passed it") the gate is the more
  # informative reason for an operator reading the ledger.
  defp review_plan_freshness_for(%Plan{} = plan) do
    cond do
      not latest_version?(plan) ->
        {:stale, :subject_superseded}

      # `Tasks.architecture_gate/1`, NOT `plan.architecture_verdict["state"]`.
      # The gate read is level-triggered: a `pending` verdict whose
      # `deadline_at` has passed reports as expired without having been
      # written. That case is the norm here rather than an edge — the runtime
      # was offline, and the 15-minute deadline very likely elapsed while it
      # was. Reading the raw column would replay a review every other reader
      # in the system already considers settled.
      match?({:resolved, _}, Tasks.architecture_gate(plan.id)) ->
        {:stale, :gate_already_settled}

      plan.status != "pending_review" ->
        {:stale, :subject_superseded}

      true ->
        :ok
    end
  end

  defp latest_version?(%Plan{} = plan) do
    case Tasks.latest_plan(plan.task_id) do
      %Plan{id: id} -> id == plan.id
      _ -> false
    end
  end
end
