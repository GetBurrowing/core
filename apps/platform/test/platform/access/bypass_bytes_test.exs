defmodule Platform.Access.BypassBytesTest do
  @moduledoc """
  The core byte surfaces honour RBAC v2 denies (task 01a1386e-45a5 stage 1,
  RBAC stack member 7;
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`,
  "The grant-less short-circuit").

  Before this stage every surface here checked MEMBERSHIP only (space
  participation, `Tenancy.member_of?/2`, the MCP org filter), so a deny on a
  project, space or canvas did not stop the bytes. Each surface now runs
  `Platform.Access.check/3` in conjunction with its existing check.

  Every absence assertion is preceded, in the same test and on the same
  fixture, by its POSITIVE CONTROL: the identical request succeeds before the
  deny row exists. After the deny the response is compared with the response
  for a random uuid, and the marker `ZQX-BYPASS-BYTES` (in every filename,
  title and body) must appear nowhere in it.

  ## Premises this suite records

    * **An agent runtime's Scope carries the agent's OWN grants only** (no
      owner intersection until stack member 5), so the MCP and bearer cases
      deny A's agent principal, not its owner M.
    * **A guest is held off `/files/*` and `/proto/*` entry before any
      controller runs** (`:enforce_external_scope`), so the guest rows cover
      the attachment route, the one byte route a guest reaches today. The
      guest file-blob row pins the 403 it gets with and without a deny.
    * **A guest's allow on P does not by itself narrow the guest.** The site's
      existing check (participation) stands in for the role-rule allow, so a
      guest who holds an allow on P is still served EQ's attachment until a
      deny covers it. The guest rows therefore deny Q, as the member rows do.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.PrototypeFixtures, only: [scratch_storage!: 1, set_settings!: 1]
  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{Canvas, Participant, Space}
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk
  alias Platform.Chat.AttachmentStorage.Root
  alias Platform.ExternalUserFixtures
  alias Platform.Federation.ToolSurface
  alias Platform.Files
  alias Platform.Prototypes
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{CanvasAttachments, Task}
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @marker "ZQX-BYPASS-BYTES"

  # ── fixture ─────────────────────────────────────────────────────────────

  setup do
    scratch = scratch_storage!("bypass_bytes_test")
    Root.put_override(scratch)
    set_settings!(%{enabled: true, who_may_publish: "members", retention_days: 90})

    _root = acme_org_id()
    org = tenant_org_id("bpb-#{System.unique_integer([:positive])}")

    p = project!(org, "bpb-p")
    q = project!(org, "bpb-q")
    tp = task!(p, "bpb p task")
    tq = task!(q, "#{@marker} task")
    ep = exec_space!(tp, org)
    eq = exec_space!(tq, org)

    m = member!(org)
    g = guest!(org)
    pm_eq = join!(eq, "user", m.id)
    pm_ep = join!(ep, "user", m.id)
    join!(eq, "user", g.id)
    join!(ep, "user", g.id)

    a = runtime!(m, [eq, ep])

    k = canvas!(eq, pm_eq, "#{@marker} canvas K")
    k2 = canvas!(eq, pm_eq, "bpb sibling canvas K2")

    att = attachment!(eq, pm_eq, nil, "#{@marker}-message.txt", "#{@marker} message bytes")
    att_k = attachment!(eq, pm_eq, k.id, "#{@marker}-canvas.txt", "#{@marker} canvas bytes")
    att_p = attachment!(ep, pm_ep, nil, "bpb-p-message.txt", "p message bytes ok")

    file_q = file!(q, "#{@marker}-q.txt", "#{@marker} file bytes")
    file_p = file!(p, "bpb-p-file.txt", "p file bytes ok")

    {:ok, %{"prototype_id" => proto_id}} =
      Prototypes.publish_embed(%{
        org_id: org,
        space_id: eq.id,
        canvas_id: k.id,
        node_id: "embed-1",
        html: "<!doctype html><p>#{@marker} prototype</p>"
      })

    %{
      org: org,
      p: p,
      q: q,
      tq: tq,
      ep: ep,
      eq: eq,
      m: m,
      g: g,
      a: a,
      k: k,
      k2: k2,
      att: att,
      att_k: att_k,
      att_p: att_p,
      file_q: file_q,
      file_p: file_p,
      proto_id: proto_id
    }
  end

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "bpb-#{tag}-#{n}@example.com",
      name: "BPB #{tag} #{n}",
      oidc_sub: "bpb-#{tag}-#{n}"
    })
  end

  defp member!(org) do
    u = user!("member")

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: u.id, org_id: org, role: "member"})
    |> Repo.insert!()

    u
  end

  defp guest!(org) do
    u = user!("guest")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: u.id, org_id: org})
    u
  end

  defp project!(org, name) do
    {:ok, p} =
      Tasks.create_project(%{name: "#{name}-#{System.unique_integer([:positive])}", org_id: org})

    p
  end

  defp task!(project, title),
    do: Repo.insert!(%Task{project_id: project.id, title: title, status: "backlog"})

  defp exec_space!(task, org) do
    n = System.unique_integer([:positive])

    %Space{}
    |> Space.changeset(%{
      kind: "execution",
      name: "bpb-exec-#{n}",
      slug: "bpb-exec-#{n}",
      org_id: org,
      metadata: %{"task_id" => task.id}
    })
    |> Repo.insert!()
  end

  defp join!(space, type, id) do
    Repo.insert!(%Participant{
      space_id: space.id,
      participant_type: type,
      participant_id: id,
      role: "member",
      joined_at: DateTime.utc_now()
    })
  end

  defp canvas!(space, author, title),
    do: Repo.insert!(%Canvas{space_id: space.id, created_by: author.id, title: title})

  defp runtime!(owner, spaces) do
    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{slug: "bpb-agent-#{n}", name: "BPB agent #{n}", status: "active"})
      |> Repo.insert()

    Enum.each(spaces, &join!(&1, "agent", agent.id))
    token = AgentRuntime.generate_token()

    {:ok, rt} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "bpb-rt-#{n}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(token),
        status: "active",
        allowed_bundles: AgentRuntime.default_allowed_bundles()
      })
      |> Repo.insert()

    Map.put(rt, :plain_token, token)
  end

  defp attachment!(space, participant, canvas_id, filename, body) do
    message = ExternalUserFixtures.post!(space.id, participant.id, "bpb message")

    key = "chat/bpb/#{Ecto.UUID.generate()}.txt"
    {:ok, _} = LocalDisk.persist(key, {:binary, body})

    {:ok, att} =
      Chat.create_attachment(%{
        space_id: space.id,
        message_id: message.id,
        canvas_id: canvas_id,
        filename: filename,
        content_type: "text/plain",
        byte_size: byte_size(body),
        storage_key: key,
        state: "ready"
      })

    att
  end

  defp file!(project, name, body) do
    storage_key = "files/#{project.id}/#{Ecto.UUID.generate()}/#{name}"
    path = AttachmentStorage.path_for(storage_key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)

    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        org_id: project.org_id,
        name: name,
        original_filename: name,
        content_type: "text/plain",
        byte_size: byte_size(body),
        storage_key: storage_key,
        content_hash: :crypto.hash(:sha256, body <> name) |> Base.encode16(case: :lower),
        ingest_status: "ingested"
      })

    {:ok, _} = Files.upsert_extracted_text(file.id, body, nil)
    file
  end

  defp deny!(principal, permission, resource),
    do:
      {:ok, _} = Grants.deny(%{principal: principal, permission: permission, resource: resource})

  defp grant!(principal, permission, resource),
    do:
      {:ok, _} = Grants.grant(%{principal: principal, permission: permission, resource: resource})

  defp session(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp bearer(rt),
    do: build_conn() |> put_req_header("authorization", "Bearer #{rt.plain_token}")

  defp get_att(conn, id, range \\ nil) do
    conn = if range, do: put_req_header(conn, "range", range), else: conn
    get(conn, "/chat/attachments/#{id}")
  end

  defp call(rt, name, args),
    do: ToolSurface.execute(name, args, %{runtime_id: rt.runtime_id, agent_id: rt.agent_id})

  defp leaks?(term), do: inspect(term, limit: :infinity, printable_limit: :infinity) =~ @marker

  # An MCP not-found envelope names the id it was asked for; compare two of
  # them with that id taken out.
  defp normalize({:error, envelope}, id),
    do: {:error, Map.new(envelope, fn {k, v} -> {k, scrub(v, id)} end)}

  defp scrub(v, id) when is_binary(v), do: String.replace(v, id, "<ID>")
  defp scrub(v, _id), do: v

  defp same_as_random_404!(conn, user) do
    random = get_att(session(user), Ecto.UUID.generate())
    assert {conn.status, conn.resp_body} == {random.status, random.resp_body}
    assert conn.status == 404
    refute conn.resp_body =~ @marker
  end

  # ── GET /chat/attachments/:id ─────────────────────────────────────────

  describe "GET /chat/attachments/:id" do
    test "member M: a chat.read deny on Q refuses EQ's attachment, full and ranged", ctx do
      # Positive control: the identical requests succeed before the deny.
      full = get_att(session(ctx.m), ctx.att.id)
      assert full.status == 200
      assert full.resp_body =~ @marker
      ranged = get_att(session(ctx.m), ctx.att.id, "bytes=0-3")
      assert ranged.status == 206
      assert ranged.resp_body == "ZQX-"

      deny!(ctx.m, "chat.read", ctx.q)

      random = get_att(session(ctx.m), Ecto.UUID.generate())
      full = get_att(session(ctx.m), ctx.att.id)
      ranged = get_att(session(ctx.m), ctx.att.id, "bytes=0-3")

      for conn <- [full, ranged] do
        assert {conn.status, conn.resp_body} == {random.status, random.resp_body}
        assert conn.status == 404
        refute conn.resp_body =~ @marker
      end

      # P's attachment is still served.
      p_conn = get_att(session(ctx.m), ctx.att_p.id)
      assert p_conn.status == 200
      assert p_conn.resp_body == "p message bytes ok"
    end

    test "guest G holding an allow on P: a chat.read deny on Q refuses EQ's attachment",
         ctx do
      grant!(ctx.g, "chat.read", ctx.p)

      # Positive control: the guest holds a grant and today's participation
      # path still serves it EQ's attachment (an allow does not narrow).
      assert Scope.has_grants?(Scope.for_user(%{id: ctx.g.id}))
      assert get_att(session(ctx.g), ctx.att.id).status == 200
      assert get_att(session(ctx.g), ctx.att.id, "bytes=0-3").status == 206

      deny!(ctx.g, "chat.read", ctx.q)

      random = get_att(session(ctx.g), Ecto.UUID.generate())

      for range <- [nil, "bytes=0-3"] do
        conn = get_att(session(ctx.g), ctx.att.id, range)
        assert {conn.status, conn.resp_body} == {random.status, random.resp_body}
        refute conn.resp_body =~ @marker
      end

      assert get_att(session(ctx.g), ctx.att_p.id).status == 200
    end

    test "a canvas.read deny on canvas K refuses K's attachment and nothing else", ctx do
      assert get_att(session(ctx.m), ctx.att_k.id).status == 200

      deny!(ctx.m, "canvas.read", ctx.k)

      conn = get_att(session(ctx.m), ctx.att_k.id)
      same_as_random_404!(conn, ctx.m)
      # The space-only attachment in the same space is untouched: the deny is
      # on canvas.read for K only.
      assert get_att(session(ctx.m), ctx.att.id).status == 200
    end

    test "runtime bearer: a deny on A's agent principal refuses EQ's attachment", ctx do
      assert get_att(bearer(ctx.a), ctx.att.id).status == 200

      deny!({:agent, ctx.a.agent_id}, "chat.read", ctx.q)

      random = get_att(bearer(ctx.a), Ecto.UUID.generate())
      conn = get_att(bearer(ctx.a), ctx.att.id)
      assert {conn.status, conn.resp_body} == {random.status, random.resp_body}
      refute conn.resp_body =~ @marker
      assert get_att(bearer(ctx.a), ctx.att_p.id).status == 200
    end
  end

  # ── MCP attachment.get_inline ─────────────────────────────────────────

  describe "MCP attachment.get_inline" do
    test "a deny on A's agent principal answers exactly as an unknown id", ctx do
      assert {:ok, %{data_base64: b64}} =
               call(ctx.a, "attachment.get_inline", %{"attachment_id" => ctx.att.id})

      assert Base.decode64!(b64) =~ @marker

      deny!({:agent, ctx.a.agent_id}, "chat.read", ctx.q)

      random_id = Ecto.UUID.generate()
      random = call(ctx.a, "attachment.get_inline", %{"attachment_id" => random_id})
      denied = call(ctx.a, "attachment.get_inline", %{"attachment_id" => ctx.att.id})

      assert denied == random
      refute leaks?(denied)

      assert {:ok, %{data_base64: p64}} =
               call(ctx.a, "attachment.get_inline", %{"attachment_id" => ctx.att_p.id})

      assert Base.decode64!(p64) == "p message bytes ok"
    end

    test "a canvas.read deny on K refuses the canvas-bound attachment", ctx do
      assert {:ok, _} = call(ctx.a, "attachment.get_inline", %{"attachment_id" => ctx.att_k.id})

      deny!({:agent, ctx.a.agent_id}, "canvas.read", ctx.k)

      assert {:error, %{error: "attachment: not found"}} =
               call(ctx.a, "attachment.get_inline", %{"attachment_id" => ctx.att_k.id})

      assert {:ok, _} = call(ctx.a, "attachment.get_inline", %{"attachment_id" => ctx.att.id})
    end
  end

  # ── GET /files/blob/:id ───────────────────────────────────────────────

  describe "GET /files/blob/:id" do
    test "member M: a files.read deny on Q answers as an unknown file id", ctx do
      conn = get(session(ctx.m), "/files/blob/#{ctx.file_q.id}")
      assert conn.status == 200
      assert conn.resp_body =~ @marker

      deny!(ctx.m, "files.read", ctx.q)

      random = get(session(ctx.m), "/files/blob/#{Ecto.UUID.generate()}")
      conn = get(session(ctx.m), "/files/blob/#{ctx.file_q.id}")
      assert {conn.status, conn.resp_body} == {random.status, random.resp_body}
      assert conn.status == 404
      refute conn.resp_body =~ @marker
      refute Enum.any?(conn.resp_headers, fn {_k, v} -> v =~ @marker end)

      p_conn = get(session(ctx.m), "/files/blob/#{ctx.file_p.id}")
      assert p_conn.status == 200
      assert p_conn.resp_body == "p file bytes ok"
    end

    test "a deny on another permission (chat.read) does not refuse a file blob", ctx do
      deny!(ctx.m, "chat.read", ctx.q)
      assert get(session(ctx.m), "/files/blob/#{ctx.file_q.id}").status == 200
    end

    test "guest G is refused before the controller, with and without a deny", ctx do
      # Premise pin: `:enforce_external_scope` answers 403 for a guest.
      assert get(session(ctx.g), "/files/blob/#{ctx.file_p.id}").status == 403
      deny!(ctx.g, "files.read", ctx.q)
      conn = get(session(ctx.g), "/files/blob/#{ctx.file_q.id}")
      refute conn.status == 200
      refute conn.resp_body =~ @marker
    end
  end

  # ── FilesLive /files/<Q> ──────────────────────────────────────────────

  describe "FilesLive /files/<project>" do
    test "member M: a files.read deny on Q behaves exactly like a missing project", ctx do
      {:ok, _view, html} = live(session(ctx.m), "/files/#{ctx.q.id}")
      assert html =~ "#{@marker}-q.txt"

      deny!(ctx.m, "files.read", ctx.q)

      # A missing project redirects to /files with the not-found flash; a
      # denied one gets exactly that answer.
      random = live(session(ctx.m), "/files/#{Ecto.UUID.generate()}")
      assert {:error, {:live_redirect, %{to: "/files"}}} = random
      denied = live(session(ctx.m), "/files/#{ctx.q.id}")
      assert denied == random
      refute inspect(denied) =~ @marker

      {:ok, _p_view, p_html} = live(session(ctx.m), "/files/#{ctx.p.id}")
      assert p_html =~ "bpb-p-file.txt"
    end

    test "a semantic-hit selection of a denied file is refused like a missing one", ctx do
      {:ok, view, _} = live(session(ctx.m), "/files/#{ctx.p.id}")

      html = render_click(view, "select_semantic_hit", %{"id" => ctx.file_q.id})
      assert html =~ "#{@marker}-q.txt"

      deny!(ctx.m, "files.read", ctx.q)
      {:ok, view, _} = live(session(ctx.m), "/files/#{ctx.p.id}")

      html = render_click(view, "select_semantic_hit", %{"id" => ctx.file_q.id})
      assert html =~ "File no longer exists."
      refute html =~ @marker
    end
  end

  # ── MCP file tools ────────────────────────────────────────────────────

  describe "MCP file tools" do
    setup ctx do
      prev = Application.get_env(:platform, :memory_service, [])

      Application.put_env(:platform, :memory_service,
        provider: __MODULE__.MemoryStub,
        search_results: [%{entry_id: ctx.file_q.id, score: 0.9}]
      )

      on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
      :ok
    end

    test "a files.read deny on A's agent answers each tool as an unknown id", ctx do
      q = ctx.q.id
      f = ctx.file_q.id

      cases = [
        {"file_list", %{"project_id" => q}, q, "project_id"},
        {"file_search", %{"project_id" => q, "query" => "bypass"}, q, "project_id"},
        {"file_get_metadata", %{"file_id" => f}, f, "file_id"},
        {"file_get_text", %{"file_id" => f}, f, "file_id"},
        {"file_get_text", %{"file_id" => f, "binary" => true}, f, "file_id"}
      ]

      # Positive control: every call succeeds and carries the marker.
      for {tool, args, _id, _key} <- cases do
        assert {:ok, result} = call(ctx.a, tool, args)
        assert leaks?(result) or match?(%{data_base64: _}, result), "#{tool} control"
      end

      assert {:ok, %{data_base64: b64}} =
               call(ctx.a, "file_get_text", %{"file_id" => f, "binary" => true})

      assert Base.decode64!(b64) =~ @marker

      deny!({:agent, ctx.a.agent_id}, "files.read", ctx.q)

      for {tool, args, id, key} <- cases do
        random_id = Ecto.UUID.generate()
        random = call(ctx.a, tool, Map.put(args, key, random_id))
        denied = call(ctx.a, tool, args)
        assert {:error, _} = denied
        assert denied == random, "#{tool} (#{id})"
        refute leaks?(denied), tool
      end

      # P is still served.
      assert {:ok, %{files: [_]}} = call(ctx.a, "file_list", %{"project_id" => ctx.p.id})

      assert {:ok, _} =
               call(ctx.a, "file_get_text", %{"file_id" => ctx.file_p.id})

      # `file_add` shares the helper: a denied project refuses it too.
      assert {:error, %{code: :not_found}} =
               call(ctx.a, "file_add", %{
                 "project_id" => q,
                 "filename" => "x.txt",
                 "content_type" => "text/plain",
                 "data_base64" => Base.encode64("x")
               })
    end
  end

  # ── prototypes ────────────────────────────────────────────────────────

  describe "prototype latest, entry and serve" do
    test "a canvas.read deny on Q refuses latest and entry, and kills a grant minted before it",
         ctx do
      id = ctx.proto_id
      latest = get(session(ctx.m), "/proto/#{id}/latest/")
      assert latest.status == 302
      entry = get(session(ctx.m), "/proto/#{id}/1/")
      assert entry.status == 302
      [grant_url] = get_resp_header(entry, "location")
      served = get(build_conn(), grant_url)
      assert served.status == 200
      assert served.resp_body =~ @marker

      deny!(ctx.m, "canvas.read", ctx.q)

      random = get(session(ctx.m), "/proto/#{Ecto.UUID.generate()}/latest/")

      for conn <- [
            get(session(ctx.m), "/proto/#{id}/latest/"),
            get(session(ctx.m), "/proto/#{id}/1/"),
            get(build_conn(), grant_url)
          ] do
        assert {conn.status, conn.resp_body} == {random.status, random.resp_body}
        assert conn.status == 404
        refute conn.resp_body =~ @marker
      end
    end

    test "a chat.read deny on the prototype's space kills a grant minted before it", ctx do
      entry = get(session(ctx.m), "/proto/#{ctx.proto_id}/1/")
      [grant_url] = get_resp_header(entry, "location")
      assert get(build_conn(), grant_url).status == 200

      deny!(ctx.m, "chat.read", ctx.eq)

      conn = get(build_conn(), grant_url)
      assert conn.status == 404
      refute conn.resp_body =~ @marker
    end
  end

  # ── the two MCP point reads (orchestrator decision) ──────────────────

  describe "MCP task_get and task_list_canvases" do
    test "task_get of a task a tasks.read deny covers answers as an unknown task", ctx do
      assert {:ok, task} = call(ctx.a, "task_get", %{"task_id" => ctx.tq.id})
      assert leaks?(task)

      deny!({:agent, ctx.a.agent_id}, "tasks.read", ctx.q)

      random_id = Ecto.UUID.generate()
      random = call(ctx.a, "task_get", %{"task_id" => random_id})
      denied = call(ctx.a, "task_get", %{"task_id" => ctx.tq.id})
      assert normalize(denied, ctx.tq.id) == normalize(random, random_id)
      refute leaks?(denied)
    end

    test "task_list_canvases drops a canvas a canvas.read deny covers", ctx do
      for c <- [ctx.k, ctx.k2] do
        {:ok, _} =
          CanvasAttachments.attach_canvas(:system, ctx.tq.id, c.id,
            attached_by: %{kind: "agent", id: Ecto.UUID.generate()}
          )
      end

      assert {:ok, %{canvases: before}} =
               call(ctx.a, "task_list_canvases", %{"task_id" => ctx.tq.id})

      assert MapSet.new(before, & &1.canvas_id) == MapSet.new([ctx.k.id, ctx.k2.id])
      assert leaks?(before)

      deny!({:agent, ctx.a.agent_id}, "canvas.read", ctx.k)

      assert {:ok, %{canvases: after_deny} = result} =
               call(ctx.a, "task_list_canvases", %{"task_id" => ctx.tq.id})

      assert Enum.map(after_deny, & &1.canvas_id) == [ctx.k2.id]
      refute leaks?(result)
      refute inspect(result) =~ ctx.k.id
    end
  end

  # ── zero grants: today's behaviour ───────────────────────────────────

  describe "zero grants" do
    test "every external_world actor gets exactly today's answer on every surface", ctx do
      world = ExternalUserFixtures.external_world()
      in_a = attachment!(world.a, world.p_a_ext, nil, "world-a.txt", "world a")
      in_b = attachment!(world.b, world.p_b, nil, "world-b.txt", "world b")

      {:ok, wp} =
        Tasks.create_project(%{
          name: "bpb-world-#{System.unique_integer()}",
          org_id: world.org_a.id
        })

      wf = file!(wp, "world-file.txt", "world file")

      actors = [world.ext, world.ext2, world.int, world.m, world.n, world.other, ctx.m, ctx.g]

      for actor <- actors do
        scope = Scope.for_user(%{id: actor.id})
        refute Scope.has_grants?(scope)

        for att <- [in_a, in_b, ctx.att, ctx.att_k, ctx.att_p] do
          expected = if Chat.user_in_space?(actor.id, att.space_id), do: 200, else: 404
          assert get_att(session(actor), att.id).status == expected
        end

        blob_expected =
          cond do
            Tenancy.external_user?(%{id: actor.id}) -> 403
            Tenancy.member_of?(Platform.Accounts.get_user(actor.id), wp.org_id) -> 200
            true -> 403
          end

        assert get(session(actor), "/files/blob/#{wf.id}").status == blob_expected
      end

      for {tool, args} <- [
            {"file_list", %{"project_id" => ctx.q.id}},
            {"file_get_text", %{"file_id" => ctx.file_q.id}},
            {"attachment.get_inline", %{"attachment_id" => ctx.att.id}},
            {"task_get", %{"task_id" => ctx.tq.id}}
          ] do
        refute Scope.has_grants?(Scope.for_runtime(ctx.a))
        assert {:ok, _} = call(ctx.a, tool, args), tool
      end

      entry = get(session(ctx.m), "/proto/#{ctx.proto_id}/1/")
      assert entry.status == 302
    end
  end

  defmodule MemoryStub do
    @moduledoc false
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(_entries, _config), do: {:ok, 0}

    @impl true
    def search(_query, _opts, config), do: {:ok, Keyword.get(config, :search_results, [])}

    @impl true
    def delete(ids, _config), do: {:ok, length(ids)}

    @impl true
    def health(_c), do: :ok
  end
end
