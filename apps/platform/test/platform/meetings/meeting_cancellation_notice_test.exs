defmodule Platform.Meetings.MeetingCancellationNoticeTest do
  @moduledoc """
  What `Platform.Meetings.MeetingNotifier` tells people when a meeting is
  called off (task 01a19e7f stage 2).

  Before this stage a cancellation ran the START fan-out: a push titled
  "<host> started a meeting" and a `meeting_starting` inbox row that the
  reconciler then dismissed. So every cancel test here asserts the negative
  too (never "started a meeting", never `meeting_starting`), and the start
  path is pinned unchanged at the bottom of the file.

  Push and inbox go through recorders injected with `Application.put_env/3`
  and restored on exit. External messages and mail rows are read from the
  database. The notifier is started per test under `start_supervised/1`,
  and `:sys.get_state/1` is used as a barrier: PubSub's local broadcast has
  already put the message in the notifier's mailbox when the cancel
  returns, so once `get_state` answers, the cancel has been handled.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Mail
  alias Platform.Meetings
  alias Platform.Meetings.CancellationMail
  alias Platform.Meetings.Invite
  alias Platform.Meetings.InviteDelivery
  alias Platform.Meetings.MeetingNotifier
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy

  defmodule NotifRecorder do
    @moduledoc "Records `Platform.Notifications` fan-outs as messages to the test."
    def install(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def fan_out_to_user(user_id, payload, _opts \\ []), do: notify({:push_user, user_id, payload})

    def fan_out_to_humans(ids, payload, opts \\ []),
      do: notify({:push_humans, ids, payload, opts})

    defp notify(msg) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, msg)
      end

      :ok
    end
  end

  defmodule InboxRecorder do
    @moduledoc "Records `Platform.Inbox.emit/1` calls as `{:inbox_emit, attrs}`."
    def install(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def emit(attrs) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, {:inbox_emit, attrs})
      end

      {:ok, attrs}
    end
  end

  setup do
    prior =
      for key <- [
            :notifications_module,
            :inbox_module,
            :meetings_enabled,
            :mail_enabled,
            :calendar_booking_mail_senders
          ],
          into: %{},
          do: {key, Application.fetch_env(:platform, key)}

    Application.put_env(:platform, :notifications_module, NotifRecorder)
    Application.put_env(:platform, :inbox_module, InboxRecorder)
    Application.delete_env(:platform, :calendar_booking_mail_senders)
    NotifRecorder.install(self())
    InboxRecorder.install(self())

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    org_id = Platform.TenancyFixtures.acme_org_id()
    project = project!(org_id)
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Roadmap review"})

    host = user!("Hana")
    {:ok, host_participant} = seat(meeting, host, "Hana")
    meeting = Repo.update!(Ecto.Changeset.change(meeting, host_participant_id: host_participant.id))

    notifier = start_supervised!({MeetingNotifier, []})

    %{org_id: org_id, project: project, meeting: meeting, host: host, notifier: notifier}
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp project!(org_id) do
    Repo.insert!(%Project{
      name: "Cancellation notice",
      slug: "cancel-notice-#{System.unique_integer([:positive])}",
      org_id: org_id
    })
  end

  defp user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{name: name, email: "cancel-notice-#{n}@example.com", oidc_sub: "cn-#{n}"})
    |> Repo.insert!()
  end

  defp seat(meeting, user, display_name) do
    Chat.add_participant(meeting.chat_space_id, %{
      participant_type: "user",
      participant_id: user.id,
      display_name: display_name,
      joined_at: DateTime.utc_now()
    })
  end

  defp invite!(meeting, attrs) do
    %Invite{}
    |> Invite.changeset(Map.merge(%{meeting_id: meeting.id, display_name: "Invitee"}, attrs))
    |> Repo.insert!()
  end

  # An external invitee delivered for real through `InviteDelivery.deliver/2`,
  # so the invite carries the `external_chat` carrier and delivery space the
  # cancellation notice reads. Its own messages are flushed.
  defp external_invitee!(meeting, name) do
    user = user!(name)
    org_id = Platform.TenancyFixtures.tenant_org_id("globex")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org_id})
    invite = invite!(meeting, %{user_id: user.id})

    Application.put_env(:platform, :meetings_enabled, true)
    assert {:ok, :external_chat} = InviteDelivery.deliver(invite, meeting)
    Application.put_env(:platform, :meetings_enabled, false)

    invite = Repo.get!(Invite, invite.id)
    assert invite.delivery_carrier == "external_chat"
    {user, invite}
  end

  defp messages_in(space_id), do: Chat.list_messages(space_id, order: :asc, limit: 100)

  defp configure_mail_sender!(org_id) do
    Application.put_env(:platform, :mail_enabled, true)

    account =
      Repo.insert!(%Mail.Account{
        org_id: org_id,
        name: "Meeting sender #{System.unique_integer([:positive])}",
        smtp_host: "smtp.test",
        smtp_port: 2525,
        smtp_tls: "none",
        internal_only: false
      })

    Repo.insert!(%Mail.Sender{account_id: account.id, key: "meetings", address: "m@example.com"})

    Application.put_env(:platform, :calendar_booking_mail_senders, %{
      org_id => %{account_id: account.id, sender_key: "meetings"}
    })

    account
  end

  defp cancellation_deliveries do
    Repo.all(
      from(d in Mail.Delivery, where: d.responsibility == ^CancellationMail.responsibility())
    )
  end

  defp cancel!(meeting, notifier) do
    {:ok, cancelled} = Meetings.cancel_meeting(meeting, nil)
    _ = :sys.get_state(notifier)
    cancelled
  end

  defp drain_pushes_and_rows(acc \\ []) do
    receive do
      {:push_user, _, _} = msg -> drain_pushes_and_rows([msg | acc])
      {:push_humans, _, _, _} = msg -> drain_pushes_and_rows([msg | acc])
      {:inbox_emit, _} = msg -> drain_pushes_and_rows([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ── Internal invitees and the host ────────────────────────────────────────

  describe "an internal invitee" do
    test "gets one 'Meeting cancelled' push and one meeting_cancelled inbox row; the host nothing",
         %{meeting: meeting, host: host, notifier: notifier} do
      invitee = user!("Ivo")
      invite!(meeting, %{user_id: invitee.id})
      invite!(meeting, %{user_id: host.id})

      cancel!(meeting, notifier)

      invitee_id = invitee.id
      assert_received {:push_user, ^invitee_id, payload}
      assert payload.title == "Meeting cancelled"
      refute payload.title =~ "started a meeting"
      assert payload.body == "Roadmap review"
      assert payload.url == "/meetings?meeting=#{meeting.id}"

      assert_received {:inbox_emit, %{user_id: ^invitee_id} = row}
      assert row.kind == "meeting_cancelled"
      assert row.source_type == "meeting"
      assert row.source_id == meeting.id
      assert row.title == "Meeting cancelled: Roadmap review"
      assert row.url == "/meetings?meeting=#{meeting.id}"

      # Exactly one of each, and nothing for the host.
      assert drain_pushes_and_rows() == []
    end

    test "a recipient already in the room still gets the row", %{meeting: meeting, notifier: n} do
      invitee = user!("Sitting In")
      invite!(meeting, %{user_id: invitee.id})
      {:ok, live} = Meetings.start_meeting(meeting)
      _ = :sys.get_state(n)
      _ = drain_pushes_and_rows()

      {:ok, _} = seat(live, invitee, "Sitting In")
      cancel!(live, n)

      invitee_id = invitee.id
      assert_received {:inbox_emit, %{user_id: ^invitee_id, kind: "meeting_cancelled"}}
    end

    test "the row body names the scheduled time when there is one", %{project: project, notifier: n} do
      starts = ~U[2031-04-02 15:30:00Z]

      {:ok, meeting} =
        Meetings.create_meeting(%{
          project_id: project.id,
          name: "Planned",
          scheduled_start_at: starts,
          scheduled_end_at: DateTime.add(starts, 1800)
        })

      invitee = user!("Pat")
      invite!(meeting, %{user_id: invitee.id})
      cancel!(meeting, n)

      assert_received {:inbox_emit, %{kind: "meeting_cancelled", body: body}}
      assert body =~ "Wed Apr 2, 2031 at 15:30 UTC"
    end
  end

  # ── External invitees ─────────────────────────────────────────────────────

  describe "an external invitee" do
    test "gets one message in their delivery space", %{meeting: meeting, notifier: n} do
      {_user, invite} = external_invitee!(meeting, "Ext")
      before = messages_in(invite.delivery_space_id)

      cancel!(meeting, n)

      assert [message] = messages_in(invite.delivery_space_id) -- before
      assert message.content == "Roadmap review has been cancelled."

      author = Chat.get_participant(message.participant_id)
      assert author.participant_type == "agent"
      assert author.participant_id == Platform.Meetings.SenderSeed.get().id
    end

    test "a failure for one invitee does not stop the next or the guest mail",
         %{meeting: meeting, notifier: n, org_id: org_id} do
      # Inserted first, so it is tried first: its recorded delivery space is
      # the meeting's own chat space, where the sender has no participant
      # row, so posting answers {:error, :sender_not_seeded}.
      broken_user = user!("Broken")

      {:ok, _} =
        Tenancy.mark_membership_external(%{
          user_id: broken_user.id,
          org_id: Platform.TenancyFixtures.tenant_org_id("globex")
        })

      broken =
        invite!(meeting, %{
          user_id: broken_user.id,
          delivery_carrier: "external_chat",
          delivery_space_id: meeting.chat_space_id
        })

      assert Repo.get!(Invite, broken.id).delivery_carrier == "external_chat"

      {_user, working} = external_invitee!(meeting, "Working")
      configure_mail_sender!(org_id)
      invite!(meeting, %{email: "guest-after@example.com"})
      before = messages_in(working.delivery_space_id)

      cancel!(meeting, n)

      assert [message] = messages_in(working.delivery_space_id) -- before
      assert message.content == "Roadmap review has been cancelled."
      assert [delivery] = cancellation_deliveries()
      assert delivery.recipients == ["guest-after@example.com"]
    end
  end

  # ── Guests ────────────────────────────────────────────────────────────────

  describe "a guest with an email" do
    test "gets nothing when no meeting mail sender is configured", %{meeting: m, notifier: n} do
      Application.put_env(:platform, :mail_enabled, true)
      invite!(m, %{email: "guest@example.com"})

      cancel!(m, n)

      assert cancellation_deliveries() == []
      assert Repo.aggregate(Mail.Draft, :count) == 0
    end

    test "gets nothing when mail is disabled, even with a sender", %{meeting: m, notifier: n} do
      configure_mail_sender!(Platform.TenancyFixtures.acme_org_id())
      Application.put_env(:platform, :mail_enabled, false)
      invite!(m, %{email: "guest@example.com"})

      cancel!(m, n)

      assert cancellation_deliveries() == []
    end

    test "gets exactly one queued email with a configured sender",
         %{meeting: m, notifier: n, org_id: org_id} do
      account = configure_mail_sender!(org_id)
      invite!(m, %{email: "guest@example.com"})
      # A link-only guest has no address and gets nothing.
      invite!(m, %{display_name: "Link only"})

      cancel!(m, n)

      assert [delivery] = cancellation_deliveries()
      assert delivery.status == "queued"
      assert delivery.recipients == ["guest@example.com"]
      assert delivery.account_id == account.id
      assert delivery.subject == "Cancelled: Roadmap review"
      assert delivery.body =~ "Roadmap review has been cancelled."
      assert Repo.aggregate(Mail.Draft, :count) == 1
    end
  end

  # ── Idempotency ───────────────────────────────────────────────────────────

  describe "two {:meeting_cancelled, _} broadcasts" do
    test "produce exactly one push, one inbox row, one external message and one email",
         %{meeting: meeting, notifier: n, org_id: org_id, project: project} do
      invitee = user!("Once")
      invite!(meeting, %{user_id: invitee.id})
      {_ext, ext_invite} = external_invitee!(meeting, "Once Ext")
      configure_mail_sender!(org_id)
      invite!(meeting, %{email: "once@example.com"})
      before = messages_in(ext_invite.delivery_space_id)

      cancelled = cancel!(meeting, n)

      # The second delivery: the same struct the first broadcast carried,
      # stale `cancellation_notified_at: nil` and all, so only the SQL
      # compare-and-swap can stop it.
      assert cancelled.cancellation_notified_at == nil

      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        Meetings.project_meetings_topic(project.id),
        {:meeting_cancelled, cancelled}
      )

      _ = :sys.get_state(n)

      invitee_id = invitee.id

      assert [{:push_user, ^invitee_id, %{title: "Meeting cancelled"}}, {:inbox_emit, row}] =
               drain_pushes_and_rows()

      assert row.kind == "meeting_cancelled"
      assert length(messages_in(ext_invite.delivery_space_id) -- before) == 1
      assert length(cancellation_deliveries()) == 1
    end
  end

  # ── The start path is unchanged ──────────────────────────────────────────

  describe "the start path" do
    test "still says 'started a meeting' and emits meeting_starting, with no cancel channels",
         %{meeting: meeting, notifier: n, org_id: org_id} do
      invitee = user!("Starter")
      invite!(meeting, %{user_id: invitee.id})
      {_ext, ext_invite} = external_invitee!(meeting, "Start Ext")
      configure_mail_sender!(org_id)
      invite!(meeting, %{email: "start@example.com"})
      before = messages_in(ext_invite.delivery_space_id)

      {:ok, _live} = Meetings.start_meeting(meeting)
      _ = :sys.get_state(n)

      invitee_id = invitee.id
      assert_received {:push_user, ^invitee_id, payload}
      assert payload.title == "Hana started a meeting"
      assert payload.url == "/meetings/#{meeting.slug}"

      assert_received {:inbox_emit, %{user_id: ^invitee_id} = row}
      assert row.kind == "meeting_starting"
      assert row.title == "Meeting started: Roadmap review"
      assert row.url == "/meetings/#{meeting.id}"

      assert messages_in(ext_invite.delivery_space_id) == before
      assert cancellation_deliveries() == []
    end
  end
end
