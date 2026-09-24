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

  ## What each org emits

  Each org with a colour contributes two rules (one line each in the real
  output, wrapped here):

      [data-scope="acme"]{--scope-fill:oklch(…);--scope-active-content:oklch(…);
        --scope-tint-100:#rrggbb;--scope-tint-200:#rrggbb;
        --scope-label-100:#rrggbb;--scope-label-200:#rrggbb;
        --scope-edge-100:#rrggbb;--scope-edge-200:#rrggbb;
        --scope-edge-hover-100:#rrggbb;--scope-edge-hover-200:#rrggbb}
      [data-theme=dark] [data-scope="acme"]{…the same eight per-surface slots…}

  The eight per-surface slots are, for each of the two surfaces a chip sits
  on, its OPAQUE tint, its label, its edge and its hover edge: `-100` is
  `base-100` (the chat pane and the page ground), `-200` is `base-200` (the
  scope rail). The dark rule overrides all eight and nothing else.
  `--scope-fill` (the full-saturation dot and active pill) and
  `--scope-active-content` (the text on that pill) vary by neither theme
  nor surface, so they are emitted once.

  Every slot value is `Platform.Tenancy.ScopeColor`'s solve for that theme
  and surface, at the org's own fill lightness when its row carries one
  (`derive/3`; the six shipped orgs, task 01a09333-d374 stage 5) and at the
  72% default otherwise (`derive/2`): the tint is the 12% composite over that surface
  from `composite_painted/3`, the label is solved against that one tint
  with a one-byte margin, and the edge is solved to 3:1 against the surface
  itself with the same margin (task 01a09333-d374 stage 4). The hover edge
  is its own solved value, one solver step darker, so hover needs no
  `color-mix` or relative colour syntax at render time. Which slot a chip
  reads is decided by the chip's CALL SITE, through `ScopePill`'s `surface`
  attr, and never by the container it happens to sit in (task
  01a09333-d374; see `ScopePill`'s moduledoc).

  An org whose `color_hue` is `nil` emits NOTHING: no custom property is set
  for its slug, `.scope-text` inherits, and the call site's existing
  `text-muted` fallback stands.

  ## Labels are emitted as the bytes the solver measured

  `ScopeColor` carries each label as an `oklch()` string, but a browser
  converts `oklch()` to sRGB itself, and that conversion was measured to
  differ from the solver's by one byte on about one channel in eighteen.
  The solver's margin covers a one-byte move on the label's GREEN channel
  only; a one-byte move on every channel drops 127 of 1440 labels below 4.5
  at C 0.15. A label emitted as `oklch()` would therefore be painted as
  bytes the solver never checked.

  So each label is emitted as `#rrggbb`: the exact bytes the solver
  quantised and handed to `floor_contrast/2`, read with
  `composite_painted(label, 1.0, _)` (at alpha 1.0 the composite is the
  label alone). The browser paints the measured bytes and converts nothing.
  Hue and chroma are unchanged, because the bytes come from the same
  `oklch()` value. Nothing consumes `--scope-label-*` in oklch space (no
  `color-mix`, no relative colour syntax): `.scope-text` and
  `.scope-text-200` use it as a plain `color`.

  Edges and hover edges are emitted the same way and for the same reason:
  their margin is the same green-only `floor_contrast/2`. `.scope-edge*`
  use them as a plain `border-color` or an inset `box-shadow` colour.

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
  encoding to get wrong.

  Colour values are never user input. They are `#rrggbb` bytes and
  `oklch(...)` strings this process just computed from two numbers. They
  are whitelisted anyway, the same way (`@value_format`, dropping the whole
  row), so a later change to how a value is produced cannot widen what
  reaches the interpolation site.
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

  # Every VALUE interpolated into a declaration: a lowercase `#rrggbb`, or an
  # `oklch(L% C H)` whose three components are plain numbers (digits, sign,
  # point, exponent). Neither alternative admits a quote, brace, semicolon,
  # angle bracket, slash, space outside the two separators, or newline.
  # Anchored with \A / \z for the same reason as `@slug_format`.
  @value_format ~r/\A(?:#[0-9a-f]{6}|oklch\([0-9.e-]+% [0-9.e-]+ [0-9.e-]+\))\z/

  @doc """
  Renders the scope-colour custom properties for `entries`.

  Pass `entries` directly (a list of `%{slug:, hue:, chroma:, lightness:}`
  maps; `lightness` may be absent or nil) or pass a `viewer` and let the
  component resolve them with `Platform.Tenancy.scope_color_entries/1`:
  every active org the viewer can SEE, because a chip anywhere on the page
  for an org outside the list renders uncoloured. Tests take the first
  form; the shell takes the second.

  The element carries a stable `id` and is deliberately NOT
  `phx-update="ignore"` — recolouring an org has to reach a connected
  client's next render, which an ignored subtree would swallow.
  """
  attr(:id, :string, default: "org-scope-colors")
  attr(:entries, :list, default: nil)
  attr(:viewer, :any, default: nil)

  def scope_color_styles(assigns) do
    entries = assigns.entries || Tenancy.scope_color_entries(assigns.viewer)
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
    |> Enum.flat_map(&rules_for/1)
    |> Enum.join("\n")
  end

  @doc """
  The eight per-surface slots for `theme`, in emission order, as
  `{custom_property, value}` pairs.

  Tints are `ScopeColor`'s opaque `#rrggbb` as solved. Labels, edges and
  hover edges are the painted bytes of `ScopeColor`'s `oklch()` value for
  the same surface; see "Labels are emitted as the bytes the solver
  measured" in the moduledoc.
  """
  @spec surface_slots(ScopeColor.ramp(), :light | :dark) :: [{String.t(), String.t()}]
  # `--scope-label-100` and base-100 byte identity (task 01a09333-d374).
  #
  # A base-100 label emitted here may land on a NEIGHBOURING solver step
  # from the pre-retrofit `oklch()` value the org wore, in two ways: the
  # solver walks down from the fill and stops at the first L that holds its
  # margin, which moved three of the six light cells; and at an UNCHANGED L
  # the bytes can still differ by one, because the browser used to do the
  # `oklch()` -> sRGB conversion itself and now receives the bytes the
  # solver quantised (see "Labels are emitted as the bytes the solver
  # measured" in the moduledoc).
  #
  # AA is the binding constraint on this slot; byte identity with the
  # pre-retrofit paint is NOT. Every base-100 label clears 4.5:1 against its
  # own tint, and sxi (the thinnest margin of the six, and a live client)
  # gains under the solve, from 4.5539 to 4.6725. Pinning these labels back
  # to the old bytes would return sxi to the tightest figure in the set and
  # reintroduce hand-maintained per-org values beside the solver.
  #
  # Approved with the move disclosed: review request
  # 01a0c74f-ab00-7001-9666-7ff46eb41f6a, 2026-09-23. The four cells that
  # moved are pinned with their provenance by
  # `PlatformWeb.Components.ScopeColorStylesShippedSixTest`, "the four
  # base-100 labels the behavioural gate flagged".
  def surface_slots(ramp, :light) do
    [
      {"--scope-tint-100", ramp.tint_light_100},
      {"--scope-tint-200", ramp.tint_light_200},
      {"--scope-label-100", painted_hex(ramp.label_light_100)},
      {"--scope-label-200", painted_hex(ramp.label_light_200)},
      {"--scope-edge-100", painted_hex(ramp.edge_light_100)},
      {"--scope-edge-200", painted_hex(ramp.edge_light_200)},
      {"--scope-edge-hover-100", painted_hex(ramp.edge_hover_light_100)},
      {"--scope-edge-hover-200", painted_hex(ramp.edge_hover_light_200)}
    ]
  end

  def surface_slots(ramp, :dark) do
    [
      {"--scope-tint-100", ramp.tint_dark_100},
      {"--scope-tint-200", ramp.tint_dark_200},
      {"--scope-label-100", painted_hex(ramp.label_dark_100)},
      {"--scope-label-200", painted_hex(ramp.label_dark_200)},
      {"--scope-edge-100", painted_hex(ramp.edge_dark_100)},
      {"--scope-edge-200", painted_hex(ramp.edge_dark_200)},
      {"--scope-edge-hover-100", painted_hex(ramp.edge_hover_dark_100)},
      {"--scope-edge-hover-200", painted_hex(ramp.edge_hover_dark_200)}
    ]
  end

  @doc """
  True when `value` may be interpolated into a declaration: a lowercase
  `#rrggbb`, or an `oklch(L% C H)` of plain numbers. Any other value drops
  its whole row from `css_for/1`.
  """
  @spec safe_value?(term()) :: boolean()
  def safe_value?(value) when is_binary(value), do: Regex.match?(@value_format, value)
  def safe_value?(_), do: false

  defp renderable?(%{slug: slug} = entry) when is_binary(slug) do
    is_integer(Map.get(entry, :hue)) and Regex.match?(@slug_format, slug)
  end

  defp renderable?(_), do: false

  defp rules_for(%{slug: slug, hue: hue} = entry) do
    chroma = Map.get(entry, :chroma) || ScopeColor.default_chroma()
    ramp = ScopeColor.derive(hue, chroma, fill_lightness(entry))

    light =
      [{"--scope-fill", ramp.fill}, {"--scope-active-content", active_content(ramp.fill)}] ++
        surface_slots(ramp, :light)

    dark = surface_slots(ramp, :dark)

    if Enum.all?(light ++ dark, fn {_property, value} -> safe_value?(value) end) do
      [
        ~s([data-scope="#{slug}"]{#{declarations(light)}}\n) <>
          ~s([data-theme=dark] [data-scope="#{slug}"]{#{declarations(dark)}})
      ]
    else
      []
    end
  end

  # The org's stored fill lightness when it is a usable one, else the
  # default. The column's CHECK constraint already bounds it to (0, 1); this
  # is the backstop for a row that never passed that constraint, and it
  # falls back rather than dropping the row, because a lightness out of
  # range says nothing wrong about the hue.
  defp fill_lightness(entry) do
    case Map.get(entry, :lightness) do
      l when is_float(l) and l > 0 and l < 1 -> l
      _ -> ScopeColor.default_fill_lightness()
    end
  end

  defp declarations(pairs),
    do: Enum.map_join(pairs, ";", fn {property, value} -> "#{property}:#{value}" end)

  # The bytes the solver measured for an opaque `oklch()` value (a label,
  # an edge or a hover edge): converted and quantised once. At alpha 1.0
  # `composite_painted/3` returns the colour alone and ignores its surface
  # argument, so the `#000000` passed there contributes nothing.
  defp painted_hex(color), do: ScopeColor.composite_painted(color, 1.0, "#000000").hex

  # The text colour baked onto a full-saturation active pill: whichever of
  # the two tokens the old per-slug `bg-<slug>-active` blocks used
  # (`oklch(15% 0 0)` / `oklch(98% 0 0)`) measures higher against the fill.
  # Those blocks chose by eye, and this does NOT reproduce their split: at
  # the six shipped fills it picks the dark token for all six, where
  # soylent and wayne-tech shipped white at 3.30:1 and 2.67:1. Moving the six
  # onto this path (task 01a09333-d374 stage 5) therefore flips those two
  # active pills to dark text, at 5.62:1 and 6.95:1;
  # `ScopeColorStylesShippedSixTest` pins that as a named delta.
  defp active_content(fill) do
    if ScopeColor.contrast("oklch(15% 0 0)", fill) >= ScopeColor.contrast("oklch(98% 0 0)", fill) do
      "oklch(15% 0 0)"
    else
      "oklch(98% 0 0)"
    end
  end
end
