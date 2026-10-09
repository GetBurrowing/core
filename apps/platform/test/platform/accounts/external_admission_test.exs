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
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
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
      email: "admin-#{n}@acme.test",
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

  defp group_claim!(org, value) do
    {:ok, claim} = Tenancy.create_group_claim(%{org_id: org.id, claim_value: value})
    claim
  end

  defp admit_external(groups, sub) do
    ExternalAdmission.admit(
      %{
        sub: sub,
        email: "#{sub}@partner.example",
        name: "Group Claimant",
        external_claim?: true,
        external_groups: groups
      },
      surface: :external
    )
  end

  # Global scoped-row census — the before/after control proving a holding
  # admission writes nothing ANYWHERE, not merely nothing for this user.
  #
  # NOTE the identity membership: `Accounts.find_or_create_from_oidc/1`
  # upserts an Acme membership with the email-derived role for EVERY new user,
  # before `decide/3` ever runs. That row is user identity, not scoped access,
  # and predates this task — so the census is taken around the ADMISSION
  # decision (see `admit_twice_census/2`), and external memberships are
  # counted separately since those are the access-granting kind.
  defp total_scoped_rows do
    %{
      participants: Repo.aggregate(Chat.Participant, :count),
      allowlist: Repo.aggregate(ExternalDmAllowlistEntry, :count),
      memberships: Repo.aggregate(OrgMembership, :count),
      external_memberships:
        Repo.aggregate(from(m in OrgMembership, where: m.external == true), :count)
    }
  end

  # Admit once (which creates the user + its identity membership), snapshot,
  # admit again with the same claims, snapshot. Any row a holding admission
  # writes shows up in the delta with user creation factored out.
  defp admit_twice_census(groups, sub) do
    result = admit_external(groups, sub)
    before_rows = total_scoped_rows()
    result2 = admit_external(groups, sub)
    {result, result2, before_rows, total_scoped_rows()}
  end

  defp org_membership_count(org_id) do
    Repo.aggregate(from(m in OrgMembership, where: m.org_id == ^org_id), :count)
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

  # ── Task 019ff7ff stage 2: group-claim resolution rides along ─────────
  #
  # The claim NAMES an org; admission still refuses to act on it. Each test
  # pins both halves: the suggestion, and that nothing changed.

  describe "admit/2 — holding carries the group-claim suggestion" do
    test "ONE mapped group -> suggested_org_id set, group_match :one, still :holding" do
      org = tenant_org!()
      group_claim!(org, "acme-client")

      {result, repeat, before_rows, after_rows} =
        admit_twice_census(["employees", "acme-client"], "oidc|grp-one")

      assert %Result{
               state: :holding,
               reason: :awaiting_grant,
               external?: true,
               suggested_org_id: suggested,
               group_match: :one,
               user: user
             } = result

      assert suggested == org.id
      # A repeat login is still holding — a resolved org never upgrades anyone.
      assert %Result{state: :holding, reason: :awaiting_grant, group_match: :one} = repeat

      # ZERO scoped rows written, for this user and globally.
      assert scoped_participant_count(user.id) == 0
      assert allowlist_count(user.id) == 0
      assert external_membership_count(user.id) == 0
      assert after_rows == before_rows
      assert after_rows.external_memberships == 0
      # And emphatically nothing lands in the SUGGESTED org.
      assert org_membership_count(org.id) == 0
    end

    test "ZERO mapped groups -> nil suggestion, :none, still :holding — no default org" do
      # An org WITH a mapping exists; the login just does not name it. Without
      # this fixture a nil result could not distinguish "no match" from
      # "no mappings configured at all".
      other = tenant_org!()
      group_claim!(other, "acme-client")

      {result, _repeat, before_rows, after_rows} =
        admit_twice_census(["employees", "unmapped-group"], "oidc|grp-none")

      assert %Result{
               state: :holding,
               reason: :awaiting_grant,
               external?: true,
               suggested_org_id: nil,
               group_match: :none,
               user: user
             } = result

      assert scoped_participant_count(user.id) == 0
      assert allowlist_count(user.id) == 0
      assert external_membership_count(user.id) == 0
      assert after_rows == before_rows
      assert after_rows.external_memberships == 0
      # No fallback: the one org that HAS a mapping gains nobody.
      assert org_membership_count(other.id) == 0
    end

    test "an EMPTY / absent claim -> nil suggestion, :none" do
      assert %Result{suggested_org_id: nil, group_match: :none, state: :holding} =
               admit_external([], "oidc|grp-empty")

      # Key absent entirely (an older caller that never learned the key).
      assert %Result{suggested_org_id: nil, group_match: :none, state: :holding} =
               ExternalAdmission.admit(
                 %{
                   sub: "oidc|grp-absent",
                   email: "grp-absent@partner.example",
                   name: "No Key",
                   external_claim?: true
                 },
                 surface: :external
               )
    end

    test "TWO mapped groups from TWO orgs -> nil suggestion and :ambiguous" do
      org_a = tenant_org!()
      org_b = tenant_org!()
      group_claim!(org_a, "acme-client")
      group_claim!(org_b, "beta-client")

      {result, _repeat, before_rows, after_rows} =
        admit_twice_census(["acme-client", "beta-client"], "oidc|grp-ambig")

      assert %Result{
               state: :holding,
               reason: :awaiting_grant,
               external?: true,
               suggested_org_id: nil,
               group_match: :ambiguous,
               user: user
             } = result

      assert scoped_participant_count(user.id) == 0
      assert allowlist_count(user.id) == 0
      assert external_membership_count(user.id) == 0
      assert after_rows == before_rows
      assert after_rows.external_memberships == 0
      # Neither candidate org is picked.
      assert org_membership_count(org_a.id) == 0
      assert org_membership_count(org_b.id) == 0
    end

    test "two claim values naming the SAME org is one match, not ambiguity" do
      org = tenant_org!()
      group_claim!(org, "acme-client")
      group_claim!(org, "acme-client-admins")

      assert %Result{suggested_org_id: suggested, group_match: :one} =
               admit_external(["acme-client", "acme-client-admins"], "oidc|grp-dupe")

      assert suggested == org.id
    end

    test "the audit row for the holding login carries the suggestion (the stage-3 seam)" do
      org = tenant_org!()
      group_claim!(org, "acme-client")

      %Result{user: user} = admit_external(["acme-client"], "oidc|grp-audit")

      row =
        Platform.Audit.list(event_type: "platform.auth.external_admission", limit: 50)
        |> Enum.filter(&(&1.actor_id == user.id and &1.action == "holding"))
        |> List.last()

      assert row, "expected a holding audit row for the login"
      assert row.metadata["suggested_org_id"] == org.id
      assert row.metadata["group_match"] == "one"
    end

    test "an unresolved login's audit row omits suggested_org_id rather than persisting \"nil\"" do
      %Result{user: user} = admit_external(["unmapped-group"], "oidc|grp-audit-none")

      row =
        Platform.Audit.list(event_type: "platform.auth.external_admission", limit: 50)
        |> Enum.filter(&(&1.actor_id == user.id and &1.action == "holding"))
        |> List.last()

      assert row
      refute Map.has_key?(row.metadata, "suggested_org_id")
      assert row.metadata["group_match"] == "none"
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
    test "acme admin -> :full/external? false with admin role; non-acme member -> member role" do
      assert %Result{state: :full, external?: false, reason: nil, user: acme_user} =
               ExternalAdmission.admit(
                 %{
                   sub: "oidc|int-1",
                   email: "someone@acme.test",
                   name: "Internal Admin",
                   external_claim?: false
                 },
                 surface: :app
               )

      acme = Tenancy.get_org_by_slug!("acme")
      assert Repo.get_by!(OrgMembership, user_id: acme_user.id, org_id: acme.id).role == "admin"
      # Internal user is never routed to holding and never gets scoped external rows.
      assert external_membership_count(acme_user.id) == 0

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

      assert Repo.get_by!(OrgMembership, user_id: member_user.id, org_id: acme.id).role ==
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

  # ── Task 019ff7ff stage 3: the group-claim suggestion on queue rows ────
  #
  # `awaiting_setup/0` reads back the metadata stage 2 wrote into the durable
  # audit row. Every case below writes the audit row DIRECTLY so the read
  # path is exercised on its own — and so the pre-stage-2 shape (neither key
  # present) is expressible, which it no longer is through `admit/2`.
  describe "awaiting_setup/0 group-claim suggestion" do
    defp holding_user!(tag) do
      %User{}
      |> User.changeset(%{
        email: "queue-#{tag}@partner.example",
        name: "Queue #{tag}",
        oidc_sub: "oidc|queue-#{tag}"
      })
      |> Repo.insert!()
    end

    defp holding_audit!(user, metadata) do
      {:ok, _event} =
        Platform.Audit.record(%{
          event_type: "platform.auth.external_admission",
          actor_id: user.id,
          actor_type: "user",
          action: "holding",
          metadata: Map.merge(%{"reason" => "awaiting_grant", "email" => user.email}, metadata)
        })

      :ok
    end

    defp row_for(user_id) do
      Enum.find(ExternalAdmission.awaiting_setup(), &(&1.user_id == user_id))
    end

    test "a one-match row exposes the org id AND the resolved org" do
      org = tenant_org!()
      user = holding_user!("one")
      holding_audit!(user, %{"suggested_org_id" => org.id, "group_match" => "one"})

      row = row_for(user.id)

      assert row.suggested_org_id == org.id
      assert row.group_match == :one
      # Resolved for the template — the name comes off the struct, not a
      # second lookup in the markup.
      assert row.suggested_org.id == org.id
      assert row.suggested_org.name == org.name
    end

    test "a zero-match row suggests nothing — no default, no first org" do
      # An org exists and is the ONLY one a fallback could pick; the row must
      # still suggest nil.
      _org = tenant_org!()
      user = holding_user!("none")
      holding_audit!(user, %{"group_match" => "none"})

      row = row_for(user.id)

      assert row.suggested_org_id == nil
      assert row.suggested_org == nil
      assert row.group_match == :none
    end

    test "an ambiguous row suggests nil and says so" do
      _a = tenant_org!()
      _b = tenant_org!()
      user = holding_user!("ambig")
      holding_audit!(user, %{"group_match" => "ambiguous"})

      row = row_for(user.id)

      assert row.suggested_org_id == nil
      assert row.suggested_org == nil
      # The distinction matters to the form: "we found several" is not
      # "we found none".
      assert row.group_match == :ambiguous
    end

    test "a legacy row with neither key does not raise and degrades to nil/:none" do
      # Exactly the metadata shape rows written BEFORE stage 2 carry.
      _org = tenant_org!()
      user = holding_user!("legacy")

      {:ok, _event} =
        Platform.Audit.record(%{
          event_type: "platform.auth.external_admission",
          actor_id: user.id,
          actor_type: "user",
          action: "holding",
          metadata: %{"reason" => "awaiting_grant", "email" => user.email, "external?" => true}
        })

      row = row_for(user.id)

      assert row.reason == "awaiting_grant"
      assert row.suggested_org_id == nil
      assert row.suggested_org == nil
      assert row.group_match == :none
    end

    test "atom-keyed metadata is tolerated exactly as string-keyed is" do
      org = tenant_org!()
      user = holding_user!("atoms")

      {:ok, _event} =
        Platform.Audit.record(%{
          event_type: "platform.auth.external_admission",
          actor_id: user.id,
          actor_type: "user",
          action: "holding",
          metadata: %{reason: :awaiting_grant, suggested_org_id: org.id, group_match: :one}
        })

      row = row_for(user.id)

      assert row.reason == "awaiting_grant"
      assert row.suggested_org_id == org.id
      assert row.group_match == :one
    end

    test "an archived org yields nil — never a dangling id the form would render" do
      org = tenant_org!()
      user = holding_user!("archived")
      holding_audit!(user, %{"suggested_org_id" => org.id, "group_match" => "one"})

      # Sanity: the suggestion IS live before archiving, so the nil below is
      # caused by the archive and not by the fixture never having resolved.
      assert row_for(user.id).suggested_org_id == org.id

      {1, _} =
        Repo.update_all(
          from(o in Org, where: o.id == ^org.id),
          set: [archived_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )

      row = row_for(user.id)

      assert row.suggested_org_id == nil
      assert row.suggested_org == nil
      # The audit row still SAYS one org matched; only the resolution is gone.
      assert row.group_match == :one
    end

    test "an id naming a deleted org yields nil rather than raising" do
      user = holding_user!("deleted")
      gone_id = Ecto.UUID.generate()
      holding_audit!(user, %{"suggested_org_id" => gone_id, "group_match" => "one"})

      row = row_for(user.id)

      assert row.suggested_org_id == nil
      assert row.suggested_org == nil
    end

    test "a malformed suggested_org_id folds into nil, not a cast error" do
      user = holding_user!("junk")
      holding_audit!(user, %{"suggested_org_id" => "not-a-uuid", "group_match" => "one"})

      assert row_for(user.id).suggested_org_id == nil
    end

    test "one query resolves the whole batch — no per-row org lookup" do
      org = tenant_org!()

      for tag <- ~w(batch1 batch2 batch3) do
        user = holding_user!(tag)
        holding_audit!(user, %{"suggested_org_id" => org.id, "group_match" => "one"})
      end

      # Count the org SELECTs the queue load issues. Three suggesting rows
      # resolved N+1-style would be three; the batch resolve is one.
      parent = self()
      handler_id = "org-query-count-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :repo, :query],
        fn _e, _m, meta, _c ->
          # The handler runs in the process that issued the query, so the
          # pid check keeps a concurrently-running test's orgs query out of
          # this count (the sandbox runs shared here).
          if self() == parent and is_binary(meta[:query]) and
               String.contains?(meta[:query], ~s(FROM "orgs")) do
            send(parent, :org_query)
          end

          :ok
        end,
        nil
      )

      rows = ExternalAdmission.awaiting_setup()
      :telemetry.detach(handler_id)

      assert Enum.count(rows, &(&1.suggested_org_id == org.id)) == 3
      assert org_query_count() == 1
    end

    defp org_query_count(acc \\ 0) do
      receive do
        :org_query -> org_query_count(acc + 1)
      after
        0 -> acc
      end
    end
  end
end
