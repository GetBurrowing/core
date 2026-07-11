defmodule Platform.Regression.SupervisedTaskRepoAuditTest do
  @moduledoc """
  Source-scan guard against future re-openings of the 2026-07-03
  DBConnection.OwnershipError cascade (task 019f3440).

  Two orthogonal assertions:

    1. **Task-Supervisor rescue audit.** Every module under
       `apps/platform/lib/**/*.ex` that spawns work under
       `Platform.TaskSupervisor` via `Task.Supervisor.async_nolink/2`
       or `Task.Supervisor.start_child/2` must EITHER
         (a) contain a literal `rescue DBConnection.OwnershipError` clause
             — the fix stage 2 applied to the router / summarizer /
             watcher seams — OR
         (b) appear in `@known_safe` below with a comment explaining
             why the sandbox-owner leak cannot propagate through it in
             test env.

       New callers that satisfy neither condition fail this test with
       an actionable message.

    2. **Start-flag audit.** Every `maybe_add_*/1` gate in
       `Platform.Application.start/2` that reads an
       `Application.get_env(:platform, :start_*_..., true)` flag must
       resolve to `false` in the test environment. If a future PR adds
       a new `maybe_add_new_thing/1` without also flipping the flag off
       in `config/test.exs`, the singleton boots for real under the
       DataCase sandbox and can raise `DBConnection.OwnershipError`
       from an unallowed process — recreating the CI cascade shape.

  Both audits are cheap (pure `File.read!` + regex, no DB, no PubSub)
  and run in the default `mix test` set — no `@moduletag :cascade_repro`.
  They belong to the regression suite (`test/platform/regression/`) so
  they read as a peer of the deterministic-repro test that pins the
  original escape (see `task_supervisor_ownership_leak_test.exs` in
  the same directory).

  Root-cause writeup: `apps/platform/notes/2026-07-06-datacase-cascade-rootcause.md`.
  """

  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib/platform", __DIR__)
  @application_ex Path.expand("../../../lib/platform/application.ex", __DIR__)

  # Modules that call `Task.Supervisor.(async_nolink|start_child)` under
  # `Platform.TaskSupervisor` but do NOT need a `rescue
  # DBConnection.OwnershipError` clause. Each entry MUST cite the reason
  # the sandbox-owner leak cannot ride this path in test env — either
  # the spawn branch is gated off by a test-env flag, or the spawned
  # body does not touch `Repo`.
  @known_safe [
    # `Platform.Memory.ingest_async/1` (memory.ex:82) spawns an HTTP
    # POST to the external memory service — the spawned body calls
    # `provider().ingest/2` (Noop / Mem0 / etc.), not `Repo.*`. In test
    # env `Platform.Memory.Providers.Noop` is the default, so there is
    # nothing to leak.
    "lib/platform/memory.ex",

    # `Platform.Chat.Canvas.Server.persist_async/5` (canvas/server.ex:398)
    # is gated on `Application.get_env(:platform, :canvas_persist_sync,
    # false)`. In `config/test.exs` this is set to `true`, so the
    # `Task.Supervisor.start_child` branch NEVER FIRES in test env —
    # persistence runs synchronously under the sandbox owner. Production
    # takes the async branch but production doesn't have the sandbox
    # constraint. The synchronous test-mode branch is the reason this
    # is safe; if `canvas_persist_sync` ever flips to `false` in test,
    # this exemption must be revisited.
    "lib/platform/chat/canvas/server.ex",

    # `Platform.Tasks.StackDeployer.*` has four call sites (lines 177,
    # 215, 244, 584). All four are guarded by
    # `if async?() do ... else <sync-fallback> end` where `async?/0`
    # reads `Keyword.get(config(), :async, true)`. In `config/test.exs`
    # (line 108–110) `:async` is set to `false`, so every branch takes
    # the synchronous body and NO `Task.Supervisor` spawn happens in
    # test env. Production takes the async branch but production
    # doesn't use the sandbox.
    "lib/platform/tasks/stack_deployer.ex",

    # `Platform.Meetings.SummarizerSweeper` (lines 290, 358) uses
    # `Task.Supervisor.(start_child|async_nolink)` for periodic sweep
    # bodies. The sweeper itself is gated on
    # `:start_summarizer_sweeper` (false in test env, verified by the
    # start-flag audit below), so no ticks fire in the shared test
    # BEAM. Individual sweeper tests start a per-case instance under
    # DataCase's `supervised_with_repo` allow-list (data_case.ex) and
    # explicitly `Sandbox.allow/3` the spawned children — the
    # sweeper-test suite is the only place the Task.Supervisor branch
    # runs, and it does so under sandbox ownership.
    "lib/platform/meetings/summarizer_sweeper.ex",

    # `Platform.Security.Sweeper` (task 019f3e8e-4406 stage 2, ADR-0043)
    # uses `Task.Supervisor.async_nolink/2` to isolate scanner-body
    # crashes. The sweeper is gated on `:start_security_sweeper` (false
    # in test env, verified by the start-flag audit below), so no ticks
    # fire in the shared test BEAM. Sweeper tests start a per-case
    # instance under DataCase's `supervised_with_repo` allow-list and
    # use stub scanner modules that only send a message back to the
    # test PID (no Repo calls in the spawned body). Stage 3+ real
    # scanner bodies DO touch Repo (via `FindingFiler → Tasks`), so
    # this exemption must be revisited when those land — either the
    # scanner call sites wrap in `rescue DBConnection.OwnershipError`
    # or the test-injection seam swaps in a stub.
    "lib/platform/security/sweeper.ex"
  ]

  # Explicit list of `:start_*` flags the Platform.Application boot
  # gates read (as of 2026-07-07 / d9307abf). The application.ex
  # traversal below programmatically extracts the flags in-use and
  # asserts this list matches — a future PR that adds a new
  # `maybe_add_*` gate MUST either extend this list AND flip the flag
  # off in `config/test.exs` OR fail the audit. This is the belt half of
  # the belt-and-braces pair; the braces half is the runtime
  # `Application.get_env` assertion further down.
  @expected_disabled_flags [
    :start_attention_router,
    :start_system_event_scheduler,
    :start_responsibilities_registry,
    :start_responsibility_router,
    :start_cutover_monitor,
    :start_wiki_indexer,
    :start_meeting_historian_handler,
    :start_meeting_notifier,
    :start_meeting_intent_classifier,
    :start_meeting_intent_dispatcher,
    :start_summarizer_sweeper,
    :start_stall_registry,
    :start_security_sweeper,
    :start_space_purger
  ]

  # ── Assertion 1: Task-Supervisor rescue audit ─────────────────────

  describe "Task.Supervisor sites under Platform.TaskSupervisor" do
    test "every caller either rescues DBConnection.OwnershipError or is in @known_safe" do
      offenders = scan_task_supervisor_sites()

      assert offenders == [], format_offenders(offenders)
    end

    test "every @known_safe entry actually contains a Task.Supervisor call site" do
      # Guard against @known_safe rotting — an entry with no matching
      # site is dead code that gives false confidence.
      stale =
        Enum.filter(@known_safe, fn relative_path ->
          full = Path.join(@lib_root |> Path.dirname() |> Path.dirname(), relative_path)
          source = File.read!(full)

          not Regex.match?(
            ~r/Task\.Supervisor\.(?:async_nolink|start_child)\(\s*(?:Platform\.TaskSupervisor|task_supervisor\(\))/,
            source
          )
        end)

      assert stale == [], """
      @known_safe lists modules that no longer spawn under
      Platform.TaskSupervisor — clean these up so the audit doesn't
      silently drift:

      #{Enum.map_join(stale, "\n", &"  - #{&1}")}
      """
    end
  end

  # ── Assertion 2: Start-flag audit ─────────────────────────────────

  describe "Platform.Application maybe_add_* start flags" do
    test "every :start_* flag application.ex reads is false in test env" do
      flags = discover_start_flags(File.read!(@application_ex))

      # Cross-check the discovered set against @expected_disabled_flags
      # — anything new must be added to both this list AND config/test.exs.
      new_flags = flags -- @expected_disabled_flags
      removed_flags = @expected_disabled_flags -- flags

      assert new_flags == [], """
      Platform.Application added new maybe_add_* gates without updating
      the audit test. Add the new flag(s) to
      @expected_disabled_flags in
      test/platform/regression/supervised_task_repo_audit_test.exs AND
      set them to `false` in config/test.exs:

      #{Enum.map_join(new_flags, "\n", &"  - #{&1}")}

      Rationale: a maybe_add_* gate that defaults to `true` will boot a
      real singleton under the DataCase sandbox — if that singleton
      touches Repo from an unallowed process it recreates the
      2026-07-03 cascade. See
      apps/platform/notes/2026-07-06-datacase-cascade-rootcause.md.
      """

      assert removed_flags == [], """
      @expected_disabled_flags references flags no longer read by
      Platform.Application. Remove these stale entries:

      #{Enum.map_join(removed_flags, "\n", &"  - #{&1}")}
      """

      # Runtime assertion: each flag reads as `false` in test env.
      # Belt-and-braces alongside the config/test.exs static scan above.
      not_disabled =
        Enum.reject(flags, fn flag ->
          Application.get_env(:platform, flag) == false
        end)

      assert not_disabled == [], """
      One or more :start_* flags did not resolve to `false` in the test
      environment. Every maybe_add_* gate MUST be explicitly disabled
      in config/test.exs so tests start per-case instances under
      DataCase sandbox ownership (see other flags for the pattern).
      Un-disabled flags:

      #{Enum.map_join(not_disabled, "\n", fn flag -> "  - #{flag} = #{inspect(Application.get_env(:platform, flag))}" end)}
      """
    end

    test "config/test.exs contains a `false` literal for every expected flag" do
      # Guards against runtime patching that flips a flag mid-test and
      # forgets to restore it — the on-disk config is the ground truth.
      test_config = File.read!(Path.expand("../../../config/test.exs", __DIR__))

      missing =
        Enum.filter(@expected_disabled_flags, fn flag ->
          not Regex.match?(
            ~r/config\s+:platform\s*,\s*:#{flag}\s*,\s*false\b/,
            test_config
          )
        end)

      assert missing == [], """
      config/test.exs is missing `config :platform, :<flag>, false`
      lines for the following flags:

      #{Enum.map_join(missing, "\n", &"  - #{&1}")}

      Every maybe_add_* gate must be explicitly disabled in test env.
      """
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────

  # Walks `apps/platform/lib/**/*.ex`, finds every file that calls
  # `Task.Supervisor.(async_nolink|start_child)` targeting
  # `Platform.TaskSupervisor` (or the `task_supervisor()` accessor used
  # by `Platform.Tasks.StackDeployer`), and returns a list of
  # `{relative_path, line_numbers}` for any file that lacks a `rescue
  # DBConnection.OwnershipError` clause AND is not in `@known_safe`.
  defp scan_task_supervisor_sites do
    lib_dir = @lib_root |> Path.dirname() |> Path.dirname()

    Path.wildcard(Path.join(@lib_root, "**/*.ex"))
    |> Enum.reduce([], fn absolute_path, acc ->
      source = File.read!(absolute_path)

      site_lines =
        source
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _idx} ->
          Regex.match?(
            ~r/Task\.Supervisor\.(?:async_nolink|start_child)\(\s*(?:Platform\.TaskSupervisor|task_supervisor\(\))/,
            line
          )
        end)
        |> Enum.map(fn {_line, idx} -> idx end)

      relative_path = Path.relative_to(absolute_path, lib_dir)

      cond do
        site_lines == [] ->
          acc

        relative_path in @known_safe ->
          acc

        # Match the literal clause head `DBConnection.OwnershipError ->`
        # rather than the bare token so a docstring / comment mention
        # or a bindings-only reference doesn't satisfy the audit.
        # `rescue` can appear either as a keyword-style block
        # (`rescue DBConnection.OwnershipError ->`) or as a `do/rescue`
        # pair with a newline between them — the `\s+` handles both.
        # The `->` on the same clause head is the load-bearing bit that
        # task-level review flagged as missing from the previous regex.
        Regex.match?(
          ~r/rescue\s+DBConnection\.OwnershipError\s*->/,
          source
        ) ->
          acc

        true ->
          [{relative_path, site_lines} | acc]
      end
    end)
    |> Enum.sort()
  end

  defp format_offenders(offenders) do
    body =
      Enum.map_join(offenders, "\n\n", fn {path, lines} ->
        line_list = Enum.map_join(lines, ", ", &Integer.to_string/1)
        "  #{path} — line(s) #{line_list}"
      end)

    """
    The following module(s) spawn work under Platform.TaskSupervisor
    but do NOT contain `rescue DBConnection.OwnershipError` and are not
    listed in @known_safe. In test env the spawned Task-Supervised
    child is not in the DataCase sandbox owner chain (see data_case.ex),
    so any Repo call inside the spawn body will raise
    DBConnection.OwnershipError — the exact shape that caused the
    2026-07-03 CI cascade.

    Fix ONE of:

      (a) Wrap the Repo-touching path in `try/rescue
          DBConnection.OwnershipError -> ...` inside the spawned body.
          Follow the pattern in
          apps/platform/lib/platform/responsibilities/router.ex
          (`safe_assignee_for/1`, `fire_trigger/3`) or
          apps/platform/lib/platform/meetings/summarizer.ex
          (`safe_fail_transcript/1`).

      (b) If the spawn path is unreachable in test env (config-gated
          off / sync-fallback), add the module to `@known_safe` in
          this file with a comment explaining why the sandbox-owner
          leak cannot ride the path.

    Root cause writeup:
      apps/platform/notes/2026-07-06-datacase-cascade-rootcause.md

    Offending sites:

    #{body}
    """
  end

  # Parses `Platform.Application`'s source for every
  # `Application.get_env(:platform, :start_XXX, ...)` call inside a
  # `maybe_add_*` function body. Returns the discovered atoms as a
  # sorted list.
  defp discover_start_flags(source) do
    ~r/Application\.get_env\(\s*:platform\s*,\s*:(start_[a-z_]+)\s*,/
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.to_atom/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
