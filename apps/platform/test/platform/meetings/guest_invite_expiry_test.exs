defmodule Platform.Meetings.GuestInviteExpiryTest do
  @moduledoc """
  Host-chosen guest link expiry and per-person renewal on `Platform.Meetings`
  (task 01a19ea6 stage 1): `invite_guest/2`'s `:expires_at`,
  `guest_invite_expiry/3`, `meeting_end_expiry?/2`,
  `set_guest_invite_expiry/3` and `renew_guest_invite/4`.

  What the groups defend:

    * **The meeting end is the default, not 24h.** `guest_invite_expiry/3`
      is asserted against a meeting whose end is NOT 24 hours away, so an
      implementation that ignored `scheduled_end_at` cannot pass.
    * **Scoping is the authorization.** The expiry and renew controls carry
      a client-supplied invite id; a forged id from another meeting, a
      member row or a revoked row must write nothing, asserted on the ROW.
    * **Mint first, then revoke.** Renewing a lapsed guest must never leave
      `list_invites/2` empty, because an empty list widens
      `recipients_for_meeting/1` to every participant of the backing space.
      The ordering test watches the list from inside the mint.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defp meeting!(schedule \\ :future_end) do
    n = System.unique_integer([:positive])

    {:ok, project} = Tasks.create_project(%{name: "Guest Expiry Project #{n}"})

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Guest Expiry Space #{n}",
        slug: "guest-expiry-space-#{n}",
        kind: "meeting"
      })

    now = DateTime.utc_now()

    times =
      case schedule do
        # Three days out: far from both 24h and 7d, so each choice is told
        # apart from the others by value.
        :future_end ->
          %{
            scheduled_start_at: DateTime.add(now, 2 * 86_400, :second),
            scheduled_end_at: DateTime.add(now, 3 * 86_400, :second)
          }

        :past_end ->
          %{
            scheduled_start_at: DateTime.add(now, -2 * 3600, :second),
            scheduled_end_at: DateTime.add(now, -3600, :second)
          }

        :no_end ->
          %{}
      end

    %Meeting{}
    |> Meeting.changeset(
      Map.merge(
        %{
          project_id: project.id,
          chat_space_id: space.id,
          slug: "guest-expiry-meeting-#{n}",
          name: "Guest Expiry Meeting",
          livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
        },
        times
      )
    )
    |> Repo.insert!()
  end

  defp user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "guest-expiry-#{n}@example.com",
      name: "Member #{n}",
      oidc_sub: "oidc-guest-expiry-#{n}"
    })
    |> Repo.insert!()
  end

  defp guest!(meeting, name \\ "Guest Alpha", expires_at \\ nil) do
    attrs = %{display_name: name, email: nil}
    attrs = if expires_at, do: Map.put(attrs, :expires_at, expires_at), else: attrs
    {:ok, %{invite: invite}} = Meetings.invite_guest(meeting, attrs)
    invite
  end

  # A row whose link lapsed an hour ago. Backdated through Repo because no
  # API can mint an already-expired link.
  defp expire!(%Invite{} = invite) do
    invite
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))
    |> Repo.update!()
  end

  defp count_invites(meeting_id, opts \\ []) do
    meeting_id |> Meetings.list_invites(opts) |> length()
  end

  # The link the host would copy NOW, re-minted from the row (the same
  # property 01a18d0a's short links rely on), resolved as a guest would.
  defp resolve_current_link(meeting, invite) do
    invite = Repo.get!(Invite, invite.id)
    url = Meetings.guest_invite_link(meeting, invite)
    token = url |> URI.parse() |> Map.fetch!(:path) |> Path.basename()
    Meetings.resolve_guest_invite(meeting.slug, token)
  end

  defp resolve_token(meeting, token), do: Meetings.resolve_guest_invite(meeting.slug, token)

  defp close_to?(%DateTime{} = a, %DateTime{} = b, seconds \\ 5),
    do: abs(DateTime.diff(a, b, :second)) <= seconds

  # ── invite_guest/2 with :expires_at ─────────────────────────────────────────

  describe "invite_guest/2 with :expires_at" do
    test "a name-only guest gets that exact expires_at and nobody is contacted" do
      meeting = meeting!()
      at = DateTime.add(DateTime.utc_now(), 5 * 3600, :second)
      inbox_before = Repo.aggregate(Platform.Inbox.Item, :count)
      messages_before = Repo.aggregate(Platform.Chat.Message, :count)

      assert {:ok, %{invite: invite, token: token}} =
               Meetings.invite_guest(meeting, %{display_name: "Guest Alpha", email: nil, expires_at: at})

      persisted = Repo.get!(Invite, invite.id)
      assert DateTime.compare(persisted.expires_at, at) == :eq
      assert persisted.email == nil
      assert persisted.delivery_carrier == "guest_link"
      assert Repo.aggregate(Platform.Inbox.Item, :count) == inbox_before
      assert Repo.aggregate(Platform.Chat.Message, :count) == messages_before
      assert {:ok, %{display_name: "Guest Alpha"}} = resolve_token(meeting, token)
    end

    test ":expires_at wins over :expires_in_hours" do
      meeting = meeting!()
      at = DateTime.add(DateTime.utc_now(), 5 * 3600, :second)

      {:ok, %{invite: invite}} =
        Meetings.invite_guest(meeting, %{
          display_name: "Guest Alpha",
          expires_at: at,
          expires_in_hours: 1
        })

      assert DateTime.compare(invite.expires_at, at) == :eq
    end

    test "a past :expires_at writes no row" do
      meeting = meeting!()
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Meetings.invite_guest(meeting, %{display_name: "Guest Alpha", expires_at: past})

      assert Keyword.has_key?(changeset.errors, :expires_at)
      assert count_invites(meeting.id, include_revoked: true) == 0
    end

    test "a non-DateTime :expires_at writes no row" do
      meeting = meeting!()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Meetings.invite_guest(meeting, %{
                 display_name: "Guest Alpha",
                 expires_at: "2099-01-01T00:00:00Z"
               })

      assert Keyword.has_key?(changeset.errors, :expires_at)
      assert count_invites(meeting.id, include_revoked: true) == 0
    end

    test "without :expires_at the default stays 24 hours" do
      meeting = meeting!()
      invite = guest!(meeting)

      assert close_to?(invite.expires_at, DateTime.add(DateTime.utc_now(), 24 * 3600, :second))
    end
  end

  # ── guest_invite_expiry/3 and meeting_end_expiry?/2 ─────────────────────────

  describe "guest_invite_expiry/3" do
    setup do
      {:ok, now: DateTime.utc_now()}
    end

    test "a meeting with a future end: :meeting_end is that end", %{now: now} do
      meeting = meeting!(:future_end)

      assert Meetings.guest_invite_expiry(meeting, :meeting_end, now) == meeting.scheduled_end_at
      assert Meetings.meeting_end_expiry?(meeting, now)
      assert Meetings.guest_invite_expiry(meeting, :hours_24, now) == DateTime.add(now, 86_400)
      assert Meetings.guest_invite_expiry(meeting, :days_7, now) == DateTime.add(now, 7 * 86_400)
    end

    test "a meeting whose end is past falls back to now + 24h", %{now: now} do
      meeting = meeting!(:past_end)

      assert Meetings.guest_invite_expiry(meeting, :meeting_end, now) == DateTime.add(now, 86_400)
      refute Meetings.meeting_end_expiry?(meeting, now)
      assert Meetings.guest_invite_expiry(meeting, :hours_24, now) == DateTime.add(now, 86_400)
      assert Meetings.guest_invite_expiry(meeting, :days_7, now) == DateTime.add(now, 7 * 86_400)
    end

    test "a meeting with no end falls back to now + 24h", %{now: now} do
      meeting = meeting!(:no_end)

      assert Meetings.guest_invite_expiry(meeting, :meeting_end, now) == DateTime.add(now, 86_400)
      refute Meetings.meeting_end_expiry?(meeting, now)
      assert Meetings.guest_invite_expiry(meeting, :hours_24, now) == DateTime.add(now, 86_400)
      assert Meetings.guest_invite_expiry(meeting, :days_7, now) == DateTime.add(now, 7 * 86_400)
    end

    test "an unknown choice raises", %{now: now} do
      meeting = meeting!()

      assert_raise ArgumentError, fn -> Meetings.guest_invite_expiry(meeting, :forever, now) end
      assert_raise ArgumentError, fn -> Meetings.guest_invite_expiry(meeting, "days_7", now) end
    end
  end

  # ── set_guest_invite_expiry/3 ───────────────────────────────────────────────

  describe "set_guest_invite_expiry/3" do
    test "extends and shortens one row, and the current link follows the row" do
      meeting = meeting!()
      invite = guest!(meeting, "Guest Alpha", DateTime.add(DateTime.utc_now(), 3600, :second))

      assert {:ok, extended} = Meetings.set_guest_invite_expiry(meeting, invite.id, :days_7)
      assert close_to?(extended.expires_at, DateTime.add(DateTime.utc_now(), 7 * 86_400))
      assert close_to?(Repo.get!(Invite, invite.id).expires_at, extended.expires_at)
      assert {:ok, %{display_name: "Guest Alpha"}} = resolve_current_link(meeting, invite)

      assert {:ok, shortened} = Meetings.set_guest_invite_expiry(meeting, invite.id, :hours_24)
      assert close_to?(shortened.expires_at, DateTime.add(DateTime.utc_now(), 86_400))

      assert {:ok, at_end} = Meetings.set_guest_invite_expiry(meeting, invite.id, :meeting_end)
      assert DateTime.compare(at_end.expires_at, meeting.scheduled_end_at) == :eq
      assert {:ok, %{display_name: "Guest Alpha"}} = resolve_current_link(meeting, invite)
    end

    test "shortening reaches a link copied earlier: the row decides" do
      meeting = meeting!()
      {:ok, %{invite: invite, token: token}} =
        Meetings.invite_guest(meeting, %{
          display_name: "Guest Alpha",
          expires_at: DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)
        })

      assert {:ok, _} = resolve_token(meeting, token)
      assert {:ok, _} = Meetings.set_guest_invite_expiry(meeting, invite.id, :hours_24)
      # Still inside 24h, so the earlier link works...
      assert {:ok, _} = resolve_token(meeting, token)

      # ...and once the row lapses it is refused, though its own baked
      # expiry is days away.
      expire!(Repo.get!(Invite, invite.id))
      assert {:error, :expired} = resolve_token(meeting, token)
    end

    test "a forged id from another meeting writes nothing" do
      meeting = meeting!()
      other = meeting!()
      foreign = guest!(other, "Guest Beta")

      assert {:error, :not_found} = Meetings.set_guest_invite_expiry(meeting, foreign.id, :days_7)
      assert Repo.get!(Invite, foreign.id).expires_at == foreign.expires_at
    end

    test "a member row writes nothing" do
      meeting = meeting!()
      member = user!()
      {:ok, member_invite} = Meetings.invite_user(meeting, member.id)

      assert {:error, :not_found} =
               Meetings.set_guest_invite_expiry(meeting, member_invite.id, :days_7)

      assert Repo.get!(Invite, member_invite.id).expires_at == member_invite.expires_at
    end

    test "a revoked row writes nothing" do
      meeting = meeting!()
      invite = guest!(meeting)
      {:ok, _} = Meetings.revoke_invite(invite)

      assert {:error, :not_found} = Meetings.set_guest_invite_expiry(meeting, invite.id, :days_7)
      assert Repo.get!(Invite, invite.id).expires_at == invite.expires_at
    end

    test "a malformed id is :not_found, not a raise" do
      meeting = meeting!()
      assert {:error, :not_found} = Meetings.set_guest_invite_expiry(meeting, "nope", :days_7)
    end

    test "an expired row refuses, so a lapsed link is not silently revived" do
      meeting = meeting!()
      invite = meeting |> guest!() |> expire!()

      assert {:error, :expired} = Meetings.set_guest_invite_expiry(meeting, invite.id, :days_7)
      assert Repo.get!(Invite, invite.id).expires_at == invite.expires_at
    end
  end

  # ── renew_guest_invite/4 ────────────────────────────────────────────────────

  describe "renew_guest_invite/4" do
    test "an expired row gets a new row, token and link; the old row is revoked" do
      meeting = meeting!()

      {:ok, %{invite: old, token: old_token}} =
        Meetings.invite_guest(meeting, %{display_name: "Guest Alpha", email: nil})

      old = expire!(old)
      assert {:error, :expired} = resolve_token(meeting, old_token)

      assert {:ok, %{invite: new, token: new_token, url: url}} =
               Meetings.renew_guest_invite(meeting, old.id, :meeting_end, nil)

      refute new.id == old.id
      refute new_token == old_token
      assert is_binary(url)
      assert new.display_name == "Guest Alpha"
      assert DateTime.compare(new.expires_at, meeting.scheduled_end_at) == :eq
      assert Repo.get!(Invite, new.id).delivery_carrier == "guest_link"

      assert %DateTime{} = Repo.get!(Invite, old.id).revoked_at
      assert [listed] = Meetings.list_invites(meeting.id)
      assert listed.id == new.id

      assert {:error, :revoked} = resolve_token(meeting, old_token)
      assert {:ok, %{display_name: "Guest Alpha"}} = resolve_token(meeting, new_token)
    end

    test "the new row carries the old row's email" do
      meeting = meeting!()

      {:ok, %{invite: old}} =
        Meetings.invite_guest(meeting, %{display_name: "Guest Beta", email: "beta@example.test"})

      old = expire!(old)
      assert {:ok, %{invite: new}} = Meetings.renew_guest_invite(meeting, old.id, :days_7, nil)
      assert new.email == "beta@example.test"
      assert close_to?(new.expires_at, DateTime.add(DateTime.utc_now(), 7 * 86_400))
    end

    # The order the moduledoc promises: while the new row is minted, the old
    # one is still listed, so `list_invites/2` is never empty. Observed from
    # inside the mint through the delivery seam, which runs after the new
    # row is inserted and before `renew_guest_invite/4` returns.
    test "mints before it revokes: the invite list is never empty in between" do
      meeting = meeting!()
      old = meeting |> guest!() |> expire!()
      test_pid = self()

      :telemetry.attach(
        "guest-renew-order-#{old.id}",
        [:platform, :meetings, :invite_delivered],
        fn _event, _measurements, metadata, _config ->
          if metadata[:meeting_id] == meeting.id do
            send(test_pid, {:listed_during_mint, Meetings.list_invites(meeting.id)})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("guest-renew-order-#{old.id}") end)

      assert {:ok, %{invite: new}} = Meetings.renew_guest_invite(meeting, old.id, :meeting_end, nil)

      assert_received {:listed_during_mint, listed}
      ids = Enum.map(listed, & &1.id)
      assert old.id in ids
      assert new.id in ids
    end

    test "a live row returns :not_expired and writes nothing" do
      meeting = meeting!()
      invite = guest!(meeting)

      assert {:error, :not_expired} =
               Meetings.renew_guest_invite(meeting, invite.id, :meeting_end, nil)

      assert count_invites(meeting.id, include_revoked: true) == 1
      assert Repo.get!(Invite, invite.id).revoked_at == nil
    end

    test "a forged id from another meeting, a member row and a revoked row write nothing" do
      meeting = meeting!()
      other = meeting!()
      foreign = other |> guest!("Guest Beta") |> expire!()
      {:ok, member_invite} = Meetings.invite_user(meeting, user!().id)
      revoked = meeting |> guest!("Guest Gamma") |> expire!()
      {:ok, _} = Meetings.revoke_invite(revoked)

      for id <- [foreign.id, member_invite.id, revoked.id, "nope"] do
        assert {:error, :not_found} = Meetings.renew_guest_invite(meeting, id, :days_7, nil)
      end

      assert count_invites(meeting.id, include_revoked: true) == 2
      assert count_invites(other.id, include_revoked: true) == 1
      assert Repo.get!(Invite, foreign.id).revoked_at == nil
    end
  end
end
