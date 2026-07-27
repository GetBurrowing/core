defmodule Platform.Regression.BootTelemetryHandlerDetachAuditTest do
  @moduledoc """
  Source-scan guard against re-opening the 2026-07-26 boot-attached
  telemetry-handler leak (task 019f9d80).

  ## Why this guard is STATIC and not a behavioural test

  `:telemetry` keys the boot handlers by a fixed `@handler_id` in ETS —
  they are VM-global, not per-process and not per-test. A test that
  detaches one and never puts it back leaves every later test in the same
  BEAM running with that bridge missing, and the symptom is not an error:
  it is an audit assertion that passes because nothing is listening.

  The obvious detector — run the two files that expose it in one BEAM —
  **does not work**, and that is measured rather than assumed. Stage 2 of
  task 019f9d80 (probe M0, `notes/2026-07-26-boot-telemetry-detach.md` §9)
  deleted the restoring `on_exit` and the ordered pair stayed GREEN,
  because what repairs today's offenders is that their setup no longer
  detaches at all. The `on_exit` guards a FUTURE detach, or a mid-body
  one. Stage 3 re-confirmed it independently. A behavioural guard would
  therefore pass a newly-written offender right up until that file happens
  to be scheduled ahead of a victim — which is exactly the eight-brief
  write-off this task exists to end.

  So the invariant is enforced at authoring time, from source.

  ## The four assertions

    1. **Derivation.** The boot-attached module set is parsed out of
       `Platform.Application.start/2`. Hardcoding it is the failure mode,
       not a shortcut: `Meetings.TelemetryHandler` and
       `IntentCorrections.TelemetryHandler` were boot-attached *after* the
       offending tests were written, so a list frozen at that time would
       have missed two of the five offenders entirely. A companion check
       fails if `application.ex` grows an `attach()` call in a shape this
       parser does not understand, so the derivation cannot go quietly
       blind — the rot mode `supervised_task_repo_audit_test.exs` hit
       twice on 2026-07-25.

    2. **Restore-before-detach.** Every `detach()` of a derived module in
       `test/**` must either be immediately followed by that module's
       `attach()` (the self-healing pair, no window), or be preceded by a
       registered restore for that same module —
       `Platform.TelemetryHelpers.ensure_boot_handler!/1` or an `on_exit`
       containing `attach()`. Registration must come FIRST: a restore
       registered after the detach does not run if the assertion between
       them fails, which is the whole failure mode. Both call shapes are
       resolved through the file's own `alias` lines, because four of the
       five original offenders wrote the bare alias form and a
       fully-qualified-only matcher would have been blind to all four.

    3. **`async: true` is banned outright** for any file that detaches a
       boot handler. A concurrently-scheduled file mutating VM-global
       telemetry state races every other file in its partition, and no
       `on_exit` ordering can make that safe.

    4. **No unqualified sandbox-owner-chain claim** in any comment or
       doc, anywhere in `lib/` or `test/`. See below — this one is not
       about telemetry at all.

  ## Why assertion 4 lives here

  Task 019f9d80 found the same defect class in prose. Four comments
  asserted that a `Task.Supervisor` child "is not in the DataCase sandbox
  owner chain". `data_case.ex` does `Sandbox.start_owner!(Repo, shared:
  not tags[:async])`, so in a file that is not `async: true` the sandbox
  is in shared mode and the spawned child **inherits** the connection.
  The claim is true only under `async: true`, and every one of those
  comments stated it unconditionally.

  A comment asserting a safety property the code does not have is exactly
  as dangerous as a test that passes for the wrong reason, and neither
  shows up in review. Stage 1 spent a work item disproving one of these
  comments; stage 3 corrected three more after measuring them false.

  The rule is therefore not "this claim is forbidden" — it is often true —
  but **"state which sandbox mode you mean"**. A claim about the owner
  chain must name `async: true` / `async: false` / manual mode / shared
  mode somewhere in the same comment or doc block. That is checkable, and
  it is the minimum a reader needs to evaluate the claim.

  ## Why there is no "DB work inside `on_exit`" assertion

  Considered and deliberately left out. Stage 3 established that ExUnit
  runs `on_exit` in a separate process after the test process is dead, so
  under the old `Sandbox.checkout/1` form every connection-dependent
  `on_exit` was a silent no-op. That is fixed at the source (`start_owner!`
  keeps the connection alive until `stop_owner/1` runs last), and a scan
  measured **zero** `on_exit` bodies anywhere in `test/**` containing a
  `Repo.*` call. A guard for it would pass unconditionally today while
  being structurally unable to see the case that matters — DB work reached
  indirectly through a context function. That is a guard that cries wolf
  in reverse: it certifies a property it cannot check. Left out on purpose;
  reasoning recorded in `notes/2026-07-26-boot-telemetry-detach.md` §20.

  Cheap by construction: `File.read!` + `Code.string_to_quoted!`, no DB,
  no PubSub, `async: true`, and in the default `mix test` set. Peer of
  `supervised_task_repo_audit_test.exs`, which is the pattern this file
  mirrors.

  Root-cause writeup: `apps/platform/notes/2026-07-26-boot-telemetry-detach.md`.
  """

  use ExUnit.Case, async: true

  @app_root Path.expand("../../..", __DIR__)
  @application_ex Path.join(@app_root, "lib/platform/application.ex")

  # Test sources scanned by assertions 2 and 3. `test/support/**/*.ex` is
  # included because a shared case template or helper is exactly where a
  # detach would do the most damage while looking the most innocent.
  @test_globs [
    Path.join(@app_root, "test/**/*.exs"),
    Path.join(@app_root, "test/support/**/*.ex")
  ]

  # Everything assertion 4 reads. Comments in lib/ carry the same claims as
  # comments in test/ and were wrong in both.
  @prose_globs [
    Path.join(@app_root, "lib/**/*.ex"),
    Path.join(@app_root, "test/**/*.exs"),
    Path.join(@app_root, "test/support/**/*.ex")
  ]

  # Files allowed to detach a boot-attached handler without a preceding
  # restore. Each entry MUST cite why the leak cannot ride this path —
  # not "it looks fine". Empty is the correct state: every detach in the
  # tree today is either a self-healing `detach(); attach()` pair or is
  # preceded by `ensure_boot_handler!/1`. The rot guard below fails any
  # entry that no longer has a matching unrestored detach, so a stale
  # exemption cannot sit here giving false confidence.
  @known_safe []

  # THE single definition of "this prose asserts that some process sits
  # outside the sandbox owner chain" — a claim that holds under
  # `async: true` (manual mode) and is false under `async: false`
  # (shared mode). The negation and the phrase may be on different source
  # lines, so assertion 4 matches against a joined comment/doc block
  # rather than a line: `responsibilities/router.ex` splits exactly this
  # claim across two lines and a line-oriented matcher misses it.
  # `(?!\bsandbox\b)` stops a negation in one sentence from binding to a
  # phrase two sentences later.
  @ownership_claim_regex ~r/(?:not|n't|never|outside)(?:(?!\bsandbox\b).){0,140}?sandbox\s+owner\s+chain/i

  # What makes such a claim evaluable: it names the sandbox mode it holds
  # under. `async: true` / `async: false` / `:manual` / shared mode all
  # count.
  @sandbox_mode_qualifier ~r/async:\s*(?:true|false)|:manual\b|manual mode|shared[- ]mode/i

  # Files carrying an ownership claim that does not name its sandbox mode
  # and that this task is NOT permitted to edit. Each entry cites the
  # fence. The rot guard below fails once the claim is fixed, which is how
  # the entry gets removed rather than outliving its reason.
  @known_unqualified_claims [
    # `lib/platform/responsibilities/**` is inside task 019f9d80's ADR-0046
    # scope fence (the stack on sibling tasks 019f9b27 / 019f9b28 is in
    # flight over it), so the comment at `router.ex:1327-1330` — "a
    # `Task.Supervisor`-spawned process (which is not part of the DataCase
    # sandbox owner chain)" — is recorded here instead of corrected. It is
    # the same unconditional claim stage 3 measured false: true under
    # `async: true`, false under shared mode. Fixing it is a one-line
    # comment edit for whoever next opens that file.
    "lib/platform/responsibilities/router.ex"
  ]

  # ── Assertion 1: the boot-attached set is derived, not transcribed ──

  describe "boot-attached handler derivation" do
    test "the module set is parsed out of Platform.Application.start/2" do
      derived = boot_attached_modules()

      assert derived != [], """
      No `<Module>.attach()` calls were found in Platform.Application.start/2.
      Either boot attachment moved, or the AST shape this audit matches
      changed. Fix the parser in
      test/platform/regression/boot_telemetry_handler_detach_audit_test.exs —
      do NOT replace it with a hardcoded list, which is the failure mode
      this assertion exists to prevent.
      """

      not_handlers =
        Enum.reject(derived, fn module ->
          Code.ensure_loaded?(module) and function_exported?(module, :attach, 0)
        end)

      assert not_handlers == [], """
      Parsed these out of Platform.Application.start/2 as boot-attached
      handlers, but they do not export attach/0 — the parser is matching
      something it should not:

      #{bullets(not_handlers)}
      """
    end

    test "no `attach()` call in application.ex is invisible to the parser" do
      source = File.read!(@application_ex)
      literal_sites = Regex.scan(~r/\.attach\(\)/, source) |> length()
      derived = boot_attached_modules()

      assert length(derived) == literal_sites, """
      application.ex contains #{literal_sites} `.attach()` call(s) but this
      audit only understood #{length(derived)} of them:

      #{bullets(derived)}

      A call written in a shape the parser does not match (a comprehension,
      a capture like `& &1.attach()`, an alias resolved at runtime) makes
      that handler invisible to the whole audit — the exact way
      supervised_task_repo_audit_test.exs went blind twice on 2026-07-25.
      Widen `boot_attached_modules/0` to cover the new shape.
      """
    end
  end

  # ── Assertion 2: restore must be registered BEFORE the detach ───────

  describe "detach of a boot-attached telemetry handler" do
    test "every detach is either self-healing or preceded by a registered restore" do
      offenders = scan_detach_sites()

      assert offenders == [], format_detach_offenders(offenders)
    end

    test "every @known_safe entry still has an unrestored detach" do
      live = scan_detach_sites(ignore_known_safe: true) |> Enum.map(fn {path, _, _} -> path end)

      stale = @known_safe -- live

      assert stale == [], """
      @known_safe lists files that no longer detach a boot-attached
      handler without a restore. Delete these entries — an exemption with
      nothing behind it is dead weight that reads as coverage:

      #{bullets(stale)}
      """
    end
  end

  # ── Assertion 3: async: true cannot mutate VM-global handler state ──

  describe "concurrency" do
    test "no `async: true` test file detaches a boot-attached handler" do
      boot = MapSet.new(boot_attached_modules())

      offenders =
        test_sources()
        |> Enum.map(&analyse_source/1)
        |> Enum.filter(fn info ->
          info.async? and Enum.any?(info.detaches, fn {mod, _} -> MapSet.member?(boot, mod) end)
        end)
        |> Enum.map(fn info ->
          sites =
            info.detaches
            |> Enum.filter(fn {mod, _} -> MapSet.member?(boot, mod) end)
            |> Enum.sort_by(&elem(&1, 1))

          {info.path, sites}
        end)
        |> Enum.sort()

      assert offenders == [], """
      These `async: true` files detach a boot-attached telemetry handler:

      #{Enum.map_join(offenders, "\n\n", fn {path, sites} -> "  #{path}\n" <> Enum.map_join(sites, "\n", fn {mod, line} -> "    line #{line} — #{inspect(mod)}" end) end)}

      Boot handlers are VM-global (`:telemetry` keys them by a fixed
      @handler_id in ETS). An `async: true` module runs concurrently with
      every other module in its partition, so detaching one silences the
      bridge for unrelated tests that are mid-flight. No `on_exit`
      ordering can fix that — the window is open while other files run.

      Fix: make the file `async: false`, or stop detaching (attach/0 has
      been idempotent since task 019f9d80 stage 2, so the defensive
      `detach(); attach()` dance is no longer needed to avoid a duplicate
      registration — it never was, `:telemetry` cannot double-register a
      fixed handler id).
      """
    end
  end

  # ── Assertion 4: ownership claims must name their sandbox mode ──────

  describe "sandbox-owner-chain claims in comments and docs" do
    test "every claim names the sandbox mode it holds under" do
      offenders =
        scan_ownership_claims()
        |> Enum.reject(fn {path, _, _} -> path in @known_unqualified_claims end)

      assert offenders == [], """
      These comment/doc blocks assert that something is outside the
      sandbox owner chain without saying under which sandbox mode:

      #{Enum.map_join(offenders, "\n\n", fn {path, line, excerpt} -> "  #{path}:#{line}\n    \"#{excerpt}\"" end)}

      `test/support/data_case.ex` calls
      `Sandbox.start_owner!(Repo, shared: not tags[:async])`. In a file
      that is NOT `async: true` the sandbox is in shared mode and a
      spawned child inherits the owner's connection, so the claim is
      false there. It holds under `async: true` (manual mode) only.

      Task 019f9d80 found four comments making this claim
      unconditionally; three were measured false and corrected in stage 3.
      A comment asserting a safety property the code does not have is as
      dangerous as a test that passes for the wrong reason.

      Fix: say which mode you mean — `async: true`, `async: false`,
      manual mode or shared mode — in the same comment or doc block. If
      the claim is not mode-specific, it is wrong; rewrite it.
      """
    end

    test "every @known_unqualified_claims entry still carries an unqualified claim" do
      live = scan_ownership_claims() |> Enum.map(fn {path, _, _} -> path end)

      stale = @known_unqualified_claims -- live

      assert stale == [], """
      @known_unqualified_claims lists files whose ownership claim now
      names its sandbox mode (or is gone). Delete these entries:

      #{bullets(stale)}
      """
    end
  end

  # ── Derivation ─────────────────────────────────────────────────────

  # Walks `Platform.Application.start/2` and returns every module that
  # boot calls `attach()` on. Parsed from source on every run so a handler
  # added to application.ex tomorrow is covered without editing this file.
  defp boot_attached_modules do
    @application_ex
    |> File.read!()
    |> Code.string_to_quoted!()
    |> start_2_body()
    |> prewalk_collect(fn
      {{:., _, [{:__aliases__, _, parts}, :attach]}, _, []} -> Module.concat(parts)
      _ -> nil
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp start_2_body(ast) do
    ast
    |> prewalk_collect(fn
      {:def, _, [{:start, _, [_, _]}, body]} -> body
      _ -> nil
    end)
    |> case do
      [body | _] -> body
      [] -> []
    end
  end

  # ── Test-source scan ───────────────────────────────────────────────

  defp scan_detach_sites(opts \\ []) do
    boot = MapSet.new(boot_attached_modules())
    ignore_known_safe = Keyword.get(opts, :ignore_known_safe, false)

    test_sources()
    |> Enum.map(&analyse_source/1)
    |> Enum.flat_map(fn info ->
      if not ignore_known_safe and Enum.member?(@known_safe, info.path) do
        []
      else
        for {mod, line} <- info.detaches,
            MapSet.member?(boot, mod),
            not MapSet.member?(info.paired, {mod, line}),
            not restored_before?(info.restores, mod, line),
            do: {info.path, line, mod}
      end
    end)
    |> Enum.sort()
  end

  defp restored_before?(restores, mod, line) do
    Enum.any?(restores, fn {restored_mod, restored_line} ->
      restored_mod == mod and restored_line < line
    end)
  end

  defp test_sources do
    @test_globs |> Enum.flat_map(&Path.wildcard/1) |> Enum.uniq() |> Enum.sort()
  end

  # One pass over a test file yielding everything the assertions need.
  # AST rather than regex: assertion 2 has to know whether a restore was
  # registered *before* a given line, whether two calls are adjacent
  # statements, and what a bare `TelemetryHandler` alias resolves to.
  # Regex cannot answer any of those without guessing, and guessing is how
  # this class of audit goes blind.
  defp analyse_source(path) do
    ast =
      path
      |> File.read!()
      |> Code.string_to_quoted!()

    aliases = collect_aliases(ast)

    %{
      path: Path.relative_to(path, @app_root),
      async?: async_true?(ast),
      detaches: handler_calls(ast, aliases, :detach),
      restores: collect_restores(ast, aliases),
      paired: immediate_pairs(ast, aliases)
    }
  rescue
    error in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      flunk("""
      #{Path.relative_to(path, @app_root)} could not be parsed by this audit:

        #{Exception.message(error)}

      The audit cannot report on a file it cannot read, so this is a hard
      failure rather than a skip.
      """)
  end

  defp collect_aliases(ast) do
    ast
    |> prewalk_collect(fn
      # alias A.B.{C, D}
      {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} ->
        Enum.map(children, fn {:__aliases__, _, parts} ->
          {List.last(parts), Module.concat(base ++ parts)}
        end)

      # alias A.B.C, as: D
      {:alias, _, [{:__aliases__, _, parts}, opts]} when is_list(opts) ->
        case Keyword.get(opts, :as) do
          {:__aliases__, _, [as]} -> [{as, Module.concat(parts)}]
          _ -> [{List.last(parts), Module.concat(parts)}]
        end

      # alias A.B.C
      {:alias, _, [{:__aliases__, _, parts}]} ->
        [{List.last(parts), Module.concat(parts)}]

      _ ->
        nil
    end)
    |> List.flatten()
    |> Map.new()
  end

  defp async_true?(ast) do
    ast
    |> prewalk_collect(fn
      {:use, _, [_, opts]} when is_list(opts) -> Keyword.get(opts, :async) == true
      _ -> nil
    end)
    |> Enum.any?(& &1)
  end

  # `Mod.detach()` / `Mod.attach()`, with `Mod` resolved through the
  # file's own aliases. Four of the five original offenders wrote the bare
  # form (`TelemetryHandler.detach()`), so a fully-qualified-only matcher
  # would have seen one file out of five.
  defp handler_calls(ast, aliases, fun) do
    prewalk_collect(ast, fn node ->
      case handler_call(node, aliases) do
        {mod, ^fun, line} -> {mod, line}
        _ -> nil
      end
    end)
  end

  defp handler_call({{:., _, [{:__aliases__, _, _} = target, fun]}, meta, []}, aliases)
       when fun in [:attach, :detach] do
    {resolve_alias(target, aliases), fun, meta[:line]}
  end

  defp handler_call(_node, _aliases), do: nil

  # A `detach()` whose very next statement is that module's `attach()` has
  # no window for a failure to leak through, so it needs no `on_exit`.
  # This is the idiom five already-correct files use in `setup`.
  defp immediate_pairs(ast, aliases) do
    ast
    |> prewalk_collect(fn
      {:__block__, _, statements} when is_list(statements) ->
        statements
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.flat_map(fn [first, second] ->
          with {mod, :detach, line} <- handler_call(first, aliases),
               {^mod, :attach, _} <- handler_call(second, aliases) do
            [{mod, line}]
          else
            _ -> []
          end
        end)

      _ ->
        nil
    end)
    |> List.flatten()
    |> MapSet.new()
  end

  # A restore is registered by `ensure_boot_handler!/1` (which installs an
  # unconditional `on_exit`) or by an `on_exit` whose body re-attaches.
  # The line reported is the line the restore is REGISTERED on, which is
  # what assertion 2 compares against the detach.
  defp collect_restores(ast, aliases) do
    prewalk_collect(ast, fn node ->
      cond do
        mod = ensure_boot_handler_arg(node, aliases) ->
          [{mod, call_line(node)}]

        args = on_exit_args(node) ->
          line = call_line(node)

          {:__block__, [], args}
          |> handler_calls(aliases, :attach)
          |> Enum.map(fn {mod, _} -> {mod, line} end)

        true ->
          nil
      end
    end)
    |> List.flatten()
  end

  defp ensure_boot_handler_arg({:ensure_boot_handler!, _, [arg]}, aliases),
    do: resolve_alias(arg, aliases)

  defp ensure_boot_handler_arg(
         {{:., _, [{:__aliases__, _, _}, :ensure_boot_handler!]}, _, [arg]},
         aliases
       ),
       do: resolve_alias(arg, aliases)

  defp ensure_boot_handler_arg(_node, _aliases), do: nil

  defp on_exit_args({:on_exit, _, args}) when is_list(args), do: args

  defp on_exit_args({{:., _, [{:__aliases__, _, _}, :on_exit]}, _, args}) when is_list(args),
    do: args

  defp on_exit_args(_node), do: nil

  defp call_line({_, meta, _}) when is_list(meta), do: meta[:line]
  defp call_line({{:., _, _}, meta, _}) when is_list(meta), do: meta[:line]
  defp call_line(_), do: 0

  defp resolve_alias({:__aliases__, _, [head | rest]}, aliases) when is_atom(head) do
    case Map.fetch(aliases, head) do
      {:ok, expanded} -> Module.concat([expanded | rest])
      :error -> Module.concat([head | rest])
    end
  end

  defp resolve_alias(_node, _aliases), do: nil

  # ── Prose scan ─────────────────────────────────────────────────────

  defp scan_ownership_claims do
    @prose_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      relative = Path.relative_to(path, @app_root)

      path
      |> File.read!()
      |> prose_blocks()
      |> Enum.flat_map(fn {line, text} ->
        case Regex.run(@ownership_claim_regex, text) do
          [match] ->
            if Regex.match?(@sandbox_mode_qualifier, text),
              do: [],
              else: [{relative, line, match}]

          nil ->
            []
        end
      end)
    end)
    |> Enum.sort()
  end

  # Groups a source file into prose blocks: a run of consecutive `#`
  # comment lines, or the body of a heredoc (`@moduledoc`, `@doc`, and the
  # failure messages audits like this one are written in — the claim this
  # guard was written for lived in a failure message, not a comment).
  # Lines are joined so a claim split across two source lines still
  # matches, and so the mode qualifier is looked for in the whole block
  # rather than on one line.
  defp prose_blocks(source) do
    source
    |> String.split("\n")
    |> do_prose_blocks(1, [])
  end

  defp do_prose_blocks([], _line, acc), do: Enum.reverse(acc)

  defp do_prose_blocks([head | tail] = lines, line, acc) do
    trimmed = String.trim(head)

    cond do
      String.starts_with?(trimmed, "#") ->
        {run, rest} = Enum.split_while(lines, &String.starts_with?(String.trim(&1), "#"))

        text =
          Enum.map_join(run, " ", fn raw ->
            raw |> String.trim() |> String.trim_leading("#") |> String.trim()
          end)

        do_prose_blocks(rest, line + length(run), [{line, text} | acc])

      String.contains?(trimmed, ~s(""")) ->
        {body, rest} = Enum.split_while(tail, &(not String.contains?(&1, ~s("""))))
        text = Enum.map_join(body, " ", &String.trim/1)

        do_prose_blocks(Enum.drop(rest, 1), line + length(body) + 2, [{line, text} | acc])

      true ->
        do_prose_blocks(tail, line + 1, acc)
    end
  end

  # ── Shared helpers ─────────────────────────────────────────────────

  # `Macro.prewalk` with an accumulator, where `fun` returns the value to
  # collect or `nil` to skip. Used by every scan above so they all traverse
  # identically — divergent traversals are how a rot guard silently stops
  # verifying the thing it exists to verify.
  defp prewalk_collect(ast, fun) do
    {_ast, collected} =
      Macro.prewalk(ast, [], fn node, acc ->
        case fun.(node) do
          nil -> {node, acc}
          value -> {node, [value | acc]}
        end
      end)

    Enum.reverse(collected)
  end

  defp bullets(entries), do: Enum.map_join(entries, "\n", &"  - #{inspect(&1)}")

  defp format_detach_offenders(offenders) do
    body =
      Enum.map_join(offenders, "\n", fn {path, line, mod} ->
        "  #{path}:#{line} — #{inspect(mod)}"
      end)

    """
    These test files detach a boot-attached telemetry handler without a
    restore registered BEFORE the detach:

    #{body}

    Boot handlers are VM-global: `:telemetry` keys them by a fixed
    @handler_id in ETS, so a detach that is not put back silences that
    bridge for every later test in the same BEAM. The symptom is not an
    error — it is an audit assertion that passes because nothing is
    listening. Task 019f9d80 traced five such files, one of which made
    `Platform.Accounts.ExternalAdmissionNotifierTest:138` fail 10/10 for
    months while being written off as a flake in eight briefs.

    Fix ONE of:

      (a) Call
          `Platform.TelemetryHelpers.ensure_boot_handler!(<Module>)` in
          `setup`, BEFORE anything detaches. It attaches now and registers
          an unconditional `on_exit` restore, so a failure between the
          detach and any manual re-attach still restores the handler.

      (b) If the detach is a defensive `detach(); attach()` refresh, put
          the `attach()` on the immediately following line — an adjacent
          pair has no window and this audit accepts it. (Since task
          019f9d80 stage 2 `attach/0` is idempotent, so the detach in that
          pair can usually just be deleted.)

      (c) Add the file to @known_safe in
          test/platform/regression/boot_telemetry_handler_detach_audit_test.exs
          WITH a written reason the leak cannot ride this path.

    Root cause writeup:
      apps/platform/notes/2026-07-26-boot-telemetry-detach.md
    """
  end
end
