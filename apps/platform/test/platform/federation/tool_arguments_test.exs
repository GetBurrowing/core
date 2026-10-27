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
      (the direction that hid `canvas_create`'s `initial_state` alias).
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
  # refuses in its own handler like `skill_get` does. Moving this number DOWN
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
  # 131 as of task 01a00570 stage 2: `review_request_get`'s `review_request_id`
  # and `review_item_list`'s `task_id`. Both HONEST. Each handler opens with
  # `require_string/3`, which refuses a missing or non-binary value before any
  # lookup runs — there is no absence-tolerance below it, and there must not
  # be: both tools authorize on the id they are given, so a tolerated absence
  # would be an unscoped read of a surface that carries a human's private
  # assessment.
  # 132 as of task 01a006c2 stage 1: `task_transition_list`'s `task_id`.
  # HONEST. The handler opens with `require_string/3` and deliberately declares
  # no `"id"` alias — an absent task_id must refuse, because falling through to
  # `list_for_task(nil)` would return the zero-row "this task predates the
  # instrumentation" shape for a call that named no task at all, which is the
  # exact false reading the tool exists to remove.
  # 134 as of task 01a006c2 stage 2: `runtime_event_list`'s and
  # `execution_lease_list`'s `task_id`. Both HONEST, for the same reason as
  # stage 1 and carrying its finding forward — each handler opens with
  # `require_string/3` and declares no `"id"` alias. A tolerated absence would
  # return a confident empty event/lease list about a task the caller never
  # identified, and an empty lease list is ALREADY a legitimate answer here
  # (leases are created only by the blocker path, never by dispatch), so the
  # two cases would be indistinguishable.
  # 135 with `space_create`'s `name`. HONEST: the handler opens with
  # `require_string(args, "name", "space_create")` and declares no alias. A
  # tolerated absence would create a nameless channel, and the slug is derived
  # from the name, so there would be nothing left to identify the space by.
  # 137 with `dm_create`'s `user_id` and `message` (task 01a04ad4). Both
  # HONEST. The handler opens with two `require_string/3` calls, declares no
  # alias for either key, and defaults neither. A tolerated absent `user_id`
  # would be a DM addressed to nobody; a tolerated absent `message` would open
  # a silent, empty conversation in a person's rail — a notification with
  # nothing in it, which is the exact noise failure the tool's own description
  # argues against.
  # 138 with `stack_retry_member_merge`'s `task_id` (task 01a05392 stage 3).
  # HONEST. The handler opens with `require_string/3`, declares no `"id"`
  # alias, and defaults nothing: an absent task id must refuse, because the
  # deployer's id arity would otherwise be asked to merge `nil` — and this is
  # the MEMBER id, not the stack id, so the refusal is also the one place the
  # caller is told which id the tool wants.
  # 140 with `plan_reject`'s `plan_id` + `rejection_reason` (task 01a05b32
  # stage 1). Both HONEST. `plan_id` resolves through `get_by_uuid/2` — an
  # absent or non-UUID id lands in the "Plan not found" envelope (same path
  # as plan_submit / plan_approve), never a write; `rejection_reason` opens
  # with `require_non_blank_string/3`, which refuses absence AND a blank or
  # whitespace value, because the reason is the artifact future planners
  # read to learn why the draft died.
  # 142 with `plan_update`'s `plan_id` + `stages` (task 01a05b32 stage 2).
  # Both HONEST. `plan_id` resolves through `get_by_uuid/2` exactly like
  # plan_reject's — absent or non-UUID is the not-found envelope, never a
  # write. `stages` is refused before any lookup by
  # `require_plan_update_stages/1`: missing or non-list, AND an empty array
  # (a draft keeps at least one stage — an empty draft would submit a plan
  # the engine treats as unapprovable), both recoverable parameter errors
  # with nothing written.
  # 144 with `meeting_say`'s `room_name` + `text` (task 01a06672 stage 2).
  # Both HONEST. The handler reads each under its declared key only, with no
  # alias and no context fallback, and hands both to `Meetings.say/4`, which
  # refuses a blank text (`:empty_text`) and an unknown room
  # (`:room_not_found`) before anything is broadcast. Neither is tolerated
  # absent: a say with no text has nothing to speak, and a say with no room
  # has nowhere to speak it.
  # 146 with `meeting_activity_push`'s `meeting_id` + `state` (task 01a07400
  # stage 1). Both HONEST. `meeting_id` is read under its declared key only
  # and goes to `Meetings.get_meeting/1`, which answers `nil` for a missing
  # or malformed id and is turned into a refusal before anything is written;
  # `state` is looked up in a closed two-entry map with a catch-all clause
  # that refuses every non-binary, including absence. Neither is tolerated
  # absent, and neither may be: a declaration with no meeting has no rail to
  # appear on, and one with no state is not a declaration.
  # 150 with `report_blocker`'s `attempts` + `memory_ref` + `unblock_action` +
  # `category` (task 01a08c1e stage 1). All four HONEST. Each is read under
  # its declared key only and checked by `validate_blocker_args/1` before
  # `record_runtime_event/1`: fewer than three distinct non-blank attempts, a
  # blank memory_ref or unblock_action, or a category outside
  # infra|product|decision is a recoverable refusal naming every missing
  # field, with nothing written. None is tolerated absent, and none may be:
  # a blocker is expensive by design, and the cost IS these four fields.
  # 152 with `task_close_as_delivered`'s `task_id` + `delivery_reference`
  # (task 01a0a552 stage 3). Both HONEST. Each is read under its declared
  # key only, with no alias and no context fallback. `task_id` goes to
  # `Tasks.get_task_record/1` behind `require_string/3`, so absent or
  # malformed is a refusal envelope and never a write. `delivery_reference`
  # is the whole point of the tool: it is required, trimmed, parsed
  # strictly by `Platform.Tasks.DeliveryReference` and RESOLVED against the
  # project's repository before `close_as_delivered/4` is called, and
  # `Tasks.close_as_delivered/4` independently refuses a blank one with
  # `:delivery_reference_required`. Neither is tolerated absent, and
  # `delivery_reference` may not be: a closure with no checkable reference
  # is the free-text close this tool exists to prevent.
  # 169 with the `experiments` bundle's 17 declarations (task 01a0d415
  # stage 2): `experiment_id` on get/variant_add/start/stop/conclude/results/
  # signals_list/exclude/promote (9), `surface_key` + `surface_target` +
  # `name` on create (3), `slug` + `payload` on variant_add (2), `subject_id`
  # + `reason` on exclude (2), `variant` on promote (1). All HONEST: each is
  # read under its declared key only, in `Platform.Experiments.Tools`, with
  # no alias and no context fallback, and an absent or blank value is the
  # `missing_<param>` refusal envelope before any read or write.
  # 172 with `validation_payload_amend`'s `validation_id` + `evaluation_payload`
  # + `reason` (task 01a0acb4 stage 2). All three HONEST: each is read under
  # its declared key only, with no alias and no context fallback.
  # `validation_id` and `reason` open with `require_non_blank_string/3`
  # (absent, non-binary or blank is a recoverable parameter error before any
  # lookup); `evaluation_payload` is refused unless it is a map by
  # `require_amend_payload/1`, also before any lookup. None is tolerated
  # absent, and `reason` may not be: the reason is what the amendment history
  # records as WHY a gate case changed after authoring.
  # 173 with `suite_run`'s `script` (task 01a114a8 stage 2). HONEST: read
  # under its declared key only by `Platform.CodeMode.Run.run_tool/2`, which
  # refuses an absent, non-binary or empty script (`missing_script`) before
  # any slot is taken or wasm is instantiated. No alias, no context fallback.
  # 174 with `code_mode_report`'s `experiment_id` (task 01a114a8 stage 4).
  # HONEST: read under its declared key only, by
  # `Platform.Experiments.Tools`'s `fetch_visible/3` -> `required_uuid/3`,
  # which refuses an absent or malformed id. No alias, no context fallback.
  # 176 with `janitor_hand_back`'s `task_id` and `reason` (task 019fa1ac-6685
  # stage 3). HONEST, both: the handler passes each under its declared key
  # straight to `Platform.Responsibilities.Janitor.hand_back/3`, which refuses
  # an absent or malformed task_id (`invalid_task_id`) and an absent or
  # unknown reason (`invalid_reason`) before it opens a transaction. No
  # alias, no context fallback.
  # 179 with `prototype_versions`' `prototype_id` and `prototype_rollback`'s
  # `prototype_id` and `version` (task 01a1316b-4e46 stage 1). HONEST, all
  # three: `Platform.Prototypes.Tools` reads each under its declared key only
  # (`require_string/2`, `require_integer/2`) and refuses an absent value with
  # `invalid_argument` before any read or write. No alias, no context fallback.
  # 177 with `vault_fetch`'s `name` (task 01a131c5 stage 1). HONEST: read
  # under its declared key only by `Platform.Vault.ToolHandlers.fetch/2`,
  # which refuses an absent or non-slug name (`invalid_name`) before any
  # lookup. No alias, no context fallback.
  # 180 with both of the above (stack prototype-runtime rollup merge).
  # 187 adds access_explain target/resource, access_propose space_id/options,
  # access_apply proposal_id and access_undo change_id/space_id. All seven
  # are HONEST: AgentTools refuses absence under the declared key; none has
  # an alias, a context fallback or an absence default.
  # 191 adds `stack_attach_canvas` and `stack_detach_canvas`'s `stack_id` and
  # `canvas_id` (task 01a1559a stage 2). All four are HONEST: each handler
  # reads both under the declared key only and passes them straight to
  # `CanvasAttachments`; no alias, no context fallback, no absence default.
  @surveyed_required_count 193

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
  # `required: false` there — while `skill_upsert` and `validation_evaluate`
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
    # The direction of drift that hid `canvas_create`'s `initial_state`:
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
      # this guard would silently pass on an empty list. Six call sites
      # collapse to four distinct pairs — `task_id || id` recurs in task_get,
      # task_update and plan_get.
      assert Enum.sort(fallbacks) == [
               {"base_updated_at", "if_unmodified_since"},
               {"document", "initial_state"},
               {"stage_id", "id"},
               {"task_id", "id"}
             ],
             "the arg-to-arg fallback scan drifted; found #{inspect(fallbacks)}"

      # The allow-list is every alias declared ANYWHERE on the surface, not
      # just those on `required: true` parameters. Task 01a08a80 stage 2 is
      # the first case that distinguishes the two: `task_update`'s
      # `base_updated_at` is OPTIONAL and declares
      # `aliases: ["if_unmodified_since"]`, and the handler reads both keys.
      # Sourcing this list from `all_required_params/0` — which filters to
      # `required: true` — would have reported a correctly-declared optional
      # alias as undeclared. That is a false positive in the guard, not a
      # defect in the handler, and a guard that fires on correct code is a
      # guard someone eventually deletes.
      #
      # This does not soften what is being checked. The property is still
      # "every fallback the handler reads is declared as an alias in
      # `tool_surface.ex`"; only the survey of declarations is now complete.
      # An UNDECLARED fallback is still caught, and the exact pin above still
      # catches a fallback that is added without anyone noticing.
      declared =
        for tool <- ToolSurface.tool_definitions(),
            {key, spec} <- Map.get(tool, :parameters, %{}),
            is_map(spec),
            alias_key <- Map.get(spec, :aliases, []),
            do: {to_string(key), to_string(alias_key)}

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
               {"canvas_create", "document", ["initial_state"]},
               {"plan_get", "task_id", ["id"]},
               {"stage_complete", "stage_id", ["id"]},
               {"task_get", "task_id", ["id"]},
               {"task_update", "task_id", ["id"]}
             ]
    end
  end
end
