defmodule PlatformWeb.RuntimeRevokeOnAgentDeleteTest do
  @moduledoc """
  Task 01a1b34b stage 1: deleting an agent revokes every runtime bound to it,
  and a runtime with no agent cannot authenticate.

  `agent_runtimes.agent_id` is `on_delete: :nilify_all`, so before this change
  deleting an agent left its runtime `active` with its token hash intact and
  `agent_id` NULL. Channel, MCP and attachment auth never looked at
  `agent_id`, so that token was still a live credential.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query

  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.ExternalAgents
  alias Platform.Federation
  alias Platform.Federation.{DeadLetter, DeadLetters}
  alias Platform.Repo
  alias PlatformWeb.ControlCenter.AgentData
  alias PlatformWeb.Plugs.AttachmentAuth

  # ── fixtures ────────────────────────────────────────────────────────────

  defp uniq, do: System.unique_integer([:positive])

  # A federated agent and its runtime, provisioned the way onboarding does it.
  defp provisioned! do
    owner = Platform.TenancyFixtures.root_admin!()
    n = uniq()

    {:ok, agent, runtime, token} =
      Federation.provision_agent_runtime(
        owner.id,
        %{slug: "revoke-agent-#{n}", name: "Revoke Agent #{n}", status: "active"},
        %{runtime_id: "revoke-rt-#{n}", tool_profile: AgentRuntime.default_tool_profile()}
      )

    %{owner: owner, agent: agent, runtime: runtime, token: token}
  end

  # An active runtime row inserted directly, with the given agent_id.
  defp raw_runtime!(owner, agent_id) do
    token = AgentRuntime.generate_token()

    runtime =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "revoke-raw-rt-#{uniq()}",
        owner_user_id: owner.id,
        agent_id: agent_id,
        auth_token_hash: AgentRuntime.hash_token(token),
        status: "active"
      })
      |> Repo.insert!()

    profile = AgentRuntime.default_tool_profile()

    {:ok, _} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        runtime,
        profile,
        Platform.Access.RuntimeProfiles.translated_permissions(profile)
      )

    {runtime, token}
  end

  defp socket_connect(runtime_id, token) do
    PlatformWeb.RuntimeSocket.connect(
      %{"runtime_id" => runtime_id, "token" => token},
      %Phoenix.Socket{},
      %{}
    )
  end

  defp mcp_status(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})
    |> Map.fetch!(:status)
  end

  defp attachment_auth(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> Plug.Test.init_test_session(%{})
    |> AttachmentAuth.call(AttachmentAuth.init([]))
  end

  defp assert_refused_everywhere(runtime_id, token) do
    assert socket_connect(runtime_id, token) == :error
    assert mcp_status(token) == 401
    conn = attachment_auth(token)
    assert conn.halted
    assert conn.status == 401
    refute Map.has_key?(conn.assigns, :principal)
  end

  defp assert_accepted_everywhere(runtime_id, token) do
    assert {:ok, %Phoenix.Socket{}} = socket_connect(runtime_id, token)
    assert mcp_status(token) == 200
    conn = attachment_auth(token)
    refute conn.halted
    assert {:runtime, %AgentRuntime{}} = conn.assigns.principal
  end

  defp assert_revoked_for(%AgentRuntime{id: id}, agent_id) do
    row = Repo.get!(AgentRuntime, id)
    assert row.status == "revoked"
    assert row.auth_token_hash == nil
    assert row.agent_id == nil
    assert row.metadata["revoked_agent_id"] == agent_id
    assert {:ok, _, _} = DateTime.from_iso8601(row.metadata["revoked_at"])
    row
  end

  # ── AgentData.delete_agent/1 ────────────────────────────────────────────

  describe "AgentData.delete_agent/1" do
    test "revokes the bound runtime and its token stops authenticating" do
      %{agent: agent, runtime: runtime, token: token} = provisioned!()

      # Positive control: the token works before the delete.
      assert_accepted_everywhere(runtime.runtime_id, token)

      :ok = AgentData.delete_agent(agent)

      assert Repo.get(Agent, agent.id) == nil
      assert_revoked_for(runtime, agent.id)
      assert_refused_everywhere(runtime.runtime_id, token)
    end

    test "revokes rows bound by agent_id AND the row agents.runtime_id points at" do
      %{owner: owner, agent: agent, runtime: primary} = provisioned!()

      # A second row bound only by agent_id (e.g. a voice runtime).
      {by_agent_id, _} = raw_runtime!(owner, agent.id)

      # A third row bound only by the agents.runtime_id pointer.
      {by_pointer, _} = raw_runtime!(owner, nil)

      agent =
        agent
        |> Agent.changeset(%{runtime_id: by_pointer.id})
        |> Repo.update!()

      :ok = AgentData.delete_agent(agent)

      for rt <- [primary, by_agent_id, by_pointer], do: assert_revoked_for(rt, agent.id)
    end

    test "keeps existing metadata on the revoked runtime" do
      %{owner: owner, agent: agent} = provisioned!()
      {rt, _} = raw_runtime!(owner, agent.id)
      rt |> AgentRuntime.changeset(%{metadata: %{"role" => "voice"}}) |> Repo.update!()

      :ok = AgentData.delete_agent(agent)

      assert assert_revoked_for(rt, agent.id).metadata["role"] == "voice"
    end

    test "regression: deleting agent A leaves agent B's runtime active and connecting" do
      a = provisioned!()
      b = provisioned!()
      b_hash_before = Repo.get!(AgentRuntime, b.runtime.id).auth_token_hash

      :ok = AgentData.delete_agent(a.agent)

      b_row = Repo.get!(AgentRuntime, b.runtime.id)
      assert b_row.status == "active"
      assert b_row.auth_token_hash == b_hash_before
      assert b_row.agent_id == b.agent.id
      refute Map.has_key?(b_row.metadata || %{}, "revoked_agent_id")
      assert_accepted_everywhere(b.runtime.runtime_id, b.token)

      assert_refused_everywhere(a.runtime.runtime_id, a.token)
    end

    test "broadcasts disconnect on the runtime socket id after commit" do
      %{agent: agent, runtime: runtime} = provisioned!()
      PlatformWeb.Endpoint.subscribe("runtime:" <> runtime.runtime_id)

      :ok = AgentData.delete_agent(agent)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: topic}
      assert topic == "runtime:" <> runtime.runtime_id
    end

    test "abandons the runtime's live dead letters and leaves other runtimes' alone" do
      %{agent: agent, runtime: runtime} = provisioned!()
      other = provisioned!()

      dl = fn rid, key ->
        {:ok, row} =
          DeadLetters.record(%{
            runtime_id: rid,
            source: "system_event",
            responsibility_key: key,
            reason: "runtime_offline"
          })

        row
      end

      pending = dl.(runtime.runtime_id, "k.pending")

      {:ok, replaying} =
        DeadLetters.mark(dl.(runtime.runtime_id, "k.replaying"), "replaying")

      {:ok, replayed} = DeadLetters.mark(dl.(runtime.runtime_id, "k.done"), "replayed")
      others = dl.(other.runtime.runtime_id, "k.other")

      :ok = AgentData.delete_agent(agent)

      assert Repo.get!(DeadLetter, pending.id).disposition == "abandoned"
      assert Repo.get!(DeadLetter, replaying.id).disposition == "abandoned"
      assert Repo.get!(DeadLetter, replayed.id).disposition == "replayed"
      assert Repo.get!(DeadLetter, others.id).disposition == "pending"
      assert DeadLetters.pending_for_runtime(runtime.runtime_id) == []
      assert DeadLetters.loss_summary().balanced
    end

    test "a failed delete transaction leaves the runtimes unrevoked" do
      %{agent: agent, runtime: runtime, token: token} = provisioned!()
      hash_before = Repo.get!(AgentRuntime, runtime.id).auth_token_hash

      # Force the final step (Multi.delete(:agent)) to fail. The trigger is
      # DDL inside the sandbox transaction, so it is rolled back after the test.
      Repo.query!("""
      CREATE FUNCTION test_01a1b34b_block_agent_delete() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'forced agent delete failure'; END;
      $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER test_01a1b34b_block_agent_delete BEFORE DELETE ON agents
      FOR EACH ROW EXECUTE FUNCTION test_01a1b34b_block_agent_delete()
      """)

      assert_raise Postgrex.Error, ~r/forced agent delete failure/, fn ->
        AgentData.delete_agent(agent)
      end

      Repo.query!("DROP TRIGGER test_01a1b34b_block_agent_delete ON agents")

      row = Repo.get!(AgentRuntime, runtime.id)
      assert row.status == "active"
      assert row.auth_token_hash == hash_before
      assert row.agent_id == agent.id
      refute Map.has_key?(row.metadata || %{}, "revoked_agent_id")
      assert Repo.get(Agent, agent.id)
      assert_accepted_everywhere(runtime.runtime_id, token)
    end
  end

  # ── ExternalAgents.delete_external_agent/1 ──────────────────────────────

  describe "ExternalAgents.delete_external_agent/1" do
    test "revokes runtimes bound to the external agent" do
      owner = Platform.TenancyFixtures.root_admin!()
      n = uniq()

      {:ok, agent} =
        ExternalAgents.create_external_agent(%{
          slug: "ext-revoke-#{n}",
          name: "Ext Revoke #{n}",
          status: "active",
          endpoint_kind: "openai_compat",
          base_url: "https://api.openai.com/v1",
          model: "gpt-4o-mini"
        })

      {runtime, token} = raw_runtime!(owner, agent.id)
      assert_accepted_everywhere(runtime.runtime_id, token)

      assert {:ok, %Agent{}} = ExternalAgents.delete_external_agent(agent)

      assert Repo.get(Agent, agent.id) == nil
      assert_revoked_for(runtime, agent.id)
      assert_refused_everywhere(runtime.runtime_id, token)
    end
  end

  # ── defense in depth: agentless active runtimes ─────────────────────────

  describe "an active runtime with agent_id nil" do
    test "is refused by socket, MCP and attachment auth" do
      owner = Platform.TenancyFixtures.root_admin!()
      {runtime, token} = raw_runtime!(owner, nil)

      row = Repo.get!(AgentRuntime, runtime.id)
      assert row.status == "active"
      assert row.agent_id == nil
      assert row.auth_token_hash == AgentRuntime.hash_token(token)

      assert_refused_everywhere(runtime.runtime_id, token)
      assert Federation.get_runtime_by_token(token) == nil
    end

    test "is refused when an agent's delete orphaned it before this change" do
      # Simulate the pre-fix orphan (e.g. agentgateway-locke): the agent row is
      # removed without the revoke step, so the FK nilifies agent_id and the
      # runtime stays active with its hash.
      %{agent: agent, runtime: runtime, token: token} = provisioned!()
      Repo.delete_all(from(a in Agent, where: a.id == ^agent.id))

      row = Repo.get!(AgentRuntime, runtime.id)
      assert row.status == "active"
      assert row.agent_id == nil
      assert row.auth_token_hash != nil

      assert_refused_everywhere(runtime.runtime_id, token)
    end
  end
end
