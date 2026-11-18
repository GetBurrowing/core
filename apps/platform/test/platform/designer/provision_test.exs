defmodule Platform.Designer.ProvisionTest do
  @moduledoc """
  `Platform.Designer.provision/1` (UX super agent phase 1): idempotent, ids at
  run time, the escalation user on the friction-watch row, spaces joined, one
  keep-rate goal, and an honest runtime report.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Access.RuntimeProfile
  alias Platform.Access.RuntimeProfiles
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Designer
  alias Platform.Experiments.Goal
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities
  alias Platform.Roles.RoleAssignment
  alias Platform.Tenancy

  setup do
    user = World.create_user!()
    World.plain_member!(user, Tenancy.get_org_by_slug!("globex"))

    agent = agent!("designer")
    watch = space!("product")
    digest = space!("ux digest")

    attrs = %{
      agent_id: agent.id,
      escalate_user_id: user.id,
      watch_space_ids: [watch.id],
      digest_space_id: digest.id
    }

    %{agent: agent, user: user, watch: watch, digest: digest, attrs: attrs}
  end

  defp agent!(slug) do
    %Agent{}
    |> Agent.changeset(%{
      slug: "#{slug}-#{System.unique_integer([:positive])}",
      name: "UX",
      status: "active",
      kind: "native",
      workspace_id: nil
    })
    |> Repo.insert!()
  end

  defp space!(name) do
    {:ok, space} =
      Chat.create_space(%{
        name: name,
        slug: "s-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp runtime!(agent, owner, modules) do
    runtime =
      Repo.insert!(%AgentRuntime{
        runtime_id: "designer-#{System.unique_integer([:positive])}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        status: "active"
      })

    Repo.insert!(%RuntimeProfile{
      runtime_id: runtime.id,
      tool_profile: modules,
      restricted_permissions: RuntimeProfiles.translated_permissions(modules)
    })

    agent |> Ecto.Changeset.change(runtime_id: runtime.id) |> Repo.update!()
  end

  defp keep_rate_goals do
    Repo.all(
      from(g in Goal,
        where: fragment("?->>'slug' = ?", g.metric_spec, ^Designer.goal_metric())
      )
    )
  end

  test "provisioning twice: one assignment, one goal, spaces joined, escalation user stored",
       %{agent: agent, user: user, watch: watch, digest: digest, attrs: attrs} do
    assert {:ok, first} = Designer.provision(attrs)
    assert first.role == :assigned
    assert {:created, goal_id} = first.goal

    # An operator moves the watch cadence between runs; it must survive.
    row = Responsibilities.get_by_key("ux.friction_watch")

    {:ok, _} =
      Responsibilities.update_responsibility(row, %{
        trigger_config: Map.put(row.trigger_config, "expression", "0 9 * * 2")
      })

    assert {:ok, second} = Designer.provision(attrs)
    assert second.role == :unchanged
    assert second.goal == {:exists, goal_id}

    assert Repo.aggregate(from(a in RoleAssignment, where: a.role_key == "designer"), :count) ==
             1

    assert [%Goal{status: "active"}] = keep_rate_goals()

    row = Responsibilities.get_by_key("ux.friction_watch")
    assert row.trigger_config["escalate_user_id"] == user.id
    assert row.trigger_config["operator_set"] == true
    assert row.trigger_config["expression"] == "0 9 * * 2"
    assert Designer.escalate_user_id() == user.id

    assert Chat.get_agent_participant(watch.id, agent.id)
    assert Chat.get_agent_participant(digest.id, agent.id)
    assert Repo.get!(Agent, agent.id).metadata["ux_digest_space_id"] == digest.id
  end

  test "phase 1's keep-rate goal is retargeted to friction drop in place, keeping its id",
       %{attrs: attrs} do
    {:ok, phase1} =
      %Goal{}
      |> Goal.changeset(%{
        "statement" => Designer.keep_rate_statement(),
        "metric_spec" => %{"kind" => "registered", "slug" => Designer.keep_rate_metric()},
        "status" => "active"
      })
      |> Repo.insert()

    assert {:ok, %{goal: {:retargeted, id}}} = Designer.provision(attrs)
    assert id == phase1.id
    goal = Repo.get!(Goal, id)
    assert goal.metric_spec["slug"] == "ux_friction_drop"
    assert goal.statement =~ "ux_finding_keep_rate"

    assert {:ok, %{goal: {:exists, ^id}}} = Designer.provision(attrs)
  end

  test "seeds the pattern cards into the home space, once", %{
    agent: agent,
    attrs: attrs,
    digest: digest
  } do
    assert {:ok, %{cards: %{written: n, kept: 0}}} = Designer.provision(attrs)
    assert n >= 20

    agent = Repo.get!(Agent, agent.id)
    assert agent.metadata[Platform.Designer.Cards.home_key()] == digest.id

    assert {:ok, %{cards: %{written: 0, kept: ^n}}} = Designer.provision(attrs)

    assert {:ok, %{cards: :skipped}} = Designer.provision(Map.put(attrs, :seed_cards, false))
  end

  test "a role held by another agent is refused unless reassign: true", %{attrs: attrs} do
    other = agent!("other")
    {:ok, _} = Platform.Roles.assign_role("designer", other.id)

    assert {:error, {:role_held_by, held}} = Designer.provision(attrs)
    assert held == other.id

    assert {:ok, %{role: :reassigned}} = Designer.provision(Map.put(attrs, :reassign, true))
  end

  test "missing or unknown ids write nothing", %{attrs: attrs} do
    assert {:error, {:missing, :escalate_user_id}} =
             Designer.provision(Map.delete(attrs, :escalate_user_id))

    assert {:error, {:not_found, :watch_space_ids, _}} =
             Designer.provision(%{attrs | watch_space_ids: [Ecto.UUID.generate()]})

    assert {:error, {:not_found, :agent_id}} =
             Designer.provision(%{attrs | agent_id: Ecto.UUID.generate()})

    assert Platform.Roles.agent_id_for_role("designer") == nil
    assert keep_rate_goals() == []
  end

  test "set_goal: false creates no goal", %{attrs: attrs} do
    assert {:ok, %{goal: :skipped}} = Designer.provision(Map.put(attrs, :set_goal, false))
    assert keep_rate_goals() == []
  end

  test "runtime report: no runtime, missing tools, and the critique gap are all warned",
       %{agent: agent, user: user, attrs: attrs} do
    assert {:ok, report} = Designer.provision(attrs)
    assert report.runtime == %{kind: :no_runtime}
    assert Enum.any?(report.warnings, &(&1 =~ "no runtime"))
    refute Enum.any?(report.warnings, &(&1 =~ "design.critique"))

    runtime!(agent, user, ["context_read"])

    assert {:ok, report} = Designer.provision(Map.put(attrs, :apply_grants, false))
    assert report.runtime.kind == :federated
    assert "prototype_publish" in report.runtime.missing_tools
    assert "prototypes.publish" in report.runtime.grants_needed.permissions
    assert "prototype" in report.runtime.grants_needed.bundles
    assert Enum.any?(report.warnings, &(&1 =~ "missing designer tools"))
    assert Enum.any?(report.warnings, &(&1 =~ "prototypes.publish"))
  end

  test "provision adds the bundles and restrict-grants a native runtime needs, once",
       %{agent: agent, attrs: attrs} do
    owner = Platform.TenancyFixtures.root_admin!()
    runtime = runtime!(agent, owner, ["context_read", "canvas"]) |> Map.fetch!(:runtime_id)
    runtime = Repo.get!(AgentRuntime, runtime)

    # The hand-fixed state on a live agent: bundles on, restriction stale.
    {:ok, _} = RuntimeProfiles.set_tool_profile(runtime, ["context_read", "canvas", "prototype"])
    refute Map.has_key?(RuntimeProfiles.restrictions(runtime), "prototypes.publish")

    assert {:ok, report} = Designer.provision(attrs)
    assert "prototypes.publish" in report.runtime.granted.permissions
    assert "memory" in report.runtime.granted.bundles
    assert report.runtime.missing_tools == [], inspect(report.runtime)
    assert report.warnings == []

    restriction = RuntimeProfiles.restrictions(runtime)
    assert restriction["prototypes.publish"] == "all"
    refute Map.has_key?(restriction, "prompts.manage")

    assert {:ok, again} = Designer.provision(attrs)
    assert again.runtime.grants_needed == %{bundles: [], permissions: []}
    refute Map.has_key?(again.runtime, :granted)
  end

  test "an external agent is warned that it cannot be the lead", %{attrs: attrs} do
    external =
      %Agent{}
      |> Agent.changeset(%{
        slug: "ext-#{System.unique_integer([:positive])}",
        name: "Ext",
        status: "active",
        kind: "external",
        endpoint_kind: "openai_compat",
        base_url: "http://127.0.0.1:1/v1",
        model: "m"
      })
      |> Repo.insert!()

    assert {:ok, report} = Designer.provision(%{attrs | agent_id: external.id})
    assert report.runtime == %{kind: :external}
    assert [warning] = report.warnings
    assert warning =~ "cannot write"
  end

  describe "agent-side templates" do
    test "ship the manifest and the four subagents, with the guardrails" do
      files = Map.new(Designer.template_files())

      assert Map.keys(files) |> Enum.sort() ==
               Enum.sort(~w(
                 CLAUDE.md .claude/settings.json .claude/agents/scout.md
                 .claude/agents/critic.md .claude/agents/prototyper.md
                 .claude/agents/evaluator.md
               ))

      manifest = files["CLAUDE.md"]
      assert manifest =~ "At most **3 subagents at once**"
      assert manifest =~ "Raw web content stops at the `scout`"
      assert manifest =~ "never edit your own prompts"
      assert manifest =~ "Reflect at the end of every job"
      assert manifest =~ "before any long step"

      assert files[".claude/agents/scout.md"] =~ "tools: WebSearch, WebFetch,"
      refute files[".claude/agents/critic.md"] =~ ~r/tools:.*(Write|Edit|_create|_patch)/
      assert files[".claude/agents/prototyper.md"] =~ "prototype_publish"
      assert files[".claude/agents/evaluator.md"] =~ "OpenAI model"

      for {path, _content} <- files do
        assert Platform.Agents.NativeAgents.valid_file_key?(path), path
      end
    end

    test "install_files writes them create-only for a native agent, and refuses a stranger" do
      owner = Platform.TenancyFixtures.root_admin!()

      {:ok, agent, _runtime} =
        Platform.Agents.NativeAgents.create(owner.id, %{name: "UX", harness: "claude_code"})

      assert {:ok, first} = Designer.install_files(owner, agent.id)
      assert Enum.all?(first, fn {_path, result} -> result == :written end), inspect(first)

      claude_md = Platform.Agents.MemoryContext.get_workspace_file(agent.id, "CLAUDE.md").content
      # The identity file the agent was created with is kept; the manifest follows it.
      assert claude_md =~ "You are UX, an agent on this Burrow install"
      assert claude_md =~ "Reflect at the end of every job"

      assert {:ok, second} = Designer.install_files(owner, agent.id)
      assert Enum.all?(second, fn {_path, result} -> result == :kept end), inspect(second)

      stranger = World.create_user!()
      assert {:error, :forbidden} = Designer.install_files(stranger, agent.id)
    end

    test "subagent tool lists use the burrow MCP prefix a native agent's .mcp.json names" do
      files = Map.new(Designer.template_files())
      assert files[".claude/agents/critic.md"] =~ "mcp__burrow__canvas_get"
      assert files[".claude/agents/scout.md"] =~ "mcp__burrow__memory_create"

      for {_path, content} <- files, do: refute(content =~ "mcp__startup-suite__")
    end

    test "rename the MCP server in subagent tool lists" do
      files = Map.new(Designer.template_files(mcp_server: "suite"))
      assert files[".claude/agents/critic.md"] =~ "mcp__suite__canvas_get"
      refute files[".claude/agents/critic.md"] =~ "mcp__burrow__"
    end
  end

  describe "reflection instruction" do
    test "ends the design.task_direction.v1 default, once" do
      content = PromptTemplates.default_content_for_slug("design.task_direction.v1")
      assert String.ends_with?(content, Designer.reflection_instruction())
      assert length(String.split(content, Designer.reflection_marker())) == 2
      # The decline exit is still there above it.
      assert content =~ "task_design_decline"
    end
  end
end
