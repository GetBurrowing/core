defmodule Platform.Meetings.OpenQuestionPilot.DatasetDriftTest do
  @moduledoc """
  Drift guard for the dataset rows COPIED from
  `test/support/scribe_misfire_corpus.ex` (task 01a0e8b5 stage 2), in the
  manner of `force_update_intent_classify_prompt_agent_roster_drift_test.exs`.

  Each `corpus-*` row names its source list and index in `provenance`.
  The row's text and shape must equal that source row, and its participants
  must be the corpus's seating. Editing either copy alone fails here.
  """
  use ExUnit.Case, async: true

  alias Platform.Meetings.OpenQuestionPilot.Dataset
  alias Platform.Meetings.ScribeMisfireCorpus, as: Corpus

  @source ~r/^copied_from: test\/support\/scribe_misfire_corpus\.ex@([0-9a-f]{8}) (negatives|causes|positives|privacy)\[(\d+)\] \(misfire intent ([a-z_]+)\)$/

  defp source_list("negatives"), do: Corpus.negatives()
  defp source_list("causes"), do: Corpus.causes()
  defp source_list("positives"), do: Corpus.positives()
  defp source_list("privacy"), do: Corpus.privacy()

  test "every copied row still equals its source row" do
    copied = Enum.filter(Dataset.load(), &String.starts_with?(&1["id"], "corpus-"))

    source_total =
      length(Corpus.negatives()) + length(Corpus.causes()) + length(Corpus.positives()) +
        length(Corpus.privacy())

    assert length(copied) == source_total

    drift =
      Enum.flat_map(copied, fn row ->
        case Regex.run(@source, row["provenance"]) do
          [_, _sha, list, index, intent] ->
            {shape, source_intent, text} = Enum.at(source_list(list), String.to_integer(index))

            if {to_string(shape), source_intent, text} == {row["shape"], intent, row["text"]} and
                 row["participants"] == Corpus.participant_names(),
               do: [],
               else: [{row["id"], row["provenance"], {shape, source_intent, text}}]

          nil ->
            []
        end
      end)

    unparsed = Enum.reject(copied, &Regex.match?(@source, &1["provenance"]))

    assert unparsed == [],
           "copied rows with no parseable source: #{inspect(Enum.map(unparsed, & &1["id"]))}"

    assert drift == [], "copied rows drifted from the corpus: #{inspect(drift)}"
  end

  test "every source row is copied exactly once" do
    sources =
      Dataset.load()
      |> Enum.flat_map(fn row ->
        case Regex.run(@source, row["provenance"]) do
          [_, _sha, list, index, _intent] -> [{list, String.to_integer(index)}]
          nil -> []
        end
      end)

    expected =
      for {list, n} <- [
            {"negatives", length(Corpus.negatives())},
            {"causes", length(Corpus.causes())},
            {"positives", length(Corpus.positives())},
            {"privacy", length(Corpus.privacy())}
          ],
          i <- 0..(n - 1),
          do: {list, i}

    assert Enum.sort(sources) == Enum.sort(expected)
  end
end
