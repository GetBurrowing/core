defmodule PlatformWeb.MeetingLiveDeclaredStateTest do
  @moduledoc """
  A federated agent's DECLARED state reaches the real `/meetings` screen
  (task `01a06f87` stage 1).

  ## The joint this closes, and why nothing else covered it

  Three quarters of this path were already pinned, each by a file that
  renders nothing past its own half:

    * tool -> ETS —
      `test/platform/federation/tool_surface_meeting_activity_push_test.exs`
      drives `ToolArguments.dispatch/3` and terminates every assertion at
      `AgentActivity.pushed/3`.
    * ETS -> component HTML —
      `test/platform_web/components/meetings/no_voice_worker_is_a_note_not_a_state_test.exs`
      pushes into the store and asserts "Thinking · 3s" out of
      `render_component(&ParticipantRail.participant_rail/1, ...)`.
    * tick -> assign — `meeting_live_test.exs` asserts only that
      `assigns.agent_activity_now` moved.

  What no test drove was the LiveView TEMPLATE wiring. Every rail test
  hand-builds `meeting: %{id: "m-1", ...}` and calls `render_component/2`,
  so not one of them exercises `meeting_live.html.heex` handing `meeting`
  / `agent_activity` / `now` down through `CallShell.call_rail/1`. Delete
  `meeting={@meeting}` from that template and `participant_rail.ex`'s
  `meeting_id_of(nil)` returns `nil`, `resolve_one/3` falls through to the
  store-blind `AgentActivity.resolve_at/2`, and every ETS-backed state
  vanishes from the real screen — with every one of the three files above
  still green and no error logged anywhere.

  That failure mode is not hypothetical: the same joint is broken TODAY on
  the quickmeet surface, where `partials.ex` reads
  `assigns[:agent_activity_now]` inside a component that declares no such
  attr and is never passed one. The bracket form is why it never failed
  loudly — it skips the compile-time undefined-attribute warning `@`
  would have raised. (That half is task `01a077e7` and is deliberately not
  touched here.)

  So these tests use `Phoenix.LiveViewTest.live/2` against the real
  `/meetings` route. A `render_component/2` test here would re-create the
  exact blind spot the file exists to close.

  ## The mutation this file was built against

  Deleting `meeting={@meeting}` from `meeting_live.html.heex`'s
  `<CallShell.call_rail>` block turns every assertion below from
  `"thinking"` / `"composing"` into `"idle"`, while
  `no_voice_worker_is_a_note_not_a_state_test.exs`,
  `participant_rail_test.exs` and
  `tool_surface_meeting_activity_push_test.exs` all stay green — 58 tests,
  0 failures. That is the whole argument for this file existing.

  One neighbour does notice, for a DIFFERENT reason worth recording:
  `meeting_live_test.exs:11605` (the reply-budget clause) also fails,
  because `room_for(assigns.meeting)` is the same nil. It is not a guard
  on the declared state — it never reaches `:thinking` or `:composing`,
  and it fails on the delay REASON rather than on the state word. So the
  attribute is not completely unwitnessed today; the ETS-backed declared
  state specifically was.

  ## Why the fixture connects a brain runtime

  The stage brief expected a bare seeded agent to read "Thinking". It does
  not, and this is a fixture fact rather than a defect: with no federation
  runtime linked, `Meetings.runtime_offline?/1` is true,
  `AgentDelayReason.specific_for_agent/1` returns "agent went offline",
  and `AgentActivity.apply_delays/2` QUALIFIES the working state — the row
  correctly reads `Delayed`, exactly as `meeting_live_test.exs`'s own tick
  test observes for a `:computing` agent. `:delayed` is a truthful reading
  of that fixture, not a bug.

  Since the property under test is "the declared state survives the
  template", the fixture has to be an agent whose declared state is the
  whole truth about it — so each agent gets a linked, `RuntimePresence`
  -tracked brain. `no_voice_worker?` remains true here and is deliberately
  harmless: it was REMOVED from the promotion set (task `01a07400` stage
  3) and renders only as a trailing note beside the true word.

  `async: false` — `RuntimePresence` is one named process and
  `Platform.Meetings.AgentActivity.Store` one shared ETS table, and the
  LiveView runs in its own process, which needs the shared sandbox.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Federation.ToolArguments
  alias Platform.Meetings
  alias Platform.Meetings.AgentActivity
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "declared-state-#{n}@example.com",
      name: "Declared State Viewer #{n}",
      oidc_sub: "oidc-declared-state-#{n}"
    })
  end

  # `/meetings/:slug` resolves through `Meetings.fetch_meeting_for_user/2`,
  # which requires an `org_memberships` row in the meeting's org. An
  # `@example.com` address keeps the derived role at `:member` rather than
  # blanket-bypassing the check.
  defp member!(user) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.fabrikam_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Declared State Space #{n}",
        slug: "declared-state-space-#{n}",
        kind: "channel"
      })

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Declared State Project #{n}",
        slug: "declared-state-project-#{n}",
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
      })
      |> Repo.insert()

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "declared-state-#{n}",
        name: "Declared State #{n}",
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    %{meeting: meeting, space: space, room: room}
  end

  # A seated agent with a CONNECTED brain — see the moduledoc for why the
  # brain is load-bearing. Returns `{agent, participant}`: the tool needs
  # the `%Agent{}` (there is no agent_id parameter, the caller is resolved
  # from context), the DOM assertions need the participant ROW id, which
  # is what `data-participant-id` carries.
  defp seated_agent!(owner, room, name) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "declared-state-agent-#{n}",
        name: name,
        status: "active"
      })

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{runtime_id: "declared-state-brain-#{n}"})

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    RuntimePresence.track(activated.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(activated.runtime_id) end)

    {:ok, participant} =
      Meetings.participant_joined(room, %{display_name: name, agent_id: agent.id})

    {agent, participant.id}
  end

  # The MCP tool, through the entry point both federation transports use —
  # NOT `AgentActivity.push/4`. Going straight to the store would skip the
  # tool and rebuild a half that is already covered.
  defp declare!(meeting, agent, state) do
    assert {:ok, %{state: ^state}} =
             ToolArguments.dispatch(
               "meeting_activity_push",
               %{"meeting_id" => meeting.id, "state" => state},
               %{agent: agent}
             )

    :ok
  end

  # ── DOM ───────────────────────────────────────────────────────────────
  #
  # `LazyHTML.query/2` descends the whole tree. `LazyHTML.filter/2` matches
  # only the fragment's ROOT nodes and would return `[]` for every node
  # below, which reads as "not there".

  defp frag(html), do: LazyHTML.from_fragment(html)

  # SCOPED TO THE LEFT RAIL (task 01a0693e). The desktop card board is now a
  # first-class LEFT rail beside the agents, so `participant-rail` renders both
  # there and in the right rail's People pane; an unscoped selector would match
  # both rows. The left rail carries the roster regardless of the right rail's
  # active tab, so it is the stable place to read one agent's declared state.
  defp row_selector(participant_id) do
    ~s([data-role="meeting-left-rail"] [data-component="participant-rail"] [data-participant-id="#{participant_id}"])
  end

  defp activity_state(html, participant_id) do
    html
    |> frag()
    |> LazyHTML.query(row_selector(participant_id) <> ~s( [data-role="agent-activity-avatar"]))
    |> LazyHTML.attribute("data-activity-state")
  end

  defp activity_word(html, participant_id) do
    html
    |> frag()
    |> LazyHTML.query(row_selector(participant_id) <> ~s( [data-role="agent-activity-primary"]))
    |> LazyHTML.text()
    |> String.trim()
  end

  # ── Setup ─────────────────────────────────────────────────────────────

  setup %{conn: conn} do
    viewer = member!(user!())
    %{meeting: meeting, room: room} = meeting!()

    {declarer, declarer_row} = seated_agent!(viewer, room, "Declarer")
    {quiet, quiet_row} = seated_agent!(viewer, room, "Quiet")

    on_exit(fn ->
      AgentActivity.clear_pushed(meeting.id, declarer.id)
      AgentActivity.clear_pushed(meeting.id, quiet.id)
      IntentQueue.stop(meeting.id)
    end)

    {:ok,
     conn: init_test_session(conn, current_user_id: viewer.id),
     meeting: meeting,
     declarer: declarer,
     declarer_row: declarer_row,
     quiet: quiet,
     quiet_row: quiet_row}
  end

  # Mount `/meetings/:slug` and land on the People tab. The tab is clicked
  # rather than assumed: `call_shell.ex` renders the rail ONLY when the
  # active tab is `"people"`, so a mount default that ever changes would
  # otherwise turn every assertion below into an assertion against an
  # empty pane — which reads as a feature failure, not a test bug.
  defp mount_people(conn, meeting) do
    {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

    html =
      view
      |> element(~s([data-role="call-rail-tab"][data-tab="people"]))
      |> render_click()

    assert html =~ ~s(data-pane-tab="people")
    {view, html}
  end

  # A render AFTER the push, driven by the real tick clause rather than a
  # bare `render/1`, because the tick is what production has: the pushed
  # state lands in ETS out of band and only a re-render with a fresh
  # `@agent_activity_now` can pick it up. `render/1` is a synchronous
  # round trip through the same mailbox `send/2` just enqueued onto, so by
  # the time it returns the tick's `handle_info/2` clause has run.
  defp tick(view) do
    send(view.pid, :agent_activity_tick)
    render(view)
  end

  describe "a declared state reaches the real /meetings screen" do
    test "thinking, pushed through the MCP tool, renders on the rail",
         %{conn: conn, meeting: meeting, declarer: declarer, declarer_row: row} do
      {view, html} = mount_people(conn, meeting)

      # Baseline: nothing declared, so there IS a row and it is idle. This
      # rules out the degenerate pass in which the row never rendered.
      assert activity_state(html, row) == ["idle"]
      assert activity_word(html, row) == "Idle"

      :ok = declare!(meeting, declarer, "thinking")

      after_push = tick(view)

      assert activity_state(after_push, row) == ["thinking"]
      assert activity_word(after_push, row) =~ "Thinking"
      refute activity_word(after_push, row) =~ "Idle"
    end

    test "composing renders as Writing on the rail",
         %{conn: conn, meeting: meeting, declarer: declarer, declarer_row: row} do
      {view, html} = mount_people(conn, meeting)
      assert activity_state(html, row) == ["idle"]

      :ok = declare!(meeting, declarer, "composing")

      after_push = tick(view)

      assert activity_state(after_push, row) == ["composing"]
      assert activity_word(after_push, row) =~ "Writing"
      refute activity_word(after_push, row) =~ "Idle"
    end

    # THE NEGATIVE CONTROL, in the SAME render as the positive. A rail that
    # painted every agent Thinking — or a resolver keyed on the wrong id —
    # satisfies both tests above and fails only here.
    test "a seated agent that declared nothing stays Idle in the same render",
         %{
           conn: conn,
           meeting: meeting,
           declarer: declarer,
           declarer_row: declarer_row,
           quiet_row: quiet_row
         } do
      {view, _html} = mount_people(conn, meeting)

      :ok = declare!(meeting, declarer, "thinking")

      html = tick(view)

      # Both rows are in this one string.
      assert activity_state(html, declarer_row) == ["thinking"]
      assert activity_state(html, quiet_row) == ["idle"]

      refute activity_state(html, quiet_row) == ["thinking"]
      assert activity_word(html, quiet_row) == "Idle"
      refute activity_word(html, quiet_row) =~ "Thinking"
    end
  end
end
