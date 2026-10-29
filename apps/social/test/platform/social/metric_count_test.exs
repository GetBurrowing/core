defmodule Platform.Social.MetricCountTest do
  use ExUnit.Case, async: true
  alias Platform.Social.MetricCount

  test "compact counts preserve zero and omit absent measurements" do
    for {count, expected} <- [
          {nil, nil},
          {0, "0"},
          {999, "999"},
          {1000, "1k"},
          {12400, "12.4k"},
          {1_000_000, "1M"},
          {2_340_000, "2.3M"}
        ] do
      assert MetricCount.format(count) == expected
    end
  end
end
