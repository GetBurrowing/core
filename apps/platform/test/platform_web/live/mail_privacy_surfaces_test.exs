defmodule PlatformWeb.MailPrivacySurfacesTest do
  @moduledoc """
  Every chat, search and file read path that can carry mail, gated on
  mailbox ownership (task 01a1ea5b stage 2). `Platform.Mail.Ownership`'s
  moduledoc lists these consumers; each has a test here, and each test proves
  both directions: the mailbox's reader (the owner, or a granted agent) sees
  the mail, a member who joined the inbound space (or an ungranted agent who
  is a participant) does not.

  The seed: personal mailbox P owned by Owner, inbound channel C bound to it,
  one mail post in C carrying a unique body token; Owner and Other both
  joined C. Agent A is granted P, agent B is not; both are in C. A file was
  made from P's mail through "Add to files".

  async: false — flips `:mail_enabled`, the Files storage root and the
  memory service in application env.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures
  import Platform.Test.MailPrivacyFixtures

  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Federation.ToolSurface
  alias Platform.Files
  alias Platform.Files.Browser
  alias Platform.Mail.{Mailbox, Ownership}
  alias Platform.Org.Wiki.Search
  alias Platform.Repo

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
    def health(_config), do: :ok
  end

  defp memory!(results) do
    Application.put_env(:platform, :memory_service, provider: MemoryStub, search_results: results)
  end

  setup do
    previous_mail = Application.fetch_env(:platform, :mail_enabled)
    Application.put_env(:platform, :mail_enabled, true)
    root = Platform.TestTemp.path("mail-privacy-surfaces")
    File.mkdir_p!(root)
    previous_root = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)
    previous_memory = Application.get_env(:platform, :memory_service, [])
    memory!([])

    on_exit(fn ->
      case previous_mail do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end

      File.rm_rf!(root)

      if previous_root,
        do: Application.put_env(:platform, :chat_attachments_root, previous_root),
        else: Application.delete_env(:platform, :chat_attachments_root)

      Application.put_env(:platform, :memory_service, previous_memory)
    end)

    org_id = acme_org_id()
    admin = user!("admin") |> member!(org_id, "admin")
    owner = user!("owner") |> member!(org_id)
    other = user!("other") |> member!(org_id)
    personal = personal!(admin, account!(admin, org_id), owner)

    space = channel!(org_id)
    bind_inbound_space!(personal, space)
    poster = join_user!(space, owner)
    join_user!(space, other)

    token = "bodyp#{unique()}marker"
    message = mail_post!(personal, space, poster, "BODY-P-1 #{token} quarterly")

    granted = agent!("granted")
    ungranted = agent!("ungranted")
    join_agent!(space, granted)
    join_agent!(space, ungranted)
    granted_rt = runtime!(granted, owner)
    ungranted_rt = runtime!(ungranted, owner)
    {:ok, _} = Ownership.grant(owner, personal, {:agent, granted.id})

    %{
      org_id: org_id,
      admin: admin,
      owner: owner,
      other: other,
      personal: personal,
      space: space,
      token: token,
      message: message,
      granted: granted,
      ungranted: ungranted,
      granted_ctx: %{agent_id: granted.id, runtime_id: granted_rt.runtime_id},
      ungranted_ctx: %{agent_id: ungranted.id, runtime_id: ungranted_rt.runtime_id}
    }
  end

  defp login(conn, user), do: init_test_session(conn, current_user_id: user.id)
  defp lv_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # ── Chat ────────────────────────────────────────────────────────────────

  describe "chat" do
    test "opening the inbound space: the owner reads the post, a joined member is turned away",
         %{conn: conn} = ctx do
      {:ok, _view, html} = live(login(conn, ctx.owner), ~p"/chat/#{ctx.space.id}")
      assert html =~ ctx.token

      denied = live(login(conn, ctx.other), ~p"/chat/#{ctx.space.id}")
      assert {:error, {:live_redirect, %{to: "/chat"}}} = denied
      {:ok, _view, html} = follow_redirect(denied, login(conn, ctx.other), "/chat")
      refute html =~ ctx.token
    end

    test "the chat list excerpt: the owner's list carries it, the member's does not",
         %{conn: conn} = ctx do
      {:ok, view, _} = live(login(conn, ctx.owner), ~p"/chat")
      assert lv_assigns(view).list_excerpts[ctx.space.id].content =~ ctx.token

      {:ok, view, html} = live(login(conn, ctx.other), ~p"/chat")
      refute Map.has_key?(lv_assigns(view).list_excerpts, ctx.space.id)
      refute html =~ ctx.token
    end

    test "chat search in an open space stops finding mail on the next search after a revoke",
         %{conn: conn} = ctx do
      shared = shared!(ctx.admin, account!(ctx.admin, ctx.org_id), [ctx.other])
      space = channel!(ctx.org_id)
      bind_inbound_space!(shared, space)
      poster = join_user!(space, ctx.other)
      token = "sharedtoken#{unique()}"
      mail_post!(shared, space, poster, "shared #{token}")

      {:ok, view, _} = live(login(conn, ctx.other), ~p"/chat/#{space.id}")
      render_hook(view, "search_submit", %{"search" => %{"query" => token}})
      assert [_ | _] = lv_assigns(view).search_results

      {:ok, _} = Ownership.revoke(ctx.admin, shared, {:user, ctx.other.id})
      render_hook(view, "search_submit", %{"search" => %{"query" => token}})
      assert lv_assigns(view).search_results == []
    end

    test "the mobile API's space authorization", ctx do
      assert {:ok, _, _} =
               Platform.Mobile.AppEntities.authorize_space(
                 Accounts.get_user(ctx.owner.id),
                 ctx.space.id
               )

      assert {:error, :forbidden} =
               Platform.Mobile.AppEntities.authorize_space(
                 Accounts.get_user(ctx.other.id),
                 ctx.space.id
               )
    end

    test "an inbox row for a mail post is emitted to the owner and refused for the member", ctx do
      item = fn user ->
        Platform.Inbox.emit(%{
          user_id: user.id,
          kind: "chat_mention",
          source_type: "chat_message",
          source_id: ctx.message.id,
          title: "Mention",
          url: "/chat/#{ctx.space.id}"
        })
      end

      assert {:ok, _} = item.(ctx.owner)
      assert {:error, :denied} = item.(ctx.other)
    end

    test "the Historian / activity digest never carries a mail-bound space's messages", ctx do
      plain = channel!(ctx.org_id)
      p = join_user!(plain, ctx.owner)
      ordinary = post!(plain, p, "ordinary chat #{ctx.token}")
      since = DateTime.add(DateTime.utc_now(), -3600, :second)
      ids = Enum.map(Platform.Chat.list_messages_since(since), & &1.id)

      # Positive control: the digest does read ordinary channels.
      assert ordinary.id in ids
      refute ctx.message.id in ids
    end

    test "a federation peer relay never carries a mail post", ctx do
      alias Platform.Federation.Peers.Relay
      plain = channel!(ctx.org_id)
      ordinary = post!(plain, join_user!(plain, ctx.owner), "ordinary")
      assert Relay.relayable?(ordinary)

      mail = %{ctx.message | metadata: %{"source" => "email_inbound"}}
      refute Relay.relayable?(mail)
    end

    test "meeting synthesis citations of a mail post", ctx do
      alias Platform.Meetings.Synthesis.Visibility
      assert Visibility.readable_by?(ctx.owner.id, {:message, ctx.message.id})
      refute Visibility.readable_by?(ctx.other.id, {:message, ctx.message.id})

      row = Repo.get_by!(Platform.Mail.InboundMessage, chat_message_id: ctx.message.id)
      assert Visibility.readable_by?(ctx.owner.id, {:mail, row.id})
      refute Visibility.readable_by?(ctx.other.id, {:mail, row.id})
    end
  end

  # ── Agent chat tools ────────────────────────────────────────────────────

  describe "agent chat tools" do
    test "space_get_messages, space_search_messages, space_get_context: granted reads, ungranted is refused",
         ctx do
      args = %{"space_id" => ctx.space.id, "query" => ctx.token}

      assert {:ok, read} = ToolSurface.execute("space_get_messages", args, ctx.granted_ctx)
      assert inspect(read) =~ ctx.token
      assert {:ok, found} = ToolSurface.execute("space_search_messages", args, ctx.granted_ctx)
      assert inspect(found) =~ ctx.token
      assert {:ok, _} = ToolSurface.execute("space_get_context", args, ctx.granted_ctx)

      for tool <- ~w(space_get_messages space_search_messages space_get_context),
          context <- [ctx.ungranted_ctx, %{agent_id: ctx.ungranted.id}] do
        assert {:error, denial} = ToolSurface.execute(tool, args, context)
        refute inspect(denial) =~ ctx.token
      end
    end

    test "waking an agent in the inbound space (mention summon, attention routing)", ctx do
      alias Platform.Access.AgentWake
      resource = {:space, ctx.space.id}

      assert AgentWake.denied([ctx.granted.id, ctx.ungranted.id], "chat.read", resource) ==
               MapSet.new([ctx.ungranted.id])

      assert AgentWake.check_agent(ctx.granted.id, nil, "chat.read", resource) == :ok

      assert AgentWake.check_agent(ctx.ungranted.id, nil, "chat.read", resource) ==
               {:error, :denied}
    end

    test "space_list marks the inbound space restricted only for the ungranted agent", ctx do
      row = fn context ->
        {:ok, %{spaces: rows}} = ToolSurface.execute("space_list", %{}, context)
        Enum.find(rows, &(&1.id == ctx.space.id))
      end

      refute Map.get(row.(ctx.granted_ctx), :restricted)
      assert row.(ctx.ungranted_ctx).restricted
    end
  end

  # ── Org memory search ───────────────────────────────────────────────────

  describe "memory search" do
    setup do
      Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)
      :ok
    end

    test "memory_search message hits: the granted agent finds the post, the ungranted one does not",
         ctx do
      hits = fn agent, scope ->
        {:ok, %{results: results}} =
          Search.search(ctx.token, agent: agent, source: :message, access_scope: scope)

        Enum.filter(results, &(&1.source == "message"))
      end

      assert [%{id: id}] = hits.(ctx.granted, nil)
      assert id == ctx.message.id
      assert hits.(ctx.ungranted, nil) == []

      granted_scope =
        Scope.for_runtime(Repo.get_by!(Platform.Agents.AgentRuntime, agent_id: ctx.granted.id))

      ungranted_scope =
        Scope.for_runtime(Repo.get_by!(Platform.Agents.AgentRuntime, agent_id: ctx.ungranted.id))

      assert [_] = hits.(ctx.granted, granted_scope)
      assert hits.(ctx.ungranted, ungranted_scope) == []
    end

    test "the Org Memory pane (a person, agent: nil) returns no message hit to anyone",
         %{conn: conn} = ctx do
      for user <- [ctx.owner, ctx.other] do
        scope = Scope.for_user(Accounts.get_user(user.id))

        {:ok, %{results: results}} =
          Search.search(ctx.token, agent: nil, source: :message, access_scope: scope)

        assert results == []
      end

      {:ok, view, _} = live(login(conn, ctx.other), ~p"/org_memory")
      refute render(view) =~ ctx.token
    end
  end

  # ── Files ───────────────────────────────────────────────────────────────

  describe "files made from mail" do
    setup ctx do
      {:ok, project} =
        Platform.Tasks.create_project(%{name: "Mp surf #{unique()}", org_id: ctx.org_id})

      row = Repo.get_by!(Platform.Mail.InboundMessage, chat_message_id: ctx.message.id)
      {:ok, _, file} = Mailbox.add_to_files(ctx.owner, row.id, project.id)
      {:ok, _} = Files.upsert_extracted_text(file.id, "extracted #{ctx.token}", nil)
      {:ok, file} = Files.update_ingest_status(file, "ingested")

      {:ok, plain} =
        Files.create_file(%{
          project_id: project.id,
          org_id: project.org_id,
          name: "plain-#{unique()}.txt",
          original_filename: "plain.txt",
          content_type: "text/plain",
          byte_size: 5,
          storage_key: "files/#{project.id}/#{Ecto.UUID.generate()}/plain.txt",
          content_hash: "plain-#{unique()}",
          ingest_status: "ingested"
        })

      %{project: project, mail_file: file, plain: plain}
    end

    test "FilesLive project list and file open", %{conn: conn} = ctx do
      {:ok, view, html} = live(login(conn, ctx.owner), ~p"/files/#{ctx.project.id}")
      assert html =~ ctx.mail_file.name
      assert Enum.any?(lv_assigns(view).files, &(&1.id == ctx.mail_file.id))

      {:ok, view, _} =
        live(login(conn, ctx.owner), ~p"/files/#{ctx.project.id}?file=#{ctx.mail_file.id}")

      assert %{id: id} = lv_assigns(view).selected_file
      assert id == ctx.mail_file.id

      {:ok, view, html} = live(login(conn, ctx.other), ~p"/files/#{ctx.project.id}")
      refute html =~ ctx.mail_file.name
      assert html =~ ctx.plain.name
      refute Enum.any?(lv_assigns(view).files, &(&1.id == ctx.mail_file.id))

      case live(login(conn, ctx.other), ~p"/files/#{ctx.project.id}?file=#{ctx.mail_file.id}") do
        {:ok, view, html} ->
          refute html =~ ctx.token
          refute match?(%{id: _}, lv_assigns(view).selected_file)

        {:error, {_redirect, _}} ->
          :ok
      end
    end

    test "the Files browser: recents, search and a direct fetch", ctx do
      viewer = fn user ->
        %{
          user: Accounts.get_user(user.id),
          access_scope: Scope.for_user(Accounts.get_user(user.id))
        }
      end

      owner = viewer.(ctx.owner)
      other = viewer.(ctx.other)
      ids = fn items -> Enum.map(items, & &1.id) end

      assert ctx.mail_file.id in ids.(Browser.recents(owner).items)
      refute ctx.mail_file.id in ids.(Browser.recents(other).items)
      assert ctx.plain.id in ids.(Browser.recents(other).items)
      assert ctx.mail_file.id in ids.(Browser.search(owner, ctx.mail_file.name))
      refute ctx.mail_file.id in ids.(Browser.search(other, ctx.mail_file.name))
      assert {:ok, _} = Browser.fetch_source(owner, {:file, ctx.mail_file.id})
      assert {:error, :not_found} = Browser.fetch_source(other, {:file, ctx.mail_file.id})
      assert {:ok, items} = Browser.in_project(owner, ctx.project.id)
      assert ctx.mail_file.id in ids.(items)
      assert {:ok, items} = Browser.in_project(other, ctx.project.id)
      refute ctx.mail_file.id in ids.(items)
    end

    test "the file download route", %{conn: conn} = ctx do
      assert get(login(conn, ctx.owner), "/files/blob/#{ctx.mail_file.id}").status == 200
      assert get(login(conn, ctx.other), "/files/blob/#{ctx.mail_file.id}").status == 404
    end

    test "file_list, file_get_metadata, file_get_text: granted reads, ungranted gets not-found",
         ctx do
      list = fn context ->
        {:ok, %{files: files, total: total}} =
          ToolSurface.execute("file_list", %{"project_id" => ctx.project.id}, context)

        {Enum.map(files, & &1.id), total}
      end

      {granted_ids, granted_total} = list.(ctx.granted_ctx)
      assert ctx.mail_file.id in granted_ids and granted_total == 2
      {ungranted_ids, ungranted_total} = list.(ctx.ungranted_ctx)
      refute ctx.mail_file.id in ungranted_ids
      assert ctx.plain.id in ungranted_ids and ungranted_total == 1

      args = %{"file_id" => ctx.mail_file.id}
      assert {:ok, _} = ToolSurface.execute("file_get_metadata", args, ctx.granted_ctx)
      assert {:ok, text} = ToolSurface.execute("file_get_text", args, ctx.granted_ctx)
      assert inspect(text) =~ ctx.token

      for tool <- ~w(file_get_metadata file_get_text) do
        assert {:error, denial} = ToolSurface.execute(tool, args, ctx.ungranted_ctx)
        refute inspect(denial) =~ ctx.token

        assert {:error, unknown} =
                 ToolSurface.execute(
                   tool,
                   %{"file_id" => Ecto.UUID.generate()},
                   ctx.ungranted_ctx
                 )

        # The same answer as an unknown file id: not an existence oracle.
        assert denial == unknown
      end

      assert {:error, _} =
               ToolSurface.execute(
                 "file_get_text",
                 Map.put(args, "binary", true),
                 ctx.ungranted_ctx
               )
    end

    test "file_search drops a hit on the mail file for the ungranted agent", ctx do
      memory!([
        %{entry_id: ctx.mail_file.id, score: 0.9, content: "snippet #{ctx.token}"},
        %{entry_id: ctx.plain.id, score: 0.5, content: "plain"}
      ])

      search = fn context ->
        {:ok, %{hits: hits}} =
          ToolSurface.execute(
            "file_search",
            %{"project_id" => ctx.project.id, "query" => "quarterly"},
            context
          )

        Enum.map(hits, & &1.file_id)
      end

      assert ctx.mail_file.id in search.(ctx.granted_ctx)
      ungranted = search.(ctx.ungranted_ctx)
      refute ctx.mail_file.id in ungranted
      assert ctx.plain.id in ungranted
    end

    test "FilesLive semantic search drops a hit on the mail file for a non-reader",
         %{conn: conn} = ctx do
      memory!([
        %{"id" => ctx.mail_file.id, "score" => 0.9, "content" => "snippet #{ctx.token}"},
        %{"id" => ctx.plain.id, "score" => 0.5, "content" => "plain"}
      ])

      {:ok, view, _} = live(login(conn, ctx.owner), ~p"/files/#{ctx.project.id}")
      render_hook(view, "semantic_search", %{"query" => "quarterly"})
      assert render(view) =~ ctx.token

      {:ok, view, _} = live(login(conn, ctx.other), ~p"/files/#{ctx.project.id}")
      render_hook(view, "semantic_search", %{"query" => "quarterly"})
      refute render(view) =~ ctx.token
      assert [%{"id" => id}] = lv_assigns(view).semantic_results
      assert id == ctx.plain.id
    end
  end
end
