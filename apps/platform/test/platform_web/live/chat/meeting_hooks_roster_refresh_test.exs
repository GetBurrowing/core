defmodule PlatformWeb.ChatLive.MeetingHooksRosterRefreshTest do
  @moduledoc """
  Task 01a0691d stage 3 — the quickmeet's People tab follows the space roster
  without a reload, and the two ways that plumbing can go wrong.

  ## The feature

  `Chat.add_space_agent/3` / `admin_remove_agent/3` broadcast
  `{:roster_changed, space_id}` on `space_agents:<id>`. `ShellLive`'s on_mount
  hook used to HALT that message for every view that did not opt in (it no
  longer handles it at all); `MeetingHooks` holds the topic for the space the
  viewer JOINED a call on, and folds the message through `maybe_refresh_roster/2` —
  keyed by the MESSAGE's space id, guarded by the one the call is on.

  ## The fence (first regression case below)

  The hold is taken in `do_join/1`, not in `attach/2`. `attach/2`'s `space_ids`
  is the whole rail — `Chat.list_spaces/1` applies no membership filter, so an
  internal viewer's rail carries channels they never joined — and a roster
  subscription on one of those is task 01a011e6's confidentiality fence open.
  `ChatLive.presence_subscribe_space_ids/2` would NOT have closed it: it
  intersects only for EXTERNAL users and returns its input unchanged for
  internal staff (`chat_live.ex:138-147`). `do_join/1` has already run
  `authorize_join/2` and `ensure_chat_space_participant/3`, so participation in
  the one space it holds is proven rather than assumed.

  ## The shared registration (deleted)

  A third case covered `ShellLive`'s own `space_agents:<id>` hold, taken for
  the utility bar's agents meter, releasing on a re-resolve without taking the
  quickmeet's registration with it. The meter and its hold were deleted in
  task 01a1557a-8f80 stage 3, so the shell no longer holds the topic and the
  case had nothing left to drive. `PlatformWeb.SpaceTopics` still refcounts
  the remaining holders (`space_topics_test.exs`).

  Driven through a REAL mounted `ChatLive` in a quickmeet: the claim is that
  the row appears in the rail, which no unit test of the hook module can see.
  `render/1` is a synchronous call into the LiveView process and local PubSub
  delivery is a plain `send`, so a broadcast issued before the render is folded
  before the render answers; no sleeps.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Repo
  alias PlatformWeb.SpaceTopics

  setup %{conn: conn} do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    user = user!("viewer")
    space = space!("quickmeet-roster")

    # A seat, so the viewer may remove agents from the roster below.
    seat!(space, user)

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, conn: conn, user: user, space: space}
  end

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "quickmeet-roster-#{label}-#{n}@example.com",
      name: "Quickmeet Roster #{label} #{n}",
      oidc_sub: "oidc-quickmeet-roster-#{label}-#{n}"
    })
  end

  defp space!(prefix) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "#{prefix} #{n}", slug: "#{prefix}-#{n}", kind: "channel"})

    space
  end

  defp seat!(space, user) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    space
  end

  defp bare_agent!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "#{label}-#{n}",
      name: "#{label} #{n}",
      status: "active"
    })
  end

  # A roster agent whose runtime declared voice: `:invitable` + `:capable`.
  defp declaring_roster_agent!(space, features) do
    n = System.unique_integer([:positive])
    agent = bare_agent!("quickmeet-roster-agent")

    {:ok, _} = Chat.add_space_agent(space.id, agent.id, role: "member")

    {:ok, runtime} =
      Federation.register_runtime(user!("runtime-owner").id, %{
        runtime_id: "quickmeet-roster-rt-#{n}"
      })

    {:ok, activated, _raw} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)
    {:ok, _} = Chat.ensure_space_agent(space.id, agent.id, role: "member")

    {:ok, _} =
      Federation.update_metadata(Federation.get_runtime(activated.id), %{
        "client_info" => %{"product" => "openclaw", "version" => "0.1.0", "features" => features}
      })

    agent
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp join(conn, space) do
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
    _ = render_async(view)
    render_click(view, "meeting_join", %{})

    assert assigns(view).in_meeting
    assert has_element?(view, "#quickmeet-call-rail")

    view
  end

  # Registrations this LiveView pid holds on the roster topic. `keys:
  # :duplicate`, so this counts ENTRIES rather than answering a yes/no — the
  # whole point, since two entries mean two deliveries and a bare unsubscribe
  # of either takes both.
  defp roster_registrations(view, space) do
    Platform.PubSub
    |> Registry.lookup(SpaceTopics.agents_topic(space.id))
    |> Enum.count(fn {pid, _meta} -> pid == view.pid end)
  end

  defp row_selector(agent_id, state) do
    ~s(#quickmeet-call-rail [data-role="meeting-agent-invite-row"][data-invite-state="#{state}"][data-agent-id="#{agent_id}"])
  end

  defp any_row_selector(agent_id) do
    ~s([data-role="meeting-agent-invite-row"][data-agent-id="#{agent_id}"])
  end

  # The "not in space" marker inside a given agent's row (task 01a05553).
  defp membership_selector(agent_id) do
    any_row_selector(agent_id) <> ~s( [data-role="meeting-agent-invite-membership"])
  end

  describe "the quickmeet People tab follows the space roster" do
    # T3.4 — an agent added to the space while the viewer is in the call
    # appears in the rail.
    test "an agent added to the space appears without a reload",
         %{conn: conn, space: space} do
      capable = declaring_roster_agent!(space, ["meeting_voice"])
      :ok = remove_from_roster!(space, capable)
      refute capable.id in Enum.map(Chat.list_space_agents(space.id), & &1.agent_id)

      view = join(conn, space)

      # Since task 01a05553 the row is present before the add — the list is
      # the active roster, not the space — so the add flips the MARKER. The
      # claim kept here is that the rail follows the roster live.
      assert has_element?(view, row_selector(capable.id, "invitable"))
      assert has_element?(view, membership_selector(capable.id))

      {:ok, _} = Chat.add_space_agent(space.id, capable.id, role: "member")

      assert has_element?(view, row_selector(capable.id, "invitable"))
      refute has_element?(view, membership_selector(capable.id))

      assert has_element?(
               view,
               ~s(#quickmeet-call-rail [data-role="meeting-agent-invite-button"][data-agent-id="#{capable.id}"])
             )

      assert Process.alive?(view.pid)
    end

    # Inverted by task 01a05553: an agent that leaves the space is still an
    # active agent and still invitable, so its row is MARKED rather than
    # dropped. The removal is still the case that carries this stage's
    # surface — `admin_remove_agent/3` (the Members sheet's Remove) is the
    # removal that broadcasts `{:roster_changed, _}`.
    test "an agent removed from the space is marked, not dropped, without a reload",
         %{conn: conn, space: space} do
      capable = declaring_roster_agent!(space, ["meeting_voice"])

      view = join(conn, space)
      assert has_element?(view, row_selector(capable.id, "invitable"))
      refute has_element?(view, membership_selector(capable.id))

      :ok = remove_from_roster!(space, capable)

      assert has_element?(view, row_selector(capable.id, "invitable"))
      assert has_element?(view, membership_selector(capable.id))
      assert Process.alive?(view.pid)
    end

    # T3.3 — negative control. `maybe_refresh_roster/2` re-derives only when the
    # message names the space this viewer is in a call on; without that guard
    # it would rebuild the rail from ANOTHER space's roster.
    #
    # REACHABILITY, and the first draft of this case got it wrong. Broadcasting
    # on an unrelated space and asserting nothing happens is VACUOUS here: this
    # pid holds `space_agents:<id>` only for the space it joined a call on, so
    # the message never arrives and the assertion is green whatever the guard
    # does. Confirmed by running it — the mutant that deletes the guard
    # survived it.
    #
    # The path that used to deliver another space's roster change to this pid
    # was `ShellLive`'s agents-meter hold, deleted in task 01a1557a-8f80 stage
    # 3. With no subscription left that can carry it, the message is delivered
    # to the LiveView directly, which is the one way left to consult the guard.
    test "a roster change for a different space adds no row",
         %{conn: conn, space: space, user: user} do
      own = declaring_roster_agent!(space, ["meeting_voice"])
      other_space = seat!(space!("quickmeet-other"), user)
      stranger = bare_agent!("stranger")

      view = join(conn, space)
      assert has_element?(view, row_selector(own.id, "invitable"))

      assert has_element?(view, membership_selector(stranger.id)),
             "the stranger should already be listed, as a non-member of this space"

      {:ok, _} = Chat.add_space_agent(other_space.id, stranger.id, role: "member")
      send(view.pid, {:roster_changed, other_space.id})
      _ = render(view)

      # Restated for task 01a05553. The stranger is now LISTED from the first
      # render — it is an active agent, which is the task's whole point — so
      # "no row appears" is no longer the thing to refute. What must not
      # happen is its membership marker clearing because it was added to a
      # DIFFERENT space, which is what a build answering `:in_space?` from
      # "is in any space" would do.
      assert has_element?(view, membership_selector(stranger.id)),
             "another space's roster row was read as membership of this call's space"

      assert has_element?(view, row_selector(own.id, "invitable"))
      refute has_element?(view, membership_selector(own.id))
    end
  end

  # ── The two ways this plumbing goes wrong ────────────────────────────────

  describe "the roster subscription is fenced to the space the call is on" do
    # THE 01a011e6 FENCE. A first draft of this stage subscribed
    # `space_agents:<id>` for every id in `MeetingHooks.attach/2`'s `space_ids`
    # — the whole rail — which for an internal viewer includes channels they
    # never joined. Measured from the REGISTRY rather than from an assign the
    # code under test writes.
    test "a rail-visible channel the viewer never joined gets no roster subscription",
         %{conn: conn, space: space} do
      _own = declaring_roster_agent!(space, ["meeting_voice"])

      # Same kind, same rail (an internal viewer's rail is workspace-wide), and
      # agent-bearing so it is not skipped for some unrelated reason. The only
      # difference is the missing participant row.
      foreign = space!("quickmeet-foreign")
      {:ok, _} = Chat.add_space_agent(foreign.id, bare_agent!("foreign-agent").id, role: "member")

      view = join(conn, space)

      # POSITIVE CONTROL first. An unpaired refute below would be green against
      # a build that subscribes nothing at all — which is also the build where
      # the whole feature is dead.
      assert roster_registrations(view, space) >= 1,
             "the space the viewer is in a call on holds no roster subscription, so the " <>
               "refute below is green because the feature is DEAD rather than because it " <>
               "is fenced"

      assert foreign.id in Enum.map(assigns(view).spaces || [], & &1.id),
             "the foreign channel is not on this viewer's rail at all, so it was never a " <>
               "candidate for the over-broad subscribe and this case proves nothing"

      # THE FENCE.
      assert roster_registrations(view, foreign) == 0,
             "the session holds a roster subscription on a space the viewer never joined, " <>
               "so the 01a011e6 confidentiality fence is open"
    end
  end

  # The Members sheet's Remove, by an admin of the space: the removal path
  # that broadcasts `{:roster_changed, _}` since `remove_space_agent/3` went.
  defp remove_from_roster!(space, agent) do
    admin_id = Ecto.UUID.generate()

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: admin_id,
        role: "admin",
        joined_at: DateTime.utc_now()
      })

    participant = Chat.get_agent_participant(space.id, agent.id)
    {:ok, _} = Chat.admin_remove_agent(Chat.get_space(space.id), admin_id, participant.id)
    :ok
  end
end
