defmodule Platform.Architecture.StageAudit do
  @moduledoc """
  The whole vocabulary for `stages.architecture_audit` (task `019fa61c`).

  No other module reads or writes that column, exactly as
  `Platform.Tasks`' architecture-gate section (`tasks.ex:2252-2259`) is
  the only vocabulary for `plans.architecture_verdict`. Two modules
  writing one column with two shapes is how the architect's two surfaces
  drifted apart in the first place.

  ## What this stage adds, and what it does not

  `open_from_fire/2` records that a fire HAPPENED. It is called from
  `Platform.Tasks.PlanEngine.after_stage_completed/1` on every branch of
  the `architecture.audit_diff` fire, so the three outcomes an operator
  cares about stop being byte-identical — today they are all `nil`.

  `record_note/3` records the RESULT. It is the ONLY writer of a
  `"noted"` audit: the `stage_architecture_audit` MCP tool calls it with
  `source: "mcp"`, and `Handlers.ArchitectureAuditDiff.handle_output/3`
  calls it with `source: "handle_output"`. Two paths, one writer.

  ## On the external path the ANSWER arrives before the record of the FIRE

  Measured while converging the second path (stage 4), because it is the
  opposite of the order the code reads in. `after_stage_completed/1`
  (`plan_engine.ex:606`) calls `Responsibilities.fire/2` and only THEN
  `open_from_fire/2` — but for an `kind: "external"` assignee the whole
  round trip is synchronous inside that fire: `run_external_dispatch/5`
  gets the HTTP body back and calls `invoke_handle_output/3`
  (`router.ex:1106`) before `fire/2` has returned anything at all. So the
  handler reaches `record_note/3` while the column is still `NULL`, and
  the engine's `open_from_fire/2` lands AFTERWARDS, on a row that by then
  holds the note.

  Two consequences, both load-bearing:

    1. The handler opens the audit itself (`open_from_fire(stage,
       {:ok, :dispatched})`) before recording — it is holding parsed
       output, so a dispatch demonstrably happened, and the row it writes
       is the same one the engine would have written moments later.
    2. `open_from_fire/2` **must not clobber a `"noted"` audit**, or the
       engine's trailing write would erase the note the handler just
       landed. The guard is in the UPDATE's own predicate rather than a
       read-then-write, so it holds for the real ordering as well as the
       reversed one. A result outranks the record of the dispatch that
       produced it.

  Without (2) the convergence is worse than the bug it replaces: the
  external path would post an annotation, record a note, and then
  silently overwrite it with `"pending"` — an audit that shows as
  unanswered while its answer sits in the execution space.

  ## `record_note/3` writes the row and posts the note, or does neither

  The defect this column exists to remove was an architect that produced
  a side effect nobody could count. Recording the row without posting the
  note would give an operator a number with nothing behind it; posting
  the note without recording the row is exactly today's bug. So both
  happen inside ONE `Repo.transaction/1`: the guarded `UPDATE` runs, the
  annotation is posted through `post_annotation/2`, and a failure of
  either rolls the other back. A stage whose task has no execution space
  is therefore REFUSED (`{:error, {:annotation_not_posted, ...}}`) rather
  than silently recorded — the audit stays open and expires, which is a
  true statement about a note that never landed.

  ## Why the annotation formatter lives HERE and not on the handler

  `format_annotation/1` and `post_annotation/2` started as privates on
  `Handlers.ArchitectureAuditDiff`. They are public here because the MCP
  path has to emit a byte-identical line — the `"[architect | audit_diff] "`
  prefix is what the execution-space reader (and
  `architecture_dispatch_test.exs`) greps for, and a second copy of the
  prefix in a second module is precisely how the two architect surfaces
  drifted apart in the first place.

  ## Why a successful dispatch records `"pending"`, not `"noted"`

  `Platform.Design.PreplanStep`'s argument, verbatim
  (`preplan_step.ex:30-46`): dispatch accepted is not output captured.
  The Router's own honesty limit says so — `call_agent_responder/1`
  (`router.ex:1549`) returns `{:ok, :dispatched}` meaning the HANDOFF was
  accepted, and on the native path there is no return value at all. If a
  successful handoff recorded `"noted"`, every subsequent silence would
  be indistinguishable from a win, which is precisely the invisibility
  this column exists to remove. So a dispatched fire stays OPEN and the
  audit is closed later by whoever actually answers — or by the deadline
  projection below, if nobody does.

  ## The mapping is borrowed, never re-derived

  `open_from_fire/2` takes the RAW result of `Platform.Responsibilities.fire/2`
  and maps it through `Platform.Responsibilities.outcome/1` (ADR-0046
  member 1), which is the single shared surface for that mapping and says
  so in its own `@doc`. Task `019f9b29-5ecd` stage 4's first detonation
  was exactly a re-laundered copy of this mapping, which made a crashed
  designer indistinguishable from an absent one. There is no second copy
  here:

      :complete        -> "pending"
      :not_applicable  -> "skipped"
      :failed          -> "failed"

  `reason` is a DISCRIMINATOR, not a second outcome mapping. `outcome/1`
  collapses `:unfilled` and `:unknown_responsibility` onto
  `:not_applicable` on purpose — the ADR merged them — but collapsing
  them in the RECORD would recreate the invisibility one level down, so
  `fire_reason/1` keeps them apart in a field no reader branches on for
  control flow. `PreplanStep`'s `"no_ui_surface"` vs `"no_designer"`
  split (`preplan_step.ex:56-64`) is the precedent. A reviewer skimming
  `fire_reason/1` will read it as a fork of the outcome mapping; it is
  not, and the two functions take different arguments for that reason.

  ## `outcome/1` can raise, and this runs inside a transaction

  `outcome/1` has no catch-all clause, by design, and its `@doc` warns
  about this exact call site: `after_stage_completed/1` runs inside
  `PlanEngine.evaluate_validation/2`'s Ecto transaction, where a raise
  rolls back the validation update itself. So the mapping is wrapped, and
  an unrecognised fire shape is written as `state: "failed"` with
  `reason: "outcome_unmapped:" <> inspect(result)` plus a `:warning`.
  Writing NOTHING on rescue would restore the invisibility this task
  exists to remove — a fire contract that grew a new value would go back
  to looking like no fire at all.

  ## `read/1` is level-triggered and never writes

  A `"pending"` row past its `deadline_at` — or with a missing or
  unparseable one — PROJECTS as
  `%{"state" => "expired", "source" => "deadline"}` without persisting
  anything. `Platform.Tasks.Stage` makes `"expired"` unrepresentable in
  the persisted enum for the same reason.

  `Tasks.architecture_gate/1` (`tasks.ex:2316-2349`) argues this at
  length for the plan gate, citing a live production incident from the
  2026-07-26 journal: `deploying -> done` lived solely in an
  edge-triggered PubSub handler with no level re-check, and a container
  restart between the broadcast and the handler stranded a completed task
  indefinitely. The level check is the correctness guarantee; an eager
  timer is only an optimisation. We ship ONLY the level check — no new
  GenServer, no new timer, nothing to lose on a restart.

  The row is always re-read from the database, even when handed a
  `%Stage{}`. A caller holding a struct loaded before the note landed
  would otherwise get a stale answer, and this is the function every
  other module asks the question through.

  ## `coverage/1` counts off the STAGE ROWS, never off a buffer

  Stage 5. The reader is the operator loop that FOUND this bug — the
  query-production-and-count pass that produced "28 broadcasts, zero
  rows" and "verdicts 4 -> 9, mcp-sourced 2 -> 7". That loop had nothing
  to count for `audit_diff`; `coverage/1` gives it a number with a
  checkable invariant.

  Sibling task `019fa56b-ca2d` refused to derive its `loss_summary/0`
  from the dead-letter LEDGER, because that ledger dedupes on write and
  prunes on age: a total read off it shrinks silently as history ages
  out, which is this task's defect reproduced one layer down — a falling
  number that looks like an improving system. It counted off monotonic
  counters instead.

  The same argument picks `stages` here. Stage rows are never deduped and
  never pruned, and `open_from_fire/2` writes the audit inside
  `evaluate_validation/2`'s transaction — the same transaction as the
  stage transition — so a recorded fire cannot outlive a rolled-back
  stage or vice versa. `dispatched` is therefore derivable from the SAME
  rows as every other bucket, which is what makes

      dispatched == pending + noted + expired + skipped + failed

  a real invariant rather than a comparison of two independently drifting
  numbers. **Do not "optimise" this into an `Enum.count` over a cache,
  an ETS table, or a counter series.** A cache that evicts, or a counter
  that is incremented from a second call site, breaks the equality in the
  direction nobody investigates: quietly downward.

  `expired` comes from `classify_audit/1` — the same level projection
  `read/1` uses — and never from a persisted `"expired"`, which
  `Platform.Tasks.Stage` makes unrepresentable. That is the point of the
  whole function: an architect runtime that is receiving nothing shows up
  as a RISING `expired` count instead of as silence. After this, a
  responsibility firing into a void stops looking identical to one that
  works.

  A row whose audit map carries no recognised `"state"` is counted in
  `dispatched` and lands in NO bucket, so `balanced?` goes false and a
  `:warning` names the stage. That is deliberate: every writer here goes
  through `Stage.architecture_audit_changeset/2`, so an unbucketable row
  means something bypassed the write surface, and the invariant is the
  only thing that would ever notice. Rounding it into a bucket would make
  `balanced?` unfalsifiable, which is worth less than nothing.
  """

  import Ecto.Query

  require Logger

  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Task, as: TaskSchema

  # The literal every execution-space reader greps for. ONE copy, in the
  # module both write paths go through.
  @annotation_prefix "[architect | audit_diff] "

  # 30 minutes. An `audit_diff` fire asks an architect to read one
  # stage's diff against the planned shape — less reading than the plan
  # gate's whole-plan review, but the same order of magnitude, and this
  # deadline holds nothing up, so erring long costs only latency in the
  # coverage numbers. Overridable per-environment because the e2e cases
  # need it near zero.
  @default_timeout_ms 30 * 60 * 1_000

  # The five buckets `coverage/1` accounts every dispatched fire into.
  # Four are persisted states from `Stage.architecture_audit_states/0`;
  # `:expired` is the level projection and exists in no enum anywhere,
  # which is why this list is not derived from that accessor. Every
  # `dispatched` row must land in exactly one of these or `balanced?`
  # is false.
  @coverage_buckets ~w(pending noted expired skipped failed)a

  @doc """
  How long an open audit has before `read/1` projects it as expired.

  Configure with `config :platform, architecture_audit_timeout_ms: <ms>`.
  Mirrors `Platform.Tasks.architecture_gate_timeout_ms/0`.
  """
  @spec timeout_ms() :: pos_integer()
  def timeout_ms do
    Application.get_env(:platform, :architecture_audit_timeout_ms, @default_timeout_ms)
  end

  @doc """
  Record the outcome of one `architecture.audit_diff` fire on its stage.

  Takes the RAW `Platform.Responsibilities.fire/2` result — not a
  pre-mapped outcome — so the mapping stays single-sourced in
  `Responsibilities.outcome/1`.

  Writes every key in `Stage.architecture_audit_required_keys/0`,
  explicitly nil where there is no value yet. `resolved_at` is stamped
  for the two TERMINAL states (`"skipped"`, `"failed"`) and left nil for
  `"pending"`, which is still open.

  Goes through `Stage.architecture_audit_changeset/2`, so it cannot move
  the stage's `status` even by accident.

  **Never overwrites a `"noted"` audit.** The UPDATE carries its own
  predicate, so this holds under the real external ordering — where the
  note lands BEFORE the engine records the fire (see the moduledoc) — and
  not merely under a read-then-write that assumed the friendlier order.
  Declining returns `{:error, :audit_already_noted}` and logs at `:info`;
  the row keeps the answer. Every other state (`NULL`, `"pending"`,
  `"skipped"`, `"failed"`) is overwritten, because a fresh dispatch of a
  stage nobody answered is genuinely a fresh audit.

  **Total by construction.** Every failure mode logs and returns an error
  tuple; nothing here raises. The caller is inside
  `evaluate_validation/2`'s transaction and its own rescue backstop would
  swallow a raise into "no row written", which is the state this function
  exists to make impossible.
  """
  @spec open_from_fire(Stage.t(), term()) :: {:ok, Stage.t()} | {:error, term()}
  def open_from_fire(%Stage{} = stage, fire_result) do
    now = DateTime.utc_now()
    {state, reason} = classify_fire(fire_result, stage)

    audit = %{
      "state" => state,
      "stage_id" => stage.id,
      "task_id" => task_id_for(stage),
      "plan_id" => stage.plan_id,
      "dispatched_at" => DateTime.to_iso8601(now),
      "deadline_at" => DateTime.to_iso8601(DateTime.add(now, timeout_ms(), :millisecond)),
      # Open audits carry no resolution yet; terminal ones resolved the
      # moment they were classified, since nothing further will arrive.
      "resolved_at" => if(state == "pending", do: nil, else: DateTime.to_iso8601(now)),
      # `source` names the CHANNEL a RESULT arrived through. A fire is not
      # a result, so it is nil here for every state — including the
      # terminal ones, which were decided by the Router rather than
      # answered by anybody.
      "source" => nil,
      "reason" => reason,
      "summary" => nil,
      "findings" => []
    }

    # Validate BEFORE the guarded UPDATE, exactly as `write_note/4` does
    # and for the same reason: `update_all` bypasses the changeset, so the
    # closed vocabularies stop being closed unless the change is applied
    # in memory first.
    case Ecto.Changeset.apply_action(
           Stage.architecture_audit_changeset(stage, %{architecture_audit: audit}),
           :update
         ) do
      {:error, %Ecto.Changeset{} = invalid} -> {:error, invalid}
      {:ok, _applied} -> commit_open(stage, audit, now)
    end
  rescue
    e ->
      Logger.warning(
        "[StageAudit] failed to record architecture.audit_diff fire " <>
          "stage=#{stage.id} error=#{Exception.message(e)}"
      )

      {:error, {:stage_audit_write_raised, Exception.message(e)}}
  end

  @doc """
  Read the audit's state. **Level-triggered, and it never writes.**

  Returns `:none` when no fire was ever recorded for this stage,
  `{:open, audit}` while it is genuinely pending, and
  `{:resolved, audit}` once it carries — or projects — a terminal state.

  A `"pending"` audit whose `deadline_at` has passed, is missing, or is
  unparseable is reported as
  `{:resolved, %{"state" => "expired", "source" => "deadline"}}` without
  persisting anything. See the moduledoc.

  Accepts a `%Stage{}` or a stage id; **either way the row is re-read
  from the database.**
  """
  @spec read(Stage.t() | binary()) :: :none | {:open, map()} | {:resolved, map()}
  def read(stage_or_id) do
    case resolve_stage(stage_or_id) do
      nil -> :none
      %Stage{architecture_audit: nil} -> :none
      %Stage{architecture_audit: audit} -> classify_audit(audit)
    end
  end

  @doc """
  How many `architecture.audit_diff` fires a project recorded, and what
  became of each one.

      iex> StageAudit.coverage(%{project_id: project.id, since: yesterday})
      %{dispatched: 11, pending: 5, noted: 3, expired: 1, skipped: 2,
        failed: 0, balanced?: true}

  `since` is a `DateTime` bounding the window on the audit's own
  `dispatched_at` — the moment the fire went out — or `nil` for all time.

  ## The invariant

  `balanced?` is `dispatched == pending + noted + expired + skipped +
  failed`. It is the only thing that will ever notice a fire that was
  recorded and then lost track of, so it is reported alongside the counts
  rather than being asserted about them somewhere else. See the moduledoc
  for why every bucket comes off the `stages` rows and why `expired` is a
  projection.

  `false` means one of two things, both worth waking up for: a row was
  written past `Stage.architecture_audit_changeset/2`, or a new state was
  added to that changeset's vocabulary and not to `@coverage_buckets`.
  The `:warning` this logs names the offending stage ids.

  ## What the numbers mean to the operator loop

  A HEALTHY project trends toward `noted`. A `pending` count is work in
  flight and should drain. **A rising `expired` is the alarm this whole
  task exists to raise** — an architect that is being dispatched and is
  answering nothing, which before stage 1 was byte-identical to an
  architect that was never dispatched at all. `skipped` means nobody
  holds the responsibility (check `reason` on the rows to tell `unfilled`
  from `unknown_responsibility`); `failed` means the Router could not get
  the fire out.
  """
  @spec coverage(%{required(:project_id) => binary(), required(:since) => DateTime.t() | nil}) ::
          %{
            dispatched: non_neg_integer(),
            pending: non_neg_integer(),
            noted: non_neg_integer(),
            expired: non_neg_integer(),
            skipped: non_neg_integer(),
            failed: non_neg_integer(),
            balanced?: boolean()
          }
  def coverage(%{project_id: project_id, since: since}) when is_binary(project_id) do
    rows =
      project_id
      |> audit_rows()
      |> Enum.filter(fn {_id, audit} -> within_window?(audit, since) end)

    {counts, unaccounted} =
      Enum.reduce(rows, {empty_buckets(), []}, fn {stage_id, audit}, {counts, unaccounted} ->
        case bucket(audit) do
          nil -> {counts, [stage_id | unaccounted]}
          key -> {Map.update!(counts, key, &(&1 + 1)), unaccounted}
        end
      end)

    warn_unaccounted(project_id, unaccounted)

    dispatched = length(rows)
    accounted = @coverage_buckets |> Enum.map(&Map.fetch!(counts, &1)) |> Enum.sum()

    counts
    |> Map.put(:dispatched, dispatched)
    |> Map.put(:balanced?, dispatched == accounted)
  end

  @doc """
  Land the architect's note on an OPEN audit. **One-shot.**

  `note` carries `:summary` (a non-blank string) and `:findings` (a list
  of string-keyed `%{"constraint" => _, "detail" => _}` maps — shape
  already validated by the caller, and validated again by
  `Stage.architecture_audit_changeset/2` before anything is written).

  `opts`:

    * `:source` — `"mcp"` or `"handle_output"`; defaults to `"mcp"`.
    * `:resolved_by` — anything JSON-encodable naming who answered.

  Returns `{:ok, audit}` with the PERSISTED map, or:

    * `{:error, :stage_not_found}`
    * `{:error, :audit_not_open}` — no fire was ever recorded here
    * `{:error, :audit_already_recorded}` — somebody answered first
    * `{:error, %Ecto.Changeset{}}` — the note failed validation
    * `{:error, {:annotation_not_posted, reason}}` — nothing was written

  ## One-shot is arbitrated on the PERSISTED row, not on `read/1`

  `read/1`'s projection is what a READER wants; a WRITER arbitrating a
  race wants the row. The check and the write are one statement — the
  `UPDATE` carries its own `state = 'pending'` predicate, so two
  concurrent writers cannot both observe an open audit. **Zero rows
  affected IS the already-recorded answer.** Lifted from
  `Tasks.record_architecture_verdict/3` (`tasks.ex:2387-2424`), argument
  included.

  ## A LATE note WINS, and says so

  The consequence of arbitrating on the row: a note arriving after
  `deadline_at` still finds a persisted `"pending"` row and is accepted.
  That is `Platform.Design.PreplanStep`'s late-arrival rule
  (`preplan_step.ex:95-101`) — an architect who engaged late still
  engaged, and refusing her would trade a real audit for a projected
  `"expired"` that carries no content at all.

  But the upgrade must not ERASE the elapsed deadline, or the coverage
  numbers would report a healthy architect where there was a slow one.
  `"noted_after_deadline" => true` keeps the two facts separable in the
  row, for the same reason `"declined_after_timeout"` does on the design
  step. `deadline_at` itself is never rewritten.
  """
  @spec record_note(Stage.t() | binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def record_note(stage_or_id, note, opts \\ []) when is_map(note) do
    with {:ok, stage} <- fetch_stage(stage_or_id),
         {:ok, current} <- open_audit(stage) do
      write_note(stage, current, note, opts)
    end
  end

  @doc """
  The `"[architect | audit_diff] "` prefix every audit annotation carries.

  Public so tests and the external handler reference the literal instead
  of re-typing it.
  """
  @spec annotation_prefix() :: String.t()
  def annotation_prefix, do: @annotation_prefix

  @doc """
  Prefix an annotation body, idempotently.

  An architect whose prose already opens with the prefix must not get it
  twice — the reader greps for the marker and a doubled one reads as a
  malformed post.
  """
  @spec format_annotation(String.t()) :: String.t()
  def format_annotation(annotation) when is_binary(annotation) do
    if String.starts_with?(annotation, @annotation_prefix) do
      annotation
    else
      @annotation_prefix <> annotation
    end
  end

  @doc """
  Post one formatted annotation to an execution space.

  Unlike the private it replaced, this REPORTS failure instead of
  swallowing it — `record_note/3` has to roll the row back when the note
  cannot land. The external handler keeps its own swallow, because on
  that path the annotation is additive and must never fail a stage.
  """
  @spec post_annotation(binary(), String.t()) :: :ok | {:error, term()}
  def post_annotation(space_id, annotation)
      when is_binary(space_id) and is_binary(annotation) do
    case ExecutionSpace.post_log(space_id, format_annotation(annotation)) do
      {:ok, _msg} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Render an audit map as the annotation body an operator reads.

  Summary first, then one line per finding. The findings are repeated in
  prose rather than left to the row because the execution space is the
  surface the operator and the reviewer subagent already read, and a note that
  says "3 findings, see the database" is not a note.
  """
  @spec annotation_body(map()) :: String.t()
  def annotation_body(audit) when is_map(audit) do
    summary = audit |> Map.get("summary") |> to_string() |> String.trim()

    case Map.get(audit, "findings") || [] do
      [] ->
        summary

      findings ->
        rendered =
          Enum.map_join(findings, "\n", fn finding ->
            "- [#{Map.get(finding, "constraint")}] #{Map.get(finding, "detail")}"
          end)

        String.trim(summary <> "\n\n" <> rendered)
    end
  end

  # One statement, not a read-then-write: the predicate IS the check. A
  # `SELECT` followed by an `UPDATE` would be correct under the ordering
  # the code reads in and wrong under the one it actually runs in, where
  # the handler's note commits between the two.
  #
  # `coalesce(...,'')` so a row whose map somehow lost its `"state"` key
  # is overwritable rather than frozen: `NULL <> 'noted'` is NULL, which
  # excludes the row, which would make a malformed audit permanent.
  defp commit_open(%Stage{} = stage, audit, now) do
    {count, _} =
      Stage
      |> where([s], s.id == ^stage.id)
      |> where(
        [s],
        is_nil(s.architecture_audit) or
          fragment("coalesce(?->>'state', '') <> 'noted'", s.architecture_audit)
      )
      |> Repo.update_all(set: [architecture_audit: audit, updated_at: now])

    case count do
      1 ->
        {:ok, %{stage | architecture_audit: audit, updated_at: now}}

      0 ->
        # Zero rows has two causes and they are NOT the same fact: an
        # answer already landed here, or the stage row is gone. Reported
        # apart because the first is routine on the external path and the
        # second is a bug somewhere else.
        declined_open(stage)
    end
  end

  defp declined_open(%Stage{} = stage) do
    case resolve_stage(stage.id) do
      %Stage{architecture_audit: %{"state" => "noted"}} ->
        Logger.info(
          "[StageAudit] architecture.audit_diff fire not recorded for stage=#{stage.id} — " <>
            "a note already landed. The answer outranks the record of the dispatch."
        )

        {:error, :audit_already_noted}

      _ ->
        {:error, :stage_not_found}
    end
  end

  # ── coverage ────────────────────────────────────────────────────────

  # `stages` carries no `project_id` — it hangs off the plan, which hangs
  # off the task. Two joins rather than a denormalised column, because a
  # copy of the project on the stage is a second source of truth that
  # nothing keeps in step.
  #
  # Only rows with an audit are selected: NULL means no fire was ever
  # RECORDED for that stage, which is not the same fact as a fire that
  # produced nothing, and `dispatched` counts fires.
  defp audit_rows(project_id) do
    if Platform.UUID.valid?(project_id) do
      Stage
      |> join(:inner, [s], p in Plan, on: p.id == s.plan_id)
      |> join(:inner, [s, p], t in TaskSchema, on: t.id == p.task_id)
      |> where([s, _p, t], t.project_id == ^project_id)
      |> where([s], not is_nil(s.architecture_audit))
      |> select([s], {s.id, s.architecture_audit})
      |> Repo.all()
    else
      []
    end
  end

  # The window is applied in Elixir, not in SQL, on purpose. A
  # `(architecture_audit->>'dispatched_at')::timestamptz` predicate RAISES
  # on any row whose stamp is unparseable — one malformed row would take
  # the whole coverage read down — and a lexicographic string comparison
  # is a timestamp comparison only for as long as every writer keeps
  # emitting the identical format. Both failure modes are silent in the
  # dangerous direction.
  #
  # An unplaceable stamp is INCLUDED rather than dropped. Dropping it
  # would shrink `dispatched` for exactly the rows most likely to be
  # broken, which is the "silently shrinking number" the moduledoc
  # rejects; including it lets the row be bucketed normally, and if it
  # cannot be bucketed either, `balanced?` says so out loud.
  defp within_window?(_audit, nil), do: true

  defp within_window?(audit, %DateTime{} = since) do
    case audit |> Map.get("dispatched_at") |> parse_at() do
      {:ok, at} -> DateTime.compare(at, since) != :lt
      :error -> true
    end
  end

  defp parse_at(stamp) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  defp parse_at(_other), do: :error

  # ONE projection, shared with `read/1`. A second copy of the
  # "pending past its deadline is expired" rule is how `coverage/1` would
  # come to disagree with the function every other module asks.
  defp bucket(audit) do
    case classify_audit(audit) do
      {:open, %{"state" => state}} -> known_bucket(state)
      {:resolved, %{"state" => state}} -> known_bucket(state)
      :none -> nil
    end
  end

  defp known_bucket(state) when is_binary(state) do
    Enum.find(@coverage_buckets, &(Atom.to_string(&1) == state))
  end

  defp known_bucket(_state), do: nil

  defp empty_buckets, do: Map.new(@coverage_buckets, &{&1, 0})

  defp warn_unaccounted(_project_id, []), do: :ok

  defp warn_unaccounted(project_id, stage_ids) do
    Logger.warning(
      "[StageAudit] coverage invariant broken for project=#{project_id} — " <>
        "#{length(stage_ids)} audit row(s) in no bucket: #{Enum.join(stage_ids, ",")}. " <>
        "Something wrote architecture_audit past Stage.architecture_audit_changeset/2, " <>
        "or a new state was added to the vocabulary and not to @coverage_buckets."
    )
  end

  # ── note recording ──────────────────────────────────────────────────

  defp fetch_stage(stage_or_id) do
    case resolve_stage(stage_or_id) do
      %Stage{} = stage -> {:ok, stage}
      nil -> {:error, :stage_not_found}
    end
  end

  # THE PERSISTED row, never `read/1`. An overdue-but-unwritten audit
  # still reads `"pending"` here, which is what makes a late note win.
  defp open_audit(%Stage{architecture_audit: %{"state" => "pending"} = audit}), do: {:ok, audit}
  defp open_audit(%Stage{architecture_audit: nil}), do: {:error, :audit_not_open}
  defp open_audit(%Stage{}), do: {:error, :audit_already_recorded}

  defp write_note(%Stage{} = stage, current, note, opts) do
    now = DateTime.utc_now()

    merged =
      current
      |> Map.merge(%{
        "state" => "noted",
        "source" => Keyword.get(opts, :source, "mcp"),
        "resolved_at" => DateTime.to_iso8601(now),
        "summary" => Map.get(note, :summary),
        "findings" => Map.get(note, :findings) || []
      })
      |> put_note_key("resolved_by", Keyword.get(opts, :resolved_by))
      |> mark_late(current)

    # Validate BEFORE the guarded UPDATE. `update_all` bypasses the
    # changeset entirely, so a note that would fail validation has to be
    # refused here or the closed vocabularies stop being closed on the
    # one path an agent actually reaches.
    case Ecto.Changeset.apply_action(
           Stage.architecture_audit_changeset(stage, %{architecture_audit: merged}),
           :update
         ) do
      {:error, %Ecto.Changeset{} = invalid} -> {:error, invalid}
      {:ok, _applied} -> commit_note(stage, merged, now)
    end
  end

  defp commit_note(%Stage{} = stage, merged, now) do
    Repo.transaction(fn ->
      {count, _} =
        Stage
        |> where([s], s.id == ^stage.id)
        |> where([s], fragment("?->>'state' = 'pending'", s.architecture_audit))
        |> Repo.update_all(set: [architecture_audit: merged, updated_at: now])

      case count do
        # Lost the race between the read and the guarded UPDATE. Same
        # answer the level check gives, and the caller does not need to
        # tell the two apart.
        0 ->
          Repo.rollback(:audit_already_recorded)

        1 ->
          case post_note(merged) do
            :ok -> merged
            {:error, reason} -> Repo.rollback({:annotation_not_posted, reason})
          end
      end
    end)
  end

  defp post_note(audit) do
    task_id = Map.get(audit, "task_id")

    case is_binary(task_id) && ExecutionSpace.find_by_task_id(task_id) do
      %{id: space_id} -> post_annotation(space_id, annotation_body(audit))
      _ -> {:error, :no_execution_space}
    end
  end

  # Only fills an absent/nil key — an explicit value already in the open
  # audit wins over the `opts` fallback, mirroring `put_verdict_default/3`.
  defp put_note_key(map, _key, nil), do: map

  defp put_note_key(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      _present -> map
    end
  end

  # Derived from the row that was OPEN, not from the merged result — the
  # merge has already stamped `resolved_at`, and asking "was this late?"
  # of the answer instead of the question would always say no.
  defp mark_late(merged, current) do
    if overdue?(current), do: Map.put(merged, "noted_after_deadline", true), else: merged
  end

  # ── fire classification ─────────────────────────────────────────────

  # The state comes from `Responsibilities.outcome/1` and NOWHERE else.
  # `outcome/1` has no catch-all and raises on an unrecognised shape,
  # which is correct for it and fatal for us — see the moduledoc.
  defp classify_fire(fire_result, stage) do
    {audit_state(Responsibilities.outcome(fire_result)), fire_reason(fire_result)}
  rescue
    _e ->
      Logger.warning(
        "[StageAudit] architecture.audit_diff fire result has no outcome mapping " <>
          "stage=#{stage.id} result=#{inspect(fire_result)} — recording as failed"
      )

      {"failed", "outcome_unmapped:" <> inspect(fire_result)}
  end

  defp audit_state(:complete), do: "pending"
  defp audit_state(:not_applicable), do: "skipped"
  defp audit_state(:failed), do: "failed"

  # NOT a second outcome mapping — a discriminator inside one. See the
  # moduledoc: `outcome/1` merges `:unfilled` and `:unknown_responsibility`
  # deliberately, and this keeps the two facts separable in a field
  # nothing branches on. Takes the raw tuple, not an outcome atom, so the
  # two cannot be confused at a call site.
  defp fire_reason({:ok, :dispatched}), do: nil
  defp fire_reason({:ok, :unfilled}), do: "unfilled"
  defp fire_reason({:ok, :unknown_responsibility}), do: "unknown_responsibility"
  defp fire_reason({:error, reason}), do: inspect(reason)
  defp fire_reason(other), do: inspect(other)

  # ── read projection ─────────────────────────────────────────────────

  defp classify_audit(%{"state" => "pending"} = audit) do
    if overdue?(audit) do
      {:resolved, Map.merge(audit, %{"state" => "expired", "source" => "deadline"})}
    else
      {:open, audit}
    end
  end

  defp classify_audit(%{"state" => state} = audit) when is_binary(state), do: {:resolved, audit}

  defp classify_audit(_other), do: :none

  # A missing or unparseable deadline is treated as elapsed, the same way
  # `Tasks.architecture_gate/1` does and for the same reason: the
  # alternative is an audit with no falsifiable end. Failing toward
  # "expired" restores today's behaviour (nobody answered, nothing
  # blocked); failing toward "open" would leave a row that can never be
  # counted in any bucket, breaking stage 5's balance invariant silently.
  defp overdue?(%{"deadline_at" => deadline}) when is_binary(deadline) do
    case DateTime.from_iso8601(deadline) do
      {:ok, at, _offset} -> DateTime.compare(DateTime.utc_now(), at) != :lt
      {:error, _reason} -> true
    end
  end

  defp overdue?(_audit), do: true

  # ── lookups ─────────────────────────────────────────────────────────

  # Always re-read: see `read/1`'s @doc.
  defp resolve_stage(%Stage{id: id}), do: Repo.get(Stage, id)

  defp resolve_stage(id) when is_binary(id),
    do: if(Platform.UUID.valid?(id), do: Repo.get(Stage, id))

  defp resolve_stage(_other), do: nil

  # `stages` carries no `task_id`; it hangs off the plan. A plain select
  # rather than `Repo.get`, and nil-tolerant, because
  # `after_stage_completed/1` documents that a stage's plan row CAN be
  # gone (the nil-plan regression at
  # `plan_engine_architect_drift_hook_test.exs:455`). A nil `task_id` in
  # the row is still a recorded fire; raising here would record nothing.
  defp task_id_for(%Stage{plan_id: plan_id}) when is_binary(plan_id) do
    Repo.one(from(p in Plan, where: p.id == ^plan_id, select: p.task_id))
  end

  defp task_id_for(_stage), do: nil
end
