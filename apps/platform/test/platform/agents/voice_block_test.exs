defmodule Platform.Agents.VoiceBlockTest do
  @moduledoc """
  Task 01a1b6ff stage 1: the voice block text and the banned-phrase data.
  """

  use ExUnit.Case, async: true

  alias Platform.Agents.VoiceBlock
  alias Platform.Agents.VoiceCheck

  defp count(haystack, needle), do: length(:binary.matches(haystack, needle))

  describe "VoiceBlock.text/0" do
    test "starts with the marker heading and carries it exactly once" do
      text = VoiceBlock.text()
      assert VoiceBlock.marker() == "## How you talk"
      assert String.starts_with?(text, "## How you talk\n")
      assert count(text, "## How you talk") == 1
    end

    test "carries the neighbour character, the canonical nouns and the model rule" do
      text = VoiceBlock.text()
      assert text =~ "shop next door"
      assert text =~ "never a bot or an assistant"
      assert text =~ "which model is underneath"
      assert text =~ "Never open with it."
      assert text =~ "participant"
    end

    test "has at most two quoted examples, neither a product or privacy claim" do
      text = VoiceBlock.text()
      examples = Regex.scan(~r/^"[^"\n]+"$/m, text)
      assert length(examples) in 1..2

      for claim <- [
            "sign-up",
            "sign up",
            "account",
            "phone",
            "link",
            "deleted",
            "Stripe",
            "card details",
            "privacy"
          ] do
        refute String.contains?(String.downcase(text), String.downcase(claim)),
               "the voice block must make no product or privacy claim (found #{inspect(claim)})"
      end
    end

    test "breaks none of its own shape checks" do
      text = VoiceBlock.text()
      assert count(text, "—") == 0
      assert count(text, "!") == 0
    end

    test "does not paste the banned phrases into the prompt" do
      text = VoiceBlock.text()

      for phrase <- VoiceCheck.default_banned() do
        pattern = ~r/(?<![\w])#{Regex.escape(phrase)}(?![\w])/iu

        refute Regex.match?(pattern, text),
               "banned phrase #{inspect(phrase)} appears in the voice block"
      end
    end
  end

  describe "VoiceCheck data" do
    test "five phrase groups plus four named shape checks, the proposal's six groups" do
      assert Keyword.keys(VoiceCheck.groups()) == [
               :openers_and_reactions,
               :assistant_self_talk,
               :closers,
               :therapy_and_apology,
               :brochure_words
             ]

      assert VoiceCheck.shape_checks() == [
               :em_dash,
               :multiple_exclamations,
               :consecutive_question_end,
               :structure_in_short_reply
             ]
    end

    test "default_banned/0 is every group's phrases flattened, non-empty and unique" do
      banned = VoiceCheck.default_banned()
      assert banned == Enum.flat_map(VoiceCheck.groups(), &elem(&1, 1))
      assert length(banned) == 49
      assert Enum.uniq(banned) == banned
      assert Enum.all?(banned, &(is_binary(&1) and String.trim(&1) != ""))
    end

    test "spot-checks the verbatim phrases, punctuation included" do
      banned = VoiceCheck.default_banned()

      for phrase <- [
            "Great!",
            "Of course!",
            "I'd be happy to",
            "Don't hesitate to",
            "game-changer"
          ] do
        assert phrase in banned
      end

      assert VoiceCheck.self_description_names() == ["Claude", "Anthropic", "ChatGPT"]
      assert Enum.all?(VoiceCheck.self_description_names(), &(&1 in banned))
    end
  end
end
