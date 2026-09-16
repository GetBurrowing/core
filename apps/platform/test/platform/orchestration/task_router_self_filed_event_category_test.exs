defmodule Platform.Orchestration.TaskRouterSelfFiledEventCategoryTest do
  @moduledoc """
  Task 01a0a6e3 stage 3 — the category guard.

  ## Scope

  This guard covers every `record_runtime_event` emit site in
  `lib/platform/orchestration/task_router.ex` that passes
  `RuntimeSupervision.self_filed_runtime_id()` as its `"runtime_id"`, and
  nothing else. It is stated as scope rather than as a list of exceptions
  because an exception list rots the moment the module grows, which is the
  defect class this file exists to catch.

  ## The property

  The router subscribes to `tasks:board`, so every event it records with the
  self-filed runtime id comes back to it as a `{:runtime_event, event}`
  message. Each such event type is therefore a DECISION: either the router
  must ignore its own copy (a `defp apply_runtime_event(state, %{event_type:
  "<t>"}), do: state` clause) or it must deliberately process it (a key of
  `TaskRouter.self_processed_self_filed_types/0`, with a non-blank reason).

  A self-filed event type in NEITHER place is an undeclared decision. That is
  exactly how `execution.dispatch_stageless` and `execution.dispatch_unanswered`
  arrived (task 01a0a5fa, PR #1023, 116af786, 2026-09-15 20:06:29Z) and sat
  unhandled: nothing failed, because nothing was looking.

  ## Why the emit sites are read from SOURCE and the allowlist from RUNTIME

  There is no runtime reflection for `defp` clause heads and no runtime
  enumeration of emit sites, so both of those must be read out of the source
  text. The allowlist, by contrast, is exposed as a compiled function
  (`TaskRouter.self_processed_self_filed_types/0`, added by stage 1), and the
  compiled value is strictly more trustworthy than a regex over the module
  attribute literal: it survives reformatting, multi-line string concatenation
  and `@attr` indentation changes, all of which a source regex gets wrong
  silently. Where a runtime read is available this guard takes it.

  ## Why a syntactic scan is allowed to be wrong LOUDLY but never quietly

  A guard keyed on spelling stops asserting when the code changes shape, and
  does so in the passing direction. So the scan below flunks with a named
  failure — `emit sites are no longer visible to this guard` — if a self-filed
  line yields no `"event_type"` literal in its look-ahead window, and asserts a
  floor on the number of sites found, so that a regex matching nothing cannot
  be read as "every site satisfied".
  """

  use ExUnit.Case, async: true

  alias Platform.Orchestration.TaskRouter

  @router_source Path.join([
                   __DIR__,
                   "..",
                   "..",
                   "..",
                   "lib",
                   "platform",
                   "orchestration",
                   "task_router.ex"
                 ])
                 |> Path.expand()

  # `"runtime_id" => ...self_filed_runtime_id()` and the `"event_type" => "..."`
  # literal sit on adjacent lines at every site on today's tree (verified at
  # 2041/2042, 2104/2105, 2188/2189, 5404/5405). The window is deliberately
  # larger than 1 so that inserting a key between them does not break the guard,
  # and deliberately small so it cannot wander into the NEXT attrs map.
  @lookahead 6

  # A floor on EMIT SITES, not on distinct event types. Today the four sites
  # yield three distinct types, because both `execution.blocked` emitters
  # (record_unresolved_stage_blocker/4 and record_review_unrunnable_blocker/4)
  # share a type. Putting the floor on the distinct-type set would make this
  # assertion false on the very tree it was written against.
  @minimum_emit_sites 4

  defp source, do: File.read!(@router_source)

  defp source_lines, do: source() |> String.split("\n")

  # Comment lines are excluded: the clause list carries a prose comment naming
  # `RuntimeSupervision.self_filed_runtime_id()`, and a comment is not an emit
  # site. Everything else that mentions the function IS treated as a site, so a
  # real site written in an unexpected shape flunks loudly rather than vanishing.
  defp self_filed_lines do
    source_lines()
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} ->
      String.contains?(line, "self_filed_runtime_id()") and
        not String.starts_with?(String.trim_leading(line), "#")
    end)
  end

  defp event_type_after(lines, index) do
    lines
    |> Enum.slice(index, @lookahead)
    |> Enum.find_value(fn line ->
      case Regex.run(~r/"event_type"\s*=>\s*"([^"]+)"/, line) do
        [_, type] -> type
        nil -> nil
      end
    end)
  end

  # {line_number, event_type_or_nil} for every self-filed emit site.
  defp emit_sites do
    lines = source_lines()

    Enum.map(self_filed_lines(), fn {_line, n} ->
      {n, event_type_after(lines, n)}
    end)
  end

  defp noop_clause_types do
    ~r/defp\s+apply_runtime_event\(\s*state\s*,\s*%\{event_type:\s*"([^"]+)"\}\s*\)\s*,\s*do:\s*state/
    |> Regex.scan(source())
    |> Enum.map(fn [_, type] -> type end)
    |> MapSet.new()
  end

  describe "self-filed emit site category guard" do
    test "the guard can still see the emit sites" do
      sites = emit_sites()

      blind =
        sites
        |> Enum.filter(fn {_n, type} -> is_nil(type) end)
        |> Enum.map(fn {n, _} -> n end)

      assert blind == [],
             """
             emit sites are no longer visible to this guard.

             These lines in #{@router_source} call
             RuntimeSupervision.self_filed_runtime_id() but no "event_type" => "..."
             literal was found within #{@lookahead} lines after them: #{inspect(blind)}

             The router's self-filed emit sites have changed shape, so this guard
             has stopped asserting anything about them. Do NOT relax this test to
             make it pass: either restore the adjacency, or teach the scan the new
             shape. A category guard that silently drops a site is the exact defect
             this file exists to prevent.
             """
    end

    test "the guard finds at least #{@minimum_emit_sites} self-filed emit sites" do
      sites = emit_sites()

      assert length(sites) >= @minimum_emit_sites,
             """
             found only #{length(sites)} self-filed emit site(s) in #{@router_source},
             expected at least #{@minimum_emit_sites}.

             A scan that matches nothing would otherwise pass this file as
             "every site satisfied". If emit sites were legitimately removed,
             lower this floor deliberately and say why in the commit.

             Sites found: #{inspect(sites)}
             """
    end

    test "every self-filed event type is either noop'd or declared self-processed" do
      noops = noop_clause_types()
      declared = TaskRouter.self_processed_self_filed_types()

      types =
        emit_sites()
        |> Enum.reject(fn {_n, type} -> is_nil(type) end)
        |> Enum.map(fn {_n, type} -> type end)
        |> MapSet.new()

      refute Enum.empty?(types),
             "no self-filed event types were extracted from #{@router_source} — the guard is inert"

      undeclared =
        types
        |> Enum.reject(fn type ->
          MapSet.member?(noops, type) or Map.has_key?(declared, type)
        end)
        |> Enum.sort()

      assert undeclared == [],
             """
             undeclared self-filed event type(s): #{inspect(undeclared)}

             The TaskRouter emits these with RuntimeSupervision.self_filed_runtime_id(),
             so it receives its own copy back over tasks:board — but nothing in
             task_router.ex says what should happen when it does.

             Decide, and record the decision in the code:

               * If the router must IGNORE its own copy, add
                   defp apply_runtime_event(state, %{event_type: "<type>"}), do: state
                 beside the existing noop clauses, with a one-line reason.

               * If the router must PROCESS its own copy, add a key to
                 @self_processed_self_filed_types with the reason WHY — the reason
                 is what stops the next reader tidying the clause list into
                 consistency, and the tidy is the regression.

             Noop'd today: #{inspect(Enum.sort(noops))}
             Declared self-processed today: #{inspect(Enum.sort(Map.keys(declared)))}
             """
    end

    test "every declared self-processed type is still a live emit type" do
      declared = TaskRouter.self_processed_self_filed_types()

      types =
        emit_sites()
        |> Enum.reject(fn {_n, type} -> is_nil(type) end)
        |> Enum.map(fn {_n, type} -> type end)
        |> MapSet.new()

      stale =
        declared
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(types, &1))
        |> Enum.sort()

      assert stale == [],
             """
             stale @self_processed_self_filed_types entries: #{inspect(stale)}

             These types are declared as deliberately-not-noop'd, but no emit site
             in #{@router_source} produces them any more. An allowlist entry for a
             removed emitter is a decision about code that no longer exists; it
             makes the clause list look reasoned when it is not. Delete the entry.

             Live self-filed emit types: #{inspect(Enum.sort(MapSet.to_list(types)))}
             """
    end

    test "every declared self-processed type carries a non-blank reason" do
      blank =
        TaskRouter.self_processed_self_filed_types()
        |> Enum.filter(fn {_type, reason} ->
          not is_binary(reason) or String.trim(reason) == ""
        end)
        |> Enum.map(fn {type, _} -> type end)
        |> Enum.sort()

      assert blank == [],
             """
             @self_processed_self_filed_types entries with no reason: #{inspect(blank)}

             The reason string IS the artefact. Without it the next reader sees an
             inconsistent clause list, tidies it, and the tidy silently disables
             router self-blocking.
             """
    end
  end
end
