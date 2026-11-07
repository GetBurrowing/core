defmodule Platform.Agents.CharacterPortsTest do
  @moduledoc """
  The pure ports in `Platform.Agents.Character` against the comp's own
  output: every case in `test/fixtures/character/comp.json` was computed by
  running the comp's `vPromptLines`, `vReply`, `firstLine` and `voiceSample`
  in node once (see `Platform.Agents.ArchetypesTest`).
  """
  use ExUnit.Case, async: true

  alias Platform.Agents.{Archetypes, Character}

  @comp "../../fixtures/character/comp.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

  defp vc(c), do: %{p: c["p"], ov: c["ov"], q: c["q"] || "pr", free: c["free"]}

  defp b(c) do
    %{
      cls: c["cls"] || "builder",
      sl: c["sl"],
      traits: c["traits"],
      line: c["cls"] && Archetypes.fetch(c["cls"]).line
    }
  end

  test "vPromptLines is byte-equal to the comp for every preset and every knob override" do
    cases = @comp["prompt_lines"]
    # 5 presets, each alone and with every non-default value of each knob.
    assert length(cases) == 35

    for c <- cases do
      assert Character.v_prompt_lines(vc(c)) == c["lines"], inspect({c["p"], c["ov"]})
    end
  end

  test "vReply is byte-equal to the comp for every voice, prompt and viewer" do
    cases = @comp["replies"]
    assert length(cases) == 420

    for c <- cases do
      assert Character.v_reply(vc(c), c["who"], c["viewer"]) == c["lines"],
             inspect({c["p"], c["ov"], c["q"], c["free"], c["viewer"]})
    end
  end

  test "firstLine is byte-equal to the comp for every class, dial set and viewer" do
    for c <- @comp["first_lines"] do
      assert Character.first_line(b(c), c["viewer"]) == c["text"], inspect(c)
    end
  end

  test "voiceSample is byte-equal to the comp" do
    for c <- @comp["voice_samples"] do
      assert Character.voice_sample(%{sl: c["sl"], traits: c["traits"]}) == c["text"],
             inspect(c)
    end
  end

  describe "the builder state" do
    test "a fresh character takes its class's defaults and skips used names" do
      b = Character.new("scout", used_names: ["Wren"])
      assert b.cls == "scout"
      assert b.n == "Kestrel"
      assert b.color == "teal"
      assert b.portrait == "owl"
      assert b.toolkit == ["read", "web", "memory", "canvases"]
      assert b.vc.p == 2
    end

    test "a class change keeps every touched field and resets the rest" do
      b =
        Character.new("scout")
        |> Map.merge(%{color: "rose", n: "Margo"})
        |> Map.put(:touched, MapSet.new(["color", "name"]))
        |> Character.apply_class("scribe")

      assert b.color == "rose"
      assert b.n == "Margo"
      assert b.portrait == "quill"
      assert b.sl == Archetypes.fetch("scribe").sl
      assert b.traits == Archetypes.fetch("scribe").traits
      assert b.toolkit == Archetypes.fetch("scribe").toolkit
      assert b.vc.p == 3
    end

    test "an untouched name is re-rolled from the new class's pool" do
      b = Character.new("scout") |> Character.apply_class("producer")
      assert b.n in Archetypes.fetch("producer").names
      assert b.color == "amber"
    end
  end

  describe "the three files" do
    setup do
      b =
        Character.new("scout")
        |> Map.merge(%{
          n: "Lark",
          color: "indigo",
          portrait: "fox",
          sl: %{"chatty" => 20, "bold" => 80, "playful" => 10, "collab" => 90},
          traits: ["skeptic", "tidy", "night owl"],
          vc: %{p: 3, ov: %{"emoji" => 1}, q: "pr", free: nil}
        })

      %{b: b}
    end

    test "SOUL.md holds each dial and its lean, the traits, the first line, then Voice", %{b: b} do
      soul = Character.soul_md(b)

      assert soul =~ "## Personality"
      assert soul =~ "- Terse ↔ Chatty: 20 (Terse)"
      assert soul =~ "- Careful ↔ Bold: 80 (Bold)"
      assert soul =~ "- Formal ↔ Playful: 10 (Formal)"
      assert soul =~ "- Solo ↔ Collaborative: 90 (Collaborative)"
      assert soul =~ "Traits: skeptic, tidy, night owl"
      assert soul =~ "First line: “" <> Character.first_line(b) <> "”"

      [_, voice] = String.split(soul, "## Voice\n\n")
      assert String.starts_with?(voice, "Voice: professional.")
      assert voice =~ "Emoji sparingly, at most one per reply."
      assert voice == Enum.join(Character.v_prompt_lines(b.vc), "\n") <> "\n"
      assert String.split(soul, "## Personality") |> hd() |> String.contains?("SOUL.md")
    end

    test "IDENTITY.md holds the name, handle, class, portrait and slot", %{b: b} do
      identity = Character.identity_md(b)

      for s <- [
            "- Name: Lark",
            "- Handle: @Lark",
            "- Class: 🔭 Scout",
            "- Portrait: fox",
            "- Colour: indigo"
          ] do
        assert identity =~ s
      end
    end

    test "TOOLS.md lists the toolkit labels", %{b: b} do
      tools = Character.tools_md(b)

      for label <- ["Read & reply", "Web search", "Org memory", "Canvases"],
          do: assert(tools =~ label)

      refute tools =~ "Ship to main"
    end

    test "the card shows what the comp's card shows", %{b: b} do
      card = Character.card(b, number: 7)
      assert card.name == "Lark"
      assert card.class == "🔭 Scout"
      assert card.colour == "Indigo"
      assert card.template == "template · Researcher"
      assert card.vibe == "Finds things out before you think to ask"

      assert Enum.map(card.stats, &{&1.label, &1.value}) ==
               [{"Terse", 80}, {"Bold", 80}, {"Formal", 90}, {"Collaborative", 90}]

      assert card.talks_like == "💼 Professional"
      assert card.footer == "Burrow"
      assert card.number == "007"
      assert Character.card(Character.new("wildcard")).template == "custom"
    end
  end
end
