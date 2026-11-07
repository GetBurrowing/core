defmodule Platform.Agents.BurrowHoldsRolesGatesTest do
  @moduledoc """
  Task 01a1b741 stage 1, intended behaviour changes: once Burrow holds every
  unheld role, it is the `Roles.assignee_for/1` answer for the architect and
  designer work, so plan submit opens the architecture gate naming Burrow,
  and the designer's pre-plan step fires instead of skipping as
  `"no_designer"`.

  Only the native hand-off is stubbed (`:responsibility_router_native_dispatcher`),
  so the route from role to Burrow is the real one: seeded role bundles,
  `Burrow.ensure/2`, `Roles.assignee_for/1`.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.SubmittablePlanFixtures

  alias Platform.Agents.Burrow
  alias Platform.Design.PreplanStep
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.DesignTaskDirection
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Task, as: TaskSchema
  alias Platform.Tenancy.OrgMembership

  @ui_title "Add an epic-create FAB above the board"

  defmodule NoopDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: :ok
  end

  setup do
    previous_token = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, "test-host-token")
    previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {NoopDispatcher, :maybe_dispatch}
    )

    on_exit(fn ->
      restore(:agent_host_token, previous_token)
      restore(:responsibility_router_native_dispatcher, previous)
    end)

    for key <- Role.valid_keys(), do: :ok = Roles.unassign_role(key)

    {:ok, _} =
      Responsibilities.upsert_by_key(%{
        key: "architecture.review_plan",
        feature: "architecture",
        trigger_kind: "event_topic",
        trigger_config: %{"topic" => "plan:submitted"},
        scope: "per_project",
        context_provided: ["plan_payload", "sibling_tasks", "adr_index"],
        output_contract: %{"comments" => "list[map]"},
        default_prompt_template: "architecture.review_plan.v1",
        cost_profile: "low_freq_capable",
        metadata: %{"owner" => "platform.architecture", "adr" => "0044"}
      })

    [spec] = DesignTaskDirection.register()
    {:ok, _} = Responsibilities.upsert_by_key(spec)

    {:ok, burrow} = Burrow.ensure(admin!().id, "claude_code")
    assert Roles.agent_id_for_role("architect") == burrow.id
    assert Roles.agent_id_for_role("designer") == burrow.id

    {:ok, project} =
      Tasks.create_project(%{name: "Burrow roles #{System.unique_integer([:positive])}"})

    %{burrow: burrow, project: project}
  end

  defp restore(key, nil), do: Application.delete_env(:platform, key)
  defp restore(key, value), do: Application.put_env(:platform, key, value)

  defp admin! do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "burrow-gates-#{n}@example.com",
        name: "Owner #{n}",
        oidc_sub: "oidc-burrow-gates-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  test "plan submit opens the architecture gate with Burrow as the architect", %{
    burrow: burrow,
    project: project
  } do
    assert Roles.assignee_for("architecture.review_plan").id == burrow.id

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Gate task", status: "planning"})

    {:ok, plan} = create_submittable_plan(%{task_id: task.id})

    capture_log([level: :info], fn ->
      assert {:ok, %Plan{status: "pending_review"}} = Tasks.submit_plan_for_review(plan)
    end)

    verdict = Repo.get!(Plan, plan.id).architecture_verdict
    assert verdict["state"] == "pending"
    assert verdict["architect_agent_id"] == burrow.id
  end

  test "the designer's pre-plan step fires for Burrow instead of skipping", %{
    burrow: burrow,
    project: project
  } do
    assert Roles.assignee_for("design.task_direction").id == burrow.id

    now = DateTime.utc_now()

    task =
      %TaskSchema{}
      |> Ecto.Changeset.change(%{
        project_id: project.id,
        title: @ui_title,
        status: "planning",
        inserted_at: now,
        updated_at: now
      })
      |> Repo.insert!()

    {:ok, _space} =
      Platform.Chat.create_space(%{
        name: "burrow-design-#{System.unique_integer([:positive])}",
        slug: "burrow-design-#{System.unique_integer([:positive])}",
        kind: "execution",
        metadata: %{"task_id" => task.id}
      })

    capture_log([level: :debug], fn -> assert {:ok, :open} = PreplanStep.start(task) end)

    reloaded = Repo.get!(TaskSchema, task.id)
    refute (reloaded.planning_step_outcomes || %{})["design"]["reason"] == "no_designer"
    assert reloaded.planning_step == "designing"
  end
end
