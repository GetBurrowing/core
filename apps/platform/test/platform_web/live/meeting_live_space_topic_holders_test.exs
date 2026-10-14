defmodule PlatformWeb.MeetingLiveSpaceTopicHoldersTest do
  @moduledoc """
  Task `01a02c4e` — how many `chat:space:<id>` registrations
  `PlatformWeb.MeetingLive` leaves on one LiveView pid, on each of the two
  live_sessions the router binds it into.

  ## STAGE 3 TURNED THESE FROM CHARACTERISATION INTO CONTRACT

  Stage 1 wrote this file as a PRE-FIX measurement: the numbers recorded what
  the code did, and a 2 was the defect being measured. Stage 3 moved
  MeetingLive's hold onto `PlatformWeb.SpaceTopics` (`hold(socket, space_id,
  :meeting)`) and gave it the release it never had, so the numbers below are
  now the DESIRED state and a regression must red this file.

  What changed, precisely:

    * the both-holders case is **1, not 2** — one registration shared by
      ShellLive's `:presence` hold and MeetingLive's `:meeting` hold;
    * leaving the room releases `:meeting`, so the count drops to **0** when
      no other surface holds the space and stays at **1** when `:presence`
      does;
    * **an audit clause had to be ADDED, not just moved.** Swapping an
      over-broad teardown for a per-owner release is not a refactor.
      `Chat.remove_participant/1` broadcasts `{:participant_left, deleted}` on
      `chat:space:<id>` (`chat.ex:1556`), and before stage 3 the shell's own
      release — `Registry.unregister/2` under the hood — destroyed
      MeetingLive's raw registration along with its own, so a revoked viewer
      sitting in a room stopped receiving BY ACCIDENT. Per-owner release
      removes that accident, so `MeetingLive` now releases `:meeting` on the
      viewer's own `{:participant_left, _}`. Same shape as task `01a01a1b`
      stage 3 on ChatLive, same fix.

    * **and a count of 1 is not delivery.** The retained-hold test below
      broadcasts on the surviving topic and asserts the message ARRIVES,
      because "one registration in the registry" is a claim about a table,
      not about a mailbox. A release bug that unsubscribed and then
      re-subscribed under a stale bookkeeping entry would satisfy the count
      and deliver nothing.

  ## The mechanism, cited directly

  `Phoenix.PubSub` starts its registry with `keys: :duplicate`.
  `Phoenix.PubSub.subscribe/3` is a bare `Registry.register/3` and
  `Phoenix.PubSub.unsubscribe/2` is `Registry.unregister/2`. So **subscribe
  adds one registration and unsubscribe removes ALL of that pid's
  registrations for the topic** — which is why a second, independent
  subscriber living in the same process is both a duplicate delivery and a
  release hazard, and why `PlatformWeb.SpaceTopics` exists to arbitrate
  ownership (`space_topics.ex`: `@owners` closes at :78, `hold/3` :120,
  `release/3` :140).

  This is NOT ADR 0013 — that ADR covers agent attention modes and triage and
  says nothing about registry arity.

  ## Two routes, two different defects

  `router.ex` binds `MeetingLive` into more than one live_session, with
  different `on_mount` stacks. Verified by grep on this ref:

    * **Route A — `live_session :meet_member`** (`router.ex:446`), host
      prefix `meet.`, `on_mount: [PlatformWeb.ShellLive, {PlatformWeb.LiveAuth,
      :default}]`, containing BOTH `live("/meetings", MeetingLive, :index)`
      (:475) and `live("/meetings/:slug", MeetingLive, :show)` (:476).
      `ShellLive` is an `on_mount` hook, so it runs INSIDE the `MeetingLive`
      process, not beside it. `meeting_live.ex:740` then calls
      `ChatPubSub.subscribe(meeting.chat_space_id)` — a RAW subscribe, not a
      `SpaceTopics.hold/3` — and nothing anywhere releases it. When the
      meeting's chat space is also in the viewer's presence set, ShellLive's
      presence branch (`shell_live.ex:370`, holding via `SpaceTopics.hold(acc,
      id, :presence)` at :381) holds the same topic on the same pid. Two
      holders, one pid.

      `/meetings/:slug` on this route carries no `token`, so it falls past the
      guest mount clause into the general `mount/3`, leaving `:state` nil —
      which is why the `:state`-guarded `handle_params/3` no-op at
      `meeting_live.ex:654` does not fire and the subscribing body at :740 DOES
      run.

    * **Route B — `live_session :guest_meeting`** (`router.ex:570`), NO
      `on_mount` at all, route `live("/:slug/:token", MeetingLive, :show)`
      (:573).

  ## A SECOND, UNRELATED DEFECT FOUND WHILE MEASURING

  The third test below set out to measure the hold ACCUMULATING across two
  meetings visited in one session and could not: room -> room is a live patch
  within `:meet_member`, so `handle_params/3` re-enters
  `MeetingHooks.attach/2` (`meeting_live.ex:823`), whose
  `attach_hook(:meeting_events, ...)` (`meeting_hooks.ex:88`) RAISES on an
  already-attached name and kills the LiveView. That crash is pinned as its
  own test. Accumulation across meetings is therefore unreachable on this ref
  and must be re-measured once the hook is made idempotent.

  A third binding exists that the task brief did not mention: the
  `:authenticated` live_session declares the same two meeting routes with
  `ShellLive` in its `on_mount` stack too (`router.ex:608`, routes at :615 and
  :616 on this ref). It is the same overlap as Route A by the same mechanism;
  this file measures the `meet.`-host route because that is the one the stage
  names.

  **Stage 3's fix covers that third binding for free, and the reason is worth
  stating rather than assuming.** The change is entirely inside
  `meeting_live.ex` and `PlatformWeb.SpaceTopics`, and every one of those
  routes mounts THAT module. Nothing on the hold, release or seed path branches
  on the live_session, on `:chrome_mode`, or on the host: `:meet_member` sets
  `chrome_mode: "none"` and `:authenticated` leaves it absent, and neither
  value is read by `handle_params/3`'s subscribe body. Both stacks carry
  `PlatformWeb.ShellLive` as the first `on_mount`, so the holder map is seeded
  identically before `mount/3` runs — and MeetingLive now calls
  `SpaceTopics.ensure_holders/1` in its own `mount/3` anyway, so a route
  WITHOUT that hook would be covered too.

  The one behavioural difference is what else the live_session contains, and it
  does not reintroduce the defect: `:authenticated` also declares `/chat` and
  `/tasks`, but those are DIFFERENT LiveView modules, so navigating there is a
  fresh mount rather than the meeting -> meeting -> index patching on one pid
  that this file measures.

  ## THE TICKET'S ROUTE B CLAIM WAS CHECKED AND DID NOT HOLD ON THIS REF

  The originating ticket says the guest route also leaks `chat:space`. It does
  not. `git grep -n ChatPubSub apps/platform/lib/platform_web/live/meeting_live.ex`
  returns exactly two hits on this ref — the alias at :226 and the single call
  at :740 — and :740 sits inside the `handle_params/3` `:show` body that the
  guest surface never reaches, because the guest mount clause seeds `:state`
  and the guarded no-op at :654 (reasoning at :642-653) returns first. The
  guest ingress helper `enter_meeting_as_guest/3` subscribes only the MEETINGS
  family: `MeetingsPubSub.subscribe_presence/1` (:3491),
  `subscribe_meeting/1` (:3505) and `subscribe_room/1` (:3508).

  So Route B's real leak is the meetings topics, not `chat:space` — and
  `MeetingsPubSub` already ships `unsubscribe_presence/1`,
  `unsubscribe_meeting/1` and `unsubscribe_room/1`, so closing it needs no new
  API. Test four below asserts the OBSERVED `chat:space` count on the guest
  route, which is zero, and carries its positive control on a meetings topic
  the guest demonstrably does hold. No `chat:space` hold was invented on the
  guest route to make the ticket's sentence true.

  ## STAGE 4 TOOK THE ZERO BRANCH ON ROUTE B — AND HERE IS THE MEASUREMENT

  Stage 4's instructions branch on stage 1's number for the guest route.
  **Stage 1 measured ZERO `chat:space` registrations on `:guest_meeting`**,
  and the zero is not vacuous: the same test asserts a positive control of 1
  on `meetings:presence:<space_id>` for the same pid at the same moment.

  So stage 4 took the ZERO branch. It added **no** `chat:space` subscription
  and **no** `SpaceTopics` call to the guest path — the originating ticket's
  Route B prose was wrong in detail, and satisfying it by subscribing would
  have fabricated the defect it describes. What stage 4 closed is the leak
  that is actually there: `enter_meeting_as_guest/3` subscribes
  `MeetingsPubSub.subscribe_presence/1`, `subscribe_meeting/1` and
  `subscribe_room/1` and released none of them. All three `unsubscribe_*`
  already existed, so no new PubSub API was introduced.

  Two release sites, for two different ways the hold outlives its meeting:
  `MeetingHooks.release_guest_topics/1` on the guest's `"meeting_leave"` /
  `"meeting_left"` events, and the same call at the TOP of
  `enter_meeting_as_guest/3` so the `"submit_name"` re-entry releases before
  re-subscribing rather than stacking a duplicate on one pid.

  ## Measurement discipline

  Counts are read ONLY through `Registry.lookup(Platform.PubSub, topic)`,
  filtered to the LiveView pid. Never through a `ChatPubSub` / `MeetingsPubSub`
  helper, and never through the `:chat_space_holders`, `:shell_chat_space_ids`
  or `:presence_space_ids` assigns — those are written by the code under test,
  so reading them to check it would be circular. The topic string comes from
  `Platform.Chat.PubSub.space_topic/1`, never a hardcoded `"chat:space:" <> id`.

  ## CONTROL TRAP

  ShellLive subscribes `chat:space:<id>` for EVERY space in the viewer's
  presence set, which is `Chat.list_member_space_ids/1` (`shell_live.ex:1190`)
  — every space the viewer holds a participant row on. **Joining the viewer to
  a "control" space would make the shell subscribe to it and destroy the
  control.** Every control space below is therefore one the viewer is
  deliberately NOT joined to. Each absence assertion carries a positive
  control in the same test, because an absence assertion over a topic nobody
  ever subscribed to passes for free.

  ## Two host mechanisms, both required

  Routing to Route A needs the `meet.` PREFIX (Phoenix's `host:` option).
  Being ADMITTED needs the request host to equal the CONFIGURED `:meet_host`
  (`PlatformWeb.ExternalSurface`), which is **fail-closed when unset** — a
  test that forgot the config would exercise the denial path and pass
  vacuously while measuring nothing. `@meet_host` satisfies both and the
  `setup` block sets the config, mirroring `meeting_live_member_mount_test.exs`.

  `async: false` — the PubSub registry is VM-global and this file mutates
  application env.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  # Satisfies BOTH mechanisms: `meet.` prefix for the router scope, exact
  # match for `ExternalSurface` once `:meet_host` is set to the same string.
  @meet_host "meet.example.com"

  # ── Reading the registry (never the assigns) ───────────────────────────────

  defp chat_space_count(pid, space_id) do
    Platform.PubSub
    |> Registry.lookup(ChatPubSub.space_topic(space_id))
    |> Enum.count(fn {entry_pid, _value} -> entry_pid == pid end)
  end

  defp topic_count(pid, topic) do
    Platform.PubSub
    |> Registry.lookup(topic)
    |> Enum.count(fn {entry_pid, _value} -> entry_pid == pid end)
  end

  # A render round-trip guarantees the LiveView has drained the mailbox up to
  # this point, so every subscription taken during mount/handle_params has
  # landed in the registry. Never `Process.sleep/1` — that pins the box's
  # timing, not the code's ordering.
  defp settle(view) do
    _ = render(view)
    view
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  # A plain member of `org` — NOT marked external. The external path is
  # deliberately avoided: `fetch_meeting_for_user/2` gates an external viewer
  # a SECOND time on `ExternalScope.visible_space_id?/2` (`meetings.ex:160`),
  # which is itself satisfied by the chat-space grant. For an external viewer,
  # "can open the meeting" and "is a participant of its chat space" therefore
  # move together — and the pair of tests below needs them to move
  # INDEPENDENTLY, since chat-space participation is the single variable under
  # study. An org member clears the org filter at `meetings.ex:187` regardless
  # of chat participation, which is exactly the separation required.
  defp create_member!(org, label) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "space-topic-holders-#{label}-#{n}@example.com",
        name: "SpaceTopicHolders #{label} #{n}",
        oidc_sub: "oidc-space-topic-holders-#{label}-#{n}"
      })
      |> Repo.insert!()

    Repo.insert!(%OrgMembership{user_id: user.id, org_id: org.id, role: "member"})

    user
  end

  defp join!(space_id, %User{} = user) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  # Silent agent seeding. A DIRECT `Repo.insert!/1` emits no PubSub fan-out, so
  # the only way the LiveView can learn about this row is a message we deliver
  # ourselves on the topic under test. `Chat.add_participant/2` would be wrong
  # here for a specific reason, mirrored from `shell_live_space_topics_test.exs`:
  # it fans out `{:roster_changed_any, _}` on `Chat.global_roster_topic/0`,
  # which this LiveView is ALSO subscribed to (`ShellLive`'s `on_mount` hook
  # subscribes it unconditionally). A refresh triggered by that global topic
  # would arrive whether or not the `chat:space:<id>` registration survived, so
  # the delivery proof would pass on a completely unsubscribed pid.
  # ── WHY THE DELIVERY PROOFS ARE NOT `shell_live_space_topics_test.exs`'s ───
  #
  # That file proves a retained registration DELIVERS by broadcasting
  # `{:roster_changed, sid}` and watching the shell's agent roster recompute.
  # That observable is UNAVAILABLE for a meeting's chat space, and the reason
  # is structural rather than incidental, so it is written down here instead of
  # being rediscovered:
  #
  #   * `Meetings.create_meeting/1` builds the bound space with `kind:
  #     "meeting"` and NO `org_id` — the project lives in `metadata`
  #     (`meetings.ex:340`). `ShellLive`'s `visible_roster/2` ends its query
  #     with `Tenancy.scope(..., binding: :space, field: :org_id)`, so a
  #     null-org space contributes no roster rows and the recompute is a
  #     no-op whether or not the message arrived.
  #   * the shell's unread badge is no use either: `Chat.total_unread_for_viewer/1`
  #     narrows to `@chat_surface_kinds` = `~w(channel dm group)` (`chat.ex:4455`),
  #     which excludes `"meeting"` outright.
  #
  # So each proof below uses an observable that the SURFACE UNDER TEST really
  # owns, and both are still true mailbox proofs: the message is delivered on
  # the `chat:space:<id>` topic and nowhere else.

  # IN-ROOM proof, read through the REGISTRY. `Chat.remove_participant/1`
  # broadcasts `{:participant_left, participant}` on `chat:space:<id>`
  # (`chat.ex:1556`). Both holders release on it — `ShellLive`'s hook drops
  # `:presence` (`shell_live.ex:339`) and `MeetingLive`'s new clause drops
  # `:meeting` — so a delivered message takes the count 1 -> 0, and a dead
  # registration leaves it at 1. The discriminator runs first: the identical
  # message published on a topic this pid does NOT hold must change nothing.
  defp assert_delivers_by_release(view, space_id, control_topic_space_id, viewer_participant) do
    assert chat_space_count(view.pid, space_id) == 1

    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      ChatPubSub.space_topic(control_topic_space_id),
      {:participant_left, viewer_participant}
    )

    _ = render(view)

    assert chat_space_count(view.pid, space_id) == 1,
           "the discriminator failed: the release fired without the topic under test " <>
             "carrying the message, so the drop below would not be evidence of delivery"

    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      ChatPubSub.space_topic(space_id),
      {:participant_left, viewer_participant}
    )

    _ = render(view)

    assert chat_space_count(view.pid, space_id) == 0,
           "the registration on #{ChatPubSub.space_topic(space_id)} did not DELIVER: a " <>
             "revoke broadcast on it produced no release. A count of 1 is a claim about " <>
             "the registry, not about the mailbox."
  end

  # RETAINED-HOLD proof. Same mechanism, and the same function: after the patch
  # back to `/meetings` the only holder left is `:presence`, so the release the
  # delivered message triggers is the shell's alone. `MeetingLive`'s own clause
  # is a no-op there because `:meeting` is nil on the index.
  defp assert_retained_hold_delivers(view, space_id, control_id, viewer_participant),
    do: assert_delivers_by_release(view, space_id, control_id, viewer_participant)

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_space_topic_holders_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    })
    |> Repo.insert!()
  end

  defp meeting!(org, label) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{name: "Space Topic Holders #{label} #{n}", org_id: org.id})

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Space Topic Holders #{label} #{n}",
        slug: "space-topic-holders-#{label}-#{n}"
      })

    meeting
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})

  defp on_meet_host(conn), do: %{conn | host: @meet_host}

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

  # ── Route A: live_session :meet_member (router.ex:446) ─────────────────────

  describe "Route A — :meet_member, /meetings/:slug (router.ex:476)" do
    setup do
      org = tenant_org!()
      viewer = create_member!(org, "member")

      %{org: org, viewer: viewer}
    end

    test "exactly 1 registration when the meeting's chat space is in the viewer's presence set (stage 1 measured 2)",
         %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "joined")

      # CONTROL SPACE / DISCRIMINATING TOPIC: a meeting whose chat space this
      # viewer is deliberately NOT joined to. Joining here would put it in
      # `Chat.list_member_space_ids/1`, make ShellLive's presence branch
      # subscribe it, and DESTROY THE CONTROL.
      control = meeting!(org, "joined-control")
      refute control.chat_space_id in Chat.list_member_space_ids(viewer.id)

      # THE SINGLE VARIABLE: a participant row on the meeting's chat space,
      # which is exactly what puts the space into
      # `Chat.list_member_space_ids/1` — the query ShellLive's presence loader
      # sends itself at `shell_live.ex:1190`.
      viewer_participant = join!(meeting.chat_space_id, viewer)

      # Fixture precondition, read through the Chat CONTEXT (a plain query),
      # not through any assign the LiveView writes. Without this the count
      # below could be 2 for reasons unrelated to the presence branch.
      assert meeting.chat_space_id in Chat.list_member_space_ids(viewer.id)

      {:ok, view, html} =
        conn |> login(viewer) |> on_meet_host() |> live("/meetings/#{meeting.slug}")

      settle(view)

      # ANTI-VACUITY: the room actually rendered. A denial card would take no
      # subscriptions at all and make a low count pass for the wrong reason.
      assert html =~ meeting.name

      # THE MEASUREMENT. TWO holders, ONE registration: ShellLive's presence
      # branch holds `:presence` and MeetingLive now holds `:meeting`, both
      # through `SpaceTopics.hold/3`, which subscribes only when the holder set
      # was empty. Stage 1 measured 2 here, because `meeting_live.ex` took a
      # raw `ChatPubSub.subscribe/1` and `keys: :duplicate` made it add rather
      # than dedupe — every broadcast on this topic reached this process twice.
      assert chat_space_count(view.pid, meeting.chat_space_id) == 1

      # A count of 1 could also be produced by the shell holding it and
      # MeetingLive holding nothing, which would be a different bug wearing the
      # same number. Prove the topic is live from here — and note this doubles
      # as the KILL TEST for stage 3's audit clause: both holders must release
      # on the revoke for the count to reach 0, so deleting
      # `MeetingLive`'s `{:participant_left, viewer}` clause leaves it at 1 and
      # reds this test.
      assert_delivers_by_release(
        view,
        meeting.chat_space_id,
        control.chat_space_id,
        viewer_participant
      )
    end

    test "1 registration while in the room when the chat space is NOT in the viewer's presence set, and 0 after leaving",
         %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "unjoined")

      # No `join!/2` call — that omission IS the variable. The meeting is
      # still reachable (org membership), but its chat space is absent from
      # the viewer's presence set.
      # The discriminating precondition — this is the ONLY thing that differs
      # from the test above, so the count difference isolates ShellLive's
      # presence branch as the second holder.
      refute meeting.chat_space_id in Chat.list_member_space_ids(viewer.id)

      {:ok, view, html} =
        conn |> login(viewer) |> on_meet_host() |> live("/meetings/#{meeting.slug}")

      settle(view)

      # ANTI-VACUITY / POSITIVE CONTROL: the room rendered, so MeetingLive's
      # subscribing body did run. Without this the count of 1 could not be
      # told apart from "the mount was denied and something else subscribed".
      assert html =~ meeting.name

      # MeetingLive alone, holding as `:meeting`.
      pid = view.pid
      assert chat_space_count(pid, meeting.chat_space_id) == 1

      # Same pid asserted, not assumed: a reconnect would clear the registry by
      # process death and make the zero below meaningless.
      _ = render_patch(view, "/meetings")
      settle(view)
      assert view.pid == pid

      # THE RELEASE. `:meeting` was the only holder, so releasing it empties
      # the set and `SpaceTopics` unsubscribes. Stage 1 measured 1 here — the
      # hold outliving the room is exactly the leak this stage closes.
      assert chat_space_count(pid, meeting.chat_space_id) == 0
    end

    test "leaving to /meetings releases :meeting and LEAVES presence's hold alive AND DELIVERING",
         %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "first")

      # THE VARIABLE that separates this test from the one above: the viewer
      # holds a participant row on the meeting's chat space, so ShellLive's
      # presence branch holds it as `:presence` too. Leaving the meeting must
      # therefore NOT take the topic down — a release that unsubscribed
      # unconditionally would silently kill the rail's unread signal for a
      # space the viewer is still a member of.
      viewer_participant = join!(meeting.chat_space_id, viewer)
      assert meeting.chat_space_id in Chat.list_member_space_ids(viewer.id)

      # CONTROL SPACE: a meeting whose chat space this viewer is deliberately
      # NOT joined to and never navigates to. Joining the viewer here would
      # put the space in `Chat.list_member_space_ids/1`, make ShellLive's
      # presence branch subscribe it, and DESTROY THE CONTROL.
      control = meeting!(org, "control")
      refute control.chat_space_id in Chat.list_member_space_ids(viewer.id)

      {:ok, view, _html} =
        conn |> login(viewer) |> on_meet_host() |> live("/meetings/#{meeting.slug}")

      settle(view)
      pid = view.pid
      assert chat_space_count(pid, meeting.chat_space_id) == 1

      # `/meetings` and `/meetings/:slug` are BOTH declared inside
      # `:meet_member` (router.ex:475/:476) precisely so index <-> room is a
      # live patch rather than a page reload. Same pid before and after —
      # asserted, not assumed, because a reconnect would clean the registry up
      # by process death and make the survival below meaningless.
      _ = render_patch(view, "/meetings")
      settle(view)
      assert view.pid == pid

      # THE PROPERTY THIS TASK CARRIES. `:meeting` released, `:presence` still
      # holding, so the registration count is 1 — NOT 0. Stage 1 also read 1
      # here, for the opposite reason (nothing released anything), which is
      # precisely why the count alone cannot certify the fix and the delivery
      # assertion below is not optional.
      assert chat_space_count(pid, meeting.chat_space_id) == 1

      # A COUNT OF 1 IS NOT DELIVERY. The control space doubles as the
      # discriminating topic here — this pid holds nothing on it, so the same
      # message published there must change nothing.
      assert_retained_hold_delivers(
        view,
        meeting.chat_space_id,
        control.chat_space_id,
        viewer_participant
      )

      # POSITIVE CONTROL, same pid, same moment: a chat space this process
      # never had reason to hold reads zero. Without it the assertion above
      # could be satisfied by a lookup that answers for anything.
      assert chat_space_count(pid, control.chat_space_id) == 0
    end

    test "a SECOND meeting in the same pid STILL crashes on a double hook attach — accumulation across meetings remains unreachable after stage 3",
         %{conn: conn, org: org, viewer: viewer} do
      # This test was written to measure accumulation across two meetings and
      # instead found a SEPARATE defect on the same route, so it pins what the
      # code actually does rather than the number that was expected.
      #
      # `handle_params/3` calls `MeetingHooks.attach/2` (`meeting_live.ex:823`),
      # which unconditionally `attach_hook(:meeting_events, :handle_event, ...)`
      # (`meeting_hooks.ex:88`). `Phoenix.LiveView.Lifecycle.attach_hook/4`
      # RAISES on a name already attached to that socket. Because both meeting
      # routes live in one live_session, room -> room is a live patch on ONE
      # pid, so the second `handle_params/3` re-enters the same attach and the
      # LiveView dies with `ArgumentError: existing hook :meeting_events
      # already attached on :handle_event`.
      #
      # Consequence for THIS task: "the hold accumulates across n meetings in
      # one session" cannot be observed, because the process does not survive
      # the second meeting. The single-meeting leak pinned above is the real
      # extent of it. Whoever fixes the hook must re-measure — accumulation
      # becomes reachable the moment the crash stops.
      #
      # RE-CHECKED IN STAGE 3, STILL BLOCKING. Stage 3 changed nothing in
      # `MeetingHooks`, and `attach/2` still calls `attach_hook(:meeting_events,
      # ...)` unconditionally (`meeting_hooks.ex:87` on this ref), so this exit
      # is unchanged. Routing via the index first does not dodge it either: the
      # `:index` `handle_params/3` clause detaches nothing, so room -> index ->
      # room re-enters the same attach.
      #
      # This test therefore still asserts a CRASH, not a count, and stage 3's
      # `SpaceTopics.release_all(socket, :meeting)` at the top of the `:show`
      # success body — the half that guards meeting -> meeting — has no
      # end-to-end observation available on this ref. It is not asserted here
      # rather than asserted weakly: `release_all/2`'s own semantics are
      # covered by `space_topics_test.exs`, and inventing a fixture that
      # bypasses `handle_params/3` to reach it would be testing a call site
      # this route cannot actually take.
      first = meeting!(org, "first")
      second = meeting!(org, "second")

      {:ok, view, _html} =
        conn |> login(viewer) |> on_meet_host() |> live("/meetings/#{first.slug}")

      settle(view)

      # Trap the exit rather than let it fail the test process, and NAME what
      # broke: a bare `catch_exit` would pass just as happily on any other
      # crash, including one this test caused itself.
      Process.flag(:trap_exit, true)

      assert catch_exit(render_patch(view, "/meetings/#{second.slug}")) |> inspect() =~
               "existing hook :meeting_events already attached"
    end
  end

  # ── Route B: live_session :guest_meeting (router.ex:570) ───────────────────

  describe "Route B — :guest_meeting, /:slug/:token (router.ex:573)" do
    test "OBSERVED: 0 chat:space registrations — the ticket's Route B claim does not hold on this ref",
         %{conn: conn} do
      org = tenant_org!()
      meeting = meeting!(org, "guest")

      # `sign/4` takes a UNIX INTEGER expiry, not a `DateTime`.
      expires_at = DateTime.to_unix(DateTime.utc_now()) + 3600
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

      {:ok, view, _html} =
        conn |> on_meet_host() |> live("/#{meeting.slug}/#{token}")

      settle(view)

      # ANTI-VACUITY: the guest really is in the meeting. `:in_meeting` is the
      # only state from which `enter_meeting_as_guest/3` runs at all; on
      # `:expired` / `:invalid` / `:name_entry` NOTHING subscribes and every
      # count below would read zero for a reason unrelated to `chat:space`.
      assert :sys.get_state(view.pid).socket.assigns.state == :in_meeting

      # POSITIVE CONTROL, same test, same pid: a topic the guest DOES hold.
      # `enter_meeting_as_guest/3` calls `MeetingsPubSub.subscribe_presence/1`
      # at `meeting_live.ex:3491`. This proves the registry lookup can see
      # this pid's registrations at all, which is what makes the zero below
      # meaningful rather than free.
      assert topic_count(view.pid, MeetingsPubSub.presence_topic(meeting.chat_space_id)) == 1

      # THE FINDING. Zero. `ChatPubSub` appears exactly twice in
      # `meeting_live.ex` on this ref — the alias at :226 and the call at
      # :740 — and :740 lives in the `handle_params/3` `:show` body, which the
      # guest never reaches because the guest mount clause seeds `:state` and
      # the guarded no-op at :654 returns first.
      #
      # Route B's real leak is the MEETINGS family (:3491, :3505, :3508), for
      # which `MeetingsPubSub` already ships `unsubscribe_presence/1`,
      # `unsubscribe_meeting/1` and `unsubscribe_room/1`.
      assert chat_space_count(view.pid, meeting.chat_space_id) == 0
    end

    # ── Stage 4: the meetings-family leak, closed ────────────────────────────
    #
    # BRANCH TAKEN, AND THE MEASUREMENT THAT DECIDED IT. The stage's
    # instructions branch on stage 1's number. Stage 1 measured the
    # `:guest_meeting` route at **ZERO** `chat:space` registrations (the test
    # directly above, non-vacuous because its positive control on
    # `meetings:presence:<id>` reads 1 on the same pid at the same moment), so
    # stage 4 took the ZERO branch: no `chat:space` hold was invented on the
    # guest path and no `SpaceTopics` call was added there. Making the
    # ticket's Route B sentence true by subscribing would have been
    # fabricating the defect it describes.
    #
    # What stage 4 fixed instead is the leak that IS there: the three
    # meetings-family subscriptions `enter_meeting_as_guest/3` takes and never
    # released — presence, meeting and room. All three unsubscribes already
    # existed on `Platform.Meetings.PubSub`, so nothing new was added to it.

    test "the guest's meetings-family holds are RELEASED on leave, and the pre-leave counts prove they existed",
         %{conn: conn} do
      org = tenant_org!()
      meeting = meeting!(org, "guest-release")

      # A live room must exist BEFORE entry or `subscribe_room/1` never runs
      # and the room third of this test would pass vacuously — the entry path
      # reads `Meetings.get_active_room/1` and subscribes only on a hit.
      {:ok, room} = Meetings.ensure_room(meeting.chat_space_id)

      expires_at = DateTime.to_unix(DateTime.utc_now()) + 3600
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

      {:ok, view, _html} = conn |> on_meet_host() |> live("/#{meeting.slug}/#{token}")
      settle(view)

      # ANTI-VACUITY: the guest really entered. On `:name_entry` / `:expired`
      # / `:invalid` nothing subscribes and every count below reads zero for a
      # reason that has nothing to do with releasing.
      assert :sys.get_state(view.pid).socket.assigns.state == :in_meeting

      pid = view.pid
      presence = MeetingsPubSub.presence_topic(meeting.chat_space_id)
      meeting_topic = MeetingsPubSub.meeting_topic(meeting.id)
      room_topic = MeetingsPubSub.room_topic(room.id)

      # POSITIVE CONTROLS FOR THE ZEROS BELOW — all three non-zero FIRST.
      # Without these, "0 after leaving" is satisfied by a guest that never
      # subscribed at all.
      assert topic_count(pid, presence) == 1
      assert topic_count(pid, meeting_topic) == 1
      assert topic_count(pid, room_topic) == 1

      # CONTROL TOPIC: a second meeting this guest has no invite to and never
      # entered. It proves the lookup is not answering 0 for everything after
      # the leave — it already answers 0 for this one now.
      control = meeting!(org, "guest-release-control")
      control_presence = MeetingsPubSub.presence_topic(control.chat_space_id)
      assert topic_count(pid, control_presence) == 0

      # THE LEAVE. `"meeting_leave"` is the guest top-bar button
      # (`meeting_live.html.heex`, `data-role="meeting-leave"`), routed to
      # `MeetingHooks.handle_guest_event/3` by `attach_guest/1`.
      render_click(view, "meeting_leave", %{})
      settle(view)

      # SAME PID asserted, not assumed: a crash-and-remount would empty the
      # registry by process death and make all three zeros meaningless.
      assert view.pid == pid

      assert topic_count(pid, presence) == 0,
             "the guest kept its meetings:presence hold after leaving"

      assert topic_count(pid, meeting_topic) == 0,
             "the guest kept its meetings:meeting hold after leaving"

      assert topic_count(pid, room_topic) == 0,
             "the guest kept its meetings:room hold after leaving"
    end

    test "re-entry via submit_name takes NO second registration on any topic (keys: :duplicate makes a repeat subscribe a real duplicate)",
         %{conn: conn} do
      org = tenant_org!()
      meeting = meeting!(org, "guest-reentry")
      {:ok, room} = Meetings.ensure_room(meeting.chat_space_id)

      expires_at = DateTime.to_unix(DateTime.utc_now()) + 3600
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

      {:ok, view, _html} = conn |> on_meet_host() |> live("/#{meeting.slug}/#{token}")
      settle(view)

      pid = view.pid

      # THE PRECONDITION THAT MAKES THIS THE SHARP CASE: already `:in_meeting`,
      # i.e. already subscribed, when the re-entering event arrives.
      assert :sys.get_state(pid).socket.assigns.state == :in_meeting

      topics = [
        MeetingsPubSub.presence_topic(meeting.chat_space_id),
        MeetingsPubSub.meeting_topic(meeting.id),
        MeetingsPubSub.room_topic(room.id)
      ]

      for topic <- topics, do: assert(topic_count(pid, topic) == 1)

      # RE-ENTRY. `"submit_name"` calls `enter_meeting_as_guest/3` again — the
      # same helper that subscribed at mount. Before stage 4 this added a
      # SECOND registration per topic on this one pid, because
      # `Phoenix.PubSub`'s registry is `keys: :duplicate` and `subscribe/3` is
      # a bare `Registry.register/3`. Every broadcast then arrived twice.
      render_submit(view, "submit_name", %{"guest" => %{"name" => "Jane Renamed"}})
      settle(view)

      # Same pid — `attach_guest/1` detaches `:meeting_events` before
      # re-attaching, so the guest surface does NOT hit the
      # `ArgumentError: existing hook :meeting_events already attached` crash
      # that stage 1 pinned on the `:meet_member` live-patch path.
      assert view.pid == pid
      assert :sys.get_state(pid).socket.assigns.state == :in_meeting

      # ANTI-VACUITY: the re-entry really re-ran. If `submit_name` had bounced
      # (validation error, unchanged assigns) the counts would stay at 1
      # without the release-then-resubscribe path ever being exercised.
      assert :sys.get_state(pid).socket.assigns.display_name == "Jane Renamed"

      for topic <- topics do
        assert topic_count(pid, topic) == 1,
               "re-entry duplicated the registration on #{topic}: " <>
                 "#{topic_count(pid, topic)} registrations on one pid"
      end
    end
  end

  # ── The two routes are two DIFFERENT defects with two DIFFERENT fixes ──────

  describe "route separation" do
    # ONE test holding BOTH facts at once, deliberately. Either fact alone is
    # ambiguous: "leaving leaves 1" is satisfied by a route that releases
    # nothing, and "leaving leaves 0" is satisfied by a route that never held
    # anything. Only the PAIR, asserted together, says the stage-3 fix
    # (`chat:space`, released per-owner, presence survives) and the stage-4
    # fix (meetings family on the guest path, nothing else holding) are
    # separate changes to separate code — which is the claim the ticket got
    # wrong when it said Route B leaked `chat:space` too.
    test "Route A leaves chat:space at 1 after leaving (presence survives) while Route B leaves it at 0 (nothing else held it)",
         %{conn: conn} do
      org = tenant_org!()

      # ── Fact 1: Route A, :meet_member ──
      viewer = create_member!(org, "separation-member")
      meeting_a = meeting!(org, "separation-a")

      # THE VARIABLE for Route A: a participant row puts the space into
      # `Chat.list_member_space_ids/1`, so ShellLive's presence branch holds
      # `chat:space:<id>` as `:presence` alongside MeetingLive's `:meeting`.
      join!(meeting_a.chat_space_id, viewer)
      assert meeting_a.chat_space_id in Chat.list_member_space_ids(viewer.id)

      {:ok, view_a, html_a} =
        conn |> login(viewer) |> on_meet_host() |> live("/meetings/#{meeting_a.slug}")

      settle(view_a)
      assert html_a =~ meeting_a.name
      pid_a = view_a.pid
      assert chat_space_count(pid_a, meeting_a.chat_space_id) == 1

      _ = render_patch(view_a, "/meetings")
      settle(view_a)
      assert view_a.pid == pid_a

      assert chat_space_count(pid_a, meeting_a.chat_space_id) == 1,
             "Route A: leaving the room took down a chat:space topic that :presence " <>
               "still holds — the shell's unread signal for a space the viewer is " <>
               "still a member of"

      # ── Fact 2: Route B, :guest_meeting, SAME test ──
      meeting_b = meeting!(org, "separation-b")
      {:ok, room_b} = Meetings.ensure_room(meeting_b.chat_space_id)
      expires_at = DateTime.to_unix(DateTime.utc_now()) + 3600
      token = GuestInvite.sign(meeting_b.slug, expires_at, "Jane Doe")

      {:ok, view_b, _html_b} = conn |> on_meet_host() |> live("/#{meeting_b.slug}/#{token}")
      settle(view_b)
      pid_b = view_b.pid
      assert :sys.get_state(pid_b).socket.assigns.state == :in_meeting

      # The guest never held chat:space — stage 1's measurement, restated at
      # the moment the contrast is drawn rather than cited from another test.
      assert chat_space_count(pid_b, meeting_b.chat_space_id) == 0

      # POSITIVE CONTROL for that zero, on this pid, in this test: a topic the
      # guest demonstrably DOES hold. Without it the 0 above and the 0 below
      # are both free.
      room_topic_b = MeetingsPubSub.room_topic(room_b.id)
      assert topic_count(pid_b, room_topic_b) == 1

      render_click(view_b, "meeting_leave", %{})
      settle(view_b)
      assert view_b.pid == pid_b

      assert chat_space_count(pid_b, meeting_b.chat_space_id) == 0,
             "Route B: a chat:space hold appeared on the guest route — stage 4 was " <>
               "supposed to add none"

      # And the thing Route B's fix DOES change, measured in the same breath
      # so this test cannot pass on a stage-4 that did nothing at all.
      assert topic_count(pid_b, room_topic_b) == 0,
             "Route B: the guest kept its meetings:room hold after leaving"

      # Both pids still alive and distinct — the two facts above were read
      # from two different processes, not one reused handle.
      assert pid_a != pid_b
      assert Process.alive?(pid_a)
      assert Process.alive?(pid_b)
    end
  end
end
