defmodule Platform.Social.Analytics.PublicationCoverage do
  @moduledoc """
  Inclusive UTC date intervals for checked and incomplete publication history.

  Valid operations return ordered, disjoint ISO-date maps, merging adjacent
  dates. Malformed persisted arrays return `{:error, :invalid_ranges}` rather
  than dropping entries: losing an incomplete interval could falsely establish
  completeness. Invalid requested dates return `{:error, :invalid_interval}`.
  `covers?/3` fails closed on either error. Work scales with interval count,
  never the number of days represented.
  """

  def normalize(ranges) do
    with {:ok, decoded} <- decode(ranges), do: encode(union(decoded))
  end

  def add(ranges, from, to) do
    with {:ok, interval} <- requested(from, to),
         {:ok, decoded} <- decode(ranges),
         do: encode(union([interval | decoded]))
  end

  def subtract(ranges, from, to) do
    with {:ok, interval} <- requested(from, to),
         {:ok, decoded} <- decode(ranges),
         do: decoded |> union() |> Enum.flat_map(&difference(&1, interval)) |> encode()
  end

  def missing(ranges, from, to) do
    with {:ok, {first, last}} <- requested(from, to),
         {:ok, decoded} <- decode(ranges) do
      {cursor, gaps} =
        decoded
        |> union()
        |> Enum.reduce({first, []}, fn {left, right}, {cursor, gaps} ->
          cond do
            right < cursor or left > last or cursor > last -> {cursor, gaps}
            left > cursor -> {right + 1, [{cursor, left - 1} | gaps]}
            true -> {max(cursor, right + 1), gaps}
          end
        end)

      gaps = if cursor <= last, do: [{cursor, last} | gaps], else: gaps
      gaps |> Enum.reverse() |> encode()
    end
  end

  def covers?(ranges, from, to), do: missing(ranges, from, to) == []

  defp requested(%Date{} = from, %Date{} = to) do
    first = Date.to_gregorian_days(from)
    last = Date.to_gregorian_days(to)
    if first <= last, do: {:ok, {first, last}}, else: {:error, :invalid_interval}
  end

  defp requested(_, _), do: {:error, :invalid_interval}

  defp decode(ranges) when is_list(ranges) do
    Enum.reduce_while(ranges, {:ok, []}, fn
      %{"from" => from, "to" => to}, {:ok, acc} when is_binary(from) and is_binary(to) ->
        with {:ok, from} <- Date.from_iso8601(from),
             {:ok, to} <- Date.from_iso8601(to),
             {:ok, interval} <- requested(from, to) do
          {:cont, {:ok, [interval | acc]}}
        else
          _ -> {:halt, {:error, :invalid_ranges}}
        end

      _, _ ->
        {:halt, {:error, :invalid_ranges}}
    end)
  end

  defp decode(_), do: {:error, :invalid_ranges}

  defp union(intervals) do
    intervals
    |> Enum.sort()
    |> Enum.reduce([], fn
      interval, [] ->
        [interval]

      {first, last}, [{previous_first, previous_last} | rest] = acc ->
        if first <= previous_last + 1,
          do: [{previous_first, max(previous_last, last)} | rest],
          else: [{first, last} | acc]
    end)
    |> Enum.reverse()
  end

  defp difference({first, last}, {remove_first, remove_last}) do
    cond do
      remove_last < first or remove_first > last ->
        [{first, last}]

      true ->
        left = if first < remove_first, do: [{first, remove_first - 1}], else: []
        right = if last > remove_last, do: [{remove_last + 1, last}], else: []
        left ++ right
    end
  end

  defp encode(intervals) do
    Enum.map(intervals, fn {first, last} ->
      %{
        "from" => first |> Date.from_gregorian_days() |> Date.to_iso8601(),
        "to" => last |> Date.from_gregorian_days() |> Date.to_iso8601()
      }
    end)
  end
end
