defmodule Platform.Meetings.InviteAccessTest do
  @moduledoc """
  Pins `Meetings.invited_to_slug?/2` and `Meetings.invited_to_space?/2` — the
  invite-row half of external meeting access.

  ## Every denial here is shown to be non-vacuous

  Both functions return `false` against an empty `meeting_invites` table, so a
  bare `refute` proves nothing: it passes on a fixture that silently failed to
  insert, on a fixture attached to the wrong meeting, and on an implementation
  that returns a constant. Each denial test therefore asserts the rows it means
  to be denied by ACTUALLY EXIST first — the table is non-empty and the specific
  row is loadable — before asserting the answer is `false`.

  ## The two-projects-one-slug fixture

  `meetings.slug` is unique per project, not globally. The ambiguity test proves
  its own fixture is ambiguous by showing that `Repo.get_by(Meeting, slug:)` —
  the shape this function deliberately does not use — RAISES
  `Ecto.MultipleResultsError` on it. Without that assertion the test would pass
  on a fixture where the second meeting never inserted, which is the single-row
  case it exists to distinguish itself from.

  ## The email-only row is the sponsor's scenario, not an edge case

  `invite_external_user/3` writes `user_id: nil` + `email` for an invitee with
  no account, and nothing backfills `user_id` when
  `Platform.Accounts.ExternalAdmission` later mints one. The case-mismatched
  email test is therefore the load-bearing one: a `user_id`-only gate passes
  every other test in this file and denies every real external invitee.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defp project! do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Invite Access Project #{n}"})
    project
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Invite Access Space #{n}",
        slug: "invite-access-space-#{n}",
        kind: "meeting"
      })

    space
  end

  defp meeting!(opts \\ []) do
    n = System.unique_integer([:positive])
    project = Keyword.get_lazy(opts, :project, &project!/0)
    slug = Keyword.get(opts, :slug, "invite-access-meeting-#{n}")

    %Meeting{}
    |> Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space!().id,
      slug: slug,
      name: "Invite Access Meeting",
      livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
    })
    |> Repo.insert!()
  end

  defp user!(opts \\ []) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: Keyword.get(opts, :email, "invite-access-#{n}@example.com"),
      name: "Invitee #{n}",
      oidc_sub: "oidc-invite-access-#{n}"
    })
    |> Repo.insert!()
  end

  defp invite!(meeting, attrs) do
    %Invite{}
    |> Invite.changeset(Map.merge(%{meeting_id: meeting.id, display_name: "Invitee"}, attrs))
    |> Repo.insert!()
  end

  # Asserts the row this test means to be denied by is really in the table.
  # `false` from an empty table is not evidence of a working guard.
  defp assert_row_present!(%Invite{id: id}) do
    assert Repo.aggregate(Invite, :count) > 0
    assert %Invite{} = Repo.get(Invite, id)
    :ok
  end

  # ── Admission ───────────────────────────────────────────────────────────────

  describe "invited_to_slug?/2 admits a live invite" do
    test "invited by user_id with no expiry" do
      meeting = meeting!()
      user = user!()
      invite!(meeting, %{user_id: user.id})

      assert Meetings.invited_to_slug?(meeting.slug, user)
    end

    test "invited by email only, with the account's address differing in CASE" do
      meeting = meeting!()
      user = user!(email: "Sponsor.Invitee@Example.COM")

      # Exactly the row `invite_external_user/3` writes for an address with no
      # account: user_id NULL, email set, no expiry, no token.
      invite!(meeting, %{user_id: nil, email: "sponsor.invitee@example.com"})

      assert user.email != "sponsor.invitee@example.com"
      assert Meetings.invited_to_slug?(meeting.slug, user)
    end

    test "expires_at in the future admits" do
      meeting = meeting!()
      user = user!()
      invite!(meeting, %{user_id: user.id, expires_at: DateTime.add(DateTime.utc_now(), 3600)})

      assert Meetings.invited_to_slug?(meeting.slug, user)
    end

    test "expires_at nil admits" do
      meeting = meeting!()
      user = user!()
      invite = invite!(meeting, %{user_id: user.id, expires_at: nil})

      assert is_nil(invite.expires_at)
      assert Meetings.invited_to_slug?(meeting.slug, user)
    end
  end

  # ── Denial ──────────────────────────────────────────────────────────────────

  describe "invited_to_slug?/2 denies" do
    test "an email-only row addressed to a DIFFERENT address, while that row exists" do
      meeting = meeting!()
      user = user!(email: "not-the-invitee@example.com")
      invite = invite!(meeting, %{user_id: nil, email: "someone-else@example.com"})

      assert_row_present!(invite)
      refute Meetings.invited_to_slug?(meeting.slug, user)
    end

    test "a revoked invite, while that row exists" do
      meeting = meeting!()
      user = user!()
      invite = invite!(meeting, %{user_id: user.id})

      assert Meetings.invited_to_slug?(meeting.slug, user)

      {:ok, revoked} = Meetings.revoke_invite(invite)

      assert_row_present!(revoked)
      refute is_nil(Repo.get(Invite, invite.id).revoked_at)
      refute Meetings.invited_to_slug?(meeting.slug, user)
    end

    test "an expired invite, while that row exists" do
      meeting = meeting!()
      user = user!()

      invite =
        invite!(meeting, %{user_id: user.id, expires_at: DateTime.add(DateTime.utc_now(), -60)})

      assert_row_present!(invite)
      assert DateTime.before?(Repo.get(Invite, invite.id).expires_at, DateTime.utc_now())
      refute Meetings.invited_to_slug?(meeting.slug, user)
    end

    test "a user invited to some OTHER meeting, while that invite exists" do
      invited_meeting = meeting!()
      other_meeting = meeting!()
      user = user!()
      invite = invite!(invited_meeting, %{user_id: user.id})

      assert_row_present!(invite)
      assert Meetings.invited_to_slug?(invited_meeting.slug, user)
      refute Meetings.invited_to_slug?(other_meeting.slug, user)
    end
  end

  # ── Slug is unique per project, not globally ────────────────────────────────

  describe "invited_to_slug?/2 with two meetings in different projects sharing one slug" do
    setup do
      slug = "shared-slug-#{System.unique_integer([:positive])}"

      first = meeting!(project: project!(), slug: slug)
      second = meeting!(project: project!(), slug: slug)

      assert first.project_id != second.project_id
      assert first.id != second.id

      # The fixture is only meaningful if it is genuinely ambiguous. This is the
      # lookup shape the implementation deliberately avoids; if it stopped
      # raising here, the two rows did not both land and every assertion below
      # would be testing the single-meeting case.
      assert_raise Ecto.MultipleResultsError, fn ->
        Repo.get_by(Meeting, slug: slug)
      end

      %{slug: slug, first: first, second: second}
    end

    test "admits when invited to exactly one of them, without raising", %{
      slug: slug,
      second: second
    } do
      user = user!()
      invite!(second, %{user_id: user.id})

      assert Meetings.invited_to_slug?(slug, user)
    end

    test "denies when invited to NEITHER of them, while other invites on both exist", %{
      slug: slug,
      first: first,
      second: second
    } do
      user = user!()
      stranger = user!()

      a = invite!(first, %{user_id: stranger.id})
      b = invite!(second, %{user_id: stranger.id})

      assert_row_present!(a)
      assert_row_present!(b)
      assert Meetings.invited_to_slug?(slug, stranger)
      refute Meetings.invited_to_slug?(slug, user)
    end
  end

  # ── invited_to_space?/2 ─────────────────────────────────────────────────────

  describe "invited_to_space?/2" do
    test "agrees with invited_to_slug?/2 on the same meeting" do
      meeting = meeting!()
      user = user!()
      invite = invite!(meeting, %{user_id: user.id})

      assert Meetings.invited_to_slug?(meeting.slug, user)
      assert Meetings.invited_to_space?(meeting.chat_space_id, user)

      {:ok, _} = Meetings.revoke_invite(invite)

      assert_row_present!(invite)
      refute Meetings.invited_to_slug?(meeting.slug, user)
      refute Meetings.invited_to_space?(meeting.chat_space_id, user)
    end

    test "admits the email-only invitee too" do
      meeting = meeting!()
      user = user!(email: "Space.Invitee@Example.COM")
      invite!(meeting, %{user_id: nil, email: "space.invitee@example.com"})

      assert Meetings.invited_to_space?(meeting.chat_space_id, user)
    end

    test "denies a chat space backing no meeting, while the user's invite exists" do
      meeting = meeting!()
      user = user!()
      invite = invite!(meeting, %{user_id: user.id})
      unbacked = space!()

      assert_row_present!(invite)
      assert Meetings.invited_to_space?(meeting.chat_space_id, user)
      refute Meetings.invited_to_space?(unbacked.id, user)
    end

    test "denies a malformed space id without raising, while the user's invite exists" do
      meeting = meeting!()
      user = user!()
      invite = invite!(meeting, %{user_id: user.id})

      assert_row_present!(invite)
      refute Meetings.invited_to_space?("system", user)
      refute Meetings.invited_to_space?("not-a-uuid-at-all", user)
    end
  end

  # ── Totality: these are called with values off a session assign ─────────────

  describe "bad input answers false rather than raising" do
    setup do
      meeting = meeting!()
      user = user!()
      invite = invite!(meeting, %{user_id: user.id})

      assert_row_present!(invite)
      assert Meetings.invited_to_slug?(meeting.slug, user)

      %{meeting: meeting, user: user}
    end

    test "nil and non-binary slug", %{user: user} do
      refute Meetings.invited_to_slug?(nil, user)
      refute Meetings.invited_to_slug?(123, user)
      refute Meetings.invited_to_slug?(%{}, user)
    end

    test "nil and non-binary space id", %{user: user} do
      refute Meetings.invited_to_space?(nil, user)
      refute Meetings.invited_to_space?(123, user)
    end

    test "nil user", %{meeting: meeting} do
      refute Meetings.invited_to_slug?(meeting.slug, nil)
      refute Meetings.invited_to_space?(meeting.chat_space_id, nil)
    end

    test "a user map with no id, or a non-binary id", %{meeting: meeting} do
      refute Meetings.invited_to_slug?(meeting.slug, %{email: "x@example.com"})
      refute Meetings.invited_to_slug?(meeting.slug, %{id: nil})
      refute Meetings.invited_to_slug?(meeting.slug, %{id: 7})
      refute Meetings.invited_to_space?(meeting.chat_space_id, %{id: nil})
    end

    test "a user whose email is nil still resolves a user_id invite", %{meeting: meeting} do
      user = user!()
      invite!(meeting, %{user_id: user.id})

      # The email disjunct must be dropped, not compared against nil — and
      # dropping it must not cost the user_id match.
      assert Meetings.invited_to_slug?(meeting.slug, %{id: user.id, email: nil})
      assert Meetings.invited_to_space?(meeting.chat_space_id, %{id: user.id, email: nil})
    end

    test "a user whose email is nil is denied an email-only invite", %{meeting: meeting} do
      user = user!()
      invite = invite!(meeting, %{user_id: nil, email: user.email})

      assert_row_present!(invite)
      assert Meetings.invited_to_slug?(meeting.slug, user)
      refute Meetings.invited_to_slug?(meeting.slug, %{id: user.id, email: nil})
    end
  end
end
