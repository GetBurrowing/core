defmodule Platform.Meetings.InviteRoomParityTest do
  @moduledoc """
  Task 01a06925 stage 1 — the invariant that the `/meetings` human and an
  invited agent are minted into ONE LiveKit room, and that the room is the
  SPACE room (`space-<chat_space_id>`), never `meetings.livekit_room_name`.

  ## Why this file exists

  The ticket claimed the human on `/meetings` sits in
  `meetings.livekit_room_name` (`meeting-<id>`) while the agent is dispatched
  to `space-<chat_space_id>`. The second half is true; the first is not. No
  code path has ever minted a browser token for `meeting-<id>`:
  `MeetingHooks.do_join/1` calls `Meetings.ensure_room(space.id)`, and
  `Meetings.invite_agent/3` is handed `Meetings.get_active_room(space_id)`.
  `meeting_rooms` has a unique index on `space_id`, so those cannot name two
  rooms for one space. The column is minted at `create_meeting/1` and read by
  nothing that joins.

  The ticket's proposed fix — dispatch the agent into `meeting-<id>` — would
  send it to a room no human joins, that the LiveKit webhook cannot attribute
  (`lookup_room/1` is `get_room_by_name/1`, `legit_room?/1` accepts only
  `space-`) and that `meeting_say` cannot find. These tests pin the parity
  so that fix, or its mirror image on the human side, fails loudly.

  ## What each test refuses to be satisfied by

  Every room comparison here is made against the DECODED JWT `video.room`
  claim, not against the `room_name` the server chose to say alongside it —
  the token is what LiveKit admits, the field is what the page was told.
  Both sides are then pinned to the LITERAL `"space-" <> chat_space_id`
  rather than to `Meetings.room_name_for_space/1`: a parity assertion alone
  stays green if the helper is changed to mint `meeting-<space_id>` and both
  sides follow it into a room the webhook's `space_id_from_room_name/1` can
  no longer parse.

  `async: false` — LiveKit config is app-env, mirroring
  `meeting_live_agent_invite_test.exs`.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  # `Phoenix.ChannelTest` in a `ConnCase`: the LiveView click and the
  # websocket runtime client have to live in the same test. `connect/2` is
  # NOT imported — `Phoenix.ConnTest` exports one too; it is called fully
  # qualified below.
  import Phoenix.ChannelTest, only: [subscribe_and_join: 3, assert_push: 3]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Federation.ToolSurface
  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Participant, as: MeetingParticipant
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.ChatLive.MeetingHooks
  alias PlatformWeb.MeetingLive

  @livekit_webhook_path "/api/webhooks/livekit"

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "room-parity-#{label}-#{n}@example.com",
        name: "Room Parity #{label} #{n}",
        oidc_sub: "oidc-room-parity-#{label}-#{n}"
      })

    # `/meetings/:slug` resolves through `fetch_meeting_for_user/2`, an org
    # visibility query. `@example.com` keeps the derived role at `:member`.
    Repo.insert!(
      OrgMembership.changeset(%OrgMembership{}, %{
        user_id: user.id,
        org_id: Platform.TenancyFixtures.acme_org_id(),
        role: "member"
      })
    )

    user
  end

  # Through the REAL constructor, so `meetings.livekit_room_name` genuinely
  # holds `meeting-<id>` and the backing chat space is the one the join seam
  # is handed. A hand-inserted row could carry any column value and the
  # `!=` assertions below would be about the fixture, not the product.
  defp meeting! do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Room Parity Project #{n}"})

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Room Parity Kickoff #{n}",
        slug: "room-parity-meeting-#{n}"
      })

    {meeting, Chat.get_space(meeting.chat_space_id)}
  end

  # An agent on the space roster with a linked, activated runtime — what
  # `invite_agent/3` requires before it will dispatch at all. `raw_token` is
  # captured because activation is the only moment the plaintext exists.
  defp roster_agent!(space) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "parity-agent-#{n}",
        name: "Parity Agent #{n}",
        status: "active"
      })

    owner = user!("runtime-owner")

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{runtime_id: "parity-rt-#{n}"})

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)
    {:ok, _entry} = Chat.ensure_space_agent(space.id, agent.id, role: "member")

    %{agent: agent, runtime: Federation.get_runtime(activated.id), raw_token: raw_token}
  end

  # A connected, authenticated websocket client for that runtime, joined on
  # the one topic `RuntimeChannel.join/3` accepts for it. `assert_push` below
  # is asserted against THIS process's pushes.
  defp join_runtime_client!(%{runtime: runtime, raw_token: raw_token}) do
    {:ok, socket} =
      Phoenix.ChannelTest.connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => raw_token
      })

    {:ok, _reply, channel} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})
    channel
  end

  defp login(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp seat_in_space!(space, user) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    :ok
  end

  # The socket shape `ChatLive` hands `MeetingHooks` for its `"meeting_join"`
  # event (`handle_event("meeting_join", _, socket) -> do_join(socket)`), as
  # built by `meeting_hooks_join_gate_test.exs`.
  defp build_socket(user_id, space) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        user_id: user_id,
        active_space: space,
        current_participant: nil,
        in_meeting: false,
        mic_enabled: true,
        camera_enabled: false,
        screen_share_enabled: false
      }
    }
  end

  defp joined_event(socket) do
    socket.private
    |> Map.get(:live_temp, %{})
    |> Map.get(:push_events, [])
    |> Enum.find(fn
      ["join-meeting" | _] -> true
      _ -> false
    end)
  end

  # The room LiveKit would actually admit this token into: the `video.room`
  # claim of the signed JWT, not whatever the server said next to it.
  defp token_room(jwt) when is_binary(jwt) do
    jwt
    |> String.split(".")
    |> Enum.at(1)
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
    |> get_in(["video", "room"])
  end

  # Every `meeting_participants` row carrying this LiveKit identity, in ANY
  # room. Keyed on `metadata["identity"]` because that is the one field only
  # `Meetings.upsert_live_participant/2` — the webhook path — ever writes.
  defp rows_with_identity(identity) do
    Repo.all(
      from(p in MeetingParticipant,
        where: fragment("? ->> 'identity' = ?", p.metadata, ^identity)
      )
    )
  end

  defp offered_agents(space) do
    space.id
    |> MeetingLive.build_meeting_participants()
    |> then(&MeetingLive.invitable_agents(space.id, &1))
  end

  defp participant_joined_payload(room_name, identity, name) do
    %{
      "event" => "participant_joined",
      "room" => %{"name" => room_name, "sid" => "RM_#{System.unique_integer([:positive])}"},
      "participant" => %{"identity" => identity, "name" => name}
    }
  end

  setup do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    {meeting, space} = meeting!()
    %{agent: agent} = runtime_agent = roster_agent!(space)

    # The precondition every `!= meeting.livekit_room_name` assertion below
    # rests on. If the constructor ever stops minting `meeting-<id>` this
    # fails here, by name, rather than letting a `!=` pass for a new reason.
    assert meeting.livekit_room_name == "meeting-" <> meeting.id

    %{
      meeting: meeting,
      space: space,
      host: user!("host"),
      agent: agent,
      runtime_agent: runtime_agent
    }
  end

  # ── T1: same room, both sides ─────────────────────────────────────────────

  describe "the /meetings human and the invited agent" do
    test "are minted into ONE room, and it is space-<chat_space_id>, not the meetings column",
         %{conn: conn, meeting: meeting, host: host, runtime_agent: runtime_agent} do
      expected_room = "space-" <> meeting.chat_space_id

      # The worker's real client, joined through `RuntimeSocket.connect/3`
      # and `RuntimeChannel.join/3`, before the page is even opened.
      _channel = join_runtime_client!(runtime_agent)

      {:ok, view, _html} = conn |> login(host) |> live(~p"/meetings/#{meeting.slug}")

      # The human side: `handle_info(:auto_join)` -> `MeetingHooks.join/1`
      # pushes `join-meeting` with the token it minted.
      assert_push_event(
        view,
        "join-meeting",
        %{token: human_token, room_name: human_room_name},
        1_000
      )

      human_room = token_room(human_token)

      # Auto-join has to have landed before the click: it is what activates
      # the room `invite_agent_into_call/2` reads. `render/1` is a synchronous
      # round trip, so the `:auto_join` message ahead of it is fully processed.
      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.in_meeting

      # The agent side: click Invite, and read the frame that reached the
      # worker — `assert_push`, so the token asserted is the one SENT.
      view
      |> element(~s([data-role="meeting-agent-invite-button"]))
      |> render_click()

      assert_push("meeting_join", payload, 1_000)
      agent_room = token_room(payload.token)

      # Parity first: the two tokens admit into ONE room. Asserted on its own,
      # ahead of the literal, so a failure below can be read as "both sides
      # moved together" (this line green) or "one side moved" (this line red).
      assert agent_room == human_room

      # Then the invariant against the LITERAL. `room_name_for_space/1` is
      # not consulted on purpose: with it, a helper that starts minting
      # `meeting-<space_id>` would keep the parity line green while the
      # webhook's `space_id_from_room_name/1` and `legit_room?/1` lose the
      # room. This line is what catches that.
      assert human_room == expected_room
      assert agent_room == expected_room
      assert payload.room_name == expected_room

      # What the page was told matches what its token is good for.
      assert human_room_name == human_room

      # And the column the ticket pointed at is a different string entirely —
      # the setup pinned it to `meeting-<id>`, so this cannot pass by accident.
      assert payload.room_name != meeting.livekit_room_name
      assert human_room != meeting.livekit_room_name
    end
  end

  # ── T2: quick-meet parity ─────────────────────────────────────────────────

  describe "a ChatLive quick-meet join on the same space" do
    test "mints the same room as the /meetings page, and its event names its token's room",
         %{conn: conn, meeting: meeting, space: space, host: host} do
      {:ok, view, _html} = conn |> login(host) |> live(~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: page_token}, 1_000)
      page_room = token_room(page_token)

      # A second, seated user joining through the ChatLive `"meeting_join"`
      # seam — `MeetingHooks.join/1` on a socket shaped as ChatLive shapes it.
      colleague = user!("colleague")
      seat_in_space!(space, colleague)

      joined = MeetingHooks.join(build_socket(colleague.id, space))
      assert joined.assigns.in_meeting == true
      assert ["join-meeting", quick_payload] = joined_event(joined)

      quick_room = token_room(quick_payload.token)

      assert quick_room == page_room
      assert quick_payload.room_name == quick_room
      assert quick_room == "space-" <> meeting.chat_space_id
      assert quick_room != meeting.livekit_room_name
    end
  end

  # ── T3: the webhook cannot attribute a meeting-<id> arrival ───────────────

  describe "the LiveKit webhook" do
    test "cannot attribute an arrival in meeting-<id>, and attributes the same identity in space-<id>",
         %{conn: conn, meeting: meeting, space: space, host: host, agent: agent} do
      # Materialise the space room the way production does: a human joins.
      {:ok, view, _html} = conn |> login(host) |> live(~p"/meetings/#{meeting.slug}")
      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.in_meeting

      identity = "agent:" <> agent.slug
      assert rows_with_identity(identity) == []
      rows_before = Repo.aggregate(MeetingParticipant, :count)

      # Positive control for the exclusion below: with no arrival on record
      # the agent IS offered, so `== []` later is a change, not a default.
      assert [%Agent{id: offered}] = offered_agents(space)
      assert offered == agent.id

      # An agent publishing into the room the ticket wanted it sent to.
      ignored =
        post(
          build_conn(),
          @livekit_webhook_path,
          participant_joined_payload(meeting.livekit_room_name, identity, agent.name)
        )

      assert %{"status" => "ignored", "reason" => "unknown room"} = json_response(ignored, 200)

      # Nothing was written — not for this identity, not for anyone.
      assert rows_with_identity(identity) == []
      assert Repo.aggregate(MeetingParticipant, :count) == rows_before

      # And the page still thinks the agent never arrived: it is still offered.
      assert [%Agent{id: ^offered}] = offered_agents(space)

      # The same identity, in the room the human actually joined.
      attributed =
        post(
          build_conn(),
          @livekit_webhook_path,
          participant_joined_payload("space-" <> meeting.chat_space_id, identity, agent.name)
        )

      assert %{"status" => "ok"} = json_response(attributed, 200)

      assert [%MeetingParticipant{metadata: %{"identity" => ^identity}, room_id: room_id}] =
               rows_with_identity(identity)

      assert Meetings.get_room(room_id).space_id == space.id

      # The arrival is what `invitable_agents/2` reads as "in the call".
      assert offered_agents(space) == []
    end
  end

  # ── T5: the join-meeting payload says the room its token is good for ─────
  #
  # Task 01a06925 stage 2. `MeetingClient._join` now compares the pinned
  # Room's `name` against the pushed `room_name` and reconnects on a
  # mismatch, so the client TRUSTS that field. These pin it, on both
  # ingresses, to the token's `video.room` — what LiveKit will admit.

  describe "the join-meeting payload's room_name" do
    test "equals the signed-in token's video.room on the MeetingHooks join seam",
         %{meeting: meeting, space: space} do
      member = user!("payload")
      seat_in_space!(space, member)

      joined = MeetingHooks.join(build_socket(member.id, space))
      assert ["join-meeting", %{token: token, room_name: room_name}] = joined_event(joined)

      assert room_name == token_room(token)
      assert room_name == "space-" <> meeting.chat_space_id
    end

    test "equals the guest token's video.room on the meet. host guest ingress",
         %{conn: conn, meeting: meeting} do
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      invite = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

      {:ok, view, _html} =
        %{conn | host: "meet.localhost"} |> live("/#{meeting.slug}/#{invite}")

      assert_push_event(view, "join-meeting", %{token: token, room_name: room_name}, 1_000)

      assert room_name == token_room(token)
      assert room_name == "space-" <> meeting.chat_space_id
      assert room_name != meeting.livekit_room_name
    end
  end

  # ── T4: the tool reports the room a joiner is minted into ────────────────

  describe "meeting_create" do
    test "reports the room a participant actually joins, which differs from the row's column" do
      {:ok, project} =
        Tasks.create_project(%{name: "Room Parity Tool #{System.unique_integer([:positive])}"})

      {:ok, result} =
        ToolSurface.execute(
          "meeting_create",
          %{"project_id" => project.id, "name" => "Parity Tool Kickoff"},
          %{}
        )

      assert result.livekit_room_name == "space-" <> result.chat_space_id

      # The column keeps `meeting-<id>` — this stage does not repurpose it —
      # so the two values are pinned as DIFFERENT strings. The assertion
      # above cannot be satisfied by echoing the column.
      row = Repo.get!(Meeting, result.id)
      assert row.livekit_room_name == "meeting-" <> result.id
      assert result.livekit_room_name != row.livekit_room_name
    end
  end
end
