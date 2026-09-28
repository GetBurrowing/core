defmodule PlatformWeb.ControlCenter.AgentDataSlugLookupTest do
  @moduledoc """
  `AgentData.ensure_selected_agent/2`'s slug fallbacks (task 01a0e77c stage 3).

  Both fallbacks were bare `Repo.get_by(Agent, slug:)`, which raised
  Ecto.MultipleResultsError into the control-center LiveView when two
  workspaces shared the selected slug. They now treat an ambiguous slug as not
  found (nil); `Platform.Agents.SlugLookup` logs the ambiguity.
  """
  use Platform.DataCase, async: true

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias PlatformWeb.ControlCenter.AgentData

  defp insert_agent!(attrs) do
    %Agent{}
    |> Agent.changeset(Map.merge(%{name: "Agent", status: "active"}, attrs))
    |> Repo.insert!()
  end

  defp collide! do
    slug = "cc-collide-#{System.unique_integer([:positive])}"
    insert_agent!(%{slug: slug, workspace_id: Ecto.UUID.generate()})
    insert_agent!(%{slug: slug, workspace_id: Ecto.UUID.generate()})
    slug
  end

  describe "ensure_selected_agent/2, slug not in the directory" do
    test "an ambiguous slug is nil, not a raise" do
      slug = collide!()

      log =
        capture_log([level: :warning], fn ->
          assert AgentData.ensure_selected_agent(slug, []) == nil
        end)

      assert log =~ slug
    end

    test "a unique slug still resolves" do
      agent = insert_agent!(%{slug: "cc-solo-#{System.unique_integer([:positive])}"})
      assert %Agent{id: id} = AgentData.ensure_selected_agent(agent.slug, [])
      assert id == agent.id
    end
  end

  describe "ensure_selected_agent/2, workspace-managed entry whose bootstrap fails" do
    test "an ambiguous slug is nil, not a raise" do
      # No mounted workspace exists in the test env, so
      # WorkspaceBootstrap.ensure_agent/1 returns {:error, _} and control
      # reaches the fallback lookup.
      slug = collide!()
      entries = [%{slug: slug, workspace_managed?: true}]

      capture_log([level: :warning], fn ->
        assert AgentData.ensure_selected_agent(slug, entries) == nil
      end)
    end
  end
end
