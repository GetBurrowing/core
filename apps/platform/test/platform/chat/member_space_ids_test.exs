defmodule Platform.Chat.MemberSpaceIdsTest do
  @moduledoc """
  rbac-external-users M10 stage 1 — the pure presence/typing scoping primitives.

  `Chat.list_member_space_ids/2` and `Chat.Presence.external_scope_space_ids/1`
  are the single source of truth for the allowlist consumed by the ChatLive
  subscribe loop (stage 2) and the PresenceHooks consumer guards (stage 3), so
  they are unit-tested here without a LiveView.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp create_user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "u-#{n}@example.com", name: "User #{n}", oidc_sub: "oidc-#{n}"})
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

  defp member!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
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

  describe "list_member_space_ids/2" do
    test "returns only the spaces the user is a participant of" do
      user = create_user!()
      other = create_user!()
      a = channel()
      b = channel()

      add_user(a.id, user.id)
      # user is NOT a participant of b — only `other` is.
      add_user(b.id, other.id)

      ids = Chat.list_member_space_ids(user.id)

      assert a.id in ids
      refute b.id in ids
    end

    test "excludes archived spaces the user still participates in" do
      user = create_user!()
      live = channel()
      archived = channel()

      add_user(live.id, user.id)
      add_user(archived.id, user.id)
      {:ok, _} = Chat.archive_space(archived)

      ids = Chat.list_member_space_ids(user.id)

      assert live.id in ids
      refute archived.id in ids
    end

    test "returns an empty list for a user who participates in nothing" do
      user = create_user!()
      _a = channel()

      assert Chat.list_member_space_ids(user.id) == []
    end

    test "honors the :kind opt" do
      user = create_user!()
      chan = channel(%{kind: "channel"})

      dm =
        channel(%{kind: "dm", slug: "dm-#{System.unique_integer([:positive])}", name: "DM"})

      add_user(chan.id, user.id)
      add_user(dm.id, user.id)

      channel_ids = Chat.list_member_space_ids(user.id, kind: "channel")

      assert chan.id in channel_ids
      refute dm.id in channel_ids
    end
  end

  describe "list_viewer_presence_space_ids/1" do
    # Every absence assertion below shares a fixture with a positive control:
    # an unconditional `[]` is the exact shape of total breakage here, so a
    # test that only asserts absence would pass on a completely broken
    # function.
    setup do
      home = Tenancy.get_org_by_slug!("sxi")
      foreign = Tenancy.get_org_by_slug!("soylent")

      viewer = create_user!()
      colleague = create_user!()
      member!(viewer, home)
      member!(colleague, home)

      %{home: home, foreign: foreign, viewer: viewer, colleague: colleague}
    end

    test "returns a shared in-org space and withholds foreign-org and archived ones", ctx do
      shared = channel(%{org_id: ctx.home.id})
      foreign_space = channel(%{org_id: ctx.foreign.id})
      archived = channel(%{org_id: ctx.home.id})

      add_user(shared.id, ctx.viewer.id)
      add_user(shared.id, ctx.colleague.id)
      # The viewer somehow holds a participant row in the foreign org's space:
      # membership alone must not be enough to see it.
      add_user(foreign_space.id, ctx.viewer.id)
      add_user(archived.id, ctx.viewer.id)
      {:ok, _} = Chat.archive_space(archived)

      ids = Chat.list_viewer_presence_space_ids(ctx.viewer)

      # Positive control — without this the refutes below prove nothing.
      assert shared.id in ids
      refute foreign_space.id in ids
      refute archived.id in ids
    end

    test "a space the viewer does not participate in is withheld even in their own org", ctx do
      shared = channel(%{org_id: ctx.home.id})
      colleague_only = channel(%{org_id: ctx.home.id})

      add_user(shared.id, ctx.viewer.id)
      add_user(colleague_only.id, ctx.colleague.id)

      ids = Chat.list_viewer_presence_space_ids(ctx.viewer)

      assert shared.id in ids
      refute colleague_only.id in ids
    end

    test "a viewer resolving to :none gets [] rather than everything", ctx do
      shared = channel(%{org_id: ctx.home.id})
      unaffiliated = create_user!()

      add_user(shared.id, ctx.viewer.id)
      add_user(shared.id, unaffiliated.id)

      assert Tenancy.visibility(unaffiliated) == :none

      # Same fixture, same space, same participant row shape — the ONLY
      # difference is the org membership, so a function that returned `[]`
      # for everyone would fail on the control.
      assert shared.id in Chat.list_viewer_presence_space_ids(ctx.viewer)
      assert Chat.list_viewer_presence_space_ids(unaffiliated) == []
    end

    test "resolves identically from a preloaded user struct (zero-query path)", ctx do
      shared = channel(%{org_id: ctx.home.id})
      foreign_space = channel(%{org_id: ctx.foreign.id})
      add_user(shared.id, ctx.viewer.id)
      add_user(foreign_space.id, ctx.viewer.id)

      preloaded = Repo.preload(ctx.viewer, org_memberships: :org)
      assert {:orgs, _} = Tenancy.visibility(preloaded)

      ids = Chat.list_viewer_presence_space_ids(preloaded)

      assert shared.id in ids
      refute foreign_space.id in ids
    end

    test "non-user input returns []" do
      assert Chat.list_viewer_presence_space_ids(nil) == []
      assert Chat.list_viewer_presence_space_ids(%{}) == []
    end
  end

  describe "external_scope_space_ids/1" do
    test "returns a MapSet of the member space ids" do
      user = create_user!()
      a = channel()
      b = channel()
      add_user(a.id, user.id)
      add_user(b.id, user.id)

      scope = ChatPresence.external_scope_space_ids(user.id)

      assert %MapSet{} = scope
      assert MapSet.member?(scope, a.id)
      assert MapSet.member?(scope, b.id)
    end

    test "excludes archived and non-participant spaces (mirrors list_member_space_ids)" do
      user = create_user!()
      other = create_user!()
      member = channel()
      archived = channel()
      foreign = channel()

      add_user(member.id, user.id)
      add_user(archived.id, user.id)
      add_user(foreign.id, other.id)
      {:ok, _} = Chat.archive_space(archived)

      scope = ChatPresence.external_scope_space_ids(user.id)

      assert MapSet.member?(scope, member.id)
      refute MapSet.member?(scope, archived.id)
      refute MapSet.member?(scope, foreign.id)
    end
  end
end
