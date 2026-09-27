defmodule Platform.Regression.SpawnPrimitiveInventoryAuditTest do
  @moduledoc """
  Source-scan guard against the blind spot in
  `supervised_task_repo_audit_test.exs` (task 01a089e5, found 2026-09-10 by
  Dalton's agent while fixing `01a06638`).

  ## The blind spot

  `supervised_task_repo_audit_test.exs`'s ONLY detection vocabulary is
  `@task_supervisor_site_regex`, which matches exactly
  `Task.Supervisor.(async_nolink|start_child)(Platform.TaskSupervisor|*_task_supervisor())`.
  Six other spawn primitives in `apps/platform/lib/**/*.ex` are completely
  invisible to it: `Task.start(`, bare `spawn(`, `spawn_link(`,
  `spawn_monitor(`, `Task.async(`, `Task.async_stream(`. None of them run
  under `Platform.TaskSupervisor`, so none of them get the rescue/known_safe
  audit that spawn class receives — and several of them reach `Repo`
  transitively through a called helper, which is exactly the shape that
  caused the 2026-07-03 DBConnection.OwnershipError cascade the sibling file
  guards against.

  This file is ADDITIVE. It does not touch
  `@task_supervisor_site_regex`, its regex, or its tests. In particular, it
  deliberately does NOT widen that regex to also match these six primitives:
  nearly every real Repo-touching site among them reaches Repo through a
  NAMED HELPER (`WorkspaceBootstrap.boot/1`, `AutoMerger.record_merge_result/2`,
  `Wiki.upsert_page/2`, `Inbound.poll_now/2`, ...) rather than a literal
  `Repo.` token inside the spawned closure itself, so a regex-only
  conjunction check would still miss exactly the sites that most need
  catching. See task 01a089e5's own census for the full reasoning.

  ## Design: inventory-with-justification, not a widened regex

  Mirrors `supervised_task_repo_audit_test.exs`'s `@known_safe` pattern, at
  the SAME granularity: one inventory entry per `{file, primitive}` pair
  (not per line — `presence_hooks.ex` has two `Task.start(` call sites with
  one shared justification, exactly like `@known_safe`'s file-level entries
  cover every `Task.Supervisor` call in that file).

  Two directions, both enforced:

    1. Every site the scanner finds that isn't in `@inventory` fails the
       suite with an actionable `file:line` message (`offenders` test).
    2. Every `@inventory` entry whose site no longer exists in the current
       tree also fails (`staleness` test) — the same shape as
       `supervised_task_repo_audit_test.exs`'s "every @known_safe entry
       actually contains a Task.Supervisor call site" test.

  `known_gap: true` marks an entry that is genuinely unprotected today
  (reaches Repo transitively, not test-env-gated, not the pinned
  state-machine exemption) rather than claiming it is safe. Seeding these
  honestly keeps this guard green without lying about coverage; a later
  stage remediates them and can add a stricter zero-known-gap assertion
  once the census is actually cleared.

  ## DO NOT WIDEN THE OLD REGEX — why `task_router.ex`'s `spawn_monitor` stays out

  `lib/platform/orchestration/task_router.ex`'s `maybe_run_design_edge/2`
  does `{pid, ref} = spawn_monitor(fn -> run_design_edge(router, task) end)`.
  That `{pid, ref}` is stored in the router's own `%State{design_run: {pid,
  ref}}` and consumed by the very next clause head
  (`maybe_run_design_edge(%State{design_run: {_pid, _ref}} = state, _task)`)
  to enforce at-most-one-designer-edge-per-router. Supervising this away
  breaks that invariant. It is pinned in `@inventory` below with this exact
  reasoning so the next agent who finds it via a widened regex does not
  "fix" it into an allowlist and rebuild the blindness this ticket is about.

  Cheap by construction (`Path.wildcard` + `File.read!` + regex, no DB, no
  PubSub, no compilation), so it runs in the default `mix test` set
  alongside its sibling in `test/platform/regression/`.
  """

  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib", __DIR__)

  # THE single definition of each of the six primitive spellings this guard
  # exists to catch. Each regex requires the literal `(` immediately after
  # the primitive's name, which is what keeps `Task.start(` from matching
  # `Task.start_link(`, `spawn(` from matching `spawn_link(`/`spawn_monitor(`,
  # and `Task.async(` from matching `Task.async_stream(` — no ordering
  # dependency between entries needed.
  #
  # `(?:Elixir\.)?` on the `Task.*` primitives mirrors
  # `supervised_task_repo_audit_test.exs`'s own guard against alias
  # shadowing (see `task_alias_shadowing_audit_test.exs`) — it is not
  # theoretical here: `github_webhook_controller.ex` aliases
  # `Platform.Tasks.Task`, so its real spawn site is written
  # `Elixir.Task.start(` and a regex without this alternation would miss it.
  @primitive_specs [
    {:task_start, ~r/(?:Elixir\.)?Task\.start\(/},
    {:spawn, ~r/\bspawn\(/},
    {:spawn_link, ~r/\bspawn_link\(/},
    {:spawn_monitor, ~r/\bspawn_monitor\(/},
    {:task_async, ~r/(?:Elixir\.)?Task\.async\(/},
    {:task_async_stream, ~r/(?:Elixir\.)?Task\.async_stream\(/}
  ]

  # ── The inventory ─────────────────────────────────────────────────
  #
  # One entry per {path, primitive} pair. Every site the scanner finds for
  # that pair is covered by the entry's justification — multiple call sites
  # in one file (e.g. presence_hooks.ex's two Task.start calls, same
  # WorkspaceBootstrap.boot/1 body) share one entry, same as @known_safe.
  #
  # Verified against the tree at HEAD as of task 01a089e5 stage 1
  # (2026-09-27): 16 live sites total (10 Task.start, 0 bare spawn — the
  # ticket's original 4 bare-spawn sites were already converted by task
  # 01a06638 / PR #965 before this stage — 1 spawn_link, 1 spawn_monitor,
  # 1 Task.async, 3 Task.async_stream), all 14 accounted for below.
  #
  # Stage 3 (2026-09-27) remediated the six confirmed-unprotected Task.start
  # call sites this file seeded as `known_gap: true`. Five of the six
  # (agent_responder.ex's 1, shell_live.ex's 1, presence_hooks.ex's 2,
  # canvas_hooks.ex's 1) were converted to
  # `Task.Supervisor.async_nolink(Platform.TaskSupervisor, ...)` with a
  # `rescue DBConnection.OwnershipError` clause in the same file — they are
  # no longer `Task.start(` sites at all, so their @inventory entries are
  # removed rather than re-justified (the staleness test would fail
  # otherwise). `supervised_task_repo_audit_test.exs`'s own file-granularity
  # rescue check now covers them; see that file's offender scan. The sixth
  # (github_webhook_controller.ex's spawn_auto_merge/5) stays a genuine
  # `Task.start` site but is now config-gated — moved to the "config-gated
  # off in test env" bucket below. 11 live sites total now (5 Task.start, 0
  # bare spawn, 1 spawn_link, 1 spawn_monitor, 1 Task.async, 3
  # Task.async_stream), 10 entries.
  #
  # Stage 4 (2026-09-27) resolved the three remaining `known_gap: true`
  # entries (the mail.ex / maintenance_subagent.ex / wiki/search.ex
  # Task.async_stream sites). None needed stage 3's conversion: each was
  # empirically verified safe under `async: true` — Task.async_stream
  # propagates `$callers` via Elixir's own Task machinery, a different risk
  # class from bare Task.start/spawn — and each entry now names the test(s)
  # that prove it. `known_gap: true` no longer appears anywhere in
  # @inventory; see the "zero remaining known_gap: true entries" test below,
  # which is what keeps that true going forward.
  @inventory [
    # ── Safe: config-gated off in test env ──
    %{
      path: "lib/platform/notifications.ex",
      primitive: :task_start,
      justification:
        "fan_out_to_humans/3 + fan_out_to_user/3: reaches Repo transitively via " <>
          "Platform.Push.send_notification/2 / send_to_user/2, but both are wrapped in " <>
          "`Application.get_env(:platform, :env) != :test` (fan_out_to_humans also requires " <>
          "recipients != []) — the spawn branch never fires in test env."
    },
    %{
      path: "lib/platform/chat/attention_router.ex",
      primitive: :task_start,
      justification:
        "maybe_send_push/4: identical `Application.get_env(:platform, :env) != :test` gate, " <>
          "reaches Repo via Push. Same justification as notifications.ex."
    },
    %{
      path: "lib/platform_web/controllers/github_webhook_controller.ex",
      primitive: :task_start,
      justification:
        "spawn_auto_merge/5 (task 01a089e5 stage 3, was known_gap: true): wrapped in " <>
          "`Application.get_env(:platform, :env) != :test`, mirroring notifications.ex's " <>
          "gate. No webhook-controller test ever drove `AutoMerger.should_auto_merge?/2` to " <>
          "`:yes` with a resolvable `merge_target/2` — every test that reaches " <>
          "`decide_auto_merge/5` through this controller sets `\"auto_merge\" => false`; the " <>
          "tests that DO set `auto_merge: true` (deploy_stage_builder_test.exs, " <>
          "auto_merger_test.exs, stack_deployer_auto_merge_stamp_test.exs, etc.) call " <>
          "`AutoMerger`/`DeployStageBuilder`/`StackDeployer` directly, never through this " <>
          "controller — so gating rather than supervising was the correct fix; there was no " <>
          "sandbox race to rescue. Still written as Elixir.Task.start( because the module " <>
          "aliases Platform.Tasks.Task."
    },

    # ── Safe: spawned body never touches Repo ──
    %{
      path: "lib/platform/execution/docker_runner.ex",
      primitive: :task_start,
      justification:
        "maybe_start_monitor/2 -> monitor_until_terminal/5: the spawned body only calls " <>
          "client.describe_run/3 then send/2 to a run_server pid — no Repo call in the " <>
          "spawned process."
    },
    %{
      path: "lib/platform/agents/tool_runner.ex",
      primitive: :task_async,
      justification: "shell_exec branch: Task.async wrapping System.cmd/3 — no Repo touch."
    },

    # ── Safe: pinned exemptions, must not be supervised away ──
    %{
      path: "lib/platform/federation/peers/peer_connection.ex",
      primitive: :spawn_link,
      justification:
        "start_sender/2: manually does Process.put(:\"$callers\", callers) before running — " <>
          "the spawned body (attempt/2) does HTTP send via Client.send_envelope/3, not Repo. " <>
          "Pinned anyway so a future Repo call added to attempt/2 trips this inventory's " <>
          "offender check instead of silently riding this exemption."
    },
    %{
      path: "lib/platform/orchestration/task_router.ex",
      primitive: :spawn_monitor,
      justification:
        "maybe_run_design_edge/2: DO NOT WIDEN @task_supervisor_site_regex to catch this. " <>
          "The {pid, ref} feeds the router's own %State{design_run: {pid, ref}} and is " <>
          "consumed by the router's state machine to enforce at-most-one-designer-edge; " <>
          "supervising it away breaks that invariant. run_design_edge/2 likely DOES touch " <>
          "Repo through the lifecycle executor — that's fine, this exemption is about " <>
          "'must not be supervised away', not 'provably never touches Repo'."
    },

    # ── Safe: $callers propagation empirically verified under async: true
    #    (task 01a089e5 stage 4). Stage 1 only established these three
    #    reach Repo; it did not run anything under the manual-mode sandbox.
    #    Task.async_stream is built on Elixir's own Task machinery, which
    #    seeds the spawned process's $callers from the caller's — a
    #    different risk class from bare Task.start/spawn (which do not).
    #    Each entry below names the test(s) that actually exercise the
    #    Repo-touching closure under `async: true` and passed with zero
    #    DBConnection.OwnershipError / process-exit failures. None of
    #    these were converted to Task.Supervisor.async_stream_nolink —
    #    doing so would have been needless, since the code was already
    #    safe. ──
    %{
      path: "lib/platform/mail.ex",
      primitive: :task_async_stream,
      justification:
        "refresh_inbound/2: Task.async_stream over Platform.Mail.Inbound.poll_now/2, heavy " <>
          "Repo use (fetch_secret, FolderCursor, InboundMessage inserts). Verified safe under " <>
          "async: true by test/platform/mail/refresh_inbound_sandbox_test.exs (both tests, " <>
          "added stage 4), which calls refresh_inbound/2 directly against a real Repo-backed " <>
          "account under the DataCase manual sandbox and asserts a clean {:ok, summary} for " <>
          "every account with zero OwnershipError. Verified under the actual code path any " <>
          "other async: true test would hit: :mail_enabled defaults false in config/test.exs, " <>
          "so poll_now/2 takes its in-process poll_safely/1 branch (Repo calls happen in the " <>
          "SAME process the Task.async_stream spawned) rather than hopping through the " <>
          "separately-supervised poller GenServer (sync_poller/1 is a no-op while disabled). " <>
          "That GenServer hop is a materially different, untested risk class (a $callers chain " <>
          "through a DynamicSupervisor-started process, not through Task's own machinery) but " <>
          "is out of scope here: no test anywhere flips :mail_enabled and calls " <>
          "refresh_inbound/2, and call_poller/2 already catches a downstream :exit into " <>
          "{:error, :poller_unavailable} rather than propagating it, so it cannot raise into " <>
          "the caller regardless."
    },
    %{
      path: "lib/platform/memory/maintenance_subagent.ex",
      primitive: :task_async_stream,
      justification:
        "run_batch/3: Task.async_stream over run_one/4 -> record_audit/4 and " <>
          "default_runner/3 -> Wiki.upsert_page/2, both Repo writes, all inside the spawned " <>
          "task's own process (no further process hop). Verified safe under async: true: " <>
          "test/platform/memory/maintenance_subagent_test.exs was flipped from async: false " <>
          "to async: true (stage 4) and its \"default runner (no :runner opt) — content " <>
          "rewrite via Wiki.upsert_page\" describe block (4 tests) exercises the REAL " <>
          "Repo-touching default_runner/3 path — not the fake :runner test double the other " <>
          "describes use — with 0 failures, no OwnershipError."
    },
    %{
      path: "lib/platform/org/wiki/search.ex",
      primitive: :task_async_stream,
      justification:
        "do_search/2: Task.async_stream over run_channel_guarded/5, multiple Repo.all/2 " <>
          "calls per channel, all inside the spawned task's own process. Verified safe under " <>
          "async: true: test/platform/org/wiki/search_test.exs (47 tests), " <>
          "search_org_scope_test.exs (7 tests) and search_lexical_query_test.exs (12 tests) " <>
          "were all flipped from async: false to async: true (stage 4) and pass in full " <>
          "(66 tests, 0 failures), exercising do_search/2's Repo.all/2 calls repeatedly and " <>
          "concurrently with the rest of the async suite, no OwnershipError. Belt-and-suspenders: " <>
          "run_channel_guarded/5 already wraps each channel body in `catch kind, reason ->`, " <>
          "which would convert even a raised OwnershipError into a dead-channel result rather " <>
          "than crashing the test — but the empirical run shows that catch clause never fires " <>
          "for sandbox reasons, because $callers propagation already works."
    }
  ]

  # ── Assertion 1: every discovered site is inventoried ──────────────

  describe "spawn primitive sites under lib/" do
    test "every discovered site appears in @inventory" do
      sites = scan_root(@lib_root)
      offenders = find_offenders(sites, @inventory)

      assert offenders == [], format_offenders(offenders)
    end

    test "every @inventory entry's site still exists (staleness)" do
      stale = find_stale(@inventory, @lib_root)

      assert stale == [], format_stale(stale)
    end

    test "every @inventory entry carries a non-empty one-line justification" do
      blank =
        Enum.filter(@inventory, fn entry ->
          justification = Map.get(entry, :justification, "")
          not is_binary(justification) or String.trim(justification) == ""
        end)

      assert blank == [], """
      The following @inventory entries have no justification text:

      #{Enum.map_join(blank, "\n", &"  - #{&1.path} (#{&1.primitive})")}
      """
    end

    # Closes the loop task 01a089e5 exists to close. This is DISTINCT from
    # the "every discovered site appears in @inventory" test above: that
    # one catches a genuinely NEW future spawn site (never inventoried at
    # all). This one guards against a DIFFERENT failure mode — a site that
    # IS inventoried, honestly flagged `known_gap: true` by some earlier
    # stage, and then just... never followed up on. Stage 1 seeded three
    # such entries; stage 3 remediated six `known_gap: true` Task.start
    # sites from a separate part of the census; stage 4 resolved the last
    # three (the Task.async_stream sites) by either converting the code or
    # proving it already safe under async: true and citing the test(s)
    # that prove it. Once true, this assertion is what makes it STAY true —
    # a future stage that seeds a new known_gap: true entry without ever
    # resolving it fails this test, not silently rides along forever.
    test "zero remaining known_gap: true entries across the whole inventory" do
      remaining_gaps = Enum.filter(@inventory, &Map.get(&1, :known_gap, false))

      assert remaining_gaps == [], """
      The following @inventory entries are still flagged known_gap: true.
      task 01a089e5 exists to drive this list to zero — either remediate the
      site (Task.Supervisor.async_*_nolink / rescue DBConnection.OwnershipError,
      matching stage 3's pattern) or empirically prove it already safe under
      async: true and clear the flag with a justification naming the test(s)
      that prove it:

      #{Enum.map_join(remaining_gaps, "\n", &"  - #{&1.path} (#{&1.primitive})")}
      """
    end
  end

  # ── Assertion 2: anti-vacuity — the scanner actually detects an
  #    uninventoried site, on a synthetic fixture, never under real lib/ ──

  describe "anti-vacuity: scanner behavior on a synthetic fixture" do
    test "fails on an uninventoried bare spawn+Repo site, passes once inventoried" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "spawn_primitive_fixture_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      # This bad snippet is synthetic and lives ONLY in this temp fixture —
      # never committed under real lib/.
      File.write!(Path.join(tmp_dir, "bad_spawn.ex"), """
      defmodule Fixture.BadSpawn do
        def go do
          spawn(fn -> Repo.one(SomeSchema) end)
        end
      end
      """)

      sites = scan_root(tmp_dir, prefix: "")
      assert sites == [%{path: "bad_spawn.ex", primitive: :spawn, lines: [3]}]

      # Direction 1: empty inventory -> the scan FAILS on it.
      offenders_uninventoried = find_offenders(sites, [])

      assert offenders_uninventoried != [],
             "expected the synthetic site to be flagged as an offender"

      assert [%{path: "bad_spawn.ex", primitive: :spawn}] = offenders_uninventoried

      # Direction 2: add a fixture-scoped inventory entry -> the same scan PASSES.
      fixture_inventory = [
        %{
          path: "bad_spawn.ex",
          primitive: :spawn,
          justification:
            "fixture-only synthetic site for the anti-vacuity test — never real code.",
          known_gap: true
        }
      ]

      offenders_inventoried = find_offenders(sites, fixture_inventory)
      assert offenders_inventoried == []

      # And the staleness check on that same fixture inventory holds true
      # against the fixture tree.
      assert find_stale(fixture_inventory, tmp_dir, prefix: "") == []
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  # Walks `root/**/*.ex` and returns one %{path:, primitive:, lines:} map
  # per {relative path, primitive} pair that has at least one match.
  # `opts[:prefix]` (default "lib") is prepended to the path relative to
  # `root` — the real scan passes root = apps/platform/lib and wants paths
  # to read "lib/platform/...", matching @known_safe's own convention in
  # the sibling audit file. The fixture test passes prefix: "" because its
  # root already IS the thing being scanned.
  defp scan_root(root, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "lib")

    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn absolute_path ->
      source = File.read!(absolute_path)
      relative = Path.relative_to(absolute_path, root)
      path = if prefix in [nil, ""], do: relative, else: prefix <> "/" <> relative

      lines_with_idx = source |> String.split("\n") |> Enum.with_index(1)

      Enum.flat_map(@primitive_specs, fn {primitive, regex} ->
        matched_lines =
          lines_with_idx
          |> Enum.filter(fn {line, _idx} -> Regex.match?(regex, line) end)
          |> Enum.map(fn {_line, idx} -> idx end)

        case matched_lines do
          [] -> []
          _ -> [%{path: path, primitive: primitive, lines: matched_lines}]
        end
      end)
    end)
    |> Enum.sort_by(&{&1.path, &1.primitive})
  end

  # Sites the scan found that have no matching {path, primitive} entry in
  # `inventory`.
  defp find_offenders(sites, inventory) do
    known = MapSet.new(inventory, &{&1.path, &1.primitive})

    Enum.reject(sites, fn site -> MapSet.member?(known, {site.path, site.primitive}) end)
  end

  # Inventory entries whose {path, primitive} no longer has any matching
  # site in the current tree at `root`.
  defp find_stale(inventory, root, opts \\ []) do
    found = scan_root(root, opts) |> MapSet.new(&{&1.path, &1.primitive})

    Enum.reject(inventory, fn entry -> MapSet.member?(found, {entry.path, entry.primitive}) end)
  end

  defp format_offenders(offenders) do
    body =
      Enum.map_join(offenders, "\n\n", fn %{path: path, primitive: primitive, lines: lines} ->
        line_list = Enum.map_join(lines, ", ", &Integer.to_string/1)
        "  #{path} — line(s) #{line_list} (#{primitive})"
      end)

    """
    The following spawn-primitive call site(s) are not in @inventory in
    spawn_primitive_inventory_audit_test.exs. supervised_task_repo_audit_test.exs
    only sees Task.Supervisor.(async_nolink|start_child) — Task.start, bare
    spawn, spawn_link, spawn_monitor, Task.async and Task.async_stream are
    invisible to it (task 01a089e5). Every call to one of those six primitives
    under lib/ must be added to @inventory with a one-line justification —
    either the spawn branch is unreachable in test env / never touches Repo
    (safe), or it is a genuine gap (known_gap: true) for a later stage to
    remediate. Do NOT widen @task_supervisor_site_regex in the sibling file to
    cover these — see this file's moduledoc for why that would still miss the
    sites that most need catching.

    Offending sites:

    #{body}
    """
  end

  defp format_stale(stale) do
    body =
      Enum.map_join(stale, "\n", fn entry -> "  - #{entry.path} (#{entry.primitive})" end)

    """
    @inventory in spawn_primitive_inventory_audit_test.exs lists entries whose
    call site no longer exists in the current tree — clean these up so the
    audit doesn't silently drift:

    #{body}
    """
  end
end
