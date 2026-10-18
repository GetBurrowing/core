defmodule Platform.Branding.ThemeCss do
  @moduledoc """
  The install's in-app theme colours as a runtime `<style>` block (task
  01a0dbee-f598-7001-b450-7890103f44c4 stage 2).

  The root layout emits `render/1`'s output in `<style id="install-theme">`
  immediately AFTER the `app.css` link, so every page re-themes from the
  stored row with no CSS rebuild and no deploy.

  ## Why a later block can override app.css at all

  The vendored `assets/vendor/daisyui-theme.js` plugin only calls `addBase`:
  it writes each theme's tokens as plain custom properties under the theme
  selectors and registers nothing with Tailwind. The colour utilities
  (`bg-primary`, `text-primary`, `btn-primary`, `border-edge`,
  `ring-focus-ring`) therefore read `var(--color-...)` at the element, and a
  later declaration at equal (or higher) specificity replaces the value they
  resolve to.

  ## The selectors, and why their ORDER is load-bearing

      :root:not([data-theme]),
        [data-theme="light"]:not([data-theme-preview])   light
      [data-theme="dark"]:not([data-theme-preview])      dark
      @media (prefers-color-scheme: dark) {
        :root:not([data-theme="light"]) { ... }      dark, OS preference
      }

  These mirror daisyUI's own selectors, so the explicit `data-theme` path and
  the OS-preference path both follow the stored row. With no `data-theme` on
  an OS-dark machine BOTH `:root:not([data-theme])` and the media block match
  at the same specificity (0,2,0); the media block wins only because it comes
  LAST. Reorder these and OS-dark users get the light palette.

  ## `:not([data-theme-preview])`

  The admin Branding page (stage 4) previews a DRAFT palette inside
  `data-theme="light"` / `"dark"` wrappers that carry `data-theme-preview`.
  Without the exclusion, a saved install theme would reach into a preview
  whose draft mode is all Burrow default and paint the saved colours there,
  because the preview's `data-theme` matches the same selector. The exclusion
  raises these two selectors to (0,2,0), which still beats daisyUI's own
  (0,1,0) theme selectors regardless of order and leaves the OS-dark
  tie-break above unchanged (neither half of that tie carries the
  exclusion's element).

  ## What is emitted

  Per mode with at least one stored slot, nil slots resolve to
  `Palette.suite_defaults/0` and `Palette.derive/2` produces the eleven
  tokens in `@tokens`. `--edge` and `--focus-ring` are the BACKING slots the
  `@theme inline` block maps; `--color-edge` / `--color-focus-ring` are never
  declared here, because declaring them makes that mapping self-referential
  and every `border-edge` / `ring-focus-ring` falls back to currentColor.
  `--color-interactive` is declared outside the daisy blocks in `app.css`, so
  it must be set here too or links keep the Burrow cyan. Status tokens (info,
  success, warning, error) are NEVER emitted: they carry meaning, not brand.

  A mode with every slot nil emits no block, and a row with all six nil
  renders nil: the page's CSS is then exactly `app.css`.

  ## Why `Phoenix.HTML.raw/1` on this output is safe

  Every value, stored AND derived, is re-validated as `#rrggbb` here at
  render time. A value that fails is dropped and logged, never interpolated,
  so nothing from the row other than a six-digit hex can reach the page. The
  selectors and property names are literals in this module.
  """

  require Logger

  alias Platform.Branding
  alias Platform.Branding.InstallBranding
  alias Platform.Branding.Palette

  @hex ~r/\A#[0-9a-f]{6}\z/

  @tokens [
    "--color-primary",
    "--color-primary-content",
    "--color-accent",
    "--color-accent-content",
    "--color-base-100",
    "--color-base-200",
    "--color-base-300",
    "--color-base-content",
    "--edge",
    "--focus-ring",
    "--color-interactive"
  ]

  @light_selector ~s|:root:not([data-theme]),[data-theme="light"]:not([data-theme-preview])|
  @dark_selector ~s|[data-theme="dark"]:not([data-theme-preview])|
  @os_dark_selector ~s|:root:not([data-theme="light"])|

  @doc "The custom properties a mode block declares, in emission order."
  @spec tokens() :: [String.t()]
  def tokens, do: @tokens

  @doc """
  The declarations one mode's block carries (`"--color-primary:#…;…"`), or
  nil when every slot is nil. `render/1` builds its blocks from this, and the
  admin page's draft preview puts the same string in an inline `style`, so the
  preview and the saved app cannot derive differently. Every value is
  re-validated as `#rrggbb`; see the moduledoc.
  """
  @spec mode_declarations(:light | :dark, map()) :: String.t() | nil
  def mode_declarations(mode, slots) when mode in [:light, :dark] do
    declarations(mode, sanitize_mode(mode, Map.take(slots, [:action, :surface, :accent])))
  end

  @doc """
  The runtime theme CSS for this row, or nil when no colour is stored.
  """
  @spec render(InstallBranding.t()) :: String.t() | nil
  def render(%InstallBranding{} = branding) do
    colours = Branding.app_colors(branding)

    light = mode_declarations(:light, colours.light)
    dark = mode_declarations(:dark, colours.dark)

    blocks =
      [
        light && "#{@light_selector}{#{light}}",
        dark && "#{@dark_selector}{#{dark}}",
        dark && "@media (prefers-color-scheme: dark){#{@os_dark_selector}{#{dark}}}"
      ]
      |> Enum.reject(&is_nil/1)

    if blocks == [], do: nil, else: Enum.join(blocks, "\n")
  end

  defp declarations(mode, slots) do
    if Enum.all?(Map.values(slots), &is_nil/1) do
      nil
    else
      tokens = Palette.derive(mode, slots)

      @tokens
      |> Enum.flat_map(fn name ->
        value = Map.get(tokens, name)

        if valid?(value) do
          ["#{name}:#{value};"]
        else
          Logger.warning("install theme: dropped derived #{name}=#{inspect(value)} (#{mode})")
          []
        end
      end)
      |> Enum.join()
    end
  end

  defp sanitize_mode(mode, slots) do
    Map.new(slots, fn
      {slot, nil} ->
        {slot, nil}

      {slot, value} ->
        normalized = if is_binary(value), do: String.downcase(value), else: value

        if valid?(normalized) do
          {slot, normalized}
        else
          Logger.warning(
            "install theme: dropped stored #{mode}_#{slot}=#{inspect(value)}, not #rrggbb"
          )

          {slot, nil}
        end
    end)
  end

  defp valid?(value) when is_binary(value), do: Regex.match?(@hex, value)
  defp valid?(_), do: false
end
