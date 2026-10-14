defmodule PlatformWeb.OrgMemoryLive.ProposalBodyTest do
  @moduledoc """
  Task 01a1170a stage 1: unit tests for the helpers shared by the mobile
  proposal card and the desktop proposal panel. No DB.
  """

  use ExUnit.Case, async: true

  alias PlatformWeb.OrgMemoryLive.ProposalBody

  # `n` hard lines of 3 chars each, far under any char budget.
  defp lines(n), do: Enum.map_join(1..n, "\n", fn _ -> "abc" end)

  describe "diff_lines/1" do
    test "splits on newlines" do
      assert ProposalBody.diff_lines("a\nb") == ["a", "b"]
    end

    test "nil is no lines" do
      assert ProposalBody.diff_lines(nil) == []
    end
  end

  describe "long_body?/1 (mobile: 320 chars / 8 lines)" do
    test "true at 321 chars on a single line" do
      assert ProposalBody.long_body?(String.duplicate("x", 321))
    end

    test "false at 320 chars spread over exactly 8 lines" do
      # 7 lines of 39 chars + 1 line of 40 + 7 newlines = 320 chars.
      body =
        Enum.map_join(1..8, "\n", fn
          8 -> String.duplicate("x", 40)
          _ -> String.duplicate("x", 39)
        end)

      assert String.length(body) == 320
      assert length(String.split(body, "\n")) == 8

      refute ProposalBody.long_body?(body)
    end

    test "true at 9 lines" do
      refute ProposalBody.long_body?(lines(8))
      assert ProposalBody.long_body?(lines(9))
    end

    test "nil is never long" do
      refute ProposalBody.long_body?(nil)
    end
  end

  describe "long_body?/2 (desktop: 12 lines)" do
    test "false at 12 lines, true at 13" do
      refute ProposalBody.long_body?(lines(12), 12)
      assert ProposalBody.long_body?(lines(13), 12)
    end
  end

  describe "target_key/1" do
    test "prefers the stored target_page_key" do
      assert ProposalBody.target_key(%{
               target_page_key: "org/page/memory.md",
               category: "recurring-theme",
               evidence: "e",
               body: "b"
             }) == "org/page/memory.md"
    end

    test "falls back to the promotion pipeline's derivation when nil" do
      proposal = %{target_page_key: nil, category: "recurring-theme", evidence: "e", body: "b"}

      assert ProposalBody.target_key(proposal) ==
               Platform.Memory.Proposals.derive_target_page_key("recurring-theme", "e", "b")
    end
  end
end
