defmodule Platform.Meetings.OpenQuestionPilot.Cassette do
  @moduledoc """
  Cassette key for the open_question pilot (task 01a0e8b5). File format,
  load, append and entry shape are `Platform.Meetings.IntentEval.Cassette`'s,
  reused rather than copied; only the KEY differs.

  ## The key

      sha256(canonical JSON of [%{"role" => .., "content" => ..}, ...])

  The intent-eval key hashes `system <NUL> user`, which fits a two-message
  call. An Imp program sends whatever its adapter renders (and retries with
  a second adapter on a parse failure), so the key here covers every
  message, in order, role and content only. Both arms go through this key
  so one cassette can hold both.
  """

  alias Platform.Meetings.IntentEval.Cassette, as: EvalCassette

  @doc "The cassette key for a list of chat messages."
  @spec key([map()]) :: String.t()
  def key(messages) when is_list(messages) do
    canonical =
      Enum.map(messages, fn message ->
        [
          ["role", to_string(field(message, :role))],
          ["content", to_string(field(message, :content) || "")]
        ]
      end)

    :sha256
    |> :crypto.hash(Jason.encode!(canonical))
    |> Base.encode16(case: :lower)
  end

  defdelegate load(path), to: EvalCassette
  defdelegate append!(path, entries), to: EvalCassette
  defdelegate entry(key, outcome, payload, latency_ms), to: EvalCassette

  defp field(message, key), do: Map.get(message, key) || Map.get(message, to_string(key))
end
