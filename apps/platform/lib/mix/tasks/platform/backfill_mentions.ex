defmodule Mix.Tasks.Platform.BackfillMentions do
  @moduledoc """
  CLI wrapper around `Platform.Chat.MentionBackfill.run/1` — rewrites legacy
  `@Display Name` mentions to `@[Display Name]` per ADR 0037.

  The actual logic lives in `Platform.Chat.MentionBackfill` so it can also be
  invoked from a release via `bin/platform eval`.

  ## Usage

      mix platform.backfill_mentions           # dry-run, all messages
      mix platform.backfill_mentions --apply   # write changes
      mix platform.backfill_mentions --space-id <uuid> --apply
      mix platform.backfill_mentions --limit 100
  """

  use Mix.Task

  alias Platform.Chat.MentionBackfill

  @shortdoc "Backfill @-mentions to @[Name] wire format (ADR 0037)"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [apply: :boolean, limit: :integer, space_id: :string],
        aliases: [l: :limit, s: :space_id]
      )

    Mix.Task.run("app.start")

    module_opts =
      [apply: opts[:apply] || false]
      |> maybe_put(:limit, opts[:limit])
      |> maybe_put(:space_id, opts[:space_id])
      |> Keyword.put(:log, &Mix.shell().info/1)

    MentionBackfill.run(module_opts)
    :ok
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
