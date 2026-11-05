defmodule Platform.Meetings.InviteMailerTest do
  @moduledoc """
  The meeting emails end to end through the real invite paths (task
  01a1a933 stage 3): `Meetings.invite_user/3` / `invite_guest/2` ->
  `InviteDelivery` -> `InviteMailer` -> `Mail.Drafts` + `Mail.Dispatch`, and
  the cancel / reschedule paths. Assertions read the `mail_deliveries` rows
  the outbox would hand to SMTP, and the invite's receipt columns.

  async: false: it flips `:meetings_enabled`, `:mail_enabled` and the
  inbox/notification collaborators in application env.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Mail.Account
  alias Platform.Mail.Delivery
  alias Platform.Mail.Sender
  alias Platform.Meetings
  alias Platform.Meetings.CalendarFeed
  alias Platform.Meetings.Invite
  alias Platform.Meetings.InviteDelivery
  alias Platform.Meetings.InviteMailer
  alias Platform.Meetings.MeetingNotifier
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership
  alias PlatformTest.ICSContentLines, as: Lines

  @start ~U[2026-11-11 14:00:00.000000Z]
  @finish ~U[2026-11-11 14:30:00.000000Z]

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
    host = member!(org_id, "Host One")
    member = member!(org_id, "Member Two")

    project =
      Repo.insert!(%Project{
        name: "Invite mail",
        slug: "invite-mail-#{System.unique_integer([:positive])}",
        org_id: org_id
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Roadmap review",
        scheduled_start_at: @start,
        scheduled_end_at: @finish,
        created_by_user_id: host.id
      })

    %{org_id: org_id, host: host, member: member, meeting: meeting}
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp member!(org_id, name) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{name: name, email: "invite-mail-#{n}@example.com", oidc_sub: "im-#{n}"})
      |> Repo.insert!()

    Repo.insert!(%OrgMembership{user_id: user.id, org_id: org_id, role: "member"})
    user
  end

  defp sender!(org_id, attrs \\ %{}) do
    account =
      Repo.insert!(
        struct(
          %Account{
            org_id: org_id,
            name: "meetings-#{System.unique_integer([:positive])}",
            smtp_host: "smtp.example.com",
            smtp_port: 2525,
            smtp_tls: "none",
            internal_only: false
          },
          attrs
        )
      )

    Repo.insert!(%Sender{
      account_id: account.id,
      key: "meetings",
      address: "meetings@example.com",
      display_name: "Example Org"
    })

    account
  end

  defp deliveries(responsibility) do
    from(d in Delivery, where: d.responsibility == ^responsibility, order_by: d.inserted_at)
    |> Repo.all()
  end

  defp invitations, do: deliveries(InviteMailer.responsibility(:invitation))
  defp reload(%Invite{id: id}), do: Repo.get!(Invite, id)

  defp guest!(meeting, attrs) do
    {:ok, %{invite: invite}} =
      Meetings.invite_guest(meeting, Map.merge(%{display_name: "Guest Three"}, attrs))

    invite
  end

  # ── Invitations ───────────────────────────────────────────────────────────

  describe "a member invite" do
    test "enqueues exactly one delivery: From the meetings sender, Reply-To the inviter, To the member",
         ctx do
      sender!(ctx.org_id)

      assert {:ok, invite} =
               Meetings.invite_user(ctx.meeting, ctx.member.id, inviter_user_id: ctx.host.id)

      assert [delivery] = invitations()
      assert delivery.status == "queued"
      assert delivery.from_address == "meetings@example.com"
      assert delivery.reply_to == ctx.host.email
      assert delivery.recipients == [ctx.member.email]
      assert delivery.subject =~ "Invitation: Roadmap review - "
      assert delivery.calendar_method == "REQUEST"
      assert delivery.on_behalf_of_user_id == ctx.host.id
      assert Lines.value!(delivery.calendar_ics, "UID") == CalendarFeed.uid(ctx.meeting)
      assert Lines.value!(delivery.calendar_ics, "ATTENDEE") == "mailto:" <> ctx.member.email

      invite = reload(invite)
      assert invite.mail_delivery_id == delivery.id
      assert invite.mail_error == nil
      refute Meetings.invite_mail_failed?(Repo.preload(invite, :mail_delivery))
    end

    test "a double submit enqueues no second delivery", ctx do
      sender!(ctx.org_id)

      assert {:ok, first} =
               Meetings.invite_user(ctx.meeting, ctx.member.id, inviter_user_id: ctx.host.id)

      assert {:ok, second} =
               Meetings.invite_user(ctx.meeting, ctx.member.id, inviter_user_id: ctx.host.id)

      assert first.id == second.id
      assert length(invitations()) == 1
    end

    test "without an inviter_user_id the meeting's creator is the inviter", ctx do
      sender!(ctx.org_id)
      {:ok, _} = Meetings.invite_user(ctx.meeting, ctx.member.id)
      assert [%{reply_to: reply_to}] = invitations()
      assert reply_to == ctx.host.email
    end

    test "the inviter is never mailed their own invite", ctx do
      sender!(ctx.org_id)
      {:ok, invite} = Meetings.invite_user(ctx.meeting, ctx.host.id, inviter_user_id: ctx.host.id)
      assert invitations() == []
      assert reload(invite).mail_error == nil
    end
  end

  describe "opt-out" do
    test "a member who turned emails off gets none, a guest on the same meeting still does",
         ctx do
      sender!(ctx.org_id)
      {:ok, _} = Accounts.put_email_notifications(ctx.member.id, false)
      refute Accounts.email_notifications?(ctx.member.id)

      {:ok, member_invite} =
        Meetings.invite_user(ctx.meeting, ctx.member.id, inviter_user_id: ctx.host.id)

      guest = guest!(ctx.meeting, %{email: "guest@example.com", host_user_id: ctx.host.id})

      assert [delivery] = invitations()
      assert delivery.recipients == ["guest@example.com"]
      assert reload(guest).mail_delivery_id == delivery.id

      # Opting out is not a failure.
      member_invite = reload(member_invite)
      assert member_invite.mail_delivery_id == nil
      assert member_invite.mail_error == nil
    end

    test "only a literal false opts out" do
      assert Accounts.email_notifications?(%User{preferences: %{}})
      assert Accounts.email_notifications?(%User{preferences: %{"email_notifications" => nil}})
      assert Accounts.email_notifications?(%User{preferences: %{"email_notifications" => true}})
      refute Accounts.email_notifications?(%User{preferences: %{"email_notifications" => false}})
      assert Accounts.email_notifications_key() == "email_notifications"
    end
  end

  describe "guests" do
    test "a guest with an address gets their /g/ link and the calendar part", ctx do
      sender!(ctx.org_id)
      guest = guest!(ctx.meeting, %{email: "guest@example.com", host_user_id: ctx.host.id})

      assert [delivery] = invitations()
      assert delivery.recipients == ["guest@example.com"]
      assert delivery.body =~ "/g/#{guest.short_code}"
      assert Lines.value!(delivery.calendar_ics, "LOCATION") =~ "/g/#{guest.short_code}"
    end

    test "a name-only guest gets nothing, and that is not an error", ctx do
      sender!(ctx.org_id)
      guest = guest!(ctx.meeting, %{host_user_id: ctx.host.id})

      assert invitations() == []
      guest = reload(guest)
      assert guest.mail_error == nil
      assert guest.mail_delivery_id == nil
      refute Meetings.invite_mail_failed?(guest)
    end
  end

  describe "failures never fail the invite" do
    test "a refused policy leaves the invite committed with the same carrier, and records it",
         ctx do
      # internal_only: an address outside the org is refused.
      sender!(ctx.org_id, %{internal_only: true})

      assert {:ok, %{invite: invite}} =
               Meetings.invite_guest(ctx.meeting, %{
                 display_name: "Outside",
                 email: "outside@example.org",
                 host_user_id: ctx.host.id
               })

      invite = reload(invite)
      assert invite.delivery_carrier == "guest_link"
      assert invite.mail_error =~ "refused"
      assert %Delivery{status: "refused"} = Repo.get!(Delivery, invite.mail_delivery_id)
      assert Meetings.invite_mail_failed?(invite)
    end

    test "deliver/3 returns the carrier whatever the email did", ctx do
      sender!(ctx.org_id, %{internal_only: true})

      invite =
        %Invite{}
        |> Invite.changeset(%{
          meeting_id: ctx.meeting.id,
          display_name: "Outside",
          email: "outside@example.org"
        })
        |> Repo.insert!()

      assert InviteDelivery.deliver(invite, ctx.meeting, inviter_user_id: ctx.host.id) ==
               {:ok, :guest_link}

      assert reload(invite).mail_error =~ "refused"
    end

    test "no meetings sender: the invite is fine and says why no email went", ctx do
      assert {:ok, invite} =
               Meetings.invite_user(ctx.meeting, ctx.member.id, inviter_user_id: ctx.host.id)

      invite = reload(invite)
      assert invite.delivery_carrier == "internal_inbox_push"
      assert invite.mail_error =~ "no meetings sender"
      assert invite.mail_delivery_id == nil
      assert Meetings.invite_mail_failed?(invite)
    end

    test "a delivery later marked failed makes invite_mail_failed?/1 true", ctx do
      sender!(ctx.org_id)

      {:ok, invite} =
        Meetings.invite_user(ctx.meeting, ctx.member.id, inviter_user_id: ctx.host.id)

      invite = reload(invite)
      refute Meetings.invite_mail_failed?(Repo.preload(invite, :mail_delivery))

      Repo.get!(Delivery, invite.mail_delivery_id)
      |> Delivery.status_changeset(%{status: "failed", error: "550 mailbox unavailable"})
      |> Repo.update!()

      assert Meetings.invite_mail_failed?(Repo.preload(reload(invite), :mail_delivery))
    end

    test "notify_email: false sends and records nothing", ctx do
      sender!(ctx.org_id)

      {:ok, invite} =
        Meetings.invite_user(ctx.meeting, ctx.member.id,
          inviter_user_id: ctx.host.id,
          notify_email: false
        )

      guest =
        guest!(ctx.meeting, %{
          email: "guest@example.com",
          host_user_id: ctx.host.id,
          notify_email: false
        })

      assert invitations() == []
      assert reload(invite).mail_error == nil
      assert reload(guest).mail_error == nil
    end
  end

  # ── Cancel and reschedule ─────────────────────────────────────────────────

  describe "cancellation" do
    test "the member and the guest get METHOD:CANCEL for the SAME UID, at a higher SEQUENCE",
         ctx do
      sender!(ctx.org_id)
      {:ok, _} = Meetings.invite_user(ctx.meeting, ctx.member.id, inviter_user_id: ctx.host.id)
      guest!(ctx.meeting, %{email: "guest@example.com", host_user_id: ctx.host.id})
      [request | _] = invitations()

      {:ok, cancelled} = Meetings.cancel_meeting(ctx.meeting, nil)
      assert InviteMailer.send_cancellations(cancelled) == 2

      cancels = deliveries(InviteMailer.responsibility(:cancelled))

      assert cancels |> Enum.flat_map(& &1.recipients) |> Enum.sort() ==
               Enum.sort([ctx.member.email, "guest@example.com"])

      for cancel <- cancels do
        assert cancel.subject == "Cancelled: Roadmap review"
        assert cancel.calendar_method == "CANCEL"
        assert Lines.value!(cancel.calendar_ics, "METHOD") == "CANCEL"

        assert Lines.value!(cancel.calendar_ics, "UID") ==
                 Lines.value!(request.calendar_ics, "UID")

        assert String.to_integer(Lines.value!(cancel.calendar_ics, "SEQUENCE")) >
                 String.to_integer(Lines.value!(request.calendar_ics, "SEQUENCE"))
      end
    end

    test "a member who opted out after the invitation is not mailed the cancel", ctx do
      sender!(ctx.org_id)
      {:ok, _} = Meetings.invite_user(ctx.meeting, ctx.member.id, inviter_user_id: ctx.host.id)
      {:ok, _} = Accounts.put_email_notifications(ctx.member.id, false)
      {:ok, cancelled} = Meetings.cancel_meeting(ctx.meeting, nil)

      assert InviteMailer.send_cancellations(cancelled) == 0
    end
  end

  describe "reschedule" do
    @new_start ~U[2026-11-12 16:00:00.000000Z]
    @new_finish ~U[2026-11-12 17:00:00.000000Z]

    test "bumps ical_sequence in the same update and broadcasts the move", ctx do
      Meetings.subscribe_to_project_meetings(ctx.meeting.project_id)

      assert {:ok, moved} =
               Meetings.reschedule_meeting(
                 ctx.meeting,
                 %{scheduled_start_at: @new_start, scheduled_end_at: @new_finish},
                 ctx.host
               )

      assert moved.ical_sequence == 1
      assert moved.scheduled_start_at == @new_start
      assert_receive {:meeting_rescheduled, %{id: id, ical_sequence: 1}}
      assert id == ctx.meeting.id
    end

    test "the same pair is a no-op; others, other statuses and bad pairs are refused", ctx do
      assert {:ok, same} =
               Meetings.reschedule_meeting(
                 ctx.meeting,
                 %{scheduled_start_at: @start, scheduled_end_at: @finish},
                 ctx.host
               )

      assert same.ical_sequence == 0

      assert {:error, :forbidden} =
               Meetings.reschedule_meeting(
                 ctx.meeting,
                 %{scheduled_start_at: @new_start, scheduled_end_at: @new_finish},
                 ctx.member
               )

      assert {:error, %Ecto.Changeset{}} =
               Meetings.reschedule_meeting(
                 ctx.meeting,
                 %{scheduled_start_at: @new_finish, scheduled_end_at: @new_start},
                 ctx.host
               )

      {:ok, cancelled} = Meetings.cancel_meeting(ctx.meeting, nil)

      assert {:error, :not_reschedulable} =
               Meetings.reschedule_meeting(
                 cancelled,
                 %{scheduled_start_at: @new_start, scheduled_end_at: @new_finish},
                 ctx.host
               )
    end

    test "the notifier sends Updated: REQUESTs with the higher SEQUENCE and the new time", ctx do
      sender!(ctx.org_id)
      {:ok, _} = Meetings.invite_user(ctx.meeting, ctx.member.id, inviter_user_id: ctx.host.id)
      [request] = invitations()

      start_supervised!({MeetingNotifier, []})

      {:ok, _moved} =
        Meetings.reschedule_meeting(
          ctx.meeting,
          %{scheduled_start_at: @new_start, scheduled_end_at: @new_finish},
          ctx.host
        )

      update = wait_for(fn -> deliveries(InviteMailer.responsibility(:updated)) end)

      assert [update] = update
      assert update.subject == "Updated: Roadmap review"
      assert update.recipients == [ctx.member.email]
      assert update.calendar_method == "REQUEST"
      assert update.body =~ "Time changed"
      assert Lines.value!(update.calendar_ics, "UID") == Lines.value!(request.calendar_ics, "UID")
      assert Lines.value!(update.calendar_ics, "SEQUENCE") == "1"
      assert Lines.value!(request.calendar_ics, "SEQUENCE") == "0"
      assert Lines.value!(update.calendar_ics, "DTSTART") == "20261112T160000Z"
    end
  end

  # The notifier runs in its own process under the sandbox's shared mode.
  defp wait_for(fun, tries \\ 50) do
    case fun.() do
      [] when tries > 0 ->
        Process.sleep(20)
        wait_for(fun, tries - 1)

      result ->
        result
    end
  end
end
