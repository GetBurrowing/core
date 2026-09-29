defmodule Platform.Meetings.OpenQuestionPilot.DatasetTest do
  @moduledoc """
  The open_question pilot dataset (task 01a0e8b5 stage 2): schema, the
  seeded split, privacy rows in every split, the README's counts, and the
  fixture rule's checkable half.
  """
  use ExUnit.Case, async: true

  alias Platform.Meetings.OpenQuestionPilot.Dataset

  @app_root Path.expand("../../../..", __DIR__)
  @readme Path.join(@app_root, "priv/imp_pilot/open_question/README.md")

  setup_all do
    {:ok, rows: Dataset.load()}
  end

  test "loads from the shipped priv path", %{rows: rows} do
    assert Dataset.path() =~ "priv/imp_pilot/open_question/dataset.jsonl"
    assert length(rows) == 100
  end

  test "every row satisfies the schema", %{rows: rows} do
    bad = for row <- rows, (problems = Dataset.problems(row)) != [], do: {row["id"], problems}
    assert bad == []
    assert rows |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == length(rows)
  end

  test "the schema check can fail" do
    row = %{
      "id" => "x",
      "text" => "Is it?",
      "participants" => ["Oskar"],
      "is_question" => false,
      "addressee" => "Oskar",
      "shape" => "s",
      "privacy" => false,
      "origin" => "transcript",
      "provenance" => "p",
      "split" => "dev"
    }

    assert Dataset.problems(row) == [
             ~s(a non-question has addressee "none"),
             "origin is synthesised|real_specimen",
             "split is train|val|test"
           ]
  end

  test "the stored split is exactly what the recorded seed computes", %{rows: rows} do
    computed = Dataset.assign_splits(Enum.map(rows, &Map.delete(&1, "split")), Dataset.seed())
    assert computed == Map.new(rows, &{&1["id"], &1["split"]})

    # The seed is load-bearing: a different one moves rows.
    refute Dataset.assign_splits(rows, "another-seed") == computed
  end

  test "the split is 40 / 25 / 35 and every split holds at least 3 privacy rows", %{rows: rows} do
    assert rows |> Dataset.split("train") |> length() == 40
    assert rows |> Dataset.split("val") |> length() == 25
    assert rows |> Dataset.split("test") |> length() == 35

    for split <- Dataset.splits() do
      privacy = rows |> Dataset.split(split) |> Enum.count(& &1["privacy"])
      assert privacy >= 3, "#{split} has #{privacy} privacy rows"
    end
  end

  test "the ticket's privacy row is pinned into test", %{rows: rows} do
    priya = Enum.find(rows, &(&1["id"] == "corpus-privacy-01"))

    assert priya["text"] == "Priya to deliver list of demands to Marcus by end of week"
    assert priya["privacy"] == true
    assert priya["is_question"] == false
    assert priya["participants"] == ["Priya", "Dana", "Marcus"]
    assert priya["split"] == "test"
  end

  test "class sizes the stage asks for", %{rows: rows} do
    synthesised_questions =
      Enum.count(
        rows,
        &(&1["is_question"] and not &1["privacy"] and not String.starts_with?(&1["id"], "corpus-"))
      )

    assert synthesised_questions >= 25

    new_non_questions =
      Enum.count(rows, &(String.starts_with?(&1["id"], "nq-") and not &1["is_question"]))

    assert new_non_questions >= 10

    assert Enum.count(rows, & &1["privacy"]) >= 9
    assert Enum.any?(rows, &(&1["privacy"] and &1["is_question"]))
  end

  test "the README's per-split table matches the data", %{rows: rows} do
    readme = File.read!(@readme)
    assert readme =~ Dataset.seed()

    for {split, subset} <-
          Enum.map(Dataset.splits(), &{&1, Dataset.split(rows, &1)}) ++ [{"all", rows}] do
      line =
        "| #{split} | #{length(subset)} | #{Enum.count(subset, & &1["is_question"])} | " <>
          "#{Enum.count(subset, &(!&1["is_question"]))} | #{Enum.count(subset, & &1["privacy"])} | " <>
          "#{Enum.count(subset, &(&1["privacy"] and &1["is_question"]))} |"

      assert readme =~ line, "README is missing the line #{line}"
    end
  end

  describe "fixture rule" do
    test "only the two allowed real specimens are real", %{rows: rows} do
      real = rows |> Enum.filter(&(&1["origin"] == "real_specimen")) |> Enum.map(& &1["text"])

      assert Enum.sort(real) ==
               Enum.sort(["Write my strategy", "Is this a demo? No, this is the…"])
    end

    test "no row text appears anywhere in priv/intent_eval", %{rows: rows} do
      # slices, candidates, prelabels, cassettes and runs were never cleared
      # for reuse; the pilot must not have copied from them.
      haystack =
        [@app_root, "priv/intent_eval", "**", "*"]
        |> Path.join()
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&(&1 |> File.read!() |> String.downcase()))

      assert haystack != []

      copied =
        for row <- rows,
            needle = String.downcase(row["text"]),
            Enum.any?(haystack, &String.contains?(&1, needle)),
            do: row["id"]

      assert copied == []
    end
  end
end
