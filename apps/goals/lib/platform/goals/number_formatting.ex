defmodule Platform.Goals.NumberFormatting do
  @moduledoc "Shared display formatting for goal numbers and notebook receipts."

  def format(nil), do: "not set"

  def format(n) when is_binary(n), do: format(Decimal.new(n))

  def format(n) when is_float(n), do: format(Decimal.from_float(n))

  def format(n) when is_integer(n), do: format(Decimal.new(n))

  def format(%Decimal{} = n) do
    text = n |> Decimal.normalize() |> Decimal.to_string(:normal)
    {sign, text} = if String.starts_with?(text, "-"), do: {"-", tail(text)}, else: {"", text}

    case String.split(text, ".", parts: 2) do
      [int] -> sign <> group(int)
      [int, frac] -> sign <> group(int) <> "." <> frac
    end
  end

  defp tail("-" <> rest), do: rest

  defp group(int) do
    int
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
