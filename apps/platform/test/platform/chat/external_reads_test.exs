defmodule Platform.Chat.ExternalReadsTest do
  @moduledoc """
  Stack member 7 (rbac-external-users), stages 2-4 — the `:scope` opt threaded
  through the Chat read paths (spaces, messages/search, attachments/canvases).

  The property under test is defense in depth: given the external caller, each
  read returns ONLY allowlisted rows (the caller's participant spaces) even
  though no M6 plug ran — the context functions are called directly. A nil /
  internal scope is pass-through (regression guard).
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.ExternalScope
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  # ── Helpers ────────────────────────────────────────────────────────────

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
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  defp plain_membership!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp channel(attrs \\ %{}) do
    default = %{
      name: "Chan",
      slug: "chan-#{System.unique_integer([:positive])}",
      kind: "channel"
    }

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

  defp canvas(space_id, created_by) do
    {:ok, c} =
      Chat.create_canvas(%{
        "space_id" => space_id,
        "created_by" => created_by,
        "title" => "Doc"
      })

    c
  end

  # Two channels A (external user is a member) and B (they are not), each with
  # a message containing "quarterly", plus an unrelated channel C.
  setup do
    ext_user = create_user!()
    org = tenant_org!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext_user.id, org_id: org.id})

    int_user = create_user!()
    plain_membership!(int_user, org)

    a = channel()
    b = channel()
    c = channel()

    p_a = add_user(a.id, ext_user.id)
    other = create_user!()
    p_b = add_user(b.id, other.id)
    _p_c = add_user(c.id, other.id)

    msg_a = post(a.id, p_a.id, "quarterly numbers for A")
    msg_b = post(b.id, p_b.id, "quarterly numbers for B")

    ext = ExternalScope.for_user(ext_user.id)
    int = ExternalScope.for_user(int_user.id)

    %{
      ext_user: ext_user,
      int_user: int_user,
      ext: ext,
      int: int,
      a: a,
      b: b,
      c: c,
      p_a: p_a,
      p_b: p_b,
      msg_a: msg_a,
      msg_b: msg_b
    }
  end

  # ── Stage 2: space reads ───────────────────────────────────────────────

  describe "space reads (stage 2)" do
    test "list_spaces(kind: channel, scope: ext) returns only member channels", ctx do
      ids = Chat.list_spaces(kind: "channel", scope: ctx.ext) |> Enum.map(& &1.id)
      assert ctx.a.id in ids
      refute ctx.b.id in ids
      refute ctx.c.id in ids
    end

    test "get_space gates on membership under external scope", ctx do
      assert %{id: id} = Chat.get_space(ctx.a.id, scope: ctx.ext)
      assert id == ctx.a.id
      assert Chat.get_space(ctx.b.id, scope: ctx.ext) == nil
    end

    test "get_space_by_slug resolves out-of-scope slug to nil (404-shaped)", ctx do
      assert %{id: id} = Chat.get_space_by_slug(ctx.a.slug, scope: ctx.ext)
      assert id == ctx.a.id
      assert Chat.get_space_by_slug(ctx.b.slug, scope: ctx.ext) == nil
    end

    test "list_user_conversations is naturally scoped and belt-and-suspenders", ctx do
      ids = Chat.list_user_conversations(ctx.ext_user.id, scope: ctx.ext) |> Enum.map(& &1.id)
      assert ids == [ctx.a.id]
    end

    test "regression: internal scope returns all channels, get_space(B) is B", ctx do
      ids = Chat.list_spaces(kind: "channel", scope: ctx.int) |> Enum.map(& &1.id)
      assert ctx.a.id in ids and ctx.b.id in ids and ctx.c.id in ids
      assert %{id: bid} = Chat.get_space(ctx.b.id, scope: ctx.int)
      assert bid == ctx.b.id
      assert %{id: _} = Chat.get_space_by_slug(ctx.b.slug, scope: ctx.int)
    end

    test "regression: no scope returns all channels, get_space(B) is B", ctx do
      ids = Chat.list_spaces(kind: "channel") |> Enum.map(& &1.id)
      assert ctx.a.id in ids and ctx.b.id in ids and ctx.c.id in ids
      assert %{id: bid} = Chat.get_space(ctx.b.id)
      assert bid == ctx.b.id
    end

    test "for_user(internal) is not external", ctx do
      assert ctx.int.external? == false
    end
  end

  # ── Stage 3: message and search reads ──────────────────────────────────

  describe "message and search reads (stage 3)" do
    test "list_messages of a non-member space is empty under external scope", ctx do
      assert Chat.list_messages(ctx.b.id, scope: ctx.ext) == []
      assert [%{id: id}] = Chat.list_messages(ctx.a.id, scope: ctx.ext)
      assert id == ctx.msg_a.id
    end

    test "get_message gates on space membership", ctx do
      assert Chat.get_message(ctx.msg_b.id, scope: ctx.ext) == nil
      assert %{id: id} = Chat.get_message(ctx.msg_a.id, scope: ctx.ext)
      assert id == ctx.msg_a.id
    end

    test "get_messages_by_ids drops out-of-scope ids silently", ctx do
      ids =
        Chat.get_messages_by_ids([ctx.msg_a.id, ctx.msg_b.id], scope: ctx.ext)
        |> Enum.map(& &1.id)

      assert ids == [ctx.msg_a.id]
    end

    test "has_more_messages sentinels cannot probe a non-member space", ctx do
      refute Chat.has_more_messages_before?(ctx.b.id, before_id: ctx.msg_b.id, scope: ctx.ext)

      refute Chat.has_more_messages_after?(ctx.b.id,
               after_id: "00000000-0000-0000-0000-000000000000",
               scope: ctx.ext
             )
    end

    test "search_messages of a non-member space is empty (filtered pre-headline)", ctx do
      assert Chat.search_messages(ctx.b.id, "quarterly", scope: ctx.ext) == []
      assert [hit] = Chat.search_messages(ctx.a.id, "quarterly", scope: ctx.ext)
      assert hit.id == ctx.msg_a.id
      assert hit.search_headline =~ "quarterly"
    end

    test "regression: internal/no scope returns B's messages and search hits", ctx do
      assert [%{id: id}] = Chat.list_messages(ctx.b.id, scope: ctx.int)
      assert id == ctx.msg_b.id
      assert [%{id: ^id}] = Chat.list_messages(ctx.b.id)
      assert [hit] = Chat.search_messages(ctx.b.id, "quarterly", scope: ctx.int)
      assert hit.id == ctx.msg_b.id
      assert %{id: ^id} = Chat.get_message(ctx.msg_b.id, scope: ctx.int)
    end
  end

  # ── Stage 4: attachment and canvas reads ───────────────────────────────

  describe "attachment and canvas reads (stage 4)" do
    setup ctx do
      att_a = attachment(ctx.a.id, ctx.msg_a.id)
      att_b = attachment(ctx.b.id, ctx.msg_b.id)
      canvas_a = canvas(ctx.a.id, ctx.p_a.id)
      canvas_b = canvas(ctx.b.id, ctx.p_b.id)
      Map.merge(ctx, %{att_a: att_a, att_b: att_b, canvas_a: canvas_a, canvas_b: canvas_b})
    end

    test "get_attachment gates on space membership", ctx do
      assert Chat.get_attachment(ctx.att_b.id, scope: ctx.ext) == nil
      assert %{id: id} = Chat.get_attachment(ctx.att_a.id, scope: ctx.ext)
      assert id == ctx.att_a.id
    end

    test "list_attachments is empty for a non-member message", ctx do
      assert Chat.list_attachments(ctx.msg_b.id, scope: ctx.ext) == []
      assert [%{id: id}] = Chat.list_attachments(ctx.msg_a.id, scope: ctx.ext)
      assert id == ctx.att_a.id
    end

    test "list_attachments_for_messages drops out-of-scope rows", ctx do
      grouped =
        Chat.list_attachments_for_messages([ctx.msg_a.id, ctx.msg_b.id], scope: ctx.ext)

      assert Map.keys(grouped) == [ctx.msg_a.id]
    end

    test "get_canvas and get_canvas_with_deleted gate on space membership", ctx do
      assert Chat.get_canvas(ctx.canvas_b.id, scope: ctx.ext) == nil
      assert %{id: id} = Chat.get_canvas(ctx.canvas_a.id, scope: ctx.ext)
      assert id == ctx.canvas_a.id
      assert Chat.get_canvas_with_deleted(ctx.canvas_b.id, scope: ctx.ext) == nil
    end

    test "list_canvases is empty for a non-member space", ctx do
      assert Chat.list_canvases(ctx.b.id, scope: ctx.ext) == []
      assert [%{id: id}] = Chat.list_canvases(ctx.a.id, scope: ctx.ext)
      assert id == ctx.canvas_a.id
    end

    test "regression: internal/no scope resolves B's attachments and canvases", ctx do
      assert %{id: att_bid} = Chat.get_attachment(ctx.att_b.id, scope: ctx.int)
      assert att_bid == ctx.att_b.id
      assert %{id: _} = Chat.get_attachment(ctx.att_b.id)
      assert [_] = Chat.list_attachments(ctx.msg_b.id, scope: ctx.int)
      assert %{id: c_bid} = Chat.get_canvas(ctx.canvas_b.id, scope: ctx.int)
      assert c_bid == ctx.canvas_b.id
      assert [_] = Chat.list_canvases(ctx.b.id, scope: ctx.int)
    end
  end
end
