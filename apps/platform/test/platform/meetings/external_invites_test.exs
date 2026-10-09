defmodule Platform.Meetings.ExternalInvitesTest do
  @moduledoc """
  Pins `Meetings.resolve_invite_candidates/2` and
  `Meetings.invite_external_user/3` — task `019fb955-1d7b`, stage 2.

  What each group is actually defending:

    * **The fork cannot open on a member.** Asserting `email == nil` for a
      free-text query passes on an implementation that only checks the
      regex. The load-bearing case is a query that is BOTH a well-formed
      address AND an existing member's address — the only input where the
      two branches could both fire. Exclusion options are tested against
      that same case, because dropping the member from `users` is exactly
      how a naive implementation re-opens the fork on their own address.

    * **The unique index bites on the SECOND meeting.** `pending_external_grants`
      carries `unique_index([:email]) WHERE email IS NOT NULL` and it is
      NOT partial on `applied_at`. So the first invite of an address always
      works and proves nothing; every grant test here invites the same
      address to TWO meetings. Asserting the second call returned
      `{:ok, _}` is vacuous — it passes on an implementation that swallowed
      the constraint error and wrote no grant at all. So each asserts the
      ROW COUNT (exactly one grant survives) AND the CONTENTS (its
      `space_grants` names both meetings' spaces). Both halves are needed:
      the count alone passes on an implementation that never widened the
      grant, and the contents alone pass on one that wrote two rows.

    * **A count assertion needs a floor.** Every count assertion is preceded
      by asserting the count was 0 before the calls, so `== 1` is measuring
      this test's writes rather than agreeing with an empty table for the
      wrong reason.

    * **Fixtures the API cannot produce.** The applied-grant case stamps
      `applied_at` straight through `Repo`, because nothing on the public
      surface can apply a grant without also creating the user row that
      would divert the call into branch 1. The test asserts the stamp
      landed before proceeding — an unstamped fixture would silently test
      the unapplied path twice.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.PendingExternalGrant

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp org! do
    n = System.unique_integer([:positive])

    %Tenancy.Org{}
    |> Tenancy.Org.changeset(%{
      name: "ExtInvite Org #{n}",
      slug: "extinvite_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    })
    |> Repo.insert!()
  end

  defp meeting!(org) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{name: "ExtInvite Project #{n}", org_id: org.id})

    {:ok, space} =
      Chat.create_space(%{
        name: "ExtInvite Space #{n}",
        slug: "extinvite-space-#{n}",
        kind: "meeting",
        org_id: org.id
      })

    %Meeting{}
    |> Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space.id,
      slug: "extinvite-meeting-#{n}",
      name: "ExtInvite Meeting",
      livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
    })
    |> Repo.insert!()
  end

  defp user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "extinvite-#{n}@example.com",
          name: "ExtInvite #{n}",
          oidc_sub: "oidc-extinvite-#{n}"
        },
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp grant_count, do: Repo.aggregate(PendingExternalGrant, :count, :id)

  defp space_ids(%PendingExternalGrant{space_grants: grants}),
    do: Enum.map(grants, &Map.get(&1, "space_id"))

  defp participant?(space_id, user_id) do
    Repo.exists?(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "user" and
            p.participant_id == ^user_id
      )
    )
  end

  # ── resolve_invite_candidates/2 ─────────────────────────────────────────

  describe "resolve_invite_candidates/2" do
    test "a query matching a member yields the member and NO guest option" do
      # The whole point: this query is a perfectly well-formed address, so
      # a regex-only implementation would offer the external branch too.
      member = user!()

      assert %{users: users, email: nil} = Meetings.resolve_invite_candidates(member.email)
      assert Enum.map(users, & &1.id) == [member.id]
    end

    test "a well-formed address matching nobody yields the guest option and no users" do
      assert Meetings.resolve_invite_candidates("  stranger@partner.example  ") ==
               %{users: [], email: "stranger@partner.example"}
    end

    test "a query that is neither a member nor an address yields neither" do
      assert Meetings.resolve_invite_candidates("zzz-no-such-person-zzz") ==
               %{users: [], email: nil}
    end

    test "excluding the matched member does NOT re-open the guest option on their address" do
      # Regression guard for the fail-open: filtering the member out of
      # `users` empties the list, and an implementation that decides the
      # fork on the FILTERED list would then offer to stage an external
      # grant for a colleague who already has an account.
      member = user!()

      assert Meetings.resolve_invite_candidates(member.email,
               exclude_user_ids: [member.id]
             ) == %{users: [], email: nil}
    end

    test "exclude_emails suppresses an already-staged address" do
      addr = "already@partner.example"

      assert %{users: [], email: ^addr} = Meetings.resolve_invite_candidates(addr)

      assert Meetings.resolve_invite_candidates(addr, exclude_emails: [addr]) ==
               %{users: [], email: nil}
    end

    test "exclude_user_ids drops the member from users" do
      keep = user!()
      drop = user!(%{email: "extinvite-drop-#{System.unique_integer([:positive])}@example.com"})

      %{users: both} = Meetings.resolve_invite_candidates("ExtInvite")
      assert keep.id in Enum.map(both, & &1.id)
      assert drop.id in Enum.map(both, & &1.id)

      %{users: remaining} =
        Meetings.resolve_invite_candidates("ExtInvite", exclude_user_ids: [drop.id])

      refute drop.id in Enum.map(remaining, & &1.id)
      assert keep.id in Enum.map(remaining, & &1.id)
    end
  end

  # ── invite_external_user/3: branch 3, the stranger ──────────────────────

  describe "invite_external_user/3 — no user, no grant" do
    test "stages a least-privileged grant and writes an external invite row" do
      org = org!()
      meeting = meeting!(org)
      addr = "new@partner.example"

      assert grant_count() == 0

      assert {:ok, %Invite{} = invite} = Meetings.invite_external_user(meeting, addr)

      # The invite row: an external invite awaiting a login, not a guest.
      assert invite.email == addr
      assert invite.user_id == nil
      assert invite.expires_at == nil
      # `meeting_invites_identity_check` forbids a row with neither a
      # user_id nor a display_name, so the address doubles as the name.
      assert invite.display_name == addr

      assert grant_count() == 1
      grant = Repo.one!(PendingExternalGrant)

      assert grant.email == addr
      assert grant.target_org_id == org.id
      assert grant.applied_at == nil
      assert grant.dm_allowlist_org_ids == []

      assert grant.space_grants == [
               %{"space_id" => meeting.chat_space_id, "role" => "member"}
             ]
    end

    test "re-inviting the same address to the same meeting is idempotent both sides" do
      org = org!()
      meeting = meeting!(org)
      addr = "twice@partner.example"

      assert grant_count() == 0

      assert {:ok, first} = Meetings.invite_external_user(meeting, addr)
      assert {:ok, second} = Meetings.invite_external_user(meeting, addr)

      assert second.id == first.id
      assert Repo.aggregate(from(i in Invite, where: i.meeting_id == ^meeting.id), :count) == 1

      assert grant_count() == 1
      # A repeat append must not grow the list.
      assert space_ids(Repo.one!(PendingExternalGrant)) == [meeting.chat_space_id]
    end
  end

  # ── invite_external_user/3: branch 2, the second meeting ────────────────

  describe "invite_external_user/3 — second meeting, same address" do
    test "widens the existing grant instead of inserting a second one" do
      org = org!()
      first = meeting!(org)
      second = meeting!(org)
      addr = "repeat@partner.example"

      assert grant_count() == 0

      assert {:ok, _} = Meetings.invite_external_user(first, addr)
      assert {:ok, _} = Meetings.invite_external_user(second, addr)

      # COUNT: the unique index means a naive create_grant/1 either raises
      # or (if swallowed) leaves this at 1 with only the FIRST space. The
      # contents assertion below is what tells those apart.
      assert grant_count() == 1

      grant = Repo.one!(PendingExternalGrant)
      ids = space_ids(grant)

      assert first.chat_space_id in ids
      assert second.chat_space_id in ids
      assert length(ids) == 2

      # Both meetings render the invitee.
      assert Repo.aggregate(from(i in Invite, where: i.meeting_id == ^first.id), :count) == 1
      assert Repo.aggregate(from(i in Invite, where: i.meeting_id == ^second.id), :count) == 1
    end

    test "widens an ALREADY-APPLIED grant — the row lookup_by_email_or_sub/1 cannot see" do
      org = org!()
      first = meeting!(org)
      second = meeting!(org)
      addr = "applied@partner.example"

      assert grant_count() == 0
      assert {:ok, _} = Meetings.invite_external_user(first, addr)

      # Stamp applied_at directly: nothing public can apply a grant without
      # also creating the `users` row that would divert the second invite
      # into branch 1. Assert the stamp landed — an unstamped fixture would
      # silently re-test the unapplied path.
      applied =
        PendingExternalGrant
        |> Repo.one!()
        |> Ecto.Changeset.change(applied_at: DateTime.utc_now())
        |> Repo.update!()

      assert %DateTime{} = applied.applied_at

      # And confirm the trap is real: the applied-blind lookup returns nil
      # for the very row that still owns the unique-index slot.
      assert Platform.Tenancy.ExternalGrants.lookup_by_email_or_sub(%{email: addr, sub: nil}) ==
               nil

      assert %PendingExternalGrant{} =
               Platform.Tenancy.ExternalGrants.get_grant_by_email(addr)

      assert {:ok, %Invite{}} = Meetings.invite_external_user(second, addr)

      assert grant_count() == 1

      grant = Repo.one!(PendingExternalGrant)
      ids = space_ids(grant)

      assert first.chat_space_id in ids
      assert second.chat_space_id in ids
      assert length(ids) == 2
      # Widening a grant does not un-apply it.
      assert grant.applied_at != nil
    end
  end

  # ── invite_external_user/3: branch 1, the account-holder ────────────────

  describe "invite_external_user/3 — the address already has a user" do
    test "invites the user, seats them in the meeting space, and stages NO grant" do
      org = org!()
      meeting = meeting!(org)
      user = user!()

      assert grant_count() == 0

      assert {:ok, %Invite{} = invite} = Meetings.invite_external_user(meeting, user.email)

      assert invite.user_id == user.id
      assert invite.email == user.email

      assert participant?(meeting.chat_space_id, user.id)

      # The reason `add_space_participants/2` exists: a second grant row for
      # an already-provisioned user collides on the per-email unique index.
      assert grant_count() == 0
    end

    test "re-inviting the same account-holder does not duplicate the invite or the seat" do
      org = org!()
      meeting = meeting!(org)
      user = user!()

      assert {:ok, first} = Meetings.invite_external_user(meeting, user.email)
      assert {:ok, second} = Meetings.invite_external_user(meeting, user.email)

      assert second.id == first.id
      assert Repo.aggregate(from(i in Invite, where: i.meeting_id == ^meeting.id), :count) == 1

      assert Repo.aggregate(
               from(p in Participant,
                 where:
                   p.space_id == ^meeting.chat_space_id and p.participant_type == "user" and
                     p.participant_id == ^user.id
               ),
               :count
             ) == 1

      assert grant_count() == 0
    end
  end
end
