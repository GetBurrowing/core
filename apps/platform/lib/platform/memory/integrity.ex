defmodule Platform.Memory.Integrity do
  @moduledoc """
  Link-graph integrity scanner for the Historian's dreaming loop.

  `scan/1` walks `org_wiki_links` rows whose `target_id` is `NULL`
  (link materialization at write-time could not resolve the target) and
  sorts them into three buckets so the maintenance subagents
  (`Platform.Memory.MaintenanceSubagent`, arriving in a later stage)
  can dispatch a targeted repair fan-out per bucket:

    * `:broken`         — target is genuinely dangling. Basename fallback
      resolves to nothing and the path has not been previously deleted.
      Fix path: rewrite the source page's inline mention to remove the
      wikilink, or a human authors a new target page.

    * `:format_dirty`   — target is stored as a bare basename
      (e.g. `[[identity]]`) that resolves unambiguously to one page via
      `Platform.Org.Wiki.resolve_basename/2`. The read-time resolver
      already round-trips, but the stored form is the class of hallucination
      called out in `feedback_memory_citation`. Fix path: normalize the
      link body to its absolute file_key (`[[org/page/identity.md]]`).

    * `:retired_target` — target has an entry in `Platform.MemoryFeedback`
      with `feedback_kind: "delete"` at exactly that path. The referrer
      still holds a mention of an intentionally-removed page. Fix path:
      strip the mention (or rewrite to the successor page when MemoryFeedback
      later grows redirect semantics — out of scope for this stage).

  Deterministic, pure DB reads — no LLM. The dreaming handler's
  contract is that this scan produces the exact fan-out work list the
  subagents will consume; nondeterminism in categorization would leak
  into audit-log expectations.

  ## Options

    * `:workspace_id` — scope filter passed through both to the source-page
      join and to `Wiki.resolve_basename/2` + `MemoryFeedback.deleted_at_path/2`.
      `nil` selects org-scoped pages (matches `Platform.Org.Wiki`'s
      `filter_workspace(nil)` semantics — `is_nil(workspace_id)` predicate,
      NOT "no filter"). Passing a UUID scopes to that workspace strictly.

    * `:scope` — optional prefix filter on `source_page.file_key`. Accepted
      values: `:org`, `:project`, `:space`, or a raw binary prefix. When
      `nil` (default), no prefix filter applies. The prefixes match the
      first path segment of `file_key` (e.g. `:project` → `project/%`).

    * `:since` — optional `DateTime`. When set, only source pages whose
      `updated_at >= since` are scanned. Enables incremental scans across
      dreaming runs; omit for a full sweep.

    * `:cap` — per-bucket maximum entry count (default 500). Guarantees the
      scan report stays bounded even if a badly-written page dumps hundreds
      of dangling wikilinks. Excess rows are silently dropped — the daily
      cadence means genuine backlogs work themselves down; a single scan
      is not the surface for surfacing pathological cases.

  ## Return shape

      %{
        broken:         [entry],
        format_dirty:   [entry],
        retired_target: [entry]
      }

  where each `entry` is:

      %{
        source_id:            String.t(),   # UUID of the source page
        source_path:          String.t(),   # source page's file_key
        target_path:          String.t(),   # raw wikilink target text
        resolved_target_path: String.t() | nil,
        reason:               String.t()
      }

  `resolved_target_path` is:

    * `nil` for `:broken` and `:retired_target`
    * the resolved file_key for `:format_dirty` (i.e. what the link
      should be rewritten to)

  ## Precedence

  Retired takes precedence over both broken and format_dirty — if a
  target both (a) has a delete row in `MemoryFeedback` AND (b) still
  matches a basename in the current workspace, `:retired_target` wins.
  The intuition: an author explicitly deleted the target, so the
  referrer should be cleaned rather than repaired even if a
  same-basename page has since been reintroduced elsewhere.

  Format_dirty takes precedence over broken when basename resolves.
  """

  import Ecto.Query, only: [where: 3]

  alias Ecto.Adapters.SQL
  alias Platform.MemoryFeedback.Entry
  alias Platform.Org.WikiPage
  alias Platform.Repo

  @default_bucket_cap 500

  @type bucket :: :broken | :format_dirty | :retired_target

  @type entry :: %{
          source_id: String.t(),
          source_path: String.t(),
          target_path: String.t(),
          resolved_target_path: String.t() | nil,
          reason: String.t()
        }

  @type scan_report :: %{
          broken: [entry()],
          format_dirty: [entry()],
          retired_target: [entry()]
        }

  @doc """
  Run an integrity scan. Returns a `t:scan_report/0`.

  See the module doc for opts.
  """
  @spec scan(keyword()) :: scan_report()
  def scan(opts \\ []) when is_list(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    scope = Keyword.get(opts, :scope)
    since = Keyword.get(opts, :since)
    cap = Keyword.get(opts, :cap, @default_bucket_cap)

    dangling = fetch_dangling(workspace_id, scope, since)

    # Preload the workspace-scoped basename map and delete-set once so
    # per-row classification is O(1) rather than O(n_pages) — the naive
    # implementation would re-scan every workspace page for each dangling
    # link (Wiki.resolve_basename/2 does a Repo.all under the hood).
    basename_map = build_basename_map(workspace_id)
    deleted_set = load_deleted_paths(workspace_id)

    classify_all(dangling, basename_map, deleted_set, cap)
  end

  # ── Categorization ───────────────────────────────────────────────────

  defp classify_all(dangling, basename_map, deleted_set, cap) do
    empty = %{broken: [], format_dirty: [], retired_target: []}

    dangling
    |> Enum.reduce(empty, fn row, acc ->
      {bucket, entry} = classify_row(row, basename_map, deleted_set)
      append_capped(acc, bucket, entry, cap)
    end)
    |> Map.new(fn {bucket, list} -> {bucket, Enum.reverse(list)} end)
  end

  defp classify_row(row, basename_map, deleted_set) do
    cond do
      MapSet.member?(deleted_set, row.target_path) ->
        {:retired_target,
         %{
           source_id: row.source_id,
           source_path: row.source_path,
           target_path: row.target_path,
           resolved_target_path: nil,
           reason: "target previously deleted (MemoryFeedback delete row present)"
         }}

      resolved = basename_hit(row.target_path, basename_map) ->
        {:format_dirty,
         %{
           source_id: row.source_id,
           source_path: row.source_path,
           target_path: row.target_path,
           resolved_target_path: resolved,
           reason: "bare-slug link — basename resolves unambiguously to #{resolved}"
         }}

      true ->
        {:broken,
         %{
           source_id: row.source_id,
           source_path: row.source_path,
           target_path: row.target_path,
           resolved_target_path: nil,
           reason: "no basename match, not previously deleted"
         }}
    end
  end

  defp append_capped(acc, bucket, entry, cap) do
    Map.update!(acc, bucket, fn list ->
      if length(list) >= cap, do: list, else: [entry | list]
    end)
  end

  # Basename lookup mirrors `Platform.Org.Wiki.resolve_basename/2`'s
  # matching rule: strip an optional `.md`, reject targets containing
  # `/` (path-shaped targets belong to exact-key / alias resolution,
  # not basename fallback).
  defp basename_hit(target, basename_map) do
    stem = String.replace_suffix(target, ".md", "")

    if stem == "" or String.contains?(stem, "/") do
      nil
    else
      Map.get(basename_map, stem)
    end
  end

  # ── Preload helpers ──────────────────────────────────────────────────

  # `%{basename_stem => file_key}` for stems that resolve unambiguously
  # within the given workspace scope. Stems with 2+ matches are absent
  # from the map (mirrors resolve_basename's zero-or-ambiguous → nil).
  defp build_basename_map(workspace_id) do
    WikiPage
    |> filter_workspace(workspace_id)
    |> Repo.all()
    |> Enum.group_by(fn %WikiPage{file_key: fk} -> basename_stem(fk) end)
    |> Enum.reduce(%{}, fn
      {stem, [%WikiPage{file_key: fk}]}, acc -> Map.put(acc, stem, fk)
      {_stem, _ambiguous}, acc -> acc
    end)
  end

  # Every path with any `feedback_kind: "delete"` row in the default
  # `org_context` namespace and matching workspace scope, collapsed to
  # a set for O(1) membership checks during classification.
  defp load_deleted_paths(workspace_id) do
    Entry
    |> where([e], e.namespace == ^"org_context")
    |> where([e], e.feedback_kind == ^"delete")
    |> maybe_filter_feedback_workspace(workspace_id)
    |> Repo.all()
    |> MapSet.new(fn %Entry{path: path} -> path end)
  end

  # `MemoryFeedback.deleted_at_path/2`'s workspace filter is "nil = no
  # filter", but the scan's workspace_id nil means "org-scoped only" (to
  # match Wiki.filter_workspace). Bridge the two: for org-scoped scans
  # we want deletes where workspace_id IS NULL; for a UUID we want
  # equality.
  defp maybe_filter_feedback_workspace(queryable, nil) do
    where(queryable, [e], is_nil(e.workspace_id))
  end

  defp maybe_filter_feedback_workspace(queryable, workspace_id) do
    where(queryable, [e], e.workspace_id == ^workspace_id)
  end

  defp filter_workspace(queryable, nil) do
    where(queryable, [p], is_nil(p.workspace_id))
  end

  defp filter_workspace(queryable, workspace_id) do
    where(queryable, [p], p.workspace_id == ^workspace_id)
  end

  defp basename_stem(file_key) do
    file_key
    |> Path.basename()
    |> String.replace_suffix(".md", "")
  end

  # ── Dangling-link fetch ──────────────────────────────────────────────

  # Raw SQL because `org_wiki_links` has no Ecto schema (see the sibling
  # pattern at `Platform.Org.Wiki.backlinks/2`). Deterministic ordering
  # by `(source_page.file_key ASC, position ASC)` so multi-run diffs
  # stay stable — the maintenance subagents' audit trail should not
  # jitter across nominally identical scans.
  defp fetch_dangling(workspace_id, scope, since) do
    {conditions, params} = build_filters(workspace_id, scope, since)

    where_sql =
      case conditions do
        [] -> ""
        [_ | _] -> " AND " <> Enum.join(conditions, " AND ")
      end

    sql = """
    SELECT l.source_id, p.file_key, l.target_path
    FROM org_wiki_links l
    JOIN org_wiki_pages p ON p.id = l.source_id
    WHERE l.target_id IS NULL#{where_sql}
    ORDER BY p.file_key ASC, l.position ASC
    """

    %{rows: rows} = SQL.query!(Repo, sql, params)

    Enum.map(rows, fn [source_id_bin, file_key, target_path] ->
      %{
        source_id: Ecto.UUID.load!(source_id_bin),
        source_path: file_key,
        target_path: target_path
      }
    end)
  end

  # Builds the parameterized `AND ...` conditions for the dangling
  # query. Each helper appends its own condition + params so `$N`
  # placeholders stay in step with `params` positions.
  defp build_filters(workspace_id, scope, since) do
    []
    |> put_workspace_filter(workspace_id)
    |> put_scope_filter(scope)
    |> put_since_filter(since)
    |> finalize_filters()
  end

  defp put_workspace_filter(acc, nil), do: [{:workspace_null} | acc]

  defp put_workspace_filter(acc, workspace_id) when is_binary(workspace_id) do
    [{:workspace_eq, Ecto.UUID.dump!(workspace_id)} | acc]
  end

  defp put_scope_filter(acc, nil), do: acc
  defp put_scope_filter(acc, :org), do: [{:scope_prefix, "org/%"} | acc]
  defp put_scope_filter(acc, :project), do: [{:scope_prefix, "project/%"} | acc]
  defp put_scope_filter(acc, :space), do: [{:scope_prefix, "space/%"} | acc]

  defp put_scope_filter(acc, prefix) when is_binary(prefix) do
    [{:scope_prefix, escape_like(prefix) <> "%"} | acc]
  end

  defp put_since_filter(acc, nil), do: acc

  defp put_since_filter(acc, %DateTime{} = since) do
    [{:since, since} | acc]
  end

  # Renders the filter tuples into `(condition, params)` in stable
  # order (workspace, scope, since) so the SQL is deterministic.
  defp finalize_filters(tuples) do
    ordered = Enum.reverse(tuples)

    {conds, params, _idx} =
      Enum.reduce(ordered, {[], [], 1}, fn tuple, {conds, params, idx} ->
        case tuple do
          {:workspace_null} ->
            {conds ++ ["p.workspace_id IS NULL"], params, idx}

          {:workspace_eq, bin} ->
            {conds ++ ["p.workspace_id = $#{idx}"], params ++ [bin], idx + 1}

          {:scope_prefix, pat} ->
            {conds ++ ["p.file_key LIKE $#{idx}"], params ++ [pat], idx + 1}

          {:since, dt} ->
            {conds ++ ["p.updated_at >= $#{idx}"], params ++ [dt], idx + 1}
        end
      end)

    {conds, params}
  end

  defp escape_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
