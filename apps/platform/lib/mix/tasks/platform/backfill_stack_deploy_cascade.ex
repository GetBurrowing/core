defmodule Mix.Tasks.Platform.BackfillStackDeployCascade do
  @moduledoc """
  Post-hoc recovery for stacks stranded by the PR #531 cascade bug.

  When the rollup PR for a Stack v2 rollup branch merges, the webhook
  handler is supposed to advance the stack + every member to `"done"`
  in one atomic pass. Before task `019f5bc4-3521`, the member half of
  that cascade never fired if no member carried a per-task `pr_merged`
  validation (the normal shape for stack members). Those stacks landed
  at `status: "done"` while members hung at `"in_review"` or
  `"deploying"` indefinitely.

  This Mix task walks the DB looking for that footprint and drives
  `Platform.Tasks.Stacks.cascade_members_to_done/2` against each
  stranded stack. It is idempotent — re-running against an already-
  cascaded stack is a no-op (the members are already `"done"`).

  ## Usage

      # Cascade every stranded stack in the DB
      bin/platform eval 'Mix.Tasks.Platform.BackfillStackDeployCascade.run([])'

      # Preview without mutating
      bin/platform eval \\
        'Mix.Tasks.Platform.BackfillStackDeployCascade.run(["--dry-run"])'

      # Target one stack (repeatable)
      bin/platform eval \\
        'Mix.Tasks.Platform.BackfillStackDeployCascade.run(["--stack-id", "<uuid>"])'

  ## Options

    * `--dry-run` — print the stranded-stack list + per-stack member
      counts, do NOT invoke the cascade, do NOT emit telemetry. Safe
      to run against production.

    * `--stack-id <uuid>` — restrict the run to a specific stack.
      Repeatable. When omitted, all stranded stacks are cascaded.

    * `--verbose` — extra per-member logging on each cascaded stack.

  ## Telemetry

  Each real (non-dry-run) cascade fires exactly one
  `[:platform, :stacks, :deploy, :cascade_completed]` event via the
  usual `Stacks.cascade_members_to_done/2` path, with metadata
  `trigger: :backfill` — so dashboards can distinguish webhook-driven
  cascades from operator-driven backfills.
  """

  use Mix.Task

  import Ecto.Query, warn: false

  alias Platform.Repo
  alias Platform.Tasks.{Stack, Stacks, Task}

  require Logger

  @shortdoc "Cascade stranded members of already-done stacks to done (post-PR #531 hang backfill)"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, stack_id: [:string, :keep], verbose: :boolean]
      )

    Mix.Task.run("app.start")
    do_run(opts)
  end

  @doc false
  # Public for testability — we exercise `do_run/1` directly rather
  # than `run/1` so the tests don't have to boot `app.start` (it's
  # already started by `Platform.DataCase`).
  def do_run(opts) when is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    verbose? = Keyword.get(opts, :verbose, false)
    stack_ids = resolve_stack_ids(opts)

    log("[BackfillStackDeployCascade] scanning: #{length(stack_ids)} stranded stack(s)")

    if stack_ids == [] do
      log("[BackfillStackDeployCascade] no stranded stacks found — nothing to do")

      log(
        "[BackfillStackDeployCascade] complete: 0 stacks cascaded, 0 members advanced, 0 skipped"
      )

      :ok
    else
      totals =
        Enum.reduce(stack_ids, %{stacks: 0, advanced: 0, skipped: 0}, fn stack_id, acc ->
          process_stack(stack_id, dry_run?, verbose?, acc)
        end)

      log(
        "[BackfillStackDeployCascade] complete: #{totals.stacks} stacks cascaded, " <>
          "#{totals.advanced} members advanced, #{totals.skipped} skipped"
      )

      :ok
    end
  end

  # ── Query ────────────────────────────────────────────────────────────────

  # A "stranded" stack is one where the stack itself has flipped to
  # `"done"` (the rollup PR merged) but at least one member is still
  # sitting at `"in_review"` or `"deploying"` — the exact shape the
  # PR #531 bug leaves behind. Restricting to `s.status == "done"` avoids
  # touching stacks whose rollup PR hasn't merged yet (the webhook still
  # owns those).
  defp resolve_stack_ids(opts) do
    case Keyword.get_values(opts, :stack_id) do
      [] ->
        Repo.all(
          from(s in Stack,
            join: t in Task,
            on: t.stack_id == s.id,
            where: s.status == "done" and t.status in ["in_review", "deploying"],
            distinct: s.id,
            select: s.id
          )
        )

      ids when is_list(ids) ->
        ids
    end
  end

  # ── Per-stack processing ────────────────────────────────────────────────

  defp process_stack(stack_id, true = _dry_run, _verbose, acc) do
    case Repo.get(Stack, stack_id) do
      nil ->
        log("  #{short(stack_id)}: stack not found — skipping")
        acc

      %Stack{} = stack ->
        pending =
          stack
          |> Stacks.members()
          |> Enum.reject(&(&1.status == "done"))

        log(
          "  #{short(stack_id)} [DRY-RUN]: #{length(pending)} member(s) would cascade " <>
            "(status counts: #{pending |> Enum.frequencies_by(& &1.status) |> inspect()})"
        )

        acc
    end
  end

  defp process_stack(stack_id, false = _dry_run, verbose?, acc) do
    # `cascade_members_to_done/2` takes a positional trigger atom
    # (`:webhook | :backfill`) — not a keyword. The stage spec's
    # `trigger: :backfill` shape drifted from the actual signature at
    # `stacks.ex:2094`; we match reality.
    result = Stacks.cascade_members_to_done(stack_id, :backfill)
    cascaded = length(result.cascaded)
    skipped = length(result.skipped)

    log(
      "  #{short(stack_id)}: cascaded=#{cascaded} skipped=#{skipped}" <>
        if(verbose?, do: " detail=#{inspect(result)}", else: "")
    )

    %{
      stacks: acc.stacks + 1,
      advanced: acc.advanced + cascaded,
      skipped: acc.skipped + skipped
    }
  end

  # ── Logging shim ────────────────────────────────────────────────────────

  # Prefer `Mix.shell().info/1` when running via `mix` so `capture_io`
  # picks up the output for tests; fall back to `Logger` under
  # `bin/platform eval` where Mix.shell isn't available.
  defp log(msg) do
    if function_exported?(Mix, :shell, 0) do
      Mix.shell().info(msg)
    else
      Logger.info(msg)
    end
  end

  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short(other), do: inspect(other)
end
