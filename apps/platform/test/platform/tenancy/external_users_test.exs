defmodule Platform.Tenancy.ExternalUsersTest do
  @moduledoc """
  Stack member 1 (rbac-external-users) — the foundational schema unit:

    * `org_memberships.external` — orthogonal external marker (stage 1)
    * `external_dm_allowlist_entries` — per-org DM allowlist (stage 2)
    * `pending_external_grants` + `ExternalGrants` context (stage 3)

  Mirrors the plan's four e2e behaviours plus the `apply_grant/2` seam M2
  consumes.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.ExternalGrants
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership
  alias Platform.Tenancy.PendingExternalGrant

  # ── Helpers ────────────────────────────────────────────────────────────

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "ext-#{n}@example.com",
          name: "Ext #{n}",
          oidc_sub: "oidc-ext-#{n}"
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
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    }

    %Org{} |> Org.changeset(Map.merge(default, attrs)) |> Repo.insert!()
  end

  defp membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  defp channel!(org) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{name: "Chan #{n}", slug: "chan-#{n}", kind: "channel", org_id: org.id})

    space
  end

  # ── Stage 1: external marker on org_memberships ────────────────────────

  describe "external marker (stage 1)" do
    test "mark_membership_external/1 persists external:true, distinguishable from a normal row" do
      user = create_user!()
      org = tenant_org!()
      other_user = create_user!()
      other_org = tenant_org!()

      assert {:ok, ext} =
               Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})

      # A second, normal membership for a different pair (external default false).
      normal = membership!(other_user, other_org, "member")

      # Fresh read, not the in-memory struct.
      reloaded = Repo.get!(OrgMembership, ext.id)
      assert reloaded.external == true
      assert reloaded.role == "member"

      assert Repo.get!(OrgMembership, normal.id).external == false

      ext_ids = org |> Tenancy.list_external_memberships() |> Enum.map(& &1.id)
      assert reloaded.id in ext_ids
      refute normal.id in ext_ids
      assert Tenancy.list_external_memberships(other_org.id) == []
    end

    test "external_user?/1 is true only for users with an external membership" do
      ext_user = create_user!()
      org = tenant_org!()
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext_user.id, org_id: org.id})

      normal_user = create_user!()
      membership!(normal_user, org, "member")

      # A user with no memberships at all is not external (M11 gate relies
      # on this: a runtime whose owner has zero memberships → internal).
      no_membership_user = create_user!()

      assert Tenancy.external_user?(ext_user)
      refute Tenancy.external_user?(normal_user)
      refute Tenancy.external_user?(no_membership_user)
      refute Tenancy.external_user?(nil)
      # Nil-safe on the by-id map shape M11's controller passes.
      refute Tenancy.external_user?(%{id: nil})
    end

    test "mark_membership_external/1 flips an existing normal membership and is idempotent" do
      user = create_user!()
      org = tenant_org!()
      existing = membership!(user, org, "member")

      assert {:ok, m1} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
      assert m1.id == existing.id
      assert m1.external == true
      # role preserved.
      assert m1.role == "member"

      assert {:ok, m2} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
      assert m2.id == existing.id
      assert m2.external == true

      # Still exactly one row for the pair.
      assert Repo.aggregate(
               from(m in OrgMembership, where: m.user_id == ^user.id and m.org_id == ^org.id),
               :count
             ) == 1
    end
  end

  # ── Stage 1: migration additive-safety (role CHECK not widened) ────────

  describe "role CHECK not widened (stage 1 additive-safety)" do
    test "a role value of 'external' is rejected at both changeset and DB level" do
      user = create_user!()
      org = tenant_org!()

      # Changeset layer.
      cs =
        OrgMembership.changeset(%OrgMembership{}, %{
          user_id: user.id,
          org_id: org.id,
          role: "external"
        })

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :role)

      # DB CHECK layer — bypass the changeset with a raw insert.
      {:ok, ub} = Ecto.UUID.dump(user.id)
      {:ok, ob} = Ecto.UUID.dump(org.id)

      assert {:error, %Postgrex.Error{postgres: %{constraint: "org_memberships_role_check"}}} =
               Repo.query(
                 "INSERT INTO org_memberships (id, user_id, org_id, role, external, inserted_at, updated_at) " <>
                   "VALUES (gen_random_uuid(), $1, $2, 'external', false, now(), now())",
                 [ub, ob]
               )
    end

    test "a membership created without an explicit external value defaults to false" do
      user = create_user!()
      org = tenant_org!()
      m = membership!(user, org, "member")
      assert Repo.get!(OrgMembership, m.id).external == false
    end
  end

  # ── Stage 2: per-org DM allowlist ──────────────────────────────────────

  describe "per-org DM allowlist (stage 2)" do
    test "allow_dm/2 gates may_dm_org?/2 per org; list + revoke; idempotent" do
      user = create_user!()
      org_a = tenant_org!()
      org_b = tenant_org!()

      assert {:ok, _entry} = Tenancy.allow_dm(user, org_a)

      assert Tenancy.may_dm_org?(user, org_a)
      refute Tenancy.may_dm_org?(user, org_b)

      assert [%Org{} = only] = Tenancy.list_dm_allowlist(user)
      assert only.id == org_a.id

      # Idempotent — duplicate allow leaves a single row.
      assert {:ok, _} = Tenancy.allow_dm(user, org_a)

      assert Repo.aggregate(
               from(e in Platform.Tenancy.ExternalDmAllowlistEntry, where: e.user_id == ^user.id),
               :count
             ) == 1

      # Revoke is idempotent too.
      assert {:ok, 1} = Tenancy.revoke_dm(user, org_a)
      refute Tenancy.may_dm_org?(user, org_a)
      assert {:ok, 0} = Tenancy.revoke_dm(user, org_a)
      assert Tenancy.list_dm_allowlist(user) == []
    end
  end

  # ── Stage 3: pending grant create / lookup / apply / delete ────────────

  describe "pending external grant lookup (stage 3)" do
    test "create_grant/1 round-trips and lookup matches by BOTH email and sub" do
      org = tenant_org!()
      space = channel!(org)
      email = "ext@partner.example"
      sub = "oidc|partner-123"

      assert {:ok, grant} =
               ExternalGrants.create_grant(%{
                 email: email,
                 oidc_sub: sub,
                 target_org_id: org.id,
                 space_grants: [%{"space_id" => space.id, "role" => "member"}],
                 dm_allowlist_org_ids: [org.id]
               })

      by_email = ExternalGrants.lookup_by_email_or_sub(%{email: email, sub: nil})
      by_sub = ExternalGrants.lookup_by_email_or_sub(%{email: nil, sub: sub})

      assert by_email.id == grant.id
      assert by_sub.id == grant.id
      # jsonb round-trips intact.
      assert by_email.target_org_id == org.id
      assert by_email.space_grants == [%{"space_id" => space.id, "role" => "member"}]
      assert by_email.dm_allowlist_org_ids == [org.id]

      # Non-matching identity → nil, and never matches NULL == NULL.
      assert ExternalGrants.lookup_by_email_or_sub(%{email: "nobody@x.example", sub: "oidc|nope"}) ==
               nil

      assert ExternalGrants.lookup_by_email_or_sub(%{email: nil, sub: nil}) == nil
    end

    test "identity CHECK — a grant with neither email nor sub is rejected" do
      org = tenant_org!()

      assert {:error, cs} = ExternalGrants.create_grant(%{target_org_id: org.id})
      refute cs.valid?
    end

    test "an applied grant is invisible to lookup" do
      org = tenant_org!()
      email = "applied@partner.example"

      {:ok, grant} = ExternalGrants.create_grant(%{email: email, target_org_id: org.id})
      user = create_user!()
      {:ok, _} = ExternalGrants.apply_grant(grant, user)

      assert ExternalGrants.lookup_by_email_or_sub(%{email: email, sub: nil}) == nil
    end
  end

  describe "apply_grant/2 (stage 3 seam M2 consumes)" do
    test "materializes membership + participants + dm allowlist, then stamps applied_at" do
      target_org = tenant_org!()
      dm_org = tenant_org!()
      space = channel!(target_org)
      user = create_user!()

      {:ok, grant} =
        ExternalGrants.create_grant(%{
          email: "provision@partner.example",
          oidc_sub: "oidc|provision-1",
          target_org_id: target_org.id,
          space_grants: [%{"space_id" => space.id, "role" => "member"}],
          dm_allowlist_org_ids: [dm_org.id]
        })

      assert {:ok, applied} = ExternalGrants.apply_grant(grant, user)
      assert %DateTime{} = applied.applied_at

      # (a) external membership at target org.
      membership = Repo.get_by!(OrgMembership, user_id: user.id, org_id: target_org.id)
      assert membership.external == true
      assert membership.role == "member"

      # (b) chat participant in the granted space.
      assert Repo.exists?(
               from(p in Platform.Chat.Participant,
                 where:
                   p.space_id == ^space.id and p.participant_id == ^user.id and
                     p.participant_type == "user"
               )
             )

      # (c) per-org DM allowlist seeded.
      assert Tenancy.may_dm_org?(user, dm_org)

      # (d) idempotent — a second apply is a no-op, no double-provision.
      assert {:ok, again} = ExternalGrants.apply_grant(grant, user)
      assert again.applied_at == applied.applied_at

      assert Repo.aggregate(
               from(p in Platform.Chat.Participant,
                 where: p.space_id == ^space.id and p.participant_id == ^user.id
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(e in Platform.Tenancy.ExternalDmAllowlistEntry,
                 where: e.user_id == ^user.id and e.allowed_org_id == ^dm_org.id
               ),
               :count
             ) == 1
    end

    test "delete_grant/1 removes the grant" do
      org = tenant_org!()

      {:ok, grant} =
        ExternalGrants.create_grant(%{email: "del@partner.example", target_org_id: org.id})

      assert {:ok, _} = ExternalGrants.delete_grant(grant)
      refute Repo.get(PendingExternalGrant, grant.id)
    end
  end
end
