defmodule PlatformWeb.ControlCenter.AgentSpacePolicyLabelTest do
  @moduledoc """
  Task 01a1557a-8f80 stage 1: /control's per-space label on an agent shows
  the SPACE's effective attention policy, not the participant's
  `attention_mode` (read only for humans). The fixture gives the agent the
  participant mode "all" in every space, so a label still reading the
  participant would render "all" and never a policy.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Repo

  defp agent! do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "policy-label-#{System.unique_integer([:positive])}",
        name: "Label Agent",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        # The Spaces panel renders for federated (external) agents.
        runtime_type: "external",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })
      |> Repo.insert()

    agent
  end

  defp space!(agent, attrs) do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(Map.merge(%{name: "Sp #{n}", slug: "sp-#{n}"}, attrs))
    {:ok, _} = Chat.add_agent_participant(space.id, agent, attention_mode: "all")
    space
  end

  defp stored!(space, policy) do
    space
    |> Platform.Chat.Space.agent_attention_changeset(%{agent_attention_policy: policy})
    |> Repo.update!()
  end

  test "agent_spaces/1 reports each space's effective policy" do
    agent = agent!()
    collaborative = space!(agent, %{name: "A collab"}) |> stored!("collaborative")
    channel_default = space!(agent, %{name: "B channel"})
    group_default = space!(agent, %{name: "C group", kind: "group"})

    assert [
             %{space_id: id_a, attention_policy: "collaborative"},
             %{space_id: id_b, attention_policy: "on_mention"},
             %{space_id: id_c, attention_policy: "collaborative"}
           ] = Federation.agent_spaces(agent)

    assert {id_a, id_b, id_c} == {collaborative.id, channel_default.id, group_default.id}
    refute Enum.any?(Federation.agent_spaces(agent), &Map.has_key?(&1, :attention_mode))
  end

  test "the /control Spaces label renders the policy", %{conn: conn} do
    agent = agent!()
    space!(agent, %{name: "Directed room"}) |> stored!("directed")
    space!(agent, %{name: "Plain room"})

    user = Platform.TenancyFixtures.root_admin!()
    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, _view, html} = live(conn, ~p"/control/#{agent.slug}")

    assert html =~ "Spaces this agent participates in."
    assert html =~ ~r/>\s*directed\s*</
    assert html =~ ~r/>\s*on-mention\s*</
    refute html =~ ~r/>\s*all\s*</
  end
end
