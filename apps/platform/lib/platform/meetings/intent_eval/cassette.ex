defmodule Platform.Meetings.IntentEval.Cassette do
  @moduledoc """
  Recorded provider responses for the offline intent-eval harness
  (task `01a03fbb` stage 4).

  ## Why a cassette exists at all

  The classifier under test is a ~2B model served by llama-server on
  `test-host:8085`. That host is not reachable from every box: an agent asked to
  pick up the off_topic work found no DNS, no HTTP and no SSH to it, and
  correctly declined rather than ship blind. Host-boundness is a standing
  tax and this harness must not inherit it — so every live call is recorded
  and every recorded call is replayable with no network at all.

  ## The key

      sha256(rendered_prompt <NUL> chunk_text)

  Both halves are in the key on purpose. The prompt alone would collide
  across rows; the chunk alone would silently serve a response recorded
  under a DIFFERENT prompt, which is exactly the confusion this task exists
  to end (three measurement runs of the same 102 rows reported 7, 8 and 23
  because one arm read the live DB template and another read a migration
  heredoc).

  ## A miss is a hard failure, never a fallback

  `--replay` with a missing key stops the run and names the missing keys and
  their count. It does NOT reach for the network — that would reintroduce
  the host-boundness — and it does NOT score the row as `model_error` —
  that would corrupt the numbers with a harness bug wearing a model result's
  clothes.
  """

  @doc "The cassette key for a rendered prompt and the chunk classified under it."
  @spec key(String.t(), String.t()) :: String.t()
  def key(rendered_prompt, chunk_text) do
    :sha256
    |> :crypto.hash([rendered_prompt, <<0>>, chunk_text || ""])
    |> Base.encode16(case: :lower)
  end

  @doc "Path of the cassette for a config name under `root`."
  def path(root, config_name), do: Path.join([root, "cassettes", "#{config_name}.jsonl"])

  @doc """
  Load a cassette file as `%{key => entry}`. A missing file is an EMPTY
  cassette, not an error: "no cassette yet" is a legitimate state that
  `--record` resolves and `--replay` reports as a miss.
  """
  @spec load(String.t()) :: %{optional(String.t()) => map()}
  def load(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Map.new(&{&1["key"], &1})
    else
      %{}
    end
  end

  @doc """
  Append entries to a cassette, de-duplicated by key with the NEW entry
  winning. Rewrites the whole file in key order so a re-record produces a
  stable diff rather than an append-only log whose sha changes on every run.
  """
  @spec append!(String.t(), [map()]) :: :ok
  def append!(path, entries) do
    File.mkdir_p!(Path.dirname(path))

    merged =
      path
      |> load()
      |> Map.merge(Map.new(entries, &{&1["key"], &1}))
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {_key, entry} -> [Jason.encode!(entry), "\n"] end)

    File.write!(path, IO.iodata_to_binary(merged))
  end

  @doc """
  Build a cassette entry from a provider outcome.

  `outcome` is `"ok"` or `"error"`. An error response is recorded too: a run
  where the endpoint failed on nine rows is a real measurement of the
  pipeline and must replay identically, not vanish.
  """
  def entry(key, outcome, payload, latency_ms) do
    %{
      "key" => key,
      "outcome" => outcome,
      "response" => payload,
      "latency_ms" => latency_ms,
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
