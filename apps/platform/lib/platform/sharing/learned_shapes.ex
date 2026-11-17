defmodule Platform.Sharing.LearnedShapes do
  @moduledoc """
  Common usage-batch adapter for the Habits aggregate contract (01a1b6a5).
  Calls only Shapes.aggregate/0, never the raw signal store. Historic shapes
  have unknown observation-time pack provenance and remain explicitly unattributed.
  """
  alias Platform.Habits.{Actions, Shapes}
  alias Platform.Experiments.Surfaces.LearnedDefaults
  @keys ~w(action rung signal_count_bucket accept_rate_bucket variant user_count pack_provenance)
  @variant_keys ~w(prefill_threshold min_signals act_after_accepts half_life_days)

  def snapshot do
    rows =
      Shapes.aggregate()
      |> Enum.map(fn shape ->
        shape
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.put("pack_provenance", "unavailable")
      end)

    if valid?(rows), do: rows, else: []
  end

  def valid?(rows) when is_list(rows) and length(rows) <= 1000,
    do: Enum.all?(rows, &valid_row?/1)

  def valid?(_), do: false

  defp valid_row?(row) when is_map(row) do
    Enum.sort(Map.keys(row)) == Enum.sort(@keys) and
      row["action"] in Actions.keys() and row["rung"] in ~w(rank prefill act) and
      row["signal_count_bucket"] in ~w(0-9 10-49 50+) and
      row["accept_rate_bucket"] in [nil, 0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0] and
      is_integer(row["user_count"]) and row["user_count"] >= 5 and
      row["user_count"] <= 1_000_000_000 and
      row["pack_provenance"] == "unavailable" and valid_variant?(row["variant"])
  end

  defp valid_row?(_), do: false

  defp valid_variant?(v) when is_map(v),
    do:
      Enum.sort(Map.keys(v)) == Enum.sort(@variant_keys) and
        match?({:ok, _}, LearnedDefaults.validate_payload(v))

  defp valid_variant?(_), do: false
end
