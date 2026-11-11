defmodule Platform.Agents.ArchetypesTest do
  @moduledoc """
  `Platform.Agents.Archetypes` against the comp's own data.

  `test/fixtures/character/comp.json` was produced once by running the comp
  (burrow-data.js `studio()` and the burrow-agents.js voice block) in node,
  with the generic copy that replaces the comp's real names substituted
  before it ran. It holds no paths.
  """
  use ExUnit.Case, async: true

  alias Platform.Agents.{Archetypes, ColorPalette}
  alias PlatformWeb.AgentPortrait
  alias PlatformWeb.ControlCenter.OnboardingEvents

  @comp "../../fixtures/character/comp.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

  @templates %{
    "builder" => "architect",
    "scout" => "researcher",
    "scribe" => "writer",
    "strategist" => "analyst",
    "producer" => "pm",
    "wildcard" => nil
  }

  test "the six classes equal the comp's ARCHETYPES, field for field" do
    ours =
      Enum.map(Archetypes.all(), fn a ->
        %{
          "id" => a.id,
          "n" => a.n,
          "glyph" => a.glyph,
          "vibe" => a.vibe,
          "template" => a.template_label,
          "color" => a.color,
          "portrait" => a.portrait,
          "toolkit" => a.toolkit,
          "names" => a.names,
          "sl" => a.sl,
          "traits" => a.traits,
          "line" => a.line
        }
      end)

    assert ours == @comp["archetypes"]
  end

  test "each class maps onto its role template, and every template id exists" do
    assert Map.new(Archetypes.all(), &{&1.id, &1.template}) == @templates

    template_ids = Enum.map(OnboardingEvents.role_templates(), & &1.id)

    for a <- Archetypes.all(), a.template do
      assert a.template in template_ids, "#{a.id} names a missing template #{a.template}"
    end

    # The comp's label names the same template the id resolves to.
    for a <- Archetypes.all(), a.template do
      template = Enum.find(OnboardingEvents.role_templates(), &(&1.id == a.template))
      assert template.name == a.template_label
    end
  end

  test "the dials, traits, portraits and toolkit equal the comp's" do
    assert Enum.map(Archetypes.sliders(), &%{"k" => &1.k, "lo" => &1.lo, "hi" => &1.hi}) ==
             @comp["sliders"]

    assert Archetypes.traits() == @comp["traits"]
    assert length(Archetypes.traits()) == 14
    assert Archetypes.portraits() == @comp["portraits"]
    assert length(Archetypes.portraits()) == 8

    assert Enum.map(Archetypes.toolkit(), &%{"id" => &1.id, "ic" => &1.ic, "t" => &1.t}) ==
             @comp["toolkit"]

    assert length(Archetypes.toolkit()) == 10
  end

  test "the comp's palette is the platform's first ten agent slots, the six appended after" do
    # The comp drew the masters' ten; ColorPalette appended six on 2026-11-11
    # (append only), so the comp's ten are its prefix in the comp's order.
    palette = Enum.map(ColorPalette.all(), &%{"id" => &1.id, "label" => &1.label})
    assert Enum.take(palette, 10) == @comp["palette"]
    assert length(palette) == 16

    for a <- Archetypes.all(), do: assert(a.color in ColorPalette.ids())
  end

  test "the voices, knobs, presets and rules equal the comp's" do
    assert Enum.map(
             Archetypes.voices(),
             &%{
               "key" => &1.key,
               "n" => &1.n,
               "s" => &1.s,
               "ic" => &1.ic,
               "blurb" => &1.blurb,
               "rule" => &1.rule
             }
           ) == @comp["voices"]

    assert Enum.map(Archetypes.knobs(), &[&1.k, &1.label, &1.options]) == @comp["knobs"]
    assert Archetypes.vdef() == @comp["vdef"]
    assert Archetypes.class_voices() == @comp["class_voice"]
    assert Archetypes.len_rules() == @comp["len_rule"]
    assert Archetypes.why_rules() == @comp["why_rule"]

    assert Enum.map(
             Archetypes.samples(),
             &%{
               "id" => &1.id,
               "q" => &1.q,
               "em" => &1.em,
               "useful" => &1.useful,
               "r" => &1.r,
               "why" => &1.why,
               "more" => &1.more
             }
           ) == @comp["samples"]
  end

  test "the portrait component draws the comp's eight SVGs, verbatim" do
    assert Enum.sort(AgentPortrait.ids()) == Enum.sort(@comp["portraits"])

    for id <- @comp["portraits"] do
      assert AgentPortrait.svg(id) == @comp["portrait_svg"][id], id
    end
  end
end
