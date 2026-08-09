defmodule Platform.Tasks.StatusWriterGuardTest do
  @moduledoc """
  Scan-and-subtract guard over every code path that can write
  `tasks.status`.

  ## Why a scan rather than a whitelist

  Task phase timestamps are recorded by a single `prepare_changes/2` hook
  attached to `Platform.Tasks.Task.changeset/2` (see
  `Platform.Tasks.PhaseTransitions`). That choke point is only a choke
  point for as long as it stays the *only* way a task's status reaches the
  database. A new `:status`-casting changeset, or a bulk
  `update_all`/`insert_all` against `tasks`, would write a status change
  that never produces a `task_phase_transitions` row — and the damage
  shows up as *missing data*, silently, months later, rather than as an
  error at the time of the change.

  A hand-maintained whitelist of "approved writers" grows quietly: the
  person adding writer number six adds a line to the list and moves on.
  So this guard does the inverse. It enumerates status-write sites from
  SOURCE TEXT and subtracts the single known-instrumented path. Anything
  left over reds the build, loudly, with the offender named.

  ## The three checks

    * **A** — `Platform.Tasks.Task.changeset/2` is the only changeset in
      `task.ex` that casts `:status`.
    * **B** — that changeset still carries the `prepare_changes` hook, and
      `record_status_transition/1` still exists.
    * **C** — no bulk (`update_all`/`insert_all`) or raw-SQL status write
      targets the `tasks` table anywhere under `apps/platform/lib`.

  ## Non-vacuity

  A scan that matches nothing passes for free, so every check is anchored:

    * A asserts the collected sets are non-empty before asserting their
      contents, so a chunker that silently matched zero functions reds.
    * C runs the *same* matcher functions over in-memory fixture strings
      containing known-bad lines and asserts they DO match.
    * B matches the CALL in CODE, not the word anywhere in the chunk.
      Comment lines are stripped first — mutation-testing this guard found
      that deleting the hook still left an explanatory comment containing
      the word `prepare_changes`, which satisfied a naive substring test
      and made check B vacuous.
    * Every filesystem scan excludes THIS FILE by absolute path, and a
      dedicated test proves that exclusion is load-bearing — the fixtures
      below would otherwise satisfy the anchors from inside the guard
      itself, and a guard that scans itself passes for the wrong reason.
  """

  use ExUnit.Case, async: true

  @app_root Path.expand("../../..", __DIR__)
  @lib_root Path.join(@app_root, "lib")
  @task_ex Path.join(@app_root, "lib/platform/tasks/task.ex")
  @self_path Path.expand(__ENV__.file)

  # A `tasks`-table reference in Elixir source is either the schema alias
  # `Task` or the literal table name. Deliberately case-sensitive and
  # word-bounded: `task_id`, `Tasks.` (the context module) and
  # `owner_attribution_status` are NOT status writes against the tasks
  # table, and matching them would make this guard cry wolf until someone
  # loosened it.
  @tasks_reference ~r/(\bTask\b|"tasks")/
  @bulk_call ~r/\b(update_all|insert_all)\s*\(/
  @status_key ~r/\bstatus:/
  @raw_sql_task_update ~r/update\s+tasks\b/i
  @window 5

  # ── Fixtures. These strings are the only thing the anchors may match. ──

  @bad_bulk_fixture """
  defmodule Fixture do
    def sweep do
      from(t in Task, where: t.status == "in_review")
      |> Repo.update_all(set: [status: "done"])
    end
  end
  """

  @bad_raw_sql_fixture """
  defmodule Fixture do
    def sweep do
      Repo.query!("UPDATE tasks SET status = 'done' WHERE id = $1", [id])
    end
  end
  """

  @clean_fixture """
  defmodule Fixture do
    def sweep do
      from(p in MemoryProposal, where: p.status == "pending")
      |> Repo.update_all(set: [status: "expired"])
    end
  end
  """

  @bad_changeset_fixture """
  defmodule Fixture do
    def changeset(task, attrs) do
      cast(task, attrs, [:title, :status])
    end

    def status_only_changeset(task, attrs) do
      cast(task, attrs, [:status])
    end

    def title_changeset(task, attrs) do
      cast(task, attrs, [:title])
    end
  end
  """

  describe "check A — sole :status-casting Task changeset" do
    test "Task.changeset/2 is the only changeset in task.ex that casts :status" do
      source = File.read!(@task_ex)

      all_changesets = changeset_names(source)
      casting = status_casting_changesets(source)

      # Non-vacuity anchor: if the chunker matched nothing, everything
      # below would pass for free.
      refute all_changesets == [],
             "the def-chunker found zero changeset functions in #{@task_ex}; " <>
               "the chunking regex has drifted and this guard is proving nothing"

      refute casting == [],
             "the matcher found zero :status-casting changesets in #{@task_ex}; " <>
               "Task.changeset/2 casts :status, so a zero result means the " <>
               "cast-extraction has drifted and this guard is proving nothing"

      extra = casting -- ["changeset"]

      assert extra == [],
             "a new Task changeset casts :status: #{Enum.join(extra, ", ")}. " <>
               "Either attach prepare_changes(&record_status_transition/1) to it " <>
               "or route its callers through Task.changeset/2, otherwise its writes " <>
               "will be missing from task_phase_transitions with no error."

      assert casting == ["changeset"]
    end

    test "anchor: the same matcher flags a status-casting changeset in a fixture" do
      assert status_casting_changesets(@bad_changeset_fixture) == [
               "changeset",
               "status_only_changeset"
             ]
    end
  end

  describe "check B — changeset/2 still carries the recording hook" do
    test "the changeset/2 chunk calls prepare_changes and the hook is defined" do
      source = File.read!(@task_ex)
      chunk = def_chunk(source, "changeset")

      assert chunk != nil, "could not locate `def changeset(` in #{@task_ex}"

      # Comment lines are stripped first. This is load-bearing: the
      # explanatory comment that sits at the end of the changeset pipeline
      # itself contains the word `prepare_changes`, so a naive substring
      # test passes even after the actual hook call is deleted. That
      # vacuity was found by mutation-testing this guard, not by reading
      # it. Match the CALL, in CODE.
      assert code_only(chunk) =~ ~r/prepare_changes\(/,
             "Task.changeset/2 no longer calls prepare_changes/2. The status-transition " <>
               "recording hook has been removed while the schema stayed intact, so every " <>
               "status write from now on will be missing from task_phase_transitions " <>
               "with no error. Restore |> prepare_changes(&record_status_transition/1)."

      assert source =~ ~r/defp?\s+record_status_transition\(/,
             "task.ex no longer defines record_status_transition/1 — the " <>
               "task_phase_transitions recorder is gone."
    end

    test "anchor: a comment mentioning prepare_changes does NOT satisfy check B" do
      hook_deleted_but_comment_remains = """
        def changeset(task, attrs) do
          task
          |> cast(attrs, [:status])
          # Last in the pipeline on purpose: prepare_changes/2 only runs
          # when the changeset is valid.
        end
      """

      refute code_only(hook_deleted_but_comment_remains) =~ ~r/prepare_changes\(/

      # ...and the real call, in code, still matches.
      assert code_only("  |> prepare_changes(&record_status_transition/1)") =~
               ~r/prepare_changes\(/
    end

    test "anchor: a commented-out bulk status write is not reported as an offender" do
      commented = """
      defmodule Fixture do
        def sweep do
          # from(t in Task, where: true) |> Repo.update_all(set: [status: "done"])
          :noop
        end
      end
      """

      assert bulk_status_writes(commented, "fixture/commented.ex") == []
    end
  end

  describe "check C — no bulk or raw status writes against tasks" do
    test "no update_all/insert_all sets status on the tasks table" do
      offenders =
        scanned_files()
        |> Enum.flat_map(fn path -> bulk_status_writes(File.read!(path), path) end)

      assert offenders == [],
             "bulk status write against the tasks table:\n" <>
               format_offenders(offenders) <>
               "\n`update_all`/`insert_all` bypass Task.changeset/2 entirely, so these " <>
               "status changes will be missing from task_phase_transitions with no error. " <>
               "Route them through Platform.Tasks.transition_task/3, or record the " <>
               "transition explicitly via Platform.Tasks.PhaseTransitions.record/2."
    end

    test "no raw SQL updates the tasks table" do
      offenders =
        scanned_files()
        |> Enum.flat_map(fn path -> raw_sql_task_writes(File.read!(path), path) end)

      assert offenders == [],
             "raw SQL update against the tasks table:\n" <>
               format_offenders(offenders) <>
               "\nRaw SQL bypasses every changeset, so a status change here is invisible " <>
               "to task_phase_transitions."
    end

    test "anchor: the same matchers flag known-bad fixture source" do
      bulk = bulk_status_writes(@bad_bulk_fixture, "fixture/bad_bulk.ex")
      assert length(bulk) == 1
      assert hd(bulk).snippet =~ "update_all"

      raw = raw_sql_task_writes(@bad_raw_sql_fixture, "fixture/bad_raw.ex")
      assert length(raw) == 1
      assert raw |> hd() |> Map.fetch!(:snippet) =~ "UPDATE tasks"
    end

    test "anchor: the matchers do NOT flag a bulk status write on another table" do
      assert bulk_status_writes(@clean_fixture, "fixture/clean.ex") == []
      assert raw_sql_task_writes(@clean_fixture, "fixture/clean.ex") == []
    end
  end

  describe "self-exclusion" do
    test "the scanned set never includes this guard file" do
      refute @self_path in scanned_files()

      refute Enum.any?(scanned_files(), &(Path.basename(&1) == "status_writer_guard_test.exs"))
    end

    test "self-exclusion is load-bearing: this file WOULD match its own matchers" do
      # If the scan ever widened to include test files, the fixtures above
      # would satisfy check C's anchors from inside the guard itself and
      # the guard would pass for the wrong reason. Prove the exclusion is
      # doing real work rather than being decorative.
      own_source = File.read!(@self_path)

      assert bulk_status_writes(own_source, @self_path) != []
      assert raw_sql_task_writes(own_source, @self_path) != []
    end

    test "the scan actually walks lib and finds files" do
      files = scanned_files()

      assert length(files) > 100,
             "expected the lib scan to find many .ex files, got #{length(files)}"

      assert @task_ex in files
    end
  end

  # ── Matchers. Private functions taking (source_text, path) so the
  # fixtures above exercise the identical code, not a parallel copy. ──

  defp scanned_files do
    Path.wildcard(Path.join(@lib_root, "**/*.ex"))
    |> Enum.map(&Path.expand/1)
    |> Enum.reject(&(&1 == @self_path))
    |> Enum.sort()
  end

  # Drops whole-line comments. Deliberately conservative: only lines whose
  # trimmed form STARTS with `#` are removed, so a `#` inside a string
  # literal is never mangled. Enough to stop prose about a call from
  # counting as the call.
  defp code_only(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&(&1 |> String.trim() |> String.starts_with?("#")))
    |> Enum.join("\n")
  end

  # Same comment rule, but BLANKS the comment lines rather than dropping
  # them, so reported line numbers still match the real file.
  defp blank_comments(source) do
    source
    |> String.split("\n")
    |> Enum.map(fn line ->
      if line |> String.trim() |> String.starts_with?("#"), do: "", else: line
    end)
  end

  defp bulk_status_writes(source, path) do
    lines = blank_comments(source)

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _no} -> Regex.match?(@bulk_call, line) end)
    |> Enum.filter(fn {_line, no} ->
      window = window_text(lines, no)
      Regex.match?(@status_key, window) and Regex.match?(@tasks_reference, window)
    end)
    |> Enum.map(fn {line, no} ->
      %{path: path, line: no, snippet: String.trim(line)}
    end)
  end

  defp raw_sql_task_writes(source, path) do
    source
    |> blank_comments()
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _no} -> Regex.match?(@raw_sql_task_update, line) end)
    |> Enum.map(fn {line, no} -> %{path: path, line: no, snippet: String.trim(line)} end)
  end

  defp window_text(lines, line_no) do
    first = max(line_no - @window, 1)
    last = line_no + @window

    lines
    |> Enum.slice((first - 1)..(last - 1)//1)
    |> Enum.join("\n")
  end

  # Splits source into `def`/`defp` chunks and returns the names of every
  # function whose name ends in "changeset".
  defp changeset_names(source) do
    source
    |> def_chunks()
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&String.ends_with?(&1, "changeset"))
    |> Enum.uniq()
  end

  # Names of every `*changeset` function whose body casts `:status` — via a
  # `cast(...)` argument list or a `put_change(:status, ...)` call.
  defp status_casting_changesets(source) do
    source
    |> def_chunks()
    |> Enum.filter(fn {name, body} ->
      String.ends_with?(name, "changeset") and casts_status?(body)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp casts_status?(body) do
    Regex.match?(~r/put_change\(\s*:status\b/, body) or
      body |> cast_arguments() |> Enum.any?(&Regex.match?(~r/:status\b/, &1))
  end

  # Extracts the balanced-paren argument text of every `cast(` call in a
  # chunk. A regex alone cannot do this: the cast list in
  # `Task.changeset/2` spans ~25 lines.
  defp cast_arguments(body) do
    body
    |> :binary.matches("cast(")
    |> Enum.map(fn {at, len} -> balanced_slice(body, at + len) end)
    |> Enum.reject(&is_nil/1)
  end

  defp balanced_slice(body, start) do
    do_balance(body, start, start, 1)
  end

  defp do_balance(body, start, pos, depth) do
    case :binary.part(body, pos, min(1, byte_size(body) - pos)) do
      "" ->
        nil

      "(" ->
        do_balance(body, start, pos + 1, depth + 1)

      ")" when depth == 1 ->
        :binary.part(body, start, pos - start)

      ")" ->
        do_balance(body, start, pos + 1, depth - 1)

      _ ->
        do_balance(body, start, pos + 1, depth)
    end
  end

  defp def_chunk(source, name) do
    source
    |> def_chunks()
    |> Enum.find_value(fn {n, body} -> if n == name, do: body end)
  end

  defp def_chunks(source) do
    lines = String.split(source, "\n")

    starts =
      lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, idx} ->
        case Regex.run(~r/^\s*defp?\s+([a-z_][a-zA-Z0-9_?!]*)\s*\(/, line) do
          [_, name] -> [{name, idx}]
          _ -> []
        end
      end)

    bounds = Enum.map(starts, &elem(&1, 1)) |> tl() |> Kernel.++([length(lines)])

    starts
    |> Enum.zip(bounds)
    |> Enum.map(fn {{name, from}, to} ->
      {name, lines |> Enum.slice(from..(to - 1)//1) |> Enum.join("\n")}
    end)
  end

  defp format_offenders(offenders) do
    Enum.map_join(offenders, "\n", fn o -> "  #{o.path}:#{o.line}  #{o.snippet}" end)
  end
end
