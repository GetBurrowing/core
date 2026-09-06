defmodule Mix.Tasks.Platform.VoiceLatencyReport do
  @moduledoc """
  Distribution report over the meeting-voice latency events recorded by task
  `01a07400` stages 1 and 2 (stage 3).

      mix platform.voice_latency_report
      mix platform.voice_latency_report --days 7
      mix platform.voice_latency_report --max-pairs 40

  It is also callable from a release, where `Mix.Task.run/1` does not exist:

      bin/platform eval 'Mix.Tasks.Platform.VoiceLatencyReport.report()'

  ## A measurement, not a benchmark

  This task starts nothing, dispatches nothing and simulates nothing. It is a
  pure read over `audit_events` rows that real meeting traffic produced. There
  is no synthetic timing harness and no simulated agent here on purpose: a
  latency drawn from a fabricated round trip measures the fabrication. If no
  traffic has been through the voice path, the correct report is an empty one,
  and an empty report is a success — the task says so and exits 0.

  ## The four measures

  | # | measure | event | key |
  |---|---------|-------|-----|
  | 1 | frame delivered to the agent's first say dispatch | `platform.meetings.agent.responded` | `response_ms` |
  | 2 | say dispatch to runtime ack, split by ack status | `platform.meetings.say.ack` | `latency_ms` |
  | 3 | speech end to transcript frame delivered | `platform.meetings.transcript.delivered` | `lag_ms` |
  | 4 | ack latency against the reported audio duration, paired | `platform.meetings.say.ack` | `latency_ms` + `duration_s` |

  ## Measure 1 is a PROXY and is labelled as one in the output

  `response_ms` is frame delivery to say DISPATCH. It is not the time the model
  took to produce a first token, and this task must never present it as one:
  core cannot observe a federated agent's tokens at all, so the number contains
  the network out, the plugin's queue, whatever the agent was already busy
  with, the model itself, and the trip back into `say/4`. It is the closest
  quantity obtainable from this side, and it is the one a human in the room
  actually waits through — which is why it is worth reporting, under its own
  name. `Platform.Meetings.TranscriptTelemetry`'s moduledoc holds the long
  version. The label goes in the printed output, not only in this docstring,
  because the reader of the number is the person who needs the caveat.

  ## Measure 3 has no sink, and the report says which kind of empty it is

  `[:platform, :meetings, :transcript, :delivered]` is emitted, but it is
  deliberately NOT registered in `Platform.Audit.TelemetryHandler` — stage 2
  declined it because the event fires once per recipient agent per final
  segment with no cap anywhere, and an audit row per frame would make the audit
  log mostly transcript delivery. That reasoning stands, and this task does not
  reverse it from inside a reporting change: wiring a durable sink for that
  event is a separate ticket, with its own volume argument.

  What this task does instead is refuse to let the gap look like calm. A
  measure with a sink and no rows prints "no events recorded"; a measure with
  no sink prints that the event is emitted but nothing persists it, and names
  the reason. Those are two different sentences because they are two different
  facts, and collapsing them would make an unwired measure indistinguishable
  from a quiet week — the one failure shape a report like this must not have.

  Whether a sink exists is asked of `TelemetryHandler.events/0` at run time
  rather than restated as a literal here, so the claim cannot go stale: the day
  someone registers the event, this measure starts reporting a distribution
  with no edit to this file.

  ## The refusal, and why it is per measure

  Below `min_sample/0` observations a measure prints its raw values and its
  sample size and REFUSES to print percentiles. Not a warning above them — a
  suppression. A p99 over six samples is the p99 of nothing; the original
  framing this work descends from went wrong exactly that way, three times,
  off a handful of hand-timed numbers, and a percentile on the page is read as
  a distribution no matter what caveat sits beside it.

  The rule applies PER MEASURE, and within measure 2 per ack status, because
  each has its own independent n. A run where the "spoken" acks number 40 and
  the "failed" acks number 6 prints percentiles for the first and refuses for
  the second, in the same output. A single global gate would suppress a sound
  distribution because an unrelated one was thin, and report a thin one because
  an unrelated one was rich; it would be a different feature and a wrong one.

  ## Percentile method

  Nearest rank on the sorted sample, no interpolation: the p-th percentile is
  the value at position `ceil(p / 100 * n)`. Every printed percentile is
  therefore a value that was actually observed, not an average of two that
  were. The method is named in the output so nobody has to guess which
  convention produced the number.
  """

  use Mix.Task

  import Ecto.Query

  alias Platform.Audit.Event
  alias Platform.Audit.TelemetryHandler
  alias Platform.Meetings.SayTelemetry
  alias Platform.Meetings.TranscriptTelemetry
  alias Platform.Repo

  @shortdoc "Report meeting voice latency distributions from recorded audit events"

  # Below this many observations a measure prints raw values and no
  # percentiles. Twenty is not a statistical threshold so much as a floor
  # under obvious nonsense — it is the point past which a p50 is at least
  # answering a question about a sample rather than about one bad afternoon.
  @min_sample 20

  # Measure 4 prints its pairs so the relationship can be READ. A busy month
  # would print tens of thousands of them and bury the rest of the report, so
  # the list is capped and the cap announces itself when it bites.
  @default_max_pairs 100

  @switches [days: :integer, max_pairs: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, _rest, _invalid} = OptionParser.parse(args, strict: @switches)

    report(parsed)
  end

  @doc """
  Prints the report and returns `:ok`. Mix-free so a release can call it.

  Options: `:days` (window, default all recorded events) and `:max_pairs`
  (measure 4's printed-pair cap, default #{@default_max_pairs}).
  """
  @spec report(keyword()) :: :ok
  def report(opts \\ []) do
    since = since_from(opts[:days])
    max_pairs = opts[:max_pairs] || @default_max_pairs

    responded = load(TranscriptTelemetry.responded_event(), since)
    acks = load(SayTelemetry.ack_event(), since)
    delivered = load(TranscriptTelemetry.delivered_event(), since)

    print_header(opts[:days])
    print_nothing_at_all(responded, acks, delivered)

    print_measure_1(responded)
    print_measure_2(acks)
    print_measure_3(delivered)
    print_measure_4(acks, max_pairs)

    print_legend()

    :ok
  end

  @doc """
  The sample size at or above which percentiles are printed. Public so a test
  asserts the boundary against the same number the report enforces, rather
  than against a copy of it that can drift.
  """
  @spec min_sample() :: pos_integer()
  def min_sample, do: @min_sample

  # -- Header --

  defp print_header(days) do
    log("voice_latency_report — meeting voice latency, from recorded audit events")
    log("window: #{window_label(days)}")
    log("percentile method: nearest rank on the sorted sample, no interpolation")
    log("percentiles are printed only at n >= #{@min_sample}; below that, raw values only")
    log("")
  end

  defp window_label(nil), do: "all recorded events"

  defp window_label(days), do: "the last #{days} day(s) of recorded events"

  # The whole-report empty case the spec calls for, said once and plainly, so
  # an operator is not left inferring it from four separate measure blocks.
  # It is a statement, not a failure: this task exits 0 either way.
  defp print_nothing_at_all([], [], []) do
    log("NO EVENTS — nothing has been recorded in this window, so there is nothing to")
    log("summarise. This is not an error: the report reads real traffic and there has")
    log("been none. Each measure below says which kind of empty it is.")
    log("")
  end

  defp print_nothing_at_all(_responded, _acks, _delivered), do: :ok

  # -- Measure 1 --

  defp print_measure_1(rows) do
    log("MEASURE 1 — transcript frame delivered -> agent's first say dispatch")
    log("  source: #{source(TranscriptTelemetry.responded_event(), "response_ms")}, milliseconds")

    log("  PROXY, not a first-token time. Core observes a federated agent's actions, never")

    log("  its tokens, so this contains the network out, the plugin's queue, whatever the")

    log("  agent was already doing, the model, and the trip back. It is what a human in the")

    log("  room waits through, which is why it is worth reporting under its own name.")

    values = numbers(rows, "response_ms")
    print_sample(values, rows, TranscriptTelemetry.responded_event(), "  ")
    log("")
  end

  # -- Measure 2 --

  defp print_measure_2(rows) do
    log("MEASURE 2 — say dispatch -> runtime ack, split by ack status")
    log("  source: #{source(SayTelemetry.ack_event(), "latency_ms")}, milliseconds")

    log("  status is the LITERAL string the runtime sent. Each status is its own sample with")

    log("  its own n, and the sample-size rule is applied per status, never across them.")

    case group_by_status(rows) do
      [] ->
        print_empty(rows, SayTelemetry.ack_event(), "  ")

      groups ->
        Enum.each(groups, fn {status, values} ->
          log("  status #{inspect(status)}")
          print_sample(values, rows, SayTelemetry.ack_event(), "    ")
        end)
    end

    log("")
  end

  # An ack row whose `latency_ms` was omitted (the registry row expired, or the
  # id was never dispatched on this node) contributes no latency and is not
  # counted into any status. It is reported as a separate line rather than
  # silently dropped: a status whose n is smaller than its row count is a fact
  # about the registry ttl, not about the runtime.
  defp group_by_status(rows) do
    rows
    |> Enum.filter(&is_number(Map.get(&1, "latency_ms")))
    |> Enum.group_by(&to_string(Map.get(&1, "status", "(no status)")), &Map.get(&1, "latency_ms"))
    |> Enum.sort_by(fn {status, values} -> {-length(values), status} end)
  end

  # -- Measure 3 --

  defp print_measure_3(rows) do
    log("MEASURE 3 — speech end -> transcript frame delivered")
    log("  source: #{source(TranscriptTelemetry.delivered_event(), "lag_ms")}, milliseconds")

    log("  measures speech end to SEND, not to hearing: a broadcast into a topic nobody is")

    log("  listening on returns :ok, and an old channel plugin drops the frame in silence.")

    values = numbers(rows, "lag_ms")
    print_sample(values, rows, TranscriptTelemetry.delivered_event(), "  ")
    log("")
  end

  # -- Measure 4 --

  defp print_measure_4(rows, max_pairs) do
    log("MEASURE 4 — runtime ack latency against the audio duration it reported (paired)")

    log(
      "  source: #{event_type(SayTelemetry.ack_event())} / latency_ms + duration_s, rows carrying both"
    )

    log("  Printed as PAIRS so the relationship is visible rather than asserted. This report")

    log("  computes no correlation coefficient and claims none — an ack that merely tracks")

    log("  the audio length and one that does not look different here, and you decide.")

    pairs = pairs(rows)

    cond do
      pairs == [] and rows == [] ->
        print_empty(rows, SayTelemetry.ack_event(), "  ")

      pairs == [] ->
        log(
          "  n=0 — #{length(rows)} ack row(s) in this window, none carrying BOTH latency_ms and"
        )

        log("  duration_s. A worker that reports no duration, or an ack past the registry ttl,")

        log("  cannot be paired.")

      true ->
        print_pair_sample(pairs, max_pairs)
    end

    log("")
  end

  defp print_pair_sample(pairs, max_pairs) do
    n = length(pairs)
    latencies = Enum.map(pairs, fn {_audio_s, ack_ms} -> ack_ms end)
    durations = Enum.map(pairs, fn {audio_s, _ack_ms} -> audio_s end)

    if too_small?(n) do
      log("  n=#{n}")
      log("  #{too_small_line(n)}")
      log("  the pairs below ARE the raw values.")
    else
      log("  #{String.pad_trailing("ack_ms", 10)}#{stats_line(latencies)}")
      log("  #{String.pad_trailing("audio_s", 10)}#{stats_line(durations)}")
    end

    print_pairs(pairs, n, max_pairs)
  end

  defp print_pairs(pairs, n, max_pairs) do
    shown = Enum.take(pairs, max_pairs)

    log("  pairs, sorted by audio duration (excess_ms = ack_ms - audio_s * 1000):")
    log("    #{String.pad_trailing("AUDIO_S", 12)}#{String.pad_trailing("ACK_MS", 12)}EXCESS_MS")

    Enum.each(shown, fn {audio_s, ack_ms} ->
      excess = round(ack_ms - audio_s * 1000)

      log(
        "    #{String.pad_trailing(num(audio_s), 12)}#{String.pad_trailing(num(ack_ms), 12)}#{excess}"
      )
    end)

    if n > max_pairs do
      log("    ... #{n - max_pairs} further pair(s) not shown (--max-pairs #{max_pairs})")
    end
  end

  # Sorted by audio duration rather than by time, because the question the pair
  # answers is whether the ack tracks the length of the audio: ordered that
  # way, a reader sees the answer down the third column without being told it.
  defp pairs(rows) do
    rows
    |> Enum.filter(fn row ->
      is_number(Map.get(row, "latency_ms")) and is_number(Map.get(row, "duration_s"))
    end)
    |> Enum.map(fn row -> {Map.get(row, "duration_s"), Map.get(row, "latency_ms")} end)
    |> Enum.sort()
  end

  # -- Sample printing --

  defp print_sample([], rows, event_name, indent), do: print_empty(rows, event_name, indent)

  defp print_sample(values, _rows, _event_name, indent) do
    n = length(values)

    if too_small?(n) do
      log("#{indent}n=#{n}")
      log("#{indent}#{too_small_line(n)}")
      log("#{indent}raw values: #{Enum.map_join(Enum.sort(values), ", ", &num/1)}")
    else
      log("#{indent}#{stats_line(values)}")
    end
  end

  # THE refusal. `<` and not `<=`, and the boundary is exercised at 19 and 20 in
  # the test: at n = @min_sample percentiles print, below it they do not.
  defp too_small?(n), do: n < @min_sample

  # Deliberately says "suppressed" and never names a percentile: the tokens
  # "p50" / "p90" / "p99" appear in this task's output ONLY on a line that is
  # actually reporting one, which is what lets a test assert their absence.
  defp too_small_line(n) do
    "sample too small: n=#{n}, need #{@min_sample} — percentiles suppressed, raw values only."
  end

  defp stats_line(values) do
    sorted = Enum.sort(values)

    "n=#{length(sorted)}  p50=#{num(percentile(sorted, 50))}  p90=#{num(percentile(sorted, 90))}" <>
      "  p99=#{num(percentile(sorted, 99))}  min=#{num(List.first(sorted))}" <>
      "  max=#{num(List.last(sorted))}"
  end

  # Nearest rank: position ceil(p / 100 * n) in the sorted sample, 1-based.
  # Every value printed is one that was observed.
  defp percentile(sorted, p) do
    n = length(sorted)
    index = max(ceil(p * n / 100) - 1, 0)
    Enum.at(sorted, index)
  end

  # The two empties, kept as two sentences. "No sink" is asked of the handler's
  # own registration list, so this never becomes a stale literal.
  defp print_empty(rows, event_name, indent) do
    cond do
      rows != [] ->
        log(
          "#{indent}n=0 — #{length(rows)} row(s) in this window, none carrying the measurement key."
        )

      sink?(event_name) ->
        log(
          "#{indent}NO EVENTS RECORDED — this measure has a sink and nothing has come through it"
        )

        log("#{indent}in this window. Nothing is wrong; there has been no traffic to measure.")

      true ->
        log(
          "#{indent}NO SINK — #{event_type(event_name)} is emitted, but it is not registered in"
        )

        log(
          "#{indent}Platform.Audit.TelemetryHandler, so nothing persists it and no distribution"
        )

        log("#{indent}can be read here. That omission is deliberate (task 01a07400 stage 2): the")

        log(
          "#{indent}event fires once per recipient agent per final segment, uncapped, and a row"
        )

        log("#{indent}per frame would make the audit log mostly transcript delivery. This is NOT")

        log("#{indent}the same as \"no traffic\" — frames are being delivered and measured in")

        log("#{indent}process, they are simply not recorded anywhere this report can read.")

        log("#{indent}Giving it a durable sink is a separate ticket, with its own volume case.")
    end
  end

  defp sink?(event_name), do: event_name in TelemetryHandler.events()

  # -- Loading --

  defp load(event_name, since) do
    type = event_type(event_name)

    query =
      from(e in Event,
        where: e.event_type == ^type,
        order_by: [asc: e.id],
        select: e.metadata
      )

    query = if since, do: where(query, [e], e.inserted_at >= ^since), else: query

    query
    |> Repo.all()
    |> Enum.map(fn
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end)
  end

  defp numbers(rows, key) do
    rows
    |> Enum.map(&Map.get(&1, key))
    |> Enum.filter(&is_number/1)
  end

  defp since_from(nil), do: nil

  defp since_from(days) when is_integer(days) do
    DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
  end

  defp event_type(event_name), do: Enum.map_join(event_name, ".", &Atom.to_string/1)

  defp source(event_name, key), do: "#{event_type(event_name)} / #{key}"

  # -- Formatting --

  defp num(value) when is_integer(value), do: Integer.to_string(value)

  defp num(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)

  defp num(value), do: to_string(value)

  defp print_legend do
    log("LEGEND")
    log("  n           observations in the window, per measure — never pooled across measures.")

    log(
      "  percentiles nearest rank on the sorted sample, printed only at n >= #{@min_sample}. Below"
    )

    log("              that the raw values are printed and the percentiles are SUPPRESSED —")
    log("              per measure, and within measure 2 per ack status. The tokens for the")
    log("              50th, 90th and 99th appear in this output only where one is reported.")
    log("  PROXY       measure 1 is frame-delivery to say-dispatch. Not a first-token time.")
    log("  NO SINK     the event is emitted but nothing persists it. Different from no traffic.")
  end

  defp log(msg) do
    if function_exported?(Mix, :shell, 0) do
      Mix.shell().info(msg)
    else
      IO.puts(msg)
    end
  end
end
