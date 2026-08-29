defmodule PlatformWeb.MeetingLiveAgentInviteTest do
  @moduledoc """
  Task 01a04c2f — the missing edge between the meeting UI and
  `Platform.Meetings.invite_agent/3`.

  ## What was actually broken

  `invite_agent/3` worked and had ZERO callers in `lib/` or `test/`. Nothing
  in the product could put an agent into a meeting, so agent voice had no way
  in. Its third parameter, `inviting_user`, was matched as `_inviting_user`
  and ignored outright.

  ## What these tests refuse to be satisfied by

  A test that asserts the rail button renders proves nothing: the whole defect
  was a control that did not exist reaching a function that was never called.
  So the load-bearing assertion here is the DISPATCH — a subscriber on
  `runtime:agent:<agent.id>` receives `meeting_join` carrying a non-empty
  token and `agent_identity` of `"agent:" <> agent.slug` — and its negative,
  that an unauthorized viewer pushing the same event produces no such message
  at all. `refute_receive` is what makes the authorization assertion mean
  something; a flash assertion alone would still pass if the broadcast fired
  and the flash were merely cosmetic.

  ## Why the negative viewer is shaped the way it is

  `handle_params/3` admits any viewer in the meeting's org
  (`fetch_meeting_for_user/2` is an ORG visibility query, not space
  membership), so "can load the page" and "may write to the space" are
  genuinely different questions. The denied viewer here is an org member — the
  page renders for them — who holds no `chat_participants` row for the
  meeting's space, mounted with `?no_autojoin=true` so the auto-join's
  `ensure_chat_space_participant/3` never mints one. That is a real
  separation, not a contrived one: auto-join is exactly what grants the
  membership `SpaceAccess.authorize_writer/2` then finds.

  `async: false` — LiveKit config is app-env, mirroring
  `meeting_live_member_mount_test.exs`.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Participant, as: MeetingParticipant
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "agent-invite-#{label}-#{n}@example.com",
        name: "Agent Invite #{label} #{n}",
        oidc_sub: "oidc-agent-invite-#{label}-#{n}"
      })

    # `/meetings/:slug` resolves through `fetch_meeting_for_user/2`, which
    # requires an `org_memberships` row in the meeting's org. `@example.com`
    # keeps `derive_role_from_email/1` at `:member`; a `@example.com` address
    # would derive admin and blanket-bypass every scope check below.
    Repo.insert!(
      OrgMembership.changeset(%OrgMembership{}, %{
        user_id: user.id,
        org_id: Platform.TenancyFixtures.fabrikam_org_id(),
        role: "member"
      })
    )

    user
  end

  defp space! do
    {:ok, space} =
      Chat.create_space(%{
        name: "Agent Invite Space #{System.unique_integer([:positive])}",
        slug: "agent-invite-space-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp meeting!(space) do
    n = System.unique_integer([:positive])

    project =
      Repo.insert!(
        Project.changeset(%Project{}, %{
          name: "Agent Invite Project #{n}",
          slug: "agent-invite-project-#{n}",
          org_id: Platform.TenancyFixtures.fabrikam_org_id()
        })
      )

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "agent-invite-meeting-#{n}",
        name: "Agent Invite Kickoff #{n}",
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    meeting
  end

  # An agent ON THE SPACE ROSTER — which is where `@invitable_agents` reads
  # from. A bare `%Agent{}` row with no `chat_participants` entry would not be
  # offered by the control at all, and every assertion below would pass or
  # fail for the wrong reason.
  defp roster_agent!(space) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "invitable-agent-#{n}",
        name: "Invitable Agent #{n}",
        status: "active"
      })

    {:ok, _entry} = Chat.add_space_agent(space.id, agent.id, role: "member")

    agent
  end

  defp login(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp agent_participant_rows(space_id, agent_id) do
    Repo.all(
      from(p in MeetingParticipant,
        join: r in Platform.Meetings.Room,
        on: r.id == p.room_id,
        where: r.space_id == ^space_id and p.agent_id == ^agent_id
      )
    )
  end

  setup do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    space = space!()

    %{space: space, meeting: meeting!(space), agent: roster_agent!(space)}
  end

  # ── The control ──────────────────────────────────────────────────────────

  describe "the invite-an-agent control" do
    test "offers each space agent and is wired to the invite event",
         %{conn: conn, meeting: meeting, agent: agent} do
      {:ok, _view, html} =
        conn |> login(user!("render")) |> live(~p"/meetings/#{meeting.slug}")

      # `LazyHTML.query/2`, NOT `filter/2` — the button is nested inside the
      # rail aside, and `filter/2` matches only a fragment's ROOT nodes, so it
      # would silently return `[]` and make every assertion here vacuous.
      buttons =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="meeting-agent-invite-button"]))

      assert LazyHTML.attribute(buttons, "data-agent-id") == [agent.id]
      assert LazyHTML.attribute(buttons, "phx-click") == ["meeting_invite_agent"]
      assert LazyHTML.attribute(buttons, "phx-value-agent-id") == [agent.id]
    end

    test "does not offer an agent that is already in the call",
         %{conn: conn, space: space, meeting: meeting, agent: agent} do
      # Same roster agent, already a live participant. The section must lose
      # its only row — otherwise a second click writes a duplicate
      # `meeting_participants` row and re-dispatches a join.
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, room} = Meetings.activate_room(room)

      {:ok, _p} =
        Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})

      {:ok, _view, html} =
        conn |> login(user!("already-in")) |> live(~p"/meetings/#{meeting.slug}")

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-role="meeting-agent-invite-button"]))
             |> Enum.empty?()
    end
  end

  # ── The dispatch ─────────────────────────────────────────────────────────

  describe "inviting an agent from the meeting rail" do
    test "broadcasts meeting_join on the agent's runtime topic with a token",
         %{conn: conn, space: space, meeting: meeting, agent: agent} do
      inviter = user!("inviter")

      PlatformWeb.Endpoint.subscribe("runtime:agent:#{agent.id}")

      {:ok, view, _html} = conn |> login(inviter) |> live(~p"/meetings/#{meeting.slug}")

      # Auto-join has to have landed before the click: it is what activates
      # the room the handler reads AND what mints the inviter's space
      # membership. `render/1` is a synchronous round trip, so the `:auto_join`
      # message ahead of it in the mailbox is fully processed by the time it
      # returns.
      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.in_meeting

      html =
        view
        |> element(~s([data-role="meeting-agent-invite-button"]))
        |> render_click()

      room = Meetings.get_active_room(space.id)
      assert room

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "meeting_join",
                       payload: payload
                     },
                     1_000

      # The three fields a voice runtime cannot connect without.
      assert payload.agent_identity == "agent:" <> agent.slug
      assert payload.room_name == room.livekit_room_name
      assert is_binary(payload.token) and payload.token != ""

      # A JWT, not just a non-empty string — the redundant pre-flight token in
      # `invite_agent/3` is discarded, so this asserts the token that is
      # actually SENT is the well-formed one.
      assert [_header, _claims, _sig] = String.split(payload.token, ".")

      # And the durable half: the agent is on the meeting roster.
      assert [%MeetingParticipant{}] = agent_participant_rows(space.id, agent.id)

      # The control has consumed its own option.
      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-role="meeting-agent-invite-button"]))
             |> Enum.empty?()
    end
  end

  # ── The refusal ──────────────────────────────────────────────────────────

  describe "a viewer who may see the meeting but may not write to its space" do
    test "causes no meeting_join broadcast and no roster row",
         %{conn: conn, space: space, meeting: meeting, agent: agent} do
      # The room is live and the agent is invitable — everything except this
      # viewer's authorization is in place, so a green result here cannot come
      # from the invite being impossible.
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, _room} = Meetings.activate_room(room)

      outsider = user!("outsider")

      PlatformWeb.Endpoint.subscribe("runtime:agent:#{agent.id}")

      # `no_autojoin=true`: auto-join would call
      # `ensure_chat_space_participant/3` and hand this viewer the very
      # membership the check looks for.
      {:ok, view, _html} =
        conn
        |> login(outsider)
        |> live(~p"/meetings/#{meeting.slug}?no_autojoin=true")

      refute Repo.get_by(Chat.Participant,
               space_id: space.id,
               participant_type: "user",
               participant_id: outsider.id
             )

      html =
        view
        |> element(~s([data-role="meeting-agent-invite-button"]))
        |> render_click()

      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_join"}, 300

      assert agent_participant_rows(space.id, agent.id) == []
      assert html =~ "do not have permission"
    end

    test "the context refuses the same invite directly, whatever the caller",
         %{space: space, agent: agent} do
      # The LiveView test above can only exercise the handler's own arguments.
      # This one pins the guard where it actually lives, so a future caller
      # that never goes through `MeetingLive` inherits it.
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, room} = Meetings.activate_room(room)

      stranger = user!("stranger")

      assert {:error, :forbidden} = Meetings.invite_agent(room, agent, stranger)
      assert {:error, :forbidden} = Meetings.invite_agent(room, agent, {:user, stranger.id})

      # `nil` is no principal, not a bypass — `SpaceAccess.normalize_actor/1`
      # has no clause promoting an unknown shape, and this is the shape the
      # parameter carried for its whole life as `_inviting_user`.
      assert {:error, :forbidden} = Meetings.invite_agent(room, agent, nil)

      assert agent_participant_rows(space.id, agent.id) == []

      # Positive control on the identical call: with a space membership the
      # very same invite succeeds, so the three refusals above are about the
      # ACTOR and not about the room, the agent, or LiveKit config.
      {:ok, _member_row} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: stranger.id,
          display_name: stranger.name,
          joined_at: DateTime.utc_now()
        })

      assert {:ok, %MeetingParticipant{}} = Meetings.invite_agent(room, agent, stranger)
    end
  end
end
