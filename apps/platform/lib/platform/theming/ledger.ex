defmodule Platform.Theming.Ledger do
  @moduledoc """
  The contrast ledger of one theme variant (task 01a1557a-fe9b stage 1), behind
  `Platform.Theming.ledger/2`.

  Two parts, in order:

    1. every row of `Platform.Theming.ContrastPairs.rows/1`, the pairs and
       floors that hold the shipped presets, measured exactly as the guards
       measure them (`WcagContrast.contrast/2` for solid pairs, the worst
       painted pixel of `PaintedComposite.contrast_min/3` for reduced-strength
       ink);
    2. the per-group rows the masters' editor paints (`paintContrast` in the
       masters' `theme.html`, beside `theme.js`), with their labels verbatim,
       held to 4.5:1, its AA verdict. Rows that read a key with no app slot
       (`faint`, `bubbleMe`) are left out. An agent row measures the slot the
       app paints agent text with, `--ag-<id>-text`.

  `ratio` is FLOORED to two decimals, never rounded: 4.497 reads 4.49 and
  fails a 4.5 floor, where rounding would show a passing 4.50. `pass?` is
  decided on that floored figure.
  """

  alias Platform.Design.PaintedComposite
  alias Platform.Design.WcagContrast, as: W
  alias Platform.Theming.ContrastPairs
  alias Platform.Theming.Tokens

  @type row :: %{
          label: String.t(),
          fg: String.t(),
          bg: String.t(),
          ratio: float(),
          floor: float(),
          pass?: boolean()
        }

  # paintContrast's groups, master key => app slot through the token mapping.
  @master_rows [
                 {"Primary on base", "ink", "ground"},
                 {"Primary on raised", "ink", "surface"},
                 {"Primary on overlay", "ink", "raised"},
                 {"Secondary on base", "muted", "ground"},
                 {"Secondary on raised", "muted", "surface"},
                 {"Accent on base", "accent", "ground"},
                 {"Accent on raised", "accent", "surface"},
                 {"Interactive on base", "interactive", "ground"},
                 {"On-accent on accent", "onAccent", "accent"},
                 {"Teal on base", "agTeal", "ground"},
                 {"Teal on raised", "agTeal", "surface"},
                 {"Green on base", "agGreen", "ground"},
                 {"Green on raised", "agGreen", "surface"},
                 {"Amber on base", "agAmber", "ground"},
                 {"Amber on raised", "agAmber", "surface"},
                 {"Orange on base", "agOrange", "ground"},
                 {"Orange on raised", "agOrange", "surface"}
               ] ++
                 for(
                   name <- ~w(Blue Purple Brick Rose Indigo Lime),
                   do: {"#{name} on raised", "ag" <> name, "surface"}
                 ) ++
                 [
                   {"Info on raised", "info", "surface"},
                   {"Success on raised", "active", "surface"},
                   {"Warning on raised", "warning", "surface"},
                   {"Error on raised", "danger", "surface"}
                 ]

  @doc "The masters' per-group rows: `[{label, fg_key, bg_key}]`."
  def master_rows, do: @master_rows

  @doc "The ledger of `theme` in `mode`."
  @spec ledger(map(), String.t()) :: [row()]
  def ledger(theme, mode) do
    v = Tokens.variant(theme, mode)
    color = fn slot -> Map.fetch!(v.colors, slot) end

    pair_rows =
      for row <- ContrastPairs.rows(v.preset_id) do
        fg = color.(row.fg)
        bg = color.(row.bg)
        measured(row.label, fg, bg, ratio(row.paint, fg, bg, v.subtle), row.floor)
      end

    slot_of = Map.new(Tokens.master_slots(), fn {key, [slot | _]} -> {key, slot} end)

    text_slot_of =
      Map.new(Tokens.master_slots(), fn {key, slots} -> {key, text_slot(key, slots)} end)

    group_rows =
      for {label, fg_key, bg_key} <- @master_rows do
        fg = color.(Map.fetch!(text_slot_of, fg_key))
        bg = color.(Map.fetch!(slot_of, bg_key))
        measured(label, fg, bg, W.contrast(W.hex(fg), W.hex(bg)), ContrastPairs.aa_text())
      end

    pair_rows ++ group_rows
  end

  @doc "A ratio floored to two decimals."
  @spec floor2(number()) :: float()
  def floor2(ratio), do: Float.floor(ratio / 1, 2)

  defp measured(label, fg, bg, raw, floor) do
    ratio = floor2(raw)
    %{label: label, fg: fg, bg: bg, ratio: ratio, floor: floor, pass?: ratio >= floor}
  end

  # An agent colour is painted as text through its `--ag-<id>-text` slot.
  defp text_slot("ag" <> _, [_rail, text]), do: text
  defp text_slot(_key, [slot | _]), do: slot

  defp ratio(:solid, fg, bg, _subtle), do: W.contrast(W.hex(fg), W.hex(bg))

  defp ratio({:painted, strength}, fg, bg, subtle) do
    pct = if strength == :subtle, do: subtle, else: strength
    elem(PaintedComposite.contrast_min(W.hex(fg), W.hex(bg), pct), 0)
  end
end
