defmodule Platform.Goals.NumberAssertions do
  @moduledoc "Number-free refusal assertion shared by source and context tests."
  def number_free?(%Decimal{}), do: false
  def number_free?(%DateTime{}), do: false
  def number_free?(value) when is_number(value), do: false
  def number_free?(value) when is_binary(value), do: not Regex.match?(~r/[0-9]/, value)
  def number_free?(value) when is_tuple(value), do: value |> Tuple.to_list() |> number_free?()
  def number_free?(value) when is_list(value), do: Enum.all?(value, &number_free?/1)
  def number_free?(value) when is_map(value), do: value |> Map.to_list() |> number_free?()
  def number_free?(_), do: true
end
