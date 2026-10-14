defmodule Platform.Branding.PaletteTest do
  @moduledoc """
  Task 01a0dbee-f598-7001-b450-7890103f44c4 stage 1. `Platform.Branding.Palette`
  derives the semantic theme tokens from three admin-chosen colours per mode
  and says which pairings the result puts at risk.

  The defaults are pinned against `app.css` by PARSING it, with the same
  theme-block extraction `primary_contrast_sweep_test.exs` uses, so the hexes
  in `suite_defaults/0` cannot drift from the stylesheet. Every other clause
  asserts a THRESHOLD over the derived map, not a hex, because the point of
  derivation is that its output is legible for colours nobody typed in here.
  """
  use ExUnit.Case, async: true

  alias Platform.Branding.Contrast, as: C
  alias Platform.Branding.Palette
  alias Platform.Design.WcagContrast, as: W

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  setup_all do
    css = File.read!(@css_path)
    {:ok, light: theme_block!(css, "light"), dark: theme_block!(css, "dark")}
  end

  # ── Defaults are app.css ─────────────────────────────────────────────────

  describe "suite_defaults/0 is what app.css declares" do
    test "light and dark action, accent and surface equal the theme declarations", ctx do
      defaults = Palette.suite_defaults()

      for mode <- [:light, :dark] do
        block = Map.fetch!(ctx, mode)
        d = Map.fetch!(defaults, mode)

        assert d.action == hex_of!(block, "--color-primary"), "#{mode} action drifted"
        assert d.accent == hex_of!(block, "--color-accent"), "#{mode} accent drifted"
        assert d.surface == hex_of!(block, "--color-base-100"), "#{mode} surface drifted"
      end
    end

    test "the near-white body text is the dark theme's --color-base-content", %{dark: dark} do
      assert Palette.near_white() == hex_of!(dark, "--color-base-content")
    end

    test "the body-text candidates are each theme's --color-base-content", ctx do
      for mode <- [:light, :dark] do
        assert Map.fetch!(Palette.body_text(), mode) ==
                 hex_of!(Map.fetch!(ctx, mode), "--color-base-content"),
               "#{mode} body text drifted from app.css"
      end
    end

    # Since the Burrow recolor (task 01a120c5) the status tokens are hex
    # literals, and light and dark carry different ones a few degrees apart
    # in hue, so the declared hue is computed, and pinned within 3 degrees.
    test "the guarded status hues are the hues app.css declares, in both themes", ctx do
      for mode <- [:light, :dark], {status, hue} <- Palette.status_hues() do
        value = decl!(Map.fetch!(ctx, mode), "--color-#{status}")
        {_l, _c, declared} = value |> W.parse!() |> W.to_hex() |> C.to_oklch()

        assert C.hue_distance(declared, hue) <= 3.0,
               "#{mode} #{status} hue drifted: #{value} is #{Float.round(declared, 1)} degrees, " <>
                 "Palette guards #{hue}"
      end
    end
  end

  describe "the Suite defaults produce zero blocks" do
    for mode <- [:light, :dark] do
      test "#{mode}" do
        blocks = Enum.filter(Palette.checks(unquote(mode), %{}), &(&1.level == :block))
        assert blocks == []
      end
    end

    test "the light Burrow orange passes visibility at 5.32:1 and rings with itself" do
      [vis] = Enum.filter(Palette.checks(:light, %{}), &(&1.id == :action_visibility))
      assert vis.level == :pass
      assert Float.round(vis.ratio, 4) == 5.3202

      tokens = Palette.derive(:light, %{})
      assert tokens["--focus-ring"] == "#ad4b07"
    end

    test "derived base-content is each theme's own, and dark rings with the action" do
      light = Palette.derive(:light, %{})
      dark = Palette.derive(:dark, %{})

      assert light["--color-base-content"] == "#000000"
      assert dark["--color-base-content"] == "#eeeff1"
      assert dark["--focus-ring"] == "#f47721"
    end

    # The lightness steps were deliberately NOT retuned by the Burrow recolor:
    # they shape the greys derived for an admin-chosen surface, and moving them
    # would repaint installs that already saved a palette. A white surface
    # still steps to exactly the pre-Burrow light greys.
    test "a white surface still steps to exactly #f2f2f2 and #d7d7d7" do
      tokens = Palette.derive(:light, %{surface: "#ffffff"})
      assert tokens["--color-base-200"] == "#f2f2f2"
      assert tokens["--color-base-300"] == "#d7d7d7"
    end
  end

  # ── Derivation meets its thresholds for colours nobody chose ─────────────

  describe "derived tokens meet their thresholds over a random sweep" do
    test "primary-content, accent-content, interactive, focus ring and edge" do
      :rand.seed(:exsss, {1, 2, 3})

      for _ <- 1..300, mode <- [:light, :dark] do
        colours = %{action: random_hex(), surface: random_hex(), accent: random_hex()}
        t = Palette.derive(mode, colours)
        label = "#{mode} #{inspect(colours)}"

        # A label on a fill picks black or white; one of them always clears.
        assert C.ratio(t["--color-primary-content"], t["--color-primary"]) >= 4.5, label
        assert C.ratio(t["--color-accent-content"], t["--color-accent"]) >= 4.5, label

        # Link text: primary is fill-only, interactive is the text colour.
        assert C.ratio(t["--color-interactive"], t["--color-base-100"]) >= 4.5, label

        # The edge is visible.
        assert C.ratio(t["--edge"], t["--color-base-100"]) >= 1.2, label

        # Focus ring clears 3:1 on all three grounds wherever that is possible
        # at all, and checks/2 says so when it is not.
        ring_min =
          ["--color-base-100", "--color-base-200", "--color-base-300"]
          |> Enum.map(&C.ratio(t["--focus-ring"], t[&1]))
          |> Enum.min()

        [ring] = Enum.filter(Palette.checks(mode, colours), &(&1.id == :focus_ring))
        assert ring_min >= 3.0 or ring.level == :warn, label

        # Body text: either it clears or the palette is BLOCKED. Never a
        # silent unreadable page.
        body = C.ratio(t["--color-base-content"], t["--color-base-100"])
        assert body >= 4.5 or Palette.blocked?(mode, colours), label
      end
    end

    test "the edge keeps today's direction: darker in light, lighter in dark" do
      :rand.seed(:exsss, {4, 5, 6})

      for _ <- 1..200 do
        light = Palette.derive(:light, %{surface: random_hex(0.3, 1.0)})
        dark = Palette.derive(:dark, %{surface: random_hex(0.0, 0.7)})

        assert C.luminance(light["--edge"]) < C.luminance(light["--color-base-100"])
        assert C.luminance(dark["--edge"]) > C.luminance(dark["--color-base-100"])
      end
    end

    test "light interactive is DARKER than the action, dark interactive LIGHTER" do
      light = Palette.derive(:light, %{action: "#06d5ed"})
      assert C.luminance(light["--color-interactive"]) < C.luminance("#06d5ed")

      dark = Palette.derive(:dark, %{action: "#0a4a8a"})
      assert C.luminance(dark["--color-interactive"]) > C.luminance("#0a4a8a")
    end

    test "a nil accent follows the action" do
      t = Palette.derive(:light, %{action: "#5e81ac", accent: nil})
      assert t["--color-accent"] == "#5e81ac"
    end

    test "status, neutral and secondary tokens are never derived" do
      keys = Palette.derive(:light, %{}) |> Map.keys()

      for forbidden <- ~w(info success warning error neutral secondary pipeline-human) do
        refute Enum.any?(keys, &String.starts_with?(&1, "--color-#{forbidden}")), forbidden
      end
    end
  end

  # ── checks/2 ─────────────────────────────────────────────────────────────

  describe "checks/2" do
    test "a mid-grey surface BLOCKS: neither black nor the near-white reads on it" do
      for mode <- [:light, :dark] do
        [body] = Enum.filter(Palette.checks(mode, %{surface: "#707070"}), &(&1.id == :body_text))

        assert body.level == :block
        assert body.ratio < 4.5

        assert body.message ==
                 "Body text on this surface is 4.3:1. It needs 4.5:1 to be readable."

        assert Palette.blocked?(mode, %{surface: "#707070"})
      end
    end

    test "a pale action on white WARNS as a non-text element, and does not block" do
      checks = Palette.checks(:light, %{action: "#fff0a0", surface: "#ffffff"})
      [vis] = Enum.filter(checks, &(&1.id == :action_visibility))

      assert vis.level == :warn
      assert vis.ratio < 3.0

      assert vis.message ==
               "The action colour is #{:erlang.float_to_binary(Float.floor(vis.ratio * 10) / 10, decimals: 1)}:1 " <>
                 "against the surface. Buttons will be hard to see as outlines; the focus " <>
                 "ring has been adjusted separately."

      refute Palette.blocked?(:light, %{action: "#fff0a0", surface: "#ffffff"})
    end

    test "a green action warns, naming success" do
      checks = Palette.checks(:light, %{action: "#10b981"})
      [collision] = Enum.filter(checks, &(&1.id == :collides_with_success))

      assert collision.level == :warn
      assert collision.message =~ "success"
      refute Enum.any?(checks, &(&1.id in [:collides_with_error, :collides_with_info]))
    end

    test "a red action warns naming error, an amber one naming warning" do
      assert Enum.any?(
               Palette.checks(:dark, %{action: "#e53935"}),
               &(&1.id == :collides_with_error)
             )

      assert Enum.any?(
               Palette.checks(:dark, %{action: "#f59e0b"}),
               &(&1.id == :collides_with_warning)
             )
    end

    test "a grey action collides with nothing, whatever its nominal hue" do
      refute Enum.any?(
               Palette.checks(:light, %{action: "#6b6f72"}),
               &(&1.id |> Atom.to_string() |> String.starts_with?("collides_with_"))
             )
    end

    test "every check has the documented shape" do
      for check <- Palette.checks(:light, %{action: "#10b981", surface: "#707070"}) do
        assert %{id: id, level: level, ratio: _, message: message} = check
        assert is_atom(id)
        assert level in [:pass, :warn, :block]
        assert is_binary(message) and message != ""
      end
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp random_hex(lo \\ 0.0, hi \\ 1.0) do
    "#" <>
      Enum.map_join(1..3, fn _ ->
        v = round((lo + :rand.uniform() * (hi - lo)) * 255)
        v |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase()
      end)
  end

  # The declared value as a lowercase #rrggbb, resolved through the reference
  # converter so an oklch() declaration pins by what it renders.
  defp hex_of!(block, token) do
    block |> decl!(token) |> W.parse!() |> W.to_hex() |> String.downcase()
  end

  # Same extraction as primary_contrast_sweep_test.exs: the body of a
  # `@plugin "../vendor/daisyui-theme" { ... }` block chosen by its `name:`
  # line, split on a `}` at column 0.
  defp theme_block!(css, name) do
    css
    |> String.split(~s(@plugin "../vendor/daisyui-theme" {))
    |> Enum.drop(1)
    |> Enum.map(&(&1 |> String.split(~r/^\}/m, parts: 2) |> hd()))
    |> Enum.find(&Regex.match?(~r/name:\s*"#{name}"/, &1))
    |> case do
      nil -> flunk("no daisyui-theme block named #{inspect(name)} in #{@css_path}")
      block -> block
    end
  end

  defp decl!(block, token) do
    re = ~r/^[^\S\n]*#{Regex.escape(token)}:[^\S\n]*([^;\n]+);/m

    case Regex.run(re, block, capture: :all_but_first) do
      [value] -> String.trim(value)
      nil -> flunk("no `#{token}:` declaration in the theme block being read.")
    end
  end
end
