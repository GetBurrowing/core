defmodule PlatformWeb.ChatLive.MeetingHooksInviteTest do
  @moduledoc """
  Task 01a0691d stage 2 — the People tab's invite section on the QUICKMEET.

  `/meetings` had an invite control; the in-chat quickmeet had none. Both
  surfaces now render one `CallShell.invite_section/1` from one
  server-built row model (`MeetingLive.invite_rows/2`), and the quickmeet's
  `quickmeet_invite_agent` event runs the same body `/meetings` runs
  (`MeetingHooks.invite_agent_into_call/3`).

  These tests drive a REAL mounted `ChatLive` through `meeting_join` and
  then through the invite event, rather than calling hook functions
  directly: the surface-level claim is that the row is drawn and the click
  lands, and no unit test of the hook module can see either.

  Every dispatch assertion here is on a topic a real runtime client has
  joined, so a `refute_push` refutes on a channel that a wrongly admitted
  invite WOULD reach.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Phoenix.ChannelTest, only: [subscribe_and_join: 3, assert_push: 3, refute_push: 3]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Repo

  setup %{conn: conn} do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    user = user!("viewer")

    {:ok, space} =
      Chat.create_space(%{
        name: "Quickmeet Invite #{System.unique_integer([:positive])}",
        slug: "quickmeet-invite-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, conn: conn, user: user, space: space}
  end

  # ── Fixtures (mirroring meeting_live_agent_invite_test.exs) ─────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "quickmeet-invite-#{label}-#{n}@example.com",
      name: "Quickmeet Invite #{label} #{n}",
      oidc_sub: "oidc-quickmeet-invite-#{label}-#{n}"
    })
  end

  # A roster agent with a linked, activated runtime — the shape
  # `invite_agent/3` requires before it will dispatch anything.
  defp roster_agent!(space) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "quickmeet-agent-#{n}",
        name: "Quickmeet Agent #{n}",
        status: "active"
      })

    {:ok, _entry} = Chat.add_space_agent(space.id, agent.id, role: "member")

    {:ok, runtime} =
      Federation.register_runtime(user!("runtime-owner").id, %{
        runtime_id: "quickmeet-rt-#{n}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)
    {:ok, _entry} = Chat.ensure_space_agent(space.id, agent.id, role: "member")

    %{agent: agent, runtime: Federation.get_runtime(activated.id), raw_token: raw_token}
  end

  defp declaring_roster_agent!(space, features) do
    %{runtime: runtime} = ctx = roster_agent!(space)

    {:ok, _runtime} =
      Federation.update_metadata(runtime, %{
        "client_info" => %{"product" => "openclaw", "version" => "0.1.0", "features" => features}
      })

    %{ctx | runtime: Federation.get_runtime(runtime.id)}
  end

  defp join_runtime_client!(%{runtime: runtime, raw_token: raw_token}) do
    {:ok, socket} =
      Phoenix.ChannelTest.connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => raw_token
      })

    {:ok, _reply, channel} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})
    channel
  end

  # An ACTIVE agent that is NOT in this space, holding one linked runtime that
  # DECLARES `meeting_voice` and is never connected. That combination is the
  # whole reproduction of task 01a06e39:
  #
  #   * declaring voice makes `Meetings.join_capability/1` answer `:capable`
  #     (positive evidence), so `invite_rows/2` states the row `:invitable`
  #     and renders a real button — the agent is NOT filtered out the way the
  #     `features: []` agent above is;
  #   * never joining the runtime channel leaves `RuntimePresence.online?/1`
  #     false, so `resolve_voice_target/1` finds a capable row, finds none
  #     connected, and answers `{:error, :voice_runtime_offline}` — the branch
  #     `invite_agent/3` pre-flights BEFORE it writes a participant row;
  #   * not being in the space is what makes `ensure_agent_in_space/3` take
  #     its writing branch rather than its read-only one.
  #
  # A `features: []` agent would be `:incapable` and lose its button; a
  # connected one would succeed. Neither reproduces this.
  defp voice_offline_outsider!(label) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "quickmeet-voice-offline-#{label}-#{n}",
        name: "Vox #{label} #{n}",
        status: "active"
      })

    {:ok, runtime} =
      Federation.register_runtime(user!("voice-owner").id, %{
        runtime_id: "quickmeet-voice-rt-#{label}-#{n}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    {:ok, _runtime} =
      Federation.update_metadata(activated, %{
        "client_info" => %{
          "product" => "burrow-voice-worker",
          "version" => "0.1.0",
          "features" => ["meeting_voice"]
        }
      })

    agent
  end

  # A channel space created DURING a test, i.e. one that postdates every agent
  # the test has already linked. See the ORDER note in the 01a06e39 test.
  defp fresh_channel!(label) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Quickmeet Invite #{label} #{n}",
        slug: "quickmeet-invite-#{label}-#{n}",
        kind: "channel"
      })

    space
  end

  defp agent_participant_rows(space_id, agent_id) do
    space_id
    |> Meetings.active_participants_for_space()
    |> Enum.filter(&(&1.agent_id == agent_id))
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Join the quickmeet from the chat surface. The rail exists only once
  # `:in_meeting` is true, so it is asserted here as the direction control
  # for every "the rail shows X" claim below.
  defp join(conn, space) do
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
    render_click(view, "meeting_join", %{})

    assert assigns(view).in_meeting
    assert has_element?(view, "#quickmeet-call-rail")

    view
  end

  defp row_selector(agent_id, state) do
    ~s(#quickmeet-call-rail [data-role="meeting-agent-invite-row"][data-invite-state="#{state}"][data-agent-id="#{agent_id}"])
  end

  defp button_selector(agent_id) do
    ~s(#quickmeet-call-rail [data-role="meeting-agent-invite-button"][data-agent-id="#{agent_id}"])
  end

  defp row_html(view, agent_id) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="meeting-agent-invite-row"][data-agent-id="#{agent_id}"]))
    |> LazyHTML.to_html()
  end

  describe "the invite section on the quickmeet rail" do
    test "is present with the heading even when there are no agents at all",
         %{conn: conn, space: space} do
      # Since task 01a05553 the list is the ACTIVE AGENT ROSTER, so an empty
      # space is no longer enough to empty the section. Both are asserted.
      assert Chat.list_space_agents(space.id) == []
      assert Chat.list_agents_for_picker() == []

      view = join(conn, space)

      assert has_element?(view, ~s(#quickmeet-call-rail [data-role="meeting-agent-invite"]))

      assert has_element?(
               view,
               ~s(#quickmeet-call-rail [data-role="meeting-agent-invite-empty"]),
               "No active agents yet"
             )

      refute has_element?(view, ~s([data-role="meeting-agent-invite-row"]))
    end

    test "lists the text-only agent disabled, with its reason and no button",
         %{conn: conn, space: space} do
      %{agent: text_only} = declaring_roster_agent!(space, [])

      view = join(conn, space)

      assert has_element?(view, row_selector(text_only.id, "incapable"))

      assert has_element?(
               view,
               row_selector(text_only.id, "incapable") <>
                 ~s( [data-role="meeting-agent-invite-reason"]),
               "No voice runtime online"
             )

      refute has_element?(view, button_selector(text_only.id))

      row = row_html(view, text_only.id)
      refute row =~ "<button"
      refute row =~ "phx-click"
    end

    test "inviting a capable agent with a connected worker dispatches meeting_join and the row turns pending",
         %{conn: conn, space: space} do
      %{agent: voice} = ctx = declaring_roster_agent!(space, ["meeting_voice"])
      _channel = join_runtime_client!(ctx)

      view = join(conn, space)

      assert has_element?(view, row_selector(voice.id, "invitable"))
      assert has_element?(view, button_selector(voice.id))
      refute has_element?(view, button_selector(voice.id) <> ~s([data-invite-pending="true"]))

      html = render_click(view, "quickmeet_invite_agent", %{"agent-id" => voice.id})

      assert_push "meeting_join", _payload, 500
      assert Process.alive?(view.pid)
      assert html =~ "waiting for it to join"
      assert [_row] = agent_participant_rows(space.id, voice.id)

      # The row is the truth surface: the same click that dispatched is
      # what re-labels it, without waiting for a presence round-trip.
      assert has_element?(view, row_selector(voice.id, "pending"))
      assert has_element?(view, button_selector(voice.id) <> ~s([data-invite-pending="true"]))

      assert has_element?(
               view,
               ~s(#quickmeet-call-rail [data-role="meeting-agent-invite-pending"]),
               "Waiting"
             )
    end

    # The refusal is the server's, not the markup's: the id is forged
    # straight at the handler, and the agent's runtime has a real client on
    # its channel so the refutation is on a topic a wrongly admitted invite
    # WOULD reach.
    test "the incapable id is refused server-side: nothing dispatched, no row written",
         %{conn: conn, space: space} do
      %{agent: text_only} = ctx = declaring_roster_agent!(space, [])
      _channel = join_runtime_client!(ctx)

      view = join(conn, space)
      refute has_element?(view, button_selector(text_only.id))

      html = render_click(view, "quickmeet_invite_agent", %{"agent-id" => text_only.id})

      refute_push "meeting_join", _payload, 200
      assert agent_participant_rows(space.id, text_only.id) == []
      assert html =~ "That agent could not be invited."
      refute html =~ "waiting for it to join"

      # Still listed, still blocked, still explained.
      assert has_element?(view, row_selector(text_only.id, "incapable"))
    end
  end

  describe "a voice-offline agent, whose invite fails after the space write (01a06e39)" do
    # RED BEFORE THE FIX on the "added to the meeting chat space" assertion
    # alone: the two assertions above it — the honest voice-worker error, and
    # the `chat_participants` row that survives it — both already held. That
    # is the defect, not a regression: `ensure_agent_in_space/3` and
    # `Meetings.invite_agent/3` are sequenced, not wrapped, so the membership
    # write outlives the failed invite and the flash never mentioned it.
    #
    # The membership assertion is deliberately kept in the FIXED test rather
    # than deleted with the bug: this task decided the row is legitimate (see
    # `invite_agent_into_call/3`), so the row is now a claim the copy makes
    # and must therefore stay pinned. If a later change makes the invite
    # atomic instead, this assertion fails and forces the copy to change with
    # it — the two can never drift apart silently.
    test "the error names the offline worker AND discloses the space membership it just granted",
         %{conn: conn} do
      voice = voice_offline_outsider!("outsider")

      # ORDER IS LOAD-BEARING, and this is the only reason the test does not
      # reuse the space from `setup`. `Federation.link_agent/2` — which
      # `voice_offline_outsider!/1` must call to give the agent a runtime at
      # all — ends in `auto_roster_federated_agent/1`, which adds the agent to
      # every channel space that EXISTS AT THAT MOMENT. So an agent linked
      # after the space is already a member of it, and the writing branch of
      # `ensure_agent_in_space/3` is unreachable.
      #
      # A space created after the agent is not hypothetical: it is the normal
      # case for a meeting, and `invite_rows/2` says so in its own comment —
      # `Chat.list_space_agents/1` "answers `[]` on the first render of every
      # meeting that has ever been created". This is that space.
      space = fresh_channel!("outsider")

      # Direction control for the whole test: it really is an outsider, and it
      # really is offered a button anyway.
      assert Chat.get_agent_participant(space.id, voice.id) == nil
      assert Meetings.join_capability(voice) == :capable

      view = join(conn, space)

      assert has_element?(view, row_selector(voice.id, "invitable"))
      assert has_element?(view, button_selector(voice.id))

      html = render_click(view, "quickmeet_invite_agent", %{"agent-id" => voice.id})

      # 1. The invite failed, and said why — the pre-existing behaviour that
      #    task 01a06686 paid for. Named, not folded into `:no_runtime`.
      assert html =~ "voice worker is offline"
      assert html =~ voice.name
      refute html =~ "no connected runtime"
      refute html =~ "waiting for it to join"

      # 2. And the side effect really did land. `invite_agent/3` refuses
      #    before writing its own roster row, so the MEETING roster is empty
      #    while the CHAT roster gained a row.
      assert %Chat.Participant{} = Chat.get_agent_participant(space.id, voice.id)
      assert agent_participant_rows(space.id, voice.id) == []

      # 3. The claim of this task: the flash says so. Without this the
      #    operator reads "error" and cannot know the agent now sees the
      #    space's messages and can be routed attention in it.
      assert html =~ "added to the meeting chat space"
    end

    # The same defect, one error code over — and the reason the note is
    # appended per-FAILURE rather than per-reason. The ticket named only
    # `:voice_runtime_offline`, but an agent with NO runtime at all is
    # `join_capability/1` `:unknown`, which `invite_rows/2` also states
    # `:invitable`, so it too gets a button, gets its space row written, and
    # then fails `invite_agent/3`'s pre-flight — with `:no_runtime`. The
    # class is "the invite failed after the space write", not one code.
    test "the same disclosure reaches the :no_runtime failure the ticket did not name",
         %{conn: conn, space: space} do
      n = System.unique_integer([:positive])

      runtimeless =
        Repo.insert!(%Agent{
          slug: "quickmeet-runtimeless-#{n}",
          name: "Mute #{n}",
          status: "active"
        })

      # Never linked to a runtime, so `auto_roster_federated_agent/1` never
      # ran and no other source has given it a row in this space.
      assert Chat.get_agent_participant(space.id, runtimeless.id) == nil
      assert Meetings.join_capability(runtimeless) == :unknown

      view = join(conn, space)
      assert has_element?(view, button_selector(runtimeless.id))

      html = render_click(view, "quickmeet_invite_agent", %{"agent-id" => runtimeless.id})

      # The two errors stay separated, as task 01a06686 required.
      assert html =~ "no connected runtime"
      refute html =~ "voice worker is offline"

      assert %Chat.Participant{} = Chat.get_agent_participant(space.id, runtimeless.id)
      assert html =~ "added to the meeting chat space"
    end

    # The pairing that stops assertion 3 above from passing against a note
    # pasted onto every error. Same agent shape, same failure, same flash
    # sentence — but the membership row predates the click (the auto-roster
    # described above wrote it, because this space existed first), so there is
    # nothing for the click to disclose. A note that fired unconditionally
    # would be a NEW false statement in exactly the class of defect this epic
    # exists to remove.
    test "an agent ALREADY in the space gets the same error and no membership claim",
         %{conn: conn, space: space} do
      voice = voice_offline_outsider!("member")
      assert %Chat.Participant{} = existing = Chat.get_agent_participant(space.id, voice.id)

      view = join(conn, space)

      assert has_element?(view, button_selector(voice.id))

      html = render_click(view, "quickmeet_invite_agent", %{"agent-id" => voice.id})

      assert html =~ "voice worker is offline"
      refute html =~ "added to the meeting chat space"

      # The read-only branch of `ensure_agent_in_space/3`: the row is the one
      # that was already there, untouched, not a second one.
      assert %Chat.Participant{id: same_id} = Chat.get_agent_participant(space.id, voice.id)
      assert same_id == existing.id
    end
  end

  # ── Task 01a18d0a-ec37 stage 2: the human invite on the quickmeet ───────

  describe "the human Invite control on the quickmeet rail" do
    setup %{space: space} do
      original_host = Application.get_env(:platform, :meeting_guest_host)
      Application.put_env(:platform, :meeting_guest_host, "meet.example.test")

      on_exit(fn ->
        case original_host do
          nil -> Application.delete_env(:platform, :meeting_guest_host)
          value -> Application.put_env(:platform, :meeting_guest_host, value)
        end
      end)

      {:ok, project} =
        Platform.Tasks.create_project(%{
          name: "Quickmeet Human Invite #{System.unique_integer([:positive])}",
          org_id: Platform.TenancyFixtures.acme_org_id()
        })

      meeting_id = Platform.Types.UUIDv7.generate()

      {:ok, meeting} =
        %Platform.Meetings.Meeting{id: meeting_id}
        |> Platform.Meetings.Meeting.changeset(%{
          project_id: project.id,
          chat_space_id: space.id,
          slug: "quickmeet-human-invite-#{System.unique_integer([:positive])}",
          name: "Quickmeet Human Invite",
          livekit_room_name: "meeting-#{meeting_id}",
          status: "live"
        })
        |> Repo.insert()

      {:ok, meeting: meeting, target: user!("target")}
    end

    defp human_invites(meeting) do
      import Ecto.Query

      Repo.all(
        from(i in Platform.Meetings.Invite,
          where: i.meeting_id == ^meeting.id,
          order_by: i.inserted_at
        )
      )
    end

    defp type_name(view, query) do
      view
      |> form("#quickmeet-call-rail-human-invite-form", %{query: query})
      |> render_change()
    end

    test "sits inside the humans section and offers the user row and the guest row, guest last",
         %{conn: conn, space: space, meeting: meeting, target: target} do
      view = join(conn, space)
      assert assigns(view).quickmeet_meeting_id == meeting.id

      assert has_element?(
               view,
               ~s(#quickmeet-call-rail [data-section="humans"] [data-role="meeting-human-invite"])
             )

      html = type_name(view, target.name)

      roles =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="meeting-human-invite-dropdown"] > button))
        |> Enum.map(&(&1 |> LazyHTML.attribute("data-role") |> List.first()))

      assert roles == ["meeting-human-invite-user", "meeting-human-invite-guest"]
    end

    test "the user row writes a user invite on the quickmeet's meeting",
         %{conn: conn, space: space, meeting: meeting, target: target} do
      view = join(conn, space)
      type_name(view, target.name)
      render_click(view, "meeting_human_invite_user", %{"id" => target.id})

      assert [%Platform.Meetings.Invite{user_id: user_id}] = human_invites(meeting)
      assert user_id == target.id
    end

    test "the guest row writes a name-only guest invite and shows its /g/ link",
         %{conn: conn, space: space, meeting: meeting} do
      view = join(conn, space)
      type_name(view, "Quickmeet Guest")
      render_click(view, "meeting_human_invite_guest", %{})

      assert [%Platform.Meetings.Invite{user_id: nil, email: nil} = invite] =
               human_invites(meeting)

      assert invite.display_name == "Quickmeet Guest"

      assert has_element?(
               view,
               ~s(#quickmeet-call-rail [data-role="meeting-human-invite-link"]),
               "https://meet.example.test/g/" <> invite.short_code
             )
    end

    test "whitespace creates nothing", %{conn: conn, space: space, meeting: meeting} do
      view = join(conn, space)
      type_name(view, "   ")
      render_click(view, "meeting_human_invite_guest", %{})
      assert human_invites(meeting) == []
    end
  end
end
