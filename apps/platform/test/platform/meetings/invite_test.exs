defmodule Platform.Meetings.InviteTest do
  @moduledoc """
  Pins `Platform.Meetings.Invite` — the declared invitee set introduced by task
  `019fb954-3ac2-7e43-9642-185280ac9983`.

  Three things are asserted, and the distinction between them is the point:

    * **Both account-holding and guest shapes persist.** The three invite kinds
      share one row shape, so the test has to prove the row shape actually
      accommodates a guest (no `user_id`) as well as a user.
    * **The database rules surface as changeset errors, not exceptions.** The
      identity CHECK and the partial unique index are enforced by Postgres;
      without the matching `check_constraint/3` / `unique_constraint/2` calls in
      the changeset, Ecto cannot translate the failure and the caller gets a
      raised `Postgrex.Error`. Every constraint test below asserts *both* that
      the insert failed and that it failed as a changeset error.
    * **What is written, not what is returned.** A valid-looking changeset
      proves nothing about the row; the persistence tests re-read from the
      database.
  """
  use Platform.DataCase, async: true

  alias Ecto.Changeset
  alias Platform.Accounts.User
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, project} = Tasks.create_project(%{name: "Invite Project #{n}"})

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Invite Space #{n}",
        slug: "invite-space-#{n}",
        kind: "meeting"
      })

    %Meeting{}
    |> Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space.id,
      slug: "invite-meeting-#{n}",
      name: "Invite Meeting",
      livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
    })
    |> Repo.insert!()
  end

  defp user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "invitee-#{n}@example.com",
      name: "Invitee #{n}",
      oidc_sub: "oidc-invitee-#{n}"
    })
    |> Repo.insert!()
  end

  defp insert_invite(attrs), do: %Invite{} |> Invite.changeset(attrs) |> Repo.insert()

  # ── Persistence ─────────────────────────────────────────────────────────────

  describe "user invites" do
    test "an invite naming a user persists with that user_id" do
      meeting = meeting!()
      user = user!()

      assert {:ok, invite} = insert_invite(%{meeting_id: meeting.id, user_id: user.id})

      # Assert the database, not the return value.
      persisted = Repo.get!(Invite, invite.id)
      assert persisted.meeting_id == meeting.id
      assert persisted.user_id == user.id
      assert is_nil(persisted.display_name)
      assert is_nil(persisted.revoked_at)
    end

    test "display_name is optional for a user invite — the user's own name is authoritative" do
      meeting = meeting!()
      user = user!()

      assert {:ok, invite} = insert_invite(%{meeting_id: meeting.id, user_id: user.id})
      assert is_nil(Repo.get!(Invite, invite.id).display_name)
    end
  end

  describe "guest invites" do
    test "a guest invite with only a display_name persists" do
      meeting = meeting!()

      assert {:ok, invite} =
               insert_invite(%{meeting_id: meeting.id, display_name: "Casey Guest"})

      persisted = Repo.get!(Invite, invite.id)
      assert is_nil(persisted.user_id)
      assert persisted.display_name == "Casey Guest"
    end

    test "a guest invite carries email and expires_at" do
      meeting = meeting!()
      expires_at = DateTime.add(DateTime.utc_now(), 86_400, :second)

      assert {:ok, invite} =
               insert_invite(%{
                 meeting_id: meeting.id,
                 display_name: "Casey Guest",
                 email: "casey@example.com",
                 expires_at: expires_at
               })

      persisted = Repo.get!(Invite, invite.id)
      assert persisted.email == "casey@example.com"
      assert DateTime.compare(persisted.expires_at, expires_at) == :eq
    end

    test "two distinct guests on one meeting both persist" do
      # The `[:meeting_id, :user_id]` unique index is partial
      # (`WHERE user_id IS NOT NULL`) precisely so this stays legal: multiple
      # guests on a meeting are the normal case, and each needs its own row so
      # each gets its own token and its own revocation surface.
      meeting = meeting!()

      assert {:ok, first} = insert_invite(%{meeting_id: meeting.id, display_name: "Guest One"})
      assert {:ok, second} = insert_invite(%{meeting_id: meeting.id, display_name: "Guest Two"})

      refute first.id == second.id

      assert [%Invite{}, %Invite{}] =
               Invite |> Ecto.Query.where(meeting_id: ^meeting.id) |> Repo.all()
    end
  end

  # ── Database rules, surfaced as changeset errors ─────────────────────────────

  describe "meeting_invites_identity_check" do
    test "a row with neither user_id nor display_name is rejected as a changeset error" do
      meeting = meeting!()

      # The failure MODE matters as much as the failure. Without
      # `check_constraint(:display_name, name: :meeting_invites_identity_check)`
      # in the changeset, Postgres still rejects the row but Ecto cannot
      # translate it, so `Repo.insert/1` RAISES `Postgrex.Error` instead of
      # returning `{:error, changeset}`. Asserting the tuple pins the
      # translation, not just the rejection.
      assert {:error, %Changeset{} = changeset} =
               insert_invite(%{meeting_id: meeting.id, email: "nobody@example.com"})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :display_name)

      assert Repo.aggregate(
               Ecto.Query.where(Invite, meeting_id: ^meeting.id),
               :count
             ) == 0
    end
  end

  describe "one invite per user per meeting" do
    test "a duplicate {meeting_id, user_id} is rejected as a changeset error" do
      meeting = meeting!()
      user = user!()

      assert {:ok, _first} = insert_invite(%{meeting_id: meeting.id, user_id: user.id})

      # Same failure-mode reasoning as the identity CHECK: without
      # `unique_constraint([:meeting_id, :user_id])` this raises rather than
      # returning a changeset.
      assert {:error, %Changeset{} = changeset} =
               insert_invite(%{meeting_id: meeting.id, user_id: user.id})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :meeting_id)

      assert Repo.aggregate(
               Ecto.Query.where(Invite, meeting_id: ^meeting.id),
               :count
             ) == 1
    end

    test "the same user may be invited to two different meetings" do
      # The unique index is scoped to the meeting. Without this, a constraint
      # accidentally widened to `[:user_id]` alone would still pass the
      # duplicate test above — that test only separates one direction.
      user = user!()
      first_meeting = meeting!()
      second_meeting = meeting!()

      assert {:ok, _} = insert_invite(%{meeting_id: first_meeting.id, user_id: user.id})
      assert {:ok, _} = insert_invite(%{meeting_id: second_meeting.id, user_id: user.id})

      assert Repo.aggregate(Ecto.Query.where(Invite, user_id: ^user.id), :count) == 2
    end
  end

  describe "cascading deletes" do
    test "deleting a meeting deletes its invites" do
      # `on_delete: :delete_all` on `meeting_id`. An invite without its meeting
      # is not a recoverable record, it is a dangling declaration.
      meeting = meeting!()
      user = user!()

      {:ok, user_invite} = insert_invite(%{meeting_id: meeting.id, user_id: user.id})
      {:ok, guest_invite} = insert_invite(%{meeting_id: meeting.id, display_name: "Guest"})

      Repo.delete!(meeting)

      refute Repo.get(Invite, user_invite.id)
      refute Repo.get(Invite, guest_invite.id)
    end

    test "deleting a user deletes their invites" do
      meeting = meeting!()
      user = user!()

      {:ok, invite} = insert_invite(%{meeting_id: meeting.id, user_id: user.id})

      Repo.delete!(user)

      refute Repo.get(Invite, invite.id)
    end
  end

  # ── Derived kind ────────────────────────────────────────────────────────────

  describe "kind/1" do
    test "returns :user when the invite names an account" do
      assert Invite.kind(%Invite{user_id: Ecto.UUID.generate()}) == :user
    end

    test "returns :guest when it does not" do
      assert Invite.kind(%Invite{user_id: nil, display_name: "Casey Guest"}) == :guest
    end

    test "classifies persisted rows, not just structs" do
      meeting = meeting!()
      user = user!()

      {:ok, user_invite} = insert_invite(%{meeting_id: meeting.id, user_id: user.id})
      {:ok, guest_invite} = insert_invite(%{meeting_id: meeting.id, display_name: "Casey Guest"})

      assert Invite.kind(Repo.get!(Invite, user_invite.id)) == :user
      assert Invite.kind(Repo.get!(Invite, guest_invite.id)) == :guest
    end
  end

  describe "changeset/2" do
    test "requires meeting_id" do
      changeset = Invite.changeset(%Invite{}, %{display_name: "Casey Guest"})
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :meeting_id)
    end

    test "a nonexistent meeting_id is a changeset error, not a raise" do
      assert {:error, %Changeset{} = changeset} =
               insert_invite(%{meeting_id: Ecto.UUID.generate(), display_name: "Casey Guest"})

      assert Keyword.has_key?(changeset.errors, :meeting_id)
    end

    test "revoked_at is writable — it is the revocation surface" do
      meeting = meeting!()
      {:ok, invite} = insert_invite(%{meeting_id: meeting.id, display_name: "Casey Guest"})

      revoked_at = DateTime.utc_now()

      {:ok, _} =
        invite |> Invite.changeset(%{revoked_at: revoked_at}) |> Repo.update()

      assert DateTime.compare(Repo.get!(Invite, invite.id).revoked_at, revoked_at) == :eq
    end
  end
end
