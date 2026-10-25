defmodule Platform.Design.InactiveTabContrastTest do
  @moduledoc """
  An inactive daisyUI `.tab` paints the secondary-text tier, `--color-subtle`
  (task 01a15907 stage 4, backlog 01a15ca0; Saru's ruling: subtle, not
  disabled).

  daisyUI paints a resting tab at base-content 50% from vendor CSS, about
  3.85:1 on the light grounds. Neither the class ratchet nor the stylesheet
  floor reads vendor CSS, so this file holds the override in `app.css`:

    * THE OVERRIDE EXISTS, unlayered, on daisyUI's own resting-tab selector
      (so `:hover`, `:checked`, `.tab-active` and `[aria-selected="true"]`
      keep daisyUI's full base-content), and it paints `var(--color-subtle)`.
      Unlayered because the built stylesheet emits daisyUI's `.tab` rules
      inside `@layer utilities`; a layered override lost to them in the
      browser.
    * PAINTED CONTRAST. The colour the override names is measured the way
      `theme_presets_guard_test.exs` measures `--subtle`: base-content at the
      strength the block declares for that token, on the worst pixel
      `Platform.Design.PaintedComposite` allows, against base-100, base-200
      and base-300, in all ten painted variants (Burrow dark and light, and
      burrow-forest, burrow-midnight, burrow-sand and high-contrast in each
      mode). With no override the colour measured is daisyUI's own 50%, read
      from the vendored plugin. A strength no browser has been measured
      painting is measured as the plain alpha composite.
    * ONE SOURCE. No `.tab` element in `lib/` carries its own text colour
      class, so the override is the only thing that colours an inactive tab.

  Named mutations, each shown red at task 01a15907 stage 4: (a) the override
  removed; (b) the override pointed at `--color-disabled`; (c) a per-site
  `text-subtle!` put back on the Social tab.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.CssRules
  alias Platform.Design.PaintedComposite
  alias Platform.Design.WcagContrast, as: W

  import Platform.Design.ThemeBlocks,
    only: [preset_blocks: 1, burrow_block: 2, resolve!: 2, declaration: 2]

  @app Path.expand("../../..", __DIR__)
  @root Path.expand("../..", @app)
  @app_css Path.join(@app, "assets/css/app.css")
  @presets_css Path.join(@app, "assets/css/theme_presets.css")
  @daisyui Path.join(@app, "assets/vendor/daisyui.js")

  @aa_text 4.5
  @grounds ["--color-base-100", "--color-base-200", "--color-base-300"]
  @variants 10

  # daisyUI's resting-tab exclusions; the override must carry every one.
  @resting_exclusions [
    ":checked",
    "label:has(:checked)",
    ":hover",
    ".tab-active",
    ~s([aria-selected="true"])
  ]

  @mix_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/

  setup_all do
    app_css = File.read!(@app_css)

    blocks =
      [burrow_block(app_css, "dark"), burrow_block(app_css, "light")] ++
        preset_blocks(File.read!(@presets_css))

    {:ok, app_css: app_css, blocks: blocks, override: override(app_css)}
  end

  # ── the override ─────────────────────────────────────────────────────────

  defp override(css) do
    css
    |> CssRules.rules()
    |> Enum.filter(fn rule ->
      String.starts_with?(rule.selector, ".tab:not(") and
        Enum.all?(@resting_exclusions, &String.contains?(rule.selector, &1)) and
        CssRules.declares?(rule.body, "color")
    end)
    |> case do
      [] -> nil
      [rule] -> rule
      many -> flunk("#{length(many)} inactive-tab colour overrides; keep one: #{inspect(many)}")
    end
  end

  defp colour_var(%{body: body}) do
    case Regex.run(~r/(?:^|;)\s*color\s*:\s*var\((--[\w-]+)\)\s*(?:;|$)/, body) do
      [_, var] -> var
      nil -> flunk("the inactive-tab override's colour is not a var(): #{inspect(body)}")
    end
  end

  test "an unlayered override on daisyUI's resting-tab selector exists", %{override: rule} do
    assert rule,
           "no inactive-tab colour rule on daisyUI's resting-tab selector in app.css " <>
             "(.tab:not(...) carrying #{Enum.join(@resting_exclusions, ", ")}); " <>
             "daisyUI's 50% resting tab paints under 4.5:1"

    assert rule.at == [],
           "the override sits inside #{inspect(rule.at)}; daisyUI's .tab rules build into " <>
             "@layer utilities, so a layered override loses there"
  end

  test "the override paints the secondary-text tier, not disabled", %{override: rule} do
    assert rule, "no inactive-tab override in app.css"
    assert colour_var(rule) == "--color-subtle"
  end

  # ── painted contrast ─────────────────────────────────────────────────────

  # {token whose strength is measured, label}. The override's var maps from
  # its @theme colour (--color-subtle) to the block token (--subtle).
  defp painted_token(nil), do: :daisyui
  defp painted_token(rule), do: String.replace_prefix(colour_var(rule), "--color-", "--")

  defp strength(_b, :daisyui) do
    case Regex.run(
           ~r/:not\(:checked, label:has\(:checked\), :hover, \.tab-active, \[aria-selected="true"\]\)'\s*:\s*\{\s*color:\s*"color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)"/,
           File.read!(@daisyui)
         ) do
      [_, pct] -> String.to_integer(pct)
      nil -> flunk("could not read daisyUI's resting-tab colour from #{@daisyui}")
    end
  end

  defp strength(b, token) do
    value = declaration(b.decls, token) || flunk("#{b.id} #{b.mode}: no #{token} declared")

    case Regex.run(@mix_form, value) do
      [_, pct] -> String.to_integer(pct)
      nil -> flunk("#{b.id} #{b.mode}: #{token} is #{inspect(value)}, not base-content at N%")
    end
  end

  defp ratio(b, ground, pct) do
    ink = resolve!(b, "--color-base-content")
    bg = resolve!(b, ground)

    if pct in PaintedComposite.measured_strengths() do
      {r, _formulas} = PaintedComposite.contrast_min(ink, bg, pct)
      r
    else
      W.contrast(W.composite(ink, pct / 100, bg), bg)
    end
  end

  test "inactive-tab text clears 4.5:1 on every ground in all ten painted variants",
       %{blocks: blocks, override: rule} do
    assert length(blocks) == @variants,
           "expected #{@variants} painted variants, read #{length(blocks)}"

    token = painted_token(rule)

    rows =
      for b <- blocks, ground <- @grounds do
        pct = strength(b, token)
        {b.id, b.mode, ground, pct, ratio(b, ground, pct)}
      end

    assert length(rows) == @variants * length(@grounds)

    failures =
      for {id, mode, ground, pct, r} <- rows, r < @aa_text do
        "#{id} #{mode}: inactive tab (#{inspect(token)} at #{pct}%) on #{ground} " <>
          "#{:erlang.float_to_binary(r, decimals: 4)}:1"
      end

    assert failures == [], "under #{@aa_text}:1:\n  " <> Enum.join(failures, "\n  ")
  end

  # ── one source ───────────────────────────────────────────────────────────

  @code_dirs [
    {"apps/platform/lib", "**/*.{ex,heex}"},
    {"apps/social/lib", "**/*.{ex,heex}"},
    {"apps/game_stream/lib", "**/*.{ex,heex}"}
  ]

  @class_expr ~r/class=(?:"([^"]*)"|\{\[(.*?)\]\})/s
  @tab_class ~r/(?:^|["\s])tab(?=["\s])/
  @text_colour ~r/(?:^|["\s])((?:[a-z0-9-]+:)*text-(?!(?:xs|sm|base|lg|[2-9]?xl|left|center|right|start|end|justify|wrap|nowrap|balance|pretty|ellipsis|clip|\[[\d.]+(?:px|rem|em)\])(?:["\s!]|$))[a-z][\w\/\[\]().-]*!?)/

  @doc false
  # [{class_expression, [colour_classes]}] for every class expression in
  # `text` that names the `tab` class.
  def tab_expressions(text) do
    for [_ | groups] <- Regex.scan(@class_expr, text),
        expr = Enum.find(groups, "", &(&1 != "")),
        Regex.match?(@tab_class, ~s(") <> expr <> ~s(")),
        do: {expr, for([_, c] <- Regex.scan(@text_colour, expr), do: c)}
  end

  test "the tab scanner fires on its fixtures and spares the rest" do
    assert [{_, ["text-subtle!"]}] =
             tab_expressions(~s|class={["tab shrink-0", @on && "tab-active", "text-subtle!"]}|)

    assert [{_, ["text-base-content/70"]}] =
             tab_expressions(~s|class="tab text-base-content/70"|)

    assert [{_, []}] = tab_expressions(~s|class={["tab", @on && "tab-active font-semibold"]}|)
    assert [{_, []}] = tab_expressions(~s|class="tab tab-active text-sm"|)
    assert [] = tab_expressions(~s|class="tabs tabs-box text-subtle"|)
    assert [] = tab_expressions(~s|class="sidebar-row text-subtle"|)
  end

  test "no .tab element carries its own text colour class" do
    found =
      for {dir, glob} <- @code_dirs,
          path <- Path.wildcard(Path.join([@root, dir, glob])),
          {expr, colours} <- tab_expressions(File.read!(path)),
          do: {Path.relative_to(path, @root), expr, colours}

    # Anti-vacuity: the real .tab sites (onboarding x2, roles_panel,
    # experiments, social; activity_live while it exists) are all read.
    assert length(found) >= 5, "read only #{length(found)} .tab class expressions"

    offenders =
      for {path, expr, [_ | _] = colours} <- found,
          do: "#{path}: #{inspect(colours)} in #{inspect(expr)}"

    assert offenders == [],
           "a .tab carries its own text colour; the inactive-tab rule in app.css is the " <>
             "one source (task 01a15907 stage 4):\n  " <> Enum.join(offenders, "\n  ")
  end
end
