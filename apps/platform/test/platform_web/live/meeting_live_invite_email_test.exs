defmodule PlatformWeb.MeetingLiveInviteEmailTest do
  @moduledoc """
  The invite email in the host's invite UI (task 01a1a933 stage 4): inviting
  from the live invite control queues an email, and a row whose email did
  not go says so, persistently, with a Copy link.

  Driven through the meeting details on /calendar, which renders the same
  `PlatformWeb.Components.Meetings.InviteControl.invite_row/1` the /meetings
  detail panel and its mobile sheet do, from the same
  `PlatformWeb.MeetingLive.detail_invite_rows/2`.

  async: false: flips `:meetings_enabled`, `:mail_enabled` and the
  inbox/notification collaborators in application env.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Mail.Delivery
  alias Platform.Meetings
  alias Platform.Meetings.InviteMailer
  alias Platform.Repo

  @in_details "[data-role=calendar-details]"
  @warning "Email not sent. Share the link instead."

  defmodule Quiet do
    @moduledoc "Inbox and notifications stand-in."
    def emit(attrs), do: {:ok, attrs}
    def fan_out_to_user(_user_id, _payload, _opts \\ []), do: :ok
    def fan_out_to_humans(_ids, _payload, _opts \\ []), do: :ok
  end

  setup %{conn: conn} do
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
    zone = midday_zone()

    %{
      conn: init_test_session(conn, current_user_id: host.id),
      org_id: org_id,
      host: host,
      zone: zone,
      meeting: meeting!(org_id, host, zone)
    }
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp member!(org_id, name) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "invite-email-ui-#{n}@example.com",
        name: "#{name} #{n}",
        oidc_sub: "invite-email-ui-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: org_id,
      role: "member"
    })

    user
  end

  # A meeting today at 10:30-11:15 in a zone where it is midday now, so the
  # calendar's week view shows it.
  defp meeting!(org_id, host, zone) do
    n = System.unique_integer([:positive])

    project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Invite email UI #{n}",
        slug: "invite-email-ui-#{n}",
        org_id: org_id
      })

    today = DateTime.utc_now() |> DateTime.shift_zone!(zone) |> DateTime.to_date()

    at = fn h, m ->
      today |> DateTime.new!(Time.new!(h, m, 0), zone) |> DateTime.shift_zone!("Etc/UTC")
    end

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Invite email review",
        scheduled_start_at: at.(10, 30),
        scheduled_end_at: at.(11, 15),
        created_by_user_id: host.id
      })

    meeting
  end

  defp midday_zone do
    offset = 12 - DateTime.utc_now().hour

    cond do
      offset == 0 -> "Etc/UTC"
      offset > 0 -> "Etc/GMT-#{offset}"
      true -> "Etc/GMT+#{-offset}"
    end
  end

  defp sender!(org_id, attrs \\ %{}) do
    account =
      Repo.insert!(
        struct(
          %Platform.Mail.Account{
            org_id: org_id,
            name: "meetings-ui-#{System.unique_integer([:positive])}",
            smtp_host: "smtp.example.com",
            smtp_port: 2525,
            smtp_tls: "none",
            internal_only: false
          },
          attrs
        )
      )

    Repo.insert!(%Platform.Mail.Sender{
      account_id: account.id,
      key: "meetings",
      address: "meetings@example.com"
    })

    account
  end

  defp invitations do
    responsibility = InviteMailer.responsibility(:invitation)
    Repo.all(from(d in Delivery, where: d.responsibility == ^responsibility))
  end

  defp open_meeting(conn, zone) do
    {:ok, view, _} = live(put_connect_params(conn, %{"timezone" => zone}), "/calendar")
    view |> element("[data-role=calendar-week] .cal-ev[data-kind=meeting]") |> render_click()
    view
  end

  defp row(invite),
    do: "#{@in_details} [data-role=meeting-invite-row][data-entry-id='#{invite.id}']"

  # ── Tests ─────────────────────────────────────────────────────────────────

  test "inviting a member from the live invite control queues exactly one email", ctx do
    sender!(ctx.org_id)
    invitee = member!(ctx.org_id, "Zed Newcomer")
    view = open_meeting(ctx.conn, ctx.zone)

    view |> element("#{@in_details} [data-role=meeting-invite-add-people]") |> render_click()

    view
    |> element("#{@in_details} [data-role=meeting-invite-search]")
    |> render_keyup(%{"value" => invitee.name})

    view
    |> element(
      "#{@in_details} [data-role=meeting-invite-candidate][data-user-id='#{invitee.id}']"
    )
    |> render_click()

    assert [delivery] = invitations()
    assert delivery.recipients == [invitee.email]
    assert delivery.reply_to == ctx.host.email
    assert delivery.calendar_method == "REQUEST"

    [invite] = Enum.filter(Meetings.list_invites(ctx.meeting.id), &(&1.user_id == invitee.id))
    assert invite.mail_delivery_id == delivery.id
    refute has_element?(view, "#{row(invite)} [data-role=meeting-invite-email-failed]")
  end

  test "a refused email shows the warning and a Copy link on the row; the invite is still there",
       ctx do
    # internal_only: an address outside the org is refused.
    sender!(ctx.org_id, %{internal_only: true})

    {:ok, %{invite: guest}} =
      Meetings.invite_guest(ctx.meeting, %{
        display_name: "Outside Guest",
        email: "outside@example.org",
        host_user_id: ctx.host.id
      })

    view = open_meeting(ctx.conn, ctx.zone)

    assert has_element?(view, row(guest), "Outside Guest")
    assert has_element?(view, "#{row(guest)} [data-role=meeting-invite-email-failed]", @warning)

    assert has_element?(
             view,
             "#{row(guest)} [data-role=meeting-invite-email-failed] [data-role=meeting-invite-copy]"
           )

    # Its own DOM id, distinct from the guest row's Copy link.
    copy_ids =
      view
      |> element(row(guest))
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role=meeting-invite-copy]")
      |> LazyHTML.attribute("id")

    assert length(copy_ids) == length(Enum.uniq(copy_ids))
    assert Enum.any?(copy_ids, &String.contains?(&1, "-mail-copy-"))
  end

  test "a member row's warning copies the absolute meeting URL", ctx do
    # No meetings sender at all: the invite records why no email went.
    invitee = member!(ctx.org_id, "No Sender")
    {:ok, invite} = Meetings.invite_user(ctx.meeting, invitee.id, inviter_user_id: ctx.host.id)
    assert Meetings.invite_mail_failed?(Repo.get!(Platform.Meetings.Invite, invite.id))

    view = open_meeting(ctx.conn, ctx.zone)

    assert has_element?(view, "#{row(invite)} [data-role=meeting-invite-email-failed]", @warning)

    assert has_element?(
             view,
             ~s(#{row(invite)} [data-role=meeting-invite-copy][data-clipboard-text="#{PlatformWeb.Endpoint.url()}/meetings/#{ctx.meeting.slug}"])
           )
  end

  test "a queued invite shows no warning, and neither does an opted-out member", ctx do
    sender!(ctx.org_id)
    queued = member!(ctx.org_id, "Queued Member")
    opted_out = member!(ctx.org_id, "Quiet Member")
    {:ok, _} = Platform.Accounts.put_email_notifications(opted_out.id, false)

    {:ok, queued_invite} =
      Meetings.invite_user(ctx.meeting, queued.id, inviter_user_id: ctx.host.id)

    {:ok, quiet_invite} =
      Meetings.invite_user(ctx.meeting, opted_out.id, inviter_user_id: ctx.host.id)

    view = open_meeting(ctx.conn, ctx.zone)

    assert has_element?(view, row(queued_invite))
    assert has_element?(view, row(quiet_invite))
    refute has_element?(view, "#{@in_details} [data-role=meeting-invite-email-failed]")
  end
end
