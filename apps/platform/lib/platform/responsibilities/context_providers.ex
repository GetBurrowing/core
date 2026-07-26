defmodule Platform.Responsibilities.ContextProviders do
  @moduledoc """
  **The single per-slot context resolver for the platform.** Every
  symbolic name declared on a `responsibility.context_provided` list is
  materialised here and nowhere else.

  Each slot is a `gather_context/2` clause in the shape M1's
  `Provider.gather_context/2` contract expects:

      gather_context(:org_identity, opts) :: {:ok, %{org_identity: payload}} | {:error, term()}

  Two consumers, one resolver:

    * **Per-slot callers** — handlers (`Handlers.DailySummary`,
      `Handlers.MeetingSummarize`, `Handlers.Dreaming`,
      `Handlers.ProposeLongTerm`) call a single slot directly and act on
      the `{:error, reason}` tuple. Hal's first nightly on a fresh org
      must distinguish "file missing" from "DB down", so refusals are
      expressed per slot, not flattened.

    * **The router's batch path** — `Platform.Responsibilities.ContextGatherer`
      is a thin *adapter* over this module. It fans a list of symbolic
      names across `gather_context/2` and folds the results into the
      tolerant `%{name => payload}` map the Dispatcher's template render
      expects, degrading every `{:error, _}` to `nil`. It resolves
      nothing itself.

  ## Adding new slots

  Add ONE `gather_context/2` clause here and widen `t:slot/0`. That is
  the whole change — the router's batch path picks it up through the
  adapter by construction. Do **not** add a matching resolver to
  `ContextGatherer`; it has none left to match.

  ## Required vs optional slots

  A slot returns `{:error, reason}` only when its absence should be able
  to *stop a dispatch* (see the router's context-refusal arm). Context
  that is legitimately empty on a healthy path — an org with no journal
  entries, a task with no siblings — returns `{:ok, ...}` with an
  explicit empty/`missing?` marker instead. Making optional context
  fatal is how a refusal mechanism gets disabled by the first false
  positive.

  `:plan_payload` is on the required side of that line, deliberately.
  ADR-0046 places the architecture pass strictly *after* plan
  submission, so every trigger that asks for this slot carries a plan,
  a plan id, or a task whose latest plan is the one under review. "No
  plan resolvable" is therefore not a legitimate empty state on any
  path that requests it — it is a wiring bug, and dispatching an LLM to
  review nothing is how that bug stays invisible. Contrast
  `:recent_journal`, where zero entries is a healthy Tuesday.

  `:sibling_tasks` is on the **optional** side, and deliberately so —
  it is the counterweight that keeps stage 2's refusal proportionate.
  An unstacked, epic-less task in a fresh project has zero siblings;
  that is not a wiring bug, it is the single most common shape in the
  system. Refusing on it would stop the architect dispatch for exactly
  the standalone tasks that most need a second read, and a refusal
  mechanism that fires on the common case gets switched off within a
  week. It returns `{:ok, ...}` with `scope: :none` instead. Only
  `plan_payload` is load-bearing enough to refuse a dispatch over.

  ## `:sibling_tasks` — what "sibling" means, and what the bound drops

  Three tiers, most-coupled first, **first match wins**:

    1. `:stack` — the anchor's stack members minus itself
       (`Platform.Tasks.Stacks.members/1`, ordered by `stack_position`).
       Tightest coupling in the system: shared rollup branch, atomic
       ship, declared dependency edges. No status filter — a `done`
       stack member has already merged into the branch this plan will
       merge into, so it is still the architect's business.
    2. `:epic` — `Tasks.list_tasks_by_epic/1` minus self, in-flight
       statuses only.
    3. `:project_window` — `Tasks.list_tasks_by_project/1` minus self,
       in-flight statuses only, further restricted to tasks whose
       latest live plan is `pending_review`/`approved`, ordered by
       `updated_at` desc, **capped**.

  First-match, not best-match: a one-member stack yields
  `scope: :stack, total: 0` rather than falling through to the project
  window. Stack membership is a deliberate authoring act; if a task was
  stacked alone, the project's other in-flight work is not what its
  author meant by "sibling".

  Every bound is disclosed in the payload, never applied silently:

    * `total` / `shown` / `truncated?` / `dropped` — how many siblings
      the tier found versus how many made the cut.
    * `unplanned_excluded` — project-window tasks dropped for having no
      submitted plan. A task with no plan has no stage descriptions and
      so cannot collide with the plan under review, but "0 siblings"
      and "0 siblings, 14 of them unplanned" are different facts and
      the model must be able to tell them apart.
    * per sibling, `stage_count` / `stages_shown` / `truncated?`.

  `Handlers.ArchitectureReviewPlan.format_sibling_tasks/1` renders all
  of it as a leading `[scope: …] showing N of M …` line. A block that
  silently drops half the siblings is the same failure mode as an index
  that silently mis-numbers an ADR: the model reads absence as evidence.

  ## `:adr_index` — why it is keyed on title, not number

  `docs/decisions/` does not have unique ADR numbers. Four numbers
  (0017, 0036, 0042, 0044) are each held by two different documents, so
  "ADR-0044" names both *Architect Responsibility* and *Task assignment
  — single source of truth*. An index that hands the architect a number
  hands it an ambiguity it cannot see, and the model cites one meaning
  the other, confidently. Every entry therefore carries `file` (the only
  unique key in this directory), `title`, `status`, and explicit
  `number_ambiguous` / `title_ambiguous` / `superseded_by` flags —
  **all computed from the directory at gather time, never hardcoded**,
  so the eventual numbering-repair task makes the flags go quiet on
  their own instead of leaving a stale list behind.

  Also on the optional side of the refusal line, and for a reason that
  is a property of the deployment rather than of the trigger: **prod
  release images do not ship `docs/`.** An unreachable ADR directory is
  the steady state there, so refusing would stop the architect from
  running at all in production — the definitive false positive. Two
  distinct non-refusing failures are reported instead, because
  "unreadable" and "genuinely empty" are different facts:

    * `:adr_dir_unreachable` — no directory resolved (release image,
      or the ancestor walk ran out of parents).
    * `:adr_dir_empty` — a directory resolved and holds zero `.md`
      files. Somebody deleted the ADRs; that is not the same event as
      "we are running from a release tarball".
    * `:adr_dir_unreadable` — the directory exists but `File.ls/1`
      refused it (permissions).

  All three render as an instruction *not to cite ADRs in this pass*,
  never as silence. `available?: false` with an empty entry list is a
  statement; an empty list on its own is indistinguishable from "there
  are no architectural decisions", which is a lie about this codebase.

  ### Supersessions have two sources, and one of them is a whitelist

  A `**Supersedes:**` header in the newer document builds a reverse map
  onto the older one. Prose is **not** scanned: regexing bodies for
  "superseded by this ADR" marks live decisions dead, which is worse
  than the gap it closes. The single prose-only supersession that
  matters (0012 → 0036) is a one-entry whitelist in
  `@manual_supersessions`, and it carries the exact source line it was
  derived from so a test can assert that line still exists. A whitelist
  that cannot detect its own staleness is how the class comes back.

  Header supersessions are not all total, either. `0013`'s header reads
  *"Attention routing sections of ADR 0008"* — ADR-0008 is very much
  alive, only part of it moved. Anything that is not a bare `ADR-NNNN`
  reference is flagged `partial?: true` and rendered as *"partially
  superseded by"* with the header text quoted, because telling the
  architect that Chat Backend Architecture is dead would be exactly the
  failure this slot exists to prevent.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.SummaryPrompt
  alias Platform.Meetings.Transcript
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stacks
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Task, as: TaskSchema

  @type slot ::
          :org_identity
          | :recent_journal
          | :meeting_transcript
          | :current_message
          | :current_meeting
          | :trigger_payload
          | :plan_payload
          | :sibling_tasks
          | :adr_index

  # A plan in one of these statuses is no longer the task's live plan, so
  # resolving `:plan_payload` from a bare `task_id` skips them.
  @dead_plan_statuses ~w(superseded rejected)

  # Truncation budgets for `:plan_payload`. Sized so an 8-stage plan lands
  # around 7 kB / ~1.8k tokens, leaving room in the ~4096-token preamble
  # for the sibling-task and ADR slots.
  @task_description_limit 1200
  @stage_description_limit 600
  @e2e_expected_limit 200

  # Truncation budgets for `:sibling_tasks`. The architect preamble is
  # ~4096 tokens (~16 kB); `:plan_payload` above is sized at ~7 kB,
  # which leaves roughly 5.5 kB here before `:adr_index` starts getting
  # squeezed. The arithmetic, written down so the next person moving a
  # cap sees the constraint instead of re-deriving it:
  #
  #   project window  10 siblings x 3 stages x 180 B ~= 5.4 kB ceiling
  #   stack / epic     8 siblings x 6 stages x 180 B ~= 8.6 kB ceiling
  #
  # The stack/epic ceiling is knowingly over the nominal share. Those
  # tiers are naturally small (stacks run 3-6 members), 180 B is a
  # ceiling rather than a mean, and a stack member is a task merging
  # into the SAME rollup branch as the plan under review — the exact
  # collision this responsibility exists to catch. The project window
  # is where the unbounded cost actually lived (it used to walk every
  # in-flight task in the project with no limit at all), so that is the
  # tier that gets the hard cap and the smaller per-sibling stage
  # budget.
  @stack_sibling_limit 8
  @epic_sibling_limit 8
  @project_window_limit 10
  @coupled_stage_limit 6
  @project_window_stage_limit 3
  @sibling_stage_description_limit 180

  # Statuses the architect flags collisions against. `done` / `deploying`
  # / `cancelled` / `backlog` are excluded so a project's graveyard does
  # not drown the annotation. Applied to the `:epic` and
  # `:project_window` tiers only — see `stack_siblings/1`.
  @in_flight_statuses ~w(planning in_progress in_review blocked stack_pending)

  # A project-window sibling only earns preamble space once it has a
  # submitted plan: with no plan it has no stage descriptions, and so
  # nothing that can collide with the plan under review.
  @live_sibling_plan_statuses ~w(pending_review approved)

  # ── :adr_index budgets and parse surface ──────────────────────────────────

  @adr_dir_from_repo_root "docs/decisions"

  # Header window. Every field this slot extracts (title, status,
  # supersedes) lives in the first few lines of an ADR; a full read of
  # 49 documents to recover three header fields is ~1.5 MB of file IO
  # per dispatch for nothing.
  @adr_header_lines 20

  # 49 ADRs today. MEASURED, not estimated: the rendered block is
  # 6.8 kB / ~1.7k tokens — filename ~48, title ~40, status ~20, plus
  # the 9 collision / supersession warning lines. The stage brief's
  # ~4.8 kB arithmetic assumed 95-char entries; real filenames and
  # titles run longer, so the honest number is written here rather than
  # the flattering one. That still fits beside `:plan_payload` (~7 kB)
  # and `:sibling_tasks` (5.4 kB at its project-window ceiling, and
  # that ceiling is a worst case that a standalone task never reaches)
  # in the ~16 kB preamble.
  #
  # No per-ADR body summary: the alternative is the first paragraph of
  # each `## Context` at roughly 5x the bytes, and these titles are
  # already descriptive one-liners. Statuses ARE capped — one ADR
  # records "Accepted (2026-03-22) — amended 2026-07-15 (task 019f640d;
  # see amendment section at bottom)", which is a changelog, not a
  # status.
  #
  # The cap is set ABOVE the current corpus deliberately. It exists so
  # the block cannot grow without bound, not to trim anything today —
  # `truncated?` is false at 49 and the arithmetic above stays true
  # until the directory nearly doubles. When it does bite it drops the
  # LOWEST-numbered ADRs, because the newest decisions are the ones a
  # plan under review is most likely to contradict, and it names every
  # dropped file in `dropped_files` so the renderer can say so.
  @adr_index_limit 80
  @adr_status_limit 60

  # Three status spellings occur in `docs/decisions/`, and only one of
  # them starts the line. Matching `^**Status:**` alone would report
  # "(status not recorded)" for a dozen ADRs whose status is written
  # right there — including 0001-0004, which are Accepted and load
  # bearing. A slot built to stop the index lying does not get to lie
  # about this.
  #
  #   `**Status:** Accepted`      — 0009+ (line-initial)
  #   `- **Status:** Accepted`    — 0001-0004, 0030, 0031 (list item)
  #   `## Status\n\nAccepted`     — 0005-0008, 0023, 0024 (section)
  @adr_status_line ~r/^\s*(?:[-*]\s+)?\*\*Status:?\*\*\s*(.+)$/u
  @adr_status_heading ~r/^#+\s+Status\s*$/iu

  @adr_heading ~r/^#\s+\S/u
  @adr_title_prefix ~r/^(?:ADR[-\s–—]*)?\d{4}\s*(?:[-:.–—]\s*)?/u
  @adr_supersedes_line ~r/^\s*(?:[-*]\s+)?\*\*Supersedes:?\*\*\s*(.+)$/u
  @adr_reference ~r/ADR[-\s–—]*(\d{3,4})/u

  # A supersession header is TOTAL only when it is a bare reference,
  # optionally followed by the superseded ADR's title in parentheses.
  # Anything else ("Attention routing sections of ADR 0008") is partial
  # and rendered as such — ADR-0008 is alive.
  @adr_total_supersession ~r/^ADR[-\s–—]*\d{3,4}\s*(?:\([^)]*\))?\s*[.,;]?$/u

  # The one supersession recorded in prose rather than in a header.
  # 0036 retires 0012 on its `**Related:**` line and again in its
  # "Related ADRs and successor context" section; it never writes a
  # `**Supersedes:**` header, and scanning bodies for phrases like
  # "superseded by this ADR" produces false positives that mark LIVE
  # decisions dead. So: a whitelist — with the exact source line it was
  # derived from, asserted by a test against the real file. Rewrite
  # 0036 and the suite goes red instead of the index going quietly
  # wrong.
  @manual_supersessions %{
    "0012" => %{
      by: "0036-canvases-first-class-collaboration-surfaces.md",
      evidence: "ADR 0012 (Agent-Driven Live Canvas Architecture — superseded by this ADR)",
      note:
        "recorded in prose on 0036's **Related:** line and in its successor-context " <>
          "section, never as a **Supersedes:** header"
    }
  }

  @doc """
  Materialise a single slot into the shape M1 providers consume.

  ## Slots

    * `:org_identity` — loads `ORG_IDENTITY.md` via
      `Platform.Org.Context.get_file/1`. Returns `missing?: true` with
      empty body when the file row doesn't exist (Hal's first nightly
      on a fresh org must not crash).
    * `:recent_journal` — last 7 days from `Platform.Org.Context.recent_memory/2`.
      Honours `opts[:workspace_id]` for scoping.
    * `:meeting_transcript` — requires `opts[:transcript_id]`. Loads the
      transcript and formats segments via `SummaryPrompt.format_segments/1`.
      Returns `{:error, :not_found}` if no transcript with that ID exists,
      `{:error, :missing_transcript_id}` if no ID provided.
    * `:current_message` — requires `opts[:message_id]`. Returns the raw
      `%Platform.Chat.Message{}`. `{:error, :missing_message_id}` /
      `{:error, :invalid_message_id}` / `{:error, :not_found}`.
    * `:current_meeting` — requires `opts[:meeting_id]`. Returns the raw
      `%Platform.Meetings.Meeting{}`. `{:error, :missing_meeting_id}` /
      `{:error, :invalid_meeting_id}` / `{:error, :not_found}`.
    * `:trigger_payload` — echoes `opts[:payload]` straight through.
      `{:error, :missing_payload}` when the trigger carried none.
    * `:plan_payload` — the plan under review: its stages, each stage's
      validation gates, and the task intent the plan was written
      against. Resolves from `opts[:plan]` (a `%Plan{}`), else
      `opts[:plan_id]`, else the latest non-superseded/non-rejected plan
      for `opts[:task_id]`. **Returns `{:error, :no_plan_payload}` when
      nothing resolves** — see "Required vs optional slots" below.
    * `:sibling_tasks` — the tasks whose in-flight work could collide
      with this one, resolved through the stack → epic → bounded
      project-window ladder documented in the moduledoc. Anchors on
      `opts[:task]`, else `opts[:task_id]`, else `opts[:plan].task_id`,
      else `opts[:plan_id]`. **Never returns `{:error, _}`** — an
      unresolvable anchor is `scope: :no_anchor` and a genuinely
      sibling-less task is `scope: :none`, both with `{:ok, ...}`.
    * `:adr_index` — every `docs/decisions/*.md` as
      `%{file:, number:, title:, status:, number_ambiguous:,
      title_ambiguous:, superseded_by: [...]}`, keyed for citation on
      `file` because numbers are not unique in that directory.
      Directory resolution order: `config :platform, :adr_dir`, then an
      ancestor walk from this module's compile-time path, then an
      ancestor walk from `File.cwd!/0`. **Never returns `{:error, _}`**
      — an unreachable / unreadable / empty directory is
      `available?: false` with a `reason`, which the renderer turns
      into an explicit "do not cite ADRs in this pass" instruction.

  `opts` may be a keyword list or a map; map keys may be atoms or
  strings (the router hands `trigger_meta` through verbatim and both
  key forms occur in the wild). Atom keys win over their string twin.
  """
  @spec gather_context(slot(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def gather_context(slot, opts \\ [])

  def gather_context(:org_identity, _opts) do
    case safe(fn -> OrgContext.get_file("ORG_IDENTITY.md") end) do
      {:ok, nil} ->
        {:ok,
         %{
           org_identity: %{
             content: "",
             version: nil,
             missing?: true
           }
         }}

      {:ok, %{content: content, version: version}} ->
        {:ok,
         %{
           org_identity: %{
             content: content || "",
             version: version,
             missing?: false
           }
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def gather_context(:recent_journal, opts) do
    opts = to_keyword(opts)
    workspace_id = Keyword.get(opts, :workspace_id)
    days = Keyword.get(opts, :days, 7)

    recent_opts = if workspace_id, do: [workspace_id: workspace_id], else: []

    case safe(fn -> OrgContext.recent_memory(days, recent_opts) end) do
      {:ok, grouped} when is_list(grouped) ->
        total = grouped |> Enum.map(fn {_date, entries} -> length(entries) end) |> Enum.sum()

        {:ok,
         %{
           recent_journal: %{
             days: days,
             entries_by_date: grouped,
             total: total
           }
         }}

      {:ok, _other} ->
        # Defensive: if recent_memory ever changes shape, surface an empty
        # window rather than crashing the dispatch pipeline.
        {:ok, %{recent_journal: %{days: days, entries_by_date: [], total: 0}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def gather_context(:meeting_transcript, opts) do
    opts = to_keyword(opts)

    case Keyword.get(opts, :transcript_id) do
      nil ->
        {:error, :missing_transcript_id}

      id when is_binary(id) ->
        case safe(fn -> Meetings.get_transcript(id) end) do
          {:ok, nil} ->
            {:error, :not_found}

          {:ok, %Transcript{} = transcript} ->
            segments = transcript.segments || []

            {:ok,
             %{
               meeting_transcript: %{
                 transcript_id: transcript.id,
                 formatted_text: SummaryPrompt.format_segments(segments),
                 segment_count: length(segments),
                 duration_ms: max_end_time(segments)
               }
             }}

          {:error, reason} ->
            {:error, reason}
        end

      _other ->
        {:error, :invalid_transcript_id}
    end
  end

  def gather_context(:current_message, opts) do
    case Keyword.get(to_keyword(opts), :message_id) do
      nil ->
        {:error, :missing_message_id}

      id when is_binary(id) ->
        case safe(fn -> Chat.get_message(id) end) do
          {:ok, nil} -> {:error, :not_found}
          {:ok, message} -> {:ok, %{current_message: message}}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :invalid_message_id}
    end
  end

  def gather_context(:current_meeting, opts) do
    case Keyword.get(to_keyword(opts), :meeting_id) do
      nil ->
        {:error, :missing_meeting_id}

      id when is_binary(id) ->
        case safe(fn -> Meetings.get_meeting(id) end) do
          {:ok, nil} -> {:error, :not_found}
          {:ok, meeting} -> {:ok, %{current_meeting: meeting}}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :invalid_meeting_id}
    end
  end

  def gather_context(:trigger_payload, opts) do
    case Keyword.get(to_keyword(opts), :payload) do
      nil -> {:error, :missing_payload}
      payload -> {:ok, %{trigger_payload: payload}}
    end
  end

  def gather_context(:plan_payload, opts) do
    case resolve_plan(to_keyword(opts)) do
      %Plan{} = plan -> {:ok, %{plan_payload: plan_payload(plan)}}
      nil -> {:error, :no_plan_payload}
    end
  end

  def gather_context(:sibling_tasks, opts) do
    payload =
      opts
      |> to_keyword()
      |> resolve_anchor_task()
      |> sibling_tasks()

    {:ok, %{sibling_tasks: payload}}
  end

  def gather_context(:adr_index, _opts) do
    {:ok, %{adr_index: adr_index()}}
  end

  def gather_context(slot, _opts) do
    {:error, {:unknown_slot, slot}}
  end

  @doc """
  The `docs/decisions/` directory this slot reads, or the reason it
  could not be resolved.

  Public so tests can compute expectations (collisions, entry counts)
  from the live directory instead of hardcoding a snapshot of it — a
  hardcoded list goes stale the moment the numbering-repair task lands
  and then certifies whatever it happens to say.
  """
  @spec adr_dir() :: {:ok, String.t()} | {:error, :adr_dir_unreachable}
  def adr_dir do
    configured = Application.get_env(:platform, :adr_dir)

    cond do
      is_binary(configured) ->
        # No fallback when an override is configured. A test that points
        # at a fixture dir and silently gets the live repo instead is
        # worse than a failing test.
        if File.dir?(configured), do: {:ok, configured}, else: {:error, :adr_dir_unreachable}

      dir = walk_for_adr_dir(__ENV__.file) ->
        {:ok, dir}

      dir = walk_for_adr_dir(safe_cwd()) ->
        {:ok, dir}

      true ->
        {:error, :adr_dir_unreachable}
    end
  end

  @doc """
  The prose-only supersessions this slot stamps by hand, each with the
  source line it was derived from.

  Public so the self-verification test asserts against the actual
  whitelist rather than a copy of it.
  """
  @spec manual_supersessions() :: %{String.t() => map()}
  def manual_supersessions, do: @manual_supersessions

  # ── :plan_payload helpers ─────────────────────────────────────────────────

  # Mirrors the cond ladder the architecture handler used to own. Atom
  # and string keys both land here because `to_keyword/1` coerces them,
  # with atom keys taking precedence.
  defp resolve_plan(opts) do
    plan = Keyword.get(opts, :plan)
    plan_id = Keyword.get(opts, :plan_id)
    task_id = Keyword.get(opts, :task_id)

    cond do
      match?(%Plan{}, plan) -> plan
      is_binary(plan_id) -> load_plan(plan_id)
      is_binary(task_id) -> latest_live_plan(task_id)
      true -> nil
    end
  end

  defp load_plan(plan_id) do
    case safe(fn -> Repo.get(Plan, plan_id) end) do
      {:ok, plan} -> plan
      {:error, _reason} -> nil
    end
  end

  defp latest_live_plan(task_id) do
    query =
      from(p in Plan,
        where: p.task_id == ^task_id and p.status not in @dead_plan_statuses,
        order_by: [desc: p.version],
        limit: 1
      )

    case safe(fn -> Repo.one(query) end) do
      {:ok, plan} -> plan
      {:error, _reason} -> nil
    end
  end

  defp plan_payload(%Plan{} = plan) do
    plan = Repo.preload(plan, [:task, stages: :validations])
    task = plan.task
    stages = plan.stages |> List.wrap() |> Enum.sort_by(& &1.position)

    %{
      plan_id: plan.id,
      plan_version: plan.version,
      plan_status: plan.status,
      task_id: task && task.id,
      task_title: task && task.title,
      task_description: task && truncate(task.description, @task_description_limit),
      task_status: task && task.status,
      project_id: task && task.project_id,
      epic_id: task && task.epic_id,
      stack_id: task && task.stack_id,
      stage_count: length(stages),
      stages: Enum.map(stages, &stage_payload/1)
    }
  end

  defp stage_payload(stage) do
    validations = stage.validations |> List.wrap() |> Enum.sort_by(& &1.kind)

    %{
      position: stage.position,
      name: stage.name,
      description: truncate(stage.description, @stage_description_limit),
      status: stage.status,
      validations: Enum.map(validations, &%{kind: &1.kind, status: &1.status}),
      e2e_expected: e2e_expected(validations)
    }
  end

  # Only the `expected` string of each `e2e_behavior` gate. The architect
  # needs to see WHETHER a stage is protected and by what kind of gate,
  # not the adversarial script — `setup` / `actions` are the largest
  # fields on a plan and add nothing to a module-boundary judgement.
  defp e2e_expected(validations) do
    validations
    |> Enum.filter(&(&1.kind == "e2e_behavior"))
    |> Enum.map(&expected_string(&1.evaluation_payload))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&truncate(&1, @e2e_expected_limit))
  end

  defp expected_string(%{"expected" => expected}) when is_binary(expected), do: expected
  defp expected_string(%{expected: expected}) when is_binary(expected), do: expected
  defp expected_string(_payload), do: nil

  # ── :sibling_tasks helpers ────────────────────────────────────────────────

  # Anchor resolution is wider than the stage brief's task/task_id/plan
  # ladder: `plan_id` is included because the plan-submit trigger can
  # legitimately carry only that, and re-deriving the task from it is a
  # single `Repo.get`. Every lookup goes through `safe/1`, so a
  # malformed id casts to `nil` rather than raising out of an OPTIONAL
  # slot.
  defp resolve_anchor_task(opts) do
    task = Keyword.get(opts, :task)
    task_id = Keyword.get(opts, :task_id)
    plan = Keyword.get(opts, :plan)
    plan_id = Keyword.get(opts, :plan_id)

    cond do
      match?(%TaskSchema{}, task) -> task
      is_binary(task_id) -> load_task(task_id)
      match?(%Plan{}, plan) -> load_task(plan.task_id)
      is_binary(plan_id) -> plan_id |> load_plan() |> anchor_from_plan()
      true -> nil
    end
  end

  defp anchor_from_plan(%Plan{task_id: task_id}) when is_binary(task_id),
    do: load_task(task_id)

  defp anchor_from_plan(_plan), do: nil

  defp load_task(task_id) when is_binary(task_id) do
    case safe(fn -> Repo.get(TaskSchema, task_id) end) do
      {:ok, %TaskSchema{} = task} -> task
      _other -> nil
    end
  end

  defp load_task(_task_id), do: nil

  defp sibling_tasks(nil), do: empty_siblings(:no_anchor)

  defp sibling_tasks(%TaskSchema{} = task) do
    cond do
      is_binary(task.stack_id) -> stack_siblings(task)
      is_binary(task.epic_id) -> epic_siblings(task)
      is_binary(task.project_id) -> project_window(task)
      true -> empty_siblings(:none)
    end
  end

  # No status filter here, unlike the other two tiers. A `done` stack
  # member has already merged into the rollup branch this plan will
  # merge into, so it is still live context for a collision check —
  # `deleted_at` exclusion and `stack_position` ordering come from
  # `Stacks.members/1`.
  defp stack_siblings(%TaskSchema{} = task) do
    fn -> Stacks.members(task.stack_id) end
    |> safe_list()
    |> Enum.reject(&(&1.id == task.id))
    |> build_sibling_payload(:stack, @stack_sibling_limit, @coupled_stage_limit)
  end

  defp epic_siblings(%TaskSchema{} = task) do
    fn -> Tasks.list_tasks_by_epic(task.epic_id) end
    |> safe_list()
    |> Enum.reject(&(&1.id == task.id or &1.status not in @in_flight_statuses))
    |> build_sibling_payload(:epic, @epic_sibling_limit, @coupled_stage_limit)
  end

  defp project_window(%TaskSchema{} = task) do
    candidates =
      fn -> Tasks.list_tasks_by_project(task.project_id) end
      |> safe_list()
      |> Enum.reject(&(&1.id == task.id or &1.status not in @in_flight_statuses))

    plans = latest_live_plans(Enum.map(candidates, & &1.id))

    planned =
      candidates
      |> Enum.filter(&planned_sibling?(Map.get(plans, &1.id)))
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

    payload =
      build_sibling_payload(
        planned,
        :project_window,
        @project_window_limit,
        @project_window_stage_limit,
        unplanned_excluded: length(candidates) - length(planned),
        plans: plans
      )

    # An empty window is reported as `:none` rather than
    # `:project_window` so the renderer can say "this task has no
    # siblings" instead of "the window found nothing", which reads as a
    # query failure. The `unplanned_excluded` count survives the
    # relabel — that is the whole point of carrying it.
    if payload.total == 0, do: %{payload | scope: :none}, else: payload
  end

  defp planned_sibling?(%Plan{status: status}), do: status in @live_sibling_plan_statuses
  defp planned_sibling?(_plan), do: false

  defp build_sibling_payload(tasks, scope, sibling_limit, stage_limit, opts \\ []) do
    total = length(tasks)
    shown = Enum.take(tasks, sibling_limit)

    plans = Keyword.get(opts, :plans) || latest_live_plans(Enum.map(shown, & &1.id))

    stages =
      shown
      |> Enum.map(&Map.get(plans, &1.id))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.id)
      |> stages_by_plan()

    %{
      scope: scope,
      total: total,
      shown: length(shown),
      truncated?: total > length(shown),
      dropped: total - length(shown),
      unplanned_excluded: Keyword.get(opts, :unplanned_excluded, 0),
      tasks:
        Enum.map(
          shown,
          &sibling_entry(&1, Map.get(plans, &1.id), stages, stage_limit)
        )
    }
  end

  defp empty_siblings(scope) do
    %{
      scope: scope,
      total: 0,
      shown: 0,
      truncated?: false,
      dropped: 0,
      unplanned_excluded: 0,
      tasks: []
    }
  end

  # One query for every candidate rather than the N+1 the old private
  # summariser ran (list_plans/1 per task, then a stage preload per
  # plan). Ordered ascending by version so the reduce leaves the highest
  # live version per task in the map.
  defp latest_live_plans([]), do: %{}

  defp latest_live_plans(task_ids) do
    from(p in Plan,
      where: p.task_id in ^task_ids and p.status not in @dead_plan_statuses,
      order_by: [asc: p.task_id, asc: p.version]
    )
    |> safe_all()
    |> Map.new(&{&1.task_id, &1})
  end

  defp stages_by_plan([]), do: %{}

  defp stages_by_plan(plan_ids) do
    from(s in Stage,
      where: s.plan_id in ^plan_ids,
      order_by: [asc: s.plan_id, asc: s.position]
    )
    |> safe_all()
    |> Enum.group_by(& &1.plan_id)
  end

  defp sibling_entry(%TaskSchema{} = task, plan, stages_by_plan_id, stage_limit) do
    all_stages = (plan && Map.get(stages_by_plan_id, plan.id)) || []
    shown_stages = Enum.take(all_stages, stage_limit)

    %{
      task_id: task.id,
      title: task.title,
      status: task.status,
      stack_position: task.stack_position,
      latest_plan_status: plan && plan.status,
      stage_count: length(all_stages),
      stages_shown: length(shown_stages),
      truncated?: length(all_stages) > length(shown_stages),
      stages: Enum.map(shown_stages, &sibling_stage_entry/1)
    }
  end

  defp sibling_stage_entry(stage) do
    %{
      position: stage.position,
      name: stage.name,
      description: truncate(stage.description, @sibling_stage_description_limit)
    }
  end

  defp safe_list(fun) when is_function(fun, 0) do
    case safe(fun) do
      {:ok, list} when is_list(list) -> list
      _other -> []
    end
  end

  defp safe_all(query) do
    case safe(fn -> Repo.all(query) end) do
      {:ok, list} when is_list(list) -> list
      _other -> []
    end
  end

  # ── :adr_index helpers ────────────────────────────────────────────────────

  defp adr_index do
    case adr_dir() do
      {:ok, dir} -> index_from_dir(dir)
      {:error, reason} -> unavailable_index(reason, nil)
    end
  end

  defp index_from_dir(dir) do
    case safe(fn -> File.ls!(dir) end) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> case do
          [] -> unavailable_index(:adr_dir_empty, dir)
          files -> build_adr_index(dir, files)
        end

      {:error, _reason} ->
        unavailable_index(:adr_dir_unreadable, dir)
    end
  end

  # `available?: false` carries a reason and an empty entry list rather
  # than just an empty list, because "there are no ADRs" and "I could
  # not read the ADRs" are different facts and only one of them is ever
  # true of this codebase.
  defp unavailable_index(reason, dir) do
    %{
      available?: false,
      reason: reason,
      dir: dir,
      total: 0,
      shown: 0,
      truncated?: false,
      dropped: 0,
      dropped_files: [],
      number_collisions: %{},
      title_collisions: %{},
      entries: []
    }
  end

  defp build_adr_index(dir, files) do
    parsed = Enum.map(files, &parse_adr(dir, &1))

    number_collisions = collisions_by(parsed, & &1.number)
    title_collisions = collisions_by(parsed, &normalised_title/1)
    supersessions = supersession_map(parsed)

    entries =
      Enum.map(parsed, fn entry ->
        %{
          file: entry.file,
          number: entry.number,
          title: entry.title,
          status: entry.status,
          number_ambiguous: Map.has_key?(number_collisions, entry.number),
          title_ambiguous: Map.has_key?(title_collisions, normalised_title(entry)),
          superseded_by:
            supersessions
            |> Map.get(entry.number, [])
            |> Enum.reject(&(&1.file == entry.file))
        }
      end)

    # Drop the lowest-numbered ADRs first when the cap bites, then
    # restore filename order for rendering.
    {kept, dropped} =
      entries
      |> Enum.sort_by(&{&1.number || "", &1.file}, :desc)
      |> Enum.split(adr_index_limit())

    %{
      available?: true,
      reason: nil,
      dir: dir,
      total: length(entries),
      shown: length(kept),
      truncated?: dropped != [],
      dropped: length(dropped),
      dropped_files: dropped |> Enum.map(& &1.file) |> Enum.sort(),
      number_collisions: number_collisions,
      title_collisions: title_collisions,
      entries: Enum.sort_by(kept, & &1.file)
    }
  end

  # Overridable so the truncation path is reachable from a test. A cap
  # that only fires once the corpus doubles is a cap nobody has ever
  # run; the disclosure it produces is the part that has to work.
  defp adr_index_limit do
    case Application.get_env(:platform, :adr_index_limit) do
      limit when is_integer(limit) and limit > 0 -> limit
      _other -> @adr_index_limit
    end
  end

  # Every number (or title) held by more than one file, computed from
  # the directory. Nothing here is hardcoded, so the repair task makes
  # these go quiet without a code change.
  defp collisions_by(parsed, key_fun) do
    parsed
    |> Enum.group_by(key_fun)
    |> Enum.reject(fn {key, group} -> is_nil(key) or length(group) < 2 end)
    |> Map.new(fn {key, group} -> {key, group |> Enum.map(& &1.file) |> Enum.sort()} end)
  end

  defp normalised_title(%{title: title}) when is_binary(title),
    do: title |> String.trim() |> String.downcase()

  defp normalised_title(_entry), do: nil

  defp supersession_map(parsed) do
    present = MapSet.new(parsed, & &1.file)

    parsed
    |> Enum.flat_map(fn entry ->
      Enum.map(entry.supersedes, fn ref ->
        {ref.number, %{file: entry.file, note: ref.note, partial?: ref.partial?, source: :header}}
      end)
    end)
    |> Kernel.++(manual_supersession_pairs(present))
    |> Enum.group_by(fn {number, _ref} -> number end, fn {_number, ref} -> ref end)
  end

  # Only stamped when the superseding document is actually in the
  # directory being indexed — otherwise a fixture directory would
  # inherit the live repo's whitelist and report a supersession by a
  # file that isn't there.
  defp manual_supersession_pairs(present) do
    for {number, manual} <- @manual_supersessions, MapSet.member?(present, manual.by) do
      {number, %{file: manual.by, note: manual.note, partial?: false, source: :manual}}
    end
  end

  defp parse_adr(dir, file) do
    lines = adr_header(Path.join(dir, file))

    %{
      file: file,
      number: adr_number(file),
      title: adr_title(lines),
      status: adr_status(lines),
      supersedes: adr_supersedes(lines)
    }
  end

  # `Enum.take/2` over the line stream, never `File.read!/1`: three
  # header fields do not justify reading 49 whole documents.
  defp adr_header(path) do
    case safe(fn -> path |> File.stream!() |> Enum.take(@adr_header_lines) end) do
      {:ok, lines} -> Enum.map(lines, &String.trim_trailing/1)
      {:error, _reason} -> []
    end
  end

  defp adr_number(file) do
    case Regex.run(~r/^(\d{4})/, file) do
      [_full, number] -> number
      _other -> nil
    end
  end

  defp adr_title(lines) do
    case Enum.find(lines, &Regex.match?(@adr_heading, &1)) do
      nil ->
        nil

      line ->
        line
        |> String.replace_prefix("#", "")
        |> String.trim()
        |> String.replace(@adr_title_prefix, "", global: false)
        |> String.trim()
        |> presence()
    end
  end

  defp adr_status(lines) do
    case Enum.find_value(lines, &capture_first(@adr_status_line, &1)) do
      nil -> lines |> status_under_heading() |> truncate(@adr_status_limit)
      value -> value |> String.trim() |> presence() |> truncate(@adr_status_limit)
    end
  end

  # `## Status` followed by a blank line and the value (0005-0008,
  # 0023, 0024). A following heading means the section is empty — that
  # is `nil`, not the next section's title.
  defp status_under_heading(lines) do
    lines
    |> Enum.drop_while(&(not Regex.match?(@adr_status_heading, &1)))
    |> Enum.drop(1)
    |> Enum.find(&(String.trim(&1) != ""))
    |> case do
      nil -> nil
      "#" <> _rest -> nil
      line -> line |> String.trim() |> presence()
    end
  end

  defp adr_supersedes(lines) do
    lines
    |> Enum.find_value(&capture_first(@adr_supersedes_line, &1))
    |> case do
      nil ->
        []

      value ->
        note = String.trim(value)
        partial? = not Regex.match?(@adr_total_supersession, note)

        @adr_reference
        |> Regex.scan(note)
        |> Enum.map(fn [_full, number] -> String.pad_leading(number, 4, "0") end)
        |> Enum.uniq()
        |> Enum.map(&%{number: &1, note: note, partial?: partial?})
    end
  end

  defp capture_first(regex, line) do
    case Regex.run(regex, line) do
      [_full, captured] -> captured
      _other -> nil
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp walk_for_adr_dir(nil), do: nil

  defp walk_for_adr_dir(path) when is_binary(path) do
    path
    |> Path.expand()
    |> find_ancestor_with_dir(@adr_dir_from_repo_root, 8)
    |> case do
      nil -> nil
      root -> Path.join(root, @adr_dir_from_repo_root)
    end
  end

  defp find_ancestor_with_dir(_path, _dir, 0), do: nil

  defp find_ancestor_with_dir(path, dir, depth) do
    parent = Path.dirname(path)

    cond do
      parent == path -> nil
      File.dir?(Path.join(parent, dir)) -> parent
      true -> find_ancestor_with_dir(parent, dir, depth - 1)
    end
  end

  defp safe_cwd do
    case File.cwd() do
      {:ok, cwd} -> Path.join(cwd, ".")
      {:error, _reason} -> nil
    end
  end

  # ── shared truncation ─────────────────────────────────────────────────────

  defp truncate(str, max_len) when is_binary(str) and byte_size(str) > max_len do
    String.slice(str, 0, max_len) <> "…"
  end

  defp truncate(str, _max_len) when is_binary(str), do: str
  defp truncate(_str, _max_len), do: nil

  # ── helpers ────────────────────────────────────────────────────────────────

  defp to_keyword(opts) when is_list(opts), do: opts

  # Coercion is per-key, not all-or-nothing. The router hands
  # `trigger_meta` straight through and it routinely carries string keys
  # nobody has ever turned into an atom; dropping the whole opts list
  # because one sibling key failed `String.to_existing_atom/1` would
  # silently blank the slot's real id. Atom pairs are placed first so an
  # atom key wins over its string twin (`Keyword.get/2` takes the first
  # match), matching the `meta[:x] || meta["x"]` precedence the batch
  # adapter used to apply.
  defp to_keyword(opts) when is_map(opts) do
    {atom_pairs, rest} = Enum.split_with(opts, fn {k, _v} -> is_atom(k) end)

    atom_pairs ++ Enum.flat_map(rest, &coerce_pair/1)
  end

  defp to_keyword(_), do: []

  defp coerce_pair({k, v}) when is_binary(k) do
    [{String.to_existing_atom(k), v}]
  rescue
    ArgumentError -> []
  end

  defp coerce_pair(_pair), do: []

  defp max_end_time([]), do: 0

  defp max_end_time(segments) do
    segments
    |> Enum.map(fn segment ->
      end_time = segment["end_time"] || segment[:end_time] || 0
      if is_number(end_time), do: end_time, else: 0
    end)
    |> Enum.max(fn -> 0 end)
    |> trunc()
  end

  # Wrap upstream lookups so a missing module / unexpected raise
  # surfaces as `{:error, term}` rather than aborting the caller. The
  # M6 router treats `{:error, _}` as a dispatch failure and decides
  # whether to retry / log / fall back.
  defp safe(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    error ->
      Logger.warning(
        "[ContextProviders] lookup raised: #{Exception.message(error)} — returning error"
      )

      {:error, {:exception, Exception.message(error)}}
  catch
    :exit, reason ->
      Logger.warning("[ContextProviders] lookup exited: #{inspect(reason)}")
      {:error, {:exit, reason}}
  end
end
