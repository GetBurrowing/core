defmodule Platform.Regression.TaskAliasShadowingAuditTest do
  @moduledoc """
  Source-scan guard against re-opening the 2026-07-25 `Platform.Tasks.Task`
  alias-shadowing bug (task 019f9b13-a89d, surfaced by that day's
  architecture audit).

  THE BUG BEING PINNED: `lib/platform/tasks/stacks.ex:2288` read

      Task.Supervisor.async_nolink(stack_deployer_task_supervisor(), fn -> ...)

  but that module carries `alias Platform.Tasks.{..., Task}` (stacks.ex:22),
  so the bare `Task` resolves to the Ecto SCHEMA, not `Elixir.Task`. The
  call therefore named `Platform.Tasks.Task.Supervisor.async_nolink/2`,
  which does not exist. Module resolution for a remote call happens in the
  CALLING process, so the `UndefinedFunctionError` landed inside
  `Stacks.dispatch_stack_deploy/1` itself — in production that blew up
  `PlanEngine` mid-transition rather than crashing a detached child.
  `mix compile` emitted the warning the whole time; nothing turned it into
  an error, and `config/test.exs` pinned `:stack_deployer, :async` to
  `false`, so no test ever executed the line.

  30 modules alias `Platform.Tasks.Task` unqualified. Mass-renaming all of
  them to `as: TaskRecord` is ~110 sites of churn in `stacks.ex` alone with
  zero behavioural change. This audit is the cheaper, permanent
  alternative: it fails the NEXT offender at the moment it is written.

  A flagged line has exactly two correct fixes:

    (a) Qualify the OTP call as `Elixir.Task.` — the precedent already set
        at `lib/platform_web/controllers/github_webhook_controller.ex:214`
        and now at `lib/platform/tasks/stacks.ex:2304`. Preferred when the
        module's `Task` references are overwhelmingly the schema, which is
        the normal case inside `Platform.Tasks.*`.

    (b) Alias the schema out of the way — `alias Platform.Tasks.Task, as:
        TaskRecord` (or `TaskSchema`) — the shape used by
        `stack_deployer.ex:116`, `chat/attention_router.ex:63`,
        `chat/agent_responder.ex:27`, `org/wiki/search.ex:70`,
        `responsibilities/timeline_appender.ex:43` and friends. Preferred
        when the module leans on OTP `Task` more than on the schema.

  Adding an exclusion is NOT a third option. If this audit fires on a
  schema call — `Task.changeset/2`, `Task.deletable?/1`, `Task.phases/0`,
  a `Task.t()` spec — the fix is to narrow `@otp_surface` below, not to
  exempt the file.

  Cheap by construction (pure `File.read!` + `Regex`, no DB, no PubSub) and
  deliberately carries no `@moduletag`, so it runs in the default
  `mix test` set. Peer of `supervised_task_repo_audit_test.exs` in this
  directory, whose `Task.Supervisor` site regex was widened in the same
  commit — it had a hole shaped exactly like this bug.
  """

  use ExUnit.Case, async: true

  @app_root Path.expand("../../..", __DIR__)
  @lib_root Path.expand("../../../lib", __DIR__)

  # Functions and submodules that live on `Elixir.Task`. A bare `Task.<one
  # of these>` inside a shadowing module is always wrong, because
  # `Platform.Tasks.Task` (a plain Ecto schema) defines none of them.
  #
  # Keep this list TIGHT. It is an allowlist of OTP surface, not a
  # denylist of schema surface: everything the schema legitimately exposes
  # (`changeset/2`, `deletable?/1`, `phases/0`, the `t()` type, struct
  # literals) must stay off it. Widen only by adding a name that genuinely
  # exists on `Elixir.Task`.
  @otp_surface [
    "Supervisor",
    "async_nolink",
    "async_stream",
    "async",
    "await_many",
    "await",
    "start_link",
    "start",
    "yield_many",
    "yield",
    "shutdown",
    "completed",
    "ignore"
  ]

  # Longest-alternative-first so `Task.async_nolink` cannot be consumed as
  # `Task.async` + a stray suffix. The `(?<![\w.])` lookbehind is what
  # excludes the correct forms: `Elixir.Task.Supervisor`,
  # `TaskRecord.start`, `SomeMod.Task.await`.
  @shadowed_call_regex ~r/(?<![\w.])Task\.(?:#{Enum.join(@otp_surface, "|")})\b/

  # `alias Platform.Tasks.Task` with no `, as:` suffix. The `(?![\w.])`
  # keeps `Platform.Tasks.TaskReference` out.
  @bare_alias_regex ~r/^\s*alias\s+Platform\.Tasks\.Task(?![\w.])\s*(?:#.*)?$/m

  # `alias Platform.Tasks.{...}` — `[^}]` matches newlines, so a
  # brace list wrapped across lines by the formatter is still captured.
  @multi_alias_regex ~r/alias\s+Platform\.Tasks\.\{([^}]*)\}/

  describe "Platform.Tasks.Task alias shadowing" do
    test "no module that aliases the schema unqualified calls a bare Task.<OTP function>" do
      offenders =
        @lib_root
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.reduce([], fn absolute_path, acc ->
          source = File.read!(absolute_path)

          if shadows_task_alias?(source) do
            case shadowed_call_lines(source) do
              [] -> acc
              lines -> [{Path.relative_to(absolute_path, @app_root), lines} | acc]
            end
          else
            acc
          end
        end)
        |> Enum.sort()

      assert offenders == [], format_offenders(offenders)
    end

    test "the audit recognises both shadowing alias forms and ignores the safe ones" do
      # Pins the detector itself. Without this, a regex typo would make
      # the audit above silently scan nothing and pass forever — the
      # precise failure mode that let stacks.ex:2288 hide from
      # supervised_task_repo_audit_test.exs.
      assert shadows_task_alias?("  alias Platform.Tasks.Task\n")
      assert shadows_task_alias?("  alias Platform.Tasks.{Plan, Stack, Task}\n")

      assert shadows_task_alias?(
               "  alias Platform.Tasks.{\n    Plan,\n    Task,\n    Stage\n  }\n"
             )

      assert shadows_task_alias?("  alias Platform.Tasks.Task # the schema\n")

      refute shadows_task_alias?("  alias Platform.Tasks.Task, as: TaskRecord\n")
      refute shadows_task_alias?("  alias Platform.Tasks.Task, as: TaskSchema\n")
      refute shadows_task_alias?("  alias Platform.Tasks.TaskReference\n")
      refute shadows_task_alias?("  alias Platform.Tasks.{Plan, TaskReference}\n")
      refute shadows_task_alias?("  alias Platform.Tasks.Stacks\n")
    end

    test "the audit flags OTP calls, skips schema calls, comments and doc prose" do
      # The offender side of the detector, pinned with the exact
      # false-positive shapes the 2026-07-25 sweep enumerated.
      source = """
      defmodule Decoy do
        @moduledoc \"\"\"
        Prose mentioning Task.start and Task.Supervisor must not count.
        \"\"\"

        alias Platform.Tasks.Task

        # Task.await in a comment must not count either.

        @spec fetch(String.t()) :: Task.t()
        def fetch(id) do
          Task.changeset(%Task{}, %{id: id})
          Task.deletable?(%Task{})
          Task.phases()
          Elixir.Task.start(fn -> :ok end)
          Task.start(fn -> :ok end)
        end
      end
      """

      assert shadows_task_alias?(source)
      # Only the bare `Task.start/1` on line 16 counts.
      assert shadowed_call_lines(source) == [16]
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────

  # True when the module pulls `Platform.Tasks.Task` into scope under the
  # bare name `Task`, either as a standalone alias or as an element of a
  # multi-alias brace list. Elements are compared after a trim so
  # `TaskReference` / `TaskRecord` cannot match on a substring.
  defp shadows_task_alias?(source) do
    Regex.match?(@bare_alias_regex, source) or multi_alias_shadows?(source)
  end

  defp multi_alias_shadows?(source) do
    @multi_alias_regex
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
    |> Enum.any?(fn brace_list ->
      brace_list
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.member?("Task")
    end)
  end

  # Line numbers (1-based) of every bare `Task.<OTP surface>` call,
  # excluding whole-line comments and `@doc` / `@moduledoc` heredoc prose.
  # Both exclusions are load-bearing: the peer audit's `@known_safe`
  # rationales and several modules' docstrings discuss `Task.Supervisor`
  # by name.
  defp shadowed_call_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], false}, fn {line, idx}, {hits, in_doc?} ->
      cond do
        in_doc? ->
          {hits, not doc_heredoc_close?(line)}

        doc_heredoc_open?(line) ->
          {hits, true}

        comment_line?(line) ->
          {hits, false}

        Regex.match?(@shadowed_call_regex, line) ->
          {[idx | hits], false}

        true ->
          {hits, false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp comment_line?(line), do: Regex.match?(~r/^\s*#/, line)

  defp doc_heredoc_open?(line),
    do: Regex.match?(~r/^\s*@(?:module)?doc\s+~?S?"""\s*$/, line)

  defp doc_heredoc_close?(line), do: Regex.match?(~r/^\s*"""\s*$/, line)

  defp format_offenders(offenders) do
    body =
      Enum.map_join(offenders, "\n\n", fn {path, lines} ->
        "  #{path} — line(s) #{Enum.map_join(lines, ", ", &Integer.to_string/1)}"
      end)

    """
    The following module(s) alias `Platform.Tasks.Task` unqualified AND
    call a bare `Task.<OTP function>`. Inside those modules `Task` is the
    Ecto SCHEMA, so the call resolves to `Platform.Tasks.Task.<...>`,
    which does not exist. `mix compile` warns; nothing fails; the
    UndefinedFunctionError raises in the CALLING process at runtime.
    That is task 019f9b13-a89d — `stacks.ex:2288` took down
    `PlanEngine.dispatch_stack_deploy` in production.

    Fix ONE of:

      (a) Qualify the OTP call: `Elixir.Task.Supervisor.async_nolink(...)`,
          `Elixir.Task.start(...)`. See
          lib/platform/tasks/stacks.ex:2304 and
          lib/platform_web/controllers/github_webhook_controller.ex:214.
          Prefer this when the module's `Task` references are mostly the
          schema.

      (b) Alias the schema out of the way:
          `alias Platform.Tasks.Task, as: TaskRecord`. See
          lib/platform/tasks/stack_deployer.ex:116 and
          lib/platform/chat/attention_router.ex:63. Prefer this when the
          module leans on OTP `Task`.

    Do NOT add an exclusion list to this audit. If the flagged line is a
    legitimate SCHEMA call, the fix is to narrow @otp_surface in
    test/platform/regression/task_alias_shadowing_audit_test.exs.

    Offending sites:

    #{body}
    """
  end
end
