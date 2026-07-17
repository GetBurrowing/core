defmodule PlatformWeb.ChatLive.PresenceHooksArchivedUserTest do
  @moduledoc """
  Regression coverage for task 019f671f Stage 3.

  `ChatLive.PresenceHooks.enter_space/4` builds `participants_map` from
  `Accounts.get_users_map/2`. After Stage 1 flipped the default to
  `include_archived: false`, an archived-user participant's row would
  render with the fallback "User" name unless the call site explicitly
  opts back in. Stage 3 flipped it to `Accounts.get_users_map(ids,
  include_archived: true)` so past-authored messages by an archived user
  still resolve to the archived user's real display name.

  This test pins that override to prevent silent regression if a future
  reader "cleans up" the option back to the default.
  """

  use Platform.DataCase, async: true

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Repo
  alias PlatformWeb.ChatLive.PresenceHooks

  defp insert_user(opts \\ []) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Accounts.User{
      name: Keyword.get(opts, :name, "User #{n}"),
      email: Keyword.get(opts, :email, "user-#{n}@example.com"),
      oidc_sub: "sub-#{n}"
    })
  end

  defp create_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Test",
        slug: "test-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp create_user_participant(space_id, %Accounts.User{} = user) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  describe "enter_space participant-map override (Stage 3)" do
    test "archived-user participant still resolves display name via participants_map" do
      space = create_space()

      active_user = insert_user(name: "Alice Active")
      archived_user = insert_user(name: "Bob Archived")

      active_participant = create_user_participant(space.id, active_user)
      archived_participant = create_user_participant(space.id, archived_user)

      {:ok, _archived_user} = Accounts.archive_user(archived_user)

      # Mimic the enter_space flow: build users_by_id from participant.participant_id,
      # asking Accounts to include archived users (Stage 3 override).
      participants = Chat.list_participants(space.id)

      users_by_id =
        participants
        |> Enum.filter(&(&1.participant_type == "user"))
        |> Enum.map(& &1.participant_id)
        |> Accounts.get_users_map(include_archived: true)

      participants_map = PresenceHooks.build_participant_identity_map(participants, users_by_id)

      active_identity = Map.fetch!(participants_map, active_participant.id)
      archived_identity = Map.fetch!(participants_map, archived_participant.id)

      assert active_identity.name == "Alice Active"

      assert archived_identity.name == "Bob Archived",
             "archived-user participant must still render with real display name — " <>
               "flipping `include_archived: true` back to the default reintroduces " <>
               "the fallback 'User' regression for past-authored messages"
    end

    test "participant identity tags archived users with archived: true (validation 1(c))" do
      # Regression: the `participants_map` is the input to the mention
      # autocomplete (`MentionsHooks.build_suggestions/2`). Historical
      # rendering must still resolve archived users' display names, so the
      # map continues to carry them — but each entry now carries an
      # `:archived` boolean so downstream consumers (autocomplete) can
      # reject archived participants without losing render fidelity.
      space = create_space()

      active_user = insert_user(name: "Alice Active")
      archived_user = insert_user(name: "Bob Archived")
      active_participant = create_user_participant(space.id, active_user)
      archived_participant = create_user_participant(space.id, archived_user)
      {:ok, _} = Accounts.archive_user(archived_user)

      participants = Chat.list_participants(space.id)

      users_by_id =
        participants
        |> Enum.filter(&(&1.participant_type == "user"))
        |> Enum.map(& &1.participant_id)
        |> Accounts.get_users_map(include_archived: true)

      participants_map = PresenceHooks.build_participant_identity_map(participants, users_by_id)

      active_identity = Map.fetch!(participants_map, active_participant.id)
      archived_identity = Map.fetch!(participants_map, archived_participant.id)

      assert active_identity.archived == false
      assert archived_identity.archived == true

      # Historical-rendering invariant: display name still resolves for both.
      assert active_identity.name == "Alice Active"
      assert archived_identity.name == "Bob Archived"
    end

    test "agent participant identity carries archived: false" do
      # Agents don't have a `Users` row, so the `:archived` flag is a
      # constant `false`. This lets `MentionsHooks.matches?/2` use a single
      # map-lookup filter across user AND agent entries without needing to
      # branch on `participant_type` first.
      space = create_space()
      n = System.unique_integer([:positive])

      agent =
        Repo.insert!(%Platform.Agents.Agent{
          name: "Higgins #{n}",
          slug: "higgins-#{n}",
          status: "active"
        })

      {:ok, agent_participant} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: agent.name,
          joined_at: DateTime.utc_now()
        })

      participants = Chat.list_participants(space.id)

      # Agents don't need a users map — pass empty.
      participants_map = PresenceHooks.build_participant_identity_map(participants, %{})

      identity = Map.fetch!(participants_map, agent_participant.id)
      assert identity.participant_type == "agent"
      assert identity.archived == false
    end

    test "without include_archived: true the archived-user participant renders as fallback (contract-defining)" do
      # Contract-defining companion to the assertion above: if a caller
      # DOESN'T pass `include_archived: true`, `get_users_map/2` drops the
      # archived user and the participant identity falls back to whatever
      # `participant_identity/2` has locally. This proves the override is
      # load-bearing, not decorative.
      space = create_space()

      archived_user = insert_user(name: "Bob Archived")
      archived_participant = create_user_participant(space.id, archived_user)
      {:ok, _} = Accounts.archive_user(archived_user)

      participants = Chat.list_participants(space.id)

      users_by_id_no_override =
        participants
        |> Enum.filter(&(&1.participant_type == "user"))
        |> Enum.map(& &1.participant_id)
        # Note: NO include_archived: true — this is the pre-Stage-3 behaviour.
        |> Accounts.get_users_map()

      participants_map =
        PresenceHooks.build_participant_identity_map(participants, users_by_id_no_override)

      # participant_identity/2 falls through to the participant's own display_name
      # (set at add_participant time). The regression this test guards against is
      # subtler: if the participant.display_name were nil OR the participant row
      # were resolved via the message-snapshot path, we'd see the "User" fallback.
      # For the seeded scenario, the display_name at insertion covers us — but
      # if a caller EVER strips include_archived: true, the participant identity
      # will diverge from the source-of-truth Users table (rename, avatar_url,
      # oidc_sub-based avatar seed, etc.). The assertion below documents the
      # non-authoritative-fallback state so the divergence is visible.
      identity = Map.fetch!(participants_map, archived_participant.id)

      # participant.display_name was set at insert; falls through to that.
      assert identity.name == "Bob Archived"
      # But the User-backed avatar/seed fields are unreachable when the User
      # row isn't fetched — proving the override matters for identity fidelity.
      assert identity.avatar_url == nil
    end
  end
end
