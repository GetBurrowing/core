defmodule Platform.ChatDmAllowlistTest do
  @moduledoc """
  Stack member 8 (rbac-external-users) — per-org DM allowlist enforcement.

  Exercises the three seams that share the single `Chat.external_dm_permitted?/3`
  predicate:

    * stage 1 — the predicate itself (internal always allowed; external
      allowed only into an allowlisted org; agent target denied; Globex↔Globex)
    * stage 2 — the CREATE seam (`find_or_create_dm/4`,
      `create_group_conversation/3`) rejects a denied target with NO rows
      materialized
    * stage 3 — the SEND seam (`post_message/2`,
      `post_message_with_attachments/3`) is defense-in-depth: a DM whose
      allowlist was revoked after creation can no longer be posted to.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.Participant
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  # ── Helpers ────────────────────────────────────────────────────────────

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "dm-#{n}@example.com",
          name: "DM #{n}",
          oidc_sub: "oidc-dm-#{n}"
        },
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp tenant_org!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    default = %{
      name: "Tenant #{n}",
      slug: "tenant_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    }

    %Org{} |> Org.changeset(Map.merge(default, attrs)) |> Repo.insert!()
  end

  defp membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  # An external user whose (external) membership lives in `org`, allowlisted
  # to DM `org` (unless allowlist: false is passed).
  defp external_user!(org, opts \\ []) do
    user = create_user!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
    if Keyword.get(opts, :allowlist, true), do: Tenancy.allow_dm(user, org)
    user
  end

  defp participant_pk!(space_id, user_id) do
    Repo.get_by!(Participant,
      space_id: space_id,
      participant_type: "user",
      participant_id: user_id
    ).id
  end

  defp space_count, do: Repo.aggregate(Space, :count, :id)
  defp participant_count, do: Repo.aggregate(Participant, :count, :id)
  defp message_count, do: Repo.aggregate(Message, :count, :id)

  # ── Stage 1: external_dm_permitted?/3 ──────────────────────────────────

  describe "external_dm_permitted?/3 (stage 1)" do
    test "internal initiator is always permitted, target in any org" do
      org = tenant_org!()
      internal = create_user!()
      membership!(internal, org, "member")
      target = create_user!()
      membership!(target, tenant_org!(), "member")

      assert Chat.external_dm_permitted?(internal.id, "user", target.id)
      # Even an agent target: internal users keep unrestricted DM behavior.
      assert Chat.external_dm_permitted?(internal.id, "agent", Ecto.UUID.generate())
    end

    test "external initiator permitted to a user in an allowlisted org" do
      org_a = tenant_org!()
      ext = external_user!(org_a)
      member = create_user!()
      membership!(member, org_a, "member")

      assert Chat.external_dm_permitted?(ext.id, "user", member.id)
    end

    test "external initiator denied to a user in a non-allowlisted org" do
      org_a = tenant_org!()
      org_b = tenant_org!()
      ext = external_user!(org_a)
      outsider = create_user!()
      membership!(outsider, org_b, "member")

      refute Chat.external_dm_permitted?(ext.id, "user", outsider.id)
    end

    test "external initiator denied to an agent target" do
      org_a = tenant_org!()
      ext = external_user!(org_a)

      refute Chat.external_dm_permitted?(ext.id, "agent", Ecto.UUID.generate())
    end

    test "external initiator permitted to a second external user in the same allowlisted org (Globex↔Globex)" do
      org_a = tenant_org!()
      u1 = external_user!(org_a)
      u2 = external_user!(org_a)

      assert Chat.external_dm_permitted?(u1.id, "user", u2.id)
      assert Chat.external_dm_permitted?(u2.id, "user", u1.id)
    end
  end

  # ── Stage 2: the CREATE seam ───────────────────────────────────────────

  describe "find_or_create_dm/4 create seam (stage 2)" do
    test "external → allowlisted-org member creates the DM with two user participants" do
      org_a = tenant_org!()
      ext = external_user!(org_a)
      member = create_user!()
      membership!(member, org_a, "member")

      assert {:ok, %Space{kind: "dm"} = space} =
               Chat.find_or_create_dm(ext.id, "user", member.id)

      users =
        Repo.all(
          from(p in Participant,
            where: p.space_id == ^space.id and p.participant_type == "user",
            select: p.participant_id
          )
        )

      assert Enum.sort(users) == Enum.sort([ext.id, member.id])
    end

    test "external → non-allowlisted user is denied and materializes NO rows" do
      org_a = tenant_org!()
      org_b = tenant_org!()
      ext = external_user!(org_a)
      outsider = create_user!()
      membership!(outsider, org_b, "member")

      spaces_before = space_count()
      participants_before = participant_count()

      assert {:error, :dm_not_allowed} = Chat.find_or_create_dm(ext.id, "user", outsider.id)

      assert space_count() == spaces_before
      assert participant_count() == participants_before
    end

    test "internal initiator DM is unaffected" do
      org = tenant_org!()
      internal = create_user!()
      membership!(internal, org, "member")
      target = create_user!()
      membership!(target, tenant_org!(), "member")

      assert {:ok, %Space{kind: "dm"}} = Chat.find_or_create_dm(internal.id, "user", target.id)
    end
  end

  describe "create_group_conversation/3 create seam (stage 2)" do
    test "external initiator with a non-allowlisted member is denied and rolls back (no space)" do
      org_a = tenant_org!()
      org_b = tenant_org!()
      ext = external_user!(org_a)
      ok_member = create_user!()
      membership!(ok_member, org_a, "member")
      bad_member = create_user!()
      membership!(bad_member, org_b, "member")

      spaces_before = space_count()

      assert {:error, :dm_not_allowed} =
               Chat.create_group_conversation(ext.id, [
                 %{type: "user", id: ok_member.id},
                 %{type: "user", id: bad_member.id}
               ])

      assert space_count() == spaces_before
    end

    test "external initiator with all-allowlisted members creates the group" do
      org_a = tenant_org!()
      ext = external_user!(org_a)
      m1 = external_user!(org_a)
      m2 = create_user!()
      membership!(m2, org_a, "member")

      assert {:ok, %Space{kind: "group"}} =
               Chat.create_group_conversation(ext.id, [
                 %{type: "user", id: m1.id},
                 %{type: "user", id: m2.id}
               ])
    end
  end

  # ── Stage 3: the SEND seam ─────────────────────────────────────────────

  describe "post_message/2 send seam (stage 3)" do
    test "external author posting into an allowlisted DM succeeds" do
      org_a = tenant_org!()
      ext = external_user!(org_a)
      member = create_user!()
      membership!(member, org_a, "member")

      {:ok, dm} = Chat.find_or_create_dm(ext.id, "user", member.id)
      pk = participant_pk!(dm.id, ext.id)

      assert {:ok, %Message{}} =
               Chat.post_message(%{
                 space_id: dm.id,
                 participant_id: pk,
                 content_type: "text",
                 content: "hello"
               })
    end

    test "external author denied after allowlist revoked; no message row inserted" do
      org_a = tenant_org!()
      ext = external_user!(org_a)
      member = create_user!()
      membership!(member, org_a, "member")

      {:ok, dm} = Chat.find_or_create_dm(ext.id, "user", member.id)
      pk = participant_pk!(dm.id, ext.id)

      {:ok, _} = Tenancy.revoke_dm(ext.id, org_a.id)

      messages_before = message_count()

      assert {:error, :dm_not_allowed} =
               Chat.post_message(%{
                 space_id: dm.id,
                 participant_id: pk,
                 content_type: "text",
                 content: "still here?"
               })

      assert message_count() == messages_before
    end

    test "internal author posting into a DM is unaffected" do
      org = tenant_org!()
      internal = create_user!()
      membership!(internal, org, "member")
      target = create_user!()
      membership!(target, org, "member")

      {:ok, dm} = Chat.find_or_create_dm(internal.id, "user", target.id)
      pk = participant_pk!(dm.id, internal.id)

      assert {:ok, %Message{}} =
               Chat.post_message(%{
                 space_id: dm.id,
                 participant_id: pk,
                 content_type: "text",
                 content: "hi"
               })
    end

    test "external member posting into a normal channel is not gated (:ok)" do
      org_a = tenant_org!()
      ext = external_user!(org_a, allowlist: false)

      {:ok, channel} =
        Chat.create_space(%{
          name: "General",
          slug: "general-#{System.unique_integer([:positive])}",
          kind: "channel",
          org_id: org_a.id
        })

      {:ok, part} =
        Chat.add_participant(channel.id, %{
          participant_type: "user",
          participant_id: ext.id,
          joined_at: DateTime.utc_now()
        })

      assert {:ok, %Message{}} =
               Chat.post_message(%{
                 space_id: channel.id,
                 participant_id: part.id,
                 content_type: "text",
                 content: "channel post"
               })
    end
  end

  describe "post_message_with_attachments/3 send seam (stage 3)" do
    test "external author denied after allowlist revoked; no message row inserted" do
      org_a = tenant_org!()
      ext = external_user!(org_a)
      member = create_user!()
      membership!(member, org_a, "member")

      {:ok, dm} = Chat.find_or_create_dm(ext.id, "user", member.id)
      pk = participant_pk!(dm.id, ext.id)

      {:ok, _} = Tenancy.revoke_dm(ext.id, org_a.id)

      messages_before = message_count()

      assert {:error, :dm_not_allowed} =
               Chat.post_message_with_attachments(
                 %{space_id: dm.id, participant_id: pk, content_type: "text", content: "x"},
                 [
                   %{
                     filename: "a.txt",
                     content_type: "text/plain",
                     byte_size: 1,
                     storage_key: "k-#{System.unique_integer([:positive])}"
                   }
                 ]
               )

      assert message_count() == messages_before
    end
  end
end
