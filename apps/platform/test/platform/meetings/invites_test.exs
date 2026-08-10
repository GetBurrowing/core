defmodule Platform.Meetings.InvitesTest do
  @moduledoc """
  Pins the public invite surface on `Platform.Meetings` — task
  `019fb954-3ac2-7e43-9642-185280ac9983`, stage 3.

  What each group is actually defending:

    * **`invite_user/3` idempotency.** Asserting `{:ok, _}` twice passes on an
      implementation that inserts a duplicate row, so every idempotency test
      here asserts the ROW COUNT as well as the returned id.
    * **One token per ROW, never per meeting.** Asserting that two guests get
      two tokens passes on an implementation that hands out the same
      meeting-wide string twice, and asserting the tokens merely differ passes
      on one that signs the same `meeting_id` with a fresh nonce. So the
      distinctness tests verify BOTH tokens and assert the decoded payloads
      carry DIFFERENT `invite_id`s matching the two row ids. This is the
      decision the whole table exists to preserve: a forwardable meeting-wide
      link is unattributable, and an unattributable speaker means transcript
      lines with no owner and action items with no principal.
    * **Revocation is evidence.** `revoked_at` records *when* access was cut,
      so a second revoke must return the original timestamp, not a fresh one.
      Asserting only `{:ok, _}` twice passes on a re-stamping implementation.
    * **Fixtures that the API under test cannot produce.** The ordering test
      backdates `inserted_at` directly through `Repo`, because every row this
      module can mint is stamped `now()` — an ordering assertion built only
      from API calls tests insertion order, not the `ORDER BY`.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, project} = Tasks.create_project(%{name: "Invites Project #{n}"})

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Invites Space #{n}",
        slug: "invites-space-#{n}",
        kind: "meeting"
      })

    %Meeting{}
    |> Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space.id,
      slug: "invites-meeting-#{n}",
      name: "Invites Meeting",
      livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
    })
    |> Repo.insert!()
  end

  defp user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "invites-#{n}@example.com",
      name: "Invitee #{n}",
      oidc_sub: "oidc-invites-#{n}"
    })
    |> Repo.insert!()
  end

  defp count_invites(meeting_id) do
    Repo.aggregate(from(i in Invite, where: i.meeting_id == ^meeting_id), :count)
  end

  # ── invite_user/3 ───────────────────────────────────────────────────────────

  describe "invite_user/3" do
    test "inserts a row naming the user, derived kind :user" do
      meeting = meeting!()
      user = user!()

      assert {:ok, invite} = Meetings.invite_user(meeting, user.id)

      # Assert the database, not the return value.
      persisted = Repo.get!(Invite, invite.id)
      assert persisted.meeting_id == meeting.id
      assert persisted.user_id == user.id
      assert is_nil(persisted.revoked_at)
      assert Invite.kind(persisted) == :user
    end

    test "is idempotent — a second invite returns the SAME row and inserts no second one" do
      meeting = meeting!()
      user = user!()

      assert {:ok, first} = Meetings.invite_user(meeting, user.id)
      assert {:ok, second} = Meetings.invite_user(meeting, user.id)

      # Same id AND a count of one. Either alone is weak: matching ids could
      # come from a fetch that hid a duplicate insert, and a count could pass
      # on an implementation that returned an unrelated row.
      assert second.id == first.id
      assert count_invites(meeting.id) == 1
      # Sandbox-isolated, so the global count is this test's rows only.
      assert Repo.aggregate(Invite, :count) == 1
    end

    test "two different users on one meeting are two rows" do
      meeting = meeting!()
      a = user!()
      b = user!()

      assert {:ok, invite_a} = Meetings.invite_user(meeting, a.id)
      assert {:ok, invite_b} = Meetings.invite_user(meeting, b.id)

      refute invite_a.id == invite_b.id
      assert count_invites(meeting.id) == 2
    end

    test "the same user on two meetings is two rows — the index is scoped per meeting" do
      meeting_a = meeting!()
      meeting_b = meeting!()
      user = user!()

      assert {:ok, invite_a} = Meetings.invite_user(meeting_a, user.id)
      assert {:ok, invite_b} = Meetings.invite_user(meeting_b, user.id)

      refute invite_a.id == invite_b.id
      assert count_invites(meeting_a.id) == 1
      assert count_invites(meeting_b.id) == 1
    end

    test "optional display_name and email are stored" do
      meeting = meeting!()
      user = user!()

      assert {:ok, invite} =
               Meetings.invite_user(meeting, user.id,
                 display_name: "Jane Doe",
                 email: "jane@example.com"
               )

      persisted = Repo.get!(Invite, invite.id)
      assert persisted.display_name == "Jane Doe"
      assert persisted.email == "jane@example.com"
    end
  end

  # ── Malformed ids (the Repo lookup boundary) ────────────────────────────────
  #
  # `Repo.get_by/2` and a `where: x.id == ^value` on a UUID column both RAISE
  # `Ecto.Query.CastError` rather than returning nil, and `Platform.
  # RepoLookupBoundaryTest` exists because that defect has been re-fixed at one
  # site three times. These ids reach the API from a LiveView `params` map once
  # the host-facing invite UI lands downstream, so each site answers its own
  # miss value instead.
  #
  # The 16-byte case is the one worth writing down: `Ecto.UUID.cast/1` accepts
  # ANY 16-byte binary and hex-encodes it into a well-formed but INVENTED
  # UUID, so a cast-based guard would not raise — it would silently look up a
  # fabricated id. Only `Platform.UUID.valid?/1` rejects it.

  describe "malformed ids" do
    test "invite_user/3 refuses a non-UUID user_id as a changeset error, not a raise" do
      meeting = meeting!()

      for bad <- ["higgins", "abcdefghijklmnop"] do
        assert {:error, changeset} = Meetings.invite_user(meeting, bad)
        assert Keyword.has_key?(changeset.errors, :user_id)
      end

      assert count_invites(meeting.id) == 0
    end

    test "revoke_invite/1 answers {:error, :not_found} for a non-UUID id" do
      assert {:error, :not_found} = Meetings.revoke_invite("higgins")
      assert {:error, :not_found} = Meetings.revoke_invite("abcdefghijklmnop")
    end

    test "list_invites/2 answers [] for a non-UUID meeting_id" do
      assert Meetings.list_invites("higgins") == []
      assert Meetings.list_invites("abcdefghijklmnop", include_revoked: true) == []
    end
  end

  # ── invite_guest/2 ──────────────────────────────────────────────────────────

  describe "invite_guest/2" do
    test "inserts a guest row and mints a token bound to it" do
      meeting = meeting!()

      assert {:ok, %{invite: invite, token: token, url: url}} =
               Meetings.invite_guest(meeting, %{
                 display_name: "Jane Doe",
                 email: "jane@example.com"
               })

      persisted = Repo.get!(Invite, invite.id)
      assert persisted.meeting_id == meeting.id
      assert is_nil(persisted.user_id)
      assert persisted.display_name == "Jane Doe"
      assert persisted.email == "jane@example.com"
      assert Invite.kind(persisted) == :guest

      assert {:ok, payload} = GuestInvite.verify(token)
      assert payload.invite_id == invite.id
      assert payload.meeting_id == meeting.id
      assert payload.meeting_slug == meeting.slug
      assert payload.display_name == "Jane Doe"
      assert is_binary(payload.guest_space_id)

      assert url =~ meeting.slug
      assert url =~ token
    end

    # THE test. Two guests, one meeting: two rows, two DIFFERENT tokens, and
    # the tokens must name DIFFERENT invite rows. A meeting-wide link would
    # pass a two-tokens-exist assertion and fail this one.
    test "two guests on one meeting get two distinct tokens bound to two distinct rows" do
      meeting = meeting!()

      assert {:ok, %{invite: invite_a, token: token_a}} =
               Meetings.invite_guest(meeting, %{display_name: "Guest A"})

      assert {:ok, %{invite: invite_b, token: token_b}} =
               Meetings.invite_guest(meeting, %{display_name: "Guest B"})

      assert count_invites(meeting.id) == 2
      refute invite_a.id == invite_b.id

      # Distinct strings — necessary, nowhere near sufficient on its own.
      refute token_a == token_b

      assert {:ok, payload_a} = GuestInvite.verify(token_a)
      assert {:ok, payload_b} = GuestInvite.verify(token_b)

      # ...and each names its OWN row. This is what a shared meeting-wide
      # link cannot do, and what makes one guest revocable alone.
      assert payload_a.invite_id == invite_a.id
      assert payload_b.invite_id == invite_b.id
      refute payload_a.invite_id == payload_b.invite_id
    end

    # Not in the stage contract, pinned deliberately: the per-invite guest
    # chat space is identity bookkeeping for ONE guest. Sharing one across two
    # invites re-creates the attribution problem the per-row token solves —
    # two guests writing into a space that names neither of them.
    test "each guest invite gets its own guest chat space" do
      meeting = meeting!()

      assert {:ok, %{token: token_a}} = Meetings.invite_guest(meeting, %{display_name: "A"})
      assert {:ok, %{token: token_b}} = Meetings.invite_guest(meeting, %{display_name: "B"})

      assert {:ok, payload_a} = GuestInvite.verify(token_a)
      assert {:ok, payload_b} = GuestInvite.verify(token_b)

      refute payload_a.guest_space_id == payload_b.guest_space_id
    end

    # The shape assertions below (`{:error, changeset}`, an error keyed
    # `:display_name`, zero rows) are NOT enough on their own, and a mutation
    # probe proved it: deleting the changeset-level `validate_required` left
    # every one of them green. `Invite.changeset/2` already carries
    # `check_constraint(:display_name, name: :meeting_invites_identity_check)`,
    # so the database's own CHECK produces the same tuple with the same error
    # key — the caller cannot tell "refused before the query" from "refused by
    # Postgres" by shape.
    #
    # The difference is real, though: the pre-flight validation costs no round
    # trip and, unlike a constraint error, cannot abort an enclosing
    # transaction a future caller wraps this in. So the error's PROVENANCE is
    # asserted: `validation: :required` only appears when the changeset
    # rejected it, and `constraint: :check` only when Postgres did.
    test "requires display_name — refused by the changeset, before Postgres sees it" do
      meeting = meeting!()

      assert {:error, changeset} = Meetings.invite_guest(meeting, %{email: "nobody@example.com"})
      refute changeset.valid?
      assert {_msg, meta} = changeset.errors[:display_name]
      assert meta[:validation] == :required
      assert count_invites(meeting.id) == 0
    end

    test "a blank display_name is refused too — cast empties it, validation catches it" do
      meeting = meeting!()

      assert {:error, changeset} = Meetings.invite_guest(meeting, %{display_name: "   "})
      assert {_msg, meta} = changeset.errors[:display_name]
      assert meta[:validation] == :required
      assert count_invites(meeting.id) == 0
    end

    test "expires_at is written to the row and the token payload copies it" do
      meeting = meeting!()

      assert {:ok, %{invite: invite, token: token}} =
               Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      persisted = Repo.get!(Invite, invite.id)
      assert %DateTime{} = persisted.expires_at

      assert {:ok, payload} = GuestInvite.verify(token)

      # The row is authoritative; the payload carries a copy. If they can
      # drift, the resolver has two answers to "when does this expire?".
      assert payload.expires_at == DateTime.to_unix(persisted.expires_at)
    end

    test "defaults to a 24h window" do
      meeting = meeting!()

      assert {:ok, %{invite: invite}} =
               Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      persisted = Repo.get!(Invite, invite.id)
      seconds_out = DateTime.diff(persisted.expires_at, DateTime.utc_now())

      assert_in_delta seconds_out, 24 * 3600, 60
    end

    test "expires_in_hours overrides the default" do
      meeting = meeting!()

      assert {:ok, %{invite: invite}} =
               Meetings.invite_guest(meeting, %{display_name: "Jane", expires_in_hours: 2})

      persisted = Repo.get!(Invite, invite.id)
      seconds_out = DateTime.diff(persisted.expires_at, DateTime.utc_now())

      assert_in_delta seconds_out, 2 * 3600, 60
    end

    test "accepts string-keyed attrs" do
      meeting = meeting!()

      assert {:ok, %{invite: invite}} =
               Meetings.invite_guest(meeting, %{"display_name" => "Jane Doe"})

      assert Repo.get!(Invite, invite.id).display_name == "Jane Doe"
    end
  end

  # ── revoke_invite/1 ─────────────────────────────────────────────────────────

  describe "revoke_invite/1" do
    test "stamps revoked_at on the row" do
      meeting = meeting!()
      {:ok, %{invite: invite}} = Meetings.invite_guest(meeting, %{display_name: "Jane"})

      assert is_nil(Repo.get!(Invite, invite.id).revoked_at)
      assert {:ok, revoked} = Meetings.revoke_invite(invite)
      assert %DateTime{} = revoked.revoked_at
      assert %DateTime{} = Repo.get!(Invite, invite.id).revoked_at
    end

    test "is idempotent — a second revoke does NOT re-stamp the timestamp" do
      meeting = meeting!()
      {:ok, %{invite: invite}} = Meetings.invite_guest(meeting, %{display_name: "Jane"})

      assert {:ok, first} = Meetings.revoke_invite(invite)
      assert {:ok, second} = Meetings.revoke_invite(first)

      # The timestamp, not just the shape. `revoked_at` is evidence of when
      # access was cut; a re-stamping implementation rewrites that record and
      # still returns {:ok, _} both times.
      assert second.revoked_at == first.revoked_at
      assert Repo.get!(Invite, invite.id).revoked_at == first.revoked_at
    end

    # The struct the caller holds is not the row. This fixture is one the
    # public API cannot hand back after a revoke: a struct whose in-memory
    # `revoked_at` is still nil while the row's is set.
    test "a STALE struct does not re-stamp either — idempotency is decided on the row" do
      meeting = meeting!()
      {:ok, %{invite: stale}} = Meetings.invite_guest(meeting, %{display_name: "Jane"})

      assert is_nil(stale.revoked_at)
      assert {:ok, first} = Meetings.revoke_invite(stale.id)

      # `stale` still carries revoked_at: nil, exactly as it was loaded.
      assert {:ok, second} = Meetings.revoke_invite(stale)
      assert second.revoked_at == first.revoked_at
    end

    test "accepts an id as well as a struct" do
      meeting = meeting!()
      {:ok, %{invite: invite}} = Meetings.invite_guest(meeting, %{display_name: "Jane"})

      assert {:ok, revoked} = Meetings.revoke_invite(invite.id)
      assert %DateTime{} = revoked.revoked_at
    end

    test "an unknown id is {:error, :not_found}, not a crash" do
      assert {:error, :not_found} = Meetings.revoke_invite(Ecto.UUID.generate())
    end

    test "revoking one guest leaves the others' rows untouched" do
      meeting = meeting!()
      {:ok, %{invite: a}} = Meetings.invite_guest(meeting, %{display_name: "A"})
      {:ok, %{invite: b}} = Meetings.invite_guest(meeting, %{display_name: "B"})

      assert {:ok, _} = Meetings.revoke_invite(a)

      assert %DateTime{} = Repo.get!(Invite, a.id).revoked_at
      assert is_nil(Repo.get!(Invite, b.id).revoked_at)
    end
  end

  # ── list_invites/2 ──────────────────────────────────────────────────────────

  describe "list_invites/2" do
    test "returns the meeting's invitees and nobody else's" do
      meeting = meeting!()
      other = meeting!()
      user = user!()

      {:ok, mine} = Meetings.invite_user(meeting, user.id)
      {:ok, _theirs} = Meetings.invite_guest(other, %{display_name: "Not Mine"})

      assert [listed] = Meetings.list_invites(meeting.id)
      assert listed.id == mine.id
    end

    test "excludes revoked by default and includes them with include_revoked: true" do
      meeting = meeting!()
      {:ok, %{invite: kept}} = Meetings.invite_guest(meeting, %{display_name: "Kept"})
      {:ok, %{invite: killed}} = Meetings.invite_guest(meeting, %{display_name: "Killed"})

      {:ok, _} = Meetings.revoke_invite(killed)

      # Both halves. The exclusion alone passes on a filter that drops
      # everything; the inclusion alone passes on no filter at all.
      default_ids = meeting.id |> Meetings.list_invites() |> Enum.map(& &1.id)
      assert default_ids == [kept.id]

      all_ids =
        meeting.id |> Meetings.list_invites(include_revoked: true) |> Enum.map(& &1.id)

      assert Enum.sort(all_ids) == Enum.sort([kept.id, killed.id])
    end

    test "orders by inserted_at, not by insertion order" do
      meeting = meeting!()
      {:ok, %{invite: first_written}} = Meetings.invite_guest(meeting, %{display_name: "First"})
      {:ok, %{invite: second_written}} = Meetings.invite_guest(meeting, %{display_name: "Second"})

      # Backdate the row written SECOND so ordering by `inserted_at` and
      # ordering by insertion sequence disagree. Every row this module mints
      # is stamped now(), so this fixture cannot be built through the public
      # API — and without it the assertion would hold under no ORDER BY at all.
      backdated = DateTime.add(DateTime.utc_now(), -3600, :second)

      {1, _} =
        Repo.update_all(
          from(i in Invite, where: i.id == ^second_written.id),
          set: [inserted_at: backdated]
        )

      assert [second_written.id, first_written.id] ==
               meeting.id |> Meetings.list_invites() |> Enum.map(& &1.id)
    end

    test "returns [] for a meeting with no invites" do
      assert Meetings.list_invites(meeting!().id) == []
    end
  end
end
