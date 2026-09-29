defmodule Platform.Meetings.OpenQuestionPilot.Dataset do
  @moduledoc """
  The open_question pilot's labelled set (task 01a0e8b5):
  `priv/imp_pilot/open_question/dataset.jsonl`, described in the README
  beside it. It lives in `priv`, not `test/support`, for the reason
  `Platform.Meetings.IntentEval` gives: it ships in the release, so a
  scoring run can be replayed against one.

  Every row is synthesised or one of the two real specimens the ticket
  allows. Nothing is read from a meeting, transcript or candidate row.

  ## Row schema

      %{"id", "text", "participants" => [name], "is_question" => bool,
        "addressee" => name | "none", "shape", "privacy" => bool,
        "origin" => "synthesised" | "real_specimen", "provenance", "split"}

  ## The split

  `assign_splits/2` is deterministic under a seed (`seed/0`), and the
  stored `"split"` column must equal what it computes; a test recomputes it.

    1. Pinned rows (`pinned/0`) go to their split first. The ticket's
       privacy row (Priya's list of demands) is pinned to `test`.
    2. The rest are grouped into strata by `{shape, is_question, privacy}`.
       Strata are walked privacy-first, then by key; inside a stratum,
       rows are ordered by `sha256(seed <> id)`.
    3. Walking that order, each row goes to the split furthest below its
       target share (train 40 / val 25 / test 35) of the rows assigned so
       far, pins included (ties: test, train, val). Consecutive rows of a
       stratum therefore spread across the splits in proportion, and the
       privacy block, walked first, lands at least 3 rows in every split.
  """

  @seed "01a0e8b5-open-question-split-v1"
  @targets [test: 0.35, train: 0.40, val: 0.25]
  @pinned %{"corpus-privacy-01" => "test"}
  @splits ["train", "val", "test"]
  @keys ~w(id text participants is_question addressee shape privacy origin provenance split)

  @doc "The recorded split seed."
  def seed, do: @seed

  @doc "Target share per split."
  def targets, do: Map.new(@targets, fn {k, v} -> {to_string(k), v} end)

  @doc "Rows pinned to a split before stratification: `%{id => split}`."
  def pinned, do: @pinned

  @doc "The split names."
  def splits, do: @splits

  @doc "The schema's keys."
  def keys, do: @keys

  @doc "Path of the dataset in the built app's priv."
  def path, do: Application.app_dir(:platform, "priv/imp_pilot/open_question/dataset.jsonl")

  @doc "Load the dataset (default: `path/0`)."
  @spec load(String.t()) :: [map()]
  def load(path \\ path()) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  @doc "Rows of one split."
  @spec split([map()], String.t()) :: [map()]
  def split(rows, name) when name in @splits, do: Enum.filter(rows, &(&1["split"] == name))

  @doc "Compute `%{id => split}` for `rows` under `seed`. Ignores any stored split."
  @spec assign_splits([map()], String.t()) :: %{String.t() => String.t()}
  def assign_splits(rows, seed \\ @seed) do
    {pinned, free} = Enum.split_with(rows, &Map.has_key?(@pinned, &1["id"]))
    pinned_assignments = Map.new(pinned, &{&1["id"], Map.fetch!(@pinned, &1["id"])})

    start_counts =
      Enum.reduce(Map.values(pinned_assignments), %{"train" => 0, "val" => 0, "test" => 0}, fn
        split, acc -> Map.update!(acc, split, &(&1 + 1))
      end)

    free
    |> Enum.group_by(&{&1["shape"], &1["is_question"], &1["privacy"]})
    |> Enum.sort_by(fn {{shape, q, privacy}, _} -> {not privacy, shape, q} end)
    |> Enum.flat_map(fn {_stratum, members} -> Enum.sort_by(members, &order_key(seed, &1)) end)
    |> Enum.reduce({pinned_assignments, start_counts}, fn row, {acc, counts} ->
      split = most_behind(counts)
      {Map.put(acc, row["id"], split), Map.update!(counts, split, &(&1 + 1))}
    end)
    |> elem(0)
  end

  defp order_key(seed, row),
    do: :crypto.hash(:sha256, seed <> row["id"]) |> Base.encode16(case: :lower)

  defp most_behind(counts) do
    total = counts |> Map.values() |> Enum.sum()

    {split, _deficit} =
      @targets
      |> Enum.map(fn {split, share} ->
        split = to_string(split)
        {split, share * (total + 1) - Map.fetch!(counts, split)}
      end)
      |> Enum.max_by(fn {_split, deficit} -> deficit end)

    split
  end

  @doc "Schema problems in one row; `[]` when the row is well formed."
  @spec problems(map()) :: [String.t()]
  def problems(row) do
    checks = [
      {Enum.sort(Map.keys(row)) == Enum.sort(@keys), "keys are exactly #{inspect(@keys)}"},
      {nonblank?(row["id"]), "id is a non-blank string"},
      {nonblank?(row["text"]), "text is a non-blank string"},
      {is_list(row["participants"]) and row["participants"] != [] and
         Enum.all?(row["participants"], &nonblank?/1),
       "participants is a non-empty list of names"},
      {is_boolean(row["is_question"]), "is_question is a boolean"},
      {row["addressee"] == "none" or row["addressee"] in List.wrap(row["participants"]) or
         nonblank?(row["addressee"]), "addressee is a name or \"none\""},
      {row["is_question"] == true or row["addressee"] == "none",
       "a non-question has addressee \"none\""},
      {nonblank?(row["shape"]), "shape is a non-blank string"},
      {is_boolean(row["privacy"]), "privacy is a boolean"},
      {row["origin"] in ["synthesised", "real_specimen"], "origin is synthesised|real_specimen"},
      {nonblank?(row["provenance"]), "provenance is a non-blank string"},
      {row["split"] in @splits, "split is train|val|test"}
    ]

    for {false, message} <- checks, do: message
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
