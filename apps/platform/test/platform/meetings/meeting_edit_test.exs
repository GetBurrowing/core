defmodule Platform.Meetings.MeetingEditTest do
  @moduledoc """
  Editing a scheduled meeting in place and soft-deleting it (task 01a1b281
  stage 2): `Meetings.update_meeting_for_user/3`, `preview_meeting_edit/2`,
  `delete_meeting_for_user/2`, and the mail `MeetingNotifier` sends for an
  edit.

  Mail is asserted on the `mail_deliveries` rows the outbox would hand to
  SMTP, as in `Platform.Meetings.InviteMailerTest`; nothing reaches SMTP.
  The notifier's `handle_info/2` is driven directly with the broadcast the
  edit made, AFTER the edit returned, so the added invitees already hold
  their own invitation (and a `mail_delivery_id`) when the update audience
  is resolved. That ordering is what makes the pre-add snapshot observable:
  without it, an added invitee would be in the audience and get an update
  too.

  async: false: it flips `:meetings_enabled`, `:mail_enabled` and the
  inbox/notification collaborators in application env.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Mail.Account
  alias Platform.Mail.Delivery
  alias Platform.Mail.Sender
  alias Platform.Meetings
  alias Platform.Meetings.Archive
  alias Platform.Meetings.CalendarFeed
  alias Platform.Meetings.Invite
  alias Platform.Meetings.InviteMailer
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.MeetingNotifier
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership
  alias PlatformTest.ICSContentLines, as: Lines

  defmodule Quiet do
    @moduledoc "Inbox and notifications stand-in: the email is under test, not these."
    def emit(attrs), do: {:ok, attrs}
    def fan_out_to_user(_user_id, _payload, _opts \\ []), do: :ok
    def fan_out_to_humans(_ids, _payload, _opts \\ []), do: :ok
  end

  setup do
    keys = [
      :meetings_enabled,
      :mail_enabled,
      :inbox_module,
      :notifications_module,
      :calendar_booking_mail_senders
    ]

    prior = for key <- keys, into: %{}, do: {key, Application.fetch_env(:platform, key)}

    Application.put_env(:platform, :meetings_enabled, true)
    Application.put_env(:platform, :mail_enabled, true)
    Application.put_env(:platform, :inbox_module, Quiet)
    Application.put_env(:platform, :notifications_module, Quiet)
    Application.delete_env(:platform, :calendar_booking_mail_senders)

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    org_id = Platform.TenancyFixtures.acme_org_id()
    sender!(org_id)
    host = member!(org_id, "Host One")
    member = member!(org_id, "Member Two")
    other = member!(org_id, "Member Three")
    newcomer = member!(org_id, "Member Four")

    project =
      Repo.insert!(%Project{
        name: "Meeting edit",
        slug: "meeting-edit-#{System.unique_integer([:positive])}",
        org_id: org_id
      })

    {start, finish} = window(2)

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Roadmap review",
        scheduled_start_at: start,
        scheduled_end_at: finish,
        created_by_user_id: host.id
      })

    Meetings.subscribe_to_project_meetings(project.id)

    %{
      org_id: org_id,
      host: host,
      member: member,
      other: other,
      newcomer: newcomer,
      project: project,
      meeting: meeting
    }
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp member!(org_id, name) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        name: name,
        email: "meeting-edit-#{n}@example.com",
        oidc_sub: "me-#{n}"
      })
      |> Repo.insert!()

    Repo.insert!(%OrgMembership{user_id: user.id, org_id: org_id, role: "member"})
    user
  end

  defp sender!(org_id) do
    account =
      Repo.insert!(%Account{
        org_id: org_id,
        name: "meetings-#{System.unique_integer([:positive])}",
        smtp_host: "smtp.example.com",
        smtp_port: 2525,
        smtp_tls: "none",
        internal_only: false
      })

    Repo.insert!(%Sender{
      account_id: account.id,
      key: "meetings",
      address: "meetings@example.com",
      display_name: "Example Org"
    })
  end

  # `days` from now, 30 minutes long, at microsecond precision.
  defp window(days) do
    start =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.add(days * 86_400, :second)
      |> Map.put(:microsecond, {0, 6})

    {start, DateTime.add(start, 1800, :second)}
  end

  defp deliveries(kind) do
    from(d in Delivery,
      where: d.responsibility == ^InviteMailer.responsibility(kind),
      order_by: d.inserted_at
    )
    |> Repo.all()
  end

  defp recipients(kind), do: kind |> deliveries() |> Enum.flat_map(& &1.recipients) |> Enum.sort()

  defp invite!(meeting, user, inviter) do
    {:ok, invite} = Meetings.invite_user(meeting, user.id, inviter_user_id: inviter.id)
    invite
  end

  defp guest!(meeting, email, host) do
    {:ok, %{invite: invite}} =
      Meetings.invite_guest(meeting, %{
        display_name: "Guest Five",
        email: email,
        host_user_id: host.id
      })

    invite
  end

  # Take the broadcast the edit made and hand it to the notifier, in this
  # process, after the edit returned.
  defp notify_edit! do
    assert_receive {:meeting_updated, %Meeting{} = meeting, info} = message
    {:noreply, _} = MeetingNotifier.handle_info(message, %{})
    {meeting, info}
  end

  # ── Edit: time ────────────────────────────────────────────────────────────

  describe "update_meeting_for_user/3 — a new time" do
    test "keeps id, slug and guest short codes; one update per emailed invitee, none to the inviter, SEQUENCE bumped",
         ctx do
      _self_invite = invite!(ctx.meeting, ctx.host, ctx.host)
      invite!(ctx.meeting, ctx.member, ctx.host)
      guest = guest!(ctx.meeting, "guest@example.com", ctx.host)
      [request | _] = deliveries(:invitation)
      {new_start, new_finish} = window(3)

      assert {:ok, %{meeting: moved, added: [], failed: []}} =
               Meetings.update_meeting_for_user(
                 ctx.meeting.id,
                 %{scheduled_start_at: new_start, scheduled_end_at: new_finish},
                 ctx.host
               )

      assert moved.id == ctx.meeting.id
      assert moved.slug == ctx.meeting.slug
      assert moved.scheduled_start_at == new_start
      assert moved.ical_sequence == 1
      assert Repo.get!(Invite, guest.id).short_code == guest.short_code
      assert Repo.get!(Invite, guest.id).revoked_at == nil

      {_meeting, info} = notify_edit!()
      assert info.changed == [:time]

      assert recipients(:updated) == Enum.sort([ctx.member.email, "guest@example.com"])
      refute ctx.host.email in recipients(:updated)

      for update <- deliveries(:updated) do
        assert update.calendar_method == "REQUEST"
        assert update.body =~ "Time changed"
        assert Lines.value!(update.calendar_ics, "UID") == CalendarFeed.uid(ctx.meeting)

        assert Lines.value!(update.calendar_ics, "UID") ==
                 Lines.value!(request.calendar_ics, "UID")

        assert Lines.value!(update.calendar_ics, "SEQUENCE") == "1"
      end

      assert deliveries(:cancelled) == []
    end

    test "an added invitee gets exactly one invitation, at the new SEQUENCE, and no update",
         ctx do
      invite!(ctx.meeting, ctx.member, ctx.host)
      {new_start, new_finish} = window(4)

      assert {:ok, %{added: [added]}} =
               Meetings.update_meeting_for_user(
                 ctx.meeting.id,
                 %{
                   scheduled_start_at: new_start,
                   scheduled_end_at: new_finish,
                   add_invitees: [%{kind: :user, user_id: ctx.newcomer.id}]
                 },
                 ctx.host
               )

      assert added.user_id == ctx.newcomer.id
      {_meeting, info} = notify_edit!()
      assert info.changed == [:time, :invitees]

      newcomer_invitations =
        Enum.filter(deliveries(:invitation), &(&1.recipients == [ctx.newcomer.email]))

      assert [invitation] = newcomer_invitations
      assert Lines.value!(invitation.calendar_ics, "SEQUENCE") == "1"
      assert recipients(:updated) == [ctx.member.email]
    end
  end

  # ── Edit: invitees ────────────────────────────────────────────────────────

  describe "update_meeting_for_user/3 — removing invitees" do
    test "the removed invitee gets exactly one METHOD:CANCEL; the rest get nothing", ctx do
      invite!(ctx.meeting, ctx.member, ctx.host)
      removed = invite!(ctx.meeting, ctx.other, ctx.host)

      assert {:ok, %{meeting: same}} =
               Meetings.update_meeting_for_user(
                 ctx.meeting.id,
                 %{remove_invite_ids: [removed.id]},
                 ctx.host
               )

      assert same.ical_sequence == 0
      assert %DateTime{} = Repo.get!(Invite, removed.id).revoked_at

      {_meeting, info} = notify_edit!()
      assert info.cancelled_invite_ids == [removed.id]
      assert info.update_invite_ids == []

      assert [cancel] = deliveries(:cancelled)
      assert cancel.recipients == [ctx.other.email]
      assert cancel.calendar_method == "CANCEL"
      assert Lines.value!(cancel.calendar_ics, "METHOD") == "CANCEL"
      assert Lines.value!(cancel.calendar_ics, "UID") == CalendarFeed.uid(ctx.meeting)
      assert Lines.value!(cancel.calendar_ics, "SEQUENCE") == "1"
      assert deliveries(:updated) == []
    end

    test "removing the last live invitee is refused and revokes nothing", ctx do
      only = invite!(ctx.meeting, ctx.member, ctx.host)

      assert {:error, :last_invitee} =
               Meetings.update_meeting_for_user(
                 ctx.meeting.id,
                 %{name: "Renamed", remove_invite_ids: [only.id]},
                 ctx.host
               )

      assert Repo.get!(Invite, only.id).revoked_at == nil
      assert Repo.get!(Meeting, ctx.meeting.id).name == "Roadmap review"
      refute_receive {:meeting_updated, _, _}
    end

    test "an invite id from another meeting is ignored, never revoked", ctx do
      invite!(ctx.meeting, ctx.member, ctx.host)

      {:ok, elsewhere} =
        Meetings.create_meeting(%{
          project_id: ctx.project.id,
          name: "Elsewhere",
          created_by_user_id: ctx.host.id
        })

      foreign = invite!(elsewhere, ctx.other, ctx.host)

      assert {:ok, _} =
               Meetings.update_meeting_for_user(
                 ctx.meeting.id,
                 %{remove_invite_ids: [foreign.id]},
                 ctx.host
               )

      assert Repo.get!(Invite, foreign.id).revoked_at == nil
    end
  end

  # ── Edit: notes and title ─────────────────────────────────────────────────

  describe "update_meeting_for_user/3 — notes and title" do
    test "a notes-only change bumps nothing and sends no mail", ctx do
      invite!(ctx.meeting, ctx.member, ctx.host)

      assert {:ok, %{meeting: noted}} =
               Meetings.update_meeting_for_user(
                 ctx.meeting.id,
                 %{"description" => "Bring the Q3 numbers."},
                 ctx.host
               )

      assert noted.description == "Bring the Q3 numbers."
      assert noted.ical_sequence == 0

      {_meeting, info} = notify_edit!()
      assert info.changed == [:description]
      assert info.update_invite_ids == []
      assert deliveries(:updated) == []
      assert deliveries(:cancelled) == []
    end

    test "a title-only change emails an update that says the title changed", ctx do
      invite!(ctx.meeting, ctx.member, ctx.host)

      assert {:ok, %{meeting: renamed}} =
               Meetings.update_meeting_for_user(ctx.meeting.id, %{name: "Roadmap"}, ctx.host)

      assert renamed.ical_sequence == 1
      notify_edit!()

      assert [update] = deliveries(:updated)
      assert update.recipients == [ctx.member.email]
      assert update.subject == "Updated: Roadmap"
      assert update.body =~ "Title changed"
      assert Lines.value!(update.calendar_ics, "SUMMARY") == "Roadmap"
    end

    test "an edit that changes nothing writes and broadcasts nothing", ctx do
      invite!(ctx.meeting, ctx.member, ctx.host)

      assert {:ok, %{meeting: same}} =
               Meetings.update_meeting_for_user(
                 ctx.meeting.id,
                 %{name: "Roadmap review"},
                 ctx.host
               )

      assert same.updated_at == ctx.meeting.updated_at
      refute_receive {:meeting_updated, _, _}
    end

    test "an invalid time pair is a changeset error and no write", ctx do
      {start, finish} = window(3)

      assert {:error, %Ecto.Changeset{}} =
               Meetings.update_meeting_for_user(
                 ctx.meeting.id,
                 %{scheduled_start_at: finish, scheduled_end_at: start},
                 ctx.host
               )

      assert Repo.get!(Meeting, ctx.meeting.id).ical_sequence == 0
    end
  end

  # ── Edit: permission ──────────────────────────────────────────────────────

  describe "update_meeting_for_user/3 — who may edit what" do
    test "an invitee who is not an organizer is forbidden and nothing changes", ctx do
      invite!(ctx.meeting, ctx.member, ctx.host)

      assert {:error, :forbidden} =
               Meetings.update_meeting_for_user(ctx.meeting.id, %{name: "Hijacked"}, ctx.member)

      row = Repo.get!(Meeting, ctx.meeting.id)
      assert row.name == "Roadmap review"
      assert row.ical_sequence == 0
      refute_receive {:meeting_updated, _, _}
    end

    test "a cancelled meeting is not editable, and an unseen id is not_found", ctx do
      {:ok, _} = Meetings.cancel_meeting(ctx.meeting, nil)

      assert {:error, :forbidden} =
               Meetings.update_meeting_for_user(ctx.meeting.id, %{name: "Again"}, ctx.host)

      assert {:error, :not_found} =
               Meetings.update_meeting_for_user(Ecto.UUID.generate(), %{name: "x"}, ctx.host)

      assert {:error, :not_found} =
               Meetings.update_meeting_for_user("not-a-uuid", %{name: "x"}, ctx.host)
    end

    test "can_edit_meeting?/2: organizer yes, invitee no, over or live no", ctx do
      assert Meetings.can_edit_meeting?(ctx.meeting, ctx.host)
      refute Meetings.can_edit_meeting?(ctx.meeting, ctx.member)
      refute Meetings.can_edit_meeting?(%{ctx.meeting | status: "live"}, ctx.host)

      past = %{ctx.meeting | scheduled_end_at: DateTime.add(DateTime.utc_now(), -60, :second)}
      refute Meetings.can_edit_meeting?(past, ctx.host)
    end
  end

  # ── Preview ───────────────────────────────────────────────────────────────

  describe "preview_meeting_edit/2" do
    test "names exactly who the save will email, from the mailer's own rule", ctx do
      invite!(ctx.meeting, ctx.member, ctx.host)
      removed = invite!(ctx.meeting, ctx.other, ctx.host)
      {new_start, new_finish} = window(5)

      attrs = %{
        scheduled_start_at: new_start,
        scheduled_end_at: new_finish,
        remove_invite_ids: [removed.id],
        add_invitees: [%{kind: :user, user_id: ctx.newcomer.id}]
      }

      preview = Meetings.preview_meeting_edit(ctx.meeting, attrs)

      assert preview.changed == [:time, :invitees]
      assert Enum.map(preview.update_recipients, & &1.email) == [ctx.member.email]
      assert Enum.map(preview.cancel_recipients, & &1.email) == [ctx.other.email]
      assert Enum.map(preview.invite_recipients, & &1.email) == [ctx.newcomer.email]
      assert preview.emails?
      assert preview.link == "/meetings/#{ctx.meeting.slug}"
      assert preview.refusal == nil

      # The save sends to the same people the preview named.
      {:ok, _} = Meetings.update_meeting_for_user(ctx.meeting.id, attrs, ctx.host)
      notify_edit!()

      assert recipients(:updated) == [ctx.member.email]
      assert recipients(:cancelled) == [ctx.other.email]

      assert ctx.newcomer.email in recipients(:invitation)
    end

    test "notes only: nobody is emailed; last invitee: the refusal", ctx do
      only = invite!(ctx.meeting, ctx.member, ctx.host)

      notes = Meetings.preview_meeting_edit(ctx.meeting, %{description: "Agenda"})
      assert notes.changed == [:description]
      refute notes.emails?
      assert notes.update_recipients == []

      last = Meetings.preview_meeting_edit(ctx.meeting, %{remove_invite_ids: [only.id]})
      assert last.refusal == :last_invitee
    end
  end

  # ── Delete ────────────────────────────────────────────────────────────────

  describe "delete_meeting_for_user/2" do
    test "a future scheduled meeting is refused; cancel first", ctx do
      assert {:error, :not_deletable} = Meetings.delete_meeting_for_user(ctx.meeting.id, ctx.host)
      assert Repo.get!(Meeting, ctx.meeting.id).deleted_at == nil
    end

    test "a live meeting is refused", ctx do
      {:ok, live} = Meetings.start_meeting(ctx.meeting)
      assert {:error, :not_deletable} = Meetings.delete_meeting_for_user(live.id, ctx.host)
    end

    test "an invitee who is not an organizer is forbidden", ctx do
      invite!(ctx.meeting, ctx.member, ctx.host)
      {:ok, _} = Meetings.cancel_meeting(ctx.meeting, nil)

      assert {:error, :forbidden} = Meetings.delete_meeting_for_user(ctx.meeting.id, ctx.member)
      assert Repo.get!(Meeting, ctx.meeting.id).deleted_at == nil
    end

    test "a deleted meeting disappears from every viewer-facing read; the transcript stays",
         ctx do
      invite!(ctx.meeting, ctx.member, ctx.host)
      {:ok, cancelled} = Meetings.cancel_meeting(ctx.meeting, nil)

      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          status: "recording"
        })

      # `create_transcript/1` derives the owner itself; pin it to this meeting
      # the way the FK (nilify_all) holds it.
      {1, _} =
        from(t in Platform.Meetings.Transcript, where: t.id == ^transcript.id)
        |> Repo.update_all(set: [meeting_id: cancelled.id])

      {from, to} =
        {DateTime.add(cancelled.scheduled_start_at, -60),
         DateTime.add(cancelled.scheduled_end_at, 60)}

      viewer = ctx.host
      id = cancelled.id

      # Visible before, so each refutation below is about the delete.
      assert Enum.any?(Meetings.list_meetings_for_user(viewer), &(&1.id == id))

      assert Enum.any?(
               Archive.search(viewer).matches ++ Archive.search(viewer).others,
               &(&1.id == id)
             )

      assert {:ok, deleted} = Meetings.delete_meeting_for_user(id, viewer)
      assert %DateTime{} = deleted.deleted_at
      assert deleted.deleted_by_user_id == viewer.id
      assert_receive {:meeting_deleted, %Meeting{id: ^id}}

      refute Enum.any?(Meetings.list_meetings_for_user(viewer), &(&1.id == id))
      refute Enum.any?(Meetings.list_meetings_in_range_for_user(viewer, from, to), &(&1.id == id))
      assert {:error, :not_found} = Meetings.get_meeting_for_user(viewer, id)
      assert {:error, :not_found} = Meetings.fetch_meeting_for_user(viewer, cancelled.slug)
      refute Enum.any?(Meetings.list_meetings_for_project(ctx.project.id), &(&1.id == id))
      refute Enum.any?(Meetings.list_all_meetings_unscoped(), &(&1.id == id))
      refute Enum.any?(Meetings.list_meetings_in_range(from, to), &(&1.id == id))

      refute Enum.any?(
               Archive.search(viewer).matches ++ Archive.search(viewer).others,
               &(&1.id == id)
             )

      assert {:error, :not_found} = Meetings.cancel_meeting_for_user(id, viewer)

      root = Platform.TenancyFixtures.root_admin!()
      refute Enum.any?(Meetings.list_meetings_for_user(root), &(&1.id == id))
      assert {:error, :not_found} = Meetings.fetch_meeting_for_user(root, cancelled.slug)

      # Left unfiltered on purpose.
      assert %Meeting{id: ^id} = Meetings.get_meeting(id)
      assert %{id: transcript_id, meeting_id: ^id} = Meetings.get_transcript(transcript.id)
      assert transcript_id == transcript.id

      # No mail for a delete.
      assert deliveries(:cancelled) == []
      assert deliveries(:updated) == []
    end

    test "a scheduled meeting whose end has passed is deletable and leaves the missed list",
         ctx do
      past_start =
        DateTime.utc_now()
        |> DateTime.truncate(:second)
        |> DateTime.add(-7200, :second)
        |> Map.put(:microsecond, {0, 6})

      {:ok, missed} =
        Meetings.create_meeting(%{
          project_id: ctx.project.id,
          name: "Missed sync",
          scheduled_start_at: past_start,
          scheduled_end_at: DateTime.add(past_start, 1800, :second),
          created_by_user_id: ctx.host.id
        })

      assert Enum.any?(Meetings.list_missed_meetings(), &(&1.id == missed.id))
      assert {:ok, _} = Meetings.delete_meeting_for_user(missed.id, ctx.host)
      refute Enum.any?(Meetings.list_missed_meetings(), &(&1.id == missed.id))
    end

    test "is idempotent: a second delete answers ok, keeps the first stamp, broadcasts once",
         ctx do
      {:ok, _} = Meetings.cancel_meeting(ctx.meeting, nil)
      {:ok, first} = Meetings.delete_meeting_for_user(ctx.meeting.id, ctx.host)
      assert_receive {:meeting_deleted, _}

      {:ok, second} = Meetings.delete_meeting_for_user(ctx.meeting.id, ctx.host)
      assert second.deleted_at == first.deleted_at
      refute_receive {:meeting_deleted, _}
    end

    test "an edit cannot reach a deleted meeting", ctx do
      {:ok, _} = Meetings.cancel_meeting(ctx.meeting, nil)
      {:ok, _} = Meetings.delete_meeting_for_user(ctx.meeting.id, ctx.host)

      assert {:error, :not_found} =
               Meetings.update_meeting_for_user(ctx.meeting.id, %{name: "Back"}, ctx.host)
    end
  end
end
