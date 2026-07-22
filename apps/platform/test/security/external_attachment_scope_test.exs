defmodule Platform.Security.ExternalAttachmentScopeTest do
  @moduledoc """
  M15 security suite — Stage 4 (S4): attachment download, write, and presign
  scope (M9), plus size-cap parity.

  Three vectors:

    * PART (a) DOWNLOAD ROUTE — driven through the real `/chat/attachments/:id`
      route (`ChatAttachmentController` + `AttachmentAuth`). An external user
      gets 200 for a member attachment, a uniform 404 (NOT 403 — the id is
      valid, no existence oracle) for an out-of-scope attachment, and 404 for a
      legacy nil-space attachment (the previously-unconditional pass-through is
      now closed for external principals). Internal sessions and agent bearers
      keep membership access and the legacy pass-through.
    * PART (b) WRITE SEAM — `post_message_with_attachments/3` refuses an
      external poster a space they are not a member of; internal/nil posters
      pass through.
    * PART (c) PRESIGN SEAM — `ToolHandlers.upload_start/2` mints no URL and
      reserves no pending row for an out-of-scope external user; the size cap is
      principal-agnostic (same `check_upload_size/1` path for external + internal).

  Binds to M9 shipped: `Chat.get_visible_attachment_for_principal/2`,
  `Chat.external_principal?/1`, `ensure_external_upload_allowed/2` →
  `{:error, :out_of_external_scope}`, `post_message_with_attachments/3`
  `:poster_user_id`, `ToolHandlers.upload_start/2`, `check_upload_size/1`,
  `upload_max_bytes/0`.
  """
  use PlatformWeb.ConnCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.Attachment
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.Attachments.ToolHandlers
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Repo

  setup %{conn: conn} do
    # Storage root for real downloadable bytes + the presign path.
    prev_root = Application.get_env(:platform, :chat_attachments_root)
    root = Path.join(System.tmp_dir!(), "m15-s4-att-#{Ecto.UUID.generate()}")
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      if prev_root, do: Application.put_env(:platform, :chat_attachments_root, prev_root)
    end)

    # ConnCase does not drain the supervised AttentionRouter the way DataCase
    # does; post_message here would otherwise risk DBConnection-owner noise on
    # exit. Mirror DataCase's drain for the GenServers that touch Repo.
    for name <- [Platform.Chat.AttentionRouter, Platform.Chat.ContextPlane] do
      if pid = Process.whereis(name), do: Sandbox.allow(Repo, self(), pid)
    end

    on_exit(fn ->
      for name <- [Platform.Chat.AttentionRouter, Platform.Chat.ContextPlane] do
        if pid = Process.whereis(name) do
          try do
            GenServer.call(pid, :__drain__, 2_000)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    w = World.external_world()

    # INT is also a member of B for the download-route regression (an internal
    # member keeps 200 on B while the external non-member is 404'd).
    World.add_user!(w.b.id, w.int.id)

    # AG — an agent runtime that IS a participant of B (regression bearer).
    agent =
      Repo.insert!(%Agent{
        name: "m15-ag-#{System.unique_integer([:positive])}",
        slug: "m15-ag-#{System.unique_integer([:positive])}"
      })

    World.add_agent!(w.b.id, agent.id)
    ag_token = "m15-rt-token-#{System.unique_integer([:positive])}"
    ag_owner = World.create_user!()

    Repo.insert!(%AgentRuntime{
      agent_id: agent.id,
      owner_user_id: ag_owner.id,
      status: "active",
      auth_token_hash: AgentRuntime.hash_token(ag_token),
      runtime_id: "m15-rt-#{System.unique_integer([:positive])}"
    })

    # Servable attachments (real bytes on disk via persist_upload).
    msg_a = World.post!(w.a.id, w.p_a_ext.id, "hi from A")
    msg_b = World.post!(w.b.id, w.p_b.id, "hi from B")
    att_a = servable_attachment!(w.a.id, msg_a.id, "alpha-bytes")
    att_b = servable_attachment!(w.b.id, msg_b.id, "bravo-bytes")
    att_legacy = servable_legacy_attachment!("legacy-bytes")

    Map.merge(w, %{
      conn: conn,
      agent: agent,
      ag_token: ag_token,
      att_a: att_a,
      att_b: att_b,
      att_legacy: att_legacy
    })
  end

  # ── PART (a): download route ───────────────────────────────────────────

  describe "download route — external user" do
    test "member attachment (A) → 200 bytes", ctx do
      conn = ctx.conn |> World.login(ctx.ext.id) |> get(~p"/chat/attachments/#{ctx.att_a.id}")
      assert response(conn, 200) == "alpha-bytes"
    end

    test "out-of-scope attachment (B) → 404 (NOT 403, valid id, no existence oracle)", ctx do
      conn = ctx.conn |> World.login(ctx.ext.id) |> get(~p"/chat/attachments/#{ctx.att_b.id}")
      assert response(conn, 404) =~ "Not found"
    end

    test "legacy nil-space attachment → 404 (leak closed for external)", ctx do
      conn =
        ctx.conn |> World.login(ctx.ext.id) |> get(~p"/chat/attachments/#{ctx.att_legacy.id}")

      assert response(conn, 404) =~ "Not found"
    end
  end

  describe "download route — internal + agent regression" do
    test "internal member session: B → 200, legacy → served", ctx do
      conn_b = ctx.conn |> World.login(ctx.int.id) |> get(~p"/chat/attachments/#{ctx.att_b.id}")
      assert response(conn_b, 200) == "bravo-bytes"

      conn_l =
        Phoenix.ConnTest.build_conn()
        |> World.login(ctx.int.id)
        |> get(~p"/chat/attachments/#{ctx.att_legacy.id}")

      assert response(conn_l, 200) == "legacy-bytes"
    end

    test "agent bearer whose agent is a member of B: B → 200, legacy → served", ctx do
      conn_b =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> ctx.ag_token)
        |> get(~p"/chat/attachments/#{ctx.att_b.id}")

      assert response(conn_b, 200) == "bravo-bytes"

      conn_l =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.ag_token)
        |> get(~p"/chat/attachments/#{ctx.att_legacy.id}")

      assert response(conn_l, 200) == "legacy-bytes"
    end
  end

  describe "external_principal?/1" do
    test "true only for an external user principal", ctx do
      assert Chat.external_principal?({:user, ctx.ext.id})
      refute Chat.external_principal?({:user, ctx.int.id})
      refute Chat.external_principal?(:anything_else)
    end
  end

  # ── PART (b): write seam ───────────────────────────────────────────────

  describe "write seam — external uploads bind to allowlisted spaces" do
    test "external poster to non-member B → {:error, :out_of_external_scope}, NO rows", ctx do
      msgs_before = World.message_count(ctx.b.id)
      atts_before = World.attachment_count(ctx.b.id)

      assert {:error, :out_of_external_scope} =
               Chat.post_message_with_attachments(
                 %{
                   space_id: ctx.b.id,
                   participant_id: ctx.p_b.id,
                   content_type: "text",
                   content: "file"
                 },
                 [upload_attrs()],
                 poster_user_id: ctx.ext.id
               )

      assert World.message_count(ctx.b.id) == msgs_before
      assert World.attachment_count(ctx.b.id) == atts_before
    end

    test "external poster to member A → {:ok, msg, [att]} stamped with space A", ctx do
      assert {:ok, _msg, [att]} =
               Chat.post_message_with_attachments(
                 %{
                   space_id: ctx.a.id,
                   participant_id: ctx.p_a_ext.id,
                   content_type: "text",
                   content: "file"
                 },
                 [upload_attrs()],
                 poster_user_id: ctx.ext.id
               )

      assert att.space_id == ctx.a.id
    end

    test "regression: internal poster to B and nil (system) poster still succeed", ctx do
      assert {:ok, _msg, [att]} =
               Chat.post_message_with_attachments(
                 %{
                   space_id: ctx.b.id,
                   participant_id: ctx.p_b.id,
                   content_type: "text",
                   content: "file"
                 },
                 [upload_attrs()],
                 poster_user_id: ctx.int.id
               )

      assert att.space_id == ctx.b.id

      assert {:ok, _msg, [_att]} =
               Chat.post_message_with_attachments(
                 %{
                   space_id: ctx.b.id,
                   participant_id: ctx.p_b.id,
                   content_type: "text",
                   content: "file"
                 },
                 [upload_attrs()],
                 poster_user_id: nil
               )
    end
  end

  # ── PART (c): presign seam + size parity ───────────────────────────────

  describe "presign seam" do
    test "external user to non-member B → error (recoverable: false), NO reserved row", ctx do
      before = World.attachment_count(ctx.b.id)

      assert {:error, %{recoverable: false}} =
               ToolHandlers.upload_start(presign_args(ctx.b.id), %{user_id: ctx.ext.id})

      assert World.attachment_count(ctx.b.id) == before
    end

    test "external user to member A → {:ok, url} with a reserved pending row", ctx do
      before = World.attachment_count(ctx.a.id)

      assert {:ok, result} =
               ToolHandlers.upload_start(presign_args(ctx.a.id), %{user_id: ctx.ext.id})

      assert is_binary(result.upload_url)
      assert String.starts_with?(result.upload_url, "/chat/attachments/upload/")
      assert World.attachment_count(ctx.a.id) == before + 1
      assert Repo.get!(Attachment, result.id).state == "pending"
    end

    test "over-cap upload rejected by the SAME check_upload_size path for both principals", ctx do
      prev = Application.get_env(:platform, :upload_max_bytes)
      Application.put_env(:platform, :upload_max_bytes, 1_000)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:platform, :upload_max_bytes, prev),
          else: Application.delete_env(:platform, :upload_max_bytes)
      end)

      # Both EXT and INT are members of A → membership passes and the cap is
      # what rejects, proving there is no external-specific limit.
      over = presign_args(ctx.a.id, %{"byte_size" => 5_000})

      assert {:error, ext_err} = ToolHandlers.upload_start(over, %{user_id: ctx.ext.id})
      assert {:error, int_err} = ToolHandlers.upload_start(over, %{user_id: ctx.int.id})

      assert ext_err.limit == 1_000
      assert int_err.limit == 1_000
      assert ext_err.error =~ "exceeds max"
      assert int_err.error =~ "exceeds max"
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp servable_attachment!(space_id, message_id, content) do
    source =
      Path.join(System.tmp_dir!(), "m15-src-#{System.unique_integer([:positive])}.txt")

    File.write!(source, content)
    {:ok, stored} = AttachmentStorage.persist_upload(source, "f.txt", "text/plain")
    File.rm(source)

    {:ok, att} =
      Chat.create_attachment(
        stored
        |> Map.put(:message_id, message_id)
        |> Map.put(:space_id, space_id)
      )

    att
  end

  defp servable_legacy_attachment!(content) do
    source =
      Path.join(System.tmp_dir!(), "m15-legacy-#{System.unique_integer([:positive])}.txt")

    File.write!(source, content)
    {:ok, stored} = AttachmentStorage.persist_upload(source, "legacy.txt", "text/plain")
    File.rm(source)

    {:ok, att} = Chat.create_attachment(stored)
    att
  end

  defp upload_attrs do
    %{
      filename: "f.bin",
      content_type: "application/octet-stream",
      byte_size: 3,
      storage_key: "chat/#{Date.utc_today()}/#{Ecto.UUID.generate()}-f.bin"
    }
  end

  defp presign_args(space_id, overrides \\ %{}) do
    Map.merge(
      %{
        "space_id" => space_id,
        "filename" => "x.pdf",
        "content_type" => "application/pdf",
        "byte_size" => 1024
      },
      overrides
    )
  end
end
