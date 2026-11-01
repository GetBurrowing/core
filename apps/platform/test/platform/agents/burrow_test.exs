defmodule Platform.Agents.BurrowTest do
  @moduledoc "The install's Burrow native agent, task 01a17b10 stage 2."
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Accounts.User
  alias Platform.Agents.{AgentRuntime, Burrow, NativeAgents, NativeLogin}
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  setup do
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, "test-host-token")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)
  end

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "burrow-#{label}-#{n}@example.com",
      name: "Burrow #{label} #{n}",
      oidc_sub: "oidc-burrow-#{label}-#{n}"
    })
  end

  defp admin! do
    user = user!("admin")

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  defp burrow_count do
    Enum.count(NativeAgents.list(), fn %{agent: a} -> a.slug == "burrow" end)
  end

  defp profile(agent) do
    Platform.Access.RuntimeProfiles.tool_profile(Repo.get!(AgentRuntime, agent.runtime_id))
  end

  describe "ensure/1" do
    test "is a logged no-op without AGENT_HOST_TOKEN" do
      admin!()
      Application.delete_env(:platform, :agent_host_token)

      log =
        capture_log(fn -> assert {:ok, :skipped, :no_agent_host_token} = Burrow.ensure() end)

      assert log =~ "no AGENT_HOST_TOKEN"
      assert burrow_count() == 0
    end

    test "is a no-op without an owner" do
      assert {:ok, :skipped, :no_owner} = Burrow.ensure()
      assert burrow_count() == 0
    end

    test "is idempotent" do
      admin!()
      assert {:ok, :created, a} = Burrow.ensure()
      assert {:ok, :exists, b} = Burrow.ensure()
      assert a.id == b.id
      assert burrow_count() == 1
    end

    test "on an empty install Burrow takes the first-agent grant" do
      admin!()
      {:ok, :created, agent} = Burrow.ensure()
      rt = Repo.get!(AgentRuntime, agent.runtime_id)

      assert rt.metadata["first_agent_grant"] == true
      assert Enum.sort(profile(agent)) == Enum.sort(Platform.Federation.first_agent_bundles())
    end

    test "with a federated agent already present Burrow gets the defaults" do
      owner = admin!()

      {:ok, _fed, _rt, _tok} =
        Platform.Federation.provision_agent_runtime(
          owner.id,
          %{slug: "fed-#{System.unique_integer([:positive])}", name: "Fed", status: "active"},
          %{runtime_id: "fed-rt-#{System.unique_integer([:positive])}"}
        )

      {:ok, :created, agent} = Burrow.ensure()
      rt = Repo.get!(AgentRuntime, agent.runtime_id)

      refute Map.has_key?(rt.metadata, "first_agent_grant")
      assert Enum.sort(profile(agent)) == Enum.sort(AgentRuntime.default_tool_profile())
    end

    test "does not change the login mode: a fresh Burrow gets the API-key path" do
      admin!()
      {:ok, :created, _agent} = Burrow.ensure()

      assert NativeLogin.login_mode() == :api_key
      refute NativeLogin.step(%{state: :needs_login}, false) == :needs_operator

      assert NativeLogin.step(%{state: :needs_login}, false) ==
               NativeLogin.step(%{state: :needs_login}, false, :api_key)
    end

    test "seeds a Burrow CLAUDE.md naming the role and bundles" do
      admin!()
      {:ok, :created, agent} = Burrow.ensure()
      claude = Enum.find(NativeAgents.start_files(agent), &(&1["key"] == "CLAUDE.md"))

      assert claude["content"] =~ "orchestrator and infra desk"

      for b <- ~w(task plan messaging space memory context_read admin) do
        assert claude["content"] =~ "`#{b}`"
      end
    end
  end

  defp native_entries, do: NativeAgents.list()

  defp file_content(agent, key) do
    NativeAgents.start_files(agent)
    |> Enum.find(&(&1["key"] == key))
    |> Map.fetch!("content")
  end

  describe "ensure/2" do
    test "ensure/2 with codex creates one agent named Burrow running codex" do
      owner = admin!()
      assert {:ok, agent} = Burrow.ensure(owner.id, "codex")

      assert [%{agent: a, runtime: rt}] = native_entries()
      assert a.id == agent.id
      assert a.name == "Burrow"
      assert a.slug == "burrow"
      assert rt.harness == "codex"
    end

    test "ensure/2 with claude_code creates one agent named Burrow running claude_code" do
      owner = admin!()
      assert {:ok, agent} = Burrow.ensure(owner.id, "claude_code")

      assert [%{agent: a, runtime: rt}] = native_entries()
      assert a.id == agent.id
      assert a.name == "Burrow"
      assert a.slug == "burrow"
      assert rt.harness == "claude_code"
    end

    test "ensure/2 on an empty install gives Burrow the first-agent grant whatever the harness" do
      owner = admin!()
      assert {:ok, agent} = Burrow.ensure(owner.id, "codex")
      rt = Repo.get!(AgentRuntime, agent.runtime_id)

      assert rt.metadata["first_agent_grant"] == true
      assert Enum.sort(profile(agent)) == Enum.sort(Platform.Federation.first_agent_bundles())
    end

    test "ensure/2 is idempotent and switches the harness of a not-running Burrow" do
      owner = admin!()
      assert {:ok, first} = Burrow.ensure(owner.id, "claude_code")
      refute Burrow.running?(first)
      assert {:ok, second} = Burrow.ensure(owner.id, "codex")

      assert first.id == second.id
      assert [%{agent: a, runtime: rt}] = native_entries()
      assert a.id == first.id
      assert rt.harness == "codex"
      assert Burrow.harness(second) == "codex"
    end

    test "a Codex Burrow's AGENTS.md carries the role and the setup guide" do
      owner = admin!()
      {:ok, agent} = Burrow.ensure(owner.id, "codex")
      content = file_content(agent, "AGENTS.md")

      assert content =~ "## Your role"
      assert content =~ "## Helping your owner finish setup"
    end

    test "a Claude Burrow's CLAUDE.md carries the role and the setup guide" do
      owner = admin!()
      {:ok, agent} = Burrow.ensure(owner.id, "claude_code")
      content = file_content(agent, "CLAUDE.md")

      assert content =~ "## Your role"
      assert content =~ "## Helping your owner finish setup"
    end

    test "start_files appends the admins section to a Codex Burrow's AGENTS.md" do
      owner = admin!()
      {:ok, agent} = Burrow.ensure(owner.id, "codex")
      content = file_content(agent, "AGENTS.md")

      assert content =~ "## Owner and admins (generated at start)"
      assert content =~ owner.id
    end
  end

  describe "boot hook" do
    test "an install that already has users plus the token gets Burrow at boot, once" do
      admin!()
      _later_admin = admin!()
      assert burrow_count() == 0

      assert :ok = Burrow.run_at_boot()
      assert burrow_count() == 1
      assert :ok = Burrow.run_at_boot()
      assert burrow_count() == 1
    end

    test "boot without the token or without an admin creates nothing" do
      assert :ok = Burrow.run_at_boot()
      assert burrow_count() == 0

      admin!()
      Application.delete_env(:platform, :agent_host_token)
      capture_log(fn -> assert :ok = Burrow.run_at_boot() end)
      assert burrow_count() == 0
    end

    test "the boot child is wired and off in test config" do
      src = File.read!("lib/platform/application.ex")
      assert src =~ "|> maybe_add_burrow_seed(flag)"
      assert src =~ "id: :burrow_seed"
      assert Application.get_env(:platform, :start_burrow_seed) == false
    end
  end

  describe "install_owner/0" do
    test "is the earliest non-archived root admin" do
      first = admin!()
      second = admin!()
      assert Platform.Accounts.install_owner().id == first.id

      first |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()
      assert Platform.Accounts.install_owner().id == second.id
      refute Enum.any?(Platform.Accounts.install_admins(), &(&1.id == first.id))
    end
  end

  describe "owner and admins in context" do
    test "start_files carries each principal id; a removed admin is gone at restart" do
      owner = admin!()
      a1 = admin!()
      a2 = admin!()
      {:ok, :created, agent} = Burrow.ensure()

      content = fn ->
        NativeAgents.start_files(agent)
        |> Enum.find(&(&1["key"] == "CLAUDE.md"))
        |> Map.fetch!("content")
      end

      for u <- [owner, a1, a2], do: assert(content.() =~ u.id)

      Repo.delete_all(from_membership(a2.id))

      refute content.() =~ a2.id
      assert content.() =~ a1.id
    end

    test "other native agents get no admins section" do
      owner = admin!()
      {:ok, agent, _} = NativeAgents.create(owner.id, %{name: "Other", harness: "claude_code"})
      files = NativeAgents.start_files(agent)
      refute Enum.any?(files, &(&1["content"] =~ "Owner and admins"))
    end
  end

  defp from_membership(user_id) do
    import Ecto.Query
    from(m in OrgMembership, where: m.user_id == ^user_id)
  end
end
