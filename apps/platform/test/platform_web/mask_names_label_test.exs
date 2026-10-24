defmodule PlatformWeb.MaskNamesLabelTest do
  @moduledoc """
  Task 01a1600d stage 1: `PlatformWeb.MaskNamesLabel`, the one formatter for
  when screen-share name masking ends (Settings' helper and the shell chip).
  """

  use ExUnit.Case, async: true

  alias PlatformWeb.MaskNamesLabel

  @chicago "America/Chicago"

  test "same local day: the clock time alone" do
    # 2026-10-21 14:00 CDT, ending 21:41 CDT the same day.
    now = ~U[2026-10-21 19:00:00Z]
    until = ~U[2026-10-22 02:41:00Z]
    assert MaskNamesLabel.until_text(until, @chicago, now) == "until 9:41 pm"
  end

  test "past local midnight: 'tomorrow'" do
    # 2026-10-21 21:41 CDT, ending 09:41 CDT on the 22nd.
    now = ~U[2026-10-22 02:41:00Z]
    until = ~U[2026-10-22 14:41:00Z]
    assert MaskNamesLabel.until_text(until, @chicago, now) == "until 9:41 am tomorrow"
  end

  test "the comparison is of LOCAL dates, not UTC dates" do
    # UTC dates differ (21st vs 22nd) but both instants are the 21st in Chicago.
    now = ~U[2026-10-21 20:00:00Z]
    until = ~U[2026-10-22 03:00:00Z]
    assert MaskNamesLabel.until_text(until, @chicago, now) == "until 10:00 pm"

    # UTC dates match (the 22nd) but Chicago crosses its midnight in between.
    now = ~U[2026-10-22 01:00:00Z]
    until = ~U[2026-10-22 13:00:00Z]
    assert MaskNamesLabel.until_text(until, @chicago, now) == "until 8:00 am tomorrow"
  end

  test "a nil or unknown zone prints UTC and says so" do
    now = ~U[2026-10-21 10:00:00Z]
    until = ~U[2026-10-21 14:41:00Z]
    assert MaskNamesLabel.until_text(until, nil, now) == "until 2:41 pm UTC"
    assert MaskNamesLabel.until_text(until, "Not/AZone", now) == "until 2:41 pm UTC"

    # The day comparison is UTC too.
    now = ~U[2026-10-21 20:00:00Z]
    until = ~U[2026-10-22 08:00:00Z]
    assert MaskNamesLabel.until_text(until, nil, now) == "until 8:00 am UTC tomorrow"
  end

  test "no end time is nil" do
    assert MaskNamesLabel.until_text(nil, @chicago, ~U[2026-10-21 10:00:00Z]) == nil
    assert MaskNamesLabel.until_text(nil, nil, ~U[2026-10-21 10:00:00Z]) == nil
  end

  test "12:05 am and 12:00 pm edges" do
    assert MaskNamesLabel.clock(~U[2026-10-21 00:05:00Z], nil) == "12:05 am UTC"
    assert MaskNamesLabel.clock(~U[2026-10-21 12:00:00Z], nil) == "12:00 pm UTC"

    # 12:05 am Chicago on the 22nd, from 1:00 pm on the 21st.
    now = ~U[2026-10-21 18:00:00Z]
    until = ~U[2026-10-22 05:05:00Z]
    assert MaskNamesLabel.until_text(until, @chicago, now) == "until 12:05 am tomorrow"

    # Noon Chicago, same day.
    now = ~U[2026-10-21 13:00:00Z]
    until = ~U[2026-10-21 17:00:00Z]
    assert MaskNamesLabel.until_text(until, @chicago, now) == "until 12:00 pm"
  end
end
