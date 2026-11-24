defmodule Platform.Regression.InstallIdentityShapeDiagnostic do
  @moduledoc false

  @max_hits 8
  @radius 64

  # The callback is explicit so the clean path can be tested without running it.
  def when_hits(_html, [], _formatter), do: ""

  def when_hits(html, hits, formatter) do
    try do
      formatter.(html, hits)
    rescue
      _ -> "diagnostic unavailable"
    catch
      _, _ -> "diagnostic unavailable"
    end
  end

  def describe(html, hits) do
    {selected, rest} = Enum.split(hits, @max_hits)
    shapes = Enum.map(selected, &shape(html, &1))
    Enum.join(shapes ++ if(rest == [], do: [], else: ["+more"]), "; ")
  end

  defp shape(html, {start, len})
       when is_binary(html) and is_integer(start) and is_integer(len) and start >= 0 and len > 0 and
              len <= @radius and start + len <= byte_size(html) do
    last = start + len - 1

    if Enum.all?(start..last, &alnum?(:binary.at(html, &1))) do
      {left, left_limited} = boundary(html, start - 1, -1, @radius)
      {right, right_limited} = boundary(html, start + len, 1, @radius)
      whole = left == start and right == start + len
      kind = if whole, do: "whole", else: "interior"

      if left_limited or right_limited do
        "#{kind} len=>bound chars=unknown"
      else
        run = binary_part(html, left, right - left)
        "#{kind} len=#{bucket(byte_size(run))} chars=#{composition(run)}"
      end
    else
      unknown()
    end
  end

  defp shape(_, _), do: unknown()
  defp unknown, do: "unknown len=unknown chars=unknown"

  # Return the exclusive right edge or inclusive left edge without reading
  # beyond @radius bytes in either direction.
  defp boundary(html, index, direction, left) do
    cond do
      index < 0 ->
        {0, false}

      index >= byte_size(html) ->
        {byte_size(html), false}

      not alnum?(:binary.at(html, index)) ->
        {if(direction == -1, do: index + 1, else: index), false}

      left == 0 ->
        {if(direction == -1, do: index + 1, else: index), true}

      true ->
        boundary(html, index + direction, direction, left - 1)
    end
  end

  defp alnum?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9
  defp bucket(n) when n <= 3, do: "3"
  defp bucket(n) when n <= 8, do: "8"
  defp bucket(n) when n <= 16, do: "16"
  defp bucket(n) when n <= 32, do: "32"
  defp bucket(_), do: ">32"

  defp composition(run) do
    bytes = :binary.bin_to_list(run)
    lower = Enum.any?(bytes, &(&1 in ?a..?z))
    upper = Enum.any?(bytes, &(&1 in ?A..?Z))
    digits = Enum.any?(bytes, &(&1 in ?0..?9))

    case {lower, upper, digits} do
      {true, true, true} -> "mixed_digits"
      {true, true, false} -> "mixed"
      {true, false, true} -> "lower_digits"
      {false, true, true} -> "upper_digits"
      {true, false, false} -> "lower"
      {false, true, false} -> "upper"
      {false, false, true} -> "digits"
    end
  end
end
