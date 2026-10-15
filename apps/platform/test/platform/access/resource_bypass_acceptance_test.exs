defmodule Platform.Access.ResourceBypassAcceptanceTest do
  @moduledoc """
  Cross-surface acceptance checks for task 01a1386e-45a5. Each denial has a
  positive control on the same resource. The focused bypass suites exercise
  the additional entry points and error-envelope equality in detail.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Socket
  alias Platform.Access.{Grants, Scope}
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk
  alias Platform.Chat.AttachmentStorage.Root
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation.ToolSurface
  alias Platform.Inbox
  alias Platform.Meetings
  alias Platform.Mobile
  alias Platform.Orchestration.{LeaseManager, TaskRouter, TaskRouterSupervisor}
  alias Platform.Org.Wiki.Search
  alias Platform.Repo
  alias Platform.Tasks
  alias PlatformWeb.ChatLive
  alias PlatformWeb.ChatLive.CanvasHooks

  setup do
    world = World.external_world()
    {:ok, p} = Tasks.create_project(%{name: "accept P", org_id: world.org_a.id})
    {:ok, q} = Tasks.create_project(%{name: "accept Q", org_id: world.org_a.id})
    {:ok, task_q} = Tasks.create_task(%{project_id: q.id, title: "accept Q task"})
    {:ok, eq} = Platform.Orchestration.ExecutionSpace.find_or_create(task_q.id)

    {:ok, guest_in_eq} =
      Chat.add_participant(eq.id, %{
        participant_type: "user",
        participant_id: world.ext.id,
        joined_at: DateTime.utc_now()
      })

    {:ok, member_in_eq} =
      Chat.add_participant(eq.id, %{
        participant_type: "user",
        participant_id: world.int.id,
        joined_at: DateTime.utc_now()
      })

    for user <- [world.int, world.ext] do
      {:ok, _} =
        Grants.grant(%{
          principal: {:user, user.id},
          permission: "chat.read",
          resource: {:project, p.id}
        })
    end

    Map.merge(world, %{
      p: p,
      q: q,
      task_q: task_q,
      eq: eq,
      guest_in_eq: guest_in_eq,
      member_in_eq: member_in_eq
    })
  end

  defp session(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp agent! do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "accept-agent-#{n}", name: "Accept agent #{n}", status: "active"})
  end

  defmodule MemoryStub do
    @behaviour Platform.Memory.Provider
    @impl true
    def search(_query, _opts, config), do: {:ok, Keyword.get(config, :search_results, [])}
    @impl true
    def ingest(_entries, _config), do: {:ok, 0}
    @impl true
    def delete(ids, _config), do: {:ok, length(ids)}
    @impl true
    def health(_config), do: :ok
  end

  defmodule Recorder do
    def fan_out_to_user(user_id, payload, _opts \\ []) do
      send(:persistent_term.get({__MODULE__, :owner}), {:push, user_id, payload})
      :ok
    end

    def fan_out_to_humans(ids, payload, opts \\ []) do
      send(:persistent_term.get({__MODULE__, :owner}), {:push_humans, ids, payload, opts})
      :ok
    end
  end

  defp runtime!(owner, agent) do
    {:ok, runtime} =
      Platform.Federation.register_runtime(owner.id, %{
        runtime_id: "accept-#{System.unique_integer([:positive])}"
      })

    {:ok, active, _token} = Platform.Federation.activate_runtime(runtime)
    {:ok, linked} = Platform.Federation.link_agent(active, agent)
    {linked, Repo.get!(Platform.Agents.AgentRuntime, active.id)}
  end

  defp mobile_token!(user) do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)
    {:ok, %{token: token}} = Mobile.exchange_code(code, verifier, %{app_install_id: "accept"})
    token
  end

  defp deny!(user, permission, project) do
    {:ok, _} =
      Grants.deny(%{
        principal: {:user, user.id},
        permission: permission,
        resource: {:project, project.id}
      })
  end

  defp no_marker!(term, marker) do
    refute inspect(term, limit: :infinity, printable_limit: :infinity) =~ marker
  end

  defp attachment!(space, participant, marker) do
    message = World.post!(space.id, participant.id, marker)
    key = "chat/accept/#{Ecto.UUID.generate()}.txt"
    {:ok, _} = LocalDisk.persist(key, {:binary, marker})

    {:ok, attachment} =
      Chat.create_attachment(%{
        space_id: space.id,
        message_id: message.id,
        filename: "#{marker}.txt",
        content_type: "text/plain",
        byte_size: byte_size(marker),
        storage_key: key,
        state: "ready"
      })

    attachment
  end

  describe "attachment download and range" do
    test "a participant's Q bytes disappear after a project deny", ctx do
      marker = "ZQX-ACCEPT-ATTACHMENT"
      Root.put_override(Platform.PrototypeFixtures.scratch_storage!("accept_attachment"))
      attachment = attachment!(ctx.eq, ctx.guest_in_eq, marker)

      for range <- [nil, "bytes=0-3"] do
        request = fn ->
          conn = session(ctx.ext)
          conn = if range, do: put_req_header(conn, "range", range), else: conn
          get(conn, "/chat/attachments/#{attachment.id}")
        end

        assert request.().status in [200, 206]
      end

      # The guest remains a participant of EQ and holds an allow on P.
      deny!(ctx.ext, "chat.read", ctx.q)

      for range <- [nil, "bytes=0-3"] do
        conn = session(ctx.ext)
        conn = if range, do: put_req_header(conn, "range", range), else: conn
        denied = get(conn, "/chat/attachments/#{attachment.id}")
        assert denied.status == 404
        no_marker!(denied.resp_body, marker)
      end
    end
  end

  describe "MCP attachment.get_inline" do
    test "agent-principal deny hides inline bytes", ctx do
      marker = "ZQX-ACCEPT-INLINE"
      Root.put_override(Platform.PrototypeFixtures.scratch_storage!("accept_inline"))
      attachment = attachment!(ctx.eq, ctx.member_in_eq, marker)
      agent = agent!()
      World.add_agent!(ctx.eq.id, agent.id)
      context = %{agent_id: agent.id, access_scope: %Scope{}}
      args = %{"attachment_id" => attachment.id}

      assert {:ok, %{data_base64: body}} =
               ToolSurface.execute("attachment.get_inline", args, context)

      assert Base.decode64!(body) == marker

      {:ok, grant} =
        Grants.deny(%{
          principal: {:agent, agent.id},
          permission: "chat.read",
          resource: {:project, ctx.q.id}
        })

      denied =
        ToolSurface.execute("attachment.get_inline", args, %{
          context
          | access_scope: %Scope{grants: [grant]}
        })

      assert {:error, _} = denied
      no_marker!(denied, marker)
    end
  end

  describe "Files blob, FilesLive and MCP file tools" do
    test "project file bytes and listing are hidden after a member deny", ctx do
      marker = "ZQX-ACCEPT-FILES"
      Root.put_override(Platform.PrototypeFixtures.scratch_storage!("accept_files"))
      storage_key = "files/#{ctx.q.id}/#{Ecto.UUID.generate()}/#{marker}.txt"
      path = AttachmentStorage.path_for(storage_key)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, marker)

      {:ok, file} =
        Platform.Files.create_file(%{
          project_id: ctx.q.id,
          org_id: ctx.q.org_id,
          name: "#{marker}.txt",
          original_filename: "#{marker}.txt",
          content_type: "text/plain",
          byte_size: byte_size(marker),
          storage_key: storage_key,
          content_hash: Base.encode16(:crypto.hash(:sha256, marker), case: :lower),
          ingest_status: "ingested"
        })

      {:ok, _view, before_html} = live(session(ctx.int), "/files/#{ctx.q.id}")
      assert before_html =~ marker
      assert get(session(ctx.int), "/files/blob/#{file.id}").resp_body == marker
      deny!(ctx.int, "files.read", ctx.q)
      denied = live(session(ctx.int), "/files/#{ctx.q.id}")
      assert {:error, {:live_redirect, %{to: "/files"}}} = denied
      no_marker!(denied, marker)
      denied_blob = get(session(ctx.int), "/files/blob/#{file.id}")
      assert denied_blob.status == 404
      no_marker!(denied_blob.resp_body, marker)
    end

    test "four MCP file tools stop returning Q metadata and text after an agent deny", ctx do
      marker = "ZQX-ACCEPT-FILE-TOOLS"
      agent = agent!()
      {linked, runtime} = runtime!(ctx.int, agent)
      context = %{runtime_id: runtime.runtime_id, agent_id: linked.id}

      {:ok, file} =
        Platform.Files.create_file(%{
          project_id: ctx.q.id,
          org_id: ctx.q.org_id,
          name: "#{marker}.txt",
          original_filename: "#{marker}.txt",
          content_type: "text/plain",
          byte_size: byte_size(marker),
          storage_key: "files/#{ctx.q.id}/#{Ecto.UUID.generate()}/#{marker}.txt",
          content_hash: Base.encode16(:crypto.hash(:sha256, marker), case: :lower),
          ingest_status: "ingested"
        })

      {:ok, _} = Platform.Files.upsert_extracted_text(file.id, marker, nil)
      previous = Application.get_env(:platform, :memory_service, [])

      Application.put_env(:platform, :memory_service,
        provider: MemoryStub,
        search_results: [%{entry_id: file.id, score: 0.9}]
      )

      on_exit(fn -> Application.put_env(:platform, :memory_service, previous) end)

      calls = [
        {"file_list", %{"project_id" => ctx.q.id}},
        {"file_search", %{"project_id" => ctx.q.id, "query" => marker}},
        {"file_get_metadata", %{"file_id" => file.id}},
        {"file_get_text", %{"file_id" => file.id}}
      ]

      for {tool, args} <- calls do
        assert {:ok, before} = ToolSurface.execute(tool, args, context)
        assert inspect(before, limit: :infinity) =~ marker, "#{tool} positive control"
      end

      {:ok, _} =
        Grants.deny(%{
          principal: {:agent, linked.id},
          permission: "files.read",
          resource: {:project, ctx.q.id}
        })

      for {tool, args} <- calls do
        denied = ToolSurface.execute(tool, args, context)
        assert {:error, _} = denied, "#{tool} denied"
        no_marker!(denied, marker)
      end
    end
  end

  describe "prototype entry and served grant" do
    test "a grant minted before denial cannot serve a prototype", ctx do
      marker = "ZQX-ACCEPT-PROTO"

      Platform.PrototypeFixtures.set_settings!(%{
        enabled: true,
        who_may_publish: "members",
        retention_days: 90
      })

      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => ctx.a.id,
          "created_by" => ctx.p_a_int.id,
          "title" => marker
        })

      {:ok, %{"prototype_id" => id}} =
        Platform.Prototypes.publish_embed(%{
          org_id: ctx.org_a.id,
          space_id: ctx.a.id,
          canvas_id: canvas.id,
          node_id: marker,
          html: "<p>#{marker}</p>"
        })

      entry = get(session(ctx.int), "/proto/#{id}/1/")
      assert entry.status == 302
      [grant_url] = get_resp_header(entry, "location")
      assert get(build_conn(), grant_url).resp_body =~ marker

      {:ok, _} =
        Grants.deny(%{
          principal: {:user, ctx.int.id},
          permission: "canvas.read",
          resource: {:canvas, canvas.id}
        })

      denied = get(build_conn(), grant_url)
      assert denied.status == 404
      no_marker!(denied.resp_body, marker)
    end
  end

  describe "TaskRouter dispatch and mention summon" do
    test "owner denial refuses the phase runtime", ctx do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      marker = "ZQX-ACCEPT-DISPATCH"
      agent = agent!()

      {linked, active} = runtime!(ctx.int, agent)

      {:ok, task} =
        Tasks.create_task(%{project_id: ctx.q.id, title: marker, deploy_target: "production"})

      entry = %{"assignee_id" => linked.id, "assignee_type" => "agent"}

      task =
        task
        |> Ecto.Changeset.change(%{
          status: "in_progress",
          assignee_id: linked.id,
          assignee_type: "agent",
          phase_assignees: %{"planning" => entry, "execution" => entry}
        })
        |> Repo.update!()

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

      {:ok, stage} =
        Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "coding", description: "code"})

      {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
      |> Repo.update!()

      PlatformWeb.Endpoint.subscribe("runtime:#{active.runtime_id}")

      {:ok, router} =
        TaskRouter.start_link(
          task_id: task.id,
          assignee: %{type: :federated, id: active.runtime_id}
        )

      assert_receive %Phoenix.Socket.Broadcast{event: "attention", topic: topic}, 1_500
      assert topic == "runtime:#{active.runtime_id}"
      _ = TaskRouter.current_status(task.id)
      assert %{stage_id: _} = LeaseManager.get(task.id)
      GenServer.stop(router, :normal)
      _ = TaskRouterSupervisor.stop_assignment(task.id)
      LeaseManager.clear(task.id)

      assert {:ok, _} = Platform.Orchestration.PhaseRuntime.resolve(task)
      deny!(ctx.int, "tasks.read", ctx.q)
      assert {:error, :owner_denied} = Platform.Orchestration.PhaseRuntime.resolve(task)

      {:ok, denied_router} =
        TaskRouter.start_link(
          task_id: task.id,
          assignee: %{type: :federated, id: active.runtime_id}
        )

      refute_receive %Phoenix.Socket.Broadcast{event: "attention", topic: ^topic}, 250
      assert LeaseManager.get(task.id) == nil
      GenServer.stop(denied_router, :normal)
      _ = TaskRouterSupervisor.stop_assignment(task.id)
    end

    test "an owner-denied agent is not summoned by an authorized mention", ctx do
      marker = "ZQX-ACCEPT-MENTION"
      agent = agent!()
      {linked, _runtime} = runtime!(ctx.int, agent)

      {:ok, author} =
        Chat.add_participant(ctx.eq.id, %{
          participant_type: "user",
          participant_id: ctx.m.id,
          role: "admin",
          joined_at: DateTime.utc_now()
        })

      post = fn ->
        {:ok, message} =
          Chat.post_message(
            %{
              space_id: ctx.eq.id,
              participant_id: author.id,
              content_type: "text",
              content: "#{marker} @[#{linked.slug}]"
            },
            from_pid: self()
          )

        message
      end

      post.()
      refute_receive {:mention_summon_refused, _, _}, 100

      assert Repo.exists?(
               from(p in Chat.Participant,
                 where:
                   p.space_id == ^ctx.eq.id and p.participant_type == "agent" and
                     p.participant_id == ^linked.id
               )
             )

      Repo.delete_all(
        from(p in Chat.Participant,
          where:
            p.space_id == ^ctx.eq.id and p.participant_type == "agent" and
              p.participant_id == ^linked.id
        )
      )

      deny!(ctx.int, "chat.read", ctx.q)
      post.()
      assert_receive {:mention_summon_refused, _, [name]}, 1_000
      assert name == linked.name

      refute Repo.exists?(
               from(p in Chat.Participant,
                 where:
                   p.space_id == ^ctx.eq.id and p.participant_type == "agent" and
                     p.participant_id == ^linked.id
               )
             )
    end
  end

  describe "inbox row, badge and push preview" do
    test "an emitted row disappears from both read scopes", ctx do
      marker = "ZQX-ACCEPT-INBOX"
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      Application.put_env(:platform, :notifications_module, Recorder)
      :persistent_term.put({Recorder, :owner}, self())

      on_exit(fn ->
        Application.delete_env(:platform, :notifications_module)
        :persistent_term.erase({Recorder, :owner})
      end)

      {:ok, task} = Tasks.create_task(%{project_id: ctx.q.id, title: marker})

      attrs = %{
        user_id: ctx.int.id,
        kind: "task_plan_review",
        source_type: "task",
        source_id: task.id,
        title: marker,
        body: marker,
        url: "/tasks/#{task.id}"
      }

      assert {:ok, row} = Inbox.emit(attrs)
      assert_receive {:push, recipient, payload}, 1_000
      assert recipient == ctx.int.id
      assert payload.body =~ marker
      assert Inbox.reachable_unread_count(ctx.int.id) == 1
      deny!(ctx.int, "tasks.read", ctx.q)
      assert Inbox.reachable_unread_count(ctx.int.id) == 0
      assert {:error, :denied} = Inbox.emit(attrs)
      refute_receive {:push, _, _}, 100
      {:ok, _view, html} = live(session(ctx.int), "/inbox")
      no_marker!(html, marker)
      assert row.id
    end
  end

  describe "search task and message corpora, message tools and canvas search" do
    test "a denied task is absent before search fusion", ctx do
      marker = "ZQX-ACCEPT-SEARCH"
      {:ok, task} = Tasks.create_task(%{project_id: ctx.q.id, title: marker})
      scope = Scope.for_user(ctx.int)
      assert {:ok, before} = Search.search(marker, source: "task", access_scope: scope)
      assert Enum.any?(before.results, &(&1.id == task.id))

      deny!(ctx.int, "tasks.read", ctx.q)

      assert {:ok, after_deny} =
               Search.search(marker, source: "task", access_scope: Scope.for_user(ctx.int))

      refute Enum.any?(after_deny.results, &(&1.id == task.id))
      assert after_deny.dropped == before.dropped
      no_marker!(after_deny.results, marker)
    end

    test "message corpus and both space tools hide a denied execution space", ctx do
      marker = "ZQX-ACCEPT-MESSAGE-SEARCH"
      agent = agent!()
      World.add_agent!(ctx.eq.id, agent.id)
      message = World.post!(ctx.eq.id, ctx.member_in_eq.id, marker)
      previous = Application.get_env(:platform, :memory_service, [])
      Application.put_env(:platform, :memory_service, provider: MemoryStub, search_results: [])
      on_exit(fn -> Application.put_env(:platform, :memory_service, previous) end)

      context = %{agent_id: agent.id, access_scope: %Scope{}}

      assert {:ok, before} =
               Search.search(marker, source: "message", agent: agent, access_scope: %Scope{})

      assert Enum.any?(before.results, &(&1.id == message.id))

      for tool <- ["space_get_messages", "space_search_messages"] do
        assert {:ok, _} =
                 ToolSurface.execute(
                   tool,
                   %{"space_id" => ctx.eq.id, "query" => marker},
                   context
                 )
      end

      {:ok, grant} =
        Grants.deny(%{
          principal: {:agent, agent.id},
          permission: "chat.read",
          resource: {:project, ctx.q.id}
        })

      denied_scope = %Scope{grants: [grant]}

      assert {:ok, after_deny} =
               Search.search(marker,
                 source: "message",
                 agent: agent,
                 access_scope: denied_scope
               )

      refute Enum.any?(after_deny.results, &(&1.id == message.id))
      assert after_deny.dropped == before.dropped
      no_marker!(after_deny.results, marker)

      for tool <- ["space_get_messages", "space_search_messages"] do
        denied =
          ToolSurface.execute(
            tool,
            %{"space_id" => ctx.eq.id, "query" => marker},
            %{context | access_scope: denied_scope}
          )

        assert {:error, _} = denied
        no_marker!(denied, marker)
      end
    end
  end

  describe "presence, canvas lookup, App API and meeting read" do
    test "a denied space drops subscription candidates and canvas lookup", ctx do
      marker = "ZQX-ACCEPT-PRESENCE"
      token = mobile_token!(ctx.int)

      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => ctx.a.id,
          "created_by" => ctx.p_a_int.id,
          "title" => marker
        })

      scope = Scope.for_user(ctx.int)
      socket = %Socket{assigns: %{__changed__: %{}, access_scope: scope, canvases: [canvas]}}
      assert ctx.a.id in ChatLive.presence_subscribe_space_ids([ctx.a], ctx.int.id, scope)
      assert CanvasHooks.find(socket, canvas.id).id == canvas.id

      before_ids =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/app/spaces")
        |> json_response(200)
        |> Map.fetch!("spaces")
        |> Enum.map(& &1["id"])

      assert ctx.a.id in before_ids

      {:ok, _} =
        Grants.deny(%{
          principal: {:user, ctx.int.id},
          permission: "chat.read",
          resource: {:space, ctx.a.id}
        })

      {:ok, _} =
        Grants.deny(%{
          principal: {:user, ctx.int.id},
          permission: "canvas.read",
          resource: {:canvas, canvas.id}
        })

      denied_scope = Scope.for_user(ctx.int)
      refute ctx.a.id in ChatLive.presence_subscribe_space_ids([ctx.a], ctx.int.id, denied_scope)

      denied_socket = %{socket | assigns: %{socket.assigns | access_scope: denied_scope}}
      assert CanvasHooks.find(denied_socket, canvas.id) == nil
      no_marker!(Chat.search_canvases([ctx.a.id], marker, access_scope: denied_scope), marker)

      after_ids =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/app/spaces")
        |> json_response(200)
        |> Map.fetch!("spaces")
        |> Enum.map(& &1["id"])

      refute ctx.a.id in after_ids
    end

    test "meeting detail in a denied space resolves as missing", ctx do
      marker = "ZQX-ACCEPT-MEETING"

      {:ok, meeting} =
        Meetings.create_meeting(%{project_id: ctx.q.id, name: marker})

      assert {:ok, %{id: id}} = Meetings.fetch_meeting_for_user(ctx.int, meeting.slug)
      assert id == meeting.id

      {:ok, _} =
        Grants.deny(%{
          principal: {:user, ctx.int.id},
          permission: "chat.read",
          resource: {:space, meeting.chat_space_id}
        })

      denied = Meetings.fetch_meeting_for_user(ctx.int, meeting.slug)
      assert denied == {:error, :not_found}
      no_marker!(denied, marker)
    end
  end
end
