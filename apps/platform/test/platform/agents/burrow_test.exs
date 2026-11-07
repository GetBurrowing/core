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

  # ── task 01a19aa4 stage 2: the setup guide ─────────────────────────────

  defp templates,
    do: [
      Burrow.identity_template("Burrow", "codex"),
      Burrow.identity_template("Burrow", "claude_code")
    ]

  # The "Helping your owner finish setup" section, up to the next heading.
  defp setup_section(template) do
    [_, rest] = String.split(template, "## Helping your owner finish setup", parts: 2)
    rest |> String.split("\n## ", parts: 2) |> hd()
  end

  # The numbered steps of the setup section, in order.
  defp setup_steps(template) do
    [_intro | steps] = Regex.split(~r/\n\d\. /, setup_section(template))
    [last | earlier] = Enum.reverse(steps)
    Enum.reverse([last |> String.split("\n\n", parts: 2) |> hd() | earlier])
  end

  defp index_of(text, needle) do
    case :binary.match(text, needle) do
      {index, _} -> index
      :nomatch -> flunk("#{inspect(needle)} not found")
    end
  end

  describe "setup guide (identity_template/2)" do
    test "setup guide puts the project step before the space step" do
      for template <- templates() do
        section = setup_section(template)
        assert index_of(section, "project_create") < index_of(section, "first space")
        assert index_of(section, "first project") < index_of(section, "first space")
      end
    end

    test "setup guide orders understand, identity page, project, space, shape Burrow" do
      for template <- templates() do
        assert [understand, memory, project, space, shape] = setup_steps(template)

        assert understand =~ "why they want Burrow"
        assert understand =~ "who they and their org are"
        assert understand =~ "who is involved"
        assert understand =~ "one at a\n   time"
        assert memory =~ "`org/page/identity.md`"
        assert memory =~ "Read it\n   back to them"
        assert project =~ "`project_create`"
        assert space =~ "first space"
        assert shape =~ "how you work for them"
        assert shape =~ "/control/burrow/config"
      end
    end

    test "setup guide says Burrow is the workspace and names no other chat tool to set up" do
      prohibition =
        ~r/Never suggest they need a separate chat or work tool, and never name one \(Slack, Teams, a task tracker\) as something to set up alongside Burrow\./

      for template <- templates() do
        assert template =~ prohibition
        refute template =~ "(email, calendar, files, chat)"
        refute template =~ "Suggest connecting the ones that matter most first"

        # Slack and Teams appear once each, inside the prohibition sentence.
        assert length(Regex.scan(~r/Slack/, template)) == 1
        assert length(Regex.scan(~r/Teams/, template)) == 1
        assert template |> String.replace(prohibition, "") |> String.contains?("Slack") == false

        assert template =~ "Burrow is where their team chats, meets, plans and tracks work"
        assert template =~ "rarely works as\nwell as doing the work in Burrow itself"
      end
    end

    test "setup guide keeps the /tasks New Project fallback" do
      for template <- templates() do
        assert template =~
                 ~s(If `project_create` is not among your tools, send them to\n   the "New Project" button on /tasks and wait for them to finish.)
      end
    end

    test "setup guide hard-codes no family or business menu" do
      for template <- templates() do
        refute template =~ ~r/famil(y|ies)/i
        refute template =~ ~r/\bbusiness(es)?\b/i
        assert setup_section(template) =~ "offer a few example uses, then follow their\n   lead"
      end
    end

    test "setup guide does not offer more agents as a default step" do
      for template <- templates() do
        refute template =~ ~r/more agents/i

        for step <- setup_steps(template),
            do: refute(step =~ ~r/(add|adding|another|more) agents?\b/i, step)

        assert [_] = Regex.scan(~r/another agent/, template)

        assert template =~
                 "Mention adding another agent only when their aims call for it"
      end
    end

    test "setup guide covers members and says Burrow works for everyone" do
      for template <- templates() do
        assert template =~ "the one agent\nfor everyone on it: you work for every member"

        assert template =~
                 "If anyone (owner or member) says they want to start a project, help them create one the same way."
      end
    end
  end

  # ── task 01a19aa4 stage 2: default roles ───────────────────────────────

  describe "ensure/2 default roles" do
    setup do
      for role <- Burrow.default_roles(), do: :ok = Platform.Roles.unassign_role(role)
      :ok
    end

    defp other_agent! do
      n = System.unique_integer([:positive])

      %Platform.Agents.Agent{}
      |> Platform.Agents.Agent.changeset(%{
        slug: "other-#{n}",
        name: "Other #{n}",
        status: "active"
      })
      |> Repo.insert!()
    end

    test "the default roles are historian, the meeting roles, triage and the lead" do
      assert Burrow.default_roles() ==
               ~w(historian meeting_scribe meeting_producer triage_officer agents_leader)
    end

    for role <- ~w(historian meeting_scribe meeting_producer triage_officer agents_leader) do
      test "an unassigned #{role} goes to Burrow" do
        owner = admin!()
        assert {:ok, agent} = Burrow.ensure(owner.id, "codex")
        assert Platform.Roles.agent_id_for_role(unquote(role)) == agent.id
      end

      test "a #{role} held by another agent is untouched" do
        other = other_agent!()
        {:ok, _} = Platform.Roles.assign_role(unquote(role), other.id)
        owner = admin!()

        assert {:ok, agent} = Burrow.ensure(owner.id, "codex")

        assert Platform.Roles.agent_id_for_role(unquote(role)) == other.id

        for held <- Burrow.default_roles() -- [unquote(role)],
            do: assert(Platform.Roles.agent_id_for_role(held) == agent.id)
      end
    end

    test "re-running ensure/2 changes no assignment and raises nothing" do
      owner = admin!()
      assert {:ok, agent} = Burrow.ensure(owner.id, "claude_code")
      before = Repo.all(from(ra in Platform.Roles.RoleAssignment, order_by: ra.role_key))

      assert {:ok, ^agent} = Burrow.ensure(owner.id, "claude_code")
      assert {:ok, again} = Burrow.ensure(owner.id, "codex")
      assert again.id == agent.id

      assert Repo.all(from(ra in Platform.Roles.RoleAssignment, order_by: ra.role_key)) == before

      for role <- Burrow.default_roles(),
          do: assert(Platform.Roles.agent_id_for_role(role) == agent.id)
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
