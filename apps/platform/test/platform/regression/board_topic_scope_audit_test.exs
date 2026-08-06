defmodule Platform.Regression.BoardTopicScopeAuditTest do
  @moduledoc """
  Source-scan guard: no `async: true` test module may subscribe to the GLOBAL
  kanban board topic via the zero-arity `Tasks.subscribe_board()`.

  ## What this defends

  `Platform.Tasks.broadcast_board/1` publishes every board event to one global
  topic, and `subscribe_board/0` subscribes to all of it. Two async modules that
  both do this share a firehose: each receives the other's `{:plan_updated, _}`
  and `{:epic_created, _}` frames, and an `assert_receive` matching loosely on
  the tuple shape happily consumes a foreign module's message. Task 019fca9e
  measured that: `plan_test.exs` failed 8 times in 20 seeded runs of
  `test/platform/tasks/` before the fix and 0 times after, at comparable box
  load. Stage 2 added scope-narrowed topics (`subscribe_board(task: id)` and
  friends); stage 3 moved the two measured-racing modules onto them.

  Nothing in the compiler stops the next author from typing `subscribe_board()`
  in a new async module and re-opening the hole. The failure it re-opens is
  intermittent and seed-dependent, so CI would not reliably catch it — the
  suite would just start being untrustworthy again. This scan is what keeps
  that from happening quietly.

  ## Keyed on `async:`, not on a roster of call sites

  The exempt set is "every SYNCHRONOUS module", determined from the module's own
  `use ... async: <bool>` line, rather than a list of individually-blessed files.
  A sync module runs alone, so no concurrent module can put a foreign board
  event in its mailbox: it is out of scope BY CONSTRUCTION, not by exception.
  That is why `@allowed_files` below is one entry long and not fourteen — the
  remaining `subscribe_board/0` call sites in the tree are all sync, and stage 4
  documented each of them in place with a `BOARD-SCOPE-EXEMPT:` comment.

  Note the subtlety stage 4 turned up: a bare `use Platform.DataCase` is
  SYNCHRONOUS, because `data_case.ex` passes `shared: not tags[:async]`. The
  scan therefore requires an explicit `async: true` to consider a file at all,
  which is the conservative direction — a module with no `async:` at all is
  treated as sync, matching ExUnit.

  ## Scan and subtract, never a whitelist

  The offender set is *every* matching file minus `@allowed_files`. It is
  deliberately NOT a comparison against a remembered list of known call sites.

  That form was tried and failed in a sibling guard's own task (see
  `attention_broadcast_funnel_audit_test.exs`, which documents the incident): an
  assertion of the shape "the matches are exactly these N files" is satisfied by
  any site the author forgot, because a forgotten site was never in the expected
  list to begin with. It would go green over precisely the hole it exists to
  catch. Subtracting an allowed set has no such blind spot.

  ## Non-vacuity

  The offender set here is currently EMPTY by construction, which means the
  first assertion below proves nothing on its own — a regex that matched no file
  at all would satisfy it forever. The anchor is doing all the work: the scan is
  asserted to MATCH something real, namely at least one `async: true` file
  containing a SCOPED `subscribe_board(task: ...)` call. Those exist because
  stage 3 created them. A bug in the walk, in the `async:` detection or in the
  comment/heredoc stripping presents as a loud failure rather than a permanently
  green test.

  Cheap by construction — `Path.wildcard` + `File.read!` + regex, no DB, no
  PubSub — so it runs in the default `mix test` set alongside its peers in
  `test/platform/regression/`.
  """

  use ExUnit.Case, async: true

  @test_root Path.expand("../..", __DIR__)

  # This file is excluded from its own walk. The regex literals below are code,
  # not comments, so `strip_prose/1` cannot blank them — without this the guard
  # reports itself as an offender, and worse, the non-vacuity anchor would be
  # satisfied by its own scoped-call literal instead of by a real test module.
  @self_file "platform/regression/board_topic_scope_audit_test.exs"

  # `board_topic_scope_test.exs` is the unit test OF the fan-out itself: it must
  # be able to subscribe globally to observe that the global copy still goes
  # out. It cannot be raced, because every id it broadcasts is freshly
  # generated in the test body, so no foreign event can match its patterns.
  @allowed_files ["platform/tasks/board_topic_scope_test.exs"]

  # An explicit `async: true` on a `use` line. Anything else — `async: false`,
  # or no `async:` key at all — is synchronous and out of scope.
  @async_regex ~r/^\s*use\s+[\w.]+\s*,[^\n]*async:\s*true/m

  # `\b` before `subscribe_board` is what keeps `unsubscribe_board()` out: there
  # is no word boundary between the `n` and the `s`. A leading `Tasks.` or
  # `Platform.Tasks.` does supply one, so qualified calls still match.
  @global_call_regex ~r/\bsubscribe_board\(\s*\)/
  @scoped_call_regex ~r/\bsubscribe_board\(\s*\w+:/
  @any_call_regex ~r/\bsubscribe_board\(/

  describe "global board subscriptions in async tests" do
    test "no async: true test module calls the zero-arity Tasks.subscribe_board()" do
      offenders =
        @global_call_regex
        |> scan()
        |> Enum.reject(fn {relative_path, _lines} -> relative_path in @allowed_files end)

      assert offenders == [], format_offenders(offenders)
    end

    test "the scan actually sees scoped subscriptions in async files (non-vacuity anchor)" do
      matched = Enum.map(scan(@scoped_call_regex), fn {path, _lines} -> path end)

      assert matched != [], """
      The source scan found NO scoped `subscribe_board(task: ...)` call in ANY
      `async: true` test file. Stage 3 of task 019fca9e created several, so this
      means the scanner is blind, not that the tree changed.

      While it is blind, the offender assertion above is passing VACUOUSLY and
      would keep passing if every async module in the tree went back to the
      global firehose. Fix the scanner — most likely @async_regex, one of the
      call regexes, or the comment/heredoc stripping in strip_prose/1 — before
      trusting anything else in this file.

      async: true files the scan saw at all: #{inspect(async_files())}
      """
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Returns `[{relative_path, line_numbers}]` for every `async: true` file under
  # `apps/platform/test` matching `regex`, sorted.
  defp scan(regex) do
    Enum.reduce(async_paths(), [], fn absolute_path, acc ->
      stripped = absolute_path |> File.read!() |> strip_prose()

      lines =
        regex
        |> Regex.scan(stripped, return: :index, capture: :first)
        |> Enum.map(fn [{offset, _len}] -> line_number(stripped, offset) end)

      case lines do
        [] -> acc
        _ -> [{Path.relative_to(absolute_path, @test_root), lines} | acc]
      end
    end)
    |> Enum.sort()
  end

  defp async_paths do
    Path.wildcard(Path.join(@test_root, "**/*.exs"))
    |> Enum.reject(&(Path.relative_to(&1, @test_root) == @self_file))
    |> Enum.filter(fn path ->
      path |> File.read!() |> strip_prose() |> then(&Regex.match?(@async_regex, &1))
    end)
  end

  # Only used to make the anchor's failure message actionable.
  defp async_files do
    async_paths()
    |> Enum.filter(&Regex.match?(@any_call_regex, strip_prose(File.read!(&1))))
    |> Enum.map(&Path.relative_to(&1, @test_root))
    |> Enum.sort()
  end

  # Blanks out `#` comments and `"""` heredoc bodies, preserving line COUNT so
  # failure messages can cite real line numbers.
  #
  # Necessary because this very file, and the `BOARD-SCOPE-EXEMPT:` comments
  # stage 4 left on the sync call sites, all quote the construct being
  # forbidden. Without stripping, documenting the rule would break the rule's
  # own test — a guard nobody can explain in prose is a guard that gets deleted.
  defp strip_prose(source) do
    source
    |> String.split("\n")
    |> Enum.map_reduce(false, fn line, in_heredoc? ->
      delimiters = length(String.split(line, ~s("""))) - 1
      next? = if rem(delimiters, 2) == 1, do: not in_heredoc?, else: in_heredoc?

      cond do
        in_heredoc? or delimiters > 0 -> {"", next?}
        String.starts_with?(String.trim_leading(line), "#") -> {"", next?}
        true -> {line, next?}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  # Byte offset -> 1-based line number. `:binary.matches/2` rather than a String
  # function because a regex offset is a BYTE offset and can land mid-codepoint.
  defp line_number(source, offset) do
    length(:binary.matches(binary_part(source, 0, offset), "\n")) + 1
  end

  defp format_offenders(offenders) do
    body =
      Enum.map_join(offenders, "\n", fn {path, lines} ->
        "  test/#{path} — line(s) #{Enum.map_join(lines, ", ", &Integer.to_string/1)}"
      end)

    """
    The following `async: true` test module(s) subscribe to the GLOBAL kanban
    board topic:

    #{body}

    Use a scope-narrowed subscription instead — the id is almost always already
    in hand:

        Tasks.subscribe_board(task: task.id)
        Tasks.subscribe_board(project: project.id)
        Tasks.subscribe_board(plan: plan.id)
        Tasks.subscribe_board(stack: stack.id)

    Why this is not a style rule: `broadcast_board/1` publishes EVERY board
    event to the global topic, so an async module subscribed there receives the
    plan and task events of every other async module running at the same moment.
    An `assert_receive {:plan_updated, %Plan{status: "approved"}}` then matches
    a stranger's message and the test fails on an id comparison it had no way to
    influence. Task 019fca9e measured this at 8 red runs in 20 seeds.

    If your module genuinely cannot scope — because it asserts that NO event
    fires for ANY entity, so there is no id to subscribe to — make the module
    `async: false` and leave a `BOARD-SCOPE-EXEMPT:` comment saying why. A sync
    module cannot be raced by a concurrent one.
    """
  end
end
