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

  defp participant(id, name, type \\ "user", opts \\ []) do
    %{
      id: id,
      name: name,
      display_name: name,
      participant_type: type,
      avatar_url: nil,
      avatar_seed: nil,
      archived: Keyword.get(opts, :archived, false)
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

  describe "build_suggestions/2 — archived-user filter (task 019f671f validation 1(c))" do
    # Regression: reviewer flagged that typing `@Rowan Kl` in `#general`
    # autocompleted the archived user "Rowan Member". The participants_map
    # still carries archived users (deliberately, so historical author
    # attribution renders) but the autocomplete must reject them.
    test "archived user matching the prefix is filtered out" do
      map = %{
        "active" => participant("active", "Rowan"),
        "archived" => participant("archived", "Rowan Member", "user", archived: true)
      }

      results = MentionsHooks.build_suggestions("Rowan", map)
      names = Enum.map(results, & &1.name)

      assert "Rowan" in names,
             "active user with matching prefix must still surface"

      refute "Rowan Member" in names,
             "archived user must NOT appear in mention autocomplete " <>
               "(validation 1(c) — soft-archive continues to render historical " <>
               "attribution but suppresses future addressability)"
    end

    test "agent participant is unaffected by the archived filter" do
      # Agents carry `archived: false` from PresenceHooks.participant_identity/2
      # so the single-map-lookup filter is safe across participant types.
      map = %{
        "agent" => participant("agent", "Claude", "agent"),
        "archived" => participant("archived", "Claude Member", "user", archived: true)
      }

      results = MentionsHooks.build_suggestions("Cla", map)
      names = Enum.map(results, & &1.name)

      assert "Claude" in names
      refute "Claude Member" in names
    end

    test "here sentinel is still returned even when every real match is archived" do
      # The sentinel is prepended AFTER filtering, so an all-archived
      # participant set for a 'h' prefix query still surfaces `@here`.
      map = %{
        "arch1" => participant("arch1", "Hera", "user", archived: true),
        "arch2" => participant("arch2", "Helga", "user", archived: true)
      }

      results = MentionsHooks.build_suggestions("h", map)

      assert [%{name: "here", participant_type: "broadcast"}] = results
    end

    test "entries with no :archived key are treated as active (backwards compatibility)" do
      # A participant identity map built before the flag existed would omit
      # the `:archived` key entirely. The pattern-match on `%{archived: true}`
      # falls through to the display-name matcher, so such entries still
      # surface. This guards against a partial-rollout regression where old
      # in-flight LV processes' maps predate the flag.
      map = %{"p" => Map.delete(participant("p", "Rowan"), :archived)}

      results = MentionsHooks.build_suggestions("Ry", map)
      assert Enum.any?(results, &(&1.name == "Rowan"))
    end
  end
end
