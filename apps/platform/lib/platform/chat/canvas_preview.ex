defmodule Platform.Chat.CanvasPreview do
  @moduledoc """
  What a chat card can say about a canvas from the document it already has
  in hand (link previews stage 1): the image nodes' sources in document
  order, and how many prototype and card nodes it holds, for the "6 options ·
  tap to open" hint.

  Pure: it walks the map and nothing else. A prototype or card node counts
  once and is not descended into, so a card holding cards is one option.
  """

  @max_images 3

  @type summary :: %{
          images: [String.t()],
          prototypes: non_neg_integer(),
          cards: non_neg_integer()
        }

  @doc "The summary of a canvas document (`%{\"root\" => node}`); empty for anything else."
  @spec summary(map() | nil) :: summary()
  def summary(%{"root" => root}) when is_map(root) do
    acc = walk(root, %{images: [], prototypes: 0, cards: 0})
    %{acc | images: acc.images |> Enum.reverse() |> Enum.take(@max_images)}
  end

  def summary(_document), do: %{images: [], prototypes: 0, cards: 0}

  defp walk(%{"type" => "image", "props" => %{"src" => src}}, acc) when is_binary(src),
    do: %{acc | images: [src | acc.images]}

  defp walk(%{"type" => "prototype"}, acc), do: %{acc | prototypes: acc.prototypes + 1}

  defp walk(%{"type" => "card"} = node, acc) do
    # A card's own images still count as the canvas's images.
    acc = %{acc | cards: acc.cards + 1}
    node |> children() |> Enum.reduce(acc, &images_only/2)
  end

  defp walk(node, acc), do: node |> children() |> Enum.reduce(acc, &walk/2)

  defp images_only(%{"type" => "image", "props" => %{"src" => src}}, acc) when is_binary(src),
    do: %{acc | images: [src | acc.images]}

  defp images_only(node, acc), do: node |> children() |> Enum.reduce(acc, &images_only/2)

  defp children(%{"children" => children}) when is_list(children),
    do: Enum.filter(children, &is_map/1)

  defp children(_node), do: []
end
