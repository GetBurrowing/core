defmodule Platform.Design.AgentsMembersSheetsContrastGuardTest do
  @moduledoc """
  Holds the Agents and Members sheets' paint (task 01a1557a-8f80, rung 8
  stage 4) in all ten variants (Burrow, Midnight, Sand, Forest, High
  contrast; light and dark), the way `space_sheet_contrast_guard_test.exs`
  holds rung 7's sheet.

  Both sheets are base-100; a pressed row (and a hovered desktop popover row)
  is base-200. Avatars fill base-200, so an avatar initial sits on base-200.

  ## Pairs and floors

  | pair                                                          | floor |
  |---------------------------------------------------------------|-------|
  | awake agent name: --ag-<slot>-text on base-100 (worst slot)    | 4.5   |
  | awake name pressed / initial: --ag-<slot>-text on base-200     | 4.5   |
  | silenced name: its slot on base-100                            | 4.5   |
  | silenced name pressed / initial: its slot on base-200          | 4.5   |
  | meta and section labels: --subtle on base-100                  | 4.5   |
  | row title / person name: base-content on base-100 and base-200 | 4.5   |
  | switch on: its ink on base-100 and base-200                    | 3     |
  | switch off: daisyUI's 50% base-content, PAINTED, both grounds  | 3     |
  | radio selected: base-content on base-100                       | 3     |
  | radio unselected ring: its border slot on base-100 / base-200  | 3     |
  | awake ring: --ag-<slot> on base-100 (worst slot)               | 3     |
  | online / away / unavailable dot on base-100 and base-200       | 3     |
  | silenced ring: its border slot on base-100                     | 3     |

  ## Method

  The SLOTS are read out of the component source (the dot classes, the
  silenced ring and name, the switch and radio class lists), so the table
  measures what the markup ships rather than what this file assumes. Opaque
  tokens are measured with `WcagContrast.contrast/2`. `--subtle` is alpha over
  its ground, so it is painted on the worst pixel `PaintedComposite` allows,
  as every other sheet guard does.

  The OFF switch is the one pair neither fits: daisyUI's `.toggle` paints its
  border and knob in `color-mix(in oklab, base-content 50%, transparent)`, a
  strength `PaintedComposite` has never been measured at (it raises for one).
  So it is read back from screenshots in headless Chrome by
  `priv/measurements/01a1557a-8f80-sheets-contrast/probe.mjs`, and this guard
  reads that run's `results.json`. The run is held to the current palette:
  each reading's painted ground must be the variant's base-100 / base-200
  bytes, its selected radio dot base-content's, and its class lists the ones
  the components ship; any drift fails with "re-measure".

  Two slots were changed here because they failed (no exemption):

    * away dot and silenced ring: `--edge` (a hairline colour, 1.43-1.61:1
      on base-100, 2.87:1 in high contrast dark) -> `--subtle`;
    * presence-unavailable dot: `--color-neutral` (1.81-2.14:1 on base-100
      in every dark variant) -> `--subtle`;
    * unselected radio ring: daisyUI's 20% `currentColor` (1.6-1.8:1,
      painted) -> `border-subtle`. Chrome's reading of that ring is never
      below the PaintedComposite envelope for `--subtle` (asserted below),
      so the envelope is the conservative figure the table uses. The selected radio keeps base-content:
      `.radio:checked` sets the border to `currentColor` at higher
      specificity.
  """
  use ExUnit.Case, async: true

  alias Platform.Agents.ColorPalette
  alias Platform.Design.PaintedComposite
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @agents_path Path.expand(
                 "../../../lib/platform_web/live/chat/partials/agents_sheet.ex",
                 __DIR__
               )
  @members_path Path.expand(
                  "../../../lib/platform_web/live/chat/members_component.ex",
                  __DIR__
                )
  @painted_path Path.expand(
                  "../../../priv/measurements/01a1557a-8f80-sheets-contrast/results.json",
                  __DIR__
                )

  @aa_text 4.5
  @non_text 3.0

  @variants [
    {"burrow", "light"},
    {"burrow", "dark"},
    {"burrow-midnight", "light"},
    {"burrow-midnight", "dark"},
    {"burrow-sand", "light"},
    {"burrow-sand", "dark"},
    {"burrow-forest", "light"},
    {"burrow-forest", "dark"},
    {"high-contrast", "light"},
    {"high-contrast", "dark"}
  ]

  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/

  setup_all do
    app_css = File.read!(@app_css_path)
    presets = File.read!(@presets_path)

    by_key =
      Map.new(Blocks.preset_blocks(presets), &{{&1.id, &1.mode}, &1})
      |> Map.put({"burrow", "light"}, Blocks.burrow_block(app_css, "light"))
      |> Map.put({"burrow", "dark"}, Blocks.burrow_block(app_css, "dark"))

    # A preset block declares only what it overrides; the element also
    # matches its mode's daisyUI theme block, so an undeclared token
    # (`--color-neutral`) resolves there, as it does on the page.
    blocks =
      for {id, mode} = key <- @variants do
        b = Map.get(by_key, key) || flunk("no #{id} #{mode} block")
        Map.put(b, :fallback, Map.fetch!(by_key, {"burrow", mode}))
      end

    agents = File.read!(@agents_path)
    members = File.read!(@members_path)

    {:ok,
     blocks: blocks,
     agents: agents,
     members: members,
     slots: slots(agents, members),
     painted: @painted_path |> File.read!() |> Jason.decode!()}
  end

  # ── the slots the markup ships ───────────────────────────────────────────

  defp slots(agents, members) do
    dot = fn state ->
      case Regex.run(~r/defp dot_class\("#{state}"\), do: "bg-([a-z0-9-]+)"/, members) do
        [_, slot] -> slot
        nil -> flunk("members_component.ex: no dot_class(\"#{state}\") bg- slot")
      end
    end

    silenced = fn src, file ->
      ring_and_initial =
        Regex.run(
          ~r/do: "border-\(--ag\) text-\(--ag-text\)",\s*else: "border-(\S+) text-(\S+)"/,
          src
        )

      name = Regex.run(~r/do: "text-\(--ag-text\)", else: "text-(\S+)"\)/, src)

      case {ring_and_initial, name} do
        {[_, ring, initial], [_, name]} ->
          %{ring: ring, initial: initial, name: name}

        _ ->
          flunk("#{file}: the silenced ring / initial / name classes moved; re-point the guard")
      end
    end

    switches =
      Regex.scan(~r/role="switch"[^>]*?class="([^"]+)"/s, agents, capture: :all_but_first)

    radios = Regex.scan(~r/type="radio"[^>]*?class="([^"]+)"/s, agents, capture: :all_but_first)

    assert length(switches) == 2, "expected the master and the agent switch in agents_sheet.ex"
    assert length(radios) == 1, "expected one policy radio class list in agents_sheet.ex"

    %{
      online_dot: dot.("online"),
      away_dot: dot.("away"),
      unavailable_dot: unavailable_dot(members),
      agents_silenced: silenced.(agents, "agents_sheet.ex"),
      members_silenced: silenced.(members, "members_component.ex"),
      switches: Enum.map(switches, &hd/1),
      radio: radios |> hd() |> hd()
    }
  end

  defp unavailable_dot(members) do
    case Regex.run(
           ~r/rounded-full bg-([a-z0-9-]+)" aria-hidden="true"><\/span>\s*<span[^>]*>Presence unavailable/,
           members
         ) do
      [_, slot] -> slot
      nil -> flunk("members_component.ex: the 'Presence unavailable' dot moved")
    end
  end

  # The ink a daisyUI toggle paints when ON: a bg- utility on the element (a
  # filled track) wins; otherwise its `toggle-<colour>`.
  defp switch_on_slot(classes) do
    words = String.split(classes)

    Enum.find_value(words, fn w ->
      case Regex.run(~r/^(?:checked:)?bg-([a-z0-9-]+)$/, w) do
        [_, slot] -> slot
        nil -> nil
      end
    end) ||
      Enum.find_value(words, fn w ->
        case Regex.run(
               ~r/^toggle-(primary|secondary|accent|neutral|info|success|warning|error)$/,
               w
             ) do
          [_, slot] -> slot
          nil -> nil
        end
      end) ||
      flunk("switch #{inspect(classes)}: no on colour; daisyUI's default is untested here")
  end

  # The unselected radio ring: a border- utility, or daisyUI's 20% default.
  defp radio_ring_slot(classes) do
    Enum.find_value(String.split(classes), :daisy_default, fn w ->
      case Regex.run(~r/^border-([a-z0-9-]+)$/, w) do
        [_, slot] -> slot
        nil -> nil
      end
    end)
  end

  # ── measuring ────────────────────────────────────────────────────────────

  defp c(b, token) do
    if Blocks.declaration(b.decls, token) || b.fallback == b,
      do: ThemeBlockAssertions.resolve!(b, token),
      else: ThemeBlockAssertions.resolve!(b.fallback, token)
  end

  defp subtle_pct(b) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] ->
        String.to_integer(pct)

      nil ->
        flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard to paint it")
    end
  end

  # A palette slot (the part after `bg-` / `border-` / `text-`) on a ground.
  defp slot_on(b, "subtle", ground) do
    {r, _} =
      PaintedComposite.contrast_min(c(b, "--color-base-content"), c(b, ground), subtle_pct(b))

    r
  end

  defp slot_on(b, slot, ground) do
    if String.contains?(slot, "/") or String.starts_with?(slot, "[") or
         String.starts_with?(slot, "(") do
      flunk("#{slot} is not a palette slot (opacity or arbitrary value)")
    end

    token = if slot == "edge", do: "--edge", else: "--color-#{slot}"
    W.contrast(c(b, token), c(b, ground))
  end

  defp ag_worst(b, suffix, ground) do
    ColorPalette.ids()
    |> Enum.map(&{&1, W.contrast(c(b, "--ag-#{&1}#{suffix}"), c(b, ground))})
    |> Enum.min_by(&elem(&1, 1))
  end

  defp painted_reading(painted, b, ground) do
    Enum.find(
      painted["readings"],
      &(&1["variant"] == "#{b.id} #{b.mode}" and &1["ground"] == ground)
    ) ||
      flunk("results.json has no #{b.id} #{b.mode} #{ground} reading; re-measure")
  end

  defp pairs(b, s, painted) do
    {ag100_slot, ag100} = ag_worst(b, "-text", "--color-base-100")
    {ag200_slot, ag200} = ag_worst(b, "-text", "--color-base-200")
    {ring_slot, ring} = ag_worst(b, "", "--color-base-100")
    off100 = painted_reading(painted, b, "base-100")["switch_off"]["ratio"]
    off200 = painted_reading(painted, b, "base-200")["switch_off"]["ratio"]
    [master_switch, agent_switch] = s.switches

    [
      {"awake name / base-100 (worst: #{ag100_slot})", ag100, @aa_text},
      {"awake name pressed, initial / base-200 (worst: #{ag200_slot})", ag200, @aa_text},
      for {who, sil} <- [{"agents", s.agents_silenced}, {"members", s.members_silenced}] do
        [
          {"#{who} silenced name #{sil.name} / base-100",
           slot_on(b, sil.name, "--color-base-100"), @aa_text},
          {"#{who} silenced name #{sil.name} / base-200",
           slot_on(b, sil.name, "--color-base-200"), @aa_text},
          {"#{who} silenced initial #{sil.initial} / base-200",
           slot_on(b, sil.initial, "--color-base-200"), @aa_text},
          {"#{who} silenced ring #{sil.ring} / base-100",
           slot_on(b, sil.ring, "--color-base-100"), @non_text}
        ]
      end,
      {"meta, labels subtle / base-100", slot_on(b, "subtle", "--color-base-100"), @aa_text},
      {"title base-content / base-100", slot_on(b, "base-content", "--color-base-100"), @aa_text},
      {"title pressed base-content / base-200", slot_on(b, "base-content", "--color-base-200"),
       @aa_text},
      for {label, cls} <- [{"master", master_switch}, {"agent", agent_switch}],
          ground <- ["--color-base-100", "--color-base-200"] do
        slot = switch_on_slot(cls)

        {"#{label} switch on #{slot} / #{String.trim_leading(ground, "--color-")}",
         slot_on(b, slot, ground), @non_text}
      end,
      {"switch off / base-100 (painted, Chrome)", off100, @non_text},
      {"switch off / base-200 (painted, Chrome)", off200, @non_text},
      {"radio selected base-content / base-100", slot_on(b, "base-content", "--color-base-100"),
       @non_text},
      for ground <- ["base-100", "base-200"] do
        case radio_ring_slot(s.radio) do
          # daisyUI's own 20% ring is an unmeasured strength: the Chrome reading.
          :daisy_default ->
            {"radio ring daisyUI 20% / #{ground} (painted, Chrome)",
             painted_reading(painted, b, ground)["radio_off"]["ratio"], @non_text}

          slot ->
            {"radio ring #{slot} / #{ground}", slot_on(b, slot, "--color-#{ground}"), @non_text}
        end
      end,
      {"awake ring / base-100 (worst: #{ring_slot})", ring, @non_text},
      for {label, slot} <- [
            {"online dot", s.online_dot},
            {"away dot", s.away_dot},
            {"unavailable dot", s.unavailable_dot}
          ],
          ground <- ["--color-base-100", "--color-base-200"] do
        {"#{label} #{slot} / #{String.trim_leading(ground, "--color-")}",
         slot_on(b, slot, ground), @non_text}
      end
    ]
    |> List.flatten()
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  # ── tests ────────────────────────────────────────────────────────────────

  test "every pair clears its floor in all ten variants; the table prints", %{
    blocks: blocks,
    slots: slots,
    painted: painted
  } do
    assert length(blocks) == 10

    rows = for b <- blocks, do: {b, pairs(b, slots, painted)}

    IO.puts(
      "\nAgents and Members sheets AA table (WCAG 2.x; --subtle on the worst PaintedComposite pixel, " <>
        "the off switch read back from Chrome):\n" <>
        "| Pair | floor | " <>
        Enum.map_join(blocks, " | ", &"#{&1.id} #{&1.mode}") <>
        " |\n|---|---|" <>
        String.duplicate("---|", length(blocks)) <>
        "\n" <>
        (rows
         |> hd()
         |> elem(1)
         |> Enum.with_index()
         |> Enum.map_join("\n", fn {{label, _, floor}, i} ->
           "| #{label} | #{floor} | " <>
             Enum.map_join(rows, " | ", fn {_, ps} -> ps |> Enum.at(i) |> elem(1) |> f4() end) <>
             " |"
         end))
    )

    failures =
      for {b, ps} <- rows, {label, r, floor} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == [], Enum.join(failures, "\n")
  end

  test "the slots the markup ships are the ones this table names", %{slots: s} do
    assert s.online_dot == "success"
    assert s.away_dot == "subtle"
    assert s.unavailable_dot == "subtle"

    for sil <- [s.agents_silenced, s.members_silenced] do
      assert sil == %{ring: "subtle", initial: "subtle", name: "subtle"}
    end

    assert s.switches == ["toggle toggle-primary", "toggle toggle-primary"]
    assert s.radio == "radio radio-sm border-subtle text-base-content"
  end

  test "the Chrome run measured the class lists the components ship, under today's palette", %{
    blocks: blocks,
    slots: s,
    painted: painted
  } do
    classes = painted["classes"]

    for key <- ["switch_off", "switch_on"],
        do:
          assert(classes[key] =~ ~s(class="#{hd(s.switches)}"), "re-measure: switch class moved")

    for key <- ["radio_off", "radio_on"],
        do: assert(classes[key] =~ ~s(class="#{s.radio}"), "re-measure: radio class moved")

    assert length(painted["readings"]) == 20

    for b <- blocks, ground <- ["base-100", "base-200"] do
      r = painted_reading(painted, b, ground)

      hex = fn token ->
        "#" <> (c(b, token) |> W.to_hex() |> String.trim_leading("#") |> String.downcase())
      end

      assert r["ground_painted"] == hex.("--color-#{ground}"),
             "re-measure: #{b.id} #{b.mode} #{ground} painted #{r["ground_painted"]}, " <>
               "the palette now declares #{hex.("--color-#{ground}")}"

      assert r["radio_on"]["painted"] == hex.("--color-base-content"),
             "re-measure: #{b.id} #{b.mode} base-content moved since the run"

      assert r["switch_on"]["painted"] == hex.("--color-primary"),
             "re-measure: #{b.id} #{b.mode} primary moved since the run"
    end
  end

  test "Chrome's unselected-ring reading is never below the --subtle envelope", %{
    blocks: blocks,
    painted: painted
  } do
    for b <- blocks, ground <- ["base-100", "base-200"] do
      chrome = painted_reading(painted, b, ground)["radio_off"]["ratio"]
      envelope = slot_on(b, "subtle", "--color-#{ground}")

      assert chrome >= envelope - 1.0e-4,
             "#{b.id} #{b.mode} #{ground}: Chrome painted #{f4(chrome)}, under the envelope #{f4(envelope)}"
    end
  end

  test "the off switch's painted reading is daisyUI's 50% path, not a token", %{painted: painted} do
    # Anti-vacuity: the off knob is neither ground nor ink, so the run did read a composite.
    for r <- painted["readings"] do
      off = r["switch_off"]["painted"]
      refute off == r["ground_painted"], "#{r["variant"]}: the off switch read back as its ground"
      refute off == r["radio_on"]["painted"], "#{r["variant"]}: the off switch read back opaque"
    end
  end

  test "no hover on phone rows, no error colour, no opacity text, no colour literal", %{
    agents: agents,
    members: members
  } do
    for {name, src} <- [{"agents_sheet.ex", agents}, {"members_component.ex", members}] do
      assert String.length(src) > 2_000, "#{name}: read back a near-empty source"
      # Present first, so the refutes cannot pass on a moved file.
      assert src =~ "text-subtle"
      assert src =~ "active:bg-base-200"

      refute Regex.match?(~r/(?<![a-z:])hover:/, src), "#{name}: hover: outside lg:hover:"
      refute src =~ "text-error", "#{name}: text-error"
      refute src =~ "text-base-content/", "#{name}: opacity text"

      refute Regex.match?(~r/#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b(?!\{)/, src),
             "#{name}: hex literal"
    end
  end
end
