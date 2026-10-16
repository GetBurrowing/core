defmodule Platform.Access.ContextRecheckTest do
  @moduledoc """
  Context-level permission re-checks (task 01a1386d-fb6e stage 2, RBAC stack
  member 4; `0058-rbac-v2-roles-scopes-and-agent-capping.md § Root-admin carve-outs`).
  A route gate is not an authorization boundary, so each
  install-level context, every human Experiments write, the prompt template
  writes and the pipeline-health read re-check through `Platform.Access`.

  Every refusal is preceded by its POSITIVE CONTROL on a fresh fixture: the
  root admin makes the same call and is permitted. A refusal with no control
  could be a broken fixture.

  The actor classes:

    * `root_admin` — internal `admin` of the root org (the one permitted class);
    * `sub_org_admin` — internal `admin` of a child org;
    * `root_member` — internal `member` of the root org;
    * `external_root_admin` — `admin` of the root org with `external: true`.
      `Tenancy.root_admin?/1` ignores `external` and says yes; guest dominance
      says no. This is the one class the change makes STRICTER;
    * `grantee` — a child-org member holding member 3's ALLOW grants of the
      module-admin permissions `tasks.manage` and `prompts.manage` on one
      project.

  ## The Tasks part is not here

  Stage 2's plan bounds the Tasks write re-checks at 25 entry points and says
  to stop that part above it. The measured list from `TasksLive` and
  `live/tasks/` is 37 entry points (14 `Platform.Tasks` functions plus 23 in
  Stacks, ReviewRequests, Skills, LifecycleActions, MergeControl,
  PlanRejection, Chat, ChatPins, CanvasAttachments, AttachmentStorage and
  Inbox), so `:tasks` stays `guest_admissible: false`. The last describe
  block pins that.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Grants, Registry, Scope}
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Branding
  alias Platform.Experiments
  alias Platform.Experiments.{Experiment, Guardrail, Guardrails, Promotion, TestSurfaces}
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.{PromptTemplate, PromptTemplates}
  alias Platform.Prototypes.Settings, as: PrototypeSettings
  alias Platform.SignInAdmin
  alias Platform.Tasks
  alias Platform.Tasks.PipelineHealth
  alias Platform.Tenancy
  alias Platform.Tenancy.{Lifecycle, OrgMembership}
  alias Platform.Vault.Shared

  @budget "test.budget"
  @refused [:sub_org_admin, :root_member, :external_root_admin, :grantee]
  @sign_in_env [:sign_in_admin_enabled, :sign_in_admin_url, :sign_in_admin_api_key]

  setup do
    TestSurfaces.register()
    root = acme_org_id()
    child = tenant_org_id("ctx-recheck")
    project = project!(child)

    grantee = member!(child)
    {:ok, _} = Grants.grant(%{principal: grantee, permission: "tasks.manage", resource: project})

    {:ok, _} =
      Grants.grant(%{principal: grantee, permission: "prompts.manage", resource: project})

    actors = %{
      root_admin: root_admin!(),
      sub_org_admin: membership!(user!("sub-admin"), child, "admin"),
      root_member: membership!(user!("root-member"), root, "member"),
      external_root_admin: external_root_admin!(root),
      grantee: grantee
    }

    %{actors: actors, child: child, project: project}
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "ctx-#{tag}-#{n}@example.com",
      name: "Ctx #{tag} #{n}",
      oidc_sub: "ctx-#{tag}-#{n}"
    })
  end

  defp membership!(user, org_id, role, external \\ false) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: role,
      external: external
    })
    |> Repo.insert!()

    user
  end

  defp member!(org_id), do: membership!(user!("grantee"), org_id, "member")

  defp external_root_admin!(root),
    do: membership!(user!("ext-root-admin"), root, "admin", true)

  defp project!(org_id) do
    {:ok, p} =
      Tasks.create_project(%{name: "ctx-#{System.unique_integer([:positive])}", org_id: org_id})

    p
  end

  defp draft!(attrs \\ %{}) do
    {:ok, experiment} =
      Experiments.create_experiment(
        Map.merge(
          %{
            slug: "ctx-#{System.unique_integer([:positive])}",
            name: "Context re-check",
            surface_key: @budget,
            surface_target: "t-#{System.unique_integer([:positive])}"
          },
          attrs
        )
      )

    experiment
  end

  # Each in its own org: `max_live` is counted per org, and the refused calls
  # below leave their experiments running.
  defp running! do
    {:ok, %Experiment{status: "running"} = running} =
      Experiments.start(draft!(%{org_id: tenant_org_id(slug())}), root_admin!())

    running
  end

  # A plain prompt experiment, for `activate/3` (the stage-1 shape).
  defp prompt_draft! do
    {:ok, experiment} = Experiments.create_experiment(%{slug: slug(), name: "Prompt"})
    experiment
  end

  defp template! do
    %PromptTemplate{}
    |> PromptTemplate.changeset(%{
      slug: "ctx.recheck.v#{System.unique_integer([:positive])}",
      name: "Context re-check",
      content: "ORIGINAL"
    })
    |> Repo.insert!()
  end

  defp runtime!(owner, bundles) do
    n = System.unique_integer([:positive])

    agent =
      %Agent{}
      |> Agent.changeset(%{slug: "ctx-agent-#{n}", name: "Ctx agent #{n}", status: "active"})
      |> Repo.insert!()

    %AgentRuntime{}
    |> AgentRuntime.changeset(%{
      runtime_id: "ctx-rt-#{n}",
      owner_user_id: owner.id,
      agent_id: agent.id,
      auth_token_hash: AgentRuntime.hash_token(AgentRuntime.generate_token()),
      status: "active",
      allowed_bundles: bundles
    })
    |> Repo.insert!()
  end

  defp enable_sign_in_admin! do
    saved = for key <- @sign_in_env, do: {key, Application.fetch_env(:platform, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    Application.put_env(:platform, :sign_in_admin_url, "http://pocket-id.test")
    Application.put_env(:platform, :sign_in_admin_api_key, "ctx-recheck-key")
    Application.put_env(:platform, :sign_in_admin_enabled, true)
  end

  # ── Access.authorize/3 and friends ──────────────────────────────────────

  describe "Access.authorize_install/1" do
    test "permits the root admin and refuses every other class", %{actors: actors} do
      assert Access.authorize_install(actors.root_admin) == :ok

      for class <- @refused do
        assert Access.authorize_install(actors[class]) == {:error, :unauthorized},
               "#{class} must be refused install-level"
      end
    end

    test "the external root admin is the one class Tenancy.root_admin?/1 admits", %{
      actors: actors
    } do
      # Positive control for the strictness claim: the old check says yes.
      assert Tenancy.root_admin?(actors.external_root_admin)
      assert Access.authorize_install(actors.external_root_admin) == {:error, :unauthorized}

      for class <- @refused -- [:external_root_admin] do
        refute Tenancy.root_admin?(actors[class]), "#{class} was never a root admin"
      end
    end

    test "re-reads memberships: a root admin demoted after load is refused", %{
      actors: actors
    } do
      admin = Repo.preload(actors.root_admin, org_memberships: :org)
      assert Access.authorize_install(admin) == :ok

      Repo.update_all(
        from(m in OrgMembership, where: m.user_id == ^admin.id),
        set: [role: "member"]
      )

      # The struct still carries the admin membership; the check must not trust it.
      assert [%OrgMembership{role: "admin"}] = admin.org_memberships
      assert Access.authorize_install(admin) == {:error, :unauthorized}
    end

    test "nil, a bare id and the system atom fail closed; Scope.system/0 is permitted" do
      assert Access.authorize_install(nil) == {:error, :unauthorized}
      assert Access.authorize_install(Ecto.UUID.generate()) == {:error, :unauthorized}
      assert Access.authorize_install(:system) == {:error, :unauthorized}
      assert Access.authorize_install(Scope.system()) == :ok
    end

    test "install.admin is the registry's install-level permission" do
      assert Access.install_permission() in Registry.install_level_permissions()
    end
  end

  describe "Access.Grants refuses an install-level grant" do
    test "a grant naming install.admin is refused and writes no row", %{
      actors: actors,
      project: project
    } do
      # Positive control: the same shape with a grantable permission inserts.
      assert {:ok, _} =
               Grants.grant(%{
                 principal: actors.sub_org_admin,
                 permission: "tasks.read",
                 resource: project
               })

      before = Repo.aggregate(Platform.Access.Grant, :count)

      assert {:error, %Ecto.Changeset{} = cs} =
               Grants.grant(%{
                 principal: actors.sub_org_admin,
                 permission: "install.admin",
                 resource: project
               })

      assert {"is install-level and cannot be granted", _} = cs.errors[:permission]
      assert Repo.aggregate(Platform.Access.Grant, :count) == before
      assert Access.authorize_install(actors.sub_org_admin) == {:error, :unauthorized}
    end
  end

  describe "Access.authorize_everywhere/2 (install-wide data)" do
    test "a one-project grant of tasks.manage opens the module but not install-wide data", %{
      actors: actors
    } do
      # Positive control: the grant is live and is read as "held somewhere".
      grantee = Scope.for_user(Repo.reload!(actors.grantee))
      assert Access.holds_anywhere?(grantee, "tasks.manage")
      assert Access.authorize(grantee, "tasks.manage") == :ok

      assert Access.authorize_everywhere(grantee, "tasks.manage") == {:error, :unauthorized}
      assert Access.authorize_everywhere(actors.root_admin, "tasks.manage") == :ok
    end
  end

  # ── install-level contexts ──────────────────────────────────────────────

  # {label, call, permitted?} — `call` gets a fresh fixture each time.
  defp install_level_calls(ctx) do
    [
      {"Branding.update_identity/2",
       fn actor -> Branding.update_identity(actor, %{app_name: "Ctx Recheck"}) end,
       &match?({:ok, _}, &1)},
      {"Branding.reset_colors/1", fn actor -> Branding.reset_colors(actor) end,
       &match?({:ok, _}, &1)},
      {"Prototypes.Settings.update/2",
       fn actor -> PrototypeSettings.update(actor, %{max_files: 77}) end,
       &match?({:ok, %PrototypeSettings{max_files: 77}}, &1)},
      {"Vault.Shared.list/1", fn actor -> Shared.list(actor) end, &match?({:ok, _}, &1)},
      {"Lifecycle.archive_project/2",
       fn actor -> Lifecycle.archive_project(actor, project!(ctx.child)) end,
       &match?({:ok, _}, &1)},
      {"Lifecycle.archive_org/2",
       fn actor ->
         Lifecycle.archive_org(actor, Tenancy.get_org!(tenant_org_id(slug())))
       end, &match?({:ok, _}, &1)},
      {"Lifecycle.create_org/2",
       fn actor ->
         s = slug()
         Lifecycle.create_org(actor, %{name: s, slug: s})
       end, &match?({:ok, _}, &1)},
      {
        "SignInAdmin.disable/2",
        fn actor ->
          enable_sign_in_admin!()
          SignInAdmin.disable(actor, actor.id)
        end,
        # The root admin passes authorization and is stopped by the next
        # guard (`not_self`), before any pocket-id call.
        &(&1 == {:error, :self})
      }
    ]
  end

  defp slug, do: "ctx-org-#{System.unique_integer([:positive])}"

  describe "install-level contexts re-check through Access.authorize_install/1" do
    test "the root admin is permitted and every other class is refused",
         %{actors: actors} = ctx do
      for {label, call, permitted?} <- install_level_calls(ctx) do
        result = call.(actors.root_admin)
        assert permitted?.(result), "#{label}: root admin got #{inspect(result)}"

        for class <- @refused do
          assert call.(actors[class]) == {:error, :unauthorized},
                 "#{label}: #{class} must be refused"
        end
      end
    end

    test "a refused install-level write changes nothing", %{actors: actors} do
      before = PrototypeSettings.get()

      for class <- @refused do
        assert {:error, :unauthorized} =
                 PrototypeSettings.update(actors[class], %{max_files: before.max_files + 1})
      end

      assert PrototypeSettings.get().max_files == before.max_files
    end
  end

  # ── experiments ─────────────────────────────────────────────────────────

  describe "Experiments: every human write is install-level" do
    test "a non-root user's start is refused and the experiment stays draft", %{actors: actors} do
      for class <- @refused do
        experiment = draft!()
        assert Experiments.start(experiment, actors[class]) == {:error, :unauthorized}
        assert Repo.get!(Experiment, experiment.id).status == "draft"
      end

      # Positive control: the same call by the root admin starts it.
      experiment = draft!()

      assert {:ok, %Experiment{status: "running"}} =
               Experiments.start(experiment, actors.root_admin)
    end

    test "an unsaved %User{} with no membership is refused, as a stranger" do
      experiment = draft!()

      assert Experiments.start(experiment, %User{id: Ecto.UUID.generate()}) ==
               {:error, :unauthorized}

      assert Repo.get!(Experiment, experiment.id).status == "draft"
    end

    test "the agent path still answers :pending_human_approval", %{child: org} do
      Repo.insert!(
        Guardrail.changeset(%Guardrail{}, %{
          org_id: org,
          max_live: 3,
          allowed_surfaces: [@budget],
          require_human_approval: true
        })
      )

      experiment = draft!(%{org_id: org})
      assert {:ok, :pending_human_approval} = Experiments.start(experiment, :agent)
      assert Repo.get!(Experiment, experiment.id).status == "draft"
    end

    test "approve_launch is refused for a non-root user and permitted for the root admin", %{
      actors: actors,
      child: org
    } do
      Repo.insert!(
        Guardrail.changeset(%Guardrail{}, %{
          org_id: org,
          max_live: 3,
          allowed_surfaces: [@budget],
          require_human_approval: true
        })
      )

      pending = draft!(%{org_id: org})
      {:ok, :pending_human_approval} = Experiments.start(pending, :agent)

      for class <- @refused do
        assert Experiments.approve_launch(pending, actors[class]) == {:error, :unauthorized}
      end

      assert Repo.get!(Experiment, pending.id).approval_state == "pending"

      assert {:ok, %Experiment{status: "running"}} =
               Experiments.approve_launch(pending, actors.root_admin)
    end

    test "every actor form refuses the sub-org admin and permits the root admin", %{
      actors: actors
    } do
      calls = [
        {"create_experiment/2",
         fn actor ->
           Experiments.create_experiment(
             %{slug: slug(), name: "c", surface_key: @budget, surface_target: "x"},
             actor
           )
         end, &match?({:ok, %Experiment{status: "draft"}}, &1)},
        {"delete_experiment/2", fn actor -> Experiments.delete_experiment(draft!(), actor) end,
         &match?({:ok, _}, &1)},
        {"add_variant/3",
         fn actor ->
           Experiments.add_variant(
             draft!(),
             %{slug: "arm", payload: %{"max_stages" => 2}, weight: 1},
             actor
           )
         end, &match?({:ok, _}, &1)},
        {"activate/3",
         fn actor ->
           Experiments.activate(prompt_draft!(), template!().slug, actor)
         end, &match?({:ok, %Experiment{status: "running"}}, &1)},
        {"stop/2 (user)", fn actor -> Experiments.stop(running!(), actor) end,
         &match?({:ok, %Experiment{status: "stopped"}}, &1)},
        {"stop/3", fn actor -> Experiments.stop(running!(), actor, "why") end,
         &match?({:ok, %Experiment{status: "stopped"}}, &1)},
        {"conclude/2 (user)", fn actor -> Experiments.conclude(running!(), actor) end,
         &match?({:ok, %Experiment{status: "concluded"}}, &1)},
        {"Guardrails.save/3",
         fn actor -> Guardrails.save(tenant_org_id(slug()), %{max_live: 2}, actor) end,
         &match?({:ok, _}, &1)},
        {
          "Promotion.promote/2 with :actor",
          fn actor -> Promotion.promote(running!(), actor: actor, variant: "nope") end,
          # The root admin passes authorization and is stopped by the
          # promotion's own guards.
          &(&1 != {:error, :unauthorized})
        }
      ]

      for {label, call, permitted?} <- calls do
        result = call.(actors.root_admin)
        assert permitted?.(result), "#{label}: root admin got #{inspect(result)}"

        for class <- @refused do
          assert call.(actors[class]) == {:error, :unauthorized},
                 "#{label}: #{class} must be refused"
        end
      end
    end

    test "a refused stop leaves the experiment running", %{actors: actors} do
      running = running!()
      assert Experiments.stop(running, actors.sub_org_admin, "no") == {:error, :unauthorized}
      assert Repo.get!(Experiment, running.id).status == "running"
    end

    test "the actor-less system forms are unchanged" do
      assert {:ok, %Experiment{status: "stopped"}} = Experiments.stop(running!())
      assert {:ok, %Experiment{status: "concluded"}} = Experiments.conclude(running!())
      assert {:ok, %Experiment{status: "draft"}} = {:ok, draft!()}
    end
  end

  # ── prompts ─────────────────────────────────────────────────────────────

  describe "PromptTemplates.update_template/3 re-checks prompts.manage" do
    test "the root admin may update; every other class is refused and nothing is written", %{
      actors: actors
    } do
      template = template!()

      assert {:ok, %PromptTemplate{content: "ROOT"}} =
               PromptTemplates.update_template(template, %{content: "ROOT"}, actors.root_admin)

      for class <- @refused do
        assert PromptTemplates.update_template(template, %{content: "NO"}, actors[class]) ==
                 {:error, :unauthorized},
               "#{class} must be refused"
      end

      assert Repo.reload!(template).content == "ROOT"
    end

    test "a one-project prompts.manage grant does not reach install-wide templates", %{
      actors: actors
    } do
      # Positive control: the grant is live.
      assert Access.holds_anywhere?(Scope.for_user(actors.grantee), "prompts.manage")

      assert PromptTemplates.update_template(template!(), %{content: "G"}, actors.grantee) ==
               {:error, :unauthorized}
    end

    test "create_template/2 is checked the same way", %{actors: actors} do
      attrs = fn ->
        %{slug: "ctx.create.v#{System.unique_integer([:positive])}", name: "n", content: "c"}
      end

      assert {:ok, %PromptTemplate{}} =
               PromptTemplates.create_template(attrs.(), actors.root_admin)

      assert PromptTemplates.create_template(attrs.(), actors.sub_org_admin) ==
               {:error, :unauthorized}
    end

    test "update_template/2 stays unchecked for system callers" do
      assert {:ok, %PromptTemplate{content: "SYSTEM"}} =
               PromptTemplates.update_template(template!(), %{content: "SYSTEM"})
    end

    test "MCP prompt_template_update: a root-admin-owned runtime with the plan bundle succeeds",
         %{
           actors: actors
         } do
      template = template!()
      rt = runtime!(actors.root_admin, AgentRuntime.default_tool_profile() ++ ["plan"])
      ctx = %{runtime_id: rt.runtime_id, agent_id: rt.agent_id}

      assert {:ok, %{slug: slug, updated_by: "agent"}} =
               ToolSurface.execute(
                 "prompt_template_update",
                 %{"slug" => template.slug, "content" => "AGENT"},
                 ctx
               )

      assert slug == template.slug
      assert Repo.reload!(template).content == "AGENT"
    end

    test "MCP prompt_template_update: a runtime without the plan bundle is refused", %{
      actors: actors
    } do
      template = template!()
      rt = runtime!(actors.root_admin, AgentRuntime.default_tool_profile() -- ["plan"])
      refute "plan" in rt.allowed_bundles
      ctx = %{runtime_id: rt.runtime_id, agent_id: rt.agent_id}

      assert {:error, %{code: :unauthorized}} =
               ToolSurface.execute(
                 "prompt_template_update",
                 %{"slug" => template.slug, "content" => "AGENT"},
                 ctx
               )

      assert {:error, %{code: :unauthorized}} =
               ToolSurface.execute(
                 "prompt_template_update",
                 %{"slug" => template.slug, "content" => "AGENT"},
                 %{}
               )

      assert Repo.reload!(template).content == "ORIGINAL"
    end
  end

  # ── pipeline health ─────────────────────────────────────────────────────

  describe "PipelineHealth.snapshot/2 needs tasks.manage everywhere" do
    test "the root admin reads it; a project grantee and every other class are refused", %{
      actors: actors
    } do
      now = DateTime.utc_now()
      window = %{since: DateTime.add(now, -86_400), until: now}

      assert {:ok, %{cohort: %{tasks_in_window: _}}} =
               PipelineHealth.snapshot(window, actors.root_admin)

      for class <- @refused do
        assert PipelineHealth.snapshot(window, actors[class]) == {:error, :unauthorized},
               "#{class} must be refused"
      end
    end
  end

  # ── the Tasks part, stopped by its bound ────────────────────────────────

  describe "Tasks stays out of reach for guests" do
    test ":tasks is not guest-admissible (stage 2 measured 37 write entry points > 25)" do
      assert Registry.rail_entry(:chat).guest_admissible
      refute Registry.rail_entry(:tasks).guest_admissible
    end
  end
end
