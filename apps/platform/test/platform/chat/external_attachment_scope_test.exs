defmodule Platform.Chat.ExternalAttachmentScopeTest do
  @moduledoc """
  M9 (rbac-external-users) — attachments scope. Consumes M1
  (`org_memberships.external`) and M7 (`Tenancy.external_user?/1`,
  `Chat.ExternalScope`). Three build stages:

    * stage 1 — DOWNLOAD gate: `get_visible_attachment_for_principal/2` fail-closes
      the nil-space (legacy) branch for external principals; the space-bound
      membership gate and the internal/agent pass-through are unchanged.
    * stage 2 — WRITE gate: `post_message_with_attachments/3` refuses an external
      poster a space they are not a member of — a file only ever lands in an
      allowlisted (Globex) space — while internal/agent/system posters pass through.
    * stage 3 — PRESIGN gate: `ToolHandlers.upload_start/2` mints no URL and
      reserves no pending row for an out-of-scope user principal; size caps are
      principal-agnostic (the same `check_upload_size` path for all callers).

  The context functions are exercised directly (no M6 plug), so each assertion is
  a defense-in-depth property of the seam itself.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.Attachment
  alias Platform.Chat.Attachments.ToolHandlers
  alias Platform.Chat.Message
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures (mirroring external_reads_test.exs) ───────────────────────────

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{email: "u-#{n}@example.com", name: "User #{n}", oidc_sub: "oidc-#{n}"},
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    })
    |> Repo.insert!()
  end

  defp plain_membership!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp channel(attrs \\ %{}) do
    default = %{name: "Chan", slug: "chan-#{System.unique_integer([:positive])}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp add_user(space_id, user_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp add_agent(space_id, agent_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "agent",
        participant_id: agent_id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp post(space_id, participant_id, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content
      })

    msg
  end

  defp attachment(space_id, message_id) do
    {:ok, att} =
      Chat.create_attachment(%{
        space_id: space_id,
        message_id: message_id,
        filename: "f.bin",
        content_type: "application/octet-stream",
        byte_size: 3,
        storage_key: "k-#{System.unique_integer([:positive])}"
      })

    att
  end

  # A pre-backfill / canvas-orphan attachment: no space_id, no message anchor.
  defp legacy_attachment do
    {:ok, att} =
      Chat.create_attachment(%{
        filename: "legacy.bin",
        content_type: "application/octet-stream",
        byte_size: 3,
        storage_key: "legacy-#{System.unique_integer([:positive])}"
      })

    att
  end

  # The attrs a persisted upload (AttachmentStorage.persist_upload/3) yields.
  defp upload_attrs do
    %{
      filename: "f.bin",
      content_type: "application/octet-stream",
      byte_size: 3,
      storage_key: "chat/#{Date.utc_today()}/#{Ecto.UUID.generate()}-f.bin"
    }
  end

  defp count_messages(space_id),
    do: Repo.aggregate(from(m in Message, where: m.space_id == ^space_id), :count)

  defp count_attachments(space_id),
    do: Repo.aggregate(from(a in Attachment, where: a.space_id == ^space_id), :count)

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

  setup do
    # Storage root for the presign path (stage 3), matching tool_handlers_test.
    prev_root = Application.get_env(:platform, :chat_attachments_root)

    root =
      Path.join(System.tmp_dir!(), "platform-m9-att-scope-#{Ecto.UUID.generate()}")

    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      if prev_root, do: Application.put_env(:platform, :chat_attachments_root, prev_root)
    end)

    # EXT — external user, member of A only. INT — internal user, member of A.
    ext_user = create_user!()
    org = tenant_org!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext_user.id, org_id: org.id})

    int_user = create_user!()
    plain_membership!(int_user, org)

    a = channel()
    b = channel()

    p_a_ext = add_user(a.id, ext_user.id)
    _p_a_int = add_user(a.id, int_user.id)
    other = create_user!()
    p_b = add_user(b.id, other.id)

    msg_a = post(a.id, p_a_ext.id, "hi from A")
    msg_b = post(b.id, p_b.id, "hi from B")

    att_a = attachment(a.id, msg_a.id)
    att_b = attachment(b.id, msg_b.id)
    att_legacy = legacy_attachment()

    # AG — an agent runtime that IS a participant of A (regression principal).
    agent =
      Repo.insert!(%Agent{
        name: "m9-agent-#{System.unique_integer([:positive])}",
        slug: "m9-agent-#{System.unique_integer([:positive])}"
      })

    p_a_agent = add_agent(a.id, agent.id)
    agent_runtime = %AgentRuntime{agent_id: agent.id}

    %{
      ext_user: ext_user,
      int_user: int_user,
      a: a,
      b: b,
      p_a_ext: p_a_ext,
      p_b: p_b,
      att_a: att_a,
      att_b: att_b,
      att_legacy: att_legacy,
      agent_runtime: agent_runtime,
      p_a_agent: p_a_agent
    }
  end

  # ── Stage 1: download gate ─────────────────────────────────────────────────

  describe "stage 1 — download gate fail-closes the nil-space leak for external users" do
    test "external user: member attachment resolves, non-member is nil, legacy is nil", ctx do
      ext = {:user, ctx.ext_user.id}

      assert %{id: id} = Chat.get_visible_attachment_for_principal(ctx.att_a.id, ext)
      assert id == ctx.att_a.id

      # 404-shaped nil for a VALID id in a non-member space (no existence oracle).
      assert Chat.get_visible_attachment_for_principal(ctx.att_b.id, ext) == nil

      # THE LEAK, now closed: a nil-space legacy row is refused to an external user.
      assert Chat.get_visible_attachment_for_principal(ctx.att_legacy.id, ext) == nil
    end

    test "regression: internal user keeps legacy pass-through and member access", ctx do
      int = {:user, ctx.int_user.id}

      assert %{id: id} = Chat.get_visible_attachment_for_principal(ctx.att_a.id, int)
      assert id == ctx.att_a.id

      assert %{id: lid} = Chat.get_visible_attachment_for_principal(ctx.att_legacy.id, int)
      assert lid == ctx.att_legacy.id

      # The space-bound membership gate is unchanged: not a member of B → nil.
      assert Chat.get_visible_attachment_for_principal(ctx.att_b.id, int) == nil
    end

    test "regression: agent runtime keeps legacy pass-through and member access", ctx do
      ag = {:runtime, ctx.agent_runtime}

      assert %{id: id} = Chat.get_visible_attachment_for_principal(ctx.att_a.id, ag)
      assert id == ctx.att_a.id

      assert %{id: lid} = Chat.get_visible_attachment_for_principal(ctx.att_legacy.id, ag)
      assert lid == ctx.att_legacy.id
    end

    test "external_principal?/1 is true only for an external user principal", ctx do
      assert Chat.external_principal?({:user, ctx.ext_user.id})
      refute Chat.external_principal?({:user, ctx.int_user.id})
      refute Chat.external_principal?({:runtime, ctx.agent_runtime})
      refute Chat.external_principal?(:anything_else)
    end
  end

  # ── Stage 2: write gate ────────────────────────────────────────────────────

  describe "stage 2 — external uploads bind to allowlisted spaces" do
    test "external poster to member space A succeeds and stamps space_id A", ctx do
      assert {:ok, _msg, [att]} =
               Chat.post_message_with_attachments(
                 %{
                   space_id: ctx.a.id,
                   participant_id: ctx.p_a_ext.id,
                   content_type: "text",
                   content: "file"
                 },
                 [upload_attrs()],
                 poster_user_id: ctx.ext_user.id
               )

      assert att.space_id == ctx.a.id
      assert String.starts_with?(att.storage_key, "chat/")
    end

    test "external poster to non-member space B is refused; NO message/attachment row", ctx do
      msgs_before = count_messages(ctx.b.id)
      atts_before = count_attachments(ctx.b.id)

      assert {:error, :out_of_external_scope} =
               Chat.post_message_with_attachments(
                 %{
                   space_id: ctx.b.id,
                   participant_id: ctx.p_b.id,
                   content_type: "text",
                   content: "file"
                 },
                 [upload_attrs()],
                 poster_user_id: ctx.ext_user.id
               )

      assert count_messages(ctx.b.id) == msgs_before
      assert count_attachments(ctx.b.id) == atts_before
    end

    test "regression: internal poster to B (not a formal member) still succeeds", ctx do
      assert {:ok, _msg, [att]} =
               Chat.post_message_with_attachments(
                 %{
                   space_id: ctx.b.id,
                   participant_id: ctx.p_b.id,
                   content_type: "text",
                   content: "file"
                 },
                 [upload_attrs()],
                 poster_user_id: ctx.int_user.id
               )

      assert att.space_id == ctx.b.id
    end

    test "regression: nil poster (system/agent) still succeeds", ctx do
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

  # ── Stage 3: presign gate ──────────────────────────────────────────────────

  describe "stage 3 — presign refused for out-of-scope external user; caps principal-agnostic" do
    test "external user to non-member B: error, NO token, NO reserved row", ctx do
      before = count_attachments(ctx.b.id)

      assert {:error, %{recoverable: false}} =
               ToolHandlers.upload_start(presign_args(ctx.b.id), %{user_id: ctx.ext_user.id})

      assert count_attachments(ctx.b.id) == before
    end

    test "external user to member A: ok with an upload_url and a reserved pending row", ctx do
      before = count_attachments(ctx.a.id)

      assert {:ok, result} =
               ToolHandlers.upload_start(presign_args(ctx.a.id), %{user_id: ctx.ext_user.id})

      assert is_binary(result.upload_url)
      assert String.starts_with?(result.upload_url, "/chat/attachments/upload/")

      assert count_attachments(ctx.a.id) == before + 1
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

      # Both EXT and INT are members of A, so membership passes and the size cap
      # is what rejects — proving there is no external-specific limit.
      over = presign_args(ctx.a.id, %{"byte_size" => 5_000})

      assert {:error, ext_err} = ToolHandlers.upload_start(over, %{user_id: ctx.ext_user.id})
      assert {:error, int_err} = ToolHandlers.upload_start(over, %{user_id: ctx.int_user.id})

      assert ext_err.limit == 1_000
      assert int_err.limit == 1_000
      assert ext_err.error =~ "exceeds max"
      assert int_err.error =~ "exceeds max"
    end

    test "regression: agent context (no :user_id) is unaffected by the user-principal branch",
         ctx do
      # An agent participant of A using the loose agent context still authorizes.
      # The id must be a REAL participant of A: since task 01a0cbe0 a context
      # participant id is verified against the target space, so a random UUID
      # is (correctly) refused.
      assert {:ok, _result} =
               ToolHandlers.upload_start(
                 presign_args(ctx.a.id),
                 %{agent_participant_id: ctx.p_a_agent.id}
               )
    end
  end
end
