defmodule Platform.Agents.ConfigFilesRestartTest do
  @moduledoc """
  Restart session (task 01a17b1c stage 4): `ConfigFiles.restart/3`,
  `pending_changes/1`, `running_task/1`, over the fake runtime host
  (federated, `session.restart` on `runtime_host:`) and the fake agent host
  (native, `agent.restart` with a ref).
  """
  use PlatformWeb.ChannelCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, ConfigFiles, NativeAgents}
  alias Platform.Audit.Event
  alias Platform.{FakeAgentHost, FakeRuntimeHost, Federation, Repo}
  alias Platform.Tenancy.OrgMembership

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "rst-#{label}-#{n}@example.com",
      name: "Rst #{label} #{n}",
      oidc_sub: "oidc-rst-#{label}-#{n}"
    })
  end

  defp member!(role) do
    user = user!(role)

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: role
    })
    |> Repo.insert!()

    user
  end

  defp tmp!(label) do
    dir = Path.join(System.tmp_dir!(), "rst-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp federated!(owner, opts) do
    root = tmp!("host")
    n = System.unique_integer([:positive])
    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: "rst-rt-#{n}"})
    {:ok, runtime, _token} = Federation.activate_runtime(runtime)

    agent =
      %Agent{}
      |> Agent.changeset(%{slug: "rst-agent-#{n}", name: "Rst Fed #{n}", status: "active"})
      |> Repo.insert!()

    {:ok, agent} = Federation.link_agent(runtime, agent)

    host =
      if Keyword.get(opts, :host, true) do
        pid =
          start_supervised!(
            {FakeRuntimeHost,
             [runtime_id: runtime.runtime_id, root: root, test_process: self()] ++
               Keyword.take(opts, [:opt_in, :session, :silent])},
            id: {:host, n}
          )

        :ok = FakeRuntimeHost.ready(pid)
        pid
      end

    %{agent: agent, runtime: runtime, root: root, host: host}
  end

  defp native!(owner, harness \\ "claude_code") do
    {:ok, agent, _runtime} =
      NativeAgents.create(owner.id, %{
        name: "Rst #{System.unique_integer([:positive])}",
        harness: harness
      })

    agent
  end

  defp rows(agent_id) do
    import Ecto.Query

    Repo.all(
      from(e in Event,
        where: e.resource_id == ^agent_id and like(e.event_type, "config.restart%"),
        order_by: e.id
      )
    )
  end

  setup do
    %{owner: member!("member"), admin: member!("admin"), other: member!("member")}
  end

  describe "federated (session.restart over runtime_host)" do
    test "the diff is computed from the host's snapshots, broadcast, and audited twice", %{
      owner: owner
    } do
      %{agent: agent, host: host} =
        federated!(owner,
          session: {["A/a_ping"], ["A/a_ping", "B/b_echo", "B/b_ping", "unreachable:C"]}
        )

      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, ConfigFiles.restart_topic(agent.id))

      assert {:ok, diff} = ConfigFiles.restart(owner, agent)
      assert diff.added == ["B/b_echo", "B/b_ping", "unreachable:C"]
      assert diff.removed == []
      assert diff.outcome == "ready"
      assert diff.resumed == true
      assert diff.before_basis == "loaded"
      # Burrow's own tools are on both sides, so they never show in the diff.
      assert "A/a_ping" in diff.before and "B/b_ping" in diff.after
      assert length(diff.after) - length(diff.before) == 3

      assert_receive {:agent_session_restarted, agent_id, ^diff}
      assert agent_id == agent.id

      # The CLI checks its own opt-in against this role.
      assert {"session.restart", "owner"} in FakeRuntimeHost.served(host)

      assert [
               %{
                 event_type: "config.restart_requested",
                 actor_id: a1,
                 metadata: %{"result" => "requested"}
               },
               %{event_type: "config.restart", actor_id: a2, metadata: meta}
             ] = rows(agent.id)

      assert a1 == owner.id and a2 == owner.id

      assert %{
               "result" => "ok",
               "outcome" => "ready",
               "resumed" => true,
               "added_count" => 3,
               "removed_count" => 0
             } =
               meta

      assert meta["after_count"] - meta["before_count"] == 3
      refute Map.has_key?(meta, "added")
    end

    test "a non-owner is forbidden, with the request and the refusal audited", %{
      owner: owner,
      other: other
    } do
      %{agent: agent, host: host} = federated!(owner, session: {[], ["B/x"]})
      agent_token = %{id: Ecto.UUID.generate(), actor_type: "agent"}

      for actor <- [other, agent_token] do
        assert {:error, :forbidden} = ConfigFiles.restart(actor, agent)
      end

      refute Enum.any?(FakeRuntimeHost.served(host), &match?({"session.restart", _}, &1))

      assert [
               %{event_type: "config.restart_requested"},
               %{event_type: "config.restart", metadata: %{"result" => "refused:forbidden"}},
               %{event_type: "config.restart_requested"},
               %{event_type: "config.restart", metadata: %{"result" => "refused:forbidden"}}
             ] = rows(agent.id)
    end

    test "owner_only refuses a root admin; admins lets one restart", %{owner: owner, admin: admin} do
      %{agent: a1} = federated!(owner, session: {[], []})
      assert {:error, :forbidden} = ConfigFiles.restart(admin, a1)

      %{agent: a2, host: host} = federated!(owner, session: {[], []}, opt_in: "admins")
      assert {:ok, _} = ConfigFiles.restart(admin, a2)
      assert {"session.restart", "admin"} in FakeRuntimeHost.served(host)
    end

    test "an offline host is {:error, :host_offline}, and the refusal is audited", %{owner: owner} do
      %{agent: agent} = federated!(owner, host: false)
      assert {:error, :host_offline} = ConfigFiles.restart(owner, agent)

      assert [
               %{event_type: "config.restart_requested"},
               %{event_type: "config.restart", metadata: %{"result" => "refused:host_offline"}}
             ] = rows(agent.id)
    end

    test "a host that never answers is host_offline after the timeout", %{owner: owner} do
      %{agent: agent} = federated!(owner, session: {[], []}, silent: true)
      assert {:error, :host_offline} = ConfigFiles.restart(owner, agent, timeout: 200)
      assert [_, %{metadata: %{"result" => "refused:host_offline"}}] = rows(agent.id)
    end

    test "no recorded session on the machine is refused, never faked", %{owner: owner} do
      %{agent: agent} = federated!(owner, [])
      assert {:error, {:host_error, "no_recorded_session"}} = ConfigFiles.restart(owner, agent)
      assert [_, %{metadata: %{"result" => "refused:host_error"}}] = rows(agent.id)
    end

    test "pending_changes: paths saved since the last successful restart", %{owner: owner} do
      %{agent: agent} = federated!(owner, session: {[], []})
      assert ConfigFiles.pending_changes(agent) == []
      assert {:ok, _} = ConfigFiles.write(owner, agent, "CLAUDE.md", "# one\n", nil)
      assert {:ok, _} = ConfigFiles.write(owner, agent, ".mcp.json", "{}\n", nil)
      # A refused write is not pending.
      assert {:conflict, _} = ConfigFiles.write(owner, agent, "CLAUDE.md", "# two\n", nil)
      assert ConfigFiles.pending_changes(agent) == [".mcp.json", "CLAUDE.md"]

      assert {:ok, _} = ConfigFiles.restart(owner, agent)
      assert ConfigFiles.pending_changes(agent) == []
    end
  end

  describe "native (agent.restart with a ref)" do
    test "the diff comes from the agent host's snapshots", %{owner: owner} do
      start_supervised!(
        {FakeAgentHost, root: tmp!("agents"), restart: {"ready", ["A/x"], ["A/x", "B/y"]}}
      )

      agent = native!(owner)

      assert {:ok, diff} = ConfigFiles.restart(owner, agent)
      assert diff.added == ["B/y"]
      assert diff.removed == []
      assert diff.outcome == "ready"
      assert diff.resumed == true

      assert [%{event_type: "config.restart_requested"}, %{metadata: %{"result" => "ok"}}] =
               rows(agent.id)
    end

    test "a needs_login agent comes back with no probe output and an empty diff", %{owner: owner} do
      start_supervised!({FakeAgentHost, root: tmp!("agents"), restart: {"needs_login", nil, nil}})
      agent = native!(owner)

      assert {:ok, %{outcome: "needs_login", before: nil, after: nil, added: [], removed: []}} =
               ConfigFiles.restart(owner, agent)
    end

    test "no agent host connected is host_offline; a codex native agent has no restart", %{
      owner: owner
    } do
      agent = native!(owner)
      assert {:error, :host_offline} = ConfigFiles.restart(owner, agent)

      start_supervised!({FakeAgentHost, root: tmp!("agents")})
      codex = native!(owner, "codex")
      assert {:error, :unsupported_harness} = ConfigFiles.restart(owner, codex)
    end

    test "a non-owner member is forbidden; a root admin may restart", %{
      owner: owner,
      other: other,
      admin: admin
    } do
      start_supervised!({FakeAgentHost, root: tmp!("agents")})
      agent = native!(owner)
      assert {:error, :forbidden} = ConfigFiles.restart(other, agent)
      assert {:ok, _} = ConfigFiles.restart(admin, agent)
    end
  end

  describe "running_task/1" do
    test "the title of the agent's in-progress task, or nil", %{owner: owner} do
      agent = native!(owner)
      assert ConfigFiles.running_task(agent) == nil

      {:ok, project} =
        Platform.Tasks.create_project(%{name: "Rst #{System.unique_integer([:positive])}"})

      {:ok, task} =
        Platform.Tasks.create_task(%{
          project_id: project.id,
          title: "Wire the restart strip",
          phase_assignees: %{
            "execution" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
          }
        })

      {:ok, _} = task |> Ecto.Changeset.change(status: "in_progress") |> Repo.update()
      assert %{title: "Wire the restart strip"} = ConfigFiles.running_task(agent)
    end
  end
end
