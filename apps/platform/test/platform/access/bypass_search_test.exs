defmodule Platform.Access.BypassSearchTest do
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Org.Wiki.Search
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  defmodule SemanticStub do
    @behaviour Platform.Memory.Provider

    @impl true
    def search(_query, _opts, config), do: {:ok, Keyword.get(config, :results, [])}

    @impl true
    def ingest(_entries, _config), do: {:ok, 0}

    @impl true
    def delete(_ids, _config), do: {:ok, 0}

    @impl true
    def health(_config), do: :ok
  end

  test "a denied task is absent before fusion and does not increment dropped" do
    org_id = tenant_org_id("bypass-search-#{System.unique_integer([:positive])}")
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "bypass-search-#{n}@example.com",
        name: "Search Reader",
        oidc_sub: "bypass-search-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "member"})
    |> Repo.insert!()

    {:ok, project} = Tasks.create_project(%{name: "Search Q #{n}", org_id: org_id})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "ZQX-BYPASS-SEARCH"})

    previous = Application.get_env(:platform, :memory_service, [])

    Application.put_env(:platform, :memory_service,
      provider: SemanticStub,
      results: [%{entry_id: task.id, score: 0.99, memory_type: "task"}]
    )

    on_exit(fn -> Application.put_env(:platform, :memory_service, previous) end)

    scope = Scope.for_user(user)

    {:ok, before} =
      Search.search("ZQX-BYPASS-SEARCH", source: "task", access_scope: scope)

    assert Enum.any?(before.results, &(&1.id == task.id))

    {:ok, _} =
      Grants.deny(%{
        principal: {:user, user.id},
        permission: "tasks.read",
        resource: {:project, project.id}
      })

    {:ok, after_deny} =
      Search.search("ZQX-BYPASS-SEARCH", source: "task", access_scope: Scope.for_user(user))

    refute Enum.any?(after_deny.results, &(&1.id == task.id))
    assert after_deny.dropped == before.dropped
    assert after_deny.match_count == before.match_count - 1
  end

  test "message tools return the non-participant envelope after a space deny" do
    n = System.unique_integer([:positive])
    org = Platform.Tenancy.get_org_by_slug!("globex")
    owner = Platform.ExternalUserFixtures.create_user!()
    Platform.ExternalUserFixtures.plain_member!(owner, org)

    {:ok, space} =
      Chat.create_space(%{
        name: "Search #{n}",
        slug: "search-#{n}",
        kind: "channel",
        org_id: org.id
      })

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{slug: "search-agent-#{n}", name: "Search Agent", status: "active"})
      |> Repo.insert()

    {:ok, participant} = Chat.add_agent_participant(space.id, agent)

    {:ok, _owner_participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: owner.id,
        display_name: owner.name,
        joined_at: DateTime.utc_now()
      })

    {:ok, runtime} =
      Platform.Federation.register_runtime(owner.id, %{
        runtime_id: "bypass-search-#{n}",
        agent_id: agent.id
      })

    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: "ZQX-BYPASS-MESSAGE"
      })

    previous = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: SemanticStub, results: [])
    on_exit(fn -> Application.put_env(:platform, :memory_service, previous) end)

    context = %{agent_id: agent.id, runtime_id: runtime.runtime_id, access_scope: %Scope{}}

    {:ok, before_search} =
      Search.search("ZQX-BYPASS-MESSAGE", source: "message", agent: agent, access_scope: %Scope{})

    assert Enum.any?(before_search.results, &(&1.id == message.id))

    assert {:ok, _} =
             ToolSurface.execute("space_get_messages", %{"space_id" => space.id}, context)

    assert {:ok, _} =
             ToolSurface.execute(
               "space_search_messages",
               %{"space_id" => space.id, "query" => "ordinary"},
               context
             )

    {:ok, _} =
      Grants.deny(%{
        principal: {:agent, agent.id},
        permission: "chat.read",
        resource: {:space, space.id}
      })

    # A runtime scope is the MCP caller's source of agent-principal grants.
    # Keep the same positive-control envelope shape while supplying the new
    # grant snapshot explicitly to this in-process tool call.
    grant = Grants.list_for_principals([{:agent, agent.id}]) |> List.first()
    denied_context = %{context | access_scope: %Scope{grants: [grant]}}

    {:ok, after_search} =
      Search.search("ZQX-BYPASS-MESSAGE",
        source: "message",
        agent: agent,
        access_scope: denied_context.access_scope
      )

    refute Enum.any?(after_search.results, &(&1.id == message.id))
    assert after_search.dropped == before_search.dropped
    assert after_search.match_count == before_search.match_count - 1

    for tool <- ["space_get_messages", "space_search_messages"] do
      args = %{"space_id" => space.id, "query" => "ordinary"}
      assert {:error, denied} = ToolSurface.execute(tool, args, denied_context)
      assert Map.drop(denied, [:restricted]) == ToolSurface.space_write_denied(space.id)
      assert denied.restricted == true
    end
  end
end
