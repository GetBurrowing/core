defmodule Platform.Security.ExternalQueryScopeTest do
  @moduledoc """
  M15 security suite — Stage 2 (S2): the query-layer read scope (M7).

  Defense in depth: given an EXTERNAL caller, every context read returns ONLY
  allowlisted (participant-space) rows EVEN WITH M6's HTTP plug entirely out of
  the loop — the context functions are called DIRECTLY. An internal (or absent)
  scope is pass-through (regression guard), so an internal caller's reads are
  never narrowed by participant membership.

  Binds to M7 shipped: `Platform.Chat.ExternalScope.for_user/1` and the
  `:scope`-threaded reads on `Platform.Chat`.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.ExternalScope
  alias Platform.ExternalUserFixtures, as: World

  setup do
    w = World.external_world()

    # A third channel EXT is not in.
    c = World.channel!()
    World.add_user!(c.id, w.other.id)

    # "quarterly" messages in both A (EXT member) and B (EXT not a member).
    msg_a = World.post!(w.a.id, w.p_a_ext.id, "quarterly numbers for A")
    msg_b = World.post!(w.b.id, w.p_b.id, "quarterly numbers for B")

    # A canvas + a message-attachment in each of A and B.
    att_a = World.attachment!(w.a.id, msg_a.id)
    att_b = World.attachment!(w.b.id, msg_b.id)
    canvas_a = World.canvas!(w.a.id, w.p_a_ext.id)
    canvas_b = World.canvas!(w.b.id, w.p_b.id)

    ext = ExternalScope.for_user(w.ext.id)
    int = ExternalScope.for_user(w.int.id)

    Map.merge(w, %{
      c: c,
      msg_a: msg_a,
      msg_b: msg_b,
      att_a: att_a,
      att_b: att_b,
      canvas_a: canvas_a,
      canvas_b: canvas_b,
      ext: ext,
      int: int,
      ext_user_id: w.ext.id,
      int_user_id: w.int.id
    })
  end

  test "for_user classifies external vs internal", ctx do
    assert ctx.ext.external? == true
    assert ctx.int.external? == false
  end

  # ── Space reads ────────────────────────────────────────────────────────

  describe "space reads" do
    test "list_spaces(channel, scope: ext) returns exactly [A]", ctx do
      ids = Chat.list_spaces(kind: "channel", scope: ctx.ext) |> Enum.map(& &1.id)
      assert ctx.a.id in ids
      refute ctx.b.id in ids
      refute ctx.c.id in ids

      # No-scope returns all channels (regression).
      all = Chat.list_spaces(kind: "channel") |> Enum.map(& &1.id)
      assert ctx.a.id in all and ctx.b.id in all and ctx.c.id in all
    end

    test "get_space / get_space_by_slug gate on membership under external scope", ctx do
      assert Chat.get_space(ctx.b.id, scope: ctx.ext) == nil
      assert %{id: aid} = Chat.get_space(ctx.a.id, scope: ctx.ext)
      assert aid == ctx.a.id
      # 404-shaped nil, not a leak.
      assert Chat.get_space_by_slug(ctx.b.slug, scope: ctx.ext) == nil
    end

    test "list_user_conversations excludes B", ctx do
      ids = Chat.list_user_conversations(ctx.ext_user_id, scope: ctx.ext) |> Enum.map(& &1.id)
      refute ctx.b.id in ids
      assert ids == [ctx.a.id]
    end
  end

  # ── Message + search reads ─────────────────────────────────────────────

  describe "message and search reads" do
    test "list_messages / get_message / get_messages_by_ids gate on membership", ctx do
      assert Chat.list_messages(ctx.b.id, scope: ctx.ext) == []
      assert Chat.get_message(ctx.msg_b.id, scope: ctx.ext) == nil

      ids =
        Chat.get_messages_by_ids([ctx.msg_a.id, ctx.msg_b.id], scope: ctx.ext)
        |> Enum.map(& &1.id)

      assert ids == [ctx.msg_a.id]
    end

    test "has_more sentinels cannot probe a non-member space", ctx do
      refute Chat.has_more_messages_before?(ctx.b.id, before_id: ctx.msg_b.id, scope: ctx.ext)

      refute Chat.has_more_messages_after?(ctx.b.id,
               after_id: "00000000-0000-0000-0000-000000000000",
               scope: ctx.ext
             )
    end

    test "search_messages filters BEFORE ts_headline — no snippet of B's content leaks", ctx do
      assert Chat.search_messages(ctx.b.id, "quarterly", scope: ctx.ext) == []

      # The A hit still resolves for the member.
      assert [hit] = Chat.search_messages(ctx.a.id, "quarterly", scope: ctx.ext)
      assert hit.id == ctx.msg_a.id
      assert hit.search_headline =~ "quarterly"

      # Belt-and-suspenders: NO fragment of B's content appears in any external
      # search result, even a scan across the whole (empty) result set.
      results_blob =
        Chat.search_messages(ctx.b.id, "quarterly", scope: ctx.ext)
        |> Enum.map(fn m -> "#{m.content} #{m.search_headline}" end)
        |> Enum.join(" ")

      refute results_blob =~ "for B"
    end
  end

  # ── Attachment + canvas reads ──────────────────────────────────────────

  describe "attachment and canvas reads" do
    test "get_attachment / list_attachments gate on membership", ctx do
      assert Chat.get_attachment(ctx.att_b.id, scope: ctx.ext) == nil
      assert %{id: aid} = Chat.get_attachment(ctx.att_a.id, scope: ctx.ext)
      assert aid == ctx.att_a.id

      assert Chat.list_attachments(ctx.msg_b.id, scope: ctx.ext) == []
      assert Chat.list_attachments_for_messages([ctx.msg_b.id], scope: ctx.ext) == %{}
      assert Chat.get_visible_attachment(ctx.att_b.id, scope: ctx.ext) == nil
    end

    test "get_canvas / get_canvas_with_deleted / list_canvases gate on membership", ctx do
      assert Chat.get_canvas(ctx.canvas_b.id, scope: ctx.ext) == nil
      assert Chat.get_canvas_with_deleted(ctx.canvas_b.id, scope: ctx.ext) == nil
      assert Chat.list_canvases(ctx.b.id, scope: ctx.ext) == []

      assert %{id: cid} = Chat.get_canvas(ctx.canvas_a.id, scope: ctx.ext)
      assert cid == ctx.canvas_a.id
    end
  end

  # ── Regression: internal / no scope is never narrowed ──────────────────

  describe "regression — internal and no-scope reads resolve B's rows" do
    test "spaces / messages / search", ctx do
      assert %{id: _} = Chat.get_space(ctx.b.id, scope: ctx.int)
      assert %{id: _} = Chat.get_space(ctx.b.id)
      assert [%{id: bmid}] = Chat.list_messages(ctx.b.id, scope: ctx.int)
      assert bmid == ctx.msg_b.id
      assert [%{id: ^bmid}] = Chat.list_messages(ctx.b.id)
      assert [hit] = Chat.search_messages(ctx.b.id, "quarterly", scope: ctx.int)
      assert hit.id == ctx.msg_b.id
      assert %{id: ^bmid} = Chat.get_message(ctx.msg_b.id, scope: ctx.int)
    end

    test "attachments / canvases", ctx do
      assert %{id: _} = Chat.get_attachment(ctx.att_b.id, scope: ctx.int)
      assert %{id: _} = Chat.get_attachment(ctx.att_b.id)
      assert [_] = Chat.list_attachments(ctx.msg_b.id, scope: ctx.int)
      assert %{id: _} = Chat.get_canvas(ctx.canvas_b.id, scope: ctx.int)
      assert [_] = Chat.list_canvases(ctx.b.id, scope: ctx.int)
    end
  end
end
