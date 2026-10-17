defmodule Platform.Meetings.RingingTest do
  @moduledoc """
  Task 01a10db7 stage 2: who a meeting rings (`Platform.Meetings.Ringing`).

  The ringing rule, in checkable form (2026-10-06):

    * R1 — on start, ring exactly the non-revoked USER invitees, minus the
      starter, the host, anyone already in the meeting, and anyone the join
      gate would refuse;
    * R2 — a meeting with no user invitees rings nobody, while its chat-space
      members keep exactly today's alert push;
    * R3 — an invite rings only when the meeting is live per the database,
      and never the inviter;
    * R4 — never the starter.

  Two recorders stand in for the transports, both under message tags so an
  assertion can tell them apart: `{:voip, user_id, payload}` for the VoIP
  push and `{:notif, ...}` / `{:notif_user, ...}` for the alert push.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.MeetingNotifier
  alias Platform.Meetings.Ring
  alias Platform.Meetings.Ringing
  alias Platform.Push.Notification
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  defmodule Recorder do
    @moduledoc false
    def install(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)
    def uninstall, do: :persistent_term.erase({__MODULE__, :owner})

    # `:voip_push_module`
    def deliver_voip_to_user(user_id, payload), do: notify({:voip, user_id, payload})

    # `:notifications_module`
    def fan_out_to_humans(participant_ids, payload, opts \\ []),
      do: notify({:notif, participant_ids, payload, opts})

    def fan_out_to_user(user_id, payload, _opts \\ []),
      do: notify({:notif_user, user_id, payload})

    defp notify(msg) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, msg)
      end

      :ok
    end
  end

  setup do
    Application.put_env(:platform, :notifications_module, Recorder)
    Application.put_env(:platform, :voip_push_module, Recorder)
    Recorder.install(self())

    on_exit(fn ->
      Application.delete_env(:platform, :notifications_module)
      Application.delete_env(:platform, :voip_push_module)
      Recorder.uninstall()
    end)

    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Ringing #{n}"})
    %{project: project}
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{name: name, email: "ring-#{n}@example.com", oidc_sub: "ring-#{n}"})
    |> Repo.insert!()
  end

  defp meeting!(project, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, meeting} =
      Meetings.create_meeting(
        Map.merge(%{project_id: project.id, name: "Ring Meeting #{n}", slug: "ring-#{n}"}, attrs)
      )

    meeting
  end

  defp member!(meeting, user) do
    {:ok, p} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp host!(meeting, user) do
    p = member!(meeting, user)
    meeting |> Ecto.Changeset.change(host_participant_id: p.id) |> Repo.update!()
  end

  # Written directly, not through `invite_user/3`, so invite DELIVERY (its
  # own alert push) does not ride along into the recorder.
  defp invite!(meeting, attrs) do
    %Invite{}
    |> Invite.changeset(Map.put(attrs, :meeting_id, meeting.id))
    |> Repo.insert!()
  end

  defp invite_user!(meeting, user, extra \\ %{}),
    do: invite!(meeting, Map.merge(%{user_id: user.id}, extra))

  defp live!(meeting) do
    {:ok, live} = Meetings.start_meeting(meeting)
    live
  end

  defp start_notifier! do
    start_supervised!({MeetingNotifier, []})
    :ok
  end

  # A GenServer call is processed after every message already in the
  # notifier's mailbox, so once it returns the broadcast has been handled
  # completely — fan-out AND ringing.
  defp drain_notifier!, do: MeetingNotifier.subscribed_projects()

  defp voip_user_ids do
    collect([])
  end

  defp collect(acc) do
    receive do
      {:voip, user_id, _payload} -> collect([user_id | acc])
    after
      0 -> Enum.sort(acc)
    end
  end

  defp ring_count(meeting),
    do: Repo.aggregate(from(r in Ring, where: r.meeting_id == ^meeting.id), :count)

  defp external_user! do
    n = System.unique_integer([:positive])

    org =
      %Org{}
      |> Org.changeset(%{
        name: "Ring Tenant #{n}",
        slug: "tenant_ring_#{n}",
        parent_org_id: Tenancy.get_org_by_slug!("acme").id
      })
      |> Repo.insert!()

    user = user!("External")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
    user
  end

  # ── R2 ─────────────────────────────────────────────────────────────────────

  test "a meeting with no invitees rings nobody on start and still sends the alert", ctx do
    start_notifier!()
    meeting = meeting!(ctx.project)
    host = user!("Host")
    a = user!("Member A")
    b = user!("Member B")
    meeting = host!(meeting, host)
    pa = member!(meeting, a)
    pb = member!(meeting, b)

    assert Meetings.list_invites(meeting.id) == []

    {:ok, _live} = Meetings.start_meeting(meeting, started_by_user_id: host.id)

    # Today's alert push, exactly: the #440 participant-row path, all three
    # humans of the space, host dropped via opts.
    assert_receive {:notif, participant_ids, payload, opts}, 2_000
    assert Enum.sort(participant_ids) == Enum.sort([meeting.host_participant_id, pa.id, pb.id])
    assert Keyword.get(opts, :exclude_participant_id) == meeting.host_participant_id
    assert payload.title == "Host started a meeting"

    drain_notifier!()
    assert voip_user_ids() == []
    refute_received {:notif_user, _, _}
    assert ring_count(meeting) == 0
  end

  # ── R1 ─────────────────────────────────────────────────────────────────────

  test "a space member who is not invited is not rung", ctx do
    start_notifier!()
    meeting = meeting!(ctx.project)
    a = user!("Invited A")
    b = user!("Member B")
    member!(meeting, a)
    member!(meeting, b)
    invite_user!(meeting, a)

    {:ok, _} = Meetings.start_meeting(meeting)
    assert_receive {:notif_user, _, _}, 2_000
    drain_notifier!()

    assert voip_user_ids() == [a.id]
  end

  # The named test above cannot fail on a build that rings
  # `recipients_for_meeting/1`'s user_ids: with a live invite row present that
  # function answers from the invites too. Its chat-participant fallback
  # opens exactly when every invite is revoked, so this is the case that
  # tells the two sources apart for a meeting that HAD invitees.
  test "when every invite is revoked, no space member is rung", ctx do
    start_notifier!()
    meeting = meeting!(ctx.project)
    a = user!("Revoked A")
    b = user!("Member B")
    member!(meeting, a)
    member!(meeting, b)
    invite_user!(meeting, a, %{revoked_at: DateTime.utc_now()})

    {:ok, _} = Meetings.start_meeting(meeting)
    assert_receive {:notif, _participant_ids, _payload, _opts}, 2_000
    drain_notifier!()

    assert voip_user_ids() == []
    assert ring_count(meeting) == 0
  end

  test "the starter is not rung", ctx do
    start_notifier!()
    meeting = meeting!(ctx.project)
    starter = user!("Starter")
    a = user!("Invitee A")
    invite_user!(meeting, starter)
    invite_user!(meeting, a)

    {:ok, _} = Meetings.start_meeting(meeting, started_by_user_id: starter.id)
    assert_receive {:notif_user, _, _}, 2_000
    drain_notifier!()

    assert voip_user_ids() == [a.id]
  end

  test "the host is not rung", ctx do
    start_notifier!()
    host = user!("Host")
    a = user!("Invitee A")
    meeting = ctx.project |> meeting!() |> host!(host)
    invite_user!(meeting, host)
    invite_user!(meeting, a)

    {:ok, _} = Meetings.start_meeting(meeting)
    assert_receive {:notif_user, _, _}, 2_000
    drain_notifier!()

    assert voip_user_ids() == [a.id]
  end

  test "the VoIP payload carries ids and display strings, never a token", ctx do
    a = user!("Invitee A")
    meeting = meeting!(ctx.project, %{name: "Planning"})
    host = user!("Hanna Host")
    meeting = host!(meeting, host)
    invite_user!(meeting, a)

    [ring] = meeting |> live!() |> Ringing.ring_for_start()

    assert_received {:voip, user_id, payload}
    assert user_id == a.id
    assert payload["ring_id"] == ring.id
    assert payload["meeting_id"] == meeting.id
    assert payload["space_id"] == meeting.chat_space_id
    assert payload["trigger"] == "meeting_started"
    # Unscheduled with invitees: "{Host} in {Meeting name}".
    assert payload["caller_name"] == "Hanna Host in Planning"
    assert {:ok, _, _} = DateTime.from_iso8601(payload["sent_at"])

    assert Map.keys(payload) |> Enum.sort() ==
             ~w(caller_name install_host meeting_id ring_id sent_at space_id trigger)
  end

  test "a scheduled meeting's start rings as \"{Meeting name} meeting\"", ctx do
    a = user!("Invitee A")
    start = DateTime.add(DateTime.utc_now(), -60, :second)

    meeting =
      meeting!(ctx.project, %{
        name: "Standup",
        scheduled_start_at: start,
        scheduled_end_at: DateTime.add(start, 1800, :second)
      })

    invite_user!(meeting, a)
    meeting |> live!() |> Ringing.ring_for_start()

    assert_received {:voip, _, %{"caller_name" => "Standup meeting"}}
  end

  test "a re-broadcast of meeting_started rings nobody twice", ctx do
    start_notifier!()
    a = user!("Invitee A")
    meeting = meeting!(ctx.project)
    invite_user!(meeting, a)

    {:ok, live} = Meetings.start_meeting(meeting)
    assert_receive {:notif_user, _, _}, 2_000

    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      Meetings.project_meetings_topic(live.project_id),
      {:meeting_started, live}
    )

    drain_notifier!()
    assert voip_user_ids() == [a.id]

    # And below the notifier's own CAS: the ring row itself is the
    # idempotency key, so a second direct call rings nobody.
    assert Ringing.ring_for_start(live) == []
    assert voip_user_ids() == []
    assert ring_count(meeting) == 1
  end

  test "a cancellation rings nobody", ctx do
    start_notifier!()
    a = user!("Invitee A")
    meeting = meeting!(ctx.project)
    invite_user!(meeting, a)

    {:ok, cancelled} = meeting |> Meeting.status_changeset("cancelled") |> Repo.update()

    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      Meetings.project_meetings_topic(cancelled.project_id),
      {:meeting_cancelled, cancelled}
    )

    # The cancellation notice still goes out, through the same fan-out.
    assert_receive {:notif_user, user_id, _}, 2_000
    assert user_id == a.id
    drain_notifier!()

    assert voip_user_ids() == []
    assert ring_count(meeting) == 0
  end

  test "a revoked invite is not rung", ctx do
    a = user!("Revoked A")
    b = user!("Kept B")
    meeting = meeting!(ctx.project)
    invite_user!(meeting, a, %{revoked_at: DateTime.utc_now()})
    invite_user!(meeting, b)

    meeting |> live!() |> Ringing.ring_for_start()
    assert voip_user_ids() == [b.id]
  end

  test "a guest or email-only invite row is not rung", ctx do
    meeting = meeting!(ctx.project)

    invite!(meeting, %{
      display_name: "Guest",
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })

    invite!(meeting, %{display_name: "pending@example.com", email: "pending@example.com"})

    assert meeting |> live!() |> Ringing.ring_for_start() == []
    assert voip_user_ids() == []
    assert ring_count(meeting) == 0
  end

  test "someone already in the meeting is not rung", ctx do
    put_livekit_env()
    a = user!("Already In")
    b = user!("Not Yet")
    meeting = meeting!(ctx.project)
    invite_user!(meeting, a)
    invite_user!(meeting, b)
    {:ok, _} = Meetings.join_for_user(meeting.chat_space_id, a.id, "Already In")

    meeting |> live!() |> Ringing.ring_for_start()
    assert voip_user_ids() == [b.id]
  end

  test "an external user without a live invite is not rung", ctx do
    external = external_user!()
    a = user!("Internal A")
    meeting = meeting!(ctx.project)
    # A row exists (not revoked) but has expired: the join gate refuses
    # them, so they must not be rung either.
    invite_user!(meeting, external, %{expires_at: DateTime.add(DateTime.utc_now(), -60, :second)})
    invite_user!(meeting, a)

    meeting |> live!() |> Ringing.ring_for_start()
    assert voip_user_ids() == [a.id]
  end

  # ── R3 ─────────────────────────────────────────────────────────────────────

  test "an invite to a scheduled meeting sends the alert and no VoIP", ctx do
    # Invite delivery (the alert path) is off suite-wide in test; this test is
    # about it, so it switches it on.
    prior = Application.fetch_env(:platform, :meetings_enabled)
    Application.put_env(:platform, :meetings_enabled, true)

    on_exit(fn ->
      case prior do
        {:ok, v} -> Application.put_env(:platform, :meetings_enabled, v)
        :error -> Application.delete_env(:platform, :meetings_enabled)
      end
    end)

    inviter = user!("Inviter")
    a = user!("Invitee A")
    meeting = meeting!(ctx.project)

    {:ok, _} = Meetings.invite_user(meeting, a.id, inviter_user_id: inviter.id)

    assert_received {:notif_user, user_id, _payload}
    assert user_id == a.id
    assert voip_user_ids() == []
    assert ring_count(meeting) == 0
  end

  test "an invite to a live meeting rings once", ctx do
    inviter = user!("Ines")
    a = user!("Invitee A")
    meeting = ctx.project |> meeting!(%{name: "Retro"}) |> live!()

    {:ok, _} = Meetings.invite_user(meeting, a.id, inviter_user_id: inviter.id)

    assert_received {:voip, user_id, payload}
    assert user_id == a.id
    assert payload["trigger"] == "live_invite"
    assert payload["caller_name"] == "Ines in Retro"
    assert %Ring{inviter_user_id: inviter_id} = Repo.get!(Ring, payload["ring_id"])
    assert inviter_id == inviter.id

    # Invited again: the invite is idempotent and so is the ring.
    {:ok, _} = Meetings.invite_user(meeting, a.id, inviter_user_id: inviter.id)
    assert voip_user_ids() == []
  end

  test "the live check reads the database, not the caller's struct", ctx do
    inviter = user!("Inviter")
    a = user!("Invitee A")
    b = user!("Invitee B")
    scheduled = meeting!(ctx.project)

    # Caller holds a SCHEDULED struct, but the meeting is live by now.
    _live = live!(scheduled)
    {:ok, _} = Meetings.invite_user(scheduled, a.id, inviter_user_id: inviter.id)
    assert voip_user_ids() == [a.id]

    # Caller holds a LIVE struct, but the meeting has ended since.
    other = ctx.project |> meeting!() |> live!()
    {:ok, _} = other |> Meeting.status_changeset("ended") |> Repo.update()
    {:ok, _} = Meetings.invite_user(other, b.id, inviter_user_id: inviter.id)
    assert voip_user_ids() == []
  end

  test "an invite with no inviter named rings nobody", ctx do
    a = user!("Invitee A")
    meeting = ctx.project |> meeting!() |> live!()

    {:ok, _} = Meetings.invite_user(meeting, a.id)
    assert voip_user_ids() == []
  end

  test "a self-invite rings nobody", ctx do
    me = user!("Me")
    meeting = ctx.project |> meeting!() |> live!()

    {:ok, _} = Meetings.invite_user(meeting, me.id, inviter_user_id: me.id)
    assert voip_user_ids() == []
    assert ring_count(meeting) == 0
  end

  test "a busy callee gets the waiting alert, not a VoIP push", ctx do
    put_livekit_env()
    inviter = user!("Inviter")
    a = user!("Busy A")
    elsewhere = ctx.project |> meeting!() |> live!()
    {:ok, _} = Meetings.join_for_user(elsewhere.chat_space_id, a.id, "Busy A")

    meeting = ctx.project |> meeting!(%{name: "Sync"}) |> live!()
    {:ok, _} = Meetings.invite_user(meeting, a.id, inviter_user_id: inviter.id)

    assert voip_user_ids() == []

    assert_received {:notif_user, user_id,
                     %Notification{kind: "meeting_ring_waiting", ring_id: ring_id} = n}

    assert user_id == a.id
    assert n.category == "SUITE_RING_WAITING"
    # Task 01a14ba1: the struct keeps the legacy id; the APNs body names it
    # per device scheme.
    assert Notification.to_apns_payload(n)["aps"]["category"] == "SUITE_RING_WAITING"
    assert Notification.to_apns_payload(n, :burrow)["aps"]["category"] == "BURROW_RING_WAITING"
    assert n.meeting_id == meeting.id
    assert %Ring{user_id: ^user_id} = Repo.get!(Ring, ring_id)
  end

  # ── Ring lifecycle ─────────────────────────────────────────────────────────

  describe "decline and missed" do
    setup ctx do
      inviter = user!("Ines Inviter")
      a = user!("Dana")
      meeting = ctx.project |> meeting!(%{name: "Review"}) |> live!()
      {:ok, _} = Meetings.invite_user(meeting, a.id, inviter_user_id: inviter.id)
      assert_received {:voip, _, %{"ring_id" => ring_id}}
      Phoenix.PubSub.subscribe(Platform.PubSub, Meetings.PubSub.meeting_topic(meeting.id))

      Map.merge(ctx, %{inviter: inviter, callee: a, meeting: meeting, ring_id: ring_id})
    end

    test "a decline is a CAS, reported to the inviter, and leaves the callee an alert", ctx do
      {:ok, ring} = Ringing.get_ring_for_user(ctx.callee.id, ctx.ring_id)
      assert {:ok, %Ring{state: "declined", declined_at: %DateTime{}}} = Ringing.decline(ring)
      assert {:error, :not_ringing} = Ringing.decline(ring)

      assert_received {:ring_declined, report}
      assert report.meeting_id == ctx.meeting.id
      assert report.user_id == ctx.callee.id
      assert report.display_name == "Dana"
      assert report.inviter_user_id == ctx.inviter.id
      refute_received {:ring_declined, _}

      assert_received {:notif_user, user_id, %Notification{} = n}
      assert user_id == ctx.callee.id
      assert n.title == "Missed call in Review"
      assert n.body =~ "Ines Inviter invited you at "
      assert n.body =~ "The meeting is still going. Tap to join."
    end

    test "a missed ring after the meeting ended says so", ctx do
      {:ok, _} =
        ctx.meeting.id
        |> Meetings.get_meeting()
        |> Meeting.status_changeset("ended")
        |> Repo.update()

      {:ok, ring} = Ringing.get_ring_for_user(ctx.callee.id, ctx.ring_id)
      assert Ringing.effective_state(ring) == "over"
      assert {:ok, %Ring{state: "missed"}} = Ringing.missed(ring)

      assert_received {:ring_missed, %{user_id: user_id}}
      assert user_id == ctx.callee.id
      assert_received {:notif_user, _, %Notification{body: body}}
      assert body =~ "The meeting has ended."
    end

    test "another user's ring is not found", ctx do
      assert {:error, :not_found} = Ringing.get_ring_for_user(ctx.inviter.id, ctx.ring_id)
      assert {:error, :not_found} = Ringing.get_ring_for_user(ctx.callee.id, "nope")
    end

    test "a ring still ringing past the window reads as over", ctx do
      {:ok, ring} = Ringing.get_ring_for_user(ctx.callee.id, ctx.ring_id)
      assert Ringing.effective_state(ring) == "ringing"

      later = DateTime.add(ring.inserted_at, Ringing.ring_window_seconds() + 1, :second)
      assert Ringing.effective_state(ring, later) == "over"
    end
  end

  defp put_livekit_env do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
  end
end
