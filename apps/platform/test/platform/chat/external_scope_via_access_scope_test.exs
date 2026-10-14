defmodule Platform.Chat.ExternalScopeViaAccessScopeTest do
  @moduledoc """
  The existing ExternalScope filter keeps working through `%Platform.Access.Scope{}`
  (task `01a1386d-cb5c` stage 3).

  Every Chat read that takes `:scope` is run twice per actor: once with
  today's `ExternalScope.for_user/1` and once with `Access.Scope.for_user/1`.
  The two result sets must be equal. The actors are the canonical
  `Platform.ExternalUserFixtures.external_world/0` users (ext, ext2, int), plus
  a mixed user (external in org A, internal member of org B) and an external
  member of the root org.

  The liveness case builds both scopes, adds a participant row, and re-reads
  without rebuilding: a Scope must filter through the LIVE
  `ExternalScope.member_space_ids/1` subquery, not its build-time snapshot.
  """
  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures

  alias Platform.Access.Scope
  alias Platform.Chat
  alias Platform.Chat.ExternalScope
  alias Platform.Tenancy

  setup do
    w = external_world()

    # The mixed user: external in org A, an internal member of org B.
    mixed = create_user!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: mixed.id, org_id: w.org_a.id})
    plain_member!(mixed, w.org_b)

    # An external member of a ROOT org (`parent_org_id IS NULL`).
    root_org = Tenancy.get_org_by_slug!("acme")
    assert root_org.parent_org_id == nil
    ext_root = create_user!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext_root.id, org_id: root_org.id})

    # Channel c lives in org B; mixed and ext_root participate, ext does not.
    c = channel!(%{org_id: w.org_b.id})
    p_c_mixed = add_user!(c.id, mixed.id)
    _ = add_user!(c.id, ext_root.id)
    _ = add_user!(w.a.id, mixed.id)

    msg_a = post!(w.a.id, w.p_a_ext.id, "quarterly numbers for A")
    msg_b = post!(w.b.id, w.p_b.id, "quarterly numbers for B")
    msg_c = post!(c.id, p_c_mixed.id, "quarterly numbers for C")

    att_a = attachment!(w.a.id, msg_a.id)
    att_b = attachment!(w.b.id, msg_b.id)
    att_c = attachment!(c.id, msg_c.id)

    canvas_a = canvas!(w.a.id, w.p_a_ext.id)
    canvas_b = canvas!(w.b.id, w.p_b.id)
    canvas_c = canvas!(c.id, p_c_mixed.id)

    Map.merge(w, %{
      mixed: mixed,
      ext_root: ext_root,
      c: c,
      spaces: [w.a, w.b, c],
      messages: [msg_a, msg_b, msg_c],
      attachments: [att_a, att_b, att_c],
      canvases: [canvas_a, canvas_b, canvas_c]
    })
  end

  # Every read the stage names, as one comparable map. `ids/1` sorts so the
  # comparison is set equality, not order.
  defp reads(scope, user_id, w) do
    space_ids = Enum.map(w.spaces, & &1.id)
    message_ids = Enum.map(w.messages, & &1.id)

    %{
      channels: Chat.list_spaces(kind: "channel", scope: scope) |> ids(),
      conversations: Chat.list_user_conversations(user_id, scope: scope) |> ids(),
      get_space: Map.new(w.spaces, &{&1.id, id_of(Chat.get_space(&1.id, scope: scope))}),
      get_space_by_slug:
        Map.new(w.spaces, &{&1.slug, id_of(Chat.get_space_by_slug(&1.slug, scope: scope))}),
      visible_space_id?: Map.new(space_ids, &{&1, ExternalScope.visible_space_id?(&1, scope)}),
      list_messages: Map.new(space_ids, &{&1, Chat.list_messages(&1, scope: scope) |> ids()}),
      get_message: Map.new(message_ids, &{&1, id_of(Chat.get_message(&1, scope: scope))}),
      get_messages_by_ids: Chat.get_messages_by_ids(message_ids, scope: scope) |> ids(),
      search_messages:
        Map.new(space_ids, &{&1, Chat.search_messages(&1, "quarterly", scope: scope) |> ids()}),
      get_attachment:
        Map.new(w.attachments, &{&1.id, id_of(Chat.get_attachment(&1.id, scope: scope))}),
      list_attachments:
        Map.new(message_ids, &{&1, Chat.list_attachments(&1, scope: scope) |> ids()}),
      list_attachments_for_messages:
        Chat.list_attachments_for_messages(message_ids, scope: scope) |> Map.keys() |> Enum.sort(),
      get_canvas: Map.new(w.canvases, &{&1.id, id_of(Chat.get_canvas(&1.id, scope: scope))}),
      list_canvases: Map.new(space_ids, &{&1, Chat.list_canvases(&1, scope: scope) |> ids()})
    }
  end

  defp ids(rows), do: rows |> Enum.map(& &1.id) |> Enum.sort()
  defp id_of(nil), do: nil
  defp id_of(%{id: id}), do: id

  defp both(user, w) do
    {reads(ExternalScope.for_user(user), user.id, w), reads(Scope.for_user(user), user.id, w)}
  end

  describe "result-set equality, ExternalScope.for_user/1 vs Access.Scope.for_user/1" do
    for actor <- [:ext, :ext2, :int, :mixed, :ext_root] do
      @actor actor
      test "#{actor}: every scoped Chat read returns the same set", w do
        user = Map.fetch!(w, @actor)
        {today, via_scope} = both(user, w)
        assert via_scope == today
      end
    end

    test "ext is restricted through the Scope: channel b is invisible", w do
      via_scope = reads(Scope.for_user(w.ext), w.ext.id, w)

      assert via_scope.channels == [w.a.id]
      assert via_scope.visible_space_id?[w.b.id] == false
      assert via_scope.list_messages[w.b.id] == []
      assert via_scope.get_canvas[Enum.at(w.canvases, 1).id] == nil
    end

    test "the mixed user is restricted like ext, not widened by the org-B membership", w do
      via_scope = reads(Scope.for_user(w.mixed), w.mixed.id, w)

      assert via_scope.channels == Enum.sort([w.a.id, w.c.id])
      assert via_scope.visible_space_id?[w.b.id] == false
    end

    test "int passes through: channel b is visible", w do
      via_scope = reads(Scope.for_user(w.int), w.int.id, w)

      assert w.b.id in via_scope.channels
      assert via_scope.visible_space_id?[w.b.id] == true
    end
  end

  describe "from_scope/1" do
    test "marks exactly the participant-restricted users external", w do
      assert %ExternalScope{external?: true, user_id: id} = ExternalScope.from_scope(Scope.for_user(w.ext))
      assert id == w.ext.id
      assert ExternalScope.from_scope(Scope.for_user(w.ext2)).external?
      assert ExternalScope.from_scope(Scope.for_user(w.mixed)).external?
      assert ExternalScope.from_scope(Scope.for_user(w.ext_root)).external?
      refute ExternalScope.from_scope(Scope.for_user(w.int)).external?
    end

    test "agrees with ExternalScope.for_user/1 for every world user", w do
      for key <- [:ext, :ext2, :int, :m, :n, :other, :mixed, :ext_root] do
        user = Map.fetch!(w, key)
        assert ExternalScope.from_scope(Scope.for_user(user)) == ExternalScope.for_user(user),
               "from_scope disagrees with for_user for #{key}"
      end
    end

    test "non-user Scopes pass through like the system scope", w do
      unscoped = Chat.list_spaces(kind: "channel") |> ids()

      for scope <- [Scope.system(), Scope.for_user(nil), Scope.for_meeting_invitee(:token)] do
        assert %ExternalScope{external?: false, user_id: nil} = ExternalScope.from_scope(scope)
        assert Chat.list_spaces(kind: "channel", scope: scope) |> ids() == unscoped
        assert ExternalScope.visible_space_id?(w.b.id, scope)
      end
    end

    test "a zero-membership user passes through, as ExternalScope.for_user/1 does", w do
      zero = create_user!()
      unscoped = Chat.list_spaces(kind: "channel") |> ids()

      refute ExternalScope.for_user(zero).external?
      refute ExternalScope.from_scope(Scope.for_user(zero)).external?
      assert Chat.list_spaces(kind: "channel", scope: Scope.for_user(zero)) |> ids() == unscoped
      assert ExternalScope.visible_space_id?(w.b.id, Scope.for_user(zero))
    end

    test "member_space_ids/1 accepts a Scope and yields the same query result", w do
      for key <- [:ext, :mixed] do
        user = Map.fetch!(w, key)

        assert Repo.all(ExternalScope.member_space_ids(Scope.for_user(user))) |> Enum.sort() ==
                 Repo.all(ExternalScope.member_space_ids(ExternalScope.for_user(user))) |> Enum.sort()
      end
    end
  end

  describe "liveness: the Scope filters live, not from its build-time snapshot" do
    test "a participant row added after both scopes were built appears in both", w do
      old = ExternalScope.for_user(w.ext)
      new = Scope.for_user(w.ext)

      refute w.b.id in Scope.permitted_ids(new, "chat.read")
      refute w.b.id in (Chat.list_spaces(kind: "channel", scope: new) |> ids())

      _ = add_user!(w.b.id, w.ext.id)

      # The snapshot is stale by design ...
      refute w.b.id in Scope.permitted_ids(new, "chat.read")

      # ... and the filter is not.
      assert w.b.id in (Chat.list_spaces(kind: "channel", scope: old) |> ids())
      assert w.b.id in (Chat.list_spaces(kind: "channel", scope: new) |> ids())
      assert ExternalScope.visible_space_id?(w.b.id, new)
      assert [_] = Chat.list_messages(w.b.id, scope: new)

      assert reads(new, w.ext.id, w) == reads(old, w.ext.id, w)
    end
  end
end
