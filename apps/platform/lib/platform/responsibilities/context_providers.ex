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
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.SummaryPrompt
  alias Platform.Meetings.Transcript
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Repo
  alias Platform.Tasks.Plan

  @type slot ::
          :org_identity
          | :recent_journal
          | :meeting_transcript
          | :current_message
          | :current_meeting
          | :trigger_payload
          | :plan_payload

  # A plan in one of these statuses is no longer the task's live plan, so
  # resolving `:plan_payload` from a bare `task_id` skips them.
  @dead_plan_statuses ~w(superseded rejected)

  # Truncation budgets for `:plan_payload`. Sized so an 8-stage plan lands
  # around 7 kB / ~1.8k tokens, leaving room in the ~4096-token preamble
  # for the sibling-task and ADR slots.
  @task_description_limit 1200
  @stage_description_limit 600
  @e2e_expected_limit 200

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

  def gather_context(slot, _opts) do
    {:error, {:unknown_slot, slot}}
  end

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
