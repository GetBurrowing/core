defmodule PlatformWeb.Components.Meetings.CandidateDisplayTest do
  @moduledoc """
  The two strings that were never brought under `CandidateDisplay`
  (task 01a05997 stage 2): the intents rail's target chip and its
  classified-intent label.

  The chip is the reason this exists. `IntentClassifier` lands the
  SENTINEL STRING `"null"` in `target_role` for an unrouted intent, and
  a non-empty binary is truthy, so the rail's old
  `slug || role || "unassigned"` chain stopped at the sentinel and every
  unrouted intent rendered `@null` to a meeting participant. The
  `"unassigned"` third term was unreachable.
  """
  use ExUnit.Case, async: true

  alias PlatformWeb.Components.Meetings.CandidateDisplay

  describe "target_label/2" do
    test "the classifier's \"null\" sentinel never reaches the DOM" do
      label = CandidateDisplay.target_label(nil, "null")

      # The assertion that detonates on the old inline expression, which
      # produced "@null" for exactly this input.
      refute label =~ "null"
      assert label == "unassigned"
    end

    test "the unassigned affordance carries no @ prefix" do
      # An `@` is an at-mention of a person. Nobody is being mentioned.
      refute CandidateDisplay.target_label(nil, "null") =~ "@"
      refute CandidateDisplay.target_label(nil, nil) =~ "@"
      refute CandidateDisplay.target_label("", "") =~ "@"
    end

    test "a real agent slug wins over the sentinel and gets the @" do
      assert CandidateDisplay.target_label("octavius", "null") == "@octavius"
      assert CandidateDisplay.target_label("octavius", "triage_officer") == "@octavius"
    end

    test "a blank slug is treated as absent, not rendered as @" do
      assert CandidateDisplay.target_label("", "triage_officer") == "Triage officer"
      assert CandidateDisplay.target_label("   ", "null") == "unassigned"
    end

    test "each known role key renders a human label, not the column value" do
      assert CandidateDisplay.target_label(nil, "triage_officer") == "Triage officer"
      assert CandidateDisplay.target_label(nil, "meeting_scribe") == "Meeting scribe"
      assert CandidateDisplay.target_label(nil, "historian") == "Historian"
      assert CandidateDisplay.target_label(nil, "designer") == "Designer"
    end

    test "an unmapped role key is humanised, never printed raw, never crashes" do
      # FINDING against the stage spec, which asked for no catch-all:
      # `IntentClassifier.normalise_target_role/1` accepts ANY binary the
      # model emits, so a total function over the four known role keys
      # would raise inside the live rail on a novel model output — a
      # worse failure than the `@null` this fixes. The invariant that
      # actually matters is that the stored token never reaches the DOM.
      label = CandidateDisplay.target_label(nil, "some_unmapped_role")

      refute label =~ "_"
      refute label =~ "@"
      assert label == "Some unmapped role"
    end
  end

  describe "intent_label/1" do
    test "maps every known classified_intent to copy" do
      assert CandidateDisplay.intent_label("off_topic") == "Off topic"
      assert CandidateDisplay.intent_label("action_items") == "Action items"
      assert CandidateDisplay.intent_label("brief_worthy") == "Brief-worthy"
      assert CandidateDisplay.intent_label("visual_adjust") == "Visual adjustment"
      assert CandidateDisplay.intent_label("decision_recorded") == "Decision recorded"
    end

    test "nil renders the em dash the rail already used" do
      assert CandidateDisplay.intent_label(nil) == "—"
    end

    test "no raw enum token survives to the DOM" do
      for value <- ~w(off_topic action_items brief_worthy visual_adjust decision_recorded) do
        refute CandidateDisplay.intent_label(value) == value
      end
    end

    test "an unmapped intent is humanised, never printed raw, never crashes" do
      # Same finding as the role key: `classified_intent` is whatever
      # binary the model returned, not a closed enum.
      label = CandidateDisplay.intent_label("some_new_intent")

      refute label =~ "_"
      assert label == "Some new intent"
    end
  end

  describe "containment — CandidateDisplay is the only place that knows the sentinel" do
    test "no rendering position in platform_web touches target_role outside this module" do
      # The architect's condition for accepting a render-time fix over a
      # data migration: the magic string is absorbed in exactly one
      # place, so the next renderer cannot reproduce `@null`.
      root = Path.join([File.cwd!(), "lib", "platform_web"])

      offenders =
        root
        |> Path.join("**/*.{ex,heex}")
        |> Path.wildcard()
        |> Enum.reject(&(Path.basename(&1) == "candidate_display.ex"))
        |> Enum.flat_map(fn file ->
          file
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _n} ->
            # A rendering position is an EEx interpolation. A bare
            # reference (an alias, a query, an assign hop) is fine; a
            # `{... target_role ...}` in markup is not.
            #
            # Handing the raw value to `target_label/2` is the ONE
            # sanctioned rendering position — that call IS the
            # absorption. Anything else in an interpolation is a second
            # place that knows what "null" means.
            String.contains?(line, "target_role") and
              Regex.match?(~r/\{[^}]*target_role/, line) and
              not String.contains?(line, "CandidateDisplay.target_label(")
          end)
          |> Enum.map(fn {line, n} ->
            "#{Path.relative_to(file, root)}:#{n}: #{String.trim(line)}"
          end)
        end)

      assert offenders == [],
             "target_role is rendered outside CandidateDisplay:\n" <> Enum.join(offenders, "\n")
    end
  end
end
