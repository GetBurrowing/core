defmodule Platform.ExternalAgentsTest do
  @moduledoc """
  Tests for the `Platform.ExternalAgents` context.

  Covers the kind-gating invariants:
    * `create_external_agent/1` forces `kind: "external"`
    * `update_external_agent/2` strips `:kind` and raises on non-external rows
    * `get_external_agent/1` and `list_external_agents/1` filter by kind
    * `delete_external_agent/1` works on external rows
  """
  use Platform.DataCase, async: true

  alias Platform.Agents.Agent
  alias Platform.ExternalAgents
  alias Platform.Repo

  @valid_external_attrs %{
    slug: "ext-agent",
    name: "Ext Agent",
    status: "active",
    workspace_id: nil,
    endpoint_kind: "openai_compat",
    base_url: "https://api.openai.com/v1",
    model: "gpt-4o-mini"
  }

  defp unique_attrs(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])

    @valid_external_attrs
    |> Map.put(:slug, "ext-agent-#{suffix}")
    |> Map.merge(overrides)
  end

  defp insert_native_agent!(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        slug: "native-#{suffix}",
        name: "Native #{suffix}",
        status: "active",
        kind: "native",
        workspace_id: nil
      }
      |> Map.merge(overrides)

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  describe "create_external_agent/1" do
    test "inserts a row with kind=external" do
      assert {:ok, %Agent{} = agent} =
               ExternalAgents.create_external_agent(unique_attrs())

      assert agent.kind == "external"
      assert agent.endpoint_kind == "openai_compat"
      assert agent.base_url == "https://api.openai.com/v1"
      assert agent.model == "gpt-4o-mini"
    end

    test "forces kind=external even when caller passes kind=native" do
      assert {:ok, %Agent{} = agent} =
               ExternalAgents.create_external_agent(unique_attrs(%{kind: "native"}))

      assert agent.kind == "external"
    end

    test "forces kind=external when caller passes string-keyed kind=native" do
      attrs =
        unique_attrs()
        |> Map.put("kind", "native")

      assert {:ok, %Agent{} = agent} = ExternalAgents.create_external_agent(attrs)
      assert agent.kind == "external"
    end

    test "returns changeset error when required external fields are missing" do
      attrs = unique_attrs() |> Map.delete(:endpoint_kind)
      assert {:error, %Ecto.Changeset{} = cs} = ExternalAgents.create_external_agent(attrs)
      refute cs.valid?
    end
  end

  describe "update_external_agent/2" do
    test "updates an external agent" do
      {:ok, agent} = ExternalAgents.create_external_agent(unique_attrs())

      assert {:ok, %Agent{} = updated} =
               ExternalAgents.update_external_agent(agent, %{name: "Renamed"})

      assert updated.name == "Renamed"
      assert updated.kind == "external"
    end

    test "strips :kind from attrs (caller cannot flip to native via update)" do
      {:ok, agent} = ExternalAgents.create_external_agent(unique_attrs())

      assert {:ok, %Agent{} = updated} =
               ExternalAgents.update_external_agent(agent, %{kind: "native", name: "Still Ext"})

      assert updated.kind == "external"
      assert updated.name == "Still Ext"
    end

    test "strips string-keyed \"kind\" from attrs" do
      {:ok, agent} = ExternalAgents.create_external_agent(unique_attrs())

      assert {:ok, %Agent{} = updated} =
               ExternalAgents.update_external_agent(agent, %{"kind" => "native", "name" => "X"})

      assert updated.kind == "external"
    end

    test "raises ArgumentError when called on a kind=native agent" do
      native = insert_native_agent!()

      assert_raise ArgumentError, ~r/kind="native"/, fn ->
        ExternalAgents.update_external_agent(native, %{name: "won't apply"})
      end
    end
  end

  describe "get_external_agent/1" do
    test "returns the agent when kind=external" do
      {:ok, agent} = ExternalAgents.create_external_agent(unique_attrs())
      assert %Agent{id: id} = ExternalAgents.get_external_agent(agent.id)
      assert id == agent.id
    end

    test "returns nil for a native-kind agent with the same id" do
      native = insert_native_agent!()
      assert ExternalAgents.get_external_agent(native.id) == nil
    end

    test "returns nil when no row matches" do
      assert ExternalAgents.get_external_agent(Ecto.UUID.generate()) == nil
    end
  end

  describe "get_external_agent!/1" do
    test "returns the agent when kind=external" do
      {:ok, agent} = ExternalAgents.create_external_agent(unique_attrs())
      assert %Agent{id: id} = ExternalAgents.get_external_agent!(agent.id)
      assert id == agent.id
    end

    test "raises Ecto.NoResultsError on miss" do
      assert_raise Ecto.NoResultsError, fn ->
        ExternalAgents.get_external_agent!(Ecto.UUID.generate())
      end
    end

    test "raises Ecto.NoResultsError on kind mismatch" do
      native = insert_native_agent!()

      assert_raise Ecto.NoResultsError, fn ->
        ExternalAgents.get_external_agent!(native.id)
      end
    end
  end

  describe "list_external_agents/1" do
    test "returns only kind=external rows" do
      {:ok, ext} = ExternalAgents.create_external_agent(unique_attrs())
      _native = insert_native_agent!()

      ids = ExternalAgents.list_external_agents() |> Enum.map(& &1.id)
      assert ext.id in ids
      assert Enum.all?(ExternalAgents.list_external_agents(), &(&1.kind == "external"))
    end

    test "honors :endpoint_kind filter" do
      {:ok, openai} =
        ExternalAgents.create_external_agent(unique_attrs(%{endpoint_kind: "openai_compat"}))

      {:ok, ollama} =
        ExternalAgents.create_external_agent(
          unique_attrs(%{
            endpoint_kind: "ollama_native",
            base_url: "http://localhost:11434",
            model: "llama3"
          })
        )

      openai_ids =
        ExternalAgents.list_external_agents(endpoint_kind: "openai_compat") |> Enum.map(& &1.id)

      ollama_ids =
        ExternalAgents.list_external_agents(endpoint_kind: "ollama_native") |> Enum.map(& &1.id)

      assert openai.id in openai_ids
      refute ollama.id in openai_ids
      assert ollama.id in ollama_ids
      refute openai.id in ollama_ids
    end

    test "honors :workspace_id filter" do
      ws_a = Ecto.UUID.generate()
      ws_b = Ecto.UUID.generate()

      {:ok, a} = ExternalAgents.create_external_agent(unique_attrs(%{workspace_id: ws_a}))
      {:ok, b} = ExternalAgents.create_external_agent(unique_attrs(%{workspace_id: ws_b}))

      ws_a_ids = ExternalAgents.list_external_agents(workspace_id: ws_a) |> Enum.map(& &1.id)
      assert a.id in ws_a_ids
      refute b.id in ws_a_ids
    end

    test "default order is inserted_at DESC" do
      {:ok, first} = ExternalAgents.create_external_agent(unique_attrs())
      # Ensure a measurable time difference
      Process.sleep(2)
      {:ok, second} = ExternalAgents.create_external_agent(unique_attrs())

      ids = ExternalAgents.list_external_agents() |> Enum.map(& &1.id)
      first_idx = Enum.find_index(ids, &(&1 == first.id))
      second_idx = Enum.find_index(ids, &(&1 == second.id))

      assert first_idx != nil
      assert second_idx != nil
      assert second_idx < first_idx, "expected newer row to come first (inserted_at DESC)"
    end
  end

  describe "delete_external_agent/1" do
    test "removes an external row" do
      {:ok, agent} = ExternalAgents.create_external_agent(unique_attrs())
      assert {:ok, %Agent{}} = ExternalAgents.delete_external_agent(agent)
      assert ExternalAgents.get_external_agent(agent.id) == nil
    end
  end
end
