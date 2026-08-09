defmodule Platform.Federation.ToolArgumentsTest do
  @moduledoc """
  Drift guard for the declared-required survey.

  The survey behind `Platform.Federation.ToolArguments` is only worth having
  if it is re-derived rather than remembered. A committed markdown table would
  rot the first time somebody adds a tool; these tests read
  `ToolSurface.tool_definitions/0` and the handler source and fail when the
  classification stops matching them.

  Three directions of drift are covered:

    * a new `required: true` declaration with no classification;
    * an exemption left behind after its declaration changed;
    * an alias fallback appearing in a handler with no matching declaration
      (the direction that hid `canvas.create`'s `initial_state` alias).
  """
  use ExUnit.Case, async: true

  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolSurface

  # Handler sources the survey covers. `tool_surface.ex` holds most clauses;
  # the rest delegate to these ToolHandlers modules.
  @handler_sources [
    "lib/platform/federation/tool_surface.ex",
    "lib/platform/chat/canvas/tool_handlers.ex",
    "lib/platform/chat/attachments/tool_handlers.ex",
    "lib/platform/skills/tool_handlers.ex"
  ]

  # Ratchet, in the style this repo already uses for `@t6_baseline_tool_count`:
  # the number of `required: true` declarations the survey actually
  # classified. A new declaration is not "enforceable by default" — it is
  # unclassified until somebody reads the handler, and moving this number is
  # how they record that they did.
  #
  # This comment used to cite `@t4_allowed_new_migrations` as a second
  # exemplar; task 019fba52 deleted that attribute. It was a per-item
  # allow-LIST rather than a count, so every branch adding a migration had to
  # edit the same list and they serialised behind the conflict. A single
  # ratchet number is cheaper but not free of that: two branches adding tools
  # both bump this line. Prefer a property of the thing itself (as the
  # migration guard now does, requiring a @moduledoc in the migration) when
  # one is available; a shared counter is the fallback, not the ideal.
  #
  # Counted from `tool_definitions/0` at 9021-line `tool_surface.ex`; the
  # ticket's figure of 119 was already stale when it was filed.
  #
  # 127 -> 126 in stage 5: `stage_list`'s `plan_id` was demoted to
  # `required: false` when `task_id` joined it as a second entry point. The
  # requirement did not go away — it became CONDITIONAL (`plan_id` XOR
  # `task_id`), which a per-parameter gate cannot express, so the tool now
  # refuses in its own handler like `skill.get` does. Moving this number DOWN
  # is the same act as moving it up: somebody read the handler and recorded a
  # ruling.
  #
  # 126 -> 128 at the task 019fa61c merge: `stage_architecture_audit` arrived
  # on a branch that forked before this survey existed, so the two counts were
  # never in textual conflict — the arithmetic was. Both of its `required: true`
  # declarations are HONEST, neither aliased nor aspirational: `stage_id` and
  # `summary` each have a catch-all handler clause that refuses on a non-binary
  # (`stage_not_found` / `missing_summary`), so there is no absence-tolerance
  # for the gate to break. Its third parameter, `findings`, is deliberately
  # `required: false` — a clean audit carries none.
  # 129 as of task 019fe844 stage 3: `design_critique_request`'s `canvas_id`.
  # Classified HONEST *for this tool*, with the nuance stated rather than
  # hidden. One layer down, `Handlers.DesignCritique.gather_context/2` does
  # tolerate an absent canvas id — it falls back to the most recently updated
  # canvas in the trigger space, which is right for a human typing
  # `@saru critique` in a channel. It is wrong for a review gate: a reviewer
  # that guesses which canvas holds its evidence produces a critique of
  # whatever was posted last. So the tool declares the key required and the
  # gate refuses before that fallback is ever reached. Enforcing it breaks no
  # live runtime — the tool ships in this same commit with no callers.
  @surveyed_required_count 129

  defp read_source(relative) do
    # Resolved from __DIR__ (apps/platform/test/platform/federation) rather
    # than cwd, so the guard reads the same files under `mix test` from the
    # app and from the umbrella root.
    Path.expand("../../../#{relative}", __DIR__) |> File.read!()
  end

  defp source_bodies, do: Enum.map(@handler_sources, &read_source/1)

  # `tool_surface.ex` split into `{tool_name, clause_body}` segments, so a
  # default can be attributed to the handler that applies it. Matching a bare
  # key name across the whole file is not good enough: `send_media` defaults
  # `content` and `epic_create` defaults `status`, but both are declared
  # `required: false` there — while `skill.upsert` and `validation_evaluate`
  # declare the same key names required and do NOT default them.
  defp handler_segments do
    source = read_source("lib/platform/federation/tool_surface.ex")

    matches =
      Regex.scan(~r/^  defp? execute\(\s*"([a-z_0-9.]+)"/m, source, return: :index)
      |> Enum.map(fn [{start, _len}, {name_start, name_len}] ->
        {binary_part(source, name_start, name_len), start}
      end)

    starts = Enum.map(matches, &elem(&1, 1))
    ends = Enum.drop(starts, 1) ++ [byte_size(source)]

    matches
    |> Enum.zip(ends)
    |> Enum.map(fn {{name, start}, stop} ->
      {name, binary_part(source, start, stop - start)}
    end)
  end

  describe "the classification is total" do
    test "no `required: true` declaration is added without being classified" do
      actual = length(ToolArguments.all_required_params())

      assert actual == @surveyed_required_count,
             """
             The declared-required surface moved: #{actual} declarations,
             survey classified #{@surveyed_required_count}.

             A `required: true` entry is documentation until something enforces
             it. Before bumping @surveyed_required_count, read the handler and
             decide which the new declaration is:

               * honest      — the handler has no absence-tolerance. Nothing to
                               add; the gate will enforce it.
               * aliased     — the handler reads a second key as a fallback. Add
                               `aliases:` to the parameter map in tool_surface.ex.
               * aspirational — the handler resolves the value elsewhere (call
                               context) or defaults when the key is absent. Add a
                               {tool, param, reason} triple to @behaviour_exempt.

             Enforcing a parameter the handler tolerates as absent is a breaking
             change for live runtimes, which is why this is not automatic.
             """
    end

    test "every exemption carries a non-empty, non-placeholder reason" do
      for {tool, param, reason} <- ToolArguments.behaviour_exempt() do
        assert is_binary(reason) and String.length(String.trim(reason)) >= 30,
               "#{tool}.#{param} is exempt with a reason too short to be a justification: #{inspect(reason)}"

        refute reason =~ ~r/\b(TODO|FIXME|TBD|XXX)\b/,
               "#{tool}.#{param}'s exemption reason is a placeholder, not a ruling: #{inspect(reason)}"
      end
    end
  end

  describe "the classification does not go stale" do
    test "every exemption names a tool that still declares that parameter required" do
      declared =
        MapSet.new(
          for {tool, param} <- ToolArguments.all_required_params(), do: {tool, param.key}
        )

      stale =
        for {tool, param, _reason} <- ToolArguments.behaviour_exempt(),
            not MapSet.member?(declared, {tool, param}),
            do: "#{tool}.#{param}"

      assert stale == [],
             """
             These exemptions no longer correspond to a `required: true` declaration:

               #{Enum.join(stale, "\n  ")}

             An exemption that outlives its declaration silently widens the gate.
             Drop the triple from `@behaviour_exempt`.
             """
    end

    test "every declared alias is actually read by a handler" do
      unread =
        for {tool, param} <- ToolArguments.all_required_params(),
            alias_key <- param.aliases,
            not Enum.any?(
              source_bodies(),
              &String.contains?(&1, ~s|Map.get(args, "#{alias_key}")|)
            ),
            do: "#{tool}.#{param.key} declares alias #{inspect(alias_key)}"

      assert unread == [],
             """
             These aliases are declared but no handler reads them:

               #{Enum.join(unread, "\n  ")}

             An alias nothing reads widens the gate for a key the handler will
             receive as nil — the failure this task exists to remove.
             """
    end
  end

  describe "handler fallbacks are declared" do
    # The direction of drift that hid `canvas.create`'s `initial_state`:
    # a handler grows `Map.get(args, "a") || Map.get(args, "b")` and the
    # declaration never learns about "b". Scanning the source for the pattern
    # means the next one cannot be missed by reading alone.
    test "every arg-to-arg fallback in a handler corresponds to a declared alias" do
      fallbacks =
        source_bodies()
        |> Enum.flat_map(fn body ->
          Regex.scan(
            ~r/Map\.get\(args, "([a-z_0-9]+)"\)\s*\|\|\s*Map\.get\(args, "([a-z_0-9]+)"\)/,
            body
          )
        end)
        |> Enum.map(fn [_full, primary, alias_key] -> {primary, alias_key} end)
        |> Enum.uniq()

      # Pinned exactly, not as a floor: if the regex stops matching the source
      # this guard would silently pass on an empty list. Five call sites
      # collapse to three distinct pairs — `task_id || id` recurs in task_get,
      # task_update and plan_get.
      assert Enum.sort(fallbacks) == [
               {"document", "initial_state"},
               {"stage_id", "id"},
               {"task_id", "id"}
             ],
             "the arg-to-arg fallback scan drifted; found #{inspect(fallbacks)}"

      declared =
        for {_tool, param} <- ToolArguments.all_required_params(),
            alias_key <- param.aliases,
            do: {param.key, alias_key}

      undeclared =
        for {primary, alias_key} <- fallbacks,
            {primary, alias_key} not in declared,
            do: "#{primary} falls back to #{alias_key}"

      assert undeclared == [],
             """
             These handler fallbacks are not declared as aliases:

               #{Enum.join(undeclared, "\n  ")}

             The handler accepts a second key; the declaration says only the
             first is acceptable. A gate built on the declaration alone would
             reject calls that work in production today. Add `aliases:` to the
             parameter map in `tool_surface.ex`.
             """
    end

    test "every defaulted required parameter is recorded as exempt or as a known behaviour change" do
      # `Map.get(args, "x", <default>)` on a declared-required param means
      # absence is a coded-for path. Enforcing it changes an outcome that
      # exists today, so it must be a recorded ruling rather than a surprise.
      defaulted =
        for {tool, body} <- handler_segments(),
            [_full, key] <-
              Regex.scan(
                # Both the direct form `Map.get(args, "k", default)` and the
                # piped form `args |> Map.put_new("k", default)` — task_create
                # applies its wire-compat defaults through the latter.
                ~r/Map\.(?:get|put_new)\((?:args, )?"([a-z_0-9]+)",\s*[^)]/,
                body
              ),
            do: {tool, key}

      required =
        MapSet.new(
          for {tool, param} <- ToolArguments.all_required_params(), do: {tool, param.key}
        )

      recorded =
        MapSet.new(
          Enum.map(ToolArguments.default_on_absence(), fn {t, p, _b} -> {t, p} end) ++
            Enum.map(ToolArguments.behaviour_exempt(), fn {t, p, _r} -> {t, p} end)
        )

      unrecorded =
        for {tool, key} <- Enum.uniq(defaulted),
            MapSet.member?(required, {tool, key}),
            not MapSet.member?(recorded, {tool, key}),
            do: "#{tool}.#{key}"

      assert unrecorded == [],
             """
             These declared-required parameters have a default-on-absence in
             their own handler but appear in neither @default_on_absence nor
             @behaviour_exempt:

               #{Enum.join(unrecorded, "\n  ")}

             A default means the handler already answers without the argument.
             Decide which it is and record it before a gate turns it into an error.
             """

      # Guard against the scan silently matching nothing, and against the
      # clause-attribution regressing to whole-file matching: send_media
      # defaults `content` but does not declare it required, so it must be
      # seen by the scan and filtered by the requirement check rather than
      # never seen at all.
      assert {"plan_create", "stages"} in defaulted
      assert {"principal_search", "query"} in defaulted
      assert {"task_create", "title"} in defaulted
      assert {"send_media", "content"} in defaulted
      refute MapSet.member?(required, {"send_media", "content"})
    end

    test "every recorded default-on-absence names a currently-declared required param" do
      declared =
        MapSet.new(
          for {tool, param} <- ToolArguments.all_required_params(), do: {tool, param.key}
        )

      for {tool, param, behaviour} <- ToolArguments.default_on_absence() do
        assert MapSet.member?(declared, {tool, param}),
               "#{tool}.#{param} is recorded as defaulting but is no longer declared required"

        assert String.contains?(behaviour, "Map.get") or
                 String.contains?(behaviour, "Map.put_new"),
               "#{tool}.#{param}'s note should name the mechanism: #{inspect(behaviour)}"
      end
    end

    test "every context-resolved required parameter is exempt, not merely undeclared" do
      # `Map.get(args, "x") || Map.get(context, :x)` cannot be fixed with an
      # alias — the value never appears in `args` at all — so these must be
      # exemptions. Asserted from source so a new context fallback is caught.
      context_fallbacks =
        source_bodies()
        |> Enum.flat_map(fn body ->
          Regex.scan(
            ~r/Map\.get\(args, "([a-z_0-9]+)"\)\s*\|\|\s*Map\.get\(context, :([a-z_0-9]+)\)/,
            body
          )
        end)
        |> Enum.map(fn [_full, key, _ctx] -> key end)
        |> Enum.uniq()

      assert "space_id" in context_fallbacks,
             "expected the surveyed space_id context fallback; regex found #{inspect(context_fallbacks)}"

      for key <- context_fallbacks do
        exempt_for_key =
          Enum.filter(ToolArguments.behaviour_exempt(), fn {_t, p, _r} -> p == key end)

        refute exempt_for_key == [],
               """
               `#{key}` is resolved from the call context when absent from args,
               but no tool exempts it. A gate would reject context-bound runtimes
               that omit it legitimately.
               """
      end
    end
  end

  describe "required_params/1" do
    test "returns the declared key with no aliases for a plain requirement" do
      assert ToolArguments.required_params("stage_start") == [%{key: "stage_id", aliases: []}]
    end

    test "returns nothing for a tool whose requirement is conditional" do
      # `stage_list` accepts `plan_id` OR `task_id` (stage 5), so neither is
      # declared required and this module has nothing to enforce. The
      # requirement lives in the handler, and `tool_surface_test.exs` owns it.
      assert ToolArguments.required_params("stage_list") == []
    end

    test "returns the alias keys for the id-fallback handlers" do
      for tool <- ~w(task_get task_update plan_get) do
        assert ToolArguments.required_params(tool) == [%{key: "task_id", aliases: ["id"]}],
               "#{tool} should declare `id` as an alias of task_id"
      end

      assert ToolArguments.required_params("stage_complete") == [
               %{key: "stage_id", aliases: ["id"]}
             ]
    end

    test "returns every required parameter for a multi-parameter tool" do
      assert ToolArguments.required_params("react") == [
               %{key: "emoji", aliases: []},
               %{key: "message_id", aliases: []},
               %{key: "space_id", aliases: []}
             ]
    end

    test "omits parameters declared required: false" do
      keys = ToolArguments.required_params("task_create") |> Enum.map(& &1.key)

      assert "project_id" in keys
      refute "description" in keys
      refute "epic_id" in keys
    end

    test "returns [] for an unknown tool and for a tool with no required parameters" do
      assert ToolArguments.required_params("no_such_tool") == []
      assert ToolArguments.required_params("project_list") == []
    end

    test "is pure — the same call twice yields the same result with no process state" do
      assert ToolArguments.required_params("react") == ToolArguments.required_params("react")
    end
  end

  describe "survey totals" do
    test "the declared-required surface matches the catalogue" do
      pairs = ToolArguments.all_required_params()

      from_catalogue =
        for tool <- ToolSurface.tool_definitions(),
            {_key, spec} <- Map.get(tool, :parameters, %{}),
            is_map(spec) and Map.get(spec, :required) == true,
            do: :counted

      assert length(pairs) == length(from_catalogue),
             "required_params/1 dropped or invented declarations: #{length(pairs)} vs #{length(from_catalogue)}"
    end

    test "exactly the surveyed tools carry aliases" do
      aliased =
        for {tool, param} <- ToolArguments.all_required_params(),
            param.aliases != [],
            do: {tool, param.key, param.aliases}

      assert Enum.sort(aliased) == [
               {"canvas.create", "document", ["initial_state"]},
               {"plan_get", "task_id", ["id"]},
               {"stage_complete", "stage_id", ["id"]},
               {"task_get", "task_id", ["id"]},
               {"task_update", "task_id", ["id"]}
             ]
    end
  end
end
