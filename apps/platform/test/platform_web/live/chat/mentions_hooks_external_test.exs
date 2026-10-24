defmodule PlatformWeb.ChatLive.MentionsHooksExternalTest do
  @moduledoc """
  rbac-external-users M5 stage 4 — the @-mention dropdown for external users
  must offer only allowlisted-org humans (no agents), keeping the `@here`
  broadcast sentinel. `build_suggestions/3` is a pure function, so this exercises
  the scope filter without a LiveView by injecting a pure `:permit_fn` in place
  of `Chat.external_dm_permitted?/3` — mention scope == DM scope == enforcement,
  no third scope path.
  """
  use ExUnit.Case, async: true

  alias PlatformWeb.ChatLive.MentionsHooks

  @allowed_id "user-allowed-org-a"
  @denied_id "user-denied-org-b"

  # Mirrors the identity struct `PresenceHooks.participant_identity/2` builds:
  # `participant_type`, `display_name`, `archived`, and (M5 stage 4) `principal_id`.
  defp participants do
    %{
      "p-allowed" => %{
        participant_type: "user",
        display_name: "Aaron Allowed",
        archived: false,
        principal_id: @allowed_id
      },
      "p-denied" => %{
        participant_type: "user",
        display_name: "Aaron Denied",
        archived: false,
        principal_id: @denied_id
      },
      "p-agent" => %{
        participant_type: "agent",
        display_name: "Aaron Bot",
        archived: false,
        principal_id: "agent-1"
      },
      "p-archived" => %{
        participant_type: "user",
        display_name: "Aaron Archived",
        archived: true,
        principal_id: "user-archived"
      }
    }
  end

  # Pure stand-in for M8: only the org-A human is DM-permitted.
  defp permit_fn do
    fn _user_id, "user", pid -> pid == @allowed_id end
  end

  defp names(suggestions), do: Enum.map(suggestions, & &1.display_name)

  describe "build_suggestions/3 — internal (default) is unchanged" do
    test "lists humans and the agent, drops only the archived user" do
      names = names(MentionsHooks.build_suggestions("aaron", participants()))

      assert "Aaron Allowed" in names
      assert "Aaron Denied" in names
      assert "Aaron Bot" in names
      refute "Aaron Archived" in names
    end

    test "external? false explicitly is identical to the default" do
      names = names(MentionsHooks.build_suggestions("aaron", participants(), external?: false))

      assert "Aaron Allowed" in names
      assert "Aaron Denied" in names
      assert "Aaron Bot" in names
    end
  end

  describe "build_suggestions/3 — external scope" do
    test "yields ONLY the allowlisted human; drops the non-allowlisted human, the agent, and the archived user" do
      suggestions =
        MentionsHooks.build_suggestions("aaron", participants(),
          external?: true,
          user_id: "external-actor",
          permit_fn: permit_fn()
        )

      assert names(suggestions) == ["Aaron Allowed"]
    end

    test "keeps the @here sentinel (it broadcasts only within the current allowlisted space)" do
      suggestions =
        MentionsHooks.build_suggestions("", participants(),
          external?: true,
          user_id: "external-actor",
          permit_fn: permit_fn()
        )

      # `@here` is a prefix of the empty query, so it prepends; the only
      # participant that survives the scope filter is the allowlisted human.
      assert Enum.any?(suggestions, &(&1[:participant_type] == "broadcast"))
      assert "Aaron Allowed" in names(suggestions)
      refute "Aaron Denied" in names(suggestions)
      refute "Aaron Bot" in names(suggestions)
    end

    test "a query matching the denied human still never surfaces them" do
      suggestions =
        MentionsHooks.build_suggestions("aaron den", participants(),
          external?: true,
          user_id: "external-actor",
          permit_fn: permit_fn()
        )

      # "Aaron Den" is a prefix of "Aaron Denied" but not "Aaron Allowed", so
      # the prefix filter leaves only the denied human — whom the scope filter
      # then drops. Result: empty (no @here either, since "aaron den" isn't a
      # prefix of "here").
      assert suggestions == []
    end

    test "never offers addable (not-in-space) agents" do
      addable = [%{id: "agent-addable", name: "Aaron Atlas", avatar_url: nil}]

      internal = MentionsHooks.build_suggestions("aaron", participants(), addable_agents: addable)

      # Positive control: the same opts on the internal surface DO offer it.
      assert "Aaron Atlas" in names(internal)

      suggestions =
        MentionsHooks.build_suggestions("aaron", participants(),
          external?: true,
          user_id: "external-actor",
          permit_fn: permit_fn(),
          addable_agents: addable
        )

      assert names(suggestions) == ["Aaron Allowed"]
      refute Enum.any?(suggestions, &(&1[:not_in_space] == true))
    end

    test "a participant with no principal id is dropped closed" do
      participants = %{
        "p-nil" => %{participant_type: "user", display_name: "No Id", archived: false}
      }

      suggestions =
        MentionsHooks.build_suggestions("no", participants,
          external?: true,
          user_id: "external-actor",
          permit_fn: fn _u, _t, _id -> true end
        )

      assert suggestions == []
    end
  end
end
