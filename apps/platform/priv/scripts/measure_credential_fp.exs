# Measure the false-positive rate of `Platform.Agents.CredentialShape`
# against real chat traffic. Task 01a09c9b, stage 3.
#
#     mix run priv/scripts/measure_credential_fp.exs [--days 30] [--limit N]
#
# ⛔ SAFETY CONTRACT — read before changing a line of this file.
#
# This script streams REAL `Platform.Chat.Message` bodies, and one of those
# bodies may be the actual credential this ticket was filed about.
#
#   * It prints the MESSAGE ID and the FIRING TIER, and nothing else drawn
#     from a body. Never the matching text, never a snippet, never a prefix,
#     never a character offset or a match length — a length plus a tier
#     narrows a secret, and a snippet simply IS the secret.
#   * It NEVER writes a body, or anything derived from one, to a file. There
#     is no `--out`, no CSV, and no dump mode. Do not add one.
#   * Its output must not be redirected to a persistent file, pasted into a
#     channel, a commit message, a journal entry or a stage note. Report the
#     AGGREGATES: total scanned, count flagged, rate, tier histogram.
#
# A credential that reaches an artefact is compromised, and rotation is the
# only control — there is no cleanup path. That asymmetry is why this script
# reports shapes by tier rather than by example.

# Run with `--no-start`: this script needs the Repo and nothing else, and
# booting the full supervision tree against a corpus-only database fails on
# unrelated children. Starting just the Repo also keeps the blast radius of
# a read-only measurement to a read-only measurement.
#
#     mix run --no-start priv/scripts/measure_credential_fp.exs
#
if is_nil(Process.whereis(Platform.Repo)) do
  {:ok, _} = Application.ensure_all_started(:ecto_sql)
  {:ok, _} = Application.ensure_all_started(:postgrex)
  {:ok, _} = Platform.Repo.start_link(pool_size: 2)
end

alias Platform.Agents.CredentialShape
alias Platform.Chat.Message
alias Platform.Repo

import Ecto.Query

{opts, _argv, _invalid} =
  OptionParser.parse(System.argv(), strict: [days: :integer, limit: :integer])

days = Keyword.get(opts, :days, 30)
limit = Keyword.get(opts, :limit)

# `System.os_time/1` rather than `DateTime.add/4`: under `--no-start` the
# tz database is not running, and `DateTime.add/4` consults it.
since = DateTime.from_unix!(System.os_time(:second) - days * 24 * 3600)

# Which tier fired, WITHOUT reporting anything about the matched span.
# Mirrors the tier order in `CredentialShape` — cheapest and most precise
# first — and reports the FIRST tier that fires, which is the tier that
# would have caused the withholding.
tier_of = fn body -> CredentialShape.firing_tier(body) || :unknown end

base =
  from(m in Message,
    where: m.inserted_at >= ^since,
    order_by: [asc: m.inserted_at],
    select: %{id: m.id, content: m.content, space_id: m.space_id, inserted_at: m.inserted_at}
  )

query = if limit, do: limit(base, ^limit), else: base

IO.puts("corpus: Platform.Chat.Message, inserted_at >= #{DateTime.to_iso8601(since)} (#{days}d)")
IO.puts("measured_at: #{DateTime.from_unix!(System.os_time(:second))} (UTC)")
IO.puts("")
IO.puts("flagged rows — message id, firing tier, space, timestamp. NO CONTENT.")

{scanned, flagged, histogram} =
  Repo.transaction(
    fn ->
      query
      |> Repo.stream(max_rows: 500)
      |> Enum.reduce({0, 0, %{}}, fn row, {scanned, flagged, hist} ->
        if CredentialShape.credential_shaped?(row.content) do
          tier = tier_of.(row.content)

          IO.puts(
            "  #{row.id}  #{tier}  space=#{row.space_id}  at=#{DateTime.to_iso8601(row.inserted_at)}"
          )

          {scanned + 1, flagged + 1, Map.update(hist, tier, 1, &(&1 + 1))}
        else
          {scanned + 1, flagged, hist}
        end
      end)
    end,
    timeout: :infinity
  )
  |> then(fn {:ok, result} -> result end)

rate = if scanned == 0, do: 0.0, else: flagged / scanned * 100

IO.puts("")
IO.puts("── aggregates ──────────────────────────────────────────────")
IO.puts("scanned:  #{scanned}")
IO.puts("flagged:  #{flagged}")
IO.puts("rate:     #{:erlang.float_to_binary(rate, decimals: 4)}%")
IO.puts("tier histogram:")

[:tier1_issuer_prefix, :tier2_assignment_shape, :tier3_generic_entropy, :unknown]
|> Enum.each(fn tier -> IO.puts("  #{tier}: #{Map.get(histogram, tier, 0)}") end)

IO.puts("")

IO.puts(
  "A rate is indexed to the corpus and window above. Quote both when citing it; " <>
    "it does not transfer to a different corpus or a different window."
)
