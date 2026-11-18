defmodule Platform.Ux.FrictionDrop do
  @moduledoc """
  Post-ship friction drop: the UX super agent's north star (spec decision 3,
  task 01a1f048).

  For every UX finding whose task shipped, how often its friction recurs in
  the 4 weeks after the ship against the 4 weeks before. A drop of 1.0 means
  the friction stopped; 0.0 means no change; a negative value means it got
  worse.

  ## What counts as shipped

  A finding with a `task_id` whose task is `done`. The ship time is the
  task's FIRST transition into `done` (`task_phase_transitions`), else the
  task's `updated_at` for a task that predates the transition log. A task
  that later left `done` still shipped once; the first ship is what the
  windows are measured around.

  ## What counts as a recurrence

  Deterministic, no model call. A human message counts when ALL of these
  hold:

    * it is in one of the spaces the finding cited (its evidence citations),
      read through `Platform.Chat.list_human_digest_messages_in_spaces/4`,
      the same privacy partition the friction watch reads (internal spaces
      only, agent messages excluded);
    * it passes the friction watch's own pre-filter
      (`Platform.Ux.FrictionWatch.friction?/1`);
    * it shares at least `min_shared/1` of the finding's salient terms
      (words of 4+ letters from its question and quotes, stopwords out).

  So the measure is "friction-shaped talk about the same thing in the same
  place", counted the same way before and after. It is coarse by design and
  it is symmetric: whatever it over- or under-counts, it does so on both
  sides of the ship.

  ## Settled vs pending

  A finding is settled once its after-window has fully elapsed. Pending
  findings are reported as a count and never enter the ratio, so a recent
  ship cannot read as a drop just because its after-window is short. A
  settled finding with no recurrence BEFORE the ship has no baseline and is
  left out of the ratio (reported as `no_baseline`).

  ## Aggregate

  `1 - sum(after) / sum(before)` over settled findings with a baseline: a
  pooled ratio, so a finding seen fifty times weighs more than one seen
  once. `:insufficient_data` when no finding qualifies, never a zero over
  zero rows. Every finding ever filed is eligible, so the metric is
  back-filled from history the first time it is read.
  """

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tasks.PhaseTransition
  alias Platform.Tasks.Task, as: TaskRow
  alias Platform.Ux.Finding
  alias Platform.Ux.FrictionWatch

  @window_days 28
  @max_messages 2_000
  @max_terms 8
  @citation ~r/\Achat:([0-9a-fA-F-]{36}):[0-9a-fA-F-]{36}\z/

  @stopwords ~w(about above after again also among because been before being below
                between both cannot could does doing down during each from further have
                having here into itself just more most much need only other ought ours over
                same should some such than that their theirs them then there these they this
                those through under until very what when where which while whom with would
                your yours want like make made still even every thing things really there's
                it's don't can't won't doesn't isn't)

  @type outcome :: %{
          finding_id: String.t(),
          task_id: String.t(),
          shipped_at: DateTime.t(),
          before: non_neg_integer(),
          after: non_neg_integer(),
          drop: float() | nil
        }

  @type summary :: %{
          value: float() | nil,
          n: non_neg_integer(),
          before: non_neg_integer(),
          after: non_neg_integer(),
          pending: non_neg_integer(),
          no_baseline: non_neg_integer(),
          outcomes: [outcome()]
        }

  @doc "The window on each side of a ship, in days."
  @spec window_days() :: pos_integer()
  def window_days, do: @window_days

  @doc """
  The install-wide friction drop, or for the findings `opts[:finding_ids]`
  names. `opts[:now]` fixes the clock (tests). Returns a `t:summary/0`;
  `value` is nil when no settled finding has a baseline.
  """
  @spec summary(keyword()) :: summary()
  def summary(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    shipped =
      opts
      |> Keyword.get(:finding_ids)
      |> shipped_findings()

    {settled, pending} =
      Enum.split_with(shipped, fn {_finding, shipped_at} ->
        DateTime.compare(DateTime.add(shipped_at, @window_days, :day), now) != :gt
      end)

    outcomes = Enum.map(settled, fn {finding, shipped_at} -> outcome(finding, shipped_at) end)
    {with_base, no_base} = Enum.split_with(outcomes, &(&1.before > 0))

    before = Enum.sum(Enum.map(with_base, & &1.before))
    after_count = Enum.sum(Enum.map(with_base, & &1.after))

    %{
      value: if(before > 0, do: 1 - after_count / before, else: nil),
      n: length(with_base),
      before: before,
      after: after_count,
      pending: length(pending),
      no_baseline: length(no_base),
      outcomes: outcomes
    }
  end

  @doc """
  The settled outcomes for the findings filed against `task_id`, each as an
  `t:outcome/0`. Empty when the task has not shipped, its after-window is
  still open, or no finding names it. Used to move pattern-card weights.
  """
  @spec for_task(String.t(), keyword()) :: [outcome()]
  def for_task(task_id, opts \\ []) when is_binary(task_id) do
    ids =
      Repo.all(from(f in Finding, where: f.task_id == ^task_id, select: f.id))

    if ids == [], do: [], else: summary(Keyword.put(opts, :finding_ids, ids)).outcomes
  end

  @doc "One finding's before/after counts around `shipped_at`."
  @spec outcome(Finding.t(), DateTime.t()) :: outcome()
  def outcome(%Finding{} = finding, %DateTime{} = shipped_at) do
    spaces = cited_spaces(finding)
    terms = terms(finding)
    window = @window_days * 86_400

    before = count(spaces, terms, DateTime.add(shipped_at, -window, :second), shipped_at)
    after_count = count(spaces, terms, shipped_at, DateTime.add(shipped_at, window, :second))

    %{
      finding_id: finding.id,
      task_id: finding.task_id,
      shipped_at: shipped_at,
      before: before,
      after: after_count,
      drop: if(before > 0, do: 1 - after_count / before, else: nil)
    }
  end

  @doc "The salient terms of a finding: question and quotes, stopwords out."
  @spec terms(Finding.t()) :: [String.t()]
  def terms(%Finding{question: question, evidence: evidence}) do
    quotes = Map.get(evidence || %{}, "quotes", []) |> Enum.filter(&is_binary/1)

    [question || "" | quotes]
    |> Enum.join(" ")
    |> words()
    |> Enum.frequencies()
    |> Enum.sort_by(fn {word, n} -> {-n, word} end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.take(@max_terms)
  end

  @doc "How many of a finding's terms a message must share to count."
  @spec min_shared([String.t()]) :: pos_integer()
  def min_shared(terms) when length(terms) < 3, do: 1
  def min_shared(_terms), do: 2

  @doc "Does `text` read as the same friction as `terms`?"
  @spec recurrence?(String.t(), [String.t()]) :: boolean()
  def recurrence?(text, terms) when is_binary(text) and is_list(terms) and terms != [] do
    FrictionWatch.friction?(text) and
      MapSet.size(MapSet.intersection(MapSet.new(words(text)), MapSet.new(terms))) >=
        min_shared(terms)
  end

  def recurrence?(_text, _terms), do: false

  # ── internals ──

  defp shipped_findings(finding_ids) do
    first_done =
      from(t in PhaseTransition,
        where: t.to_status == "done",
        group_by: t.task_id,
        select: %{task_id: t.task_id, at: min(t.occurred_at)}
      )

    query =
      from(f in Finding,
        join: task in TaskRow,
        on: task.id == f.task_id,
        left_join: d in subquery(first_done),
        on: d.task_id == task.id,
        where: task.status == "done",
        order_by: [asc: f.inserted_at],
        select: {f, type(coalesce(d.at, task.updated_at), :utc_datetime_usec)}
      )

    query =
      case finding_ids do
        ids when is_list(ids) -> where(query, [f], f.id in ^ids)
        _ -> query
      end

    Repo.all(query)
  end

  defp cited_spaces(%Finding{evidence: evidence}) do
    (Map.get(evidence || %{}, "citations") || [])
    |> Enum.flat_map(fn citation ->
      case Regex.run(@citation, to_string(citation)) do
        [_, space_id] -> [space_id]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp count([], _terms, _from, _to), do: 0
  defp count(_spaces, [], _from, _to), do: 0

  defp count(spaces, terms, from, to) do
    spaces
    |> Chat.list_human_digest_messages_in_spaces(from, to, limit: @max_messages)
    |> Enum.count(&recurrence?(&1.content || "", terms))
  end

  defp words(text) do
    ~r/[\p{L}][\p{L}'’]+/u
    |> Regex.scan(String.downcase(text))
    |> Enum.map(fn [word] -> String.replace(word, "’", "'") end)
    |> Enum.filter(&(String.length(&1) >= 4 and &1 not in @stopwords))
  end
end
