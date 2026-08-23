defmodule PlatformWeb.ShellLiveSpaceTopicsTest do
  @moduledoc """
  Task 01a01a1b stage 2 — ShellLive's roster and presence branches now hold
  `chat:space:<id>` through `PlatformWeb.SpaceTopics` instead of subscribing
  raw.

  ## What stage 1 measured, and what this module pins

  Stage 1's census (`shell_live_subscription_enumeration_test.exs`) recorded
  **2** registrations on one LiveView pid for a space that was both the roster
  space and in the viewer's presence set: `shell_live.ex`'s roster branch and
  its presence branch each issued their own `Phoenix.PubSub.subscribe/2`, which
  is a bare `Registry.register/3` on a `keys: :duplicate` registry, so the
  second call added a second registration rather than deduping. Every broadcast
  on that topic was therefore delivered twice.

  This module pins the collapse to **1**, and pins the two lifecycle
  properties the holder map buys:

    * a presence set that SHRINKS releases exactly the ids that dropped out and
      RETAINS the rest (before stage 2 the presence branch was append-only:
      `Enum.each(space_ids -- already, &subscribe/1)` with no release path at
      all, so a departed space kept its live subscription for the life of the
      LiveView);
    * the roster moving from space A to space B releases A **only if** presence
      is not also holding it — and, crucially, the retained case is retained
      *for real*, not merely bookkept.

  ## Measurement discipline

  Counts are read ONLY through `Registry.lookup(Platform.PubSub, topic)`,
  filtered to the LiveView pid. They are deliberately NOT read through a
  `Platform.Chat.PubSub` helper, and NOT through the `:presence_space_ids` or
  `:chat_space_holders` assigns — those assigns are written by the very code
  under test, so reading them to check that code would be circular. The topic
  string itself comes from `Platform.Chat.PubSub.space_topic/1` rather than
  being hardcoded here.

  ## A COUNT OF 1 IS NOT DELIVERY

  A registration count is a claim about the registry, not about the mailbox. A
  release that corrupted the *surviving* registration would still read as 1.
  So two tests below broadcast for real on a topic that survived a release and
  assert the message ARRIVES, observed through a roster recomputation that
  could only have been triggered by that message.

  The recomputation is made observable by inserting an agent participant row
  DIRECTLY via `Repo` rather than through `Chat.add_participant/2` or
  `Chat.set_principal_agent/2`: those fan out `{:roster_changed_any, _}` on
  `Chat.global_roster_topic/0`, which this LiveView is also subscribed to
  (`shell_live.ex`, the connected `on_mount` branch). A refresh triggered by
  that topic would happen whether or not the `chat:space:<id>` subscription
  survived, and the delivery assertion would pass for the wrong reason.

  ## CONTROL-SPACE TRAP

  The presence branch subscribes `chat:space:<id>` for EVERY space in the
  viewer's presence set, and that set is
  `Chat.list_viewer_presence_space_ids/1` — every non-archived space the viewer
  participates in. Joining the viewer to a "control" space would make the shell
  subscribe to it and DESTROY THE CONTROL. Every control below is therefore a
  space the viewer is deliberately NOT joined to, and its assertion is a claim
  about subscription only, never about what the viewer may read.

  ## VACUITY TRAP

  PR #791 fenced `visible_roster/2` to spaces the viewer participates in (see
  the CONFIDENTIALITY FENCE comment in `shell_live.ex`). A fixture that seeds
  an agent-bearing space WITHOUT joining the viewer therefore yields an EMPTY
  roster — and an empty roster resolves `{:roster_resolved, nil}`, subscribes
  nothing, and would make a low count pass for a reason unrelated to
  subscription hygiene. The first test joins the viewer AND carries an
  anti-vacuity assertion that the seeded agent actually appears in the roster.

  Tests that drive the branches directly (by sending `{:roster_resolved, _}` /
  `{:presence_spaces_resolved, _}`, the exact messages the async loaders send)
  use NOT-joined spaces on purpose: that keeps the presence set empty and the
  roster resolution out of the way, so each assertion isolates one branch.

  `async: false` — the registry is VM-global; a concurrently mounted LiveView
  in another test would add its own pid's registrations to the same topics.
  Scoping every count to our own pid makes the numbers safe regardless, but
  serial keeps the failure messages readable.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures (invented names only — `core` is a PUBLIC repo) ────────────────

  # Roster and presence are both org-scoped by `Tenancy.scope/3`, so a user
  # with no org membership resolves an empty visibility and every branch under
  # test no-ops. The membership is plumbing to make the code reachable at all.
  defp create_user!(name) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "space-topics-#{n}@example.com",
        name: name,
        oidc_sub: "oidc-space-topics-#{n}",
        avatar_url: nil
      })

    Repo.insert!(%OrgMembership{
      user_id: user.id,
      org_id: Platform.Tenancy.get_org_by_slug!("fabrikam").id,
      role: "admin"
    })

    user
  end

  defp create_channel!(label) do
    slug = "#{label}-#{System.unique_integer([:positive])}"

    {:ok, space} =
      Chat.create_space(%{name: String.capitalize(label), slug: slug, kind: "channel"})

    space
  end

  defp create_agent!(name) do
    Repo.insert!(%Agent{
      name: name,
      slug: "#{String.downcase(name)}-#{System.unique_integer([:positive])}",
      status: "active",
      runtime_type: "builtin"
    })
  end

  defp join!(space_id, %User{} = user, display_name) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  # Silent agent seeding — see "A COUNT OF 1 IS NOT DELIVERY" in the moduledoc.
  # A direct insert emits no PubSub fan-out, so the ONLY way the LiveView can
  # learn about this agent is a message we deliver ourselves.
  defp seed_agent_participant_silently!(space_id, %Agent{} = agent) do
    Repo.insert!(%Chat.Participant{
      space_id: space_id,
      participant_type: "agent",
      participant_id: agent.id,
      role: "member",
      display_name: agent.name,
      joined_at: DateTime.utc_now()
    })
  end

  # ── Reading the registry (never the assigns) ───────────────────────────────

  defp registration_count(pid, space_id) do
    Platform.PubSub
    |> Registry.lookup(ChatPubSub.space_topic(space_id))
    |> Enum.count(fn {entry_pid, _value} -> entry_pid == pid end)
  end

  # `render_async/1` waits for both `assign_async` loaders; each sends its
  # resolution message before returning, and both travel the same mailbox in
  # order, so the trailing `render/1` round-trip guarantees the LiveView has
  # processed `{:roster_resolved, _}` and `{:presence_spaces_resolved, _}`.
  # Never `Process.sleep/1` — that would pin the box's timing, not the code's
  # ordering.
  defp settle(view) do
    _ = render_async(view)
    _ = render(view)
    view
  end

  # Drive one of the two branches with the exact message its async loader
  # sends, then round-trip so the handler has definitely run.
  defp drive(view, message) do
    send(view.pid, message)
    _ = render(view)
    view
  end

  defp mount_tasks(conn, viewer) do
    conn
    |> init_test_session(current_user_id: viewer.id)
    |> live(~p"/tasks")
    |> then(fn {:ok, view, _html} -> view end)
    |> settle()
  end

  defp roster_agent_ids(pid) do
    :sys.get_state(pid).socket.assigns.roster_items.result
    |> Kernel.||([])
    |> Enum.map(fn {entry, _status} -> entry.agent_id end)
  end

  # The delivery proof. Seeds an agent the LiveView cannot know about, then
  # broadcasts a roster ping ON THE SPACE TOPIC UNDER TEST. `shell_live.ex`'s
  # `:roster_updates` hook matches `{:roster_changed, space_id}` whatever topic
  # carried it, and recomputes the viewer-scoped roster. If the registration
  # that survived the release were dead, the message would never land and the
  # agent would stay absent.
  defp assert_topic_delivers(view, space_id, agent_name) do
    agent = create_agent!(agent_name)
    seed_agent_participant_silently!(space_id, agent)

    refute agent.id in roster_agent_ids(view.pid),
           "anti-vacuity failed: the LiveView already knows about #{agent_name} before " <>
             "the broadcast, so its later presence proves nothing about delivery"

    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      ChatPubSub.space_topic(space_id),
      {:roster_changed, space_id}
    )

    _ = render(view)

    assert agent.id in roster_agent_ids(view.pid),
           "the surviving registration on #{ChatPubSub.space_topic(space_id)} did not " <>
             "DELIVER: a broadcast on it produced no roster recomputation. A count of 1 " <>
             "is a claim about the registry, not about the mailbox."
  end

  describe "roster and presence sharing one space" do
    test "a space that is BOTH the roster space and in the presence set holds exactly ONE registration (stage 1 measured 2)",
         %{conn: conn} do
      viewer = create_user!("Topics Viewer")
      agent = create_agent!("TopicsBot")

      overlap = create_channel!("topics-overlap")
      join!(overlap.id, viewer, "Topics Viewer")
      Chat.set_principal_agent(overlap.id, agent.id)

      # NOT joined — see CONTROL-SPACE TRAP in the moduledoc.
      control = create_channel!("topics-control")
      Chat.set_principal_agent(control.id, create_agent!("ControlBot").id)

      view = mount_tasks(conn, viewer)
      pid = view.pid

      # ANTI-VACUITY for the #791 fence: an empty roster never runs the roster
      # branch, and the count below would be low for the wrong reason.
      assert agent.id in roster_agent_ids(pid),
             "anti-vacuity failed: the seeded agent is not in the roster, so the roster " <>
               "branch never ran and the count below is meaningless"

      overlap_count = registration_count(pid, overlap.id)

      assert overlap_count == 1,
             "expected the roster and presence branches to SHARE one registration via " <>
               "SpaceTopics (stage 1 measured 2, one per branch), observed #{overlap_count}"

      # Positive control for the zero below: the measurement can read non-zero.
      assert overlap_count > 0
      assert registration_count(pid, control.id) == 0

      assert_topic_delivers(view, overlap.id, "OverlapDeliveryBot")
    end
  end

  describe "presence set reconciliation" do
    # These channels carry NO agent participant, so `visible_roster/2` returns
    # nothing, the roster resolves to nil and the roster branch never holds
    # anything. What is measured here is the presence branch alone.
    test "a presence set that shrinks releases exactly the dropped ids and RETAINS the rest",
         %{conn: conn} do
      viewer = create_user!("Presence Viewer")

      kept = create_channel!("topics-presence-kept")
      dropped = create_channel!("topics-presence-dropped")
      join!(kept.id, viewer, "Presence Viewer")
      join!(dropped.id, viewer, "Presence Viewer")

      view = mount_tasks(conn, viewer)
      pid = view.pid

      # Positive control: both spaces really are held before the shrink, so a
      # zero afterwards means "released", not "never subscribed".
      assert registration_count(pid, kept.id) == 1
      assert registration_count(pid, dropped.id) == 1

      # The exact message `async_load_presence/2` sends, now carrying a SMALLER
      # set — the case the pre-stage-2 append-only branch could not express.
      drive(view, {:presence_spaces_resolved, [kept.id]})

      assert registration_count(pid, dropped.id) == 0,
             "the dropped space is still subscribed: the presence branch is still " <>
               "append-only and never releases"

      assert registration_count(pid, kept.id) == 1,
             "the retained space lost its registration — a release of one id must not " <>
               "disturb another"

      assert_topic_delivers(view, kept.id, "PresenceDeliveryBot")
    end

    test "a presence set that grows adds only the new ids and does not double-register the ones already held",
         %{conn: conn} do
      viewer = create_user!("Presence Growth Viewer")

      first = create_channel!("topics-presence-first")
      join!(first.id, viewer, "Presence Growth Viewer")

      # NOT joined at mount, so it is outside the resolved presence set until
      # we hand it over explicitly.
      later = create_channel!("topics-presence-later")

      view = mount_tasks(conn, viewer)
      pid = view.pid

      assert registration_count(pid, first.id) == 1
      assert registration_count(pid, later.id) == 0

      drive(view, {:presence_spaces_resolved, [first.id, later.id]})

      assert registration_count(pid, first.id) == 1,
             "an id already held was re-subscribed: subscribe is Registry.register/3 and " <>
               "is NOT idempotent per pid, so a second call would double every delivery"

      assert registration_count(pid, later.id) == 1
    end
  end

  describe "roster moving between spaces" do
    # Both spaces are deliberately NOT joined, so the presence set is empty and
    # the roster branch is the only holder. Isolates the release.
    test "roster moving from A to B releases A when presence does not also hold it",
         %{conn: conn} do
      viewer = create_user!("Roster Move Viewer")

      a = create_channel!("topics-roster-a")
      b = create_channel!("topics-roster-b")

      view = mount_tasks(conn, viewer)
      pid = view.pid

      drive(view, {:roster_resolved, a.id})
      assert registration_count(pid, a.id) == 1

      drive(view, {:roster_resolved, b.id})

      assert registration_count(pid, a.id) == 0,
             "the roster's previous space was not released. Before stage 2 the release " <>
               "was conditional on presence, which is now SpaceTopics' decision, not " <>
               "this branch's."

      assert registration_count(pid, b.id) == 1
    end

    test "roster moving away from a space presence also holds RETAINS it, and it still delivers",
         %{conn: conn} do
      viewer = create_user!("Roster Overlap Viewer")

      # Joined => in the presence set => presence holds it too.
      shared = create_channel!("topics-roster-shared")
      join!(shared.id, viewer, "Roster Overlap Viewer")

      elsewhere = create_channel!("topics-roster-elsewhere")

      view = mount_tasks(conn, viewer)
      pid = view.pid

      drive(view, {:roster_resolved, shared.id})

      assert registration_count(pid, shared.id) == 1,
             "two holders must still be ONE registration"

      drive(view, {:roster_resolved, elsewhere.id})

      assert registration_count(pid, shared.id) == 1,
             "releasing the ROSTER hold killed a registration presence still wants — " <>
               "exactly how the unread badge died in cb429830"

      assert registration_count(pid, elsewhere.id) == 1

      # A COUNT OF 1 IS NOT DELIVERY.
      assert_topic_delivers(view, shared.id, "SharedDeliveryBot")
    end
  end
end
