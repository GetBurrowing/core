defmodule PlatformWeb.ChatLive.MentionsHooksTest do
  @moduledoc """
  Pure-function tests for the mention suggestion builder.

  The full hook event dispatch is exercised indirectly via the chat
  LiveView integration tests; these tests focus on the ordering
  contract for the `@here` broadcast sentinel introduced in task
  019edbbf, where a missing-prefix or wrong-prefix case would
  silently break discovery.
  """

  use ExUnit.Case, async: true

  alias PlatformWeb.ChatLive.MentionsHooks

  defp participant(id, name, type \\ "user") do
    %{
      id: id,
      name: name,
      display_name: name,
      participant_type: type,
      avatar_url: nil,
      avatar_seed: nil
    }
  end

  defp participants_map do
    %{
      "p1" => participant("p1", "Rowan"),
      "p2" => participant("p2", "Hera"),
      "p3" => participant("p3", "Helga"),
      "p4" => participant("p4", "Claude", "agent")
    }
  end

  describe "build_suggestions/2 — @here sentinel" do
    test "empty query yields here sentinel plus participants, here on top" do
      [first | rest] = MentionsHooks.build_suggestions("", participants_map())

      assert %{
               name: "here",
               participant_type: "broadcast",
               avatar_url: nil,
               avatar_seed: nil
             } = first

      # Sentinel is not in the participants_map — the rest are real entries.
      assert length(rest) == 4
      assert Enum.all?(rest, &(&1.participant_type in ["user", "agent"]))
    end

    test "prefix 'h' yields here sentinel at the top" do
      result = MentionsHooks.build_suggestions("h", participants_map())

      assert List.first(result).name == "here"
      assert List.first(result).participant_type == "broadcast"
      # Hera and Helga still match the prefix.
      names = Enum.map(result, & &1.name)
      assert "Hera" in names
      assert "Helga" in names
    end

    test "prefix 'here' yields only the broadcast sentinel" do
      result = MentionsHooks.build_suggestions("here", participants_map())

      assert [%{name: "here", participant_type: "broadcast"}] = result
    end

    test "prefix 'hera' (NOT a prefix of here) drops the sentinel" do
      result = MentionsHooks.build_suggestions("hera", participants_map())

      refute Enum.any?(result, &(&1.participant_type == "broadcast"))
      # Hera (real participant) still matches.
      assert Enum.any?(result, &(&1.name == "Hera"))
    end

    test "is case-insensitive — uppercase 'HERE' still surfaces sentinel" do
      result = MentionsHooks.build_suggestions("HERE", participants_map())
      assert List.first(result).name == "here"
    end

    test "nil query treated as empty (broadcast surfaces)" do
      result = MentionsHooks.build_suggestions(nil, participants_map())
      assert List.first(result).name == "here"
    end

    test "empty participants_map still yields the sentinel for matching query" do
      result = MentionsHooks.build_suggestions("h", %{})

      assert result == [
               %{
                 name: "here",
                 display_name: "here",
                 participant_type: "broadcast",
                 avatar_url: nil,
                 avatar_seed: nil
               }
             ]
    end

    test "non-matching query returns no sentinel and no participants" do
      result = MentionsHooks.build_suggestions("zzz", participants_map())
      assert result == []
    end
  end
end
