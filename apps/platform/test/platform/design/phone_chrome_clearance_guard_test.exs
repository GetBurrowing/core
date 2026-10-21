defmodule Platform.Design.PhoneChromeClearanceGuardTest do
  @moduledoc """
  Guards the END padding of phone scrollers against the glass tab bar (task
  01a15f2e-80cd-7000-8990-3b721f8bd938, stage 1; Saru's canvas
  01a15f2f-5a5f-7000-8d85-1e9717443a8b, rule "Other scrollers").

  Content scrolls UNDER the glass bar, so a scroller's last row must end above
  the bar's top edge. The one sanctioned way to say that is
  `--phone-chrome-bottom` (the bar's top edge, `--bottom-nav-clearance`, plus
  8px), reached through the `.clears-tab-bar` class.

  ## The four checks

    (a) Every app.css rule whose selector names `.clears-tab-bar` pads by
        `var(--phone-chrome-bottom)` and nothing else, and the token is
        declared in the top-level `:root` as
        `calc(var(--bottom-nav-clearance) + 8px)`. Rules are read with
        `Platform.Design.CssRules`, not a line grep.
    (b) The `clears-tab-bar` class is in use: a non-empty inventory of the
        quoted class strings that carry it in `lib/platform_web/**/*.{ex,heex}`,
        with a positive floor of four surfaces named by the ticket.
    (c) Every `pb-[...]` utility, and every `padding-bottom` declaration, in
        those files that references `--bottom-nav-height` or
        `--bottom-nav-clearance` sits in `@allowlist`. The allowlist is FROZEN
        and SHRINK-ONLY: a new occurrence fails; an entry whose count drops
        fails until the entry is lowered or removed. These older scrollers
        pad by `env(safe-area-inset-bottom) + var(--bottom-nav-height)`, which
        stage 1 made equal to the bar's top edge at every inset, so they are
        correct but carry their own breathing room; new code uses
        `.clears-tab-bar` / `--phone-chrome-bottom`.
    (d) Positive controls: the scanners report a synthetic, non-allowlisted
        scroller and count a synthetic `clears-tab-bar` class.

  ## Out of scope, on purpose

  Positional `bottom-[...]` offsets (FABs, toasts, side panels, sheets, the
  meeting mini bar) are NOT padding and are outside this inventory. They ride
  on the same `env(safe-area-inset-bottom) + var(--bottom-nav-height)` sum and
  are checked in the browser, not here. Desktop is out of scope: the
  `.clears-tab-bar` rule lives inside `@media (max-width: 1023.98px)`.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.CssRules

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @lib_root Path.expand("../../../lib/platform_web", __DIR__)
  @phone "@media (max-width: 1023.98px)"
  @chat_zone "#chat-drop-zone:has(> .chat-dock--glass)"

  # {file relative to lib/platform_web, exact class token} => {count, reason}.
  # Seeded from the planning grep at bbe3a040 and re-grepped at stage 1.
  # SHRINK-ONLY: lower a count or delete an entry when a site migrates to
  # `.clears-tab-bar`; never add one.
  @allowlist %{
    {"live/admin_vault_live.html.heex",
     "pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px)+1rem)]"} =>
      {1, "vault page scroller, predates .clears-tab-bar; carries its own 1rem"},
    {"components/meetings/call_recap.ex",
     "pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px)+1rem)]"} =>
      {1, "call recap shares the guest surface where the bar is absent (0px)"},
    {"components/canvases/prototype_frame.ex",
     "pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px)+0.75rem)]"} =>
      {1, "full-screen prototype footer, its own 0.75rem gap"},
    {"live/org_memory_live/mobile_shell.ex",
     "pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))]"} =>
      {1, "org memory mobile shell, ends exactly at the bar's top edge"},
    {"live/meeting_live.html.heex", "pb-[calc(0.5rem+var(--bottom-nav-clearance))]"} =>
      {1, "meeting control dock, height paired with h-[calc(96px+clearance)]"},
    {"live/meeting_live.html.heex",
     "pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px)+5rem)]"} =>
      {1, "meeting panel scroller clearing the bar and the control dock"},
    {"live/meeting_live.html.heex",
     "pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px)+4rem)]"} =>
      {3, "meeting side panels clearing the bar and the control dock"},
    {"live/email_live.html.heex",
     "pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px)+1rem)]"} =>
      {1, "email page scroller, predates .clears-tab-bar; carries its own 1rem"},
    {"live/tasks/canvas_picker_component.ex",
     "pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))]"} =>
      {1, "canvas picker sheet, ends exactly at the bar's top edge"}
  }

  @floor [
    "live/inbox_live.html.heex",
    "live/settings_live.ex",
    "live/tasks/my_tasks_list.ex",
    "live/files_live.html.heex"
  ]

  @bar_vars ~r/--bottom-nav-height|--bottom-nav-clearance/
  @pb_token ~r/(?<![\w-])(?:[a-z0-9-]+:)*pb-\[[^\]\s"'<>]*\]/
  @padding_bottom ~r/padding-bottom\s*:\s*[^;"']*/

  setup_all do
    sources =
      @lib_root
      |> Path.join("**/*.{ex,heex}")
      |> Path.wildcard()
      |> Map.new(&{Path.relative_to(&1, @lib_root), File.read!(&1)})

    {:ok, sources: sources, rules: CssRules.rules(File.read!(@app_css_path))}
  end

  describe "(a) the .clears-tab-bar rule pads by --phone-chrome-bottom" do
    test "every rule naming .clears-tab-bar declares exactly that bottom padding",
         %{rules: rules} do
      hits = Enum.filter(rules, &(&1.selector =~ ~r/\.clears-tab-bar(?![\w-])/))
      assert hits != [], "no app.css rule names .clears-tab-bar"

      for r <- hits do
        assert r.at == ["@media (max-width: 1023.98px)"],
               "#{r.selector} sits in #{inspect(r.at)}, not below lg only"

        assert declarations(r.body, "padding-bottom") == ["var(--phone-chrome-bottom)"],
               "#{r.selector} pads by #{inspect(declarations(r.body, "padding-bottom"))}"

        for prop <- ["padding", "padding-block", "padding-block-end"] do
          assert declarations(r.body, prop) == [],
                 "#{r.selector} sets #{prop}, a second bottom padding"
        end
      end
    end

    test "--phone-chrome-bottom is the bar's top edge plus 8px, in the top-level :root",
         %{rules: rules} do
      values =
        for r <- rules,
            r.selector == ":root" and r.at == [],
            v <- declarations(r.body, "--phone-chrome-bottom"),
            do: normalise(v)

      assert values == ["calc(var(--bottom-nav-clearance) + 8px)"]

      redeclared =
        for r <- rules,
            not (r.selector == ":root" and r.at == []),
            declarations(r.body, "--phone-chrome-bottom") != [],
            do: {r.at, r.selector}

      # Exactly one override, the chat dock's (stage 3, section (e) below).
      assert redeclared == [{[@phone], @chat_zone}],
             "--phone-chrome-bottom is overridden: #{inspect(redeclared)}"
    end
  end

  describe "(f) a composer inside a sheet has no bar under it (task 01a15f2e follow-up)" do
    test "below lg it sits 8px above the safe area; the routed rules are unchanged",
         %{rules: rules} do
      sheet = Enum.filter(rules, &(&1.selector == ".sheet-panel .compose-input-area"))
      assert length(sheet) == 1, "anti-vacuity: the sheet composer rule was not found"
      [r] = sheet
      assert r.at == [@phone]

      assert Enum.map(declarations(r.body, "padding-bottom"), &normalise/1) ==
               ["calc(8px + env(safe-area-inset-bottom, 0px))"]

      # The routed and glass-dock composer rules are exactly as shipped.
      [routed] =
        Enum.filter(
          rules,
          &(&1.selector == ".compose-input-area" and &1.at == [@phone] and
              declarations(&1.body, "padding-bottom") != [])
        )

      assert Enum.map(declarations(routed.body, "padding-bottom"), &normalise/1) ==
               ["calc(8px + var(--bottom-nav-clearance))"]

      [dock] = Enum.filter(rules, &(&1.selector == ".chat-dock--glass .compose-input-area"))
      assert declarations(dock.body, "padding-bottom") == ["0"]

      # Keyed on the Sheet component, never on a meeting-specific class.
      meeting =
        for x <- rules,
            x.selector =~ "compose-input-area",
            x.selector =~ ~r/meeting/,
            do: x.selector

      assert meeting == []
    end
  end

  describe "(e) the chat dock (stage 3)" do
    test "top-level .chat-dock is display: contents, so desktop and embedded keep their flex layout",
         %{rules: rules} do
      top = Enum.filter(rules, &(&1.selector == ".chat-dock" and &1.at == []))
      assert length(top) == 1
      assert declarations(hd(top).body, "display") == ["contents"]

      # Nothing else may give the bare wrapper a box at any width.
      boxed =
        for r <- rules,
            r.selector =~ ~r/\.chat-dock(?![\w-])/,
            not (r.selector =~ "chat-dock--glass"),
            declarations(r.body, "display") not in [[], ["contents"]],
            do: {r.at, r.selector}

      assert boxed == []
    end

    test "every .chat-dock--glass rule sits inside the max-lg media", %{rules: rules} do
      glass = Enum.filter(rules, &(&1.selector =~ "chat-dock--glass"))
      assert length(glass) >= 5, "anti-vacuity: the glass dock rules were not found"

      outside = for r <- glass, List.first(r.at) != @phone, do: {r.at, r.selector}
      assert outside == []

      [dock] = Enum.filter(glass, &(&1.selector == ".chat-dock.chat-dock--glass"))
      assert declarations(dock.body, "position") == ["absolute"]
      assert declarations(dock.body, "pointer-events") == ["none"]

      assert normalise(hd(declarations(dock.body, "padding-bottom"))) ==
               "calc(8px + var(--bottom-nav-clearance))"
    end

    test "the typing band's glass is the tab bar's own declarations, with the same fallback",
         %{rules: rules} do
      # A shared rule is impossible (stage 3 report): the bar's glass must stay
      # in its top-level `.bottom-nav` rule for the painted fixtures, while the
      # band must sit below lg because `.chat-dock--glass` exists at desktop.
      # So the copy is pinned equal instead.
      [bar] =
        Enum.filter(
          rules,
          &(&1.selector == ".bottom-nav" and &1.at == [] and
              declarations(&1.body, "background") != [])
        )

      band_sel = ".chat-dock--glass > [data-role=\"typing-indicator\"]"
      [band] = Enum.filter(rules, &(&1.selector == band_sel and &1.at == [@phone]))

      for prop <- ~w(background -webkit-backdrop-filter backdrop-filter border) do
        assert declarations(bar.body, prop) != [], "the bar lost #{prop}"

        assert Enum.map(declarations(band.body, prop), &normalise/1) ==
                 Enum.map(declarations(bar.body, prop), &normalise/1),
               "typing band #{prop} differs from the bar's"
      end

      refute Enum.any?(
               rules,
               &(&1.selector == band_sel and declarations(&1.body, "box-shadow") != [])
             )

      fb_at = "@media (prefers-reduced-transparency: reduce)"
      [bar_fb] = Enum.filter(rules, &(&1.selector == ".bottom-nav" and &1.at == [fb_at]))
      [band_fb] = Enum.filter(rules, &(&1.selector == band_sel and &1.at == [@phone, fb_at]))

      for prop <-
            ~w(--glass-alpha --glass-blur background -webkit-backdrop-filter backdrop-filter) do
        assert declarations(band_fb.body, prop) == declarations(bar_fb.body, prop),
               "typing band fallback #{prop} differs from the bar's"
      end
    end

    test "the chat override of --phone-chrome-bottom is the dock height plus 8px",
         %{rules: rules} do
      [zone] = Enum.filter(rules, &(&1.selector == @chat_zone and &1.at == [@phone]))
      [value] = declarations(zone.body, "--phone-chrome-bottom")

      assert normalise(value) ==
               "calc(var(--chat-dock-h, calc(var(--bottom-nav-clearance) + 60px)) + 8px)"
    end

    test "the timeline's end padding is var(--phone-chrome-bottom), not a constant",
         %{rules: rules} do
      list =
        Enum.filter(
          rules,
          &(&1.selector =~ "#message-list" and &1.selector =~ "chat-dock--glass")
        )

      assert length(list) == 1
      [r] = list
      assert r.at == [@phone]
      assert declarations(r.body, "padding-bottom") == ["var(--phone-chrome-bottom)"]

      # No other #message-list rule below lg pads its end.
      others =
        for x <- rules,
            x.selector =~ ~r/#message-list(?![\w-])/,
            x != r,
            declarations(x.body, "padding-bottom") != [] or
              declarations(x.body, "padding") != [],
            do: {x.at, x.selector}

      assert others == []
    end
  end

  describe "(b) the clears-tab-bar inventory" do
    test "is non-empty and holds the positive floor", %{sources: sources} do
      files =
        for {file, text} <- sources, clears_tab_bar_count(text) > 0, into: MapSet.new(), do: file

      assert MapSet.size(files) > 0

      for f <- @floor do
        assert f in files, "#{f} no longer carries clears-tab-bar"
      end
    end
  end

  describe "(c) inline scroll-end padding against the bar" do
    test "is either --phone-chrome-bottom or a frozen, shrink-only allowlist entry",
         %{sources: sources} do
      found =
        sources
        |> Enum.flat_map(fn {file, text} -> Enum.map(bar_paddings(text), &{file, &1}) end)
        |> Enum.frequencies()

      new =
        for {key, n} <- found,
            n > elem(Map.get(@allowlist, key, {0, nil}), 0),
            do: {key, n}

      assert new == [],
             "new scroll-end padding against the bar; use .clears-tab-bar " <>
               "(--phone-chrome-bottom) instead: #{inspect(new, pretty: true)}"

      stale =
        for {key, {n, _reason}} <- @allowlist,
            Map.get(found, key, 0) < n,
            do: {key, n, Map.get(found, key, 0)}

      assert stale == [],
             "allowlist entries no longer found as often as recorded; remove it " <>
               "(or lower its count): #{inspect(stale, pretty: true)}"
    end

    test "every allowlist entry has a reason and references a bar token" do
      for {{file, token}, {n, reason}} <- @allowlist do
        assert is_integer(n) and n > 0, inspect(file)
        assert is_binary(reason) and String.length(reason) > 10, inspect(file)
        assert token =~ @bar_vars, token
      end
    end
  end

  describe "(d) positive controls" do
    test "a synthetic non-allowlisted scroller is reported" do
      text =
        ~s|<div class="overflow-y-auto pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px)+1rem)]">|

      assert bar_paddings(text) == [
               "pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px)+1rem)]"
             ]

      refute Map.has_key?(@allowlist, {"live/synthetic.html.heex", hd(bar_paddings(text))})

      style = ~s|<div style="padding-bottom: calc(var(--bottom-nav-clearance) + 2px)">|
      assert bar_paddings(style) == ["padding-bottom: calc(var(--bottom-nav-clearance) + 2px)"]

      assert bar_paddings(~s|<div class="pb-[var(--phone-chrome-bottom)]">|) == []
    end

    test "a synthetic clears-tab-bar class is counted" do
      assert clears_tab_bar_count(~s|<div class="x clears-tab-bar">|) == 1
      assert clears_tab_bar_count(~s|<%!-- clears-tab-bar in prose --%>|) == 0
      assert clears_tab_bar_count(~s|<div class="x clears-tab-bar-ish">|) == 0
    end
  end

  # Inline paddings that reference a bar token: `pb-[...]` utilities (with any
  # variant prefix) and `padding-bottom:` declarations.
  defp bar_paddings(text) do
    pbs = for [t] <- Regex.scan(@pb_token, text), t =~ @bar_vars, do: t
    decls = for [d] <- Regex.scan(@padding_bottom, text), d =~ @bar_vars, do: String.trim(d)
    pbs ++ decls
  end

  # Quoted strings carrying the class token, after HEEx and HTML comments are
  # stripped (prose mentions are not uses).
  defp clears_tab_bar_count(text) do
    text = Regex.replace(~r/<%!--.*?--%>|<!--.*?-->/s, text, "")

    ~r/"[^"\n]*"/
    |> Regex.scan(text)
    |> Enum.count(fn [s] -> s =~ ~r/(?<![\w-])clears-tab-bar(?![\w-])/ end)
  end

  defp declarations(body, prop) do
    ~r/(?:^|[;{])\s*#{Regex.escape(prop)}\s*:\s*([^;]+);/m
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [v] -> String.trim(v) end)
  end

  defp normalise(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\(\s+/, "(")
    |> String.replace(~r/\s+\)/, ")")
    |> String.trim()
  end
end
