defmodule Platform.Social.TransportParityTest do
  @moduledoc """
  The `social` bundle on BOTH federation transports (task 01a140a9-4c70,
  Social 4/7 stage 3), modelled on Play's
  `apps/game_stream/test/security/transport_capability_parity_test.exs`; the
  HTTP and WS helpers are that file's, copied.

    * A runtime granted `social` sees the registered `social_*` tools on the
      MCP `tools/list` (`POST /mcp`) AND in the runtime channel's
      `capabilities` push, each description carrying the human-approves
      sentence.
    * A runtime on the default bundles sees none.
    * No advertised name contains publish or approve.
    * `tools/call` to `social_post_publish` and `social_post_approve` is
      denied on both transports with the same text (the shared formatter,
      which Social words), and nothing is written.

  The grant sets are literal lists, as in Play's file.
  """
  use PlatformWeb.ChannelCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0, post: 3, json_response: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation.ToolAuthorization
  alias Platform.Repo
  alias Platform.Social.{Clip, Post}

  # Social 4/7's six, Social 5/7's social_clip_list and social_clip_render,
  # Social 6/7's social_task_request, and Clip Studio 1/9's social_clip_submit
  # and six clip job tools, Social authoring 2/11's two idea tools, and
  # 7/11's idea tools, and Studio's social_studio_draft_create. Sorted.
  @social_tools ~w(
    social_clip_edit_request_get social_clip_edit_request_list social_clip_job_claim social_clip_job_complete
    social_clip_job_fail social_clip_job_list social_clip_job_progress social_clip_job_source
    social_clip_list social_clip_propose social_clip_render social_clip_submit
    social_clip_update_copy social_clip_version_append social_draft_create social_draft_update
    social_idea_archive social_idea_create social_idea_list social_idea_note_add
    social_idea_unvote social_idea_vote social_post_list social_profile_get
    social_profile_list social_results_get social_studio_draft_create social_task_request
    social_weekly_note_list social_weekly_note_submit)

  @idea_tools ~w(social_idea_archive social_idea_create social_idea_list social_idea_note_add social_idea_unvote social_idea_vote)

  @granted ~w(federation space context_read messaging review canvas task plan memory skill attachment social)

  @sentence "A human approves this in Burrow and the platform publishes it; agents cannot approve or publish."

  @deny "There is no publish or approve tool: a human approves in Burrow and the platform publishes."

  setup do
    owner =
      Repo.insert!(%Platform.Accounts.User{
        email: "social-parity-#{System.unique_integer([:positive])}@example.com",
        name: "Social Parity Owner",
        oidc_sub: "social-parity-#{System.unique_integer([:positive])}"
      })

    org = Platform.Tenancy.get_org_by_slug!("acme")

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: owner.id,
      org_id: org.id,
      role: "admin"
    })

    %{owner: owner, org: org}
  end

  test "the registered tools on both transports", ctx do
    {runtime, token} = runtime_for(ctx, @granted)
    {_socket, capabilities} = join_runtime(runtime, token)

    http = http_tools_by_name(token)

    http_social =
      http |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "social_")) |> Enum.sort()

    ws_social =
      capabilities |> ws_tool_names() |> Enum.filter(&String.starts_with?(&1, "social_"))

    assert http_social == @social_tools
    assert ws_social == @social_tools
    assert http |> Map.keys() |> Enum.sort() == ws_tool_names(capabilities)

    for name <- @social_tools do
      assert http[name]["description"] =~ @sentence
      ws_tool = Enum.find(capabilities.tools, &(&1.name == name))
      assert ws_tool.description =~ @sentence

      if name == "social_clip_list" do
        for description <- [http[name]["description"], ws_tool.description] do
          assert description =~ "stable version id"
          assert description =~ "actual_start_s"
          assert description =~ "historical_unknown"
        end
      end
    end
  end

  test "the selected filter on social_idea_list is one schema on MCP, the socket and code mode",
       ctx do
    {runtime, token} = runtime_for(ctx, @granted)
    {_socket, capabilities} = join_runtime(runtime, token)

    http = http_tools_by_name(token)["social_idea_list"]
    ws = Enum.find(capabilities.tools, &(&1.name == "social_idea_list"))

    defined =
      Enum.find(Platform.Social.ToolDefinitions.definitions(), &(&1.name == "social_idea_list"))

    assert %{"type" => "boolean", "description" => text} =
             http["inputSchema"]["properties"]["selected"]

    refute "selected" in http["inputSchema"]["required"]
    assert %{type: "boolean", required: false, description: ^text} = ws.parameters.selected
    assert defined.parameters.selected.description == text
    assert http["description"] =~ "vote interest"
    assert ws.description =~ "vote interest"

    # code mode reaches the same handler: the filter works and a non-boolean is refused there too
    {cm_runtime, _} = runtime_for(ctx, ["social", "code_mode"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(cm_runtime, %{
               "social.ideas" => "all",
               "skills.read" => "all"
             })

    {:ok, project} = Platform.Tasks.create_project(%{name: "Selected parity", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Parity", project_id: project.id})

    {:ok, chosen} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Chosen one"},
        {:agent, cm_runtime.agent_id}
      )

    {:ok, _other} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Left alone"},
        {:agent, cm_runtime.agent_id}
      )

    {:ok, _, :changed} =
      Platform.Social.Ideas.select_for_research(ctx.org.id, chosen.id, {:user, ctx.owner.id})

    run = fn selected ->
      Platform.Federation.ToolCall.invoke(
        "burrow_run",
        %{
          "script" =>
            "burrow.social_idea_list({profile_id: inputs.profile_id, selected: inputs.selected})",
          "inputs" => %{"profile_id" => profile.id, "selected" => selected}
        },
        cm_runtime
      )
    end

    assert {:ok, %{ok: true, result: result}} = run.(true)
    assert inspect(result) =~ "Chosen one"
    refute inspect(result) =~ "Left alone"
    refute inspect(result) =~ "selected_at"

    assert {:ok, %{ok: true, result: result}} = run.(false)
    assert inspect(result) =~ "Left alone"
    refute inspect(result) =~ "Chosen one"

    assert {:ok, %{ok: false} = refused} = run.("maybe")
    assert inspect(refused) =~ "Unsupported idea-board argument"
  end

  test "Social profile stays capped by its owner and profile restriction", ctx do
    {runtime, token} = runtime_for(ctx, ["social"])

    assert token |> http_tools_by_name() |> Map.keys() |> Enum.filter(&social?/1) |> Enum.sort() ==
             @social_tools

    assert Platform.Access.can?(Platform.Access.Scope.for_runtime(runtime), "social.use")
    {:ok, _} = Platform.Access.RuntimeProfiles.restrict(runtime, %{})
    refute Platform.Access.can?(Platform.Access.Scope.for_runtime(runtime), "social.use")
    assert token |> http_tools_by_name() |> Map.keys() |> Enum.filter(&social?/1) == []
    {:ok, _} = Platform.Access.RuntimeProfiles.restrict(runtime, nil)

    assert token |> http_tools_by_name() |> Map.keys() |> Enum.filter(&social?/1) |> Enum.sort() ==
             @social_tools

    {:ok, _} =
      Platform.Tenancy.mark_membership_external(%{user_id: ctx.owner.id, org_id: ctx.org.id})

    refute Platform.Access.can?(Platform.Access.Scope.for_runtime(runtime), "social.use")
    assert Platform.Access.RuntimeProfiles.tool_profile(runtime) == ["social"]
    assert token |> http_tools_by_name() |> Map.keys() |> Enum.filter(&social?/1) == []
  end

  test "an ideas-only runtime with a Social owner discovers only board tools on both transports",
       ctx do
    {runtime, token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {_socket, capabilities} = join_runtime(runtime, token)

    http_social =
      token |> http_tools_by_name() |> Map.keys() |> Enum.filter(&social?/1) |> Enum.sort()

    ws_social = capabilities |> ws_tool_names() |> Enum.filter(&social?/1) |> Enum.sort()

    assert http_social == @idea_tools
    assert ws_social == @idea_tools
  end

  test "a board-tool capability refusal names both available permissions" do
    for name <- @idea_tools do
      message = ToolAuthorization.deny_message(name)
      assert message =~ "social.use"
      assert message =~ "social.ideas"
    end
  end

  test "registration does not add ideas permission to built-in or root-admin roles" do
    import Ecto.Query

    Platform.Access.reset_builtin_roles_cache()
    rules = Platform.Access.builtin_role_rules()

    for role <- ~w(admin member guest) do
      refute Map.has_key?(Map.fetch!(rules, role), "social.ideas")
    end

    root = Repo.one!(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1))
    root_admin = Platform.Access.Scope.for_role(root, "admin")
    refute Platform.Access.Scope.carries?(root_admin, "social.ideas")
    refute Platform.Access.can?(root_admin, "social.ideas")
  end

  test "a guest owner with an explicit ideas grant cannot discover or call the narrow tools",
       ctx do
    {runtime, token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {:ok, project} = Platform.Tasks.create_project(%{name: "Guest project", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Guest board", project_id: project.id})

    assert {:ok, _} =
             Platform.Tenancy.mark_membership_external(%{
               user_id: ctx.owner.id,
               org_id: ctx.org.id
             })

    assert {:ok, _} =
             Platform.Access.Grants.grant(%{
               principal: {:user, ctx.owner.id},
               permission: "social.ideas",
               resource: {:project, project.id}
             })

    owner = Platform.Access.Scope.for_user(ctx.owner)
    assert Platform.Access.Scope.guest?(owner)
    assert Platform.Access.can?(owner, "social.ideas", {:project, project.id})
    assert token |> http_tools_by_name() |> Map.keys() |> Enum.filter(&social?/1) == []

    assert {:error, :forbidden} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_list",
               %{"profile_id" => profile.id},
               runtime
             )
  end

  test "a runtime holding only Social use cannot borrow its owner's ideas-only grant", ctx do
    {runtime, token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.use" => "all"})

    {:ok, project} = Platform.Tasks.create_project(%{name: "Reverse caps", org_id: ctx.org.id})

    # Memberships have built-in member/admin roles, and custom role grants are
    # additive, so an ordinary non-guest owner already holds social.use. This
    # serialized test changes only its sandboxed role fixture, then restores
    # the row before invalidating the process-wide cache, even on failure.
    role = Repo.get_by!(Platform.Access.Role, key: "admin")
    permissions = role.permissions |> Map.delete("social.use") |> Map.put("social.ideas", "all")
    on_exit(fn -> Platform.Access.reset_builtin_roles_cache() end)

    try do
      Repo.update!(Ecto.Changeset.change(role, permissions: permissions))
      Platform.Access.reset_builtin_roles_cache()
      owner = Platform.Access.Scope.for_user(ctx.owner)
      assert Platform.Access.can?(owner, "social.ideas", {:project, project.id})
      refute Platform.Access.can?(owner, "social.use", {:project, project.id})
      refute Map.has_key?(http_tools_by_name(token), "social_idea_list")

      assert {:error, :forbidden} =
               Platform.Federation.ToolCall.invoke(
                 "social_idea_list",
                 %{"profile_id" => Ecto.UUID.generate()},
                 runtime
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

  test "both capabilities on both caps retain the full Social idea projection", ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])
    {:ok, project} = Platform.Tasks.create_project(%{name: "Full caps", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Full board", project_id: project.id})

    {:ok, idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Full result"},
        {:agent, runtime.agent_id}
      )

    assert {:ok, _} =
             Platform.Access.Grants.grant(%{
               principal: {:user, ctx.owner.id},
               permission: "social.ideas",
               resource: {:project, project.id}
             })

    assert {:ok, %{ideas: [row]}} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_list",
               %{"profile_id" => profile.id},
               runtime
             )

    assert %{id: id, stage: "inbox", posts: [], created_by_agent_id: author_id} = row
    assert id == idea.id
    assert author_id == runtime.agent_id
    refute Map.has_key?(row, :board_stage)
  end

  test "removing the owner's membership hides previously available ideas tools", ctx do
    import Ecto.Query
    {runtime, token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    assert Map.has_key?(http_tools_by_name(token), "social_idea_list")

    Repo.delete_all(
      from(m in Platform.Tenancy.OrgMembership,
        where: m.org_id == ^ctx.org.id and m.user_id == ^ctx.owner.id
      )
    )

    refute Map.has_key?(http_tools_by_name(token), "social_idea_list")

    assert {:error, :forbidden} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_list",
               %{"profile_id" => Ecto.UUID.generate()},
               runtime
             )
  end

  test "an ideas-only call cannot list a project-less profile", ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {:ok, profile} = Platform.Social.create_profile(ctx.org.id, %{name: "No project"})

    {:ok, _idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Private board item"},
        {:agent, runtime.agent_id}
      )

    assert {:error, %{code: :not_found}} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_list",
               %{"profile_id" => profile.id},
               runtime
             )
  end

  test "a project Social deny refuses an ideas-only list despite discovery", ctx do
    {runtime, token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {:ok, project} = Platform.Tasks.create_project(%{name: "Ideas gate", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Scoped board", project_id: project.id})

    {:ok, _idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Not for denied actor"},
        {:agent, runtime.agent_id}
      )

    assert {:ok, _} =
             Platform.Access.Grants.deny(%{
               principal: {:user, ctx.owner.id},
               permission: "social.use",
               resource: {:project, project.id}
             })

    assert Map.has_key?(http_tools_by_name(token), "social_idea_list")

    assert {:error, %{code: :not_found}} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_list",
               %{"profile_id" => profile.id},
               runtime
             )
  end

  test "HTTP and an already-connected socket enforce a new project deny", ctx do
    {runtime, token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {:ok, project} = Platform.Tasks.create_project(%{name: "Transport board", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Board", project_id: project.id})

    {:ok, _idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Transport sentinel"},
        {:agent, runtime.agent_id}
      )

    {socket, _} = join_runtime(runtime, token)
    args = %{"profile_id" => profile.id}
    body = rpc("tools/call", %{"name" => "social_idea_list", "arguments" => args})

    assert %{"result" => %{"content" => [%{"text" => text}], "isError" => false}} =
             json_response(mcp_post(token, body), 200)

    assert %{"ideas" => [%{"title" => "Transport sentinel"}]} = Jason.decode!(text)

    push(socket, "tool_call", %{
      "call_id" => "before-deny",
      "tool" => "social_idea_list",
      "args" => args
    })

    assert_push "tool_result", %{
      call_id: "before-deny",
      status: "ok",
      result: %{ideas: [%{title: "Transport sentinel"}]}
    }

    assert {:ok, _} =
             Platform.Access.Grants.deny(%{
               principal: {:user, ctx.owner.id},
               permission: "social.use",
               resource: {:project, project.id}
             })

    assert %{"result" => %{"isError" => true}} = json_response(mcp_post(token, body), 200)

    push(socket, "tool_call", %{
      "call_id" => "after-deny",
      "tool" => "social_idea_list",
      "args" => args
    })

    assert_push "tool_result", %{
      call_id: "after-deny",
      status: "error",
      error: %{code: :not_found}
    }
  end

  test "code mode rechecks the project on its inner board call", ctx do
    {runtime, _token} = runtime_for(ctx, ["social", "code_mode"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{
               "social.ideas" => "all",
               "skills.read" => "all"
             })

    {:ok, project} = Platform.Tasks.create_project(%{name: "Code mode board", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Board", project_id: project.id})

    {:ok, _idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Code mode sentinel"},
        {:agent, runtime.agent_id}
      )

    args = %{
      "script" => "burrow.social_idea_list({profile_id: inputs.profile_id})",
      "inputs" => %{"profile_id" => profile.id}
    }

    assert {:ok, %{ok: true, result: result}} =
             Platform.Federation.ToolCall.invoke("burrow_run", args, runtime)

    assert inspect(result) =~ "Code mode sentinel"
    refute inspect(result) =~ "created_by_agent_id"

    assert {:ok, _} =
             Platform.Access.Grants.deny(%{
               principal: {:user, ctx.owner.id},
               permission: "social.use",
               resource: {:project, project.id}
             })

    assert {:ok, %{ok: false} = denied} =
             Platform.Federation.ToolCall.invoke("burrow_run", args, runtime)

    refute inspect(denied) =~ "Code mode sentinel"
  end

  test "a Social module lock hides and refuses ideas-only tools", ctx do
    {runtime, token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    assert Map.has_key?(http_tools_by_name(token), "social_idea_list")

    assert {:ok, _} =
             Platform.Access.Grants.deny(%{
               principal: {:user, ctx.owner.id},
               permission: "social",
               resource: {:module, ctx.org.id}
             })

    refute Map.has_key?(http_tools_by_name(token), "social_idea_list")

    assert {:error, :forbidden} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_list",
               %{"profile_id" => Ecto.UUID.generate()},
               runtime
             )
  end

  test "a project ideas deny blocks a full Social holder without hiding the tool", ctx do
    {runtime, token} = runtime_for(ctx, ["social"])
    {:ok, project} = Platform.Tasks.create_project(%{name: "Full gate", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Full board", project_id: project.id})

    args = %{"profile_id" => profile.id}

    assert {:ok, %{ideas: []}} =
             Platform.Federation.ToolCall.invoke("social_idea_list", args, runtime)

    assert {:ok, _} =
             Platform.Access.Grants.deny(%{
               principal: {:user, ctx.owner.id},
               permission: "social.ideas",
               resource: {:project, project.id}
             })

    assert Map.has_key?(http_tools_by_name(token), "social_idea_list")

    assert {:error, %{code: :not_found}} =
             Platform.Federation.ToolCall.invoke("social_idea_list", args, runtime)
  end

  test "either permission denied on owner or agent blocks a narrow project call", ctx do
    {runtime, token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    for {principal, permission} <- [
          {{:user, ctx.owner.id}, "social.use"},
          {{:user, ctx.owner.id}, "social.ideas"},
          {{:agent, runtime.agent_id}, "social.use"},
          {{:agent, runtime.agent_id}, "social.ideas"}
        ] do
      {:ok, project} =
        Platform.Tasks.create_project(%{
          name: "Deny matrix #{System.unique_integer([:positive])}",
          org_id: ctx.org.id
        })

      {:ok, profile} =
        Platform.Social.create_profile(ctx.org.id, %{
          name: "Matrix board #{System.unique_integer([:positive])}",
          project_id: project.id
        })

      args = %{"profile_id" => profile.id}

      assert {:ok, %{ideas: []}} =
               Platform.Federation.ToolCall.invoke("social_idea_list", args, runtime)

      assert {:ok, _} =
               Platform.Access.Grants.deny(%{
                 principal: principal,
                 permission: permission,
                 resource: {:project, project.id}
               })

      assert Map.has_key?(http_tools_by_name(token), "social_idea_list")

      assert {:error, %{code: :not_found}} =
               Platform.Federation.ToolCall.invoke("social_idea_list", args, runtime)
    end
  end

  test "a revoked runtime cannot use a stale call context", ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])
    {:ok, project} = Platform.Tasks.create_project(%{name: "Runtime state", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Runtime board", project_id: project.id})

    args = %{"profile_id" => profile.id}

    assert {:ok, %{ideas: []}} =
             Platform.Federation.ToolCall.invoke("social_idea_list", args, runtime)

    Repo.update!(Ecto.Changeset.change(runtime, status: "revoked"))

    assert {:error, %{code: :not_found}} =
             Platform.Federation.ToolCall.invoke("social_idea_list", args, runtime)
  end

  test "an authorized ideas-only list returns board fields without author or post details", ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {:ok, project} =
      Platform.Tasks.create_project(%{name: "Ideas projection", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Scoped board", project_id: project.id})

    {:ok, idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "An agent idea"},
        {:agent, runtime.agent_id}
      )

    assert {:ok, %{ideas: [row]}} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_list",
               %{"profile_id" => profile.id},
               runtime
             )

    assert %{id: id, title: "An agent idea", board_stage: "inbox", is_mine: true} = row
    assert id == idea.id

    assert MapSet.new(Map.keys(row)) ==
             MapSet.new(
               ~w(id profile_id title brief source_kind source_url inserted_at board_stage vote_count voted selected is_mine notes)a
             )

    refute Map.has_key?(row, :created_by_agent_id)
    refute Map.has_key?(row, :posts)
    refute Map.has_key?(row, :open_revisions)
  end

  test "ideas-only lists coarsen linked post stages and reject detailed or archived filters",
       ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {:ok, project} =
      Platform.Tasks.create_project(%{name: "Board projection", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Board", project_id: project.id})

    {:ok, account} =
      Platform.Social.create_account(ctx.org.id, profile, %{
        platform: "youtube",
        handle: "@projection"
      })

    {:ok, idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Produced idea"},
        {:agent, runtime.agent_id}
      )

    {:ok, post} =
      Platform.Social.create_post(ctx.org.id, account, %{body: "private post body"},
        idea_id: idea.id
      )

    assert post.idea_id == idea.id

    args = %{"profile_id" => profile.id, "stage" => "in_production"}

    {result, queries} =
      count_idea_post_queries(fn ->
        Platform.Federation.ToolCall.invoke("social_idea_list", args, runtime)
      end)

    assert {:ok, %{ideas: [row]}} = result
    assert "social_ideas" in queries
    assert "social_posts" in queries
    assert row.board_stage == "in_production"
    refute Map.has_key?(row, :posts)
    refute inspect(row) =~ "private post body"

    for bad <- [%{"stage" => "drafting"}, %{"stage" => "failed"}, %{"archived" => true}] do
      {result, queries} =
        count_idea_post_queries(fn ->
          Platform.Federation.ToolCall.invoke("social_idea_list", Map.merge(args, bad), runtime)
        end)

      assert {:error, _} = result
      assert queries == []
    end
  end

  test "ideas-only stage filters distinguish inbox from shortlisted", ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {:ok, project} = Platform.Tasks.create_project(%{name: "Board stages", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Stages", project_id: project.id})

    {:ok, inbox} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Inbox"},
        {:agent, runtime.agent_id}
      )

    {:ok, short} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Shortlist"},
        {:agent, runtime.agent_id}
      )

    for _ <- 1..3 do
      {voter, _} = runtime_for(ctx, ["social"])

      assert {:ok, _} =
               Platform.Social.IdeaVotes.vote(ctx.org.id, short.id, {:agent, voter.agent_id})
    end

    for {stage, expected} <- [{"inbox", inbox.id}, {"shortlisted", short.id}] do
      assert {:ok, %{ideas: [%{id: ^expected, board_stage: ^stage}]}} =
               Platform.Federation.ToolCall.invoke(
                 "social_idea_list",
                 %{"profile_id" => profile.id, "stage" => stage},
                 runtime
               )
    end
  end

  test "an ideas-only create on a project-less profile refuses without writing", ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {:ok, profile} = Platform.Social.create_profile(ctx.org.id, %{name: "No project"})
    before = Repo.aggregate(Platform.Social.Idea, :count)

    assert {:error, %{code: :not_found}} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_create",
               %{"profile_id" => profile.id, "title" => "Not allowed"},
               runtime
             )

    assert Repo.aggregate(Platform.Social.Idea, :count) == before
  end

  test "ideas-only create rejects private source references and never trusts a supplied author",
       ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])
    {other, _token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {:ok, project} =
      Platform.Tasks.create_project(%{name: "Create boundaries", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Board", project_id: project.id})

    before = Repo.aggregate(Platform.Social.Idea, :count)

    for key <- ~w(clip_id task_id meeting_id message_id) do
      args = %{"profile_id" => profile.id, "title" => "No reference", key => Ecto.UUID.generate()}

      assert {:error, _} =
               Platform.Federation.ToolCall.invoke("social_idea_create", args, runtime)

      assert Repo.aggregate(Platform.Social.Idea, :count) == before
    end

    assert {:ok, %{idea: idea}} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_create",
               %{
                 "profile_id" => profile.id,
                 "title" => "Actual author",
                 "created_by_agent_id" => other.agent_id
               },
               runtime
             )

    assert idea.is_mine
    assert Repo.get!(Platform.Social.Idea, idea.id).created_by_agent_id == runtime.agent_id
    refute Map.has_key?(idea, :created_by_agent_id)
  end

  test "an ideas-only agent can create a URL-sourced idea without a private reference", ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {:ok, project} = Platform.Tasks.create_project(%{name: "URL source", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "URL board", project_id: project.id})

    assert {:ok,
            %{
              idea: %{
                source_kind: "url",
                source_url: "https://example.com/article",
                is_mine: true
              }
            }} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_create",
               %{
                 "profile_id" => profile.id,
                 "title" => "Article idea",
                 "source_kind" => "url",
                 "source_url" => "https://example.com/article"
               },
               runtime
             )
  end

  test "a direct board call without trusted runtime context cannot create", ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])
    {:ok, project} = Platform.Tasks.create_project(%{name: "Runtime gate", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Board", project_id: project.id})

    before = Repo.aggregate(Platform.Social.Idea, :count)

    assert {:error, %{code: :not_found}} =
             Platform.Federation.ToolArguments.dispatch(
               "social_idea_create",
               %{"profile_id" => profile.id, "title" => "Missing runtime"},
               %{agent_id: runtime.agent_id}
             )

    assert Repo.aggregate(Platform.Social.Idea, :count) == before
  end

  test "create rechecks the agent's home organization even with a stale root scope", ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])
    {:ok, project} = Platform.Tasks.create_project(%{name: "Agent authority", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Scoped board", project_id: project.id})

    other =
      Platform.TenancyFixtures.tenant_org_id("ideas-other-#{System.unique_integer([:positive])}")

    agent = Repo.get!(Agent, runtime.agent_id)
    Repo.update!(Ecto.Changeset.change(agent, metadata: %{"org_id" => other}))
    before = Repo.aggregate(Platform.Social.Idea, :count)

    assert {:error, %{code: :not_found}} =
             Platform.Social.Tools.execute(
               "social_idea_create",
               %{"profile_id" => profile.id, "title" => "Wrong org"},
               %{agent_id: agent.id, runtime_id: runtime.runtime_id, agent_home_org: :root}
             )

    assert Repo.aggregate(Platform.Social.Idea, :count) == before
  end

  test "malformed trusted agent context refuses without raising or creating", ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])
    {:ok, project} = Platform.Tasks.create_project(%{name: "Malformed actor", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Board", project_id: project.id})

    before = Repo.aggregate(Platform.Social.Idea, :count)

    assert {:error, %{code: :not_found}} =
             Platform.Social.Tools.execute(
               "social_idea_create",
               %{"profile_id" => profile.id, "title" => "Malformed"},
               %{
                 agent: %Agent{id: "not-a-uuid", status: "active"},
                 runtime_id: runtime.runtime_id,
                 agent_home_org: :root
               }
             )

    assert Repo.aggregate(Platform.Social.Idea, :count) == before
  end

  test "ideas-only note, vote, unvote and archive refuse a project-less idea", ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {:ok, profile} = Platform.Social.create_profile(ctx.org.id, %{name: "No project"})

    {:ok, idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Guarded idea"},
        {:agent, runtime.agent_id}
      )

    for name <- ~w(social_idea_note_add social_idea_vote social_idea_unvote social_idea_archive) do
      assert {:error, %{code: :not_found}} =
               Platform.Federation.ToolCall.invoke(
                 name,
                 %{"idea_id" => idea.id, "body" => "No write"},
                 runtime
               )
    end

    assert Repo.aggregate(Platform.Social.IdeaNote, :count) == 0
    assert Repo.aggregate(Platform.Social.IdeaVote, :count) == 0
    assert is_nil(Repo.get!(Platform.Social.Idea, idea.id).archived_at)
  end

  test "an authorized ideas-only agent can note, vote, withdraw and archive its own separate idea",
       ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])
    {author, _token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {:ok, project} = Platform.Tasks.create_project(%{name: "Board work", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Board", project_id: project.id})

    {:ok, other_idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Other idea"},
        {:agent, author.agent_id}
      )

    {:ok, own_idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Own idea"},
        {:agent, runtime.agent_id}
      )

    assert {:ok, %{note: note}} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_note_add",
               %{"idea_id" => other_idea.id, "body" => "A note"},
               runtime
             )

    assert %{body: "A note", is_mine: true} = note
    refute Map.has_key?(note, :author_id)

    assert {:ok, %{vote_count: 1, voted: true}} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_vote",
               %{"idea_id" => other_idea.id},
               runtime
             )

    assert {:ok, %{vote_count: 0, voted: false}} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_unvote",
               %{"idea_id" => other_idea.id},
               runtime
             )

    assert {:ok, %{idea_id: id, archived: true}} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_archive",
               %{"idea_id" => own_idea.id},
               runtime
             )

    assert id == own_idea.id
  end

  test "an ideas-only agent cannot add a note to an archived idea, while full Social can", ctx do
    {narrow, _} = runtime_for(ctx, ["social"])
    {full, _} = runtime_for(ctx, ["social"])
    assert {:ok, _} = Platform.Access.RuntimeProfiles.restrict(narrow, %{"social.ideas" => "all"})
    {:ok, project} = Platform.Tasks.create_project(%{name: "Archived notes", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Archived board", project_id: project.id})

    {:ok, idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Archived"},
        {:agent, full.agent_id}
      )

    assert {:ok, _} = Platform.Social.Ideas.archive(ctx.org.id, idea.id)
    args = %{"idea_id" => idea.id, "body" => "An archived note"}

    assert {:error, %{code: :not_found}} =
             Platform.Federation.ToolCall.invoke("social_idea_note_add", args, narrow)

    assert Repo.aggregate(Platform.Social.IdeaNote, :count) == 0

    assert {:ok, %{note: %{body: "An archived note"}}} =
             Platform.Federation.ToolCall.invoke("social_idea_note_add", args, full)
  end

  test "ideas-only archive refuses another author's idea and an own idea with a linked post",
       ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])
    {author, _token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {:ok, project} =
      Platform.Tasks.create_project(%{name: "Archive boundary", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Board", project_id: project.id})

    {:ok, account} =
      Platform.Social.create_account(ctx.org.id, profile, %{
        platform: "youtube",
        handle: "@archive"
      })

    {:ok, other} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Another author"},
        {:agent, author.agent_id}
      )

    {:ok, linked} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Linked idea"},
        {:agent, runtime.agent_id}
      )

    {:ok, post} =
      Platform.Social.create_post(ctx.org.id, account, %{body: "draft"}, idea_id: linked.id)

    assert {:error, %{code: :not_idea_author}} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_archive",
               %{"idea_id" => other.id},
               runtime
             )

    assert {:error, %{code: :idea_has_posts}} =
             Platform.Federation.ToolCall.invoke(
               "social_idea_archive",
               %{"idea_id" => linked.id},
               runtime
             )

    assert is_nil(Repo.get!(Platform.Social.Idea, other.id).archived_at)
    assert is_nil(Repo.get!(Platform.Social.Idea, linked.id).archived_at)
    assert Repo.get!(Post, post.id).idea_id == linked.id
  end

  test "a denied board actor cannot learn vote or archive eligibility", ctx do
    {runtime, _token} = runtime_for(ctx, ["social"])
    {author, _token} = runtime_for(ctx, ["social"])

    assert {:ok, _} =
             Platform.Access.RuntimeProfiles.restrict(runtime, %{"social.ideas" => "all"})

    {:ok, project} =
      Platform.Tasks.create_project(%{name: "Eligibility privacy", org_id: ctx.org.id})

    {:ok, profile} =
      Platform.Social.create_profile(ctx.org.id, %{name: "Board", project_id: project.id})

    {:ok, account} =
      Platform.Social.create_account(ctx.org.id, profile, %{
        platform: "youtube",
        handle: "@eligibility"
      })

    {:ok, own} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Own"},
        {:agent, runtime.agent_id}
      )

    {:ok, other} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Other"},
        {:agent, author.agent_id}
      )

    {:ok, linked} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        profile.id,
        %{title: "Linked"},
        {:agent, runtime.agent_id}
      )

    {:ok, _post} =
      Platform.Social.create_post(ctx.org.id, account, %{body: "draft"}, idea_id: linked.id)

    for {tool, idea, expected} <- [
          {"social_idea_vote", own, :own_idea},
          {"social_idea_archive", other, :not_idea_author},
          {"social_idea_archive", linked, :idea_has_posts}
        ] do
      assert {:error, %{code: ^expected}} =
               Platform.Federation.ToolCall.invoke(tool, %{"idea_id" => idea.id}, runtime)
    end

    assert {:ok, _} =
             Platform.Access.Grants.deny(%{
               principal: {:user, ctx.owner.id},
               permission: "social.use",
               resource: {:project, project.id}
             })

    for {tool, idea} <- [
          {"social_idea_vote", own},
          {"social_idea_archive", other},
          {"social_idea_archive", linked}
        ] do
      assert {:error, %{code: :not_found}} =
               Platform.Federation.ToolCall.invoke(tool, %{"idea_id" => idea.id}, runtime)

      assert is_nil(Repo.get!(Platform.Social.Idea, idea.id).archived_at)
    end

    assert Repo.aggregate(Platform.Social.IdeaVote, :count) == 0
  end

  test "a default-bundles runtime sees no social tool on either transport", ctx do
    {runtime, token} = runtime_for(ctx, AgentRuntime.default_tool_profile())
    refute "social" in AgentRuntime.default_tool_profile()
    {_socket, capabilities} = join_runtime(runtime, token)

    assert token |> http_tools_by_name() |> Map.keys() |> Enum.filter(&social?/1) == []
    assert capabilities |> ws_tool_names() |> Enum.filter(&social?/1) == []
  end

  # Scoped to the social bundle's names: core's own `plan` bundle carries
  # `plan_approve` (a plan gate, not a post), which this task does not own.
  test "no advertised social name contains publish or approve", ctx do
    {runtime, token} = runtime_for(ctx, @granted)
    {_socket, capabilities} = join_runtime(runtime, token)

    names =
      (Map.keys(http_tools_by_name(token)) ++ ws_tool_names(capabilities))
      |> Enum.filter(&social?/1)

    # Twenty-seven names, once per transport
    assert length(names) == 60
    assert Enum.filter(names, &(&1 =~ "publish" or &1 =~ "approve")) == []
  end

  # Social Studio slice B: approval, planning and
  # cancelling are human-only context functions; no tool name can reach one.
  test "no advertised social name can approve, plan, cancel, revoke, accept or retarget", ctx do
    {runtime, token} = runtime_for(ctx, @granted)
    {_socket, capabilities} = join_runtime(runtime, token)

    names =
      (Map.keys(http_tools_by_name(token)) ++ ws_tool_names(capabilities))
      |> Enum.filter(&social?/1)

    assert length(names) == 60

    forbidden =
      ~r/approv|plan|cancel|revok|revoke|retarget|accept|resubmit|request_changes|schedule/

    assert Enum.filter(names, &(&1 =~ forbidden)) == []

    # The Studio write functions are not exposed as tools by any other name either.
    studio_writers =
      ~w(approve_version plan_post cancel_plan revoke_approval request_changes resubmit save_version accept_render)

    tool_source =
      ["tools.ex", "tool_definitions.ex"]
      |> Enum.map(&File.read!(Path.expand("../../lib/platform/social/#{&1}", __DIR__)))
      |> Enum.join("\n")

    for fun <- studio_writers do
      refute tool_source =~ fun, "#{fun} is referenced from the agent tool modules"
    end
  end

  test "publish and approve calls are denied on both transports, same text, nothing written",
       ctx do
    {runtime, token} = runtime_for(ctx, @granted)
    {socket, _capabilities} = join_runtime(runtime, token)
    before = {Repo.aggregate(Post, :count), Repo.aggregate(Clip, :count)}

    for name <- ~w(social_post_publish social_post_approve) do
      assert ToolAuthorization.deny_message(name) == @deny
      assert {:denied, http_message} = http_verdict(token, name)
      assert {:denied, ws_message} = ws_verdict(socket, name)
      assert http_message == @deny
      assert ws_message == @deny
    end

    assert {Repo.aggregate(Post, :count), Repo.aggregate(Clip, :count)} == before
  end

  test "a granted tool is allowed on both transports (the verdict probe is not vacuous)", ctx do
    {runtime, token} = runtime_for(ctx, @granted)
    {socket, _capabilities} = join_runtime(runtime, token)

    for name <-
          ~w(social_profile_list social_results_get social_task_request social_weekly_note_list social_weekly_note_submit) do
      assert http_verdict(token, name) == :allowed
      assert ws_verdict(socket, name) == :allowed
    end
  end

  defp social?(name), do: String.starts_with?(name, "social_")

  defp count_idea_post_queries(fun) do
    caller = self()
    ref = make_ref()

    :ok =
      :telemetry.attach(
        ref,
        [:platform, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == caller and metadata[:source] in ["social_ideas", "social_posts"] do
            send(caller, {ref, metadata.source})
          end
        end,
        nil
      )

    result =
      try do
        fun.()
      after
        :telemetry.detach(ref)
      end

    {result, drain_idea_post_queries(ref, [])}
  end

  defp drain_idea_post_queries(ref, rows) do
    receive do
      {^ref, source} -> drain_idea_post_queries(ref, [source | rows])
    after
      0 -> rows
    end
  end

  # ── HTTP transport (POST /mcp) ─────────────────────────────────────────

  defp http_tools_by_name(token) do
    conn = mcp_post(token, rpc("tools/list"))
    %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    Map.new(tools, fn tool -> {tool["name"], tool} end)
  end

  defp http_verdict(token, name) do
    conn = mcp_post(token, rpc("tools/call", %{"name" => name, "arguments" => %{}}))

    case json_response(conn, 200) do
      %{"error" => %{"code" => -32001, "message" => message}} -> {:denied, message}
      _ -> :allowed
    end
  end

  defp mcp_post(token, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", body)
  end

  defp rpc(method, params \\ %{}, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  # ── WebSocket transport (runtime:*) ────────────────────────────────────

  defp ws_tool_names(capabilities), do: capabilities.tools |> Enum.map(& &1.name) |> Enum.sort()

  defp ws_verdict(socket, name) do
    call_id = "social-parity-#{System.unique_integer([:positive])}"
    push(socket, "tool_call", %{"call_id" => call_id, "tool" => name, "args" => %{}})
    assert_push("tool_result", %{call_id: ^call_id} = frame)

    case frame do
      %{status: "error", error: %{code: "forbidden", error: message}} -> {:denied, message}
      _ -> :allowed
    end
  end

  defp join_runtime(runtime, token) do
    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{"runtime_id" => runtime.runtime_id, "token" => token})

    {:ok, _reply, socket} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})
    assert_push("capabilities", capabilities)
    {socket, capabilities}
  end

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp runtime_for(ctx, modules) do
    raw_token = AgentRuntime.generate_token()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "social-parity-agent-#{System.unique_integer([:positive])}",
        name: "Social Parity Agent",
        status: "active"
      })
      |> Repo.insert()

    {:ok, runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "social-parity-rt-#{System.unique_integer([:positive])}",
        owner_user_id: ctx.owner.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw_token),
        status: "active"
      })
      |> Repo.insert()

    {:ok, _} = Platform.Access.RuntimeProfiles.create_for_runtime(runtime, modules, nil)
    {runtime, raw_token}
  end
end
