defmodule Platform.Admin.ToolsTest do
  @moduledoc """
  The `admin` bundle and its one audit wrapper (task 01a17b10 stage 3).

  Mutant this names: delete the `audit/4` call in `run/4` and every "audit row"
  test goes red.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.AgentHost.Reconciler
  alias Platform.Agents.{AgentRuntime, Burrow}
  alias Platform.Audit.Event
  alias Platform.Federation.{AdminTools, ToolSurface}
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @all_tools ~w(admin_health admin_logs admin_env_names admin_migrations admin_rpc admin_restart admin_deploy admin_rollback)

  setup do
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, "admin-tools-token-01a17b10")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)

    owner = user!("owner")
    make_admin!(owner)
    {:ok, agent} = Burrow.ensure(owner.id, "claude_code")
    runtime = Repo.get!(AgentRuntime, agent.runtime_id)
    %{owner: owner, agent: agent, runtime: runtime, ctx: %{runtime_id: runtime.runtime_id}}
  end

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "admin-tools-#{label}-#{n}@example.com",
      name: "Admin tools #{label} #{n}",
      oidc_sub: "oidc-admin-tools-#{label}-#{n}"
    })
  end

  defp make_admin!(user) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "admin"
    })
    |> Repo.insert!()
  end

  # A host that answers `host.env_names` and `host.admin` the way the real one
  # does: a `host.reply` on the reply topic.
  defp fake_host(opts \\ []) do
    test = self()
    full_root = Keyword.get(opts, :full_root, false)
    names = Keyword.get(opts, :names, ["FAKE_ENV_FILE_NAME"])

    host =
      spawn_link(fn ->
        loop = fn loop ->
          receive do
            {:agent_host_push, event, %{"ref" => ref} = payload} ->
              send(test, {:host_got, event, payload})

              result =
                case event do
                  "host.env_names" -> %{"names" => names}
                  "host.admin" -> %{"service" => payload["service"], "restarted" => true}
                end

              Phoenix.PubSub.broadcast(
                Platform.PubSub,
                Platform.AgentHost.reply_topic(ref),
                {:agent_host_reply, ref, result}
              )

              loop.(loop)

            _ ->
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    :ok = Reconciler.host_joined(host, %{"profile" => "contained", "full_root" => full_root})
    host
  end

  defp rows(tool) do
    Repo.all(
      from(e in Event,
        where: e.event_type == "platform.admin.call" and e.action == ^tool,
        order_by: [asc: e.id]
      )
    )
  end

  describe "the bundle" do
    test "is a valid module, in the first-agent grant, declared and permissioned", %{runtime: rt} do
      assert "admin" in Platform.Access.RuntimeProfiles.valid_modules()
      assert "admin" in ToolSurface.all_bundles()
      assert "admin" in Platform.Federation.first_agent_bundles()
      assert "admin" in Platform.Access.RuntimeProfiles.tool_profile(rt)
      assert Platform.Access.Registry.undeclared_bundles() == []

      names = for t <- ToolSurface.list_tools(["admin"]), do: t.name
      assert Enum.sort(names) == Enum.sort(@all_tools)

      for t <- @all_tools,
          do: assert(Platform.Access.ToolPermissions.for_tool(t) == "admin.use")

      assert Platform.Access.ToolPermissions.bundle_permissions("admin") ==
               MapSet.new(["admin.use"])
    end

    test "no admin tool takes a confirm or approve argument" do
      for d <- AdminTools.definitions(), {param, _} <- d.parameters do
        refute to_string(param) =~ ~r/confirm|approve|allow|yes/i, "#{d.name}.#{param}"
      end

      assert length(AdminTools.definitions()) == 8
    end
  end

  describe "admin_health backup_status" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "backup-status-#{System.unique_integer([:positive])}.json")

      previous = Application.get_env(:platform, :backup_status_path)
      Application.put_env(:platform, :backup_status_path, path)

      on_exit(fn ->
        File.rm(path)

        if previous,
          do: Application.put_env(:platform, :backup_status_path, previous),
          else: Application.delete_env(:platform, :backup_status_path)
      end)

      %{path: path}
    end

    test "no status file reads as not configured", %{ctx: ctx} do
      assert {:ok, %{backup_status: %{configured: false}}} =
               ToolSurface.execute("admin_health", %{}, ctx)
    end

    test "reports last success time and size from the job's status file", %{ctx: ctx, path: path} do
      File.write!(
        path,
        ~s({"last_success_at":"2026-10-27T03:15:42Z","size_bytes":4016,"target":"local-path","databases":3})
      )

      assert {:ok, %{backup_status: status}} = ToolSurface.execute("admin_health", %{}, ctx)
      assert status.configured
      assert status.last_success_at == "2026-10-27T03:15:42Z"
      assert status.size_bytes == 4016
    end

    test "a garbled file is reported, not crashed on", %{ctx: ctx, path: path} do
      File.write!(path, "not json")

      assert {:ok, %{backup_status: %{configured: true, error: "invalid"}}} =
               ToolSurface.execute("admin_health", %{}, ctx)
    end
  end

  describe "an audit row per tool" do
    test "every tool writes one row with actor, tool, args, result and time", %{
      agent: agent,
      owner: owner,
      ctx: ctx
    } do
      fake_host()

      calls = [
        {"admin_health", %{}},
        {"admin_logs", %{"source" => "core", "lines" => 5}},
        {"admin_env_names", %{}},
        {"admin_migrations", %{"action" => "status"}},
        {"admin_rpc", %{"expression" => "1 + 1"}},
        {"admin_restart", %{"service" => "core-platform"}},
        {"admin_deploy", %{"service" => "core-platform", "tag" => "v1"}},
        {"admin_rollback", %{"service" => "core-platform"}}
      ]

      for {tool, args} <- calls do
        assert {:ok, _} = ToolSurface.execute(tool, args, ctx), tool
        assert [row] = rows(tool), tool
        assert row.actor_type == "agent"
        assert row.actor_id == agent.id
        assert row.resource_id == tool
        assert row.metadata["tool"] == tool
        assert row.metadata["owner_id"] == owner.id
        assert row.metadata["result"] in ["ok", "requires_full_root"]
        assert is_binary(row.metadata["at"])
        assert %DateTime{} = row.inserted_at
      end
    end

    test "a failure gets a row too", %{ctx: ctx, agent: agent} do
      assert {:error, _} =
               ToolSurface.execute("admin_rpc", %{"expression" => "raise \"boom\""}, ctx)

      assert [row] = rows("admin_rpc")
      assert row.actor_id == agent.id
      assert row.metadata["result"] == "error"
      assert row.metadata["detail"] =~ "boom"

      assert {:error, _} = ToolSurface.execute("admin_logs", %{"source" => "nowhere"}, ctx)
      assert [%{metadata: %{"result" => "error"}}] = rows("admin_logs")
    end

    test "a caller without install.admin is refused, and the refusal is audited" do
      member = user!("member")

      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: member.id,
        org_id: Platform.TenancyFixtures.acme_org_id(),
        role: "member"
      })
      |> Repo.insert!()

      {:ok, _agent, rt} =
        Platform.Agents.NativeAgents.create(member.id, %{name: "Plain", harness: "claude_code"})

      # Give it the bundle: the owner cap, not the profile, must refuse.
      {:ok, _} =
        Platform.Access.RuntimeProfiles.set_tool_profile(Repo.get!(AgentRuntime, rt.id), ["admin"])

      ctx = %{runtime_id: rt.runtime_id}
      assert {:error, %{code: "forbidden"}} = ToolSurface.execute("admin_health", %{}, ctx)
      assert [%{metadata: %{"result" => "forbidden"}}] = rows("admin_health")
    end

    test "args are redacted in the row: secret-shaped keys at any depth, secret-shaped values", %{
      ctx: ctx
    } do
      probe = "probe-" <> Ecto.UUID.generate()

      assert {:ok, _} =
               ToolSurface.execute(
                 "admin_rpc",
                 %{
                   "expression" => "1",
                   "api_token" => probe,
                   "args" => %{
                     "db_password" => probe,
                     "nested" => [%{"my_secret" => probe}],
                     "n" => 1
                   },
                   "note" => "key sk-ant-api03-#{probe}"
                 },
                 ctx
               )

      [row] = rows("admin_rpc")
      args = row.metadata["args"]
      assert args["api_token"] == "[redacted]"
      assert args["args"]["db_password"] == "[redacted]"
      assert [%{"my_secret" => "[redacted]"}] = args["args"]["nested"]
      assert args["args"]["n"] == 1
      assert args["note"] =~ "sk-ant-[redacted]"
      refute inspect(row.metadata) =~ probe
    end
  end

  describe "env names" do
    test "names only: the secret value is in neither the result nor the audit row", %{ctx: ctx} do
      probe = "env-probe-" <> Ecto.UUID.generate()
      System.put_env("FAKE_SECRET_PROBE", probe)
      on_exit(fn -> System.delete_env("FAKE_SECRET_PROBE") end)
      fake_host(names: ["FAKE_ENV_FILE_NAME"])

      assert {:ok, result} = ToolSurface.execute("admin_env_names", %{}, ctx)
      assert "FAKE_SECRET_PROBE" in result.core

      assert [%{names: ["FAKE_ENV_FILE_NAME"]}] =
               Enum.filter(result.agents, &Map.has_key?(&1, :names))

      refute inspect(result, limit: :infinity) =~ probe

      [row] = rows("admin_env_names")
      refute inspect(row, limit: :infinity) =~ probe
    end
  end

  describe "full root" do
    test "restart, deploy and rollback return requires_full_root while it is off", %{ctx: ctx} do
      fake_host(full_root: false)

      for {tool, args} <- [
            {"admin_restart", %{}},
            {"admin_deploy", %{"tag" => "v2"}},
            {"admin_rollback", %{}}
          ] do
        assert {:ok, %{error: "requires_full_root", manifest_key: "agents.full_root"}} =
                 ToolSurface.execute(tool, args, ctx)

        assert [%{metadata: %{"result" => "requires_full_root"}}] = rows(tool)
      end

      refute_received {:host_got, "host.admin", _}
    end

    test "with it on, the host is asked, and a started row precedes the result row", %{ctx: ctx} do
      fake_host(full_root: true)
      assert Platform.AgentHost.full_root?()

      assert {:ok, %{"restarted" => true}} =
               ToolSurface.execute("admin_restart", %{"service" => "memory-service"}, ctx)

      assert_received {:host_got, "host.admin",
                       %{"op" => "restart", "service" => "memory-service"}}

      assert ["started", "ok"] == Enum.map(rows("admin_restart"), & &1.metadata["result"])
    end
  end
end
