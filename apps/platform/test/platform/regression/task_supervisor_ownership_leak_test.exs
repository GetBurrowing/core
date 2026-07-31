defmodule Platform.Regression.TaskSupervisorOwnershipLeakTest do
  @moduledoc """
  Deterministic repro for the 2026-07-03 mass-cascade discovered by
  task 019f3440.

  ## Symptom in CI (job 85296636791, HEAD b3339a24)

      [warning] [ResponsibilityRouter] Roles.assignee_for/1 raised
        key=meetings.summarize: cannot find ownership process for
        #PID<0.764.0> (Task.Supervised)
      [error]   [Summarizer] Unexpected error for transcript ...
      ** (DBConnection.OwnershipError) cannot find ownership process
        for #PID<0.800.0> (Task.Supervised)
          (elixir 1.19.5) lib/task/supervised.ex:105:
            Task.Supervised.invoke_mfa/2
      [error] GenServer Platform.Orchestration.TaskRouterWatcher
        terminating
      ** (DBConnection.OwnershipError) ... in resolve_runtime_for_task
        at task_router_watcher.ex:167

  Every subsequent `data_case.ex:24` sandbox checkout then failed.

  ## Traced chain (verified against b3339a24)

    1. `Summarizer.summarize_async/1`
       (`apps/platform/lib/platform/meetings/summarizer.ex:58`) fires
       `Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        run_summary(transcript) end)` — spawns a process **not**
       listed in DataCase's `supervised_with_repo` allow-list
       (`apps/platform/test/support/data_case.ex:33-37`).
    2. Spawned Task calls `router_meetings_summarize_filled?/0` →
       `ResponsibilityRouter.responsibility_filled?/1` →
       `safe_assignee_for/1` at
       `apps/platform/lib/platform/responsibilities/router.ex:1226`.
    3. `safe_assignee_for/1` calls `Roles.assignee_for/1` which runs
       `Repo.one` from a process without sandbox ownership. The
       existing `rescue error ->` clause at router.ex:1231 catches
       the DBConnection.OwnershipError, logs at :warning, and returns
       `nil` — this branch is safe.
    4. `responsibility_filled?/1` returns `false` → the summarizer
       falls through to `run_summary_legacy/3` at summarizer.ex:161.
    5. `run_summary_legacy/3` calls `call_llm/3` which returns
       `{:error, :no_summary_provider_configured}` in test env
       (`Platform.Meetings.Config.summary().provider == :none`), then
       calls `Meetings.fail_transcript(id)` at summarizer.ex:210 —
       **this** `Repo.update` **raises DBConnection.OwnershipError**.
    6. The outer `rescue e ->` at summarizer.ex:213 catches THAT
       raise, then **calls `Meetings.fail_transcript(id)` a second
       time at summarizer.ex:216** — which raises again from the
       exact same Task-Supervised process. The second raise escapes
       the rescue clause (a `rescue` block does not wrap itself).
    7. The uncaught exit propagates through `Task.Supervised.invoke_mfa/2`
       → the global `Platform.TaskSupervisor`'s task terminates. In
       CI's serial-retry batch the escape coincides with
       `TaskRouterWatcher` (`apps/platform/lib/platform/orchestration/task_router_watcher.ex:167`)
       receiving a `{:task_updated, ...}` PubSub broadcast and running
       its OWN unguarded `Repo.get` outside the sandbox allow-list.
       The watcher terminates + supervisor restarts it OUTSIDE the
       DataCase owner chain — every subsequent test's
       `data_case.ex:24` sandbox checkout fails.

  ## PR provenance

    * PR #474 (`216a3f88`) — introduced the Roles predicate; the
      `Roles.assignee_for → Repo.one` path is the ORIGINAL DB touch.
      Before this PR, `safe_assignee_for/1` short-circuited on an
      absent `Platform.Roles` module and never raised.
    * PR #480 (`243252ae`) — seeded the closed-roster prompt templates
      including `meetings.summarize`. Did NOT itself materialise a
      `RoleAssignment`, but its test coverage brought the router path
      up in more suites, exposing the DB touch inside Task-Supervised
      children.
    * PR #481 (`83eaeeae`) — shipped `Meetings.SummarizerSweeper`
      (`apps/platform/lib/platform/meetings/summarizer_sweeper.ex`)
      and `Responsibilities.StallRegistry`. Both use
      `Task.Supervisor.async_nolink(Platform.TaskSupervisor, ...)` to
      run `Summarizer.run_summary_legacy/3`. In test env both are
      gated off (`config/test.exs:97,102`), so they don't drive the
      cascade directly — but they made the double-fail_transcript
      code path load-bearing.

  ## What this test asserts (the repro)

  Reproduces the leak deterministically by:

    1. Seeding the `meeting_scribe` role bundle so
       `safe_assignee_for/1` reaches the `role_assignments` table
       (matching the exact call shape production tests exercise).
    2. Spawning an unlinked intermediate process, clearing its
       `$callers` chain via `Process.put(:"$callers", [])`, and
       calling `Summarizer.summarize_async/1` from there. Ecto's
       modern `$callers` propagation would otherwise carry sandbox
       ownership into the spawned Task-Supervised child and mask
       the leak. Clearing `$callers` mirrors the production shape
       where the Cowboy handler / Router GenServer that invokes
       `summarize_async` is not itself sandbox-owned.
    3. Monitoring the Task-Supervised child and pattern-matching
       on its exit reason.

  On CURRENT MAIN (b3339a24) this test **FAILS** with:

      Task-Supervised process exited abnormally (leak still present).
      Reason: {%DBConnection.OwnershipError{...}, [
        ...
        {Platform.Meetings, :fail_transcript, 1,
         [file: ~c"lib/platform/meetings.ex", line: 1447]},
        {Platform.Meetings.Summarizer, :run_summary_legacy, 3,
         [file: ~c"lib/platform/meetings/summarizer.ex", line: 216]},
        {Task.Supervised, :invoke_mfa, 2, ...}
      ]}

  Line 216 is the second `fail_transcript` INSIDE the outer rescue —
  this is the escape point.

  On STAGE 2's FIX (planned) this test **PASSES**: the summarizer's
  rescue body (or `Meetings.fail_transcript/1` itself) catches
  `DBConnection.OwnershipError`, the Task exits `:normal`, and the
  transcript reaches `"failed"`.

  Tagged `:cascade_repro` and excluded from the default `mix test`
  run in `test/test_helper.exs`; pass condition for stage 1 is that
  the module compiles and the test can be invoked explicitly via
  `mix test --only cascade_repro`.
  """
  # async: true is load-bearing — DataCase's shared-mode sandbox (set on
  # async: false setups) makes the connection reachable from *any*
  # process on the node, including our `Task.Supervisor.start_child`
  # spawn. That silently masks the leak. With async: true the sandbox
  # is per-owner and Task.Supervised children must be explicitly
  # allowed via `Sandbox.allow/3` — the leak deterministically fires.
  use Platform.DataCase, async: true

  import ExUnit.CaptureLog

  alias Platform.Meetings
  alias Platform.Meetings.Summarizer
  alias Platform.Repo
  alias Platform.Roles.RoleResponsibility

  @summarize_key "meetings.summarize"

  @moduletag :cascade_repro

  # Seed the meeting_scribe role bundle so
  # `Roles.lookup_role_assigned_agent/1` actually reaches the
  # `role_assignments` table from the Task-Supervised process. We
  # intentionally do NOT seed a `RoleAssignment` — that keeps the
  # `responsibility_filled?/1` branch as `false` (via the current
  # `rescue`), so `run_summary/1` falls through to
  # `run_summary_legacy/3`, whose double-`fail_transcript` inside the
  # rescue is the actual escape point.
  defp seed_meeting_scribe_bundle! do
    Repo.insert!(
      %Platform.Roles.Role{
        key: "meeting_scribe",
        name: "Meeting Scribe",
        description: "cascade-repro seed",
        icon: "hero-star"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    Repo.insert!(
      %RoleResponsibility{
        role_key: "meeting_scribe",
        responsibility_key: @summarize_key
      },
      on_conflict: :nothing,
      conflict_target: [:role_key, :responsibility_key]
    )
  end

  describe "Summarizer.summarize_async leaks sandbox ownership through fail_transcript rescue" do
    test "Task exits normally AND transcript reaches a terminal state — proves fail_transcript inside the rescue did not re-raise" do
      _ = seed_meeting_scribe_bundle!()

      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: "cascade-repro-#{System.unique_integer([:positive])}",
          space_id: nil,
          status: "processing",
          segments: [
            %{
              "speaker_name" => "Rowan",
              "text" => "Kicking off the retro. Sprint felt good but demo slid to Wednesday.",
              "start_time" => 0,
              "end_time" => 6_000,
              "final" => true
            },
            %{
              "speaker_name" => "Dana",
              "text" => "Onboarding funnel dropped 12%. Revert lands tomorrow.",
              "start_time" => 6_500,
              "end_time" => 14_000,
              "final" => true
            }
          ]
        })

      # The router path bails via the `safe_assignee_for/1` rescue —
      # `responsibility_filled?/1` returns `false` because no
      # `RoleAssignment` exists yet the bundle row would otherwise
      # link `meeting_scribe → meetings.summarize`. That drives the
      # summarizer down `run_summary_legacy/3` → `call_llm/3` → since
      # `Meetings.Config.summary().provider == :none` in test env the
      # LLM path returns `{:error, :no_summary_provider_configured}`
      # → line 210 calls `Meetings.fail_transcript/1` → **raises**
      # DBConnection.OwnershipError from the Task-Supervised process.
      # The outer rescue at summarizer.ex:213 catches it, then line
      # 216 calls `Meetings.fail_transcript/1` a SECOND time — which
      # raises again and ESCAPES the rescue (a rescue block does not
      # wrap itself). That escape is the leak.

      # ── Force the sandbox-unowned scenario ──
      #
      # Modern Ecto propagates the sandbox owner through `$callers`.
      # `Task.Supervisor.start_child(sup, fn -> ... end)` inherits
      # `$callers` from the caller — so if we spawn directly from the
      # test process, the child inherits our sandbox ownership and
      # the leak silently doesn't fire.
      #
      # The production cascade happens when
      # `Summarizer.summarize_async/1` is invoked from a process that
      # is NOT itself sandbox-owned — e.g. the Cowboy handler
      # servicing `POST /api/webhooks/livekit`, or a Router GenServer
      # that just received a PubSub broadcast. `$callers` in that
      # environment is `[cowboy-handler-pid]`, and NEITHER of those
      # pids has the sandbox connection allowed.
      #
      # We reproduce the leak deterministically by first spawning an
      # unlinked intermediate process (whose `$callers` chain we then
      # clear) and calling `summarize_async` from THAT process — so
      # the inner Task.Supervisor.start_child inherits an empty
      # `$callers` and its DB calls raise DBConnection.OwnershipError
      # exactly like production.
      test_pid = self()

      # ── Runtime Logger level override (required for the log capture below) ──
      # `config/test.exs:33` sets `config :logger, level: :warning` — so
      # `Logger.debug/1` calls are filtered at the Logger level BEFORE
      # they ever reach `CaptureLog`'s handler, even when the capture
      # opts pass `level: :debug`. Per `ExUnit.CaptureLog.with_log/2`
      # docstring (elixir 1.19): "if `Logger.level/0` is set to a higher
      # level than the one configured in this function, no message will
      # be captured." We temporarily drop the runtime level to `:debug`
      # around the spawn+wait window, then restore.
      #
      # Global mutation is acceptable here because the whole module is
      # tagged `@moduletag :cascade_repro` and excluded from the default
      # `mix test` run (`test/test_helper.exs:7`). The test only runs
      # under `--only cascade_repro`, and this is currently the only
      # cascade_repro test. If a future PR adds peer cascade_repro tests
      # they should either accept this brief window or migrate the
      # capture to a dedicated Logger handler.
      original_logger_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original_logger_level) end)

      # ── Log capture (load-bearing for assertion E) ──
      # The specific `rescue DBConnection.OwnershipError ->` clause in
      # `Platform.Responsibilities.Router.safe_assignee_for/1` (and the
      # peer clause in `Platform.Meetings.Summarizer.safe_fail_transcript/1`)
      # emit a distinctive `:debug` log substring: `"sandbox-owned DB
      # call from Task.Supervised"`. The GENERIC `error ->` fallback
      # clause immediately below the OwnershipError one logs at
      # `:warning` with a different message (`"Roles.assignee_for/1
      # raised ..."`) and does NOT contain that substring. Capturing
      # the log and asserting the substring is present pins the fix
      # to the OwnershipError-specific clause — commenting it out and
      # letting the generic rescue absorb the raise flips this test to
      # RED even though the outer `exit_reason == :normal` assertion
      # would still pass.
      {exit_reason, log_output} =
        with_log([level: :debug], fn ->
          spawn(fn ->
            # Blank out the callers chain so the Task supervisor's child
            # can't reach back to us for sandbox ownership.
            Process.put(:"$callers", [])

            result = Summarizer.summarize_async(transcript)
            send(test_pid, {:async_result, result})
          end)

          task_pid =
            receive do
              {:async_result, {:ok, pid}} -> pid
              {:async_result, other} -> flunk("summarize_async returned #{inspect(other)}")
            after
              2_000 -> flunk("summarize_async never returned")
            end

          ref = Process.monitor(task_pid)

          receive do
            {:DOWN, ^ref, :process, ^task_pid, reason} -> reason
          after
            3_000 ->
              flunk("Task did not exit within 3s — should have completed the run_summary body")
          end
        end)

      # ── Load-bearing assertion (A) ──
      # Pre-fix: the second `Meetings.fail_transcript/1` call inside
      # the summarizer's rescue re-raises DBConnection.OwnershipError,
      # escaping the rescue. The Task exit reason is a 2-tuple
      # `{%DBConnection.OwnershipError{}, [stacktrace...]}` — this
      # assertion FAILS.
      # Post-fix (stage 2): the rescue body is itself guarded and the
      # Task exits `:normal`.
      assert exit_reason == :normal,
             """
             Task-Supervised process exited abnormally (leak still present).
             Reason: #{inspect(exit_reason, pretty: true, limit: :infinity)}

             This is the 2026-07-03 cascade — see
             apps/platform/notes/2026-07-06-datacase-cascade-rootcause.md
             for the traced chain. Stage-2 fix must catch
             DBConnection.OwnershipError in the summarizer's rescue
             body OR in Meetings.fail_transcript itself.
             """

      # ── Load-bearing assertion (B) ──
      # Pre-fix: because the second `fail_transcript` raised, the
      # transcript row was never updated — it's still `"processing"`
      # (our seed status). Post-fix: `fail_transcript` succeeds and
      # the transcript is `"failed"` (the LLM path's terminal state).
      reloaded = Meetings.get_transcript(transcript.id)

      assert reloaded.status in ~w(failed complete),
             """
             Transcript status is #{inspect(reloaded.status)} — should be "failed"
             (LLM path's terminal state) or "complete". Pre-fix, the
             rescue-block escape leaves the row stuck in "processing"
             because `Meetings.fail_transcript/1` re-raised before the
             update landed.
             """

      # ── Load-bearing assertion (E) ──
      # Pins the fix to the OwnershipError-SPECIFIC rescue clause.
      #
      # Task-level review flagged that the `exit_reason == :normal` and
      # `transcript.status == "failed"` assertions above are BOTH
      # satisfied even if the specific `DBConnection.OwnershipError ->`
      # clause in `safe_assignee_for/1` (router.ex:1270) is deleted —
      # the peer generic `error ->` clause on the immediately following
      # line will still catch the raise, log a `:warning`, and return
      # `nil`. The test would pass green while the fix is gone.
      #
      # The OwnershipError-specific clause emits a distinctive `:debug`
      # log line containing `"sandbox-owned DB call from Task.Supervised"`.
      # The generic `error ->` fallback emits a different message
      # (`"Roles.assignee_for/1 raised ..."`) at `:warning` and does
      # NOT contain this substring. Same distinctive substring is
      # emitted by `Summarizer.safe_fail_transcript/1` when its own
      # OwnershipError branch fires with `:no_sandbox`.
      #
      # Asserting the substring is present makes the test load-bearing
      # on the specific clause: strip it and the test flips RED.
      assert log_output =~ "sandbox-owned DB call from Task.Supervised",
             """
             Captured logs do not contain the OwnershipError-specific
             substring `"sandbox-owned DB call from Task.Supervised"`.
             Either:

               (a) The `rescue DBConnection.OwnershipError ->` clause in
                   `Platform.Responsibilities.Router.safe_assignee_for/1`
                   (or its peer in
                   `Platform.Meetings.Summarizer.safe_fail_transcript/1`)
                   was deleted / commented out — the generic `error ->`
                   fallback silently absorbs the raise but does NOT
                   emit this specific substring. Restore the specific
                   clause.

               (b) Test env `Logger` level is above `:debug` and the
                   capture opts didn't override it — this test wraps
                   its spawn+wait in `with_log([level: :debug], ...)`
                   specifically to override, so if this assertion
                   fires that override is broken.

             Captured log:
             #{log_output}
             """

      # ── Belt (C): DELETED in task 019fb978 stage 2, deliberately ──
      #
      # This belt asserted `Process.alive?(Process.whereis(TaskRouterWatcher))`
      # behind an `if watcher_pid do` guard. Stage 2 gated the watcher off in
      # test (`:start_task_router_watcher`, config/test.exs), so `whereis/1` is
      # now always `nil` and the guard always false — the assertion would never
      # execute again.
      #
      # It is removed rather than left in place because an assertion that can
      # no longer run is worse than no assertion: it reads as coverage. This is
      # a REAL, named coverage loss (the belt was already documented above as
      # "not directly proven by this isolated test"), and it is recorded as one
      # rather than papered over. It is NOT re-established by starting a
      # per-case watcher here: this module is `async: true` precisely so the
      # sandbox is per-owner, and adding a Repo-touching singleton to it would
      # reintroduce the hazard stage 2 exists to remove.
      #
      # ── Belt (D) ──
      # The test process's own sandbox connection still works — proves
      # the child's exit didn't invalidate the owner chain for us.
      assert is_integer(Repo.aggregate(Platform.Tasks.Task, :count, :id))
    end
  end
end
