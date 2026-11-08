defmodule Platform.Repo.Migrations.RevokeOrphanAgentRuntimesTest do
  @moduledoc """
  Task 01a1b84c stage 3: the data migration revokes exactly the `active`,
  `agent_id`-NULL rows no agent points at, clears their token hash and
  stamps `metadata.revoked_reason`; every other row keeps status, token
  hash, metadata and `updated_at`; running twice is harmless; the freed
  runtime_id is reusable through `Federation.register_runtime/2`.

  Orphans are built by deleting the agent row with `Repo.delete!/1` (the
  `agent_runtimes.agent_id` FK is `on_delete: :nilify_all`), never through
  `AgentData.delete_agent/1`, which revokes.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Tenancy.Org

  @migration Path.expand(
               "../../../../priv/repo/migrations/20261108041700_revoke_orphan_agent_runtimes.exs",
               __DIR__
             )
  Code.require_file(@migration)
  alias Platform.Repo.Migrations.RevokeOrphanAgentRuntimes, as: Migration

  defp run_up do
    %{num_rows: n} = Repo.query!(Migration.up_sql())
    n
  end

  defp member! do
    user = World.create_user!()
    World.plain_member!(user, Repo.get!(Org, acme_org_id()))
    user
  end

  defp rid(prefix), do: "gateway-example-#{prefix}-#{System.unique_integer([:positive])}"

  defp attached!(owner, runtime_id) do
    n = System.unique_integer([:positive])

    {:ok, agent, runtime, token} =
      Federation.provision_agent_runtime(
        owner.id,
        %{slug: "orph-mig-#{n}", name: "Orphan migration #{n}", status: "active"},
        %{runtime_id: runtime_id, tool_profile: AgentRuntime.default_tool_profile()}
      )

    {agent, runtime, token}
  end

  defp orphan!(owner, runtime_id) do
    {agent, runtime, token} = attached!(owner, runtime_id)
    Repo.delete!(agent)
    runtime = Federation.get_runtime(runtime.id)
    assert runtime.agent_id == nil
    assert runtime.status == "active"
    assert is_binary(runtime.auth_token_hash)
    {runtime, token}
  end

  # agent_id NULL, but an agent still points at the row via agents.runtime_id.
  defp pointed_at!(owner, runtime_id) do
    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: runtime_id})
    {:ok, runtime, _token} = Federation.activate_runtime(runtime)
    n = System.unique_integer([:positive])

    Repo.insert!(
      Agent.changeset(%Agent{}, %{
        slug: "pointer-mig-#{n}",
        name: "Pointer #{n}",
        runtime_type: "external",
        runtime_id: runtime.id
      })
    )

    runtime = Federation.get_runtime(runtime.id)
    assert runtime.agent_id == nil and runtime.status == "active"
    runtime
  end

  defp snapshot(%AgentRuntime{id: id}) do
    r = Federation.get_runtime(id)
    {r.status, r.auth_token_hash, r.metadata, r.updated_at}
  end

  setup do
    %{owner: member!()}
  end

  test "metadata is jsonb, so the || and jsonb_build_object cast hold" do
    %{rows: [[type]]} =
      Repo.query!(
        "SELECT data_type FROM information_schema.columns WHERE table_name = 'agent_runtimes' AND column_name = 'metadata'"
      )

    assert type == "jsonb"
  end

  test "an orphan's token cannot authenticate before the migration runs (the premise)", %{
    owner: owner
  } do
    {_orphan, token} = orphan!(owner, rid("premise"))
    assert Federation.get_runtime_by_token(token) == nil
  end

  test "revokes active agent_id-NULL unreferenced rows and leaves every other row alone", %{
    owner: owner
  } do
    {orphan_a, _} = orphan!(owner, rid("a"))
    {orphan_b, _} = orphan!(owner, rid("b"))

    {attached_agent, attached, _} = attached!(owner, rid("attached"))

    {:ok, voice, _token} =
      Federation.register_voice_runtime(owner.id, attached_agent, %{runtime_id: rid("voice")})

    assert voice.agent_id == attached_agent.id

    pointed = pointed_at!(owner, rid("pointed"))

    {:ok, pending} = Federation.register_runtime(owner.id, %{runtime_id: rid("pending")})
    assert pending.status == "pending" and pending.agent_id == nil

    {suspended_src, _} = orphan!(owner, rid("suspended"))
    {:ok, suspended} = Federation.suspend_runtime(suspended_src)
    assert suspended.status == "suspended" and suspended.agent_id == nil

    untouched = [attached, voice, pointed, pending, suspended]
    before = Map.new(untouched, &{&1.id, snapshot(&1)})

    assert run_up() == 2

    for orphan <- [orphan_a, orphan_b] do
      after_row = Federation.get_runtime(orphan.id)
      assert after_row.status == "revoked"
      assert after_row.auth_token_hash == nil
      assert after_row.metadata["revoked_reason"] == "orphan_runtime_revoked"
      assert {:ok, _, 0} = DateTime.from_iso8601(after_row.metadata["revoked_at"])
      # `now()` is the transaction start; under the SQL sandbox that predates
      # the fixture rows, so only inequality is meaningful here.
      refute DateTime.compare(after_row.updated_at, orphan.updated_at) == :eq
    end

    for row <- untouched do
      assert snapshot(row) == Map.fetch!(before, row.id), "#{row.runtime_id} must be unchanged"
    end
  end

  test "running it twice is harmless", %{owner: owner} do
    {orphan, _} = orphan!(owner, rid("twice"))

    assert run_up() == 1
    first = snapshot(orphan)

    assert run_up() == 0
    assert snapshot(orphan) == first
  end

  test "a revoked orphan's runtime_id can be registered again", %{owner: owner} do
    runtime_id = rid("reuse")
    {orphan, _} = orphan!(owner, runtime_id)

    assert {:error, %Ecto.Changeset{}} =
             Federation.register_runtime(owner.id, %{runtime_id: runtime_id})

    assert run_up() == 1

    assert {:ok, %AgentRuntime{} = reused} =
             Federation.register_runtime(owner.id, %{runtime_id: runtime_id})

    assert reused.id == orphan.id
    assert reused.status == "pending"
    assert reused.auth_token_hash == nil
  end

  test "down is a no-op and the file carries the old-code-compatible waiver" do
    assert Migration.down() == :ok
    assert File.read!(@migration) =~ ~r/^\s*#\s*old-code-compatible:\s*\S/m
  end
end
