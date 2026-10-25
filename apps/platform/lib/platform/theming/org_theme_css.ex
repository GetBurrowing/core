defmodule Platform.Theming.OrgThemeCss do
  @moduledoc """
  The viewer's published org themes as a runtime `<style>` block (task
  01a1557a-fe9b stage 3).

  The root layout emits `render/1`'s output in
  `<style id="org-themes" data-role="org-themes">`, after
  `<style id="install-theme">`, for a signed-in viewer only, from
  `Platform.Theming.list_published_for_user/1`. Per theme and mode:

      [data-preset="org-<id>"][data-theme="dark"]:not([data-theme-preview]) { ... }

  the same (0,3,0) selector form `theme_presets.css` uses for the shipped
  presets, so an org theme beats the install theme block (0,2,0) and
  daisyUI's layered blocks exactly as a shipped preset does, and the picker's
  chips (which carry `data-preset` + `data-theme`) paint with it too.

  ## When a member sees a newly published theme

  On their next FULL page load. The root layout is rendered once per dead
  render; LiveView live navigation does not re-render it, so a tab that is
  already open keeps the blocks (and the theme boot's preset list) it loaded
  with. Pushing a publish into open tabs is out of scope.

  One exception (task 01a1557a stage 5): when the person SELECTS such a
  theme in the picker (which lists it after any live navigation remounts
  the shell), `PlatformWeb.ShellLive.put_theme/2` pushes `render/1` of that
  one theme as `burrow:org-theme`, and the ThemePicker hook appends it to
  `#org-themes` as text. Same function, same sanitising, so the pushed block
  is byte-identical to the one a full load would have rendered.

  ## Why `Phoenix.HTML.raw/1` on this output is safe

  The declarations are `Platform.Theming.Tokens.safe_declarations/2`: every
  stored value is re-sanitised here at render, and a name off the
  `Tokens.declared_names/0` allowlist or a value carrying `}`, `;`, `url(`,
  `@import`, `<` or `expression(` is dropped, not interpolated. The id in the
  selector is re-checked as a UUID, and a theme whose id fails emits nothing.
  `color-scheme` is a literal of the mode, not stored data.
  """

  alias Platform.Theming.OrgTheme
  alias Platform.Theming.Tokens

  @modes ["dark", "light"]

  @doc """
  The CSS for `themes` (published `OrgTheme`s the viewer can see), or nil when
  there are none, so the root layout renders no `<style>` at all.
  """
  @spec render([OrgTheme.t()]) :: String.t() | nil
  def render(themes) when is_list(themes) do
    case Enum.flat_map(themes, &blocks/1) do
      [] -> nil
      blocks -> Enum.join(blocks, "\n")
    end
  end

  @doc "The preset ids of `themes` whose id is a valid UUID, in order."
  @spec preset_ids([OrgTheme.t()]) :: [String.t()]
  def preset_ids(themes) when is_list(themes) do
    for %OrgTheme{id: id} = theme <- themes,
        Platform.UUID.valid?(id),
        do: OrgTheme.preset_id(theme)
  end

  defp blocks(%OrgTheme{id: id} = theme) do
    if Platform.UUID.valid?(id) do
      preset = OrgTheme.preset_id(theme)

      for mode <- @modes do
        ~s|[data-preset="#{preset}"][data-theme="#{mode}"]:not([data-theme-preview]) {\n| <>
          "color-scheme: #{mode};\n" <>
          Tokens.safe_declarations(theme, mode) <> "\n}"
      end
    else
      []
    end
  end

  defp blocks(_), do: []
end
