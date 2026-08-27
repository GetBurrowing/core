defmodule Mix.Tasks.Platform.IntentEval.Sample do
  @moduledoc """
  Draw a stratified, deterministic candidate set out of the meeting-transcript
  archive for hand-labelling (task `01a03fbb` stage 2).

      mix platform.intent_eval.sample --limit 400 --out priv/intent_eval/candidates.jsonl --seed 20260827

  ## Every row comes out of the archive

  This task does not, and must not, generate synthetic negatives. The false
  positives that matter are disfluent, half-abandoned speech — *"Um, Captions
  is working. Okay, so."* — and a model asked to write chatter writes tidy
  chatter, so a classifier tuned on it will still fire on the genuine
  article. Synthetic text is permitted only to pad rare POSITIVE classes the
  archive does not contain, and every such row must carry
  `"origin": "synthetic"` so a scoring run can drop it with one flag. Rows
  emitted here always carry `"origin": "archive"`.

  ## Stratification

  One chatty standup is 300 segments; without caps it would BE the benchmark.
  Two caps apply, both enforced during selection rather than after:

    * at most 8 segments from any single transcript (`--per-transcript`)
    * at most 15% of the emitted set from any single speaker
      (`--speaker-share`)

  ## Determinism

  `:rand` is seeded from `--seed` and the seed is recorded in the output's
  header line, so the same command against the same archive reproduces the
  same file byte for byte. Candidates are ordered by `(transcript_id,
  segment index)` before the shuffle so the database's row order cannot
  leak in.

  ## `prior` is carried now, on purpose

  Each row carries up to three preceding segments from the same transcript.
  Nothing consumes them yet. The first variant this harness will be asked to
  measure is sibling task `01a03fb9-46b4` (fragment buffering), which needs
  the preceding context — and re-sampling later to add it would invalidate
  every label collected in between.

  ## Redaction

  Every emitted `text` (including the `prior` texts) is scrubbed before it is
  written: account-shaped 12-digit numbers become `<account-id>`, ARNs and
  key-shaped literals become `<redacted>`. The labelling set is read by
  humans and by whatever model a later stage points at it; neither should
  ever see a credential.
  """

  use Mix.Task

  import Ecto.Query

  alias Platform.Meetings.Transcript
  alias Platform.Repo

  @shortdoc "Sample transcript segments into a labelling candidate set"

  @default_limit 400
  @default_out "priv/intent_eval/candidates.jsonl"
  @default_seed 20_260_827
  @default_per_transcript 8
  @default_speaker_share 0.15
  @prior_window 3

  @switches [
    limit: :integer,
    out: :string,
    seed: :integer,
    per_transcript: :integer,
    speaker_share: :float
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, _rest, _invalid} = OptionParser.parse(args, strict: @switches)
    opts = normalize_opts(parsed)

    rows = sample_rows(opts)
    body = render(rows, opts)

    out = opts[:out]
    File.mkdir_p!(Path.dirname(out))
    File.write!(out, body)

    Mix.shell().info(
      "INTENT_EVAL_SAMPLE out=#{out} rows=#{length(rows)} seed=#{opts[:seed]} " <>
        "limit=#{opts[:limit]} per_transcript=#{opts[:per_transcript]} " <>
        "speaker_share=#{opts[:speaker_share]}"
    )

    :ok
  end

  @doc """
  Option map with defaults applied. Exposed so a test can build the same
  options `run/1` would without going through `OptionParser`.
  """
  def normalize_opts(opts) do
    %{
      limit: Keyword.get(opts, :limit, @default_limit),
      out: Keyword.get(opts, :out, @default_out),
      seed: Keyword.get(opts, :seed, @default_seed),
      per_transcript: Keyword.get(opts, :per_transcript, @default_per_transcript),
      speaker_share: Keyword.get(opts, :speaker_share, @default_speaker_share)
    }
    |> Enum.into([])
    |> Enum.sort()
  end

  @doc """
  The full file body: a header line carrying the seed and the selection
  parameters, then one JSON object per line.
  """
  def render(rows, opts) do
    header =
      Jason.encode!(%{
        "header" => true,
        "seed" => opts[:seed],
        "limit" => opts[:limit],
        "per_transcript" => opts[:per_transcript],
        "speaker_share" => opts[:speaker_share],
        "count" => length(rows),
        "source" => "meeting_transcripts.segments",
        "origin_policy" =>
          "archive only; synthetic rows must carry \"origin\": \"synthetic\" and are never emitted by this task"
      })

    [header | Enum.map(rows, &Jason.encode!/1)]
    |> Enum.map(&[&1, "\n"])
    |> IO.iodata_to_binary()
  end

  @doc """
  Select and shape the candidate rows. Deterministic for a given seed and a
  given archive.
  """
  def sample_rows(opts) do
    opts
    |> candidates()
    |> select_stratified(opts)
  end

  # ── candidate construction ────────────────────────────────────────────

  defp candidates(_opts) do
    from(t in Transcript,
      where: fragment("jsonb_array_length(?) > 0", t.segments),
      order_by: [asc: t.id],
      select: %{id: t.id, room_id: t.room_id, segments: t.segments}
    )
    |> Repo.all()
    |> Enum.flat_map(&explode/1)
  end

  defp explode(transcript) do
    segments = transcript.segments || []

    segments
    |> Enum.with_index()
    |> Enum.map(fn {segment, index} ->
      prior =
        segments
        |> Enum.slice(max(index - @prior_window, 0), min(index, @prior_window))
        |> Enum.map(&shape(&1, transcript))

      transcript
      |> then(&shape(segment, &1))
      |> Map.put("prior", prior)
      |> Map.put("origin", "archive")
    end)
    |> Enum.reject(&(&1["text"] in [nil, ""]))
  end

  defp shape(segment, transcript) do
    text = segment |> field(["text"]) |> to_text() |> scrub()

    %{
      "id" => row_id(transcript.room_id, field(segment, ["start_time", "timestamp_ms"]), text),
      "text" => text,
      "speaker" => field(segment, ["speaker_name", "participant_identity", "speaker"]),
      "room_id" => transcript.room_id,
      "timestamp_ms" => field(segment, ["start_time", "timestamp_ms"]),
      "transcript_id" => transcript.id
    }
  end

  # Segments are `{:array, :map}` JSONB: string-keyed from the database,
  # atom-keyed from a fixture or an in-flight broadcast payload. Read both
  # spellings rather than depending on either.
  defp field(segment, keys) when is_map(segment) do
    Enum.find_value(keys, fn key ->
      Map.get(segment, key) || Map.get(segment, String.to_existing_atom(key))
    end)
  rescue
    ArgumentError -> Enum.find_value(keys, &Map.get(segment, &1))
  end

  defp field(_segment, _keys), do: nil

  defp to_text(text) when is_binary(text), do: String.trim(text)
  defp to_text(_), do: ""

  defp row_id(room_id, timestamp_ms, text) do
    :crypto.hash(:sha256, "#{room_id}|#{timestamp_ms}|#{text}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # ── stratified selection ──────────────────────────────────────────────

  defp select_stratified(candidates, opts) do
    limit = opts[:limit]
    per_transcript = opts[:per_transcript]
    speaker_cap = max(1, ceil(limit * opts[:speaker_share]))

    :rand.seed(:exsss, {opts[:seed], opts[:seed], opts[:seed]})

    candidates
    |> Enum.sort_by(& &1["id"])
    |> Enum.shuffle()
    |> Enum.reduce_while({[], %{}, %{}}, fn row, {kept, by_transcript, by_speaker} = acc ->
      transcript_count = Map.get(by_transcript, row["transcript_id"], 0)
      speaker_key = row["speaker"] || "<unattributed>"
      speaker_count = Map.get(by_speaker, speaker_key, 0)

      cond do
        length(kept) >= limit ->
          {:halt, acc}

        transcript_count >= per_transcript ->
          {:cont, acc}

        speaker_count >= speaker_cap ->
          {:cont, acc}

        true ->
          {:cont,
           {[row | kept], Map.put(by_transcript, row["transcript_id"], transcript_count + 1),
            Map.put(by_speaker, speaker_key, speaker_count + 1)}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # ── redaction ─────────────────────────────────────────────────────────

  @arn_re ~r/arn:[a-z0-9-]*:[^\s"']*/i
  @account_re ~r/\b\d{12}\b/
  @aws_key_re ~r/\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[A-Z0-9]{12,}\b/
  @token_re ~r/\b(?:sk|pk|rk)-[A-Za-z0-9_\-]{12,}\b|\b(?:gh[pousr]|xox[baprs])_[A-Za-z0-9]{12,}\b/
  @secret_re ~r/\b(?=[A-Za-z0-9\/+=]{32,})(?=[^\s]*[A-Z])(?=[^\s]*[a-z])(?=[^\s]*\d)[A-Za-z0-9\/+=]{32,}\b/

  @doc """
  Strip credential-shaped literals out of a transcript line.

  ARNs go first: an ARN embeds the account id, so redacting the 12-digit
  number first would leave a mangled ARN behind rather than removing it.
  """
  def scrub(text) when is_binary(text) do
    text
    |> String.replace(@arn_re, "<redacted>")
    |> String.replace(@aws_key_re, "<redacted>")
    |> String.replace(@token_re, "<redacted>")
    |> String.replace(@secret_re, "<redacted>")
    |> String.replace(@account_re, "<account-id>")
  end

  def scrub(other), do: other
end
