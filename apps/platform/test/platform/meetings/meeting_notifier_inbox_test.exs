defmodule Platform.Meetings.MeetingNotifierInboxTest do
  @moduledoc """
  Tests for the inbox fan-out arm of `Platform.Meetings.MeetingNotifier` — the
  parallel path (alongside the #440 push fan-out) that writes one durable
  `Platform.Inbox` row per invited human on `:meeting_started`, and the
  auto-dismiss of that row when the invitee joins the meeting.

  Two injection seams are exercised:

    * `:inbox_module` — swapped to a recorder (`InboxRecorder`) to assert
      per-invitee `emit/1` args, host exclusion, and the already-active skip
      without touching the DB; and left as the real `Platform.Inbox` in the
      broadcast test to assert the `{:inbox_item_added, item}` contract.
    * `:notifications_module` — stubbed to a no-op so the #440 Push pipeline
      never runs during these tests.
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Meetings
  alias Platform.Meetings.MeetingNotifier
  alias Platform.Repo
  alias Platform.Tasks

  defmodule InboxRecorder do
    @moduledoc """
    Test double for `Platform.Inbox`. Records each `emit/1` call as
    `{:inbox_emit, attrs}` and each `dismiss_by_source/3` call as
    `{:inbox_dismiss, user_id, source_type, source_id}` so tests can
    `assert_receive`/`refute_receive` against the captured args.
    """
    def install(pid \\ self()) do
      :persistent_term.put({__MODULE__, :owner}, pid)
    end

    def emit(attrs) do
      notify({:inbox_emit, attrs})
      {:ok, attrs}
    end

    def dismiss_by_source(user_id, source_type, source_id) do
      notify({:inbox_dismiss, user_id, source_type, source_id})
      :ok
    end

    defp notify(msg) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, msg)
      end
    end
  end

  defmodule NotifStub do
    @moduledoc """
    Stand-in for `Platform.Notifications` push fan-out. Records BOTH entry
    points so a test can tell the two push paths apart:

      * `{:push_humans, participant_row_ids, payload, opts}` — the
        chat-participant path (`fan_out_to_humans/3`).
      * `{:push_user, user_id, payload}` — the user-keyed path
        (`fan_out_to_user/2`), the only one that can reach an invitee who is
        not in the meeting's chat space.

    Recording rather than no-op'ing lets the fallback test assert the push
    *and* the inbox arm in one place — the fallback is the path every
    pre-existing meeting takes, so it is worth proving end to end.
    """
    def install(pid \\ self()) do
      :persistent_term.put({__MODULE__, :owner}, pid)
    end

    def fan_out_to_humans(recipients, payload, opts \\ []) do
      notify({:push_humans, recipients, payload, opts})
    end

    def fan_out_to_user(user_id, payload, opts \\ []) do
      notify({:push_user, user_id, payload, opts})
    end

    defp notify(msg) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, msg)
      end

      :ok
    end
  end

  setup do
    Application.put_env(:platform, :inbox_module, InboxRecorder)
    Application.put_env(:platform, :notifications_module, NotifStub)
    InboxRecorder.install(self())
    NotifStub.install(self())

    on_exit(fn ->
      Application.delete_env(:platform, :inbox_module)
      Application.delete_env(:platform, :notifications_module)
    end)

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp create_project(name) do
    {:ok, project} = Tasks.create_project(%{name: name})
    project
  end

  # Real users so the DB FKs (meeting_participants.user_id, inbox_items.user_id)
  # are satisfiable in the real-Inbox / already-active paths.
  defp create_user(name) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      %User{}
      |> User.changeset(%{name: name, email: "inbox-#{n}@example.com", oidc_sub: "sub-#{n}"})
      |> Repo.insert()

    user
  end

  defp create_meeting(project, name) do
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    meeting
  end

  defp add_user_participant(meeting, user_id, display_name) do
    {:ok, p} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    p
  end

  defp assign_host(meeting, %{id: participant_id}) do
    meeting
    |> Ecto.Changeset.change(host_participant_id: participant_id)
    |> Platform.Repo.update!()
  end

  # Make `user_id` genuinely active in the meeting's room so
  # `active_participants_for_space/1` returns their row.
  defp mark_active(meeting, user_id, display_name) do
    {:ok, room} = Meetings.ensure_room(meeting.chat_space_id)
    {:ok, room} = Meetings.activate_room(room)

    {:ok, _p} =
      Meetings.upsert_live_participant(room, %{
        identity: "user:#{user_id}",
        name: display_name
      })

    room
  end

  defp start_notifier! do
    {:ok, pid} = start_supervised({MeetingNotifier, []})
    pid
  end

  # Drain N `{:inbox_emit, attrs}` messages into a user_id => attrs map.
  defp collect_emits(count, timeout \\ 2_000) do
    Enum.reduce(1..count, %{}, fn _, acc ->
      assert_receive {:inbox_emit, attrs}, timeout
      Map.put(acc, attrs.user_id, attrs)
    end)
  end

  # ── Fan-out: per-invitee emit + host exclusion ─────────────────────────────

  describe "meeting_started inbox fan-out" do
    test "emits one meeting_starting row per invited human, host excluded" do
      project = create_project("Inbox Fanout")
      _pid = start_notifier!()

      meeting = create_meeting(project, "Standup")
      host_uid = create_user("Alice").id
      a_uid = create_user("Bob").id
      c_uid = create_user("Carol").id

      host = add_user_participant(meeting, host_uid, "Alice")
      _a = add_user_participant(meeting, a_uid, "Bob")
      _c = add_user_participant(meeting, c_uid, "Carol")
      meeting = assign_host(meeting, host)

      {:ok, _live} = Meetings.start_meeting(meeting)

      # Two invitees (A, C) — the host is skipped (no self-row).
      emits = collect_emits(2)

      assert Map.has_key?(emits, a_uid)
      assert Map.has_key?(emits, c_uid)
      refute Map.has_key?(emits, host_uid)

      a = emits[a_uid]
      assert a.kind == "meeting_starting"
      assert a.source_type == "meeting"
      assert a.source_id == meeting.id
      assert a.title == "Meeting started: Standup"
      # invitee_count = user participants (3) minus host (1) = 2.
      assert a.body == "Host: Alice · 2 invited"
      assert a.url == "/meetings/#{meeting.id}"

      # No stray third emit.
      refute_receive {:inbox_emit, _}, 200
    end

    test "skips an invitee who is already active in the meeting" do
      project = create_project("Inbox Active Skip")
      _pid = start_notifier!()

      meeting = create_meeting(project, "Sync")
      host_uid = create_user("Host").id
      a_uid = create_user("A").id
      b_uid = create_user("B").id
      c_uid = create_user("C").id

      host = add_user_participant(meeting, host_uid, "Host")
      _a = add_user_participant(meeting, a_uid, "A")
      _b = add_user_participant(meeting, b_uid, "B")
      _c = add_user_participant(meeting, c_uid, "C")
      meeting = assign_host(meeting, host)

      # B is already active in the room → skipped.
      _room = mark_active(meeting, b_uid, "B")

      {:ok, _live} = Meetings.start_meeting(meeting)

      # A and C get rows; B is skipped; host is skipped.
      emits = collect_emits(2)

      assert Map.has_key?(emits, a_uid)
      assert Map.has_key?(emits, c_uid)
      refute Map.has_key?(emits, b_uid)
      refute Map.has_key?(emits, host_uid)

      # invitee_count stays 3 (invitees-minus-host), independent of the
      # active-skip that dropped B's row.
      assert emits[a_uid].body == "Host: Host · 3 invited"

      refute_receive {:inbox_emit, _}, 200
    end

    test "falls back to 'Someone' host name when host has no display_name" do
      project = create_project("Inbox Anon Host")
      _pid = start_notifier!()

      meeting = create_meeting(project, "Mystery")
      host_uid = create_user("Mystery Host").id
      a_uid = create_user("A").id

      host = add_user_participant(meeting, host_uid, nil)
      _a = add_user_participant(meeting, a_uid, "A")
      meeting = assign_host(meeting, host)

      {:ok, _live} = Meetings.start_meeting(meeting)

      assert_receive {:inbox_emit, %{user_id: ^a_uid} = attrs}, 2_000
      assert attrs.body == "Host: Someone · 1 invited"
    end
  end

  # ── Declared invitees vs the chat-participant fallback ────────────────────
  #
  # `Meetings.recipients_for_meeting/1` picks between two rules. Both are
  # exercised against the SAME fixture — a chat space holding the host plus
  # three other users — so the only difference between the branches is whether
  # invite rows exist. That matters because the failure being guarded against
  # is silent: a wrong fallback emits nothing, logs nothing, and raises
  # nothing, and EVERY meeting that predates `meeting_invites` takes it.

  describe "invite-driven fan-out" do
    # Host + three non-host user participants, all real users so the invite
    # rows' `user_id` FK resolves. Deliberately three, so the chat-participant
    # count (3) can never coincide with the invitee counts asserted below.
    defp host_and_three(project_name, meeting_name) do
      project = create_project(project_name)
      _pid = start_notifier!()

      meeting = create_meeting(project, meeting_name)

      host = create_user("Host")
      one = create_user("One")
      two = create_user("Two")
      three = create_user("Three")

      host_p = add_user_participant(meeting, host.id, "Host")
      _ = add_user_participant(meeting, one.id, "One")
      _ = add_user_participant(meeting, two.id, "Two")
      _ = add_user_participant(meeting, three.id, "Three")

      %{
        meeting: assign_host(meeting, host_p),
        host: host,
        host_p: host_p,
        one: one,
        two: two,
        three: three
      }
    end

    test "notifies the declared invitee and NOT the uninvited chat participants" do
      ctx = host_and_three("Invite Path", "Kickoff")

      {:ok, _user_invite} = Meetings.invite_user(ctx.meeting, ctx.one.id)
      {:ok, %{invite: _}} = Meetings.invite_guest(ctx.meeting, %{display_name: "Grace"})

      {:ok, _live} = Meetings.start_meeting(ctx.meeting)

      one_id = ctx.one.id
      two_id = ctx.two.id
      three_id = ctx.three.id
      host_id = ctx.host.id

      assert_receive {:inbox_emit, %{user_id: ^one_id} = attrs}, 2_000
      assert attrs.kind == "meeting_starting"
      assert attrs.source_id == ctx.meeting.id

      # The count is the DECLARED set — 1 user invite + 1 guest invite — not
      # the 3 non-host chat participants. The two numbers differ on purpose:
      # a fixture where they coincided would pass identically against the
      # pre-invite implementation and prove nothing.
      assert attrs.body == "Host: Host · 2 invited"

      # Both halves. Asserting only that the invitee was notified passes on an
      # implementation that notifies everybody — which is the bug being fixed.
      refute_receive {:inbox_emit, %{user_id: ^two_id}}, 300
      refute_receive {:inbox_emit, %{user_id: ^three_id}}, 300
      refute_receive {:inbox_emit, %{user_id: ^host_id}}, 300

      # The guest counts toward "2 invited" but gets no row of their own —
      # no account to hang one on. Nothing else was emitted at all.
      refute_receive {:inbox_emit, _}, 200

      # Push is user-keyed on this branch: `fan_out_to_humans/3` takes
      # chat-participant ROW ids and could not address an invitee outside the
      # space even if it wanted to.
      assert_receive {:push_user, ^one_id, _payload, _opts}, 2_000
      refute_receive {:push_user, _, _, _}, 200
      refute_receive {:push_humans, _, _, _}, 200
    end

    test "with ZERO invite rows, every non-host chat participant is still notified" do
      # THE REGRESSION SURFACE. Every meeting in production has no invite rows.
      ctx = host_and_three("Fallback Path", "Legacy")

      assert Meetings.list_invites(ctx.meeting.id) == []

      assert %{source: :chat_participants, invitee_count: 3} =
               Meetings.recipients_for_meeting(ctx.meeting)

      {:ok, _live} = Meetings.start_meeting(ctx.meeting)

      emits = collect_emits(3)

      assert Map.has_key?(emits, ctx.one.id)
      assert Map.has_key?(emits, ctx.two.id)
      assert Map.has_key?(emits, ctx.three.id)
      refute Map.has_key?(emits, ctx.host.id)

      assert emits[ctx.one.id].body == "Host: Host · 3 invited"
      refute_receive {:inbox_emit, _}, 200

      # Push stays on the participant-row path, host dropped by the opt (not
      # by pre-filtering the list) exactly as before invites existed.
      assert_receive {:push_humans, row_ids, payload, opts}, 2_000
      assert length(row_ids) == 4
      assert ctx.host_p.id in row_ids
      assert Keyword.get(opts, :exclude_participant_id) == ctx.host_p.id
      assert payload.body == "Legacy"
      refute_receive {:push_user, _, _, _}, 200
    end

    test "a revoked user invite does not resurrect the chat-participant fallback" do
      ctx = host_and_three("Revoked Invite", "Board")

      {:ok, user_invite} = Meetings.invite_user(ctx.meeting, ctx.one.id)
      {:ok, %{invite: _guest}} = Meetings.invite_guest(ctx.meeting, %{display_name: "Grace"})
      {:ok, _revoked} = Meetings.revoke_invite(user_invite)

      # One guest invite survives, so the meeting still carries a declaration.
      # `list_invites/2` excludes revoked rows, so the count reads 1 — and the
      # resolution must NOT read the empty *user* set as "no declaration".
      assert %{source: :invites, user_ids: [], invitee_count: 1} =
               Meetings.recipients_for_meeting(ctx.meeting)

      {:ok, _live} = Meetings.start_meeting(ctx.meeting)

      # Nobody is invited who has an account, so nobody gets a row — and in
      # particular the three chat participants do not.
      refute_receive {:inbox_emit, _}, 500
      refute_receive {:push_user, _, _, _}, 200
      refute_receive {:push_humans, _, _, _}, 200
    end

    test "a host self-invite neither notifies the host nor inflates the count" do
      ctx = host_and_three("Host Self Invite", "Ops")

      {:ok, _} = Meetings.invite_user(ctx.meeting, ctx.host.id)
      {:ok, _} = Meetings.invite_user(ctx.meeting, ctx.one.id)

      # Two invite rows, one of them the host's own — the host is not their
      # own invitee, so both the recipient list and the count drop them.
      assert %{source: :invites, invitee_count: 1} =
               Meetings.recipients_for_meeting(ctx.meeting)

      {:ok, _live} = Meetings.start_meeting(ctx.meeting)

      one_id = ctx.one.id
      host_id = ctx.host.id

      assert_receive {:inbox_emit, %{user_id: ^one_id} = attrs}, 2_000
      assert attrs.body == "Host: Host · 1 invited"

      refute_receive {:inbox_emit, %{user_id: ^host_id}}, 300
      refute_receive {:push_user, ^host_id, _, _}, 200
    end

    test "an invitee who is already active in the meeting is skipped, count unchanged" do
      ctx = host_and_three("Invite Active Skip", "Sync")

      {:ok, _} = Meetings.invite_user(ctx.meeting, ctx.one.id)
      {:ok, _} = Meetings.invite_user(ctx.meeting, ctx.two.id)

      # One is already in the room → no inbox row for them.
      _room = mark_active(ctx.meeting, ctx.one.id, "One")

      {:ok, _live} = Meetings.start_meeting(ctx.meeting)

      two_id = ctx.two.id
      one_id = ctx.one.id

      assert_receive {:inbox_emit, %{user_id: ^two_id} = attrs}, 2_000
      # The declared count is 2 and stays 2: the active-skip suppresses a row,
      # it does not un-invite anyone.
      assert attrs.body == "Host: Host · 2 invited"

      refute_receive {:inbox_emit, %{user_id: ^one_id}}, 300
    end
  end

  # ── emit/1 contract: real Inbox broadcasts {:inbox_item_added, item} ───────

  describe "real Inbox emit broadcast" do
    test "a {:inbox_item_added, item} lands on inbox:<user_id> for each invitee" do
      # Use the real Inbox context so the emit → PubSub broadcast contract runs.
      Application.put_env(:platform, :inbox_module, Inbox)

      project = create_project("Inbox Broadcast")
      _pid = start_notifier!()

      meeting = create_meeting(project, "Launch")
      host_uid = create_user("Host").id
      a_uid = create_user("A").id

      host = add_user_participant(meeting, host_uid, "Host")
      _a = add_user_participant(meeting, a_uid, "A")
      meeting = assign_host(meeting, host)

      :ok = Inbox.subscribe(a_uid)

      {:ok, _live} = Meetings.start_meeting(meeting)

      assert_receive {:inbox_item_added, item}, 2_000
      assert item.user_id == a_uid
      assert item.kind == "meeting_starting"
      assert item.source_type == "meeting"
      assert item.source_id == meeting.id

      # The durable row is queryable via the Inbox context.
      assert [persisted] = Inbox.list_unread_for_user(a_uid, kind: "meeting_starting")
      assert persisted.source_id == meeting.id
    end
  end

  # ── Auto-dismiss on join (upsert_live_participant seam) ────────────────────

  describe "join auto-dismiss" do
    # Bring the meeting live and give it an active room so
    # get_live_meeting_for_space/1 resolves and joins are "new active rows".
    defp live_meeting_with_room(project_name, meeting_name) do
      project = create_project(project_name)
      meeting = create_meeting(project, meeting_name)
      {:ok, live} = Meetings.start_meeting(meeting)
      {:ok, room} = Meetings.ensure_room(live.chat_space_id)
      {:ok, room} = Meetings.activate_room(room)
      {live, room}
    end

    defp create_agent do
      n = System.unique_integer([:positive])

      {:ok, agent} =
        %Platform.Agents.Agent{}
        |> Platform.Agents.Agent.changeset(%{
          slug: "bot-#{n}",
          name: "Bot",
          status: "active"
        })
        |> Repo.insert()

      agent
    end

    test "a new user join dismisses that user's meeting_starting row for the meeting" do
      {live, room} = live_meeting_with_room("Join Dismiss", "Retro")
      user = create_user("Joiner")

      {:ok, _p} =
        Meetings.upsert_live_participant(room, %{identity: "user:#{user.id}", name: "Joiner"})

      assert_receive {:inbox_dismiss, dismiss_uid, "meeting", source_id}, 2_000
      assert dismiss_uid == user.id
      assert source_id == live.id
    end

    test "a real-Inbox row is stamped dismissed_at on join" do
      Application.put_env(:platform, :inbox_module, Inbox)

      {live, room} = live_meeting_with_room("Join Real Dismiss", "Sync")
      user = create_user("Joiner")

      {:ok, item} =
        Inbox.emit(%{
          user_id: user.id,
          kind: "meeting_starting",
          source_type: "meeting",
          source_id: live.id,
          title: "Meeting started: Sync"
        })

      refute item.dismissed_at

      {:ok, _p} =
        Meetings.upsert_live_participant(room, %{identity: "user:#{user.id}", name: "Joiner"})

      # Row is now dismissed — gone from the unread list.
      assert Inbox.list_unread_for_user(user.id, kind: "meeting_starting") == []
    end

    test "a reconnect (existing active row) does NOT dismiss" do
      {_live, room} = live_meeting_with_room("Reconnect", "Standup")
      user = create_user("Reconnector")

      # First join: new active row → dismisses.
      {:ok, _p1} =
        Meetings.upsert_live_participant(room, %{identity: "user:#{user.id}", name: "R"})

      assert_receive {:inbox_dismiss, _, "meeting", _}, 2_000

      # Second join for the same identity matches the existing active row
      # (maybe_backfill_identity path) → NO dismiss.
      {:ok, _p2} =
        Meetings.upsert_live_participant(room, %{identity: "user:#{user.id}", name: "R"})

      refute_receive {:inbox_dismiss, _, _, _}, 300
    end

    test "agent and guest joins do not attempt a user dismissal" do
      {_live, room} = live_meeting_with_room("Non-User Join", "Ops")
      agent = create_agent()

      {:ok, _a} =
        Meetings.upsert_live_participant(room, %{identity: "agent:#{agent.id}", name: "Bot"})

      {:ok, _g} =
        Meetings.upsert_live_participant(room, %{
          identity: "guest:#{Ecto.UUID.generate()}",
          name: "Guest"
        })

      refute_receive {:inbox_dismiss, _, _, _}, 300
    end
  end
end
