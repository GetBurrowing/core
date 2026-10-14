defmodule Platform.Branding.ContrastTest do
  @moduledoc """
  Task 01a0dbee-f598-7001-b450-7890103f44c4 stage 1. `Platform.Branding.Contrast`
  is the runtime twin of the test-support `Platform.Design.WcagContrast`; this
  file holds the two to each other and to the figures `app.css` records.
  """
  use ExUnit.Case, async: true

  alias Platform.Branding.Contrast, as: C
  alias Platform.Design.WcagContrast, as: W

  doctest Platform.Branding.Contrast

  describe "agrees with Platform.Design.WcagContrast" do
    # Figures app.css records, computed by focus_ring_slot_test.exs and
    # primary_contrast_sweep_test.exs through the reference module: three
    # Burrow pairs (task 01a120c5) and the three pre-Burrow ones they replaced.
    for {a, b, expected} <- [
          {"#AD4B07", "#FBFAF9", 5.3202},
          {"#8B3B04", "#FBFAF9", 7.3919},
          {"#F47721", "#191B20", 6.1588},
          {"#06D5ED", "#FFFFFF", 1.7875},
          {"#087F93", "#FFFFFF", 4.7007},
          {"#06D5ED", "#171B25", 9.6304}
        ] do
      test "#{a} on #{b} is #{expected} to 4 dp" do
        {:ok, a} = C.normalize_hex(unquote(a))
        {:ok, b} = C.normalize_hex(unquote(b))
        assert Float.round(C.ratio(a, b), 4) == unquote(expected)
      end
    end

    @fixed ~w(#000000 #ffffff #06d5ed #087f93 #171b25 #4dd7e8 #767676 #d7d7d7 #f2f2f2
              #10b981 #f59e0b #ef4444 #2e3440 #88c0d0 #b48ead #123456 #fedcba #7f7f7f
              #ad4b07 #f47721 #8b3b04 #ff9b55 #fbfaf9 #191b20 #221f1b #eeeff1)

    test "ratio/2 matches the reference on every pair of a fixed set" do
      for a <- @fixed, b <- @fixed do
        assert_in_delta C.ratio(a, b), W.contrast(W.hex(a), W.hex(b)), 1.0e-12, "#{a} vs #{b}"
      end
    end

    test "to_oklch/1 then from_oklch/1 round-trips every hex in the set" do
      for hex <- @fixed do
        assert C.from_oklch(C.to_oklch(hex)) == hex, hex
      end
    end

    test "to_oklch/1 agrees with the reference's Oklab" do
      for hex <- @fixed do
        {l, c, h} = C.to_oklch(hex)
        {rl, ra, rb} = W.to_oklab(W.hex(hex))
        assert_in_delta l, rl, 1.0e-9
        assert_in_delta c, :math.sqrt(ra * ra + rb * rb), 1.0e-9

        if c > 1.0e-4 do
          ref_h = :math.atan2(rb, ra) * 180 / :math.pi()
          assert_in_delta C.hue_distance(h, ref_h), 0.0, 1.0e-6
        end
      end
    end
  end

  describe "exact clauses" do
    test "black on white is 21, self-contrast is 1" do
      assert C.ratio("#000000", "#ffffff") == 21.0
      assert C.ratio("#06d5ed", "#06d5ed") == 1.0
    end

    test "an out-of-gamut request keeps lightness and hue, gives up chroma" do
      hex = C.from_oklch({0.8, 0.5, 209.0})
      {l, c, h} = C.to_oklch(hex)
      assert_in_delta l, 0.8, 0.01
      assert c < 0.5
      assert C.hue_distance(h, 209.0) < 3.0
    end

    test "hue_distance/2 wraps round 360" do
      assert C.hue_distance(350, 10) == 20.0
      assert C.hue_distance(10, 350) == 20.0
      assert C.hue_distance(0, 180) == 180.0
    end
  end

  describe "normalize_hex/1" do
    test "accepts #RGB and #RRGGBB, with or without #, any case, trimmed" do
      assert C.normalize_hex("#abc") == {:ok, "#aabbcc"}
      assert C.normalize_hex("ABC") == {:ok, "#aabbcc"}
      assert C.normalize_hex("  #06D5ED ") == {:ok, "#06d5ed"}
      assert C.normalize_hex("06d5ed") == {:ok, "#06d5ed"}
    end

    test "refuses anything else" do
      for bad <- ["", "#", "#abcd", "#12345", "#1234567", "red", "#ggg", "rgb(0,0,0)", nil, 12] do
        assert C.normalize_hex(bad) == :error, inspect(bad)
      end
    end
  end
end
