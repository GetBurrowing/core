defmodule Platform.Social.Trends.Comparison do
  @moduledoc false

  def movement(
        %{reporting_date: %Date{} = previous} = old,
        %{reporting_date: %Date{} = current} = new
      ) do
    if Date.diff(current, previous) == 1, do: comparable(old, new), else: unavailable(new)
  end

  def movement(%{reporting_date: nil}, %{reporting_date: %Date{}} = new), do: unavailable(new)
  def movement(%{reporting_date: %Date{}}, %{reporting_date: nil} = new), do: unavailable(new)

  def movement(old, new), do: comparable(old, new)

  defp comparable(%{source: source, limit: limit, items: previous}, %{
         source: source,
         limit: limit,
         items: current
       }) do
    old_ranks = Map.new(previous, &{&1.id, &1.rank})

    current_ids = MapSet.new(current, & &1.id)

    absent =
      previous
      |> Enum.reject(&MapSet.member?(current_ids, &1.id))
      |> Map.new(&{&1.id, :absent_from_sample})

    Map.new(current, fn item ->
      movement =
        case old_ranks[item.id] do
          nil -> :new_in_sample
          old when old > item.rank -> {:up, old - item.rank}
          old when old < item.rank -> {:down, item.rank - old}
          _ -> :unchanged
        end

      {item.id, movement}
    end)
    |> Map.merge(absent)
  end

  defp comparable(_, current), do: unavailable(current)
  defp unavailable(%{items: items}), do: Map.new(items, &{&1.id, :unavailable})
end
