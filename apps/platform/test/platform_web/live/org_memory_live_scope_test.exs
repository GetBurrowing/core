defmodule PlatformWeb.OrgMemoryLiveScopeTest do
  @moduledoc """
  T7 stage 7 — scope-creep guards for OrgMemoryLive (ADR-0041).

  Scope contract: T7 is UI-only. It adds the OrgMemoryLive wiki UI
  (`lib/platform_web/live/org_memory_live*`, routes, components) and
  must not touch the T2 domain surface (`Platform.Org.Wiki`) or the
  federation tool surface (`Platform.Federation.ToolSurface`). Domain
  changes belong in T2/T5 follow-ups, not here.

  Baseline: T5 HEAD `c0a3f9d` ("T5 stage 6: task-level adversarial
  e2e + scope-creep guards"), merged into this branch at `44f13f5`.
  Because the T1–T5 stacked chain was merged in wholesale, a diff
  against `main` would attribute T2's wiki.ex changes to T7 — so the
  guards pin against `c0a3f9d`, the last commit before T7's own work.

  wiki.ex was originally guarded by byte-identity against T5 HEAD
  (nothing outside the stack ever touched it). Amended 2026-06-11:
  Sloane authorized the basename wikilink resolution change
  (`Wiki.resolve_basename/2`), which legitimately modifies the T2
  domain surface on the rollup branch — the byte-identity guard is
  replaced by a sha256 pin of the NEW authorized content (pure
  File.read! + :crypto, no git needed). tool_surface.ex is guarded by
  memory_* definition + execute-clause counts instead: `origin/main`
  legitimately evolves that file for non-memory reasons and the
  rollup merges main, so byte-identity cannot hold there (amended
  2026-06-11 alongside the Sloane-approved doc-string fix that retired
  the `daily_summary` mention).

  Git availability: mirrors the T5 guard idiom in
  `test/platform/federation/tool_surface_t5_e2e_test.exs` — repo root
  discovered from `Mix.Project.project_file/0`, and each git-backed
  assertion skips silently when git can't resolve the repo (e.g. CI
  containers where the worktree's `.git` gitdir isn't mounted). The
  memory_* clause count keeps a pinned fallback so it still asserts
  in-container.
  """
  use ExUnit.Case, async: true

  # T5 HEAD — the baseline commit these guards pin against.
  @t5_head "c0a3f9d"

  # `def execute("memory_` clause count and `name: "memory_` definition
  # count in tool_surface.ex at @t5_head, measured via
  # `git show #{@t5_head}:.../tool_surface.ex`. Used as the fallback
  # baselines when git is unavailable.
  @t5_memory_execute_clause_count 7
  @t5_memory_tool_definition_count 7

  defp app_root, do: Mix.Project.project_file() |> Path.dirname()

  defp repo_root, do: Path.expand("../..", app_root())

  # Returns {:ok, content} with the file's content at @t5_head, or
  # :unavailable when git can't run here (masked .git, no binary).
  defp baseline_content(rel_path) do
    case System.cmd(
           "git",
           ["show", "#{@t5_head}:apps/platform/#{rel_path}"],
           cd: repo_root(),
           stderr_to_stdout: true
         ) do
      {content, 0} -> {:ok, content}
      {_out, _nonzero} -> :unavailable
    end
  rescue
    ErlangError -> :unavailable
  end

  defp count_memory_execute_clauses(src) do
    ~r/def execute\("memory_/
    |> Regex.scan(src)
    |> length()
  end

  defp count_memory_tool_definitions(src) do
    ~r/name: "memory_/
    |> Regex.scan(src)
    |> length()
  end

  # Rollup amendment (Sloane, 2026-06-11): the original guard byte-pinned
  # wiki.ex against T5 HEAD (#{@t5_head}). This commit's basename
  # wikilink resolution (`Wiki.resolve_basename/2` + its private
  # `basename_stem/1` helper and doc updates) legitimately modifies the
  # T2 domain surface under Sloane's authorization, so the byte-identity
  # check is replaced by a sha256 pin of the NEW wiki.ex content. Any
  # further drift still fails here — regenerate the constant only in
  # the same commit as another authorized domain change. Pure
  # File.read! + :crypto, so this asserts even where git is unavailable.
  #
  # Re-pinned 2026-07-11 (task 019f4f55 stage 2): the Historian chunked
  # threshold-pass plan authorizes two additive accessors on
  # `Platform.Org.Wiki` — `list_pages_updated_since/2` and
  # `list_journal_entries_since/2` — so the windowed dispatcher can
  # scope each pages/journal digest to a single `[window_start,
  # window_end)` range. Pure list-Ecto helpers, no behavioural
  # changes to any existing surface.
  @wiki_ex_sha256_2026_07_11 "06e9ac5d8c4ac7f86fbde0b21c83dfba333a7570cc02f2a23b3e7d1b102d5e72"

  test "wiki.ex matches the 2026-07-11 authorized domain surface (sha256 pin)" do
    rel_path = "lib/platform/org/wiki.ex"
    contents = File.read!(Path.join(app_root(), rel_path))
    hash = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

    assert hash == @wiki_ex_sha256_2026_07_11,
           """
           Scope-creep detected: #{rel_path} drifted from the 2026-07-11
           authorized content (task 019f4f55 stage 2 — Historian windowed
           dispatch accessors).
           Expected sha256: #{@wiki_ex_sha256_2026_07_11}
           Got sha256:      #{hash}
           Domain changes to Platform.Org.Wiki require explicit authorization
           — re-pin this constant in the same commit as the authorized change.
           """
  end

  # Rollup amendment (Sloane, 2026-06-11): the original guard byte-pinned
  # tool_surface.ex against T5 HEAD. That cannot hold on the rollup
  # branch — `origin/main` legitimately evolves this file for non-memory
  # reasons (e.g. StackDeployer wiring) and the rollup merges main. The
  # byte-pin is replaced by the two invariants it was protecting: the
  # memory_* tool DEFINITIONS count (below) and the memory_* execute
  # clause count (next test) both still match T5 HEAD. Growth of either
  # means someone snuck a memory-surface change past a T5 follow-up.
  test "no new memory_* tool definitions were added to tool_surface.ex" do
    rel_path = "lib/platform/federation/tool_surface.ex"
    current_count = count_memory_tool_definitions(File.read!(Path.join(app_root(), rel_path)))

    baseline_count =
      case baseline_content(rel_path) do
        {:ok, baseline} -> count_memory_tool_definitions(baseline)
        :unavailable -> @t5_memory_tool_definition_count
      end

    assert current_count == baseline_count,
           """
           Scope-creep detected: tool_surface.ex defines #{current_count}
           `name: "memory_..."` tools; T5 HEAD (#{@t5_head}) had
           #{baseline_count}. Memory tool-surface changes belong in a T5
           follow-up task, not in the OrgMemoryLive task or rollup.
           """
  end

  test "no new memory_* execute clauses were added to tool_surface.ex" do
    # Implied by the byte-identity guard above, but asserted separately
    # so the failure message stays precise if that guard is ever relaxed.
    rel_path = "lib/platform/federation/tool_surface.ex"
    current_count = count_memory_execute_clauses(File.read!(Path.join(app_root(), rel_path)))

    baseline_count =
      case baseline_content(rel_path) do
        {:ok, baseline} -> count_memory_execute_clauses(baseline)
        :unavailable -> @t5_memory_execute_clause_count
      end

    assert current_count == baseline_count,
           """
           Scope-creep detected: tool_surface.ex has #{current_count}
           `def execute("memory_...")` clauses; T5 HEAD (#{@t5_head}) had
           #{baseline_count}. T7 is UI-only — new memory_* tools (and any
           other domain/tool-surface growth) belong in T2/T5 follow-ups,
           not in the OrgMemoryLive task.
           """
  end
end
