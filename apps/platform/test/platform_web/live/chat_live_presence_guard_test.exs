defmodule PlatformWeb.ChatLivePresenceGuardTest do
  @moduledoc """
  Task 019fe860 stage 2 — the chat route must survive a DEAD presence tracker.

  `PresenceHooks.enter_space/4` called `Chat.Presence.track_in_space/4` and
  `online_count/1` with no guard, so a terminated tracker (whose ETS table is
  gone, making `Phoenix.Tracker`'s `pool_size/1` lookup raise `ArgumentError`)
  took down every chat route at mount. This module proves the guarded path.

  ## Why this is ONE test, not two

  A test that mounts chat with a HEALTHY tracker passes today against the
  unpatched code and proves nothing — the bug exists only when the tracker is
  dead. So the healthy mount here is not a test, it is the POSITIVE CONTROL for
  the broken one, captured in the same run: it establishes that the render we
  compare against actually shows presence, because an all-broken render
  satisfies a bare "did not crash" assertion trivially.

  The tracker is killed FOR REAL via `Supervisor.terminate_child/2` — not a
  mock, not an injected error tuple, and never a pattern-based process kill
  (this machine runs other agents' processes).

  ## Where presence is read (task 01a1557a-8f80 stage 3)

  The utility bar's people-online badge and panel this test opened were
  deleted; presence is now read in the space's Members sheet
  (`Chat.space_member_presence/2`). The same two-render comparison runs there:
  healthy shows online/away words, a dead tracker shows "Presence
  unavailable" and NO online or away word on any row, so a failed read can
  never read as everybody away.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @tracker ChatPresence

  defp guard_user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "chat-presence-guard-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-chat-presence-guard-#{n}"
    })
  end

  defp org_member!(user, org) do
    Repo.insert!(%OrgMembership{user_id: user.id, org_id: org.id, role: "member"})
  end

  defp guard_space!(org) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Presence Guard Chan",
        slug: "chat-presence-guard-#{System.unique_integer([:positive])}",
        kind: "channel",
        org_id: org.id
      })

    space
  end

  defp participant!(space, user, display_name) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp open_presence_panel(view) do
    view |> element(~s([data-role="members-open"])) |> render_click()
  end

  # The presence facts the desktop popover renders: each person row's
  # `data-presence` word, plus "unavailable" when the failure row renders.
  defp presence_markers(html) do
    popover = html |> LazyHTML.from_fragment() |> LazyHTML.query("#members-popover")

    words =
      popover
      |> LazyHTML.query(~s([data-role="members-person-row"]))
      |> LazyHTML.attribute("data-presence")

    unavailable =
      if LazyHTML.to_tree(LazyHTML.query(popover, ~s([data-role="members-presence-unavailable"]))) ==
           [],
         do: [],
         else: ["unavailable"]

    MapSet.new(words ++ unavailable)
  end

  # The tracker is VM-global. Terminating it delivers the shutdown to this
  # process as an exit signal (the supervisor's child link), which kills the
  # test mid-run BEFORE its assertions and BEFORE `on_exit` — leaving a dead
  # tracker leaked into the rest of the suite, where it reds unrelated presence
  # cases and reads exactly like flake. Trap first, then terminate.
  defp kill_tracker! do
    Process.flag(:trap_exit, true)
    :ok = Supervisor.terminate_child(Platform.Supervisor, @tracker)
    refute Process.whereis(@tracker), "tracker should be down after terminate_child/2"
    :ok
  end

  defp restore_tracker! do
    if is_nil(Process.whereis(@tracker)) do
      {:ok, _} = Supervisor.restart_child(Platform.Supervisor, @tracker)
    end

    wait_for_tracker!(50)
  end

  defp wait_for_tracker!(0), do: flunk("presence tracker did not come back up after restart")

  defp wait_for_tracker!(attempts) do
    if Process.whereis(@tracker) do
      :ok
    else
      Process.sleep(20)
      wait_for_tracker!(attempts - 1)
    end
  end

  setup %{conn: conn} do
    on_exit(&restore_tracker!/0)

    org = Tenancy.get_org_by_slug!("globex")

    viewer = guard_user!("Vera Viewer")
    colleague = guard_user!("Cora Colleague")
    org_member!(viewer, org)
    org_member!(colleague, org)

    space = guard_space!(org)
    participant!(space, viewer, "Vera Viewer")
    participant!(space, colleague, "Cora Colleague")

    {:ok, _} =
      ChatPresence.track_in_space(self(), space.id, colleague.id, %{
        participant_type: "user",
        display_name: "Cora Colleague"
      })

    %{conn: init_test_session(conn, current_user_id: viewer.id), space: space}
  end

  test "chat renders through a dead tracker, and the broken render is distinguishable from the healthy one",
       ctx do
    # (a) POSITIVE CONTROL — healthy tracker. Not an end in itself: it proves
    # the comparison baseline actually shows presence, so the "still renders"
    # assertion below cannot be satisfied by a uniformly broken page.
    {:ok, healthy_view, _} = live(ctx.conn, ~p"/chat/#{ctx.space.slug}")
    _ = render_async(healthy_view, 2_000)
    healthy = open_presence_panel(healthy_view)

    assert healthy =~ "Cora Colleague",
           "positive control failed: the healthy render does not show the online participant, " <>
             "so it cannot serve as a baseline for the dead-tracker comparison"

    healthy_markers = presence_markers(healthy)

    assert MapSet.member?(healthy_markers, "online"),
           "positive control failed: expected an online row in the healthy render, got: " <>
             inspect(Enum.sort(healthy_markers))

    refute MapSet.member?(healthy_markers, "unavailable")

    healthy_assigns = :sys.get_state(healthy_view.pid).socket.assigns
    assert healthy_assigns.presence_status == :ok
    assert is_integer(healthy_assigns.online_count)

    # (b) Kill the tracker FOR REAL — terminate the supervised child so its ETS
    # table is destroyed and the next tracker call raises for the same reason
    # it would in production.
    kill_tracker!()

    # (c) The route still mounts. Before this stage, `enter_space/4` raised here
    # and the chat LiveView never rendered at all.
    {:ok, broken_view, _} = live(ctx.conn, ~p"/chat/#{ctx.space.slug}")
    _ = render_async(broken_view, 2_000)
    broken = open_presence_panel(broken_view)

    broken_markers = presence_markers(broken)

    assert MapSet.member?(broken_markers, "unavailable"),
           "expected the dead-tracker render to carry Presence unavailable, got: " <>
             inspect(Enum.sort(broken_markers))

    assert broken =~ "Presence unavailable"

    # A failed read is NEVER away (nor online): every row is "unknown".
    refute MapSet.member?(broken_markers, "away"),
           "a failed presence read rendered a member as away"

    refute MapSet.member?(broken_markers, "online")
    assert MapSet.member?(broken_markers, "unknown"), "the people rows did not render at all"

    broken_assigns = :sys.get_state(broken_view.pid).socket.assigns

    assert broken_assigns.presence_status == :unavailable,
           "expected :presence_status == :unavailable, got #{inspect(broken_assigns.presence_status)}"

    # `nil`, never `0`. `0` is the claim that nobody is here; `nil` plus
    # :unavailable is the honest "we could not ask". Collapsing the two is the
    # sibling bug this task exists to avoid.
    assert broken_assigns.online_count == nil,
           "expected :online_count nil when presence is unavailable, got " <>
             "#{inspect(broken_assigns.online_count)} — a number here is a claim we cannot make"

    # (d) The two renders must DIFFER, and differ in the markers that carry the
    # distinction. If a dead tracker rendered identically to a healthy one, the
    # unavailable state would be decorative and this fix would have reproduced
    # the very defect it exists to prevent.
    assert MapSet.member?(healthy_markers, "online") and
             not MapSet.member?(broken_markers, "online"),
           "expected an online row to be present in the healthy render and ABSENT in the " <>
             "dead-tracker render. healthy=#{inspect(Enum.sort(healthy_markers))} " <>
             "broken=#{inspect(Enum.sort(broken_markers))}"

    assert not MapSet.member?(healthy_markers, "unavailable") and
             MapSet.member?(broken_markers, "unavailable"),
           "expected Presence unavailable to be ABSENT in the healthy render and present " <>
             "in the dead-tracker render. healthy=#{inspect(Enum.sort(healthy_markers))} " <>
             "broken=#{inspect(Enum.sort(broken_markers))}"

    refute healthy == broken
  end
end
