defmodule Platform.Social.MetricCount do
  @moduledoc "Compact display of measured per-post counts."
  @spec format(non_neg_integer() | nil) :: String.t() | nil
  def format(nil), do: nil
  def format(count) when is_integer(count) and count < 1000, do: Integer.to_string(count)
  def format(count) when is_integer(count) and count < 1_000_000, do: compact(count, 1000, "k")
  def format(count) when is_integer(count), do: compact(count, 1_000_000, "M")

  defp compact(count, divisor, suffix) do
    value = :erlang.float_to_binary(count / divisor, decimals: 1)
    String.trim_trailing(value, ".0") <> suffix
  end
end
