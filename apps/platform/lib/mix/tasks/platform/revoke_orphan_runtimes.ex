defmodule Mix.Tasks.Platform.RevokeOrphanRuntimes do
  @moduledoc """
  One-off sweep (task 01a1b34b stage 4): revoke `active` runtimes left with
  no agent by agent deletes made before stage 1 landed. Dry run by default.

  ## Usage

      mix platform.revoke_orphan_runtimes                      # dry run: table + count
      mix platform.revoke_orphan_runtimes --stale-days 14      # dry run, other cutoff
      mix platform.revoke_orphan_runtimes --apply              # revoke
      mix platform.revoke_orphan_runtimes --runtime-id ID [--runtime-id ID2] [--apply]

  `--runtime-id` targets named rows and drops ONLY the staleness clause: a
  named row must still be `active`, have no agent, be pointed at by no
  agent, and not be online.

  The logic lives in `Platform.Federation.OrphanRuntimes`; this task is a
  thin wrapper. In a release (no mix), call the module on the live node:

      bin/platform rpc 'Platform.Federation.OrphanRuntimes.print(dry_run: true)'

  This task starts its own VM, so its `RuntimePresence` only knows runtimes
  connected to THIS VM (none, unless it is the dev server's node). The
  staleness clause is the backstop for that; for a named `--runtime-id`
  against a separately running server, check the runtime is offline first.

  Not a migration: nothing here runs on deploy.
  """

  use Mix.Task

  alias Platform.Federation.OrphanRuntimes

  @shortdoc "Dry-run-first revoke of active runtimes with no agent"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [apply: :boolean, stale_days: :integer, runtime_id: [:string, :keep]]
      )

    Mix.Task.run("app.start")

    sweep_opts = [
      dry_run: not Keyword.get(opts, :apply, false),
      stale_days: Keyword.get(opts, :stale_days, OrphanRuntimes.default_stale_days()),
      runtime_ids: Keyword.get_values(opts, :runtime_id)
    ]

    result = OrphanRuntimes.revoke_orphans(sweep_opts)
    shell = Mix.shell()
    result |> OrphanRuntimes.format_result() |> Enum.each(&shell.info/1)
    result
  end
end
