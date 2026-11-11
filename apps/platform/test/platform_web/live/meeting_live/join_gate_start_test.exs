defmodule PlatformWeb.MeetingLive.JoinGateStartTest do
  @moduledoc """
  A join the gate refuses must not change meeting state.

  `MeetingLive` used to run `maybe_start_meeting/1` (scheduled -> live, ended
  -> live) BEFORE `MeetingHooks.join/1`, and the invite gate
  (`Meetings.join_permitted?/2`, reached through `join_for_user/3`) runs only
  inside `join/1`. A joiner the gate was about to refuse had therefore already
  started or resumed the meeting. The fix is a read-only pre-check
  (`maybe_start_meeting_if_permitted/1`); the start must still happen BEFORE
  `do_join/1` for an admitted joiner, because `do_join/1` reads the live
  meeting row.

  ## How a refused joiner is built

  The router (`ExternalUserScope`) 403s an uninvited external user before the
  LiveView mounts, so the only way a refused joiner reaches a handler is an
  invite that is live at mount and revoked afterwards. Each refused test mounts
  as an invited external member, revokes the invite, then drives the real
  event.

  ## Every test pins both sides

  The refused tests assert the meeting did not change; the admitted tests
  assert that the SAME events DO start and resume a meeting for a joiner the
  gate admits. Without the second half, a build that never starts anything
  passes the first.

  `async: false`: app-env mutation (`:meet_host`, `:livekit`) and a
  process-global telemetry handler.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Participant
  alias Platform.Meetings.State
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  @meet_host "meet.example.com"
  @status_write ~s(UPDATE "meetings" SET "status")

  # ── Fixtures ───────────────────────────────────────────────────────────

  setup do
    original_meet = Application.get_env(:platform, :meet_host)
    Application.put_env(:platform, :meet_host, @meet_host)

    original_livekit = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn ->
      Application.put_env(:platform, :livekit, original_livekit)

      case original_meet do
        nil -> Application.delete_env(:platform, :meet_host)
        value -> Application.put_env(:platform, :meet_host, value)
      end
    end)

    :ok
  end

  defp create_user!(label) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "join-gate-start-#{label}-#{n}@example.com",
      name: "JoinGateStart #{label} #{n}",
      oidc_sub: "oidc-join-gate-start-#{label}-#{n}"
    })
    |> Repo.insert!()
  end

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_join_gate_start_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    })
    |> Repo.insert!()
  end

  defp meeting!(org_id, status) do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Gate Start Project #{n}", org_id: org_id})

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Gate Start Meeting #{n}",
        slug: "gate-start-meeting-#{n}"
      })

    case status do
      :scheduled ->
        meeting

      :ended ->
        {:ok, live} = Meetings.start_meeting(meeting)
        {:ok, ended} = Meetings.end_meeting(live)
        ended
    end
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  defp on_meet_host(conn), do: %{conn | host: @meet_host}

  # An external member invited to a fresh meeting in a fresh tenant org.
  defp external_with_invite(status) do
    org = tenant_org!()
    ext = create_user!("ext")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext.id, org_id: org.id})
    meeting = meeting!(org.id, status)
    {:ok, invite} = Meetings.invite_external_user(meeting, ext.email)
    %{user: ext, meeting: meeting, invite: invite}
  end

  # An internal member of the root org: the gate admits with no query.
  defp internal_member(status) do
    user = create_user!("int")

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    %{user: user, meeting: meeting!(Platform.TenancyFixtures.acme_org_id(), status)}
  end

  # `:lobby` is the lobby Join (default mount); `:shell` is the call-shell
  # Join, reached with `?no_autojoin=true`.
  defp mount(conn, user, meeting, :lobby),
    do: conn |> login(user) |> on_meet_host() |> live("/meetings/#{meeting.slug}")

  defp mount(conn, user, meeting, :shell),
    do:
      conn |> login(user) |> on_meet_host() |> live("/meetings/#{meeting.slug}?no_autojoin=true")

  defp click_join(view, :lobby), do: render_click(view, "join_meeting", %{})
  defp click_join(view, :shell), do: render_click(view, "meeting_join", %{})

  defp reload(meeting), do: Repo.get!(Meeting, meeting.id)

  defp participant_rows(user) do
    Repo.all(from(p in Participant, where: p.user_id == ^user.id))
  end

  # Every query issued by ANY process while `fun` runs. The LiveView is its
  # own process, so a caller-pid filter would see nothing.
  defp capture_queries(fun) do
    ref = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach_many(
      handler_id,
      [[:platform, :repo, :query], [:platform, :auth, :access_blocked]],
      fn
        [:platform, :repo, :query], _measurements, metadata, _config ->
          send(test_pid, {ref, metadata[:query]})

        [:platform, :auth, :access_blocked], _measurements, _metadata, _config ->
          send(test_pid, {ref, :access_blocked})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(ref, acc) do
    receive do
      {^ref, query} -> drain(ref, [query | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp status_writes(queries),
    do: Enum.filter(queries, &(is_binary(&1) and String.contains?(&1, @status_write)))

  # ── Refused joiner ─────────────────────────────────────────────────────

  for entry <- [:lobby, :shell], status <- [:scheduled, :ended] do
    test "a refused #{entry} Join leaves a #{status} meeting #{status}", %{conn: conn} do
      entry = unquote(entry)
      status = unquote(status)
      %{user: ext, meeting: meeting, invite: invite} = external_with_invite(status)
      before = reload(meeting)

      {:ok, view, _html} = mount(conn, ext, meeting, entry)
      {:ok, _} = Meetings.revoke_invite(invite)

      {_html, queries} = capture_queries(fn -> click_join(view, entry) end)

      after_attempt = reload(meeting)
      assert after_attempt.status == Atom.to_string(status)
      assert after_attempt.started_at == before.started_at
      assert after_attempt.ended_at == before.ended_at
      assert participant_rows(ext) == []
      assert status_writes(queries) == []

      # The refusal itself still happens, once, inside join/1, and the page is
      # still alive.
      assert Enum.count(queries, &(&1 == :access_blocked)) == 1
      assert Process.alive?(view.pid)
      assert render(view) =~ meeting.name
    end
  end

  test "a refused :auto_join on a held call leaves the meeting unchanged", %{conn: conn} do
    %{user: ext, meeting: meeting, invite: invite} = external_with_invite(:scheduled)

    # A call this user held while the invite was live: a State row naming the
    # meeting's space and an active participant row in it.
    {:ok, _} = Meetings.join_for_user(meeting.chat_space_id, ext.id, "Held Call")
    State.broadcast_joined(ext.id, meeting.chat_space_id, "Space", "space", meeting.slug)

    {:ok, view, _html} = mount(conn, ext, meeting, :shell)
    {:ok, _} = Meetings.revoke_invite(invite)

    assert Repo.get!(Meeting, meeting.id).status == "scheduled"

    {_, queries} =
      capture_queries(fn ->
        send(view.pid, :auto_join)
        render(view)
      end)

    assert reload(meeting).status == "scheduled"
    assert reload(meeting).started_at == nil
    assert status_writes(queries) == []
  end

  test "a stray Join event on the index (no meeting on the socket) does not crash", %{conn: conn} do
    %{user: user} = internal_member(:scheduled)
    {:ok, view, _html} = conn |> login(user) |> live("/meetings")

    render_click(view, "join_meeting", %{})

    assert Process.alive?(view.pid)
  end

  # ── Admitted joiner (non-vacuity) ──────────────────────────────────────

  for entry <- [:lobby, :shell] do
    test "an invited external member's #{entry} Join starts a scheduled meeting", %{conn: conn} do
      entry = unquote(entry)
      %{user: ext, meeting: meeting} = external_with_invite(:scheduled)

      {:ok, view, _html} = mount(conn, ext, meeting, entry)
      {_html, queries} = capture_queries(fn -> click_join(view, entry) end)

      started = reload(meeting)
      assert started.status == "live"
      assert started.started_at != nil
      assert length(status_writes(queries)) == 1
    end

    test "an invited external member's #{entry} Join resumes an ended meeting", %{conn: conn} do
      entry = unquote(entry)
      %{user: ext, meeting: meeting} = external_with_invite(:ended)

      {:ok, view, _html} = mount(conn, ext, meeting, entry)
      click_join(view, entry)

      assert reload(meeting).status == "live"
    end

    test "an internal member's #{entry} Join starts a scheduled meeting", %{conn: conn} do
      entry = unquote(entry)
      %{user: user, meeting: meeting} = internal_member(:scheduled)

      {:ok, view, _html} = mount_internal(conn, user, meeting, entry)
      click_join(view, entry)

      assert reload(meeting).status == "live"
    end

    test "an internal member's #{entry} Join resumes an ended meeting", %{conn: conn} do
      entry = unquote(entry)
      %{user: user, meeting: meeting} = internal_member(:ended)

      {:ok, view, _html} = mount_internal(conn, user, meeting, entry)
      click_join(view, entry)

      assert reload(meeting).status == "live"
    end
  end

  # The root-org member reaches the page on the app host, not the meet host.
  defp mount_internal(conn, user, meeting, :lobby),
    do: conn |> login(user) |> live("/meetings/#{meeting.slug}")

  defp mount_internal(conn, user, meeting, :shell),
    do: conn |> login(user) |> live("/meetings/#{meeting.slug}?no_autojoin=true")
end
