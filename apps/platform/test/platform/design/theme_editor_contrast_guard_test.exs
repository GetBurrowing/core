defmodule Platform.Design.ThemeEditorContrastGuardTest do
  @moduledoc """
  Holds the theme editor's own paint (`PlatformWeb.AdminThemesLive`, task
  01a1557a-fe9b stage 2) in all ten preset variants (Burrow, Midnight, Sand,
  Forest, High contrast; light and dark).

  ## Pairs and floors

  | pair                                                       | floor     |
  |------------------------------------------------------------|-----------|
  | base-content on base-100, base-200, base-300               | 4.5       |
  | --subtle on base-100 and base-200 (painted, worst pixel)   | 4.5       |
  | primary-content on primary (the modal's OK button)         | 4.5       |
  | focus ring (`focus-visible-ring`, --focus-ring) on base-100 | 3         |
  | success, warning and error dots on base-100                | 3         |
  | the same dots on base-200 (the groups' ground)             | 3         |
  | error (the Delete button's trash icon) on base-100         | 3         |
  | edge on base-100                                           | recorded  |

  The colours are each preset's declared variant
  (`Platform.Theming.Presets`, parsed from the stylesheets), so the guard
  measures what the blocks paint. --subtle is alpha over its ground, so it is
  painted on the worst pixel `Platform.Design.PaintedComposite` allows. If a
  pair fails, the token changes, never the floor.

  ## Structure

  The editor's source is read and shown to be the editor before anything is
  refuted in it: text colours are base-content and subtle only (plus
  primary-content on the primary fill, and the trash icon's error glyph), no
  hex literal, no hover outside `lg:hover:`, no base-content alpha.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.PaintedComposite, as: PC
  alias Platform.Design.WcagContrast, as: W
  alias Platform.Theming.Presets

  @source_path Path.expand("../../../lib/platform_web/live/admin_themes_live.ex", __DIR__)

  @text 4.5
  @ui 3.0

  defp variants do
    for preset <- Presets.all(), mode <- ["light", "dark"] do
      {"#{preset.id} #{mode}", Map.fetch!(preset.variants, mode)}
    end
  end

  defp c(v, slot), do: v.colors |> Map.fetch!(slot) |> W.hex()

  defp solid(v, fg, bg), do: W.contrast(c(v, fg), c(v, bg))

  defp painted(v, bg) do
    {r, _} = PC.contrast_min(c(v, "--color-base-content"), c(v, bg), v.subtle)
    r
  end

  defp pairs(v) do
    [
      {"base-content / base-100", @text, solid(v, "--color-base-content", "--color-base-100")},
      {"base-content / base-200", @text, solid(v, "--color-base-content", "--color-base-200")},
      {"base-content / base-300", @text, solid(v, "--color-base-content", "--color-base-300")},
      {"subtle / base-100 (painted)", @text, painted(v, "--color-base-100")},
      {"subtle / base-200 (painted)", @text, painted(v, "--color-base-200")},
      {"primary-content / primary", @text,
       solid(v, "--color-primary-content", "--color-primary")},
      {"focus-ring / base-100", @ui, solid(v, "--focus-ring", "--color-base-100")},
      {"success dot / base-100", @ui, solid(v, "--color-success", "--color-base-100")},
      {"warning dot / base-100", @ui, solid(v, "--color-warning", "--color-base-100")},
      {"error dot / base-100", @ui, solid(v, "--color-error", "--color-base-100")},
      {"success dot / base-200", @ui, solid(v, "--color-success", "--color-base-200")},
      {"warning dot / base-200", @ui, solid(v, "--color-warning", "--color-base-200")},
      {"error dot / base-200", @ui, solid(v, "--color-error", "--color-base-200")}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  test "every editor pair clears its floor in all ten variants; the table prints" do
    rows = for {name, v} <- variants(), do: {name, v, pairs(v)}
    assert length(rows) == 10

    labels = rows |> hd() |> elem(2) |> Enum.map(&elem(&1, 0))

    IO.puts(
      "\nTheme editor AA table (WCAG 2.x; --subtle painted on the worst pixel):\n" <>
        "| Variant | " <>
        Enum.join(labels ++ ["edge / base-100 (recorded)"], " | ") <>
        " |\n" <>
        Enum.map_join(rows, "\n", fn {name, v, ps} ->
          "| #{name} | " <>
            Enum.map_join(ps, " | ", fn {_, _, r} -> f4(r) end) <>
            " | " <> f4(solid(v, "--edge", "--color-base-100")) <> " |"
        end)
    )

    failures =
      for {name, _v, ps} <- rows, {label, floor, r} <- ps, r < floor do
        "#{name}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end

  test "edge on base-100 is recorded, not floored (a border beside text, not an indicator)" do
    for {_name, v} <- variants() do
      assert solid(v, "--edge", "--color-base-100") > 1.0
    end
  end

  describe "source" do
    setup do
      {:ok, source: File.read!(@source_path)}
    end

    test "anti-vacuity: the source read is the theme editor and paints these slots", %{
      source: source
    } do
      assert source =~ ~s(data-role="theme-editor")

      for slot <-
            ~w(bg-success bg-warning bg-error focus-visible-ring text-subtle text-base-content
                     bg-primary text-primary-content bg-base-100 bg-base-200 border-edge) do
        assert source =~ slot, "the editor no longer paints #{slot}; update the guard"
      end
    end

    test "text colours are base-content and subtle only", %{source: source} do
      text_slots =
        Regex.scan(
          ~r/(?<![\w-])text-(base-content|subtle|primary-content|primary|secondary|accent|neutral|info|success|warning|error|disabled|decorative|on-viewer)(?![\w-])/,
          source
        )
        |> Enum.map(fn [_, slot] -> slot end)
        |> Enum.frequencies()

      # Positive control: the scan finds both permitted slots.
      assert Map.has_key?(text_slots, "base-content")
      assert Map.has_key?(text_slots, "subtle")

      assert text_slots |> Map.keys() |> Enum.sort() ==
               ["base-content", "error", "primary-content", "subtle"]

      # text-error exactly once, on the Delete button's trash glyph.
      assert text_slots["error"] == 1
      assert source =~ ~s(<.icon name="hero-trash" class="size-3.5 text-error" />)
      # text-primary-content only on the primary fill.
      assert source =~ ~r/bg-primary [^"]*text-primary-content/
    end

    test "no hex literal, no bare hover, no base-content alpha", %{source: source} do
      assert source =~ "lg:hover:"
      refute Regex.match?(~r/#[0-9a-fA-F]{3,8}\b/, source)
      refute Regex.match?(~r/(?<![\w:-])hover:/, source)
      refute source =~ "text-base-content/"
      refute source =~ "String.to_atom("
    end
  end
end
