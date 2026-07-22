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
