defmodule PlatformWeb.CommandPalette.Rank do
  @moduledoc """
  The command palette's ranking (Burrow redesign 23, stage 1): one pure,
  deterministic function over `PlatformWeb.CommandPalette.Sources.load/1`'s
  items. Kept as the single function `rank/2` so a later rung can register
  it as an experiment subject.

  An empty (or blank) query returns the first 14 items in Sources order;
  there is no Recent list. Otherwise the query is downcased and trimmed and
  every item takes the best tier it reaches:

    * 0: the label starts with the query;
    * 1: a label word starts with it (a word starts after a space, `-`, `_`,
      `#`, `·` or `/`), or one of the item's `terms` does;
    * 2: the label contains it;
    * 3: the item's kind contains it.

  Within a tier: kind order (module, space, direct, canvas, settings, then
  archived), then the shorter label, then the downcased label, then Sources
  order. Archived channels only enter when no other item reaches tiers 0-2.
  At most 14 items come back.

  Matching reads the label exactly as Sources built it, so a masked channel
  matches its placeholder and never its real name.
  """

  @limit 14
  @kind_order %{
    "module" => 0,
    "space" => 1,
    "direct" => 2,
    "canvas" => 3,
    "settings" => 4,
    "archived" => 5
  }
  @word_break ~r/[\s\-_#·\/]/u

  @doc "Rank `items` for `query`; at most #{@limit} come back. See the moduledoc."
  @spec rank([map()], String.t() | nil) :: [map()]
  def rank(items, query) do
    case query |> to_string() |> String.trim() |> String.downcase() do
      "" -> Enum.take(items, @limit)
      q -> ranked(items, q)
    end
  end

  defp ranked(items, q) do
    scored =
      items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} ->
        case tier(item, q) do
          nil -> []
          tier -> [{sort_key(item, tier, index), item}]
        end
      end)

    {archived, active} = Enum.split_with(scored, fn {_key, item} -> item.kind == "archived" end)

    candidates =
      if Enum.any?(active, fn {{tier, _, _, _, _}, _} -> tier <= 2 end),
        do: active,
        else: active ++ archived

    candidates
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(@limit)
    |> Enum.map(&elem(&1, 1))
  end

  defp tier(item, q) do
    label = String.downcase(item.label || "")

    cond do
      String.starts_with?(label, q) -> 0
      word_start?(label, q) or term_start?(item, q) -> 1
      String.contains?(label, q) -> 2
      String.contains?(item.kind, q) -> 3
      true -> nil
    end
  end

  defp word_start?(label, q) do
    @word_break
    |> Regex.scan(label, return: :index)
    |> Enum.any?(fn [{at, len}] ->
      from = at + len
      label |> binary_part(from, byte_size(label) - from) |> String.starts_with?(q)
    end)
  end

  defp term_start?(item, q),
    do: Enum.any?(item.terms || [], &String.starts_with?(String.downcase(&1), q))

  defp sort_key(item, tier, index) do
    label = item.label || ""

    {tier, Map.get(@kind_order, item.kind, map_size(@kind_order)), String.length(label),
     String.downcase(label), index}
  end
end
