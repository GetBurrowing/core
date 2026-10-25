defmodule Platform.Theming.Tokens do
  @moduledoc """
  The token mapping between the Burrow masters' theme keys and the app's CSS
  slots, and the sanitised CSS variable string a theme paints with (task
  01a1557a-fe9b stage 1).

  ## The mapping

  The masters' `theme.js` keys that have an app slot, as the header of
  `assets/css/theme_presets.css` maps them:

    * grounds: `ground` -> base-200, `surface` -> base-100, `raised` ->
      base-300, `edge` -> `--edge`;
    * text: `ink` -> base-content, `muted` -> secondary;
    * accent: `accent` -> primary AND accent, `onAccent` -> primary-content
      AND accent-content, `interactive` -> `--color-interactive`;
    * status: `info` / `active` / `warning` / `danger` -> info / success /
      warning / error, and `infoDim` / `activeDim` / `warningDim` -> the
      `-dim` steps;
    * agents: `agTeal` ... `agLime` -> `--ag-<id>`, with `--ag-<id>-text`
      reading it unless the palette holds the optional `agTealText` ...
      `agLimeText` (`override_slots/0`);
    * `viewer` -> `--viewer`, `stage` -> `--stage`.

  Not mapped: `desk` (demo only), `faint` (the tier is retired),
  `bubbleMe` and `dangerDim` (no app slot), and `scrim` / `shade`, whose
  masters values carry an alpha channel and so cannot be stored as the
  `#rrggbb` an org theme holds; those two fall through to Burrow's.

  ## Derived tokens

  Computed the way the preset blocks compute them: secondary and status
  `-content` are black on a dark variant and white on a light one; the focus
  ring is the primary in dark and the interactive colour in light; `--subtle`
  is base-content at 55%, or at 57% where no 55% composite clears 4.5:1 on all
  three grounds (Burrow sand light's rule); `--disabled` and `--decorative`
  are base-content at 40%; `--radius-field` is `round(radius x 0.71)`. A
  palette may hold any of these colour slots as an optional key instead
  (`override_slots/0`); a draft seeded from a preset holds every one the
  preset block declares differently.

  A shipped preset carries its own declared values instead
  (`Platform.Theming.Presets`), so its ledger measures exactly what its block
  paints.
  """

  alias Platform.Design.PaintedComposite
  alias Platform.Design.WcagContrast, as: W
  alias Platform.Theming.ContrastPairs

  @agent_ids ~w(teal green amber orange blue purple brick rose indigo lime)

  # master key => the slots it drives. The first slot is the one a preset
  # maps back from.
  @master_slots [
                  {"ground", ["--color-base-200"]},
                  {"surface", ["--color-base-100"]},
                  {"raised", ["--color-base-300"]},
                  {"edge", ["--edge"]},
                  {"ink", ["--color-base-content"]},
                  {"muted", ["--color-secondary"]},
                  {"accent", ["--color-primary", "--color-accent"]},
                  {"interactive", ["--color-interactive"]},
                  {"onAccent", ["--color-primary-content", "--color-accent-content"]}
                ] ++
                  for(
                    id <- @agent_ids,
                    do: {"ag" <> String.capitalize(id), ["--ag-#{id}", "--ag-#{id}-text"]}
                  ) ++
                  [
                    {"info", ["--color-info"]},
                    {"infoDim", ["--info-dim"]},
                    {"active", ["--color-success"]},
                    {"activeDim", ["--success-dim"]},
                    {"warning", ["--color-warning"]},
                    {"warningDim", ["--warning-dim"]},
                    {"danger", ["--color-error"]},
                    {"viewer", ["--viewer"]},
                    {"stage", ["--stage"]}
                  ]

  @color_keys Enum.map(@master_slots, &elem(&1, 0))

  # Optional palette keys (task 01a1557a-fe9b stage 6): a slot no master key
  # sets on its own, held where a preset block declares it apart from what
  # this module derives. Burrow sand and forest light darken
  # `--ag-<id>-text` below the rail colour; Burrow light's warning content is
  # not pure white. A draft seeded from a preset carries those declared
  # values, so it paints and measures exactly what the preset does. Absent,
  # the slot is derived as before.
  @override_slots for(
                    id <- @agent_ids,
                    do: {"ag" <> String.capitalize(id) <> "Text", "--ag-#{id}-text"}
                  ) ++
                    [
                      {"mutedContent", "--color-secondary-content"},
                      {"focusRing", "--focus-ring"},
                      {"infoContent", "--color-info-content"},
                      {"activeContent", "--color-success-content"},
                      {"warningContent", "--color-warning-content"},
                      {"dangerContent", "--color-error-content"}
                    ]

  @override_keys Enum.map(@override_slots, &elem(&1, 0))

  # Slots no master key drives; derived per mode.
  @derived_slots [
    "--color-secondary-content",
    "--focus-ring",
    "--color-info-content",
    "--color-success-content",
    "--color-warning-content",
    "--color-error-content"
  ]

  # Every colour slot, in declaration order.
  @color_slots [
                 "--color-base-100",
                 "--color-base-200",
                 "--color-base-300",
                 "--edge",
                 "--viewer",
                 "--stage",
                 "--color-base-content",
                 "--color-secondary",
                 "--color-secondary-content",
                 "--color-primary",
                 "--color-primary-content",
                 "--color-accent",
                 "--color-accent-content",
                 "--color-interactive",
                 "--focus-ring",
                 "--color-info",
                 "--color-info-content",
                 "--info-dim",
                 "--color-success",
                 "--color-success-content",
                 "--success-dim",
                 "--color-warning",
                 "--color-warning-content",
                 "--warning-dim",
                 "--color-error",
                 "--color-error-content"
               ] ++ Enum.flat_map(@agent_ids, &["--ag-#{&1}", "--ag-#{&1}-text"])

  @shape_keys ["radius", "density", "glass_alpha", "glass_blur", "font"]

  # The non-colour names a variant declares, in declaration order.
  @text_slots ["--subtle", "--disabled", "--decorative", "--ag-tint-pct"]
  @shape_slots [
    "--radius-box",
    "--radius-field",
    "--font-sans",
    "--density",
    "--glass-alpha",
    "--glass-blur"
  ]

  # Every name `declarations/2` emits, in order: THE allowlist. The preview
  # receiver's ALLOWED_VARS (assets/js/hooks/theme_preview_receiver.js) is
  # held equal to it by theme_preview_allowlist_parity_test.exs, and the root
  # layout's org theme blocks (`Platform.Theming.OrgThemeCss`) emit nothing
  # else.
  @declared_names @color_slots ++ @text_slots ++ @shape_slots

  # The receiver's `safeValue` (theme_preview_receiver.js), mirrored: the
  # characters a value the server could have produced may use, and the only
  # functions it may call.
  @value_chars ~r/\A[A-Za-z0-9 #.,%()"'-]{1,160}\z/
  @allowed_functions ["color-mix", "var"]
  # Refused outright, whatever else holds. Most are already outside
  # @value_chars; they are listed so the rule reads at the call.
  @forbidden ["}", "{", ";", "<", ">", "\\", "/*", "url(", "@import", "expression("]
  @length_format ~r/\A\d+(\.\d+)?(px)?\z/

  # The five font chips of the masters' editor (theme.html), in its order.
  @font_chips [
    ~s(Inter, system-ui, -apple-system, "Segoe UI", sans-serif),
    ~s(system-ui, -apple-system, "Segoe UI", sans-serif),
    ~s(Georgia, "Iowan Old Style", "Palatino Linotype", serif),
    ~s("SF Mono", ui-monospace, Menlo, monospace),
    ~s("Avenir Next", "Helvetica Neue", Helvetica, Arial, sans-serif)
  ]

  @font_format ~r/^[A-Za-z0-9 ,"'-]{1,120}$/
  @hex_format ~r/^#[0-9a-f]{6}$/

  @subtle_strengths [55, 57]
  @exempt_strength 40
  @agent_tint_pct "8%"

  @type variant :: %{
          preset_id: String.t() | nil,
          colors: %{String.t() => String.t()},
          subtle: pos_integer(),
          shape: %{String.t() => String.t()}
        }

  @doc "The theme keys an org theme stores per mode, in theme.js order."
  @spec color_keys() :: [String.t()]
  def color_keys, do: @color_keys

  @doc """
  The optional palette keys, `[{key, slot}]`: a value for a slot that is
  otherwise read from a rail key (`--ag-<id>-text`) or derived (the
  `-content` slots and the focus ring). See `palette_keys/0`.
  """
  @spec override_slots() :: [{String.t(), String.t()}]
  def override_slots, do: @override_slots

  @doc "Every key a palette may hold: `color_keys/0` (required) then the optional overrides."
  @spec palette_keys() :: [String.t()]
  def palette_keys, do: @color_keys ++ @override_keys

  @doc """
  Every colour slot of `palette` in `mode`, before any override: the master
  keys' slots plus the derived ones. What a palette holding only the
  master keys paints.
  """
  @spec base_colors(map(), String.t()) :: %{String.t() => String.t()}
  def base_colors(palette, mode) do
    for {key, slots} <- @master_slots, slot <- slots, into: %{} do
      {slot, Map.get(palette, key)}
    end
    |> Map.merge(derived(palette, mode))
  end

  @doc "`[{master_key, [slot]}]`, the mapping, in theme.js order."
  @spec master_slots() :: [{String.t(), [String.t()]}]
  def master_slots, do: @master_slots

  @doc "Every colour slot a variant declares, in declaration order."
  @spec color_slots() :: [String.t()]
  def color_slots, do: @color_slots

  @doc """
  Every custom-property name `declarations/2` emits, in declaration order.
  The one allowlist of names; see `safe_declaration?/2`.
  """
  @spec declared_names() :: [String.t()]
  def declared_names, do: @declared_names

  @doc "The shape keys an org theme stores."
  @spec shape_keys() :: [String.t()]
  def shape_keys, do: @shape_keys

  @doc "The five font stacks the editor offers as chips."
  @spec font_chips() :: [String.t()]
  def font_chips, do: @font_chips

  @doc "The pattern a custom font stack must match."
  def font_format, do: @font_format

  @doc "The agent slot ids, as `Platform.Agents.ColorPalette` names them."
  def agent_ids, do: @agent_ids

  @doc """
  The resolved variant of `theme` in `mode`: every colour slot as lowercase
  `#rrggbb`, the `--subtle` strength, and the shape declarations.

  `theme` is a `Platform.Theming.OrgTheme` (or any map with string-keyed
  `light` / `dark` / `shape`), or a shipped preset from
  `Platform.Theming.Presets`, which carries its declared variants verbatim.
  """
  @spec variant(map(), String.t()) :: variant()
  def variant(%{variants: variants}, mode) when mode in ["light", "dark"],
    do: Map.fetch!(variants, mode)

  def variant(%{} = theme, mode) when mode in ["light", "dark"] do
    palette = if mode == "light", do: Map.fetch!(theme, :light), else: Map.fetch!(theme, :dark)
    shape = Map.fetch!(theme, :shape)

    colors =
      for {key, slots} <- @master_slots, slot <- slots, into: %{} do
        {slot, Map.fetch!(palette, key)}
      end
      |> Map.merge(derived(palette, mode))
      |> Map.merge(overrides(palette))

    %{
      preset_id: nil,
      colors: colors,
      subtle: subtle_strength(colors),
      shape: shape_declarations(shape)
    }
  end

  @doc """
  The sanitised CSS variable string for `theme` in `mode`:
  `--slot: value;` declarations, one per line, in a fixed order. Every value
  is re-checked against its allowed form on the way out, so nothing that did
  not pass the schema can reach a stylesheet; a value that fails raises.

  For a stylesheet built from STORED rows at render time use
  `safe_declarations/2`, which drops a failing value instead.
  """
  @spec declarations(map(), String.t()) :: String.t()
  def declarations(theme, mode) do
    v = variant(theme, mode)

    color_lines = for slot <- @color_slots, do: {slot, hex!(Map.fetch!(v.colors, slot))}

    shape_lines =
      for key <- @shape_slots, do: {key, shape_value!(key, Map.fetch!(v.shape, key))}

    (color_lines ++ text_lines(v.subtle) ++ shape_lines)
    |> join_declarations()
  end

  @doc """
  The declarations of a stored theme in `mode`, re-sanitised at render (task
  01a1557a-fe9b stage 3): the same names in the same order as
  `declarations/2`, but read leniently, and every `{name, value}` that fails
  `safe_declaration?/2` is DROPPED, never interpolated and never raised. A
  row written around the schema (a value carrying `}`, `;`, `url(`,
  `@import`, `<` or `expression(`) therefore paints Burrow's value for that
  slot and nothing else changes.
  """
  @spec safe_declarations(map(), String.t()) :: String.t()
  def safe_declarations(theme, mode) when mode in ["light", "dark"] do
    theme
    |> lenient_pairs(mode)
    |> Enum.filter(fn {name, value} -> safe_declaration?(name, value) end)
    |> join_declarations()
  end

  @doc """
  Whether `{name, value}` may be written into a stylesheet: `name` is in
  `declared_names/0`, and `value` is a string holding nothing in the
  forbidden list (`}`, `{`, `;`, `<`, `>`, backslash, `/*`, `url(`,
  `@import`, `expression(`), only the characters the preview receiver's
  `safeValue` allows, no function but `color-mix()` / `var()`, and the form
  of its slot: lowercase `#rrggbb` for a colour, a plain length or number for
  a shape, the font pattern for `--font-sans`.
  """
  @spec safe_declaration?(term(), term()) :: boolean()
  def safe_declaration?(name, value) when is_binary(name) and is_binary(value) do
    name in @declared_names and safe_value?(value) and slot_form?(name, value)
  end

  def safe_declaration?(_name, _value), do: false

  defp safe_value?(value) do
    not String.contains?(String.downcase(value), @forbidden) and
      Regex.match?(@value_chars, value) and
      Enum.all?(Regex.scan(~r/([A-Za-z-]+)\s*\(/, value), fn [_, fun] ->
        String.downcase(fun) in @allowed_functions
      end)
  end

  defp slot_form?(name, value) do
    cond do
      name in @color_slots -> Regex.match?(@hex_format, value)
      name == "--font-sans" -> Regex.match?(@font_format, value)
      name in @shape_slots -> Regex.match?(@length_format, value)
      true -> true
    end
  end

  defp text_lines(subtle) do
    [
      {"--subtle", mix(subtle)},
      {"--disabled", mix(@exempt_strength)},
      {"--decorative", mix(@exempt_strength)},
      {"--ag-tint-pct", @agent_tint_pct}
    ]
  end

  defp join_declarations(pairs), do: Enum.map_join(pairs, "\n", fn {k, v} -> "#{k}: #{v};" end)

  # Every declared name with whatever value a stored row yields for it (nil
  # when it yields none); nothing here raises on a bad row. A shipped preset
  # is compile-time data and goes through `variant/2`.
  defp lenient_pairs(%{variants: _} = preset, mode) do
    v = variant(preset, mode)

    for(slot <- @color_slots, do: {slot, Map.get(v.colors, slot)}) ++
      text_lines(v.subtle) ++ for(key <- @shape_slots, do: {key, Map.get(v.shape, key)})
  end

  defp lenient_pairs(theme, mode) do
    palette = map_or_empty(Map.get(theme, if(mode == "light", do: :light, else: :dark)))
    shape = map_or_empty(Map.get(theme, :shape))

    colors = palette |> base_colors(mode) |> Map.merge(overrides(palette))

    for(slot <- @color_slots, do: {slot, Map.get(colors, slot)}) ++
      text_lines(lenient_subtle(colors)) ++
      for(key <- @shape_slots, do: {key, lenient_shape(key, shape)})
  end

  defp map_or_empty(%{} = map), do: map
  defp map_or_empty(_), do: %{}

  # The measured strength when the ink and the three grounds are all valid
  # colours; otherwise the default 55%, which no stored value can steer.
  defp lenient_subtle(colors) do
    needed = ["--color-base-content" | ContrastPairs.grounds()]

    if Enum.all?(needed, &(is_binary(colors[&1]) and Regex.match?(@hex_format, colors[&1]))),
      do: subtle_strength(colors),
      else: hd(@subtle_strengths)
  end

  defp lenient_shape("--radius-box", %{"radius" => r}) when is_number(r), do: "#{r}px"

  defp lenient_shape("--radius-field", %{"radius" => r}) when is_number(r),
    do: "#{round(r * 0.71)}px"

  defp lenient_shape("--font-sans", shape), do: shape["font"]
  defp lenient_shape("--density", %{"density" => n}) when is_number(n), do: number(n)
  defp lenient_shape("--density", shape), do: shape["density"]
  defp lenient_shape("--glass-alpha", %{"glass_alpha" => n}) when is_number(n), do: number(n)
  defp lenient_shape("--glass-alpha", shape), do: shape["glass_alpha"]
  defp lenient_shape("--glass-blur", %{"glass_blur" => n}) when is_number(n), do: "#{n}px"
  defp lenient_shape(_key, _shape), do: nil

  @doc "The `--subtle` declaration value at `pct`."
  @spec mix(pos_integer()) :: String.t()
  def mix(pct) when is_integer(pct),
    do: "color-mix(in oklab, var(--color-base-content) #{pct}%, transparent)"

  @doc """
  The `--subtle` strength for a colour map: 55%, or 57% when the 55%
  composite misses 4.5:1 on some ground and 57% clears all three.
  """
  @spec subtle_strength(%{String.t() => String.t()}) :: pos_integer()
  def subtle_strength(colors) do
    ink = W.hex(Map.fetch!(colors, "--color-base-content"))
    grounds = Enum.map(ContrastPairs.grounds(), &W.hex(Map.fetch!(colors, &1)))

    clears? = fn pct ->
      Enum.all?(grounds, fn g ->
        elem(PaintedComposite.contrast_min(ink, g, pct), 0) >= ContrastPairs.aa_text()
      end)
    end

    Enum.find(@subtle_strengths, &clears?.(&1)) || hd(@subtle_strengths)
  end

  # ── derived slots ───────────────────────────────────────────────────────

  # The slots a palette overrides; a key it does not hold leaves the slot
  # read from its rail key or derived.
  defp overrides(palette) do
    for {key, slot} <- @override_slots, Map.has_key?(palette, key), into: %{} do
      {slot, Map.fetch!(palette, key)}
    end
  end

  defp derived(palette, mode) do
    content = if mode == "dark", do: W.to_hex({0.0, 0.0, 0.0}), else: W.to_hex({1.0, 1.0, 1.0})
    content = String.downcase(content)
    ring = if mode == "dark", do: palette["accent"], else: palette["interactive"]

    @derived_slots
    |> Enum.map(fn
      "--focus-ring" -> {"--focus-ring", ring}
      slot -> {slot, content}
    end)
    |> Map.new()
  end

  defp shape_declarations(shape) do
    radius = Map.fetch!(shape, "radius")

    %{
      "--radius-box" => "#{radius}px",
      "--radius-field" => "#{round(radius * 0.71)}px",
      "--font-sans" => Map.fetch!(shape, "font"),
      "--density" => number(Map.fetch!(shape, "density")),
      "--glass-alpha" => number(Map.fetch!(shape, "glass_alpha")),
      "--glass-blur" => "#{Map.fetch!(shape, "glass_blur")}px"
    }
  end

  defp number(n) when is_integer(n), do: Integer.to_string(n)

  defp number(n) when is_float(n) do
    if n == Float.round(n), do: Integer.to_string(trunc(n)), else: Float.to_string(n)
  end

  # ── sanitising ──────────────────────────────────────────────────────────

  defp hex!(value) do
    if is_binary(value) and Regex.match?(@hex_format, value),
      do: value,
      else: raise(ArgumentError, "not a lowercase #rrggbb colour: #{inspect(value)}")
  end

  defp shape_value!("--font-sans", value) do
    if is_binary(value) and Regex.match?(@font_format, value),
      do: value,
      else: raise(ArgumentError, "not an allowed font stack: #{inspect(value)}")
  end

  defp shape_value!(key, value) do
    if is_binary(value) and Regex.match?(~r/^\d+(\.\d+)?(px)?$/, value),
      do: value,
      else: raise(ArgumentError, "#{key}: not a plain length or number: #{inspect(value)}")
  end
end
