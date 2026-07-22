defmodule Platform.Accounts.ExternalAdmissionTest do
  @moduledoc """
  rbac-external-users M2 stages 2 + 4: the login-admission orchestrator and
  the seamless live-recovery seam. Fail-closed-on-ACCESS: holding writes zero
  scoped rows; full materializes once; recovery broadcasts on the topic.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.ExternalAdmission
  alias Platform.Accounts.ExternalAdmission.Result
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.ExternalDmAllowlistEntry
  alias Platform.Tenancy.ExternalGrants
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp tenant_org!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    default = %{
      name: "Tenant #{n}",
      slug: "tenant_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    }

    %Org{} |> Org.changeset(Map.merge(default, attrs)) |> Repo.insert!()
  end

  defp channel!(org) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{name: "Chan #{n}", slug: "chan-#{n}", kind: "channel", org_id: org.id})

    space
  end

  defp admin_user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "admin-#{n}@example.com",
      name: "Admin #{n}",
      oidc_sub: "oidc-admin-#{n}"
    })
    |> Repo.insert!()
  end

  defp scoped_participant_count(user_id) do
    Repo.aggregate(
      from(p in Chat.Participant, where: p.participant_id == ^user_id),
      :count
    )
  end

  defp allowlist_count(user_id) do
    Repo.aggregate(
      from(e in ExternalDmAllowlistEntry, where: e.user_id == ^user_id),
      :count
    )
  end

  defp external_membership_count(user_id) do
    Repo.aggregate(
      from(m in OrgMembership, where: m.user_id == ^user_id and m.external == true),
      :count
    )
  end

  # ── Stage 2: admit/2 ───────────────────────────────────────────────────

  describe "admit/2 — full with a staged grant" do
    test "materializes external membership + participant + allowlist ONCE (idempotent)" do
      target_org = tenant_org!()
      dm_org = tenant_org!()
      space = channel!(target_org)

      {:ok, _grant} =
        ExternalGrants.create_grant(%{
          email: "ext@partner.example",
          oidc_sub: "oidc|partner-1",
          target_org_id: target_org.id,
          space_grants: [%{"space_id" => space.id, "role" => "member"}],
          dm_allowlist_org_ids: [dm_org.id]
        })

      oidc_user = %{
        sub: "oidc|partner-1",
        email: "ext@partner.example",
        name: "Ext User",
        external_claim?: true
      }

      assert %Result{state: :full, external?: true, reason: nil, user: user} =
               ExternalAdmission.admit(oidc_user, surface: :external)

      membership = Repo.get_by!(OrgMembership, user_id: user.id, org_id: target_org.id)
      assert membership.external == true
      assert membership.role == "member"
      assert scoped_participant_count(user.id) == 1
      assert allowlist_count(user.id) == 1
      assert Tenancy.may_dm_org?(user, dm_org)
      assert user.id in Enum.map(Tenancy.list_external_memberships(target_org), & &1.user_id)

      # Second login (double-login) — idempotent, no duplicates.
      assert %Result{state: :full, user: user2} =
               ExternalAdmission.admit(oidc_user, surface: :external)

      assert user2.id == user.id

      assert scoped_participant_count(user.id) == 1
      assert allowlist_count(user.id) == 1
      assert external_membership_count(user.id) == 1
    end
  end

  describe "admit/2 — holding (fail-closed)" do
    test "external claim, no grant -> :holding/:awaiting_grant with ZERO scoped rows" do
      assert %Result{state: :holding, reason: :awaiting_grant, external?: true, user: user} =
               ExternalAdmission.admit(
                 %{
                   sub: "oidc|black-1",
                   email: "black@partner.example",
                   name: "Black Holed",
                   external_claim?: true
                 },
                 surface: :external
               )

      assert scoped_participant_count(user.id) == 0
      assert allowlist_count(user.id) == 0
      assert external_membership_count(user.id) == 0
    end

    test "external surface, no claim, no grant -> :holding/:missing_claim, ZERO scoped rows" do
      assert %Result{state: :holding, reason: :missing_claim, external?: false, user: user} =
               ExternalAdmission.admit(
                 %{
                   sub: "oidc|B",
                   email: "b@partner.example",
                   name: "Unknown B",
                   external_claim?: false
                 },
                 surface: :external
               )

      assert scoped_participant_count(user.id) == 0
      assert allowlist_count(user.id) == 0
      assert external_membership_count(user.id) == 0
    end
  end

  describe "admit/2 — internal app login is unchanged" do
    test "fabrikam admin -> :full/external? false with admin role; non-fabrikam member -> member role" do
      assert %Result{state: :full, external?: false, reason: nil, user: fabrikam_user} =
               ExternalAdmission.admit(
                 %{
                   sub: "oidc|int-1",
                   email: "someone@example.com",
                   name: "Internal Admin",
                   external_claim?: false
                 },
                 surface: :app
               )

      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      assert Repo.get_by!(OrgMembership, user_id: fabrikam_user.id, org_id: fabrikam.id).role == "admin"
      # Internal user is never routed to holding and never gets scoped external rows.
      assert external_membership_count(fabrikam_user.id) == 0

      assert %Result{state: :full, external?: false, user: member_user} =
               ExternalAdmission.admit(
                 %{
                   sub: "oidc|int-2",
                   email: "someone@other.example",
                   name: "Internal Member",
                   external_claim?: false
                 },
                 surface: :app
               )

      assert Repo.get_by!(OrgMembership, user_id: member_user.id, org_id: fabrikam.id).role ==
               "member"
    end
  end

  describe "admit/2 — archived users still refuse" do
    test "propagates {:error, :user_archived} straight through (not holding)" do
      {:ok, user} =
        Platform.Accounts.find_or_create_from_oidc(%{
          sub: "oidc|arch-1",
          email: "arch@partner.example",
          name: "Archived One"
        })

      {:ok, _} = Platform.Accounts.archive_user(user)

      assert {:error, :user_archived} =
               ExternalAdmission.admit(
                 %{
                   sub: "oidc|arch-1",
                   email: "arch@partner.example",
                   name: "Archived One",
                   external_claim?: true
                 },
                 surface: :external
               )
    end
  end

  # ── Stage 4: recover/3 ─────────────────────────────────────────────────

  describe "recover/3 — seamless live recovery" do
    test "recovers a holding user, materializes rows, and broadcasts :recovered on the topic" do
      admin = admin_user!()
      target_org = tenant_org!()
      dm_org = tenant_org!()
      space = channel!(target_org)

      # First login black-holes: holding, zero scoped rows.
      %Result{state: :holding, user: user} =
        ExternalAdmission.admit(
          %{
            sub: "oidc|rec-1",
            email: "rec@partner.example",
            name: "Recover Me",
            external_claim?: true
          },
          surface: :external
        )

      assert scoped_participant_count(user.id) == 0

      Phoenix.PubSub.subscribe(
        Platform.PubSub,
        ExternalAdmission.external_admission_topic(user.id)
      )

      assert {:ok, %Result{state: :full, external?: true, user: recovered}} =
               ExternalAdmission.recover(admin, user, %{
                 email: "rec@partner.example",
                 oidc_sub: "oidc|rec-1",
                 target_org_id: target_org.id,
                 space_grants: [%{"space_id" => space.id, "role" => "member"}],
                 dm_allowlist_org_ids: [dm_org.id]
               })

      assert recovered.id == user.id
      assert external_membership_count(user.id) == 1
      assert scoped_participant_count(user.id) == 1
      assert allowlist_count(user.id) == 1

      assert_receive {:external_admission, :recovered, broadcast_user_id, %Result{state: :full}}
      assert broadcast_user_id == user.id
    end

    test "double recover is idempotent and still broadcasts (stale tab upgrades)" do
      admin = admin_user!()
      target_org = tenant_org!()
      space = channel!(target_org)

      %Result{state: :holding, user: user} =
        ExternalAdmission.admit(
          %{
            sub: "oidc|rec-2",
            email: "rec2@partner.example",
            name: "Recover Twice",
            external_claim?: true
          },
          surface: :external
        )

      {:ok, grant} =
        ExternalGrants.create_grant(%{
          email: "rec2@partner.example",
          oidc_sub: "oidc|rec-2",
          target_org_id: target_org.id,
          space_grants: [%{"space_id" => space.id, "role" => "member"}],
          dm_allowlist_org_ids: [target_org.id]
        })

      Phoenix.PubSub.subscribe(
        Platform.PubSub,
        ExternalAdmission.external_admission_topic(user.id)
      )

      assert {:ok, %Result{state: :full}} = ExternalAdmission.recover(admin, user, grant)
      assert_receive {:external_admission, :recovered, _uid, %Result{state: :full}}

      # Second click — the already-applied grant re-applies harmlessly, still
      # broadcasts, and leaves exactly one of each scoped row.
      assert {:ok, %Result{state: :full}} = ExternalAdmission.recover(admin, user, grant)
      assert_receive {:external_admission, :recovered, _uid2, %Result{state: :full}}

      assert external_membership_count(user.id) == 1
      assert scoped_participant_count(user.id) == 1
      assert allowlist_count(user.id) == 1
    end

    test "recover never re-creates the user (recovery is not a re-login)" do
      admin = admin_user!()
      target_org = tenant_org!()

      %Result{state: :holding, user: user} =
        ExternalAdmission.admit(
          %{
            sub: "oidc|rec-3",
            email: "rec3@partner.example",
            name: "Stable Id",
            external_claim?: true
          },
          surface: :external
        )

      count_before = Repo.aggregate(User, :count)

      {:ok, %Result{user: recovered}} =
        ExternalAdmission.recover(admin, user, %{
          email: "rec3@partner.example",
          oidc_sub: "oidc|rec-3",
          target_org_id: target_org.id
        })

      # User id stable and no new user row inserted — find_or_create was NOT
      # called (recovery keys off the existing user, not a fresh login).
      assert recovered.id == user.id
      assert Repo.aggregate(User, :count) == count_before
    end
  end
end
