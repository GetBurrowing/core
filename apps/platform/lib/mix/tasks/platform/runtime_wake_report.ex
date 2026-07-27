defmodule Mix.Tasks.Platform.RuntimeWakeReport do
  @moduledoc """
  Standing report of which `claude_channel` runtimes have PROVEN that their
  build renders the body of a `system_event` attention.

  A `system_event` attention (`Platform.Chat.AgentResponder.broadcast_system_event/3`)
  carries its body on `signal.prompt` and has no `message` key at all, unlike
  the two task/chat dispatch paths. A bridge that reads only
  `payload.message.content` renders those two perfectly and drops every
  `system_event` wake — which is why "a task dispatch reached that runtime with
  a full body" proves nothing about its wake handling.

  The version string does not discriminate either: every `claude_channel`
  runtime reported `0.2.0` both before and after the fix landed, because the
  fix did not touch `package.json`. What DOES discriminate is the capability
  the client declares on join (`client_info.features`), because it is emitted
  by the same module that contains the behavior. This report reads that
  declaration back out.

  ## Usage

      mix platform.runtime_wake_report

  ## Why a Mix task instead of a data migration or a Control Center panel

  Re-runnable from any node via `bin/platform eval` after deploy, and
  decoupled from schema migration ordering — it is a pure read, so it can be
  run before, during and after a rollout to watch rows flip:

      bin/platform eval 'Mix.Tasks.Platform.RuntimeWakeReport.report()'

  Deliberately not a Control Center LiveView panel: no visual surface means no
  design review and no cycle-time cost for what is an operator's rollout
  checklist. If it earns a UI later, that is its own task.

  ## Reading the verdicts

  The verdict is three-valued in wording and two-valued in code, and the
  wording is the point:

    * `proven` — declared the capability on its most recent join.
    * `unproven` — has not. This covers BOTH a runtime running an old build
      AND a runtime running a new build that has not reconnected since the
      server started recording. It is NOT a defect count, and the report never
      prints the word "broken" for it.
    * `revoked` — printed in its own section and excluded from the unproven
      count. A revoked runtime cannot authenticate, cannot join, cannot
      declare and cannot receive a dispatch, so it is not a delivery risk;
      counting it as unverified would inflate the number an operator reads.
  """

  use Mix.Task

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Repo

  @shortdoc "Report system_event wake-delivery capability per claude_channel runtime"

  # Two spaces of gutter between columns. Widths are computed from the data
  # rather than fixed: `neven-home-claude-code` is 22 characters and a slug can
  # be longer still, and a value that exactly fills a fixed column runs into
  # the next one with no separator — which reads as a corrupt row and breaks
  # any whitespace-splitting an operator (or a test) does on the output.
  @gutter 2

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    report()
  end

  @doc """
  Prints the report. Public and Mix-free so it is callable from a release
  (`bin/platform eval`) where `Mix.Task.run/1` is not available.
  """
  @spec report() :: :ok
  def report do
    {revoked, joinable} =
      load_claude_channel_runtimes()
      |> Enum.split_with(fn {runtime, _slug} -> runtime.status == "revoked" end)

    rows = Enum.map(joinable, fn {runtime, slug} -> {runtime, slug, verdict(runtime)} end)

    proven_count = Enum.count(rows, fn {_runtime, _slug, verdict} -> verdict == "proven" end)
    unproven_count = length(rows) - proven_count
    revoked_count = length(revoked)

    log("runtime_wake_report: #{feature()} delivery across claude_channel runtimes")
    log("")

    print_live_section(rows, revoked_count)
    print_revoked_section(revoked)
    print_legend()
    print_footer(proven_count, unproven_count, revoked_count)

    :ok
  end

  defp print_live_section([], 0) do
    log("no claude_channel runtimes recorded — nothing to report")
    log("")
  end

  defp print_live_section([], _revoked_count) do
    log("no claude_channel runtimes can currently join (see REVOKED below)")
    log("")
  end

  defp print_live_section(rows, _revoked_count) do
    header = ["RUNTIME", "AGENT", "STATUS", "LAST CONNECTED", "VERSION", "VERDICT"]

    cells =
      Enum.map(rows, fn {runtime, slug, verdict} ->
        [
          runtime.runtime_id,
          slug,
          runtime.status,
          connected_at(runtime),
          client_version(runtime),
          verdict
        ]
      end)

    print_table(header, cells, "")
    log("")
  end

  defp print_revoked_section([]) do
    log("REVOKED — none")
    log("")
  end

  defp print_revoked_section(revoked) do
    log("REVOKED — cannot join — not a delivery risk (excluded from the unproven count)")

    cells =
      Enum.map(revoked, fn {runtime, slug} ->
        [runtime.runtime_id, slug, runtime.status, connected_at(runtime), client_version(runtime)]
      end)

    print_table(["RUNTIME", "AGENT", "STATUS", "LAST CONNECTED", "VERSION"], cells, "  ")
    log("")
  end

  defp print_table(header, rows, indent) do
    widths =
      [header | rows]
      |> Enum.map(fn row -> Enum.map(row, &(&1 |> cell() |> String.length())) end)
      |> Enum.zip_with(&Enum.max/1)
      |> Enum.map(&(&1 + @gutter))

    Enum.each([header | rows], fn row ->
      line =
        row
        |> Enum.zip(widths)
        |> Enum.map(fn {value, width} -> String.pad_trailing(cell(value), width) end)
        |> Enum.join()
        |> String.trim_trailing()

      log(indent <> line)
    end)
  end

  defp print_legend do
    log("LEGEND")
    log("  proven   — declared #{feature()} on its most recent join.")
    log("  unproven — has not declared it. This covers BOTH a runtime running an old build")

    log(
      "             AND a runtime running a new build that has not reconnected since the server started recording."
    )

    log(
      "             Absence of a declaration is not evidence of a defect — it means not yet proven."
    )

    log("  revoked  — cannot join — not a delivery risk. Listed separately, never as unproven.")
    log("")
  end

  defp print_footer(proven, unproven, revoked) do
    total = proven + unproven + revoked

    log(
      "TOTALS: total=#{total}  proven=#{proven}  unproven=#{unproven}  revoked=#{revoked}" <>
        "  (total = proven + unproven + revoked)"
    )
  end

  # Scoped by PRODUCT, not by capability: a non-claude_channel runtime that
  # happens to declare the same feature name is out of scope, and a
  # claude_channel runtime that declares nothing is very much in scope.
  # `client_product/1` is the single place that classification lives.
  defp load_claude_channel_runtimes do
    query =
      from(r in AgentRuntime,
        left_join: a in Agent,
        on: a.id == r.agent_id,
        order_by: [asc: r.runtime_id],
        select: {r, a.slug}
      )

    query
    |> Repo.all()
    |> Enum.filter(fn {runtime, _slug} ->
      AgentRuntime.client_product(runtime) == "claude_channel"
    end)
  end

  # Two-valued in code. `client_supports?/2` fails closed, so everything that
  # is not a positive declaration lands on "unproven" — never "broken".
  defp verdict(runtime) do
    if AgentRuntime.client_supports?(runtime, feature()), do: "proven", else: "unproven"
  end

  # Referenced through the accessor rather than restated as a literal: the
  # word the client declares and the word the server checks have to be the
  # same one or the verdict is meaningless.
  defp feature, do: AgentRuntime.system_event_prompt_feature()

  defp client_version(%{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("client_info", %{})
    |> case do
      m when is_map(m) -> Map.get(m, "version")
      _ -> nil
    end
    |> case do
      version when is_binary(version) -> version
      _ -> "-"
    end
  end

  defp client_version(_), do: "-"

  # "never" rather than a blank column: an empty cell reads as a formatting
  # bug, and "has never connected" is a meaningful state here — it is one of
  # the two things `unproven` covers.
  defp connected_at(%{last_connected_at: nil}), do: "never"

  defp connected_at(%{last_connected_at: at}) do
    at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  # An unlinked runtime has no agent slug; print a dash rather than an empty
  # cell so the column count of every row stays readable.
  defp cell(nil), do: "-"

  defp cell(value), do: to_string(value)

  defp log(msg) do
    if function_exported?(Mix, :shell, 0) do
      Mix.shell().info(msg)
    else
      IO.puts(msg)
    end
  end
end
