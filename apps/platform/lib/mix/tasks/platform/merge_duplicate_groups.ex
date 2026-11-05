defmodule Mix.Tasks.Platform.MergeDuplicateGroups do
  @moduledoc """
  Reports, and with `--apply` merges, live unnamed groups that have the same
  current members (task 01a1acea stage 2).

  The logic lives in `Platform.Chat.DuplicateGroups`; read its moduledoc for
  what counts as a duplicate, how the keeper is chosen, what moves and what
  stays with the archived loser. This task only parses flags and prints.

  Nothing is deleted. A merged loser is archived, not removed, and a second
  `--apply` finds no duplicate set and changes nothing.

  This is an operator task. It is never run by deploy, a migration or CI.

  ## Usage

      mix platform.merge_duplicate_groups           # report only, writes nothing
      mix platform.merge_duplicate_groups --apply   # merge every duplicate set

  ## In production

  Releases have no Mix. Call the module directly:

      podman exec <platform-container> /app/bin/platform rpc \\
        "Platform.Chat.DuplicateGroups.report() |> inspect() |> IO.puts()"

      podman exec <platform-container> /app/bin/platform rpc \\
        "Platform.Chat.DuplicateGroups.apply() |> inspect() |> IO.puts()"
  """

  use Mix.Task

  alias Platform.Chat.DuplicateGroups

  @shortdoc "Report (or with --apply merge) duplicate unnamed group conversations"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [apply: :boolean])

    Mix.Task.run("app.start")

    lines =
      if opts[:apply],
        do: apply_lines(DuplicateGroups.apply()),
        else: report_lines(DuplicateGroups.report())

    shell = Mix.shell()
    Enum.each(lines, &shell.info/1)
  end

  @doc false
  def report_lines(%{sets: sets, total_sets: total, total_losers: losers}) do
    Enum.flat_map(sets, &set_lines/1) ++
      [
        "Duplicate sets: #{total}, groups to archive: #{losers}",
        "Report only: nothing written. Re-run with --apply to merge."
      ]
  end

  @doc false
  def apply_lines(%{sets: sets, total_sets: total, totals: totals}) do
    Enum.flat_map(sets, fn
      %{error: reason, key: key} ->
        ["Set #{key}: FAILED #{inspect(reason)} (rolled back)"]

      set ->
        set_lines(set) ++ ["  merged #{counts_line(set.counts)}"]
    end) ++
      ["Merged duplicate sets: #{total}", "Totals: #{counts_line(totals)}"]
  end

  defp set_lines(set) do
    head =
      "Set of #{set.size} members: keeper #{set.keeper_id}, losers #{Enum.join(set.loser_ids, ", ")}"

    spaces =
      Enum.map(set.spaces, fn s ->
        role = if s.id == set.keeper_id, do: "keeper", else: "loser"

        latest =
          if s.latest_message_at, do: DateTime.to_iso8601(s.latest_message_at), else: "none"

        "  #{role} #{s.id}: #{s.message_count} messages, latest #{latest}"
      end)

    [head | spaces]
  end

  defp counts_line(counts) do
    counts
    |> Enum.sort()
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)
  end
end
