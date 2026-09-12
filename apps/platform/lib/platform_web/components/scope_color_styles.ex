defmodule PlatformWeb.Components.ScopeColorStyles do
  @moduledoc """
  Server-rendered `<style>` block carrying every active org's scope colour
  as CSS custom properties.

  ## Why a style element and not utility classes

  Tailwind utilities are resolved at BUILD time. `.text-cyberdyne` is a
  literal rule in the compiled stylesheet, so an org created at runtime can
  never acquire one without a CSS rebuild and a deploy — which is the whole
  defect task 01a09287 exists to kill. Custom properties are resolved at
  RENDER time, so the slug-agnostic `.scope-*` utilities in `app.css` plus
  the declarations emitted here give a brand-new org its colour on the next
  page load, with no deploy.

  Each org with a colour contributes two rules:

      [data-scope="fabrikam"]{--scope-fill:…;--scope-label:…;--scope-active-content:…}
      [data-theme=dark] [data-scope="fabrikam"]{--scope-label:…}

  Every value is solved by `Platform.Tenancy.ScopeColor.derive/2`, which
  pins both labels at >= 4.5:1 against the 12%-tint composite they really
  sit on. An org whose `color_hue` is `nil` emits NOTHING: no custom
  property is set for its slug, `.scope-text` inherits, and the call site's
  existing `text-muted` fallback stands.

  ## Escaping

  A slug reaches this module from the database, and the database is fed by
  an admin form. `Org.changeset/2` constrains slugs to
  `~r/^[a-z][a-z0-9_-]*$/`, but a changeset is not a storage
  guarantee — a direct write, a migration, or an import bypasses it. A
  `"` or `}` inside a selector would close the attribute or the rule and let
  the rest of the string be parsed as CSS, and a `<style>` element's content
  is CDATA-ish: HEEx escaping of `{}` and quotes does not apply inside it.

  So the slug is re-validated HERE, at the interpolation site, against the
  same character class (anchored a notch tighter — see `@slug_format`), and
  any row that fails is DROPPED. That is a
  whitelist, not a sanitiser: nothing is stripped or escaped and there is no
  encoding to get wrong. Colour values are never user input — they are
  `oklch(...)` strings this process just computed from two numbers.
  """
  use Phoenix.Component

  alias Platform.Tenancy
  alias Platform.Tenancy.ScopeColor

  # `Platform.Tenancy.Org`'s `@slug_format` character class, anchored with
  # \A / \z instead of ^ / $. Duplicated rather than imported because this
  # is a defence-in-depth check on data that may never have passed through
  # that changeset at all — and deliberately STRICTER: in PCRE `$` also
  # matches immediately before a trailing newline, so `~r/^[a-z]…$/` accepts
  # "acme\n". No legitimate slug contains one, and a newline inside a
  # <style> element is a statement separator. \z admits nothing the
  # changeset rejects, so nothing that can be created through the admin form
  # is dropped here.
  @slug_format ~r/\A[a-z][a-z0-9_-]*\z/

  @doc """
  Renders the scope-colour custom properties for `entries`.

  Pass `entries` directly (a list of `%{slug:, hue:, chroma:}` maps, the
  shape of `Platform.Tenancy.scope_slug_entries/1`) or pass a `viewer` and
  let the component resolve them. Tests take the first form; the shell takes
  the second.

  The element carries a stable `id` and is deliberately NOT
  `phx-update="ignore"` — recolouring an org has to reach a connected
  client's next render, which an ignored subtree would swallow.
  """
  attr(:id, :string, default: "org-scope-colors")
  attr(:entries, :list, default: nil)
  attr(:viewer, :any, default: nil)

  def scope_color_styles(assigns) do
    entries = assigns.entries || Tenancy.scope_slug_entries(assigns.viewer)
    assigns = assign(assigns, :css, css_for(entries))

    ~H"""
    <style id={@id} data-role="org-scope-colors">
      <%= Phoenix.HTML.raw(@css) %>
    </style>
    """
  end

  @doc """
  The CSS text the component renders, as a plain string.

  Exposed so a test can assert on the declarations without going through
  `render_component/2`, and so the rule-building logic has a name.
  """
  @spec css_for([map()]) :: String.t()
  def css_for(entries) do
    entries
    |> Enum.filter(&renderable?/1)
    |> Enum.map_join("\n", &rules_for/1)
  end

  defp renderable?(%{slug: slug} = entry) when is_binary(slug) do
    is_integer(Map.get(entry, :hue)) and Regex.match?(@slug_format, slug)
  end

  defp renderable?(_), do: false

  defp rules_for(%{slug: slug, hue: hue} = entry) do
    chroma = Map.get(entry, :chroma) || ScopeColor.default_chroma()
    ramp = ScopeColor.derive(hue, chroma)

    """
    [data-scope="#{slug}"]{--scope-fill:#{ramp.fill};--scope-label:#{ramp.label_light};--scope-active-content:#{active_content(ramp.fill)}}
    [data-theme=dark] [data-scope="#{slug}"]{--scope-label:#{ramp.label_dark}}\
    """
  end

  # The text colour baked onto a full-saturation active pill. The six
  # shipped `bg-<slug>-active` blocks in app.css each hard-code one of two
  # tokens (`oklch(15% 0 0)` / `oklch(98% 0 0)`) chosen by eye per scope;
  # choosing by measured contrast reproduces that split without a table,
  # and answers for a hue nobody has picked yet.
  defp active_content(fill) do
    if ScopeColor.contrast("oklch(15% 0 0)", fill) >= ScopeColor.contrast("oklch(98% 0 0)", fill) do
      "oklch(15% 0 0)"
    else
      "oklch(98% 0 0)"
    end
  end
end
