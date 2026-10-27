defmodule Platform.Agents.ConfigFilesTest do
  @moduledoc """
  The config channel (task 01a17b1c stage 2): `Platform.Agents.ConfigFiles`
  over both backends, `Config.Access`, the `runtime_host:` channel and the
  audit trail.

  Mutants these name (each run and pasted in the stage evidence):

    * drop the `expected_sha256` compare in `Backend.WorkspaceStore` and in
      `FakeRuntimeHost` -> the conflict cases go red;
    * skip core's second redaction in `ConfigFiles.read/3` -> the secret
      cases (the fake host sends raw) go red;
    * deny the root admin on a native agent -> "a root admin can write a
      native agent's config" goes red;
    * let a root admin through at `:owner_only` -> "owner_only refuses an
      admin" goes red;
    * delete the audit call -> the audit cases go red.
  """
  use PlatformWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, ConfigFiles, MemoryContext, NativeAgents}
  alias Platform.Agents.ConfigFiles.Access
  alias Platform.Audit.Event
  alias Platform.{FakeAgentHost, FakeRuntimeHost, Federation, Repo}
  alias Platform.Federation.{RemoteAccess, RuntimeHosts}
  alias Platform.Tenancy.OrgMembership

  # ── fixtures ───────────────────────────────────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "cfg-#{label}-#{n}@example.com",
      name: "Cfg #{label} #{n}",
      oidc_sub: "oidc-cfg-#{label}-#{n}"
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
    dir = Path.join(System.tmp_dir!(), "cfg-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp sha(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  defp probe, do: "probe-" <> Ecto.UUID.generate()

  defp native!(owner, harness \\ "claude_code") do
    {:ok, agent, _runtime} =
      NativeAgents.create(owner.id, %{
        name: "Cfg #{System.unique_integer([:positive])}",
        harness: harness
      })

    agent
  end

  defp native_store!(agent, key, content),
    do: {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, key, content)

  # A federated agent whose host (the fake) has joined `runtime_host:<id>`.
  defp federated!(owner, opts \\ []) do
    root = tmp!("host")
    n = System.unique_integer([:positive])
    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: "cfg-rt-#{n}"})
    {:ok, runtime, _token} = Federation.activate_runtime(runtime)

    agent =
      %Agent{}
      |> Agent.changeset(%{slug: "cfg-agent-#{n}", name: "Cfg Fed #{n}", status: "active"})
      |> Repo.insert!()

    {:ok, agent} = Federation.link_agent(runtime, agent)

    host =
      if Keyword.get(opts, :host, true) do
        pid =
          start_supervised!(
            {FakeRuntimeHost,
             [runtime_id: runtime.runtime_id, root: root, test_process: self()] ++
               Keyword.take(opts, [:opt_in, :raw, :harness])},
            id: {:host, n}
          )

        :ok = FakeRuntimeHost.ready(pid)
        pid
      end

    %{agent: agent, runtime: runtime, root: root, host: host}
  end

  defp audit_rows(agent_id) do
    import Ecto.Query

    Repo.all(
      from(e in Event,
        where: e.resource_id == ^agent_id and like(e.event_type, "config.%"),
        order_by: e.id
      )
    )
  end

  setup do
    %{owner: member!("member"), admin: member!("admin"), other: member!("member")}
  end

  # ── native: owner OR root admin ────────────────────────────────────

  describe "native agent (WorkspaceStore)" do
    test "the owner can write, and the write is audited once", %{owner: owner} do
      agent = native!(owner)
      {:ok, entries} = ConfigFiles.list(owner, agent)
      claude = Enum.find(entries, &(&1.path == "CLAUDE.md"))
      assert %{sha256: <<_::binary-size(64)>>, secret?: false} = claude

      assert {:ok, new_sha} =
               ConfigFiles.write(owner, agent, "CLAUDE.md", "# mine\n", claude.sha256)

      assert new_sha == sha("# mine\n")
      assert {:ok, %{content: "# mine\n"}} = ConfigFiles.read(owner, agent, "CLAUDE.md")

      assert [%{event_type: "config.write", actor_id: actor_id, metadata: meta}] =
               audit_rows(agent.id)

      assert actor_id == owner.id

      assert %{
               "result" => "ok",
               "path" => "CLAUDE.md",
               "old_sha256" => _,
               "new_sha256" => ^new_sha
             } = meta
    end

    test "a root admin can write a native agent's config", %{owner: owner, admin: admin} do
      agent = native!(owner)
      {:ok, %{sha256: sha}} = ConfigFiles.read(admin, agent, "CLAUDE.md")
      assert {:ok, _} = ConfigFiles.write(admin, agent, "CLAUDE.md", "# by admin\n", sha)
      assert %{content: "# by admin\n"} = MemoryContext.get_workspace_file(agent.id, "CLAUDE.md")
    end

    test "another member and an agent token are forbidden, and each refusal is audited", %{
      owner: owner,
      other: other
    } do
      agent = native!(owner)
      before = MemoryContext.get_workspace_file(agent.id, "CLAUDE.md")
      agent_token = %{id: Ecto.UUID.generate(), actor_type: "agent"}

      for actor <- [other, agent_token] do
        assert {:error, :forbidden} = ConfigFiles.list(actor, agent)
        assert {:error, :forbidden} = ConfigFiles.read(actor, agent, "CLAUDE.md")

        assert {:error, :forbidden} =
                 ConfigFiles.write(actor, agent, "CLAUDE.md", "x", sha(before.content))

        assert {:error, :forbidden} = ConfigFiles.set_secret(actor, agent, ".env", "K", "v")
      end

      assert MemoryContext.get_workspace_file(agent.id, "CLAUDE.md").content == before.content
      assert length(audit_rows(agent.id)) == 4
      assert Enum.all?(audit_rows(agent.id), &(&1.metadata["result"] == "refused:forbidden"))
    end

    test "a stale expected_sha256 is a conflict and the file is unchanged", %{owner: owner} do
      agent = native!(owner)
      before = MemoryContext.get_workspace_file(agent.id, "CLAUDE.md")

      assert {:conflict, current} =
               ConfigFiles.write(owner, agent, "CLAUDE.md", "# lost\n", sha("stale"))

      assert current == sha(before.content)
      assert MemoryContext.get_workspace_file(agent.id, "CLAUDE.md").content == before.content

      assert {:conflict, _} = ConfigFiles.write(owner, agent, "CLAUDE.md", "# create-only\n", nil)

      assert [%{metadata: %{"result" => "conflict"}}, %{metadata: %{"result" => "conflict"}}] =
               audit_rows(agent.id)
    end

    test "drift: a disk edit by the agent makes a store write a conflict", %{owner: owner} do
      agent = native!(owner)
      root = tmp!("agents")
      File.mkdir_p!(Path.join(root, agent.id))
      stored = MemoryContext.get_workspace_file(agent.id, "CLAUDE.md")
      disk = stored.content <> "\nthe agent added this line\n"
      File.write!(Path.join([root, agent.id, "CLAUDE.md"]), disk)

      host = start_supervised!({FakeAgentHost, root: root})

      :ok =
        FakeAgentHost.report(host, agent.id, "running", %{
          "files_applied" => %{"CLAUDE.md" => stored.version},
          "files_drifted" => ["CLAUDE.md"]
        })

      assert NativeAgents.drifted_keys(agent) == ["CLAUDE.md"]

      assert {:conflict, disk_sha} =
               ConfigFiles.write(owner, agent, "CLAUDE.md", "# mine\n", sha(stored.content))

      assert disk_sha == sha(disk)
      assert MemoryContext.get_workspace_file(agent.id, "CLAUDE.md").content == stored.content
      assert NativeAgents.force_keys(agent) == []

      # Compare shows the disk copy; saving on top of it (expected = disk sha) resolves.
      assert {:ok, %{content: ^disk}} = ConfigFiles.read_disk(owner, agent, "CLAUDE.md")

      assert {:ok, _} =
               ConfigFiles.write(owner, agent, "CLAUDE.md", disk <> "mine too\n", disk_sha)

      assert NativeAgents.force_keys(agent) == ["CLAUDE.md"]
    end

    test "secrets: names are shown, values never are (list, read, audit, log)", %{owner: owner} do
      agent = native!(owner)
      p = probe()
      native_store!(agent, ".env", "API_KEY=#{p}\nOTHER=#{p}\n")

      native_store!(
        agent,
        ".mcp.json",
        Jason.encode!(%{
          "mcpServers" => %{
            "srv" => %{
              "command" => "x",
              "env" => %{"FAKE_TOKEN" => p},
              "headers" => %{"X-Key" => p}
            }
          }
        })
      )

      log =
        capture_log([level: :debug], fn ->
          send(
            self(),
            {:results,
             [
               ConfigFiles.list(owner, agent),
               ConfigFiles.read(owner, agent, ".env"),
               ConfigFiles.read(owner, agent, ".mcp.json")
             ]}
          )
        end)

      assert_received {:results, [{:ok, list}, {:ok, env}, {:ok, mcp}]}
      assert Enum.find(list, &(&1.path == ".env")).secret?
      assert env.secret_names == ["API_KEY", "OTHER"]
      assert mcp.secret_names == ["FAKE_TOKEN", "X-Key"]
      refute inspect({list, env, mcp}) =~ p
      refute log =~ p
      assert mcp.content =~ "FAKE_TOKEN"

      # A secret file is not writable as text; a redacted write keeps the stored secrets.
      assert {:error, :secret_path} = ConfigFiles.write(owner, agent, ".env", "A=b\n", sha(""))

      assert {:ok, _} =
               ConfigFiles.write(
                 owner,
                 agent,
                 ".mcp.json",
                 String.replace(mcp.content, "\"x\"", "\"y\""),
                 mcp.sha256
               )

      assert MemoryContext.get_workspace_file(agent.id, ".mcp.json").content =~ p

      # set_secret is write-only: the value changes on the store and still reads hidden.
      new = probe()
      assert {:ok, _} = ConfigFiles.set_secret(owner, agent, ".env", "API_KEY", new)
      assert MemoryContext.get_workspace_file(agent.id, ".env").content =~ new
      assert {:ok, env2} = ConfigFiles.read(owner, agent, ".env")
      refute inspect(env2) =~ new
      refute inspect(Enum.map(audit_rows(agent.id), & &1.metadata)) =~ p
      refute inspect(Enum.map(audit_rows(agent.id), & &1.metadata)) =~ new
    end

    test "settings_key/1 and the harness seed", %{owner: owner} do
      agent = native!(owner, "codex")
      assert {:ok, entries} = ConfigFiles.list(owner, agent)
      assert ".codex/config.toml" in Enum.map(entries, & &1.path)
    end
  end

  # ── federated: kind x opt-in ───────────────────────────────────────

  describe "federated agent (Host backend)" do
    test "every request names the actor role", %{owner: owner, admin: admin} do
      %{agent: agent, host: host} = federated!(owner, opt_in: "admins")
      {:ok, _} = ConfigFiles.list(owner, agent)
      {:ok, _} = ConfigFiles.list(admin, agent)
      assert FakeRuntimeHost.served(host) == [{"file.list", "owner"}, {"file.list", "admin"}]
    end

    test "a skill (four path segments) can be written on both backends", %{owner: owner} do
      path = ".claude/skills/probe-skill/SKILL.md"

      assert {:ok, _} =
               ConfigFiles.write(
                 owner,
                 native!(owner),
                 path,
                 "---\nname: probe-skill\n---\n",
                 nil
               )

      %{agent: agent, root: root} = federated!(owner)

      assert {:ok, _} =
               ConfigFiles.write(owner, agent, path, "---\nname: probe-skill\n---\n", nil)

      assert File.exists?(Path.join(root, path))
    end

    test "the owner can write through the host, the disk changes, one audit row", %{owner: owner} do
      %{agent: agent, root: root} = federated!(owner)
      File.write!(Path.join(root, "CLAUDE.md"), "# before\n")

      {:ok, entries} = ConfigFiles.list(owner, agent)
      %{sha256: current} = Enum.find(entries, &(&1.path == "CLAUDE.md"))

      assert {:ok, new_sha} = ConfigFiles.write(owner, agent, "CLAUDE.md", "# after\n", current)
      assert File.read!(Path.join(root, "CLAUDE.md")) == "# after\n"
      assert new_sha == sha("# after\n")
      assert [%{metadata: %{"result" => "ok"}}] = audit_rows(agent.id)
    end

    test "a stale expected_sha256 is a conflict and the disk file is unchanged", %{owner: owner} do
      %{agent: agent, root: root} = federated!(owner)
      File.write!(Path.join(root, "CLAUDE.md"), "# on the machine\n")

      assert {:conflict, current} =
               ConfigFiles.write(owner, agent, "CLAUDE.md", "# mine\n", sha("stale"))

      assert current == sha("# on the machine\n")
      assert File.read!(Path.join(root, "CLAUDE.md")) == "# on the machine\n"
      assert {:conflict, _} = ConfigFiles.write(owner, agent, "CLAUDE.md", "# create-only\n", nil)
      assert Enum.map(audit_rows(agent.id), & &1.metadata["result"]) == ["conflict", "conflict"]
    end

    test "opted out (off): refused for everyone, audited, nothing written", %{
      owner: owner,
      admin: admin
    } do
      %{agent: agent, root: root} = federated!(owner, opt_in: "off")

      assert {:error, :opt_in_required} = ConfigFiles.write(owner, agent, "CLAUDE.md", "x", nil)
      assert {:error, :forbidden} = ConfigFiles.write(admin, agent, "CLAUDE.md", "x", nil)
      assert {:error, :opt_in_required} = ConfigFiles.list(owner, agent)
      refute File.exists?(Path.join(root, "CLAUDE.md"))
      assert length(audit_rows(agent.id)) == 2
    end

    test "owner_only refuses an admin; the owner is allowed", %{
      owner: owner,
      admin: admin,
      other: other
    } do
      %{agent: agent, root: root} = federated!(owner, opt_in: "owner_only")

      assert {:error, :forbidden} = ConfigFiles.write(admin, agent, "CLAUDE.md", "x", nil)
      assert {:error, :forbidden} = ConfigFiles.write(other, agent, "CLAUDE.md", "x", nil)
      refute File.exists?(Path.join(root, "CLAUDE.md"))
      assert {:ok, _} = ConfigFiles.write(owner, agent, "CLAUDE.md", "x\n", nil)
    end

    test "admins allows a root admin, still not another member", %{
      owner: owner,
      admin: admin,
      other: other
    } do
      %{agent: agent, root: root} = federated!(owner, opt_in: "admins")

      assert {:ok, _} = ConfigFiles.write(admin, agent, "CLAUDE.md", "by admin\n", nil)
      assert File.read!(Path.join(root, "CLAUDE.md")) == "by admin\n"

      assert {:error, :forbidden} =
               ConfigFiles.write(other, agent, "CLAUDE.md", "x", sha("by admin\n"))
    end

    test "a kind other than own-agent-in-member-install cannot be switched on", %{admin: admin} do
      # An owner who is not a member of this install: not "own agent in a member install".
      outsider = user!("outsider")
      %{agent: agent, runtime: runtime} = federated!(outsider, opt_in: "admins")

      assert Access.runtime_kind(Federation.get_runtime(runtime.id)) == :other_federation
      assert {:error, :forbidden} = ConfigFiles.write(outsider, agent, "CLAUDE.md", "x", nil)
      assert {:error, :forbidden} = ConfigFiles.write(admin, agent, "CLAUDE.md", "x", nil)

      for opt_in <- Access.opt_ins(), role <- [:owner, :admin, :other] do
        refute Access.decide(:other_federation, opt_in, role)
      end

      assert RemoteAccess.allowed_kinds() == [:own_agent_in_member_install]
      assert Access.decide(:own_agent_in_member_install, :admins, :admin)
      refute Access.decide(:own_agent_in_member_install, :owner_only, :admin)
      refute Access.decide(:own_agent_in_member_install, :off, :owner)
    end

    test "an agent token is forbidden everywhere", %{owner: owner} do
      %{agent: agent} = federated!(owner, opt_in: "admins")
      token = %{id: owner.id, actor_type: "agent"}

      assert {:error, :forbidden} = ConfigFiles.list(token, agent)
      assert {:error, :forbidden} = ConfigFiles.read(token, agent, "CLAUDE.md")
      assert {:error, :forbidden} = ConfigFiles.write(token, agent, "CLAUDE.md", "x", nil)
      assert {:error, :forbidden} = ConfigFiles.set_secret(token, agent, ".env", "K", "v")
    end

    test "no joined host is :host_offline, and the refusal is audited", %{owner: owner} do
      %{agent: agent} = federated!(owner, host: false)
      assert {:error, :host_offline} = ConfigFiles.write(owner, agent, "CLAUDE.md", "x", nil)
      assert [%{metadata: %{"result" => "refused:host_offline"}}] = audit_rows(agent.id)
    end

    test "a harness with no adapter has no config", %{owner: owner} do
      %{agent: agent} = federated!(owner, harness: "hermes")
      assert {:error, :unsupported_harness} = ConfigFiles.list(owner, agent)
    end

    test "secrets: the host sends raw, core still hides every value", %{owner: owner} do
      %{agent: agent, root: root} = federated!(owner, raw: true)
      p = probe()
      File.write!(Path.join(root, ".env"), "API_KEY=#{p}\n")

      File.write!(
        Path.join(root, ".mcp.json"),
        Jason.encode!(%{
          "mcpServers" => %{
            "srv" => %{
              "command" => "x",
              "env" => %{"FAKE_TOKEN" => p},
              "headers" => %{"X-Key" => p}
            }
          }
        })
      )

      log =
        capture_log([level: :debug], fn ->
          send(
            self(),
            {:r,
             [
               ConfigFiles.list(owner, agent),
               ConfigFiles.read(owner, agent, ".env"),
               ConfigFiles.read(owner, agent, ".mcp.json")
             ]}
          )
        end)

      assert_received {:r, [{:ok, list}, {:ok, env}, {:ok, mcp}]}
      assert env.secret_names == ["API_KEY"]
      assert mcp.secret_names == ["FAKE_TOKEN", "X-Key"]
      refute inspect({list, env, mcp}) =~ p
      refute log =~ p

      # set_secret reaches the disk, and later reads still hide it.
      new = probe()

      log2 =
        capture_log([level: :debug], fn ->
          send(self(), {:set, ConfigFiles.set_secret(owner, agent, ".env", "API_KEY", new)})
        end)

      assert_received {:set, {:ok, _}}
      assert File.read!(Path.join(root, ".env")) =~ new
      assert {:ok, env2} = ConfigFiles.read(owner, agent, ".env")
      refute inspect(env2) =~ new
      refute log2 =~ new
      refute inspect(Enum.map(audit_rows(agent.id), & &1.metadata)) =~ new
    end

    test "every write attempt leaves exactly one audit row", %{owner: owner, other: other} do
      %{agent: agent} = federated!(owner)

      assert {:ok, _} = ConfigFiles.write(owner, agent, "a.md", "1\n", nil)
      assert length(audit_rows(agent.id)) == 1
      assert {:conflict, _} = ConfigFiles.write(owner, agent, "a.md", "2\n", sha("nope"))
      assert length(audit_rows(agent.id)) == 2
      assert {:error, :forbidden} = ConfigFiles.write(other, agent, "a.md", "3\n", nil)
      assert length(audit_rows(agent.id)) == 3
      assert {:error, :invalid_path} = ConfigFiles.write(owner, agent, "../etc/x", "4\n", nil)
      assert length(audit_rows(agent.id)) == 4
      assert {:ok, _} = ConfigFiles.set_secret(owner, agent, ".env", "K", "v")

      assert Enum.map(audit_rows(agent.id), & &1.event_type) ==
               ~w(config.write config.write config.write config.write config.secret_set)
    end
  end

  # ── the channel ────────────────────────────────────────────────────

  describe "runtime_host channel" do
    test "joining another runtime's topic is refused", %{owner: owner} do
      %{runtime: runtime} = federated!(owner, host: false)
      socket = socket(PlatformWeb.RuntimeSocket, nil, %{runtime_id: runtime.runtime_id})

      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(socket, "runtime_host:someone-else", %{})

      assert {:ok, _, _} = subscribe_and_join(socket, "runtime_host:#{runtime.runtime_id}", %{})
    end

    test "terminal.data and any other event is refused, and core will not send one", %{
      owner: owner
    } do
      %{runtime: runtime} = federated!(owner, host: false)
      socket = socket(PlatformWeb.RuntimeSocket, nil, %{runtime_id: runtime.runtime_id})
      {:ok, _, socket} = subscribe_and_join(socket, "runtime_host:#{runtime.runtime_id}", %{})

      ref = push(socket, "terminal.data", %{"data" => "ls\n"})
      assert_reply ref, :error, %{reason: "event_not_allowed"}
      ref = push(socket, "file.write", %{"path" => "x"})
      assert_reply ref, :error, %{reason: "event_not_allowed"}

      assert {:error, :event_not_allowed} =
               RuntimeHosts.request(runtime.runtime_id, "terminal.data", %{})

      refute "terminal.data" in RuntimeHosts.ops()
    end

    test "hello is recorded, and an unknown opt-in reads as off", %{owner: owner} do
      %{runtime: runtime} = federated!(owner, host: false)
      socket = socket(PlatformWeb.RuntimeSocket, nil, %{runtime_id: runtime.runtime_id})

      hello = %{
        "harness" => "codex",
        "cli_version" => "1.2.3",
        "capabilities" => ["file"],
        "resumes" => true,
        "config_opt_in" => "everyone"
      }

      {:ok, _, _} = subscribe_and_join(socket, "runtime_host:#{runtime.runtime_id}", hello)

      assert %{
               hello: %{
                 harness: "codex",
                 cli_version: "1.2.3",
                 resumes: true,
                 config_opt_in: :off
               }
             } =
               RuntimeHosts.lookup(runtime.runtime_id)
    end
  end
end
