defmodule Platform.Social.IdeaHandlerBoundaryTest do
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  alias Platform.Repo
  alias Platform.Access.{Grants, RuntimeProfiles, Scope}
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation.ToolCall
  alias Platform.Social

  setup do
    n = System.unique_integer([:positive])
    org = Platform.Tenancy.get_org_by_slug!("acme")

    owner =
      Repo.insert!(%Platform.Accounts.User{
        name: "Boundary",
        email: "board-boundary-#{n}@example.com",
        oidc_sub: "board-boundary-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: owner.id,
      org_id: org.id,
      role: "admin"
    })

    agent =
      Repo.insert!(%Agent{
        slug: "board-boundary-#{n}",
        name: "Boundary",
        metadata: %{"org_id" => org.id}
      })

    {:ok, project} = Platform.Tasks.create_project(%{name: "Board boundary #{n}", org_id: org.id})

    {:ok, profile} =
      Social.create_profile(org.id, %{name: "Board boundary #{n}", project_id: project.id})

    %{org: org, owner: owner, agent: agent, project: project, profile: profile}
  end

  defp runtime!(owner, agent, restrictions) do
    runtime =
      Repo.insert!(%AgentRuntime{
        runtime_id: "board-boundary-#{System.unique_integer([:positive])}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        status: "active"
      })

    {:ok, _} = RuntimeProfiles.create_for_runtime(runtime, ["social"], restrictions)
    runtime
  end

  defp context(runtime, agent),
    do: %{
      runtime_id: runtime.runtime_id,
      agent_id: agent.id,
      agent_home_org: {:tenant, agent.metadata["org_id"]}
    }

  defp real_refs!(ctx) do
    {:ok, clip} =
      Social.AgentDrafts.propose_clip(ctx.org.id, ctx.profile.id, %{
        "source_url" => "https://www.youtube.com/watch?v=abcdefghijk",
        "start_s" => 1,
        "end_s" => 10
      })

    {:ok, task} = Platform.Tasks.create_task(%{project_id: ctx.project.id, title: "Real task"})

    {:ok, meeting} =
      Platform.Meetings.create_meeting(%{project_id: ctx.project.id, name: "Real meeting"})

    space = channel!(ctx.org.id)
    participant = join!(space.id, :user, ctx.owner.id)

    {:ok, message} =
      Platform.Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content: "Real source"
      })

    %{
      "clip_id" => clip.id,
      "task_id" => task.id,
      "meeting_id" => meeting.id,
      "message_id" => message.id
    }
  end

  for key <- ~w(clip_id task_id meeting_id message_id) do
    @ref_key key
    test "narrow create rejects a real in-org #{@ref_key}; full Social accepts it", ctx do
      narrow = runtime!(ctx.owner, ctx.agent, %{"social.ideas" => "all"})
      full = runtime!(ctx.owner, ctx.agent, %{"social.use" => "all"})
      refs = real_refs!(ctx)
      before = Repo.aggregate(Social.Idea, :count)

      args = %{
        "profile_id" => ctx.profile.id,
        "title" => "Reference #{@ref_key}",
        @ref_key => Map.fetch!(refs, @ref_key)
      }

      assert {:error, %{code: :invalid_argument}} =
               ToolCall.invoke("social_idea_create", args, narrow)

      assert Repo.aggregate(Social.Idea, :count) == before
      assert {:ok, %{idea: _}} = ToolCall.invoke("social_idea_create", args, full)
      assert Repo.aggregate(Social.Idea, :count) == before + 1
    end
  end

  for kind <- ~w(human chat clip task meeting) do
    @source_kind kind
    test "narrow create rejects source kind #{@source_kind}", ctx do
      narrow = runtime!(ctx.owner, ctx.agent, %{"social.ideas" => "all"})

      assert {:error, %{code: :invalid_argument}} =
               ToolCall.invoke(
                 "social_idea_create",
                 %{
                   "profile_id" => ctx.profile.id,
                   "title" => "Unsupported",
                   "source_kind" => @source_kind
                 },
                 narrow
               )
    end
  end

  test "narrow create permits agent and URL sources", ctx do
    narrow = runtime!(ctx.owner, ctx.agent, %{"social.ideas" => "all"})

    for attrs <- [%{}, %{"source_kind" => "url", "source_url" => "https://example.com/article"}] do
      assert {:ok, %{idea: %{is_mine: true}}} =
               ToolCall.invoke(
                 "social_idea_create",
                 Map.merge(%{"profile_id" => ctx.profile.id, "title" => "Permitted"}, attrs),
                 narrow
               )
    end
  end

  test "authorized bad filters are invalid arguments, but inaccessible profiles remain not found",
       ctx do
    narrow = runtime!(ctx.owner, ctx.agent, %{"social.ideas" => "all"})

    for filter <- [%{"stage" => "failed"}, %{"archived" => true}] do
      assert {:error, %{code: :invalid_argument}} =
               ToolCall.invoke(
                 "social_idea_list",
                 Map.merge(%{"profile_id" => ctx.profile.id}, filter),
                 narrow
               )

      assert {:error, %{code: :not_found}} =
               ToolCall.invoke(
                 "social_idea_list",
                 Map.merge(%{"profile_id" => Ecto.UUID.generate()}, filter),
                 narrow
               )
    end

    {:ok, _} =
      Grants.deny(%{
        principal: {:user, ctx.owner.id},
        permission: "social.use",
        resource: {:project, ctx.project.id}
      })

    assert {:error, %{code: :not_found}} =
             ToolCall.invoke(
               "social_idea_list",
               %{"profile_id" => ctx.profile.id, "stage" => "failed"},
               narrow
             )

    assert {:error, %{code: :not_found}} =
             ToolCall.invoke(
               "social_idea_create",
               %{
                 "profile_id" => ctx.profile.id,
                 "title" => "Denied",
                 "task_id" => Ecto.UUID.generate()
               },
               narrow
             )
  end

  test "handler refuses a guest owner even with a project ideas grant", ctx do
    runtime = runtime!(ctx.owner, ctx.agent, %{"social.ideas" => "all"})

    {:ok, _} =
      Platform.Tenancy.mark_membership_external(%{user_id: ctx.owner.id, org_id: ctx.org.id})

    {:ok, _} =
      Grants.grant(%{
        principal: {:user, ctx.owner.id},
        permission: "social.ideas",
        resource: {:project, ctx.project.id}
      })

    owner = Scope.for_user(ctx.owner)
    assert Scope.guest?(owner)
    assert Platform.Access.can?(owner, "social.ideas", {:project, ctx.project.id})

    assert {:error, %{code: :not_found}} =
             Social.Tools.execute(
               "social_idea_list",
               %{"profile_id" => ctx.profile.id},
               context(runtime, ctx.agent)
             )
  end

  test "handler refuses a runtime belonging to a different agent", ctx do
    runtime = runtime!(ctx.owner, ctx.agent, nil)

    other =
      Repo.insert!(%Agent{
        slug: "board-other-#{System.unique_integer([:positive])}",
        name: "Other",
        metadata: %{"org_id" => ctx.org.id}
      })

    assert {:error, %{code: :not_found}} =
             Social.Tools.execute(
               "social_idea_list",
               %{"profile_id" => ctx.profile.id},
               context(runtime, other)
             )

    assert {:ok, %{ideas: []}} =
             Social.Tools.execute(
               "social_idea_list",
               %{"profile_id" => ctx.profile.id},
               context(runtime, ctx.agent)
             )
  end

  test "full handler requires owner authority on the selected project", ctx do
    runtime = runtime!(ctx.owner, ctx.agent, nil)

    {:ok, other_project} =
      Platform.Tasks.create_project(%{name: "Other authorized project", org_id: ctx.org.id})

    {:ok, other_profile} =
      Social.create_profile(ctx.org.id, %{name: "Authorized board", project_id: other_project.id})

    role = Repo.get_by!(Platform.Access.Role, key: "admin")
    on_exit(fn -> Platform.Access.reset_builtin_roles_cache() end)

    try do
      Repo.update!(
        Ecto.Changeset.change(role, permissions: Map.delete(role.permissions, "social.use"))
      )

      Platform.Access.reset_builtin_roles_cache()

      {:ok, _} =
        Grants.grant(%{
          principal: {:user, ctx.owner.id},
          permission: "social.use",
          resource: {:project, other_project.id}
        })

      owner = Scope.for_user(ctx.owner)
      assert Platform.Access.can?(owner, "social.use", {:project, other_project.id})
      refute Platform.Access.can?(owner, "social.use", {:project, ctx.project.id})

      assert {:ok, %{ideas: []}} =
               Social.Tools.execute(
                 "social_idea_list",
                 %{"profile_id" => other_profile.id},
                 context(runtime, ctx.agent)
               )

      assert {:error, %{code: :not_found}} =
               Social.Tools.execute(
                 "social_idea_list",
                 %{"profile_id" => ctx.profile.id},
                 context(runtime, ctx.agent)
               )
    after
      try do
        role
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.force_change(:permissions, role.permissions)
        |> Repo.update!()
      after
        Platform.Access.reset_builtin_roles_cache()
      end
    end

    assert Platform.Access.builtin_role_rules()["admin"] == role.permissions
  end
end
