defmodule Platform.Tasks.DeliverySweep do
  @moduledoc """
  On-demand sweep that lists open tickets whose work looks delivered
  (task 01a044b0). It REPORTS; it never closes.

  ## Never closes

  This module reads tasks and asks GitHub (through the
  `Platform.Tasks.DeliveryReference.Runner` seam) and returns a report.
  It performs no write of any kind. Closing stays a verified, deliberate
  act through `task_close_as_delivered`, because a wrong close deletes a
  ticket's reasoning from the open board: the person who reads this
  report decides, and that tool checks the reference.

  ## Why on demand and not a scheduled responsibility

  The report's only consumer is someone who then decides and calls
  `task_close_as_delivered`. A cron with nobody to hand its answer to
  repeats the `tasks.triage` failure (its output was thrown away daily
  and it was declared inert). GitHub code search is heavily rate-limited,
  so an unattended pass over every open ticket is not free;
  `:max_code_searches` bounds each call. A schedule can be layered on
  later by calling `run/1`.

  ## What is scanned

  Open tasks are those in `Platform.Tasks.undeliverable_statuses/0` (the
  set `task_close_as_delivered` accepts), not soft-deleted, optionally
  limited to one `:project_id`. Tasks are grouped by the GitHub slug of
  their project's `repo_url`; the merged-PR list is fetched once per
  slug, and a PR can only surface tasks whose project points at that
  same repository.

  ## Two kinds of candidate

    * `"id-named-in-commit"` — a merged PR's title or body names the task
      by full UUID, or by an 8-hex prefix that
      `Platform.Tasks.DeliverySweep.Matcher.resolve_prefix/1` resolves to
      exactly one task (`{:unique, id}`). An ambiguous prefix produces no
      candidate and is listed under `ambiguous_prefixes`.
    * `"defect-string-absent"` — for a task with no id-named candidate:
      every code-like backtick token from its description that a merged
      PR (merged at or after the task was created) names in its title or
      body is no longer found by GitHub code search. This deliberately
      narrows the idea "a commit names its replacement" to something
      checkable: a later merged PR names the token, and the token is gone.
      Any token still present means no candidate.

  ## Nothing vanishes

  Every scanned task ends in exactly one of: a candidate, `cannot_verify`
  (no usable repo, a runner without the listing callbacks, or GitHub
  unavailable), or no finding (which includes tasks whose searches were
  cut off by `:max_code_searches`, listed under `not_checked`). An
  unavailable answer is never read as an empty one.
  """

  import Ecto.Query, warn: false

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.DeliveryReference
  alias Platform.Tasks.DeliverySweep.Matcher
  alias Platform.Tasks.Project
  alias Platform.Tasks.RepoRef
  alias Platform.Tasks.Task

  @default_pr_limit 100
  @default_max_code_searches 20

  @doc "Default `:pr_limit`."
  @spec default_pr_limit() :: pos_integer()
  def default_pr_limit, do: @default_pr_limit

  @doc "Default `:max_code_searches`."
  @spec default_max_code_searches() :: non_neg_integer()
  def default_max_code_searches, do: @default_max_code_searches

  @no_repo_reason "project has no usable repo_url"
  @no_project_reason "task has no project"

  @type report :: %{
          candidates: [map()],
          cannot_verify: [map()],
          not_checked: [map()],
          ambiguous_prefixes: [map()],
          scanned: %{
            tasks: non_neg_integer(),
            projects: non_neg_integer(),
            prs_by_slug: %{String.t() => non_neg_integer()}
          }
        }

  @doc """
  Runs the sweep. Options: `:project_id`, `:pr_limit` (default
  #{@default_pr_limit}), `:max_code_searches` (default
  #{@default_max_code_searches}), `:runner` (default
  `DeliveryReference.runner/0`).
  """
  @spec run(keyword()) :: {:ok, report()}
  def run(opts \\ []) when is_list(opts) do
    runner = Keyword.get_lazy(opts, :runner, &DeliveryReference.runner/0)
    pr_limit = Keyword.get(opts, :pr_limit, @default_pr_limit)
    max_searches = Keyword.get(opts, :max_code_searches, @default_max_code_searches)

    tasks = load_open_tasks(Keyword.get(opts, :project_id))
    projects = load_projects(tasks)

    {groups, unscoped} = group_by_slug(tasks, projects)

    acc = %{
      candidates: [],
      cannot_verify: unscoped,
      not_checked: [],
      ambiguous_prefixes: [],
      prs_by_slug: %{},
      searches_left: max_searches
    }

    acc =
      if listing_runner?(runner) do
        Enum.reduce(groups, acc, fn {slug, slug_tasks}, acc ->
          sweep_slug(slug, slug_tasks, runner, pr_limit, acc)
        end)
      else
        reason =
          "runner #{inspect(runner)} does not implement merged_pull_requests/2 and code_search/2"

        unverifiable =
          for {_slug, slug_tasks} <- groups, task <- slug_tasks, do: cannot_verify(task, reason)

        %{acc | cannot_verify: acc.cannot_verify ++ unverifiable}
      end

    {:ok,
     %{
       candidates:
         acc.candidates
         |> Enum.uniq_by(&{&1.task_id, &1.pr_number, &1.confidence})
         |> Enum.sort_by(&{&1.task_id, &1.pr_number}),
       cannot_verify: Enum.sort_by(acc.cannot_verify, & &1.task_id),
       not_checked: acc.not_checked,
       ambiguous_prefixes:
         acc.ambiguous_prefixes
         |> Enum.uniq_by(&{&1.prefix, &1.pr.number})
         |> Enum.sort_by(&{&1.prefix, &1.pr.number}),
       scanned: %{
         tasks: length(tasks),
         projects: map_size(projects),
         prs_by_slug: acc.prs_by_slug
       }
     }}
  end

  # ── loading ────────────────────────────────────────────────────────────

  defp load_open_tasks(project_id) do
    Task
    |> where([t], is_nil(t.deleted_at))
    |> where([t], t.status in ^Tasks.undeliverable_statuses())
    |> maybe_filter_project(project_id)
    |> order_by([t], asc: t.id)
    |> Repo.all()
  end

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, id), do: where(query, [t], t.project_id == ^id)

  defp load_projects(tasks) do
    ids = tasks |> Enum.map(& &1.project_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Project
    |> where([p], p.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # Returns {[{slug, [task]}], [cannot_verify entry]}. Every task lands on
  # one side or the other.
  defp group_by_slug(tasks, projects) do
    {scoped, unscoped} =
      Enum.reduce(tasks, {%{}, []}, fn task, {scoped, unscoped} ->
        case Map.get(projects, task.project_id) do
          nil ->
            {scoped, [cannot_verify(task, @no_project_reason) | unscoped]}

          project ->
            case RepoRef.normalize(project.repo_url) do
              {:ok, slug} ->
                key = String.downcase(slug)

                {Map.update(scoped, key, {slug, [task]}, fn {s, ts} -> {s, [task | ts]} end),
                 unscoped}

              :error ->
                {scoped, [cannot_verify(task, @no_repo_reason) | unscoped]}
            end
        end
      end)

    groups =
      scoped
      |> Map.values()
      |> Enum.map(fn {slug, ts} -> {slug, Enum.reverse(ts)} end)
      |> Enum.sort_by(&elem(&1, 0))

    {groups, Enum.reverse(unscoped)}
  end

  defp listing_runner?(runner) do
    Code.ensure_loaded?(runner) and function_exported?(runner, :merged_pull_requests, 2) and
      function_exported?(runner, :code_search, 2)
  end

  # ── per slug ───────────────────────────────────────────────────────────

  defp sweep_slug(slug, tasks, runner, pr_limit, acc) do
    case runner.merged_pull_requests(slug, pr_limit) do
      {:ok, prs} ->
        acc = %{acc | prs_by_slug: Map.put(acc.prs_by_slug, slug, length(prs))}
        in_scope = Map.new(tasks, &{&1.id, &1})

        {id_candidates, ambiguous} = id_named(prs, in_scope)
        named_ids = MapSet.new(id_candidates, & &1.task_id)

        acc = %{
          acc
          | candidates: acc.candidates ++ id_candidates,
            ambiguous_prefixes: acc.ambiguous_prefixes ++ ambiguous
        }

        tasks
        |> Enum.reject(&MapSet.member?(named_ids, &1.id))
        |> Enum.reduce(acc, &defect_sweep(&1, slug, prs, runner, &2))

      {:error, {:unavailable, msg}} ->
        %{acc | cannot_verify: acc.cannot_verify ++ Enum.map(tasks, &cannot_verify(&1, msg))}
    end
  end

  # ── id-named-in-commit ─────────────────────────────────────────────────

  defp id_named(prs, in_scope) do
    Enum.reduce(prs, {[], []}, fn pr, {cands, ambiguous} ->
      text = pr_text(pr)
      %{full: full, prefixes: prefixes} = Matcher.id_references(text)

      full_cands =
        for id <- full,
            task = Map.get(in_scope, id),
            do: candidate(task, pr, "id-named-in-commit", Matcher.evidence_line(text, id))

      {prefix_cands, prefix_ambiguous} =
        Enum.reduce(prefixes, {[], []}, fn prefix, {pc, pa} ->
          case Matcher.resolve_prefix(prefix) do
            {:unique, id} ->
              case Map.get(in_scope, id) do
                nil ->
                  {pc, pa}

                task ->
                  cand =
                    candidate(task, pr, "id-named-in-commit", Matcher.evidence_line(text, prefix))

                  {[cand | pc], pa}
              end

            {:ambiguous, ids} ->
              {pc, [%{prefix: prefix, task_ids: ids, pr: pr_ref(pr)} | pa]}

            :none ->
              {pc, pa}
          end
        end)

      {cands ++ full_cands ++ Enum.reverse(prefix_cands),
       ambiguous ++ Enum.reverse(prefix_ambiguous)}
    end)
  end

  # ── defect-string-absent ───────────────────────────────────────────────

  defp defect_sweep(task, slug, prs, runner, acc) do
    later_prs = Enum.filter(prs, &merged_at_or_after?(&1, task.inserted_at))

    named_tokens =
      task.description
      |> Matcher.defect_tokens()
      |> Enum.flat_map(fn token ->
        case Enum.find(later_prs, &String.contains?(pr_text(&1), token)) do
          nil -> []
          pr -> [{token, pr}]
        end
      end)

    check_tokens(task, slug, named_tokens, runner, acc, [])
  end

  # All named tokens absent => one candidate per token. Any token present
  # => no candidate. Unavailable => cannot_verify. Cap reached => the
  # remaining tokens go to not_checked and the task yields no candidate.
  defp check_tokens(_task, _slug, [], _runner, acc, []), do: acc

  defp check_tokens(_task, _slug, [], _runner, acc, absent) do
    %{acc | candidates: acc.candidates ++ Enum.reverse(absent)}
  end

  defp check_tokens(task, _slug, tokens, _runner, %{searches_left: left} = acc, _absent)
       when left <= 0 do
    skipped =
      Enum.map(tokens, fn {token, _pr} ->
        %{task_id: task.id, token: token, reason: "max_code_searches reached"}
      end)

    %{acc | not_checked: acc.not_checked ++ skipped}
  end

  defp check_tokens(task, slug, [{token, pr} | rest], runner, acc, absent) do
    acc = %{acc | searches_left: acc.searches_left - 1}

    case runner.code_search(slug, token) do
      {:ok, []} ->
        evidence =
          "`#{token}` not found by code search on #{slug}; named by ##{pr["number"]}: " <>
            (Matcher.evidence_line(pr_text(pr), token) || "")

        cand = candidate(task, pr, "defect-string-absent", evidence)
        check_tokens(task, slug, rest, runner, acc, [cand | absent])

      {:ok, [_ | _]} ->
        acc

      {:error, {:unavailable, msg}} ->
        %{acc | cannot_verify: acc.cannot_verify ++ [cannot_verify(task, msg)]}
    end
  end

  defp merged_at_or_after?(pr, inserted_at) do
    with merged when is_binary(merged) <- pr["mergedAt"],
         {:ok, merged_at, _offset} <- DateTime.from_iso8601(merged) do
      DateTime.compare(merged_at, inserted_at) != :lt
    else
      _ -> false
    end
  end

  # ── shapes ─────────────────────────────────────────────────────────────

  defp pr_text(pr), do: to_string(pr["title"]) <> "\n" <> to_string(pr["body"])

  defp pr_ref(pr), do: %{number: pr["number"], url: pr["url"]}

  defp candidate(task, pr, confidence, evidence) do
    %{
      task_id: task.id,
      title: task.title,
      status: task.status,
      confidence: confidence,
      pr_number: pr["number"],
      pr_url: pr["url"],
      merge_commit: merge_commit(pr["mergeCommit"]),
      merged_at: pr["mergedAt"],
      evidence: evidence
    }
  end

  defp merge_commit(%{"oid" => oid}), do: oid
  defp merge_commit(_), do: nil

  defp cannot_verify(task, reason),
    do: %{task_id: task.id, project_id: task.project_id, reason: reason}
end
