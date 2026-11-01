defmodule Platform.Agents.BurrowTest do
  @moduledoc "The install's Burrow native agent, task 01a17b10 stage 2."
  use Platform.DataCase, async: false

  import Ecto.Query

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

    test "with a federated agent already present Burrow gets the defaults" do
      owner = admin!()

      {:ok, _fed, _rt, _tok} =
        Platform.Federation.provision_agent_runtime(
          owner.id,
          %{slug: "fed-#{System.unique_integer([:positive])}", name: "Fed", status: "active"},
          %{runtime_id: "fed-rt-#{System.unique_integer([:positive])}"}
        )

      {:ok, agent} = Burrow.ensure(owner.id, "codex")
      rt = Repo.get!(AgentRuntime, agent.runtime_id)

      refute Map.has_key?(rt.metadata, "first_agent_grant")
      assert Enum.sort(profile(agent)) == Enum.sort(AgentRuntime.default_tool_profile())
    end

    test "does not change the login mode: a fresh Burrow gets the API-key path" do
      owner = admin!()
      {:ok, _agent} = Burrow.ensure(owner.id, "claude_code")

      assert NativeLogin.login_mode() == :api_key
      refute NativeLogin.step(%{state: :needs_login}, false) == :needs_operator

      assert NativeLogin.step(%{state: :needs_login}, false) ==
               NativeLogin.step(%{state: :needs_login}, false, :api_key)
    end

    test "seeds a Burrow CLAUDE.md naming the role and bundles" do
      owner = admin!()
      {:ok, agent} = Burrow.ensure(owner.id, "claude_code")
      claude = file_content(agent, "CLAUDE.md")

      assert claude =~ "orchestrator and infra desk"

      for b <- ~w(task plan messaging space memory context_read admin) do
        assert claude =~ "`#{b}`"
      end
    end

    test "start_files appends the admins section to a Codex Burrow's AGENTS.md" do
      owner = admin!()
      {:ok, agent} = Burrow.ensure(owner.id, "codex")
      content = file_content(agent, "AGENTS.md")

      assert content =~ "## Owner and admins (generated at start)"
      assert content =~ owner.id
    end
  end

  describe "channels started from a first goal (task 01a19948 stage 3)" do
    # Pins that the instruction EXISTS and names the real signals and tool.
    # Burrow is an LLM, so nothing here asserts the wording it produces.
    for harness <- ~w(codex claude_code) do
      test "the #{harness} instructions carry the first-goal naming section" do
        text = Burrow.identity_template("Burrow", unquote(harness))

        assert text =~ "## Channels started from a first goal"
        assert text =~ ~s(origin: "first_run_goal")
        assert text =~ "`space_rename`"
        assert text =~ "If they ignore the suggestion, do not ask again."
        assert text =~ "Never rename a channel nobody agreed to rename."
      end
    end

    test "a Burrow's written instructions file carries the section" do
      owner = admin!()
      {:ok, agent} = Burrow.ensure(owner.id, "claude_code")

      assert file_content(agent, "CLAUDE.md") =~ "## Channels started from a first goal"
    end
  end

  describe "no agent before the owner configures one" do
    test "a first OIDC login with AGENT_HOST_TOKEN set creates no agent" do
      assert Platform.AgentHost.configured?()
      n = System.unique_integer([:positive])

      {:ok, user} =
        Platform.Accounts.find_or_create_from_oidc(%{
          sub: "oidc-burrow-first-login-#{n}",
          email: "first-login-#{n}@example.com",
          name: "First Login #{n}"
        })

      # Positive control: this login made the install's owner, the condition
      # under which the old login hook created a Burrow.
      assert Platform.Tenancy.root_admin?(user)
      assert Platform.Accounts.install_owner().id == user.id

      # Anything the login started under the task supervisor has finished.
      assert :ok = Platform.SandboxHelpers.await_supervised_writes()

      assert NativeAgents.list() == []

      external =
        Repo.aggregate(
          from(a in Platform.Agents.Agent,
            where: a.runtime_type == "external" and a.status != "archived"
          ),
          :count
        )

      assert external == 0
    end

    test "the application starts no Burrow boot child" do
      ids = for {id, _pid, _type, _mods} <- Supervisor.which_children(Platform.Supervisor), do: id
      refute :burrow_seed in ids

      # The boot child is off in test config whatever the code says, so also
      # pin that the application no longer wires one.
      src = File.read!("lib/platform/application.ex")
      refute src =~ "burrow_seed"
      refute src =~ ~r/Agents\.Burrow\.run_at/
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
      {:ok, agent} = Burrow.ensure(owner.id, "claude_code")

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
    from(m in OrgMembership, where: m.user_id == ^user_id)
  end
end
