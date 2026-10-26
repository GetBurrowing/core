defmodule PlatformWeb.ChatLive.MentionsHooksTest do
  @moduledoc """
  Tests for the mention suggestion builder and its per-space state.

  `build_suggestions/3` is pure; most cases exercise its ranking contract
  (agents, then users, then the `@here` sentinel; prefix before infix;
  alphabetical) directly. The `reset_for_space/1` cases touch the database
  because the addable-agent list comes from `Chat.list_addable_agents/1`.
  """

  use Platform.DataCase, async: true

  alias Platform.Chat
  alias Platform.Repo
  alias PlatformWeb.ChatLive.MentionsHooks

  defp participant(id, name, type \\ "user", opts \\ []) do
    %{
      id: id,
      name: name,
      display_name: name,
      participant_type: type,
      principal_id: Keyword.get(opts, :principal_id, "principal-" <> id),
      avatar_url: nil,
      avatar_seed: nil,
      archived: Keyword.get(opts, :archived, false)
    }
  end

  defp participants_map do
    %{
      "p1" => participant("p1", "Avery"),
      "p2" => participant("p2", "Hera"),
      "p3" => participant("p3", "Helga"),
      "p4" => participant("p4", "Atlas", "agent")
    }
  end

  defp addable(id, name), do: %{id: id, name: name, avatar_url: nil}

  defp names(suggestions), do: Enum.map(suggestions, & &1.display_name)

  describe "build_suggestions/3 — ranking" do
    test "agents come before users for the same query" do
      map = %{
        "u1" => participant("u1", "Avery"),
        "a1" => participant("a1", "Atlas", "agent"),
        "u2" => participant("u2", "Aaron"),
        "a2" => participant("a2", "Axel", "agent")
      }

      assert names(MentionsHooks.build_suggestions("a", map)) ==
               ["Atlas", "Axel", "Aaron", "Avery"]
    end

    test "prefix matches rank before infix matches within a group" do
      map = %{
        # infix "ob" (in "Bob"), alphabetically first
        "u1" => participant("u1", "Bob"),
        # prefix "ob"
        "u2" => participant("u2", "Oberon"),
        "a1" => participant("a1", "Cobalt", "agent"),
        "a2" => participant("a2", "Obsidian", "agent")
      }

      assert names(MentionsHooks.build_suggestions("ob", map)) ==
               ["Obsidian", "Cobalt", "Oberon", "Bob"]
    end

    test "an infix-only match is offered" do
      map = %{"a1" => participant("a1", "Cobalt", "agent")}
      assert names(MentionsHooks.build_suggestions("bal", map)) == ["Cobalt"]
    end

    test "ties break alphabetically, case-insensitively" do
      map = %{
        "u1" => participant("u1", "blake"),
        "u2" => participant("u2", "Avery"),
        "u3" => participant("u3", "Bea")
      }

      assert names(MentionsHooks.build_suggestions("", map)) |> Enum.drop(-1) ==
               ["Avery", "Bea", "blake"]
    end

    test "truncation to eight keeps the agents" do
      users = for n <- 1..10, into: %{}, do: {"u#{n}", participant("u#{n}", "Aa user #{n}")}

      map =
        users
        |> Map.put("a1", participant("a1", "Zephyr Atlas", "agent"))
        |> Map.put("a2", participant("a2", "Zulu Atlas", "agent"))

      result = MentionsHooks.build_suggestions("a", map)

      assert length(result) == 8
      assert Enum.take(names(result), 2) == ["Zephyr Atlas", "Zulu Atlas"]
    end

    test "every suggestion carries not_in_space false when no addable agents are given" do
      result = MentionsHooks.build_suggestions("", participants_map())

      assert Enum.all?(result, &(&1.not_in_space == false))

      assert Enum.all?(
               result,
               &match?(
                 %{name: _, display_name: _, participant_type: _, avatar_url: _, avatar_seed: _},
                 &1
               )
             )
    end
  end

  describe "build_suggestions/3 — @here sentinel" do
    test "empty query yields every participant, then here last" do
      result = MentionsHooks.build_suggestions("", participants_map())

      assert names(result) == ["Atlas", "Avery", "Helga", "Hera", "here"]

      assert %{
               name: "here",
               participant_type: "broadcast",
               avatar_url: nil,
               avatar_seed: nil,
               not_in_space: false
             } = List.last(result)
    end

    test "here sits last when the query prefixes 'here'" do
      map = Map.put(participants_map(), "p5", participant("p5", "Helios", "agent"))
      result = MentionsHooks.build_suggestions("he", map)

      assert names(result) == ["Helios", "Helga", "Hera", "here"]
    end

    test "prefix 'here' yields only the broadcast sentinel" do
      assert [%{name: "here", participant_type: "broadcast"}] =
               MentionsHooks.build_suggestions("here", participants_map())
    end

    test "prefix 'hera' (NOT a prefix of here) drops the sentinel" do
      result = MentionsHooks.build_suggestions("hera", participants_map())

      refute Enum.any?(result, &(&1.participant_type == "broadcast"))
      assert names(result) == ["Hera"]
    end

    test "is case-insensitive — uppercase 'HERE' still surfaces sentinel" do
      assert List.last(MentionsHooks.build_suggestions("HERE", participants_map())).name ==
               "here"
    end

    test "nil query treated as empty (broadcast surfaces last)" do
      assert List.last(MentionsHooks.build_suggestions(nil, participants_map())).name == "here"
    end

    test "empty participants_map still yields the sentinel for matching query" do
      assert MentionsHooks.build_suggestions("h", %{}) == [
               %{
                 name: "here",
                 display_name: "here",
                 participant_type: "broadcast",
                 avatar_url: nil,
                 avatar_seed: nil,
                 not_in_space: false
               }
             ]
    end

    test "non-matching query returns no sentinel and no participants" do
      assert MentionsHooks.build_suggestions("zzz", participants_map()) == []
    end
  end

  describe "build_suggestions/3 — addable agents" do
    test "an addable agent appears once, after in-space agents, with not_in_space true" do
      result =
        MentionsHooks.build_suggestions("a", participants_map(),
          addable_agents: [addable("ag-1", "Aardvark")]
        )

      assert names(result) == ["Atlas", "Aardvark", "Avery", "Helga", "Hera"]

      assert [%{not_in_space: true, participant_type: "agent"}] =
               Enum.filter(result, &(&1.display_name == "Aardvark"))

      assert %{not_in_space: false} = Enum.find(result, &(&1.display_name == "Atlas"))
    end

    test "an addable agent with a better match tier still ranks by tier first" do
      map = %{"a1" => participant("a1", "Cobalt", "agent")}

      result =
        MentionsHooks.build_suggestions("co", map, addable_agents: [addable("ag-1", "Copper")])

      assert names(result) == ["Cobalt", "Copper"]

      result =
        MentionsHooks.build_suggestions("ob", map, addable_agents: [addable("ag-1", "Oboe")])

      assert names(result) == ["Oboe", "Cobalt"]
    end

    test "an in-space agent never appears as not_in_space, even if listed as addable" do
      map = %{"a1" => participant("a1", "Atlas", "agent", principal_id: "ag-atlas")}

      result =
        MentionsHooks.build_suggestions("atl", map,
          addable_agents: [
            addable("ag-atlas", "Atlas"),
            addable("ag-other", "atlas"),
            addable("ag-2", "Atlantic"),
            addable("ag-2", "Atlantic")
          ]
        )

      assert [
               %{display_name: "Atlas", not_in_space: false},
               %{display_name: "Atlantic", not_in_space: true}
             ] = result
    end

    test "addable agents survive truncation ahead of users" do
      users = for n <- 1..10, into: %{}, do: {"u#{n}", participant("u#{n}", "Blake #{n}")}

      result =
        MentionsHooks.build_suggestions("b", users, addable_agents: [addable("ag-1", "Bolt")])

      assert length(result) == 8
      assert hd(result).display_name == "Bolt"
    end
  end

  describe "build_suggestions/3 — archived-user filter (task 019f671f validation 1(c))" do
    test "archived user matching the query is filtered out" do
      map = %{
        "active" => participant("active", "Avery"),
        "archived" => participant("archived", "Avery Blake", "user", archived: true)
      }

      result = MentionsHooks.build_suggestions("Avery", map)

      assert names(result) == ["Avery"],
             "archived users must NOT appear in mention autocomplete " <>
               "(validation 1(c) — soft-archive keeps historical attribution only)"
    end

    test "an archived user matching only by infix is still filtered out" do
      map = %{"archived" => participant("archived", "Avery Blake", "user", archived: true)}
      assert MentionsHooks.build_suggestions("blake", map) == []
    end

    test "agent participant is unaffected by the archived filter" do
      map = %{
        "agent" => participant("agent", "Cobalt", "agent"),
        "archived" => participant("archived", "Cobalt Blake", "user", archived: true)
      }

      assert names(MentionsHooks.build_suggestions("Cob", map)) == ["Cobalt"]
    end

    test "here sentinel is still returned even when every real match is archived" do
      map = %{
        "arch1" => participant("arch1", "Hera", "user", archived: true),
        "arch2" => participant("arch2", "Helga", "user", archived: true)
      }

      assert [%{name: "here", participant_type: "broadcast"}] =
               MentionsHooks.build_suggestions("h", map)
    end

    test "entries with no :archived key are treated as active (backwards compatibility)" do
      map = %{"p" => Map.delete(participant("p", "Avery"), :archived)}
      assert names(MentionsHooks.build_suggestions("Av", map)) == ["Avery"]
    end
  end

  describe "reset_for_space/1 — :mention_addable_agents" do
    defp socket(assigns) do
      %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
    end

    defp agent!(name) do
      n = System.unique_integer([:positive])

      Repo.insert!(%Platform.Agents.Agent{
        name: "#{name} #{n}",
        slug: "mention-agent-#{n}",
        status: "active"
      })
    end

    defp channel! do
      n = System.unique_integer([:positive])

      {:ok, space} =
        Chat.create_space(%{name: "Mentions #{n}", slug: "mentions-#{n}", kind: "channel"})

      space
    end

    test "loads only summonable agents not already in the space" do
      space = channel!()
      present = agent!("Atlas")
      absent = agent!("Cobalt")

      {:ok, _} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: present.id,
          display_name: present.name,
          joined_at: DateTime.utc_now()
        })

      ids =
        %{active_space: space, external?: false}
        |> socket()
        |> MentionsHooks.reset_for_space()
        |> then(& &1.assigns.mention_addable_agents)
        |> Enum.map(& &1.id)

      assert absent.id in ids
      refute present.id in ids
    end

    test "is empty for an external session" do
      space = channel!()
      _ = agent!("Cobalt")

      assert %{assigns: %{mention_addable_agents: []}} =
               %{active_space: space, external?: true}
               |> socket()
               |> MentionsHooks.reset_for_space()
    end

    test "is empty with no active space" do
      assert %{assigns: %{mention_addable_agents: []}} =
               %{active_space: nil, external?: false}
               |> socket()
               |> MentionsHooks.reset_for_space()
    end
  end
end
