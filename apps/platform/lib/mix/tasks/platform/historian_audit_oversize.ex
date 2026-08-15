defmodule Mix.Tasks.Platform.HistorianAuditOversize do
  @moduledoc """
  Audits every Historian `oversize: true` window for digest eligibility.

  Answers, per window, the only question that matters when an oversize
  window dispatches `_No activity in this window._`: **was there anything
  the digest would actually have rendered?** Eligibility comes from the
  digest's own accessors, never from a hand-written SQL predicate — see
  `Platform.Agents.HistorianAudit` for why that distinction is the whole
  point of the tool.

  Read-only. Writes nothing.

  ## Usage

      mix platform.historian_audit_oversize
      mix platform.historian_audit_oversize --corpus messages
      mix platform.historian_audit_oversize --corpus files
      mix platform.historian_audit_oversize --since 2026-07-14
      mix platform.historian_audit_oversize --summary-only
      mix platform.historian_audit_oversize --class silent_loss

  ## Options

    * `--limit` — max audit rows to walk (default 1000)
    * `--since` — ISO date (`YYYY-MM-DD`) or full ISO-8601 instant; lower
      bound on `audit_events.inserted_at`
    * `--corpus` — restrict to one corpus (`messages`, `transcripts`,
      `pages`, `journal`, `files`). This list is a hand-maintained mirror
      of `Platform.Agents.HistorianCursor.valid_corpora/0`; a corpus
      missing from it is still filterable but undiscoverable, so the
      operator debugging that corpus's oversize windows never learns the
      flag accepts it. `Platform.Agents.HistorianCorpusRegistrationTest`
      pins this text against the real corpus list.
    * `--class` — print only windows with this classification
      (`spurious`, `silent_loss`, `truncated_loss`, `legitimate`). The
      summary still covers every window walked.
    * `--summary-only` — print the totals line and nothing else

  ## In production

  Releases have no Mix. Call the context directly:

      podman exec core-platform /app/bin/platform rpc \\
        "alias Platform.Agents.HistorianAudit, as: A;
         A.audit_oversize_windows() |> A.summarize() |> inspect() |> IO.puts()"
  """

  use Mix.Task

  alias Platform.Agents.HistorianAudit

  @shortdoc "Audit Historian oversize windows for digest eligibility"

  @classes ~w(spurious silent_loss truncated_loss legitimate)

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          limit: :integer,
          since: :string,
          corpus: :string,
          class: :string,
          summary_only: :boolean
        ],
        aliases: [l: :limit, s: :since, c: :corpus]
      )

    Mix.Task.run("app.start")

    audit_opts =
      []
      |> maybe_put(:limit, opts[:limit])
      |> maybe_put(:corpus, opts[:corpus])
      |> maybe_put(:since, parse_since(opts[:since]))

    results = HistorianAudit.audit_oversize_windows(audit_opts)
    summary = HistorianAudit.summarize(results)

    unless opts[:summary_only] do
      results
      |> filter_class(opts[:class])
      |> print_rows()
    end

    Mix.shell().info("")
    Mix.shell().info(HistorianAudit.summary_line(summary))
    Mix.shell().info("corpora: #{inspect(summary.corpora)}")
  end

  defp print_rows([]) do
    Mix.shell().info("No matching oversize windows.")
  end

  defp print_rows(rows) do
    Mix.shell().info(
      String.pad_trailing("window_start", 28) <>
        String.pad_trailing("corpus", 13) <>
        String.pad_trailing("class", 16) <>
        String.pad_leading("day_bytes", 11) <>
        String.pad_leading("raw", 7) <>
        String.pad_leading("elig", 6) <>
        String.pad_leading("elig_b", 9) <>
        String.pad_leading("body_b", 9) <> "  flags"
    )

    Enum.each(rows, fn row ->
      flags =
        [
          if(row.empty_stub?, do: "empty_stub"),
          if(row.truncation_marker?, do: "trunc_marker"),
          if(row.digest_compressed?, do: "compressed"),
          if(is_nil(row.dispatched_message_id), do: "no_body_found")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(",")

      Mix.shell().info(
        String.pad_trailing(DateTime.to_iso8601(row.window_start), 28) <>
          String.pad_trailing(row.corpus, 13) <>
          String.pad_trailing(to_string(row.classification), 16) <>
          String.pad_leading(to_string(row.day_bytes), 11) <>
          String.pad_leading(to_string(row.raw_row_count), 7) <>
          String.pad_leading(to_string(row.eligible_row_count), 6) <>
          String.pad_leading(to_string(row.eligible_bytes), 9) <>
          String.pad_leading(to_string(row.body_bytes), 9) <> "  " <> flags
      )
    end)
  end

  defp filter_class(results, nil), do: results

  defp filter_class(results, class) when class in @classes do
    wanted = String.to_existing_atom(class)
    Enum.filter(results, &(&1.classification == wanted))
  end

  defp filter_class(results, class) do
    Mix.shell().error("Unknown --class #{inspect(class)}; expected one of #{inspect(@classes)}")
    results
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_since(nil), do: nil

  defp parse_since(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _} ->
        dt

      _ ->
        case Date.from_iso8601(raw) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          _ -> Mix.raise("Could not parse --since #{inspect(raw)} as a date or ISO-8601 instant")
        end
    end
  end
end
