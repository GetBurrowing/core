defmodule Platform.AccountsTest do
  @moduledoc """
  Covers the Stage 2 self-healing email-domain admin rule wired into
  `Platform.Accounts.find_or_create_from_oidc/1`.

  The hook fires on:

    * **INSERT** — every new user gets an `org_memberships` row in Fabrikam
      with role derived from `Platform.Tenancy.derive_role_from_email/1`.
    * **email-change UPDATE** — if a user's email refreshes to a Fabrikam
      address, they auto-promote to admin. There is **no auto-revoke**;
      offboarding is explicitly out of scope per the plan.

  Tenancy-level rule semantics (anchoring, case-insensitivity, idempotent
  upsert) live in `Platform.TenancyTest`; this file exercises only the
  Accounts-side wiring.
  """

  use Platform.DataCase, async: true

  alias Platform.Accounts
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── Helpers ──────────────────────────────────────────────────────────

  defp fabrikam_role(user) do
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")

    Repo.one(
      from(m in OrgMembership,
        where: m.user_id == ^user.id and m.org_id == ^fabrikam.id,
        select: m.role
      )
    )
  end

  defp fabrikam_membership_count(user) do
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")

    Repo.aggregate(
      from(m in OrgMembership, where: m.user_id == ^user.id and m.org_id == ^fabrikam.id),
      :count,
      :id
    )
  end

  defp oidc_attrs(overrides) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        sub: "accounts-oidc-#{n}",
        email: "accounts-#{n}@example.com",
        name: "Accounts Test #{n}"
      },
      overrides
    )
  end

  # `apply_derived_role/1`'s bootstrap-admin fallback (task 01a068f6 stage
  # 1) force-admins the FIRST-EVER membership on an empty root org,
  # regardless of the domain rule. This file is specifically about the
  # DOMAIN rule wiring (see moduledoc), not that fallback — it has its own
  # dedicated, isolated coverage in `tenancy_test.exs`. Seed an unrelated
  # membership first so Fabrikam is never empty in a test's sandboxed
  # transaction and the fallback never fires here.
  defp seed_bystander_fabrikam_membership! do
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")
    n = System.unique_integer([:positive])

    bystander =
      %Accounts.User{}
      |> Accounts.User.changeset(%{
        email: "bystander-#{n}@example.com",
        name: "Bystander #{n}",
        oidc_sub: "oidc-bystander-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: bystander.id, org_id: fabrikam.id, role: "member"})
    |> Repo.insert!()

    :ok
  end

  # ── INSERT hook ──────────────────────────────────────────────────────

  describe "find_or_create_from_oidc/1 — INSERT hook" do
    setup do
      seed_bystander_fabrikam_membership!()
    end

    test "a brand-new @example.com signup gets a Fabrikam admin membership" do
      attrs = oidc_attrs(%{email: "newhire@example.com"})
      assert {:ok, user} = Accounts.find_or_create_from_oidc(attrs)

      assert fabrikam_role(user) == "admin"
      assert fabrikam_membership_count(user) == 1
      assert Tenancy.fabrikam_admin?(user)
    end

    test "a brand-new @gmail.com signup gets a Fabrikam member membership" do
      attrs = oidc_attrs(%{email: "external@gmail.com"})
      assert {:ok, user} = Accounts.find_or_create_from_oidc(attrs)

      assert fabrikam_role(user) == "member"
      assert fabrikam_membership_count(user) == 1
      refute Tenancy.fabrikam_admin?(user)
    end

    test "the case-insensitive rule applies on insert" do
      attrs = oidc_attrs(%{email: "Mixed-Case@example.com"})
      assert {:ok, user} = Accounts.find_or_create_from_oidc(attrs)
      assert fabrikam_role(user) == "admin"
    end

    test "subdomain spoofs do NOT receive admin on insert" do
      attrs = oidc_attrs(%{email: "subdomain@us.example.com"})
      assert {:ok, user} = Accounts.find_or_create_from_oidc(attrs)
      assert fabrikam_role(user) == "member"
      refute Tenancy.fabrikam_admin?(user)
    end
  end

  # ── UPDATE / email-change hook ───────────────────────────────────────

  describe "find_or_create_from_oidc/1 — email-change hook" do
    setup do
      seed_bystander_fabrikam_membership!()
    end

    test "an existing member changing email to @example.com is promoted to admin" do
      sub = "promo-sub-#{System.unique_integer([:positive])}"

      {:ok, user} =
        Accounts.find_or_create_from_oidc(%{
          sub: sub,
          email: "alice@gmail.com",
          name: "Alice"
        })

      assert fabrikam_role(user) == "member"

      {:ok, promoted} =
        Accounts.find_or_create_from_oidc(%{
          sub: sub,
          email: "alice@example.com",
          name: "Alice"
        })

      assert promoted.id == user.id
      assert promoted.email == "alice@example.com"
      assert fabrikam_role(promoted) == "admin"
      assert fabrikam_membership_count(promoted) == 1
      assert Tenancy.fabrikam_admin?(promoted)
    end

    test "an existing admin (Fabrikam email) changing email to @gmail.com STAYS admin" do
      # DELIBERATE: offboarding is out of scope per plan Stage 2. The
      # hook is promote-only; a Fabrikam email changing to non-Fabrikam MUST
      # NOT auto-revoke admin. Stripping a departed employee is a
      # separate operation (planned for a later stage).
      sub = "offboard-sub-#{System.unique_integer([:positive])}"

      {:ok, fabrikam_user} =
        Accounts.find_or_create_from_oidc(%{
          sub: sub,
          email: "bob@example.com",
          name: "Bob"
        })

      assert fabrikam_role(fabrikam_user) == "admin"

      {:ok, after_change} =
        Accounts.find_or_create_from_oidc(%{
          sub: sub,
          email: "bob@gmail.com",
          name: "Bob"
        })

      assert after_change.id == fabrikam_user.id
      assert after_change.email == "bob@gmail.com"
      # Role is preserved — no auto-revoke.
      assert fabrikam_role(after_change) == "admin"
      assert fabrikam_membership_count(after_change) == 1
    end

    test "an existing user whose email does NOT change is unaffected by the hook" do
      sub = "noop-sub-#{System.unique_integer([:positive])}"
      email = "carol@gmail.com"

      {:ok, user} =
        Accounts.find_or_create_from_oidc(%{sub: sub, email: email, name: "Carol"})

      assert fabrikam_role(user) == "member"

      # Name refresh, same email — hook is a no-op.
      {:ok, refreshed} =
        Accounts.find_or_create_from_oidc(%{sub: sub, email: email, name: "Carol Renamed"})

      assert refreshed.id == user.id
      assert refreshed.name == "Carol Renamed"
      assert fabrikam_role(refreshed) == "member"
      assert fabrikam_membership_count(refreshed) == 1
    end

    test "a member changing email to another non-Fabrikam address is NOT auto-promoted" do
      sub = "lateral-sub-#{System.unique_integer([:positive])}"

      {:ok, user} =
        Accounts.find_or_create_from_oidc(%{
          sub: sub,
          email: "dave@gmail.com",
          name: "Dave"
        })

      assert fabrikam_role(user) == "member"

      {:ok, refreshed} =
        Accounts.find_or_create_from_oidc(%{
          sub: sub,
          email: "dave@yahoo.com",
          name: "Dave"
        })

      assert refreshed.email == "dave@yahoo.com"
      assert fabrikam_role(refreshed) == "member"
    end
  end

  # ── Soft-archive (task 019f671f Stage 1) ──────────────────────────────

  describe "archive_user/2 + unarchive_user/1" do
    setup do
      {:ok, target} =
        Accounts.find_or_create_from_oidc(oidc_attrs(%{email: "target@example.com"}))

      {:ok, actor} =
        Accounts.find_or_create_from_oidc(oidc_attrs(%{email: "actor@example.com"}))

      %{target: target, actor: actor}
    end

    test "archive_user/2 stamps archived_at (no actor, no reason)", %{target: target} do
      assert is_nil(target.archived_at)
      assert {:ok, archived} = Accounts.archive_user(target)
      refute is_nil(archived.archived_at)
      assert is_nil(archived.archived_by_user_id)
      assert is_nil(archived.archived_reason)
    end

    test "archive_user/2 with :actor stamps archived_by_user_id", %{target: target, actor: actor} do
      assert {:ok, archived} = Accounts.archive_user(target, actor: actor)
      assert archived.archived_by_user_id == actor.id
    end

    test "archive_user/2 with :reason stamps archived_reason", %{target: target} do
      assert {:ok, archived} = Accounts.archive_user(target, reason: "left the company")
      assert archived.archived_reason == "left the company"
    end

    test "archive_user/2 with actor + reason stamps both", %{target: target, actor: actor} do
      assert {:ok, archived} = Accounts.archive_user(target, actor: actor, reason: "offboard")
      refute is_nil(archived.archived_at)
      assert archived.archived_by_user_id == actor.id
      assert archived.archived_reason == "offboard"
    end

    test "unarchive_user/1 clears all three columns", %{target: target, actor: actor} do
      {:ok, archived} = Accounts.archive_user(target, actor: actor, reason: "test")

      assert {:ok, restored} = Accounts.unarchive_user(archived)

      assert is_nil(restored.archived_at)
      assert is_nil(restored.archived_by_user_id)
      assert is_nil(restored.archived_reason)
    end

    test "archive/unarchive round-trip preserves other fields", %{target: target, actor: actor} do
      original_email = target.email

      {:ok, archived} = Accounts.archive_user(target, actor: actor)
      {:ok, restored} = Accounts.unarchive_user(archived)

      assert restored.id == target.id
      assert restored.email == original_email
      assert restored.name == target.name
    end
  end

  describe "list_users/1 include_archived option" do
    setup do
      {:ok, active} =
        Accounts.find_or_create_from_oidc(oidc_attrs(%{email: "active@example.com"}))

      {:ok, archived_user} =
        Accounts.find_or_create_from_oidc(oidc_attrs(%{email: "archived@example.com"}))

      {:ok, archived_user} = Accounts.archive_user(archived_user)

      %{active: active, archived_user: archived_user}
    end

    test "defaults to excluding archived users", %{
      active: active,
      archived_user: archived_user
    } do
      ids = Accounts.list_users() |> Enum.map(& &1.id)
      assert active.id in ids
      refute archived_user.id in ids
    end

    test "include_archived: true includes archived users", %{
      active: active,
      archived_user: archived_user
    } do
      ids = Accounts.list_users(include_archived: true) |> Enum.map(& &1.id)
      assert active.id in ids
      assert archived_user.id in ids
    end

    test "query filter composes with archived filter by default", %{
      archived_user: archived_user
    } do
      # Even if the query would match, archived rows are dropped by default.
      ids = Accounts.list_users(query: "archived@example.com") |> Enum.map(& &1.id)
      refute archived_user.id in ids
    end

    test "query filter + include_archived: true returns matching archived rows", %{
      archived_user: archived_user
    } do
      ids =
        Accounts.list_users(query: "archived@example.com", include_archived: true)
        |> Enum.map(& &1.id)

      assert archived_user.id in ids
    end
  end

  describe "get_users_map/2 include_archived option" do
    setup do
      {:ok, active} =
        Accounts.find_or_create_from_oidc(oidc_attrs(%{email: "map-active@example.com"}))

      {:ok, archived_user} =
        Accounts.find_or_create_from_oidc(oidc_attrs(%{email: "map-archived@example.com"}))

      {:ok, archived_user} = Accounts.archive_user(archived_user)

      %{active: active, archived_user: archived_user}
    end

    test "get_users_map/1 defaults to dropping archived rows", %{
      active: active,
      archived_user: archived_user
    } do
      result = Accounts.get_users_map([active.id, archived_user.id])
      assert Map.has_key?(result, active.id)
      refute Map.has_key?(result, archived_user.id)
    end

    test "get_users_map/2 with include_archived: true returns archived rows", %{
      active: active,
      archived_user: archived_user
    } do
      result =
        Accounts.get_users_map([active.id, archived_user.id], include_archived: true)

      assert Map.has_key?(result, active.id)
      assert Map.has_key?(result, archived_user.id)
    end

    test "get_users_map/1 handles archived-only id list by returning empty map", %{
      archived_user: archived_user
    } do
      assert Accounts.get_users_map([archived_user.id]) == %{}
    end

    test "get_users_map/1 for empty list is empty map (regression guard)" do
      assert Accounts.get_users_map([]) == %{}
    end
  end

  describe "find_or_create_from_oidc/1 — archived user (Stage 5)" do
    test "returns {:error, :user_archived} for a sub whose user is archived, no mutation" do
      attrs = oidc_attrs(%{email: "archived-oidc@example.com"})

      {:ok, user} = Accounts.find_or_create_from_oidc(attrs)
      {:ok, archived} = Accounts.archive_user(user)

      snapshot = %{
        email: archived.email,
        name: archived.name,
        avatar_url: archived.avatar_url,
        archived_at: archived.archived_at
      }

      # Simulate a re-login attempt with a fresh (would-be-refreshed)
      # name + avatar payload from the OIDC provider.
      relogin_attrs = %{
        sub: user.oidc_sub,
        email: archived.email,
        name: "Renamed Post-Archive",
        avatar_url: "https://issuer.example.com/new-avatar-post-archive.png"
      }

      assert {:error, :user_archived} =
               Accounts.find_or_create_from_oidc(relogin_attrs)

      # Row is untouched — nothing on the archived user got refreshed.
      reloaded = Repo.get!(Platform.Accounts.User, user.id)
      assert reloaded.email == snapshot.email
      assert reloaded.name == snapshot.name
      assert reloaded.avatar_url == snapshot.avatar_url
      assert reloaded.archived_at == snapshot.archived_at
    end
  end

  describe "get_user/1 (unchanged by archival)" do
    # get_user/1 is deliberately NOT filtered by archived_at — Stage 5's
    # auth plugs need to look up the archived user in order to bounce it.
    # This test locks that behavior in.
    test "returns archived user unchanged" do
      {:ok, user} =
        Accounts.find_or_create_from_oidc(oidc_attrs(%{email: "auth-lookup@example.com"}))

      {:ok, archived} = Accounts.archive_user(user)

      fetched = Accounts.get_user(archived.id)
      assert fetched.id == archived.id
      refute is_nil(fetched.archived_at)
    end
  end

  describe "get_user/1 totality" do
    # `get_user/1` promises `User.t() | nil` and is named like a total
    # function. Before the `Platform.UUID.valid?/1` guard it raised
    # `Ecto.Query.CastError` on every non-UUID id, because `User`'s
    # `@primary_key` is `Platform.Types.UUIDv7` and its `cast/1` rejects
    # any non-36-character binary.
    #
    # WHICH OF THESE CASES ARE LOAD-BEARING. Reverting the guard fails
    # EXACTLY the malformed-id assertions below while
    # "returns nil for a valid but absent UUID" still PASSES. That
    # asymmetry is what makes this block non-vacuous: a suite written with
    # only the valid-but-absent UUID is fully green against the bug.
    #
    # `"higginshigginsxx"` is 16 characters and is the subtlest case —
    # `Ecto.UUID.cast/1` ACCEPTS a raw 16-byte binary (it hex-encodes it),
    # so a cast-only guard lets it through and `Repo` raises anyway. Do
    # not prune it as a duplicate of `"higgins"`; it is the only input
    # here that discriminates between the correct predicate and the
    # obvious-but-wrong one. See `Platform.UUID`'s moduledoc.

    test "returns nil for the actor sentinel \"system\"" do
      assert Accounts.get_user("system") == nil
    end

    test "returns nil for the qualified actor sentinel \"system:auto\"" do
      assert Accounts.get_user("system:auto") == nil
    end

    test "returns nil for an agent slug" do
      assert Accounts.get_user("higgins") == nil
    end

    test "returns nil for a 16-character slug that Ecto.UUID.cast/1 would accept" do
      # Guards the cast/dump gap: cast/1 hex-encodes this into a UUID,
      # dump/1 rejects it, so a bare-cast guard still raises inside Repo.
      assert {:ok, _} = Ecto.UUID.cast("higginshigginsxx")
      assert Accounts.get_user("higginshigginsxx") == nil
    end

    test "returns nil for the empty string" do
      assert Accounts.get_user("") == nil
    end

    test "returns nil for a valid but absent UUID" do
      assert Accounts.get_user(Platform.Types.UUIDv7.generate()) == nil
    end

    test "returns nil for non-binary ids" do
      assert Accounts.get_user(nil) == nil
      assert Accounts.get_user(:system) == nil
      assert Accounts.get_user(42) == nil
    end

    # "Total" must not degrade into "always nil" — these two lock in that
    # the guard made the function total by CASTING, not by short-circuiting.
    test "still returns the user for a real id" do
      {:ok, user} =
        Accounts.find_or_create_from_oidc(oidc_attrs(%{email: "totality@example.com"}))

      assert %Platform.Accounts.User{} = fetched = Accounts.get_user(user.id)
      assert fetched.id == user.id
    end

    test "still preloads org_memberships and the nested org for a real id" do
      {:ok, user} =
        Accounts.find_or_create_from_oidc(oidc_attrs(%{email: "totality-preload@example.com"}))

      fetched = Accounts.get_user(user.id)

      refute match?(%Ecto.Association.NotLoaded{}, fetched.org_memberships)
      assert [membership | _] = fetched.org_memberships
      refute match?(%Ecto.Association.NotLoaded{}, membership.org)
      assert membership.org.slug == "fabrikam"
    end
  end

  # ── relink_oidc_identity/2 (task 01a113ea stage 2) ───────────────────

  describe "relink_oidc_identity/2" do
    setup do
      seed_bystander_fabrikam_membership!()
    end

    test "relinks an archived user to a new sub and unarchives them; a login with the new sub finds the same row" do
      attrs = oidc_attrs(%{email: "relink-me@example.com"})
      {:ok, user} = Accounts.find_or_create_from_oidc(attrs)
      {:ok, archived} = Accounts.archive_user(user, reason: "sign-in removed")
      new_sub = "relinked-#{System.unique_integer([:positive])}"

      assert {:ok, relinked} = Accounts.relink_oidc_identity(archived, new_sub)

      assert relinked.id == user.id
      assert relinked.oidc_sub == new_sub
      assert is_nil(relinked.archived_at)
      assert is_nil(relinked.archived_by_user_id)
      assert is_nil(relinked.archived_reason)

      count_before = Repo.aggregate(Accounts.User, :count)

      assert {:ok, logged_in} =
               Accounts.find_or_create_from_oidc(%{
                 sub: new_sub,
                 email: attrs.email,
                 name: attrs.name
               })

      assert logged_in.id == user.id
      assert Repo.aggregate(Accounts.User, :count) == count_before

      # The old sub no longer reaches the row.
      assert {:ok, other} =
               Accounts.find_or_create_from_oidc(%{attrs | email: "old-sub@example.com"})

      refute other.id == user.id
    end

    test "refuses a user that is not archived and writes nothing" do
      {:ok, user} = Accounts.find_or_create_from_oidc(oidc_attrs(%{}))
      before = Repo.get!(Accounts.User, user.id)

      assert {:error, :not_archived} = Accounts.relink_oidc_identity(user, "never-applied")

      assert Repo.get!(Accounts.User, user.id) == before
    end

    test "a sub already held by another user returns a changeset and leaves the row unchanged" do
      {:ok, holder} = Accounts.find_or_create_from_oidc(oidc_attrs(%{}))
      {:ok, user} = Accounts.find_or_create_from_oidc(oidc_attrs(%{}))
      {:ok, archived} = Accounts.archive_user(user, reason: "sign-in removed")
      before = Repo.get!(Accounts.User, user.id)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Accounts.relink_oidc_identity(archived, holder.oidc_sub)

      assert {_, [constraint: :unique, constraint_name: _]} = changeset.errors[:oidc_sub]
      assert Repo.get!(Accounts.User, user.id) == before
    end
  end
end
