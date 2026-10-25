defmodule Platform.Theming.PresetParser do
  @moduledoc """
  Compile-time parser behind `Platform.Theming.Presets` (task 01a1557a-fe9b
  stage 1): reads the shipped preset blocks out of `theme_presets.css` and
  app.css through `Platform.Design.ThemeBlocks` and maps each back to the
  masters' theme keys. Raises on any block or token it cannot read, so a
  stylesheet edit that breaks the mapping fails the build, not a page.
  """

  alias Platform.Accounts.ThemePreference
  alias Platform.Design.ThemeBlocks
  alias Platform.Design.WcagContrast, as: W
  alias Platform.Theming.Tokens

  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/

  @doc "Every shipped preset, parsed from the two stylesheets' text."
  def parse(presets_css, app_css) do
    blocks = ThemeBlocks.preset_blocks(presets_css)

    for %{id: id, name: name} <- ThemePreference.presets() do
      variants =
        for mode <- ["light", "dark"], into: %{} do
          block =
            if id == ThemePreference.base_preset(),
              do: ThemeBlocks.burrow_block(app_css, mode),
              else:
                Enum.find(blocks, &(&1.id == id and &1.mode == mode)) ||
                  raise(ArgumentError, "theme_presets.css has no #{id} #{mode} block")

          {mode, variant(id, block)}
        end

      %{
        id: id,
        name: name,
        default_mode: "dark",
        light: masters(variants["light"], "light"),
        dark: masters(variants["dark"], "dark"),
        shape: shape(variants),
        variants: variants
      }
    end
  end

  # ── parsing ─────────────────────────────────────────────────────────────

  defp variant(id, block) do
    colors =
      for slot <- Tokens.color_slots(), into: %{} do
        case ThemeBlocks.resolve(block, slot) do
          {:ok, color} -> {slot, color |> W.to_hex() |> String.downcase()}
          {:error, reason} -> raise ArgumentError, reason
        end
      end

    %{
      preset_id: id,
      colors: colors,
      subtle: subtle(block),
      shape: %{
        "--radius-box" => px(decl!(block, "--radius-box")),
        "--radius-field" => px(decl!(block, "--radius-field")),
        "--font-sans" => decl!(block, "--font-sans"),
        "--density" => ThemeBlocks.declaration(block.decls, "--density") || "1",
        "--glass-alpha" => decl!(block, "--glass-alpha"),
        "--glass-blur" => decl!(block, "--glass-blur")
      }
    }
  end

  defp subtle(block) do
    value = decl!(block, "--subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] -> String.to_integer(pct)
      nil -> raise ArgumentError, "#{block.id} #{block.mode}: --subtle is #{inspect(value)}"
    end
  end

  defp decl!(block, var) do
    ThemeBlocks.declaration(block.decls, var) ||
      raise ArgumentError, "#{block.id} #{block.mode}: no #{var} declared"
  end

  # "12px" stays; "0.75rem" becomes "12px" (16px root).
  defp px(value) do
    case Regex.run(~r/^(\d+(?:\.\d+)?)(px|rem)$/, value) do
      [_, n, "px"] -> "#{round(to_number(n))}px"
      [_, n, "rem"] -> "#{round(to_number(n) * 16)}px"
      nil -> raise ArgumentError, "not a px or rem length: #{inspect(value)}"
    end
  end

  defp to_number(text) do
    {n, ""} = Float.parse(text)
    n
  end

  # The master keys, plus every slot the block declares apart from what the
  # master keys alone would paint (stage 6: agent text, the -content slots,
  # the focus ring), so a draft seeded from the preset paints as the block.
  defp masters(%{colors: colors}, mode) do
    keys =
      for {key, [slot | _]} <- Tokens.master_slots(),
          into: %{},
          do: {key, Map.fetch!(colors, slot)}

    base = Tokens.base_colors(keys, mode)

    overrides =
      for {key, slot} <- Tokens.override_slots(),
          Map.fetch!(colors, slot) != Map.fetch!(base, slot),
          into: %{},
          do: {key, Map.fetch!(colors, slot)}

    Map.merge(keys, overrides)
  end

  defp shape(%{"light" => light, "dark" => dark}) do
    alpha = max(to_number(light.shape["--glass-alpha"]), to_number(dark.shape["--glass-alpha"]))

    %{
      "radius" =>
        light.shape["--radius-box"] |> String.trim_trailing("px") |> String.to_integer(),
      "density" => to_number(light.shape["--density"]),
      "glass_alpha" => alpha,
      "glass_blur" =>
        light.shape["--glass-blur"] |> String.trim_trailing("px") |> String.to_integer(),
      "font" => light.shape["--font-sans"]
    }
  end
end
