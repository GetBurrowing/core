defmodule Platform.Federation.CanvasReadEnumerationTest do
  @moduledoc """
  Every tool on the federation surface that can reach a canvas row must be
  classified here, on purpose, in writing (task 019fb01b, stage 5).

  ## The failure this exists to prevent

  `canvas.describe` shipped with no authorization at all — it ignored its
  `context` and resolved through `Chat.get_canvas/1`, the deliberately
  unauthorized primitive — and survived four releases. Nothing was subverted.
  It was added, reviewed and merged without anyone ever having to state out
  loud that it was ungated, because there was no place where such a statement
  belonged. This file is that place. A list you must edit on purpose is what
  makes the next one impossible to add by accident.

  ## Why the tool set is DERIVED and not typed out

  A test that checks a hand-written list against a hand-written list is
  theatre: it passes forever, including on the day someone adds the fifth
  ungated canvas read. So `canvas_reaching_tools/1` parses
  `lib/platform/federation/tool_surface.ex`, walks every `def execute/3` clause,
  follows the private helpers it calls, resolves the module aliases the file
  actually declares, and reports which clauses reach canvas code. Add a tool that
  touches a canvas through any of those paths and it appears here whether or not
  you thought about this file. The paths it does NOT follow are listed under
  "What this guard still cannot see" below, because a false negative in a guard
  is worth more words than a true positive.

  Source AST rather than `tool_definitions/0` alone, for a reason the first run
  of this guard turned up: `canvas_create` and `canvas_update` have `execute/3`
  clauses and NO entry in `tool_definitions/0`. A guard reading only the
  declared surface cannot see them. (They are unreachable for a different
  reason, asserted below rather than assumed.)

  Source AST rather than a grep, for the reason
  `test/support/repo_lookup_scan.ex` gives: `ToolHandlers` is the last segment
  of three unrelated modules on this surface (`Chat.Canvas`, `Skills`,
  `Chat.Attachments`), so a name match without alias resolution guesses, and
  guessing is how this class of audit goes blind.

  ## Two ways this bites, and the anti-tautology proof for each

  1. STRUCTURAL. A new canvas-reaching tool is not in `@canvas_reach`, so
     `test "every tool that reaches canvas code is classified"` fails and names
     it. Proved against a synthetic source in `test "the derivation sees a
     newly added ungated canvas read"` rather than against the live tree —
     the lesson `repo_lookup_scan.ex` records, that a capability asserted
     against a real defect stops being asserted the day the defect is fixed.

  2. BEHAVIOURAL. Classifying a tool as gated does not make it gated, so the
     classifications that claim a gate are DRIVEN: a real canvas, a real
     outsider agent, and `ToolSurface.execute/3` itself. Adding a tool to
     `@canvas_reach` with the wrong classification fails just as loudly as
     omitting it. Driven: `:tool_access_read`, `:tool_access_write`,
     `:space_gated`, `:task_gated`, and `:unreachable_legacy` (whose claim
     is a declaration check, since the tool cannot be called at all).
     `:creates_only` and `:no_canvas_row` are structural claims about tools that
     take no canvas id, and are asserted rather than driven.

  Both directions of drift fail: an unclassified tool, and a classification
  whose tool no longer exists.

  ## What this guard still cannot see

  It reads `execute/3` clause bodies and follows PRIVATE helpers in the same
  module, transitively. It does not follow a call into another module and out
  again, so a canvas read reached through a public function on some third module
  that is not in `@canvas_modules` is invisible. Widen `@canvas_modules` or
  `@canvas_functions` when that changes; the lists are the seam, and a
  false negative here is silent by construction.
  """

  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures, except: [canvas!: 2]

  alias Ecto.UUID
  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Tenancy

  @app_root Path.expand("../../..", __DIR__)
  @tool_surface Path.join(@app_root, "lib/platform/federation/tool_surface.ex")

  # Modules that can only be called with a canvas row, a canvas document, or a
  # canvas id in hand. Reaching one of these from an `execute/3` clause is the
  # structural signal that the tool touches canvas state.
  @canvas_modules [
    Platform.Chat.Canvas.ToolHandlers,
    Platform.Chat.Canvas.VersionHandlers,
    Platform.Chat.Canvas.Server,
    Platform.Chat.Canvas.ToolAccess,
    Platform.Chat.CanvasDocument,
    Platform.Tasks.CanvasAttachments,
    # The schema itself, so `Repo.get(Canvas, id)` and `from(c in Canvas, ...)`
    # are seen. This surface already imports `Ecto.Query` and calls `Repo.one/1`,
    # so bypassing the context module is one edit away.
    Platform.Chat.Canvas,
    # Builds the space context bundle, which includes `active_canvases`.
    Platform.Chat.ContextPlane
  ]

  # `Platform.Chat` is the shared context module, so it is matched per-function
  # rather than wholesale. Every canvas door on it, taken from `chat.ex` rather
  # than from memory — `get_canvas_with_deleted/1,2` in particular is the one
  # that returns SOFT-DELETED rows, which is exactly the door a future read
  # would be tempted to use and the one a partial list would miss.
  @canvas_functions [
    {Platform.Chat, :get_canvas},
    {Platform.Chat, :get_canvas_with_deleted},
    {Platform.Chat, :list_canvases},
    {Platform.Chat, :create_canvas},
    {Platform.Chat, :create_canvas_with_message},
    {Platform.Chat, :update_canvas},
    {Platform.Chat, :clone_canvas},
    {Platform.Chat, :list_message_ids_for_canvas},
    {Platform.Chat, :restore_canvas},
    {Platform.Chat, :delete_canvas}
  ]

  # `Platform.Chat.Canvas.Links.view_url/1` is deliberately absent: it is pure
  # id-to-URL string building and calling it proves nothing about reading a
  # canvas.

  @classifications [
    :tool_access_read,
    :tool_access_write,
    :space_gated,
    :creates_only,
    :no_canvas_row,
    :unreachable_legacy,
    :task_gated
  ]

  # THE LIST. Every canvas-reaching tool, what gate it has, and why that is the
  # right gate for it. An entry is a statement someone made on purpose; a
  # missing entry is a test failure, and so is a stale one.
  @canvas_reach %{
    "canvas.describe" =>
      {:tool_access_read,
       "Resolves a caller-supplied canvas id through ToolAccess.fetch_for_read/2 " <>
         "and returns the whole document. Gated in stage 3 of this task; before " <>
         "that it was the bug this file exists to prevent recurring."},
    "canvas.versions" =>
      {:tool_access_read,
       "Same seam as canvas.describe, on purpose, so the two cannot drift into " <>
         "two answers to one question. Returns revision numbers, write " <>
         "timestamps and written_by attribution, which is a read of who worked " <>
         "on what even without the document."},
    "canvas_get" =>
      {:tool_access_read,
       "Moved onto the shared seam in stage 4. Was space-participation gated, " <>
         "which was narrower and inconsistent rather than safer."},
    "canvas.patch" =>
      {:tool_access_write,
       "ToolAccess.fetch_for_write/3, which rejects the read-only grant levels. " <>
         "Argument shape is validated before authorization so a denial cannot " <>
         "be probed with junk operations."},
    "canvas.restore" =>
      {:tool_access_write,
       "Same write gate as canvas.patch. A restore is a full-document " <>
         "overwrite, so it is the most destructive write on this surface."},
    "canvas_list" =>
      {:space_gated,
       "Takes a space_id and enumerates it. There is no canvas in hand to " <>
         "resolve a grant from, so space participation is the right question " <>
         "and CanvasAccess has nothing to add. Stays on assert_agent_in_space/2 " <>
         "by decision in stage 4, not by omission."},
    "space_get_context" =>
      {:space_gated,
       "Takes a space_id and returns the space's context bundle, which includes " <>
         "active_canvases (id, title, kind) via ContextPlane.build_context_bundle/1. " <>
         "Gated on assert_agent_in_space/2, which is the right question for a " <>
         "space-keyed enumeration. Found by this guard rather than by hand: the " <>
         "canvas read is two hops from the execute clause, which is why the " <>
         "derivation follows private helpers instead of stopping at the body."},
    "canvas.create" =>
      {:creates_only,
       "Writes a new canvas into a space, and requires the context's " <>
         "agent_participant_id to be a participant row OF that space " <>
         "(Chat.get_space_participant/2, task 01a0cbe0 stage 2). Reads no " <>
         "existing canvas, so there is nothing for a read gate to protect."},
    "canvas.list_kinds" =>
      {:no_canvas_row,
       "Returns the static node-kind registry. Takes no canvas id and touches " <>
         "no canvas row."},
    "canvas.template" =>
      {:no_canvas_row,
       "Returns static starter documents. Takes no canvas id and touches no " <>
         "canvas row."},
    "canvas_create" =>
      {:unreachable_legacy,
       "Legacy underscore alias with an execute/3 clause and no " <>
         "tool_definitions/0 entry, so it belongs to no capability bundle and " <>
         "ToolAuthorization denies it on both transports. Asserted below."},
    "canvas_update" =>
      {:unreachable_legacy,
       "Same, and it matters more here: this clause calls " <>
         "Canvas.Server.describe/1 to fetch a base revision BEFORE " <>
         "ToolHandlers.patch/2 authorizes anything, which would materialize a " <>
         "Canvas.Server for an arbitrary canvas id and distinguish a real id " <>
         "from a junk one by error shape. Unreachable is the only reason that " <>
         "is not a live defect, which is why the unreachability is asserted " <>
         "rather than trusted."},
    "task_attach_canvas" =>
      {:task_gated,
       "Authorizes BOTH halves now. The canvas half is CanvasAttachments." <>
         "attach_canvas/4 calling fetch_for_viewer/3 before writing the row; " <>
         "the task half is ensure_task_touchable/3, which task 019fb581 added " <>
         "over Platform.Tasks.TaskAccess.fetch_for_actor/3. An outsider can no " <>
         "longer staple a canvas it CAN read onto someone else's task."},
    "task_detach_canvas" =>
      {:task_gated,
       "Was _context and no authorization at all; task 019fb581 put it behind " <>
         "CanvasAttachments.ensure_task_touchable/3, so removing an attachment " <>
         "now needs standing on the TASK, not merely its id."},
    "task_list_canvases" =>
      {:task_gated,
       "Was _context and no authorization at all, which handed the title of " <>
         "every attached canvas to anyone holding a task id. Task 019fb581 " <>
         "gated it on ensure_task_touchable/3. Titles are not documents, but " <>
         "they were the strongest hint this surface leaked, so the denial is " <>
         "driven below rather than trusted."}
  }

  setup do
    %{org_a: Tenancy.get_org_by_slug!("sxi"), org_b: Tenancy.get_org_by_slug!("soylent")}
  end

  # ── The guard ─────────────────────────────────────────────────────────────

  describe "the registry covers the surface" do
    test "every tool that reaches canvas code is classified" do
      derived = @tool_surface |> File.read!() |> canvas_reaching_tools() |> Map.keys()
      registered = Map.keys(@canvas_reach)

      unclassified = derived -- registered

      # `flunk/1` inside a conditional rather than `assert/2` with a message:
      # `assert/2` is a function, so its message argument is evaluated on the
      # PASSING path too, and building this one re-reads and re-parses all 9,000
      # lines of tool_surface.ex for a string nobody sees.
      if unclassified != [] do
        flunk("""
        These tools on the federation surface reach canvas code and are not in
        @canvas_reach:

        #{bullets(unclassified, derived_detail(unclassified))}

        Add each one with a classification from #{inspect(@classifications)} and a
        sentence saying what gate it has and why that gate is right for it. If the
        answer is "none", that is a legitimate entry — say so and say why. The
        point of this list is that nobody can add a canvas read without stating
        its gate out loud, which is exactly what did not happen for
        canvas.describe.
        """)
      end
    end

    test "every classification still names a tool that exists" do
      derived = @tool_surface |> File.read!() |> canvas_reaching_tools() |> Map.keys()
      stale = Map.keys(@canvas_reach) -- derived

      assert stale == [], """
      @canvas_reach names tools that no longer reach canvas code (renamed,
      deleted, or refactored onto a different module). Delete these entries:

      #{bullets(stale)}

      A stale entry is worse than a missing one: it reads as coverage.
      """
    end

    test "every entry carries a known classification and a written rationale" do
      for {name, {classification, rationale}} <- @canvas_reach do
        assert classification in @classifications,
               "#{name}: #{inspect(classification)} is not one of #{inspect(@classifications)}"

        assert is_binary(rationale) and String.length(rationale) > 40,
               "#{name}: the rationale must say what gate this tool has and why. " <>
                 "A placeholder here defeats the whole file."
      end
    end
  end

  # ── Anti-vacuity ──────────────────────────────────────────────────────────

  describe "the derivation is not vacuous" do
    test "it finds the reads this task spent four stages gating" do
      derived = @tool_surface |> File.read!() |> canvas_reaching_tools()

      # A predicate that silently stopped matching would make every assertion
      # above pass against an empty set, which is the exact shape of a guard
      # that certifies a property it can no longer check. Pinned to the registry
      # size rather than to a slack floor: the two lists are supposed to be the
      # same set, so anything else is either a derivation that went blind or a
      # registry nobody updated.
      assert map_size(derived) == map_size(@canvas_reach)

      for name <- ["canvas.describe", "canvas.versions", "canvas_get", "canvas.patch"] do
        assert Map.has_key?(derived, name),
               "the derivation no longer sees #{name}, so it is not seeing anything"
      end
    end

    test "the derivation sees a newly added ungated canvas read" do
      # Synthetic rather than live. Asserting "the guard still sees the defect
      # in tool_surface.ex" is a test that fails the day the defect is fixed,
      # which is the wrong reason for a capability test to go red.
      source = """
      defmodule Fake do
        alias Platform.Chat
        alias Platform.Chat.Canvas.ToolHandlers

        def execute("canvas.summarize", args, _context) do
          canvas = Chat.get_canvas(Map.get(args, "canvas_id"))
          {:ok, %{summary: canvas.title}}
        end

        def execute("canvas.diff", args, context) do
          ToolHandlers.describe(args, context)
        end

        def execute("space_list", _args, _context), do: {:ok, []}
      end
      """

      derived = canvas_reaching_tools(source)

      assert Map.has_key?(derived, "canvas.summarize"),
             "a tool reading a canvas row through the aliased Chat context escaped the derivation"

      assert Map.has_key?(derived, "canvas.diff"),
             "a tool delegating to a canvas handler escaped the derivation"

      refute Map.has_key?(derived, "space_list"),
             "the derivation flags tools that touch no canvas, so it would flag everything"
    end

    test "an alias to a same-named module on another surface is not a false positive" do
      # `Platform.Skills.ToolHandlers` and `Platform.Chat.Attachments.ToolHandlers`
      # both end in `ToolHandlers` and both are called from execute/3 clauses on
      # this surface. A last-segment match would classify skill.get as a canvas
      # read.
      source = """
      defmodule Fake do
        alias Platform.Skills.ToolHandlers

        def execute("skill.get", args, context), do: ToolHandlers.get(args, context)
      end
      """

      assert canvas_reaching_tools(source) == %{}
    end

    test "a canvas read in the SECOND clause of a same-named tool is still seen" do
      # Keying clauses by tool name would keep only the last one, so an ungated
      # read added as a pattern-matched first clause would vanish and the tool
      # would drop off the registry entirely — a false negative that fails OPEN.
      # Pattern-matched heads are already routine on this surface
      # (`def execute("task_complete", %{"task_id" => id}, _ctx)`), so a second
      # clause is one ordinary edit away.
      source = """
      defmodule Fake do
        alias Platform.Chat

        def execute("canvas.peek", %{"legacy" => true} = args, _ctx) do
          Chat.get_canvas(args["canvas_id"])
        end

        def execute("canvas.peek", _args, _ctx), do: {:error, :bad_args}
      end
      """

      assert Map.has_key?(canvas_reaching_tools(source), "canvas.peek")
    end

    test "a canvas read reached through a private helper is seen" do
      # The dominant shape in tool_surface.ex: the execute clause delegates and
      # the canvas read is one or more hops down. A derivation that stopped at
      # the clause body would report this tool as touching nothing at all.
      source = """
      defmodule Fake do
        alias Platform.Chat

        def execute("canvas.peek", args, ctx), do: do_peek(args, ctx)

        defp do_peek(args, ctx), do: deeper(args, ctx)

        defp deeper(args, _ctx), do: Chat.get_canvas(args["canvas_id"])
      end
      """

      assert Map.has_key?(canvas_reaching_tools(source), "canvas.peek")
    end

    test "mutually recursive private helpers do not hang the derivation" do
      source = """
      defmodule Fake do
        alias Platform.Chat

        def execute("canvas.peek", args, ctx), do: ping(args, ctx)

        defp ping(args, ctx), do: pong(args, ctx)

        defp pong(args, ctx) do
          Chat.get_canvas(args["canvas_id"])
          ping(args, ctx)
        end
      end
      """

      assert Map.has_key?(canvas_reaching_tools(source), "canvas.peek")
    end
  end

  # ── Behavioural: the classifications are true ─────────────────────────────

  describe "tools classified as gated actually deny an outsider" do
    test "every :tool_access_read denies a foreign agent and returns no canvas state", %{
      org_a: org_a,
      org_b: org_b
    } do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      context = federation_context(outsider_agent!(org_b))
      names = classified(:tool_access_read)

      # An empty classification would make this whole loop assert nothing and
      # report green, which is the failure mode the file is written against.
      refute names == [], "no tool is classified :tool_access_read, so nothing is being driven"

      for name <- names do
        assert {:error, payload} = ToolSurface.execute(name, probe_args(name, canvas), context),
               "#{name} is classified :tool_access_read but answered an outsider"

        assert payload.recoverable == false, "#{name}: a denial is not recoverable by retrying"
        refute_leaks(payload, canvas, name)
      end
    end

    test "every :tool_access_write denies a foreign agent", %{org_a: org_a, org_b: org_b} do
      canvas = canvas!(space!(%{org_id: org_a.id}))
      context = federation_context(outsider_agent!(org_b))
      names = classified(:tool_access_write)

      refute names == [], "no tool is classified :tool_access_write, so nothing is being driven"

      for name <- names do
        assert {:error, payload} = ToolSurface.execute(name, probe_args(name, canvas), context),
               "#{name} is classified :tool_access_write but answered an outsider"

        refute_leaks(payload, canvas, name)
      end
    end

    test "every :space_gated tool denies a non-participant", %{org_a: org_a, org_b: org_b} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      context = federation_context(outsider_agent!(org_b))

      names = classified(:space_gated)
      refute names == [], "no tool is classified :space_gated, so nothing is being driven"

      for name <- names do
        assert {:error, _} = ToolSurface.execute(name, %{"space_id" => space.id}, context),
               "#{name} is classified :space_gated but enumerated a space for a non-participant"
      end

      # The positive half: a space member does get the listing. A tool that
      # denied everyone would pass the loop above for the wrong reason.
      member = UUID.generate()
      add_agent!(space.id, member)

      assert {:ok, rows} =
               ToolSurface.execute(
                 "canvas_list",
                 %{"space_id" => space.id},
                 federation_context(member)
               )

      assert Enum.any?(rows, &(&1.id == canvas.id))
    end

    test "every :tool_access_read still answers a caller who does hold a grant", %{org_a: org_a} do
      # The counterweight to the denial loops. Four stages of gating could end
      # with a surface that denies everyone, and every denial assertion in this
      # file would still be green.
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      member = UUID.generate()
      add_agent!(space.id, member)
      context = federation_context(member)

      for name <- classified(:tool_access_read) do
        assert {:ok, _} = ToolSurface.execute(name, probe_args(name, canvas), context),
               "#{name} denied a participant of the canvas's own space"
      end
    end
  end

  describe "tools classified as unreachable actually are" do
    test "every :unreachable_legacy tool is absent from the declared surface" do
      declared = ToolSurface.tool_definitions() |> Enum.map(& &1.name) |> MapSet.new()

      for name <- classified(:unreachable_legacy) do
        refute MapSet.member?(declared, name), """
        #{name} now has a tool_definitions/0 entry, so it belongs to a
        capability bundle and a runtime can call it. Its @canvas_reach entry
        classifies it :unreachable_legacy, and that classification is the ONLY
        reason it is not treated as a live gap — canvas_update in particular
        reads a canvas revision before it authorizes anything.

        Either revert the declaration, or gate the clause and reclassify it.
        """
      end
    end
  end

  describe "tools classified :task_gated actually deny a caller with no standing" do
    test "every :task_gated tool refuses a stranger holding only the task id", %{org_a: org_a} do
      # This block used to PIN THE GAP: task_attach_canvas / task_detach_canvas /
      # task_list_canvases took `_context` and authorized nothing against the
      # TASK, so anyone holding a task id could staple, unstaple, or read the
      # titles of its attachments. Task 019fb581 closed it with
      # `CanvasAttachments.ensure_task_touchable/3` over
      # `Platform.Tasks.TaskAccess.fetch_for_actor/3`, so the pin is inverted
      # here rather than deleted: the @canvas_reach claim stays DRIVEN, and a
      # reclassification that outran the code fails here instead of reading as
      # coverage.
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      task = task_in!(org_a)
      attach!(task, canvas)

      names = classified(:task_gated)
      refute names == [], "no tool is classified :task_gated, so nothing is being driven"

      # No binding to the task, its execution space, its sponsor slot, or its
      # project's org — none of the six TaskAccess grant paths can answer.
      stranger = federation_context(UUID.generate())

      for name <- names do
        assert {:error, payload} =
                 ToolSurface.execute(
                   name,
                   %{"task_id" => task.id, "canvas_id" => canvas.id},
                   stranger
                 ),
               "#{name} is classified :task_gated but answered a caller with no standing on the task"

        assert payload.recoverable == false, "#{name}: a denial is not recoverable by retrying"
        refute_leaks(payload, canvas, name)
      end
    end

    test "task_attach_canvas refuses a canvas the caller cannot read", %{
      org_a: org_a,
      org_b: org_b
    } do
      # The CANVAS half of task_attach_canvas, which predates 019fb581:
      # `CanvasAttachments.attach_canvas/4` resolves the attacher through
      # fetch_for_viewer/3 before writing the row.
      #
      # Since 019fb581 this particular denial is OVER-DETERMINED — the task
      # gate runs first and this outsider fails that too — so the assertion is
      # deliberately left at `{:error, _}`. The isolated canvas half, driven by
      # a caller that HAS task standing and lacks only canvas standing, lives in
      # test/security/task_canvas_attachment_authorization_test.exs.
      canvas = canvas!(space!(%{org_id: org_a.id}))
      task = task_in!(org_a)
      context = federation_context(outsider_agent!(org_b))

      assert {:error, _} =
               ToolSurface.execute(
                 "task_attach_canvas",
                 %{"task_id" => task.id, "canvas_id" => canvas.id},
                 context
               )
    end
  end

  # ── Derivation ────────────────────────────────────────────────────────────

  # Returns %{tool_name => [{module, function}]} for every `def execute/3`
  # clause with a literal string name whose body calls into canvas code.
  # Parsed from source on every run, so a tool added tomorrow is covered
  # without editing this function.
  defp canvas_reaching_tools(source) do
    ast = Code.string_to_quoted!(source)
    aliases = alias_map(ast)
    helpers = private_helpers(ast)
    modules = MapSet.new(@canvas_modules)
    functions = MapSet.new(@canvas_functions)

    ast
    |> execute_clauses()
    |> Enum.map(fn {name, body} -> {name, reachable_calls(body, aliases, helpers)} end)
    |> Enum.map(fn {name, calls} ->
      {name,
       Enum.filter(calls, fn {mod, fun} ->
         MapSet.member?(modules, mod) or MapSet.member?(functions, {mod, fun})
       end)}
    end)
    |> Enum.reject(fn {_name, touching} -> touching == [] end)
    # Grouped rather than `Map.new/1`. One tool name may carry several
    # `execute/3` clauses (different guards, different argument shapes), and
    # collapsing by key keeps only the last — so a canvas read added as a second
    # clause beside a non-canvas first one would drop out of the derivation
    # silently. No name has two clauses today; the guard is for the day one does.
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {name, call_lists} -> {name, call_lists |> List.flatten() |> Enum.uniq()} end)
  end

  defp execute_clauses(ast) do
    prewalk_collect(ast, fn
      {:def, _, [{:when, _, [{:execute, _, [name, _, _]} | _]}, body]} when is_binary(name) ->
        {name, body}

      {:def, _, [{:execute, _, [name, _, _]}, body]} when is_binary(name) ->
        {name, body}

      _ ->
        nil
    end)
  end

  # `alias A.B`, `alias A.B, as: C` and `alias A.{B, C}` all bind a short name
  # to a full module path. Without this the derivation cannot tell
  # `Platform.Chat.Canvas.ToolHandlers` from `Platform.Skills.ToolHandlers`.
  defp alias_map(ast) do
    prewalk_collect(ast, fn
      {:alias, _, [{:__aliases__, _, parts}]} ->
        [{List.last(parts), parts}]

      {:alias, _, [{:__aliases__, _, parts}, opts]} when is_list(opts) ->
        case Keyword.get(opts, :as) do
          {:__aliases__, _, [as]} -> [{as, parts}]
          _ -> [{List.last(parts), parts}]
        end

      {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} ->
        for {:__aliases__, _, sub} <- children, do: {List.last(sub), base ++ sub}

      _ ->
        nil
    end)
    |> List.flatten()
    |> Map.new()
  end

  # Remote calls in `body`, PLUS the remote calls of every private helper it
  # reaches, transitively. Without this the derivation is blind one hop past the
  # clause body, which is the dominant shape in `tool_surface.ex`:
  # `assert_agent_in_space/2`, `lookup_participant/2` and `format_datetime/1`
  # are all private helpers, so `def execute("x", a, c), do: do_x(a, c)` would
  # read as touching nothing at all.
  #
  # `visited` is what stops mutual recursion between two helpers from looping.
  defp reachable_calls(body, aliases, helpers, visited \\ MapSet.new()) do
    direct = remote_calls(body, aliases)

    local =
      body
      |> local_calls()
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.flat_map(fn key ->
        case Map.fetch(helpers, key) do
          {:ok, bodies} ->
            seen = MapSet.put(visited, key)
            Enum.flat_map(bodies, &reachable_calls(&1, aliases, helpers, seen))

          :error ->
            []
        end
      end)

    Enum.uniq(direct ++ local)
  end

  # %{{name, arity} => [body, ...]} for every `defp` in the module. A helper with
  # several clauses keeps all of them: a canvas read living in the second clause
  # is exactly as reachable as one in the first.
  defp private_helpers(ast) do
    prewalk_collect(ast, fn
      {:defp, _, [{:when, _, [{name, _, args} | _]}, body]}
      when is_atom(name) and is_list(args) ->
        {{name, length(args)}, body}

      {:defp, _, [{name, _, args}, body]} when is_atom(name) and is_list(args) ->
        {{name, length(args)}, body}

      _ ->
        nil
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # Bare `name(args)` calls — no module prefix — which is how a local helper is
  # invoked. Pipes are rewritten first so `x |> helper()` counts its real arity.
  defp local_calls(body) do
    body
    |> expand_pipes()
    |> prewalk_collect(fn
      {name, _, args} when is_atom(name) and is_list(args) -> {name, length(args)}
      _ -> nil
    end)
    |> Enum.uniq()
  end

  defp expand_pipes(ast) do
    Macro.prewalk(ast, fn
      {:|>, _meta, [lhs, {call, meta, args}]} when is_list(args) -> {call, meta, [lhs | args]}
      other -> other
    end)
  end

  defp remote_calls(body, aliases) do
    prewalk_collect(body, fn
      {{:., _, [{:__aliases__, _, parts}, fun]}, _, _} when is_atom(fun) ->
        {resolve(parts, aliases), fun}

      _ ->
        nil
    end)
    |> Enum.uniq()
  end

  defp resolve(parts, aliases) do
    case Map.get(aliases, hd(parts)) do
      nil -> Module.concat(parts)
      full -> Module.concat(full ++ tl(parts))
    end
  end

  defp prewalk_collect(ast, fun) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case fun.(node) do
          nil -> {node, acc}
          value -> {node, [value | acc]}
        end
      end)

    Enum.reverse(acc)
  end

  # ── Probes ────────────────────────────────────────────────────────────────

  defp classified(classification) do
    for {name, {^classification, _}} <- @canvas_reach, do: name
  end

  # No catch-all clause that guesses. A tool added to a probed classification
  # without probe arguments fails here with an instruction rather than silently
  # probing nothing.
  defp probe_args("canvas.describe", canvas), do: %{"canvas_id" => canvas.id}
  defp probe_args("canvas.versions", canvas), do: %{"canvas_id" => canvas.id}
  defp probe_args("canvas_get", canvas), do: %{"canvas_id" => canvas.id, "mode" => "full"}

  defp probe_args("canvas.patch", canvas),
    do: %{"canvas_id" => canvas.id, "base_revision" => 0, "operations" => []}

  defp probe_args("canvas.restore", canvas), do: %{"canvas_id" => canvas.id, "revision" => 1}

  defp probe_args(name, _canvas) do
    flunk("""
    #{name} is classified as gated in @canvas_reach but has no probe_args/2
    clause, so nothing drives it and the classification is an unverified claim.
    Add a clause returning the arguments that reach its authorization check.
    """)
  end

  # A denial must not tell the caller what it was denied. Title and document are
  # the payload; space_id is the discriminator that would let a caller tell a
  # channel canvas from a DM canvas from an execution-space one.
  defp refute_leaks(payload, canvas, name) do
    serialized = inspect(payload, limit: :infinity, printable_limit: :infinity)

    refute serialized =~ canvas.title, "#{name} leaked the canvas title in its denial"
    refute serialized =~ canvas.space_id, "#{name} leaked the canvas space_id in its denial"
    refute Map.has_key?(payload, :document), "#{name} returned a document in its denial"
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp space!(attrs) do
    n = System.unique_integer([:positive, :monotonic])
    default = %{name: "Enum Space #{n}", slug: "enum-space-#{n}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp canvas!(space) do
    author = add_user!(space.id, create_user!().id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => "Enumeration Fixture #{System.unique_integer([:positive])}"
      })

    canvas
  end

  defp task_in!(org) do
    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Enum Project #{System.unique_integer([:positive])}",
        org_id: org.id
      })

    {:ok, task} = Platform.Tasks.create_task(%{project_id: project.id, title: "Enum Task"})
    task
  end

  defp attach!(task, canvas) do
    {:ok, _attachment} =
      Platform.Tasks.CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
        attached_by: %{kind: "user", id: UUID.generate()}
      )

    :ok
  end

  defp outsider_agent!(org) do
    agent_id = UUID.generate()
    add_agent!(space!(%{org_id: org.id}).id, agent_id)
    agent_id
  end

  defp federation_context(agent_id) do
    %{
      space_id: nil,
      agent_id: agent_id,
      agent_participant_id: nil,
      runtime_id: "runtime-#{System.unique_integer([:positive])}"
    }
  end

  defp bullets(items), do: Enum.map_join(items, "\n", &"  - #{&1}")

  defp bullets(items, detail) do
    Enum.map_join(items, "\n", fn item ->
      "  - #{item} (reaches #{Map.get(detail, item, "canvas code")})"
    end)
  end

  defp derived_detail(names) do
    derived = @tool_surface |> File.read!() |> canvas_reaching_tools()

    for name <- names, into: %{} do
      calls =
        derived
        |> Map.get(name, [])
        |> Enum.map_join(", ", fn {mod, fun} -> "#{inspect(mod)}.#{fun}" end)

      {name, calls}
    end
  end
end
