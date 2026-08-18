defmodule Platform.Chat.ExternalScopeTest do
  @moduledoc """
  Stack member 7 (rbac-external-users), stage 1 — the composable external
  read-scope primitive. Exercises the query building blocks in isolation:
  `Tenancy.external_user?/1`, and `ExternalScope.{for_user,member_space_ids,
  scope_spaces,scope_by_space_id,visible_space_id?}/*`.

  Task 01a011ed added `authorized_space?/2` to this module — the ADMISSION
  gate both the HTTP plug and the LiveView mount call. Its own describe block
  is at the bottom, and it is tested here directly rather than only through
  the plug, because a predicate only ever exercised through one of its two
  callers is how the two callers drifted in the first place.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.ExternalScope
  alias Platform.Chat.Message
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

  defp create_space(attrs \\ %{}) do
    default = %{name: "Space", slug: "sp-#{System.unique_integer([:positive])}", kind: "channel"}
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

  # ── Tenancy.external_user?/1 ───────────────────────────────────────────

  describe "Tenancy.external_user?/1 (reused, not redefined by M7)" do
    test "true for a user with an external membership" do
      user = create_user!()
      org = tenant_org!()
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})

      assert Tenancy.external_user?(user)
      assert Tenancy.external_user?(%{id: user.id})
    end

    test "false for a plain member" do
      user = create_user!()
      org = tenant_org!()
      plain_membership!(user, org)

      refute Tenancy.external_user?(user)
    end

    test "false for nil / non-user input" do
      refute Tenancy.external_user?(nil)
      refute Tenancy.external_user?(%{})
    end
  end

  # ── for_user/1 ─────────────────────────────────────────────────────────

  describe "for_user/1" do
    test "builds an external scope for an external user (from a %User{})" do
      user = create_user!()
      org = tenant_org!()
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})

      scope = ExternalScope.for_user(user)
      assert scope.external? == true
      assert scope.user_id == user.id
    end

    test "builds an internal (non-external) scope for a plain member (from a user_id binary)" do
      user = create_user!()
      org = tenant_org!()
      plain_membership!(user, org)

      scope = ExternalScope.for_user(user.id)
      assert scope.external? == false
      assert scope.user_id == user.id
    end

    test "nil (and non-user) input yields the unrestricted system scope" do
      assert %ExternalScope{user_id: nil, external?: false} = ExternalScope.for_user(nil)
      assert %ExternalScope{external?: false} = ExternalScope.for_user(:not_a_user)
    end
  end

  # ── member_space_ids/1 ─────────────────────────────────────────────────

  describe "member_space_ids/1" do
    test "returns exactly the user's participant space_ids" do
      user = create_user!()
      a = create_space()
      b = create_space()
      _c = create_space()
      add_user(a.id, user.id)
      add_user(b.id, user.id)

      scope = ExternalScope.for_user(user.id)
      ids = scope |> ExternalScope.member_space_ids() |> Repo.all() |> Enum.sort()

      assert ids == Enum.sort([a.id, b.id])
    end
  end

  # ── scope_spaces/2 ─────────────────────────────────────────────────────

  describe "scope_spaces/2" do
    setup do
      user = create_user!()
      org = tenant_org!()
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})

      a = create_space()
      b = create_space()
      add_user(a.id, user.id)

      ext = ExternalScope.for_user(user.id)
      {:ok, user: user, a: a, b: b, ext: ext}
    end

    test "external scope narrows a Space query to member spaces", %{a: a, b: b, ext: ext} do
      ids =
        Space
        |> where([s], s.id in ^[a.id, b.id])
        |> ExternalScope.scope_spaces(ext)
        |> Repo.all()
        |> Enum.map(& &1.id)

      assert ids == [a.id]
    end

    test "internal scope is identity", %{user: user, a: a, b: b} do
      int = ExternalScope.for_user(user.id) |> Map.put(:external?, false)

      ids =
        Space
        |> where([s], s.id in ^[a.id, b.id])
        |> ExternalScope.scope_spaces(int)
        |> Repo.all()
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids == Enum.sort([a.id, b.id])
    end

    test "nil scope is identity", %{a: a, b: b} do
      ids =
        Space
        |> where([s], s.id in ^[a.id, b.id])
        |> ExternalScope.scope_spaces(nil)
        |> Repo.all()
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids == Enum.sort([a.id, b.id])
    end
  end

  # ── scope_by_space_id/2 ────────────────────────────────────────────────

  describe "scope_by_space_id/2" do
    test "filters a Message query to member spaces under an external scope" do
      user = create_user!()
      org = tenant_org!()
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})

      a = create_space()
      b = create_space()
      pa = add_user(a.id, user.id)
      pb = add_user(b.id, create_user!().id)
      msg_a = post(a.id, pa.id, "in A")
      _msg_b = post(b.id, pb.id, "in B")

      ext = ExternalScope.for_user(user.id)

      ids =
        Message
        |> ExternalScope.scope_by_space_id(ext)
        |> Repo.all()
        |> Enum.map(& &1.id)

      assert ids == [msg_a.id]
    end

    test "nil scope is identity on a Message query" do
      a = create_space()
      pa = add_user(a.id, create_user!().id)
      msg_a = post(a.id, pa.id, "hi")

      ids =
        Message
        |> where([m], m.id == ^msg_a.id)
        |> ExternalScope.scope_by_space_id(nil)
        |> Repo.all()
        |> Enum.map(& &1.id)

      assert ids == [msg_a.id]
    end
  end

  # ── visible_space_id?/2 ────────────────────────────────────────────────

  describe "visible_space_id?/2" do
    setup do
      user = create_user!()
      org = tenant_org!()
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})

      a = create_space()
      b = create_space()
      add_user(a.id, user.id)

      {:ok, user: user, a: a, b: b, ext: ExternalScope.for_user(user.id)}
    end

    test "external scope: true for a member space, false for a non-member space", ctx do
      assert ExternalScope.visible_space_id?(ctx.a.id, ctx.ext)
      refute ExternalScope.visible_space_id?(ctx.b.id, ctx.ext)
    end

    test "internal and nil scopes are always true", ctx do
      int = Map.put(ctx.ext, :external?, false)
      assert ExternalScope.visible_space_id?(ctx.b.id, int)
      assert ExternalScope.visible_space_id?(ctx.b.id, nil)
    end
  end

  # ── authorized_space?/2 ────────────────────────────────────────────────
  #
  # The ADMISSION gate, as against the membership-only read scope above. It
  # was private to `PlatformWeb.Plugs.ExternalUserScope` until task 01a011ed
  # and is exercised directly here, so neither caller owns the proof.

  describe "authorized_space?/2" do
    setup do
      user = create_user!()
      org = tenant_org!()
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})

      {:ok, user: user, org: org}
    end

    test "true for a space the user holds a participant row in", ctx do
      space = create_space()
      add_user(space.id, ctx.user.id)

      assert ExternalScope.authorized_space?(ctx.user, space)
    end

    test "false for a space with no participant row", ctx do
      refute ExternalScope.authorized_space?(ctx.user, create_space())
    end

    test "true for a DM whose counterpart org is on the user's allowlist", ctx do
      dm = dm_with_counterpart!()
      {:ok, _} = Tenancy.allow_dm(ctx.user, dm.counterpart_org)

      # No participant row for the external user, so the allowlist branch is
      # the only thing that can admit this space.
      refute Chat.participant?(dm.space.id, ctx.user.id)
      assert ExternalScope.authorized_space?(ctx.user, dm.space)
    end

    test "false for a DM whose counterpart org is not on the allowlist", ctx do
      dm = dm_with_counterpart!()

      refute ExternalScope.authorized_space?(ctx.user, dm.space)
    end

    # The `kind: "dm"` guard is the whole difference between "a DM with someone
    # from an allowlisted org" and "any space containing someone from an
    # allowlisted org". Drop it and the allowlist alone admits an external user
    # to a CHANNEL, which is the widest escalation available in this predicate.
    test "false for a non-DM space holding a member of an allowlisted org", ctx do
      counterpart = create_user!()
      counterpart_org = tenant_org!()
      plain_membership!(counterpart, counterpart_org)

      channel = create_space(%{kind: "channel"})
      add_user(channel.id, counterpart.id)
      {:ok, _} = Tenancy.allow_dm(ctx.user, counterpart_org)

      refute ExternalScope.authorized_space?(ctx.user, channel)
    end

    test "false for a nil space", ctx do
      refute ExternalScope.authorized_space?(ctx.user, nil)
    end

    # The trap the move exists to prevent: `visible_space_id?/2` looks like a
    # drop-in gate and is not one. Swapping it in silently locks an external
    # user out of an allowlisted DM.
    test "an allowlisted DM is admitted here and refused by visible_space_id?/2", ctx do
      dm = dm_with_counterpart!()
      {:ok, _} = Tenancy.allow_dm(ctx.user, dm.counterpart_org)

      assert ExternalScope.authorized_space?(ctx.user, dm.space)

      refute ExternalScope.visible_space_id?(dm.space.id, ExternalScope.for_user(ctx.user.id)),
             "membership-only read scope must not be substituted for the admission gate"
    end
  end

  # A DM space carrying exactly one participant, who belongs to an org of
  # their own. Whether the caller may open it is then a pure function of
  # whether that org is on the caller's DM allowlist.
  defp dm_with_counterpart! do
    counterpart = create_user!()
    counterpart_org = tenant_org!()
    plain_membership!(counterpart, counterpart_org)

    space = create_space(%{kind: "dm"})
    add_user(space.id, counterpart.id)

    %{space: space, counterpart: counterpart, counterpart_org: counterpart_org}
  end
end
