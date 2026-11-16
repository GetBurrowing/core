defmodule Platform.Goals.RetroVerdictTest do
  use ExUnit.Case, async: false
  alias Platform.Goals.Retro
  @today ~D[2026-02-07]

  for {prediction, actual, date, expected} <- [
        {"40", "40", @today, "came_true"},
        {"40", "39.9", @today, "did_not"},
        {"-5", "-6", @today, "came_true"},
        {"-5", "-4", @today, "did_not"},
        {"0", "0", @today, "came_true"},
        {"0", "1", @today, "did_not"},
        {nil, "100", @today, "not_scored"},
        {"40", :cannot_measure, @today, "cannot_measure"},
        {"40", nil, @today, "cannot_measure"},
        {"40", "100", ~D[2026-02-08], "too_early"},
        {nil, nil, ~D[2026-02-08], "too_early"},
        {"40", "100", nil, "not_scored"},
        {nil, nil, nil, "not_scored"}
      ] do
    test "verdict #{inspect({prediction, actual, date})} is #{expected}" do
      prediction = unquote(prediction)
      actual = unquote(actual)

      row = %{
        predicted_change: if(prediction, do: Decimal.new(prediction)),
        predicted_by: unquote(Macro.escape(date)),
        actual_change: if(is_binary(actual), do: Decimal.new(actual), else: actual)
      }

      assert Retro.verdict(row, @today) == unquote(expected)
    end
  end
end
