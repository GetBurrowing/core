defmodule Platform.Chat.MentionIdentityTest do
  use ExUnit.Case, async: true

  alias Platform.Agents.Agent
  alias Platform.Chat.MentionIdentity

  describe "agent_keys/1" do
    test "returns the downcased name and slug" do
      assert MentionIdentity.agent_keys(%Agent{name: "Zip Probe", slug: "Zip-Slug-Probe"}) ==
               ["zip probe", "zip-slug-probe"]
    end

    test "drops a nil or blank name or slug" do
      assert MentionIdentity.agent_keys(%Agent{name: nil, slug: "zip-slug-probe"}) ==
               ["zip-slug-probe"]

      assert MentionIdentity.agent_keys(%Agent{name: "Zip", slug: ""}) == ["zip"]
      assert MentionIdentity.agent_keys(%Agent{name: "", slug: nil}) == []
    end

    test "de-duplicates a name and slug that downcase to the same key" do
      assert MentionIdentity.agent_keys(%Agent{name: "Zip", slug: "zip"}) == ["zip"]
    end
  end

  describe "agent_named?/2" do
    setup do
      %{agent: %Agent{name: "Zip", slug: "zip-slug-probe"}}
    end

    test "matches the slug exactly", %{agent: agent} do
      assert MentionIdentity.agent_named?(agent, ["zip-slug-probe"])
    end

    test "matches the name exactly", %{agent: agent} do
      assert MentionIdentity.agent_named?(agent, ["other", "zip"])
    end

    test "does not prefix-match a longer token", %{agent: agent} do
      refute MentionIdentity.agent_named?(agent, ["zip-slug-probe-2"])
      refute MentionIdentity.agent_named?(agent, ["zipper"])
    end

    test "does not match a token that is a prefix of a key", %{agent: agent} do
      refute MentionIdentity.agent_named?(agent, ["zip-slug"])
    end

    test "is false for no tokens", %{agent: agent} do
      refute MentionIdentity.agent_named?(agent, [])
    end
  end
end
