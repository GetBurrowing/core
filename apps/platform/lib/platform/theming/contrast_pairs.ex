defmodule Platform.Theming.ContrastPairs do
  @moduledoc """
  THE contrast pair list and floor set (task 01a1557a-fe9b stage 1).

  Before this module the list lived twice, as literal `@text_pairs` in
  `theme_presets_guard_test.exs` and `burrow_palette_guard_test.exs`, with the
  floors repeated beside each. Both guards now read it from here, and so does
  `Platform.Theming.ledger/2`, so the admin theme editor refuses to publish a
  palette on exactly the pairs that hold the shipped presets.

  ## The floors

    * `aa_text/0` — 4.5:1, WCAG 1.4.3 text;
    * `aaa_text/0` — 7:1, High contrast's full-strength text;
    * `non_text/0` — 3:1, WCAG 1.4.11, the focus ring.

  ## The pairs

    * `text_pairs/0` — the thirteen solid `{text, ground}` slot pairs both
      guards check;
    * `muted_pairs/0` — secondary (muted) text on each of the three grounds,
      which the preset guard adds;
    * `painted_rows/0` — base-content at reduced strength (`--subtle` at its
      block's own strength, and 60% for daisyUI `.label`), measured on the
      worst painted pixel `Platform.Design.PaintedComposite` allows;
    * `ring_pairs/0` — the focus ring on each ground, at the non-text floor.

  `rows/1` is all of them, labelled and floored, for one variant.
  """

  @aa_text 4.5
  @aaa_text 7.0
  @non_text 3.0

  @high_contrast "high-contrast"

  @grounds ["--color-base-100", "--color-base-200", "--color-base-300"]

  @text_pairs [
    {"--color-base-content", "--color-base-100"},
    {"--color-base-content", "--color-base-200"},
    {"--color-base-content", "--color-base-300"},
    {"--color-primary-content", "--color-primary"},
    {"--color-accent-content", "--color-accent"},
    {"--color-secondary-content", "--color-secondary"},
    {"--color-info-content", "--color-info"},
    {"--color-success-content", "--color-success"},
    {"--color-warning-content", "--color-warning"},
    {"--color-error-content", "--color-error"},
    {"--color-interactive", "--color-base-100"},
    {"--color-interactive", "--color-base-200"},
    {"--color-interactive", "--color-base-300"}
  ]

  # daisyUI's .label paints base-content at 60%.
  @sixty 60

  @type paint :: :solid | {:painted, :subtle | pos_integer()}
  @type row :: %{
          label: String.t(),
          fg: String.t(),
          bg: String.t(),
          paint: paint(),
          floor: float()
        }

  @doc "The WCAG AA text floor."
  def aa_text, do: @aa_text

  @doc "High contrast's text floor."
  def aaa_text, do: @aaa_text

  @doc "The non-text floor (the focus ring)."
  def non_text, do: @non_text

  @doc "The three grounds, base-100/200/300."
  def grounds, do: @grounds

  @doc "The thirteen solid `{text, ground}` pairs both guards check."
  def text_pairs, do: @text_pairs

  @doc "Secondary (muted) text on each ground."
  def muted_pairs, do: for(g <- @grounds, do: {"--color-secondary", g})

  @doc "Every solid text pair the preset guard checks: `text_pairs/0` plus `muted_pairs/0`."
  def preset_text_pairs, do: @text_pairs ++ muted_pairs()

  @doc "The strength (percent) daisyUI's `.label` paints base-content at."
  def sixty, do: @sixty

  @doc """
  The painted rows: `{strength, ground}`, where `strength` is `:subtle` (the
  block's own `--subtle` strength) or an integer percent.
  """
  def painted_rows, do: for(s <- [:subtle, @sixty], g <- @grounds, do: {s, g})

  @doc "The focus ring on each ground."
  def ring_pairs, do: for(g <- @grounds, do: {"--focus-ring", g})

  @doc "The full-strength text floor for a variant: 7:1 for High contrast, else 4.5:1."
  @spec text_floor(String.t() | nil) :: float()
  def text_floor(@high_contrast), do: @aaa_text
  def text_floor(_), do: @aa_text

  @doc """
  Every row for the variant whose preset id is `preset_id` (`nil` for an org
  theme), labelled and floored. Painted rows hold the AA floor in every
  variant, High contrast included, as the preset guard does.
  """
  @spec rows(String.t() | nil) :: [row()]
  def rows(preset_id) do
    text_floor = text_floor(preset_id)

    solid =
      for {fg, bg} <- preset_text_pairs(),
          do: %{
            label: "#{short(fg)} on #{short(bg)}",
            fg: fg,
            bg: bg,
            paint: :solid,
            floor: text_floor
          }

    painted =
      for {strength, bg} <- painted_rows() do
        label =
          case strength do
            :subtle -> "subtle on #{short(bg)}"
            pct -> "base-content at #{pct}% on #{short(bg)}"
          end

        %{
          label: label,
          fg: "--color-base-content",
          bg: bg,
          paint: {:painted, strength},
          floor: @aa_text
        }
      end

    rings =
      for {fg, bg} <- ring_pairs(),
          do: %{
            label: "focus-ring on #{short(bg)}",
            fg: fg,
            bg: bg,
            paint: :solid,
            floor: @non_text
          }

    solid ++ painted ++ rings
  end

  defp short("--color-" <> rest), do: rest
  defp short("--" <> rest), do: rest
end
