defmodule Platform.Security.ExternalDmScopeTest do
  @moduledoc """
  M15 security suite — Stage 3 (S3): the DM allowlist write seams (M8).

  An external initiator can neither OPEN nor POST into a DM/group with a
  non-allowlisted target, at BOTH the create seam and the send seam — and a
  denied create materializes NO rows. Internal initiators are unrestricted, and
  DM rules never gate normal channels.

  Binds to M8 shipped: `Chat.external_dm_permitted?/3`, `find_or_create_dm/4`,
  `create_group_conversation/3`, `post_message/2` (via the private
  `ensure_dm_send_allowed/2`), the `{:error, :dm_not_allowed}` atom, and
  `Tenancy.allow_dm/2` / `revoke_dm/2`.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.Space
  alias Platform.ExternalUserFixtures, as: World

  setup do
    World.external_world()
  end

  # ── The shared predicate ───────────────────────────────────────────────

  describe "external_dm_permitted?/3" do
    test "external → allowlisted-org user is permitted; non-allowlisted denied", ctx do
      assert Chat.external_dm_permitted?(ctx.ext.id, "user", ctx.m.id)
      refute Chat.external_dm_permitted?(ctx.ext.id, "user", ctx.n.id)
    end

    test "external → agent target is denied", ctx do
      refute Chat.external_dm_permitted?(ctx.ext.id, "agent", Ecto.UUID.generate())
    end

    test "external → second external user in the same allowlisted org is permitted (Globex↔Globex)",
         ctx do
      assert Chat.external_dm_permitted?(ctx.ext.id, "user", ctx.ext2.id)
    end

    test "internal initiator is unrestricted", ctx do
      assert Chat.external_dm_permitted?(ctx.int.id, "user", ctx.n.id)
    end
  end

  # ── The CREATE seam ────────────────────────────────────────────────────

  describe "find_or_create_dm/4 create seam" do
    test "denied target materializes NO chat_spaces / chat_participants rows", ctx do
      spaces_before = Repo.aggregate(Space, :count, :id)
      participants_before = World.participant_count()

      assert {:error, :dm_not_allowed} = Chat.find_or_create_dm(ctx.ext.id, "user", ctx.n.id)

      assert Repo.aggregate(Space, :count, :id) == spaces_before
      assert World.participant_count() == participants_before
    end

    test "allowlisted target creates a DM with exactly two user participants", ctx do
      assert {:ok, %Space{kind: "dm"} = dm} = Chat.find_or_create_dm(ctx.ext.id, "user", ctx.m.id)

      users =
        Repo.all(
          from(p in Platform.Chat.Participant,
            where: p.space_id == ^dm.id and p.participant_type == "user",
            select: p.participant_id
          )
        )

      assert Enum.sort(users) == Enum.sort([ctx.ext.id, ctx.m.id])
    end

    test "Globex↔Globex DM (external → second external in the same org) is allowed", ctx do
      assert {:ok, %Space{kind: "dm"}} =
               Chat.find_or_create_dm(ctx.ext.id, "user", ctx.ext2.id)
    end
  end

  describe "create_group_conversation/3 create seam" do
    test "a non-allowlisted member rolls back the whole group (no space created)", ctx do
      spaces_before = Repo.aggregate(Space, :count, :id)

      assert {:error, :dm_not_allowed} =
               Chat.create_group_conversation(ctx.ext.id, [
                 %{type: "user", id: ctx.m.id},
                 %{type: "user", id: ctx.n.id}
               ])

      assert Repo.aggregate(Space, :count, :id) == spaces_before
    end

    test "all-allowlisted members create the group", ctx do
      assert {:ok, %Space{kind: "group"}} =
               Chat.create_group_conversation(ctx.ext.id, [
                 %{type: "user", id: ctx.m.id},
                 %{type: "user", id: ctx.ext2.id}
               ])
    end
  end

  # ── The SEND seam (defense in depth: revoke-after-create) ──────────────

  describe "post_message/2 send seam" do
    test "external author is denied after the allowlist is revoked; NO message row inserted",
         ctx do
      {:ok, dm} = Chat.find_or_create_dm(ctx.ext.id, "user", ctx.m.id)
      pk = World.participant_pk!(dm.id, ctx.ext.id)

      {:ok, _} = Platform.Tenancy.revoke_dm(ctx.ext.id, ctx.org_a.id)

      messages_before = Repo.aggregate(Message, :count, :id)

      assert {:error, :dm_not_allowed} =
               Chat.post_message(%{
                 space_id: dm.id,
                 participant_id: pk,
                 content_type: "text",
                 content: "still here?"
               })

      assert Repo.aggregate(Message, :count, :id) == messages_before
    end

    test "control: internal author posting into a DM is unaffected", ctx do
      {:ok, dm} = Chat.find_or_create_dm(ctx.int.id, "user", ctx.m.id)
      pk = World.participant_pk!(dm.id, ctx.int.id)

      assert {:ok, %Message{}} =
               Chat.post_message(%{
                 space_id: dm.id,
                 participant_id: pk,
                 content_type: "text",
                 content: "hi"
               })
    end

    test "control: external member posting into a normal CHANNEL is not gated", ctx do
      # EXT is a participant of channel A; DM rules do not gate channels.
      assert {:ok, %Message{}} =
               Chat.post_message(%{
                 space_id: ctx.a.id,
                 participant_id: ctx.p_a_ext.id,
                 content_type: "text",
                 content: "channel post"
               })
    end
  end
end
