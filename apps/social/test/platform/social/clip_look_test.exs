defmodule Platform.Social.ClipLookTest do
  @moduledoc """
  Clip Studio 1/9 (task 01a16661-e234): the studio look, its show default,
  validation, merge, delta, and the translation to htc-clip-tool profile
  keys (the moduledoc table of `Platform.Social.ClipLook`).
  """
  use ExUnit.Case, async: true

  alias Platform.Social.ClipLook

  # Prototype 01a16628 v2 app.js SHOW_DEFAULT, with string keys.
  @show_default %{
    "cap" => %{
      "preset" => "bold-pop",
      "font" => "Anton",
      "size" => 5.8,
      "color" => "#FFFFFF",
      "outline" => true,
      "hl" => "#FFE000",
      "vpos" => 0.66
    },
    "title" => %{
      "font" => "Anton",
      "size" => 24,
      "box" => false,
      "twoLine" => true,
      "secs" => 3.0
    },
    "outro" => true,
    "music" => true,
    "level" => -18,
    "reframe" => "shots",
    "cutaways" => true
  }

  @no_equivalent ~w(title.font title.size title.box title.twoLine outro music level cutaways)

  test "caption styles are validated and map to the CLI style field independently of presets" do
    assert ClipLook.styles() == ["plain", "phrase-pop", "karaoke"]

    for style <- ["plain", "phrase-pop", "karaoke"] do
      assert {:ok, %{"cap" => %{"style" => ^style}}} = ClipLook.validate(%{cap: %{style: style}})

      assert ClipLook.to_clip_overrides(%{"cap" => %{"style" => style}}) ==
               %{"mapped" => %{"captions.style" => style}, "unmapped" => []}
    end

    assert {:error, _} = ClipLook.validate(%{cap: %{style: "bold-pop"}})
    assert ClipLook.caption_style(%{"cap" => %{"preset" => "bold-pop"}}) == "phrase-pop"
  end

  test "ClipLook.default matches the prototype SHOW_DEFAULT" do
    assert ClipLook.default() == @show_default
    assert ClipLook.presets() == ~w(bold-pop podcast-clean speaker-color)
  end

  describe "validate/1" do
    test "the default and a partial look are valid; atom keys come back as strings" do
      assert {:ok, @show_default} = ClipLook.validate(@show_default)
      assert {:ok, %{"cap" => %{"size" => 7.0}}} = ClipLook.validate(%{cap: %{size: 7.0}})
      assert {:ok, %{}} = ClipLook.validate(%{})
    end

    test "refuses an unknown key" do
      assert {:error, [msg]} = ClipLook.validate(%{"sparkle" => true})
      assert msg =~ "sparkle"
      assert {:error, [_]} = ClipLook.validate(%{"cap" => %{"glow" => 1}})
    end

    test "refuses an out-of-range size" do
      for size <- [0, -1, 20.5, "big"] do
        assert {:error, [msg]} = ClipLook.validate(%{"cap" => %{"size" => size}})
        assert msg =~ "cap.size"
      end

      assert {:ok, _} = ClipLook.validate(%{"cap" => %{"size" => 20}})
    end

    test "refuses every other bad value" do
      bad = [
        %{"cap" => %{"preset" => "neon"}},
        %{"cap" => %{"font" => "Comic Sans"}},
        %{"cap" => %{"color" => "white"}},
        %{"cap" => %{"color" => "#FFF"}},
        %{"cap" => %{"hl" => "red"}},
        %{"cap" => %{"vpos" => 0}},
        %{"cap" => %{"vpos" => 1}},
        %{"cap" => %{"outline" => "yes"}},
        %{"title" => %{"secs" => 601}},
        %{"title" => %{"secs" => -1}},
        %{"title" => %{"box" => 1}},
        %{"title" => %{"twoLine" => nil}},
        %{"level" => -31},
        %{"level" => -5},
        %{"reframe" => "split"},
        %{"outro" => "on"},
        %{"music" => 0},
        %{"cutaways" => "true"},
        %{"cap" => "big"},
        "not a map"
      ]

      for look <- bad, do: assert({:error, _} = ClipLook.validate(look), inspect(look))

      assert {:ok, _} = ClipLook.validate(%{"cap" => %{"hl" => "none", "font" => "Georgia Bold"}})
    end
  end

  describe "effective/1" do
    test "deep-merges a stored look over the default; nil and %{} give the default" do
      assert ClipLook.effective(nil) == @show_default
      assert ClipLook.effective(%{}) == @show_default

      merged = ClipLook.effective(%{"cap" => %{"size" => 7.0}, "music" => false})
      assert merged["cap"]["size"] == 7.0
      assert merged["cap"]["font"] == "Anton"
      assert merged["music"] == false
      assert merged["title"] == @show_default["title"]
    end
  end

  describe "delta/2" do
    test "identical looks give %{}" do
      assert ClipLook.delta(@show_default, @show_default) == %{}
      assert ClipLook.delta(ClipLook.effective(%{}), ClipLook.default()) == %{}
      # 24 and 24.0 are the same size
      assert ClipLook.delta(put_in(@show_default, ["title", "size"], 24.0), @show_default) == %{}
    end

    test "a cap.size change gives only that leaf" do
      look = ClipLook.effective(%{"cap" => %{"size" => 7.0}})
      assert ClipLook.delta(look, ClipLook.default()) == %{"cap" => %{"size" => 7.0}}
    end

    test "several leaves across sections" do
      look =
        ClipLook.effective(%{"title" => %{"box" => true}, "outro" => false, "reframe" => "fit"})

      assert ClipLook.delta(look, @show_default) == %{
               "title" => %{"box" => true},
               "outro" => false,
               "reframe" => "fit"
             }
    end
  end

  describe "to_clip_overrides/1" do
    test "cap.size 5.8 maps to captions.size_frac 0.058" do
      assert %{"mapped" => %{"captions.size_frac" => 0.058}, "unmapped" => []} =
               ClipLook.to_clip_overrides(%{"cap" => %{"size" => 5.8}})

      assert %{"mapped" => %{"captions.size_frac" => 0.07}} =
               ClipLook.to_clip_overrides(%{"cap" => %{"size" => 7.0}})
    end

    test "an empty delta has nothing mapped or unmapped" do
      assert ClipLook.to_clip_overrides(%{}) == %{"mapped" => %{}, "unmapped" => []}
      assert ClipLook.to_clip_overrides(nil) == %{"mapped" => %{}, "unmapped" => []}
    end

    test "every mapped key translates as the table says" do
      delta = %{
        "cap" => %{
          "preset" => "podcast-clean",
          "font" => "Inter SemiBold",
          "color" => "#00FF00",
          "outline" => false,
          "hl" => "#FF0000",
          "vpos" => 0.7
        },
        "title" => %{"secs" => 5.0},
        "reframe" => "splits"
      }

      assert ClipLook.to_clip_overrides(delta) == %{
               "mapped" => %{
                 "captions.preset" => "podcast-clean",
                 "captions.font" => "Inter-SemiBold.ttf",
                 "captions.primary_color" => "#00FF00",
                 "captions.stroke_frac" => 0.0,
                 "captions.highlight_color" => "#FF0000",
                 "captions.vpos" => 0.7,
                 "captions.hook_title_seconds" => 5.0,
                 "captions.hook_title" => true,
                 "reframe.mode" => "split"
               },
               "unmapped" => []
             }

      assert %{"mapped" => %{"captions.font" => "Anton-Regular.ttf", "reframe.mode" => "fit"}} =
               ClipLook.to_clip_overrides(%{"cap" => %{"font" => "Anton"}, "reframe" => "fit"})

      assert %{"mapped" => %{"reframe.mode" => "shots"}} =
               ClipLook.to_clip_overrides(%{"reframe" => "shots"})
    end

    test "every NO EQUIVALENT key lands in unmapped" do
      delta = %{
        "title" => %{"font" => "Georgia Bold", "size" => 30, "box" => true, "twoLine" => false},
        "outro" => false,
        "music" => false,
        "level" => -12,
        "cutaways" => false
      }

      assert ClipLook.to_clip_overrides(delta) == %{
               "mapped" => %{},
               "unmapped" => Enum.sort(@no_equivalent)
             }
    end

    test "the partial keys: unbundled fonts, hl none and outline true are unmapped" do
      for {delta, key} <- [
            {%{"cap" => %{"font" => "Inter Black"}}, "cap.font"},
            {%{"cap" => %{"font" => "Georgia Bold"}}, "cap.font"},
            {%{"cap" => %{"hl" => "none"}}, "cap.hl"},
            {%{"cap" => %{"outline" => true}}, "cap.outline"}
          ] do
        assert ClipLook.to_clip_overrides(delta) == %{"mapped" => %{}, "unmapped" => [key]}
      end
    end
  end
end
