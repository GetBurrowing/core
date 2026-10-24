defmodule PlatformWeb.ShellLiveSubscriptionEnumerationTest do
  @moduledoc """
  ENUMERATION, not a fix (task 01a01a1b stage 1).

  This module ships **no behaviour change**. Its deliverable is a measured
  census of how many `Platform.PubSub` registrations a single LiveView pid
  holds per `chat:space:<id>` topic after a settled mount, taken by two
  independent methods, together with an explicit statement of what each
  method cannot see. A later stage may act on the numbers; nothing here
  asserts that any particular number is *correct*.

  ## Premise — re-verified against `deps/phoenix_pubsub` (2.2.0) at this sha

    * `deps/phoenix_pubsub/lib/phoenix/pubsub/supervisor.ex:31` — the backing
      `Registry` is started with `keys: :duplicate`.
    * `deps/phoenix_pubsub/lib/phoenix/pubsub.ex:205` — `subscribe/3` is a bare
      `Registry.register(pubsub, topic, opts[:metadata])`. It is **not**
      idempotent per pid: N subscribes by one process to one topic produce N
      registrations.
    * `deps/phoenix_pubsub/lib/phoenix/pubsub.ex:216` — `unsubscribe/2` is a
      bare `Registry.unregister(pubsub, topic)`, which drops **every** one of
      that pid's registrations for the topic in a single call.

  **Subscribe adds one; unsubscribe removes all.** That asymmetry — not any
  individual call site — is what makes the count worth measuring: a surface
  that subscribed twice and unsubscribes once is fully unsubscribed, and a
  surface that subscribed twice and never unsubscribes double-delivers.

  ## Structural fact this test depends on

  `PlatformWeb.ShellLive` is an `on_mount` hook, not a separate process. It is
  installed on the `:authenticated`, `:external_chat` and `:meet_member`
  live_sessions (`lib/platform_web/router.ex:354`, `:447`, `:600`, `:666`,
  `:687`, `:698`), so its subscribes land in the **same pid** as `TasksLive`
  and `ChatLive`. File scope is not process scope, and the count below is a
  property of the pid, not of `shell_live.ex`.

  ## The two methods, and why both

    1. **Forward map** — `Registry.lookup(Platform.PubSub, topic)` for a topic
       we name up front, counting entries whose pid is the LV pid. Gives an
       exact per-topic **count**, which is the whole point. Blind to any topic
       we did not think to name.

    2. **Reverse map** — `Registry.keys(Platform.PubSub, lv_pid)` filtered to
       the `chat:space:` prefix. Finds topics we did **not** predict.

  **REFUTED PREMISE — this stage's brief said method 2 dedupes. It does not.**
  The brief asserted that `Registry.keys/2` returns unique keys and therefore
  "cannot see the 2-vs-1 count". Measured against Elixir 1.19.5, a `:duplicate`
  registry returns the key ONCE PER REGISTRATION:

      {:ok, _} = Registry.start_link(keys: :duplicate, name: :probe)
      Registry.register(:probe, "t", nil)
      Registry.register(:probe, "t", nil)
      Registry.keys(:probe, self())  #=> ["t", "t"]   NOT ["t"]

  So method 2 is a **multiset**, not a set, and it *can* see the count. That
  makes the two methods agree on counts rather than complement each other on
  them, and `assert_methods_agree/2` below pins that agreement — if a future
  Elixir does start deduping, that assertion fails loudly instead of silently
  turning method 2 into a weaker instrument. Method 2's real and only unique
  value is **discovery**: topics we did not name up front.

  The `chat:space:` prefix is `Platform.Chat.PubSub.space_topic/1`
  (`lib/platform/chat/pub_sub.ex:50`), read here as the source of truth rather
  than hardcoded.

  ## Blind spots shared by BOTH methods — do not read a number here as a total

    * **Later subscribes.** `{:roster_resolved, _}` and
      `{:presence_spaces_resolved, _}` are sent from Tasks and land *after*
      mount returns (`shell_live.ex:971`, `:994`). A census taken at the wrong
      instant undercounts. This module synchronises with `render_async/1` plus
      `render/1` — never `Process.sleep/1`, which would pin the box's timing
      rather than the code's ordering.
    * **Other pids.** Both methods are scoped to one LV pid. A duplicate
      delivery caused by a *second* process subscribing to the same topic is
      invisible here, by construction.
    * **Other topics carrying the same events.** `space_agents:<id>`
      (`shell_live.ex:253`), `active_agent:<id>` (`chat_live.ex:690`),
      `Chat.global_roster_topic/0` (`shell_live.ex:118`) and the meetings
      presence topics all fan out alongside `chat:space:<id>`. Filtering to the
      `chat:space:` prefix deliberately excludes them; a "1" below does not
      mean one delivery.

  ## Measurement discipline

  Counts are read **only** through `Registry.lookup/2` and `Registry.keys/2`
  against `Platform.PubSub`. They are deliberately *not* read through a
  `ChatPubSub` helper, and *not* through the `:shell_chat_space_ids` or
  `:roster_space_id` assigns — those assigns are written by the very code under
  measurement, so reading them to check that code would be circular.

  ## The control-space trap

  The presence branch (`shell_live.ex:275`) subscribes `chat:space:<id>` for
  **every** space in the shell's chat subscribe set, and that set is
  `Chat.list_member_space_ids/1` — i.e. every non-archived space the viewer
  participates in, with no org fence (task 01a01f4c). So joining the
  viewer to the "control" space would make the shell subscribe to it and
  destroy the control. The control here is therefore a space the viewer is
  deliberately **not** joined to. Its assertion is a claim about
  **subscription**, not about roster visibility or about what the viewer may
  read.

  ## The vacuity trap

  PR #791 fenced the roster to spaces the viewer participates in
  (`shell_live.ex:848-857`), so a fixture that seeds a space *without* joining
  the viewer yields an **empty roster** — and an empty roster subscribes to
  nothing, which would make the positive case pass for the wrong reason. The
  positive fixture therefore joins the viewer **and** carries an anti-vacuity
  assertion that the seeded agent actually appears in the roster.

  ## ── MEASURED RESULTS (the deliverable) ────────────────────────────────────

  All numbers are registrations held by ONE LiveView pid on
  `chat:space:<id>`, after the async loaders have settled. Measured on this
  branch; re-measure rather than quoting these.

  **Amended by task 01a01a1b stage 2** — the shell's roster and presence
  branches now share a single `PlatformWeb.SpaceTopics` hold, so every count
  below that included BOTH of them drops by one. **Amended again by stages 3
  and 4** — `chat_live.ex` and `tasks_live.ex` have since adopted the same
  holder map, so no surface subscribes `chat:space:<id>` raw any more and the
  counts below are final rather than interim. The pre-stage-2 numbers are kept
  in parentheses because the delta is the finding.

  | Surface           | Space                                   | Count |
  |-------------------|-----------------------------------------|-------|
  | `/tasks`          | roster space AND in presence set        | **1** (was 2) |
  | `/tasks`          | never joined (control)                  | 0     |
  | `/chat/<viewed>`  | viewed AND roster AND joined            | **2** (was 3) |
  | `/chat/<viewed>`  | joined, not viewed                      | 2     |
  | `/chat/<viewed>`  | **never joined**                        | **1** |
  | `/chat/<viewed>`  | archived                                | 0     |
  | after navigating away from the viewed space | that space    | **1** |

  (`before` the navigation is now 2, was 3.)

  ### Confirmed from the hypothesis list

    * `shell_live.ex:254` (roster) and `shell_live.ex:275` (presence) both
      fire for an overlapping space and neither knows about the other. **This
      is the headline 2**, and it is the pair stage 2 exists to collapse.
    * `ChatLive` subscribes per-space in three places: the mount sidebar loop
      (`chat_live.ex:585-587`), the `handle_params` enter path
      (`chat_live.ex:833-834`) and the leave path (`chat_live.ex:750-754`).

  ### REFUTED by measurement

    * **`Registry.keys/2` does not dedupe.** See the REFUTED PREMISE note
      above. Method 2 is a multiset and can see counts.
    * **`MeetingState.subscribe/1` is not in scope.** Its topic is
      `"meeting:state:<user_id>"` (`lib/platform/meetings/state.ex:83`) —
      keyed by user, no `chat:space:` prefix. Excluded, as the third test pins.
    * **"Not joined" is not a subscription control on the chat surface.** It
      measures 1, not 0, because the sidebar loop is unrestricted for internal
      users. It remains a valid control on `/tasks`.
    * **The `chat_live.ex:829-834` comment's guarantee does not survive
      mount.** It says the unsubscribe-then-subscribe "guarantee[s] a single
      active subscription here". True of ChatLive alone, false of the pid: the
      shell's two async subscribes land afterwards, taking the viewed space to
      3.

  ## ── SCOPE VERDICT: THIS IS BIGGER THAN STAGES 2-5 ─────────────────────────

  Stages 2-5 touch `shell_live.ex` and `tasks_live.ex` only. The navigation
  measurement below shows `chat_live.ex` mutates the same registry keys in the
  same pid, and stage 2 plans a holder map that is a **per-process mirror** of
  registry state. A mirror is only true while every mutation goes through it.

  `ChatLive`'s leave path (`chat_live.ex:750`) calls
  `ChatPubSub.unsubscribe(prev.id)` — an unconditional `Registry.unregister/2`
  that will drop registrations stage 2's holder map still believes are held,
  from a file stage 2 does not touch. After stage 2 lands, the holder map will
  therefore **confidently report a hold that no longer exists**, and will
  refuse to re-subscribe on the next `hold_chat_space/3` because its set is
  non-empty. That is strictly worse than today's honest double-subscribe: a
  silently dead subscription instead of a duplicated one.

  So either stage 4's shared module must be adopted by `chat_live.ex` too, or
  ChatLive's per-space subscribe/unsubscribe must be brought under the same
  bookkeeping by the concurrent chat-subscription task before stage 2 ships.
  **Flagged, not fixed here** — this stage ships no lifecycle change.

  `async: false` — the census reads a VM-global registry, and a concurrently
  mounted LiveView in another test would add its own pid's registrations to
  the same topics. Scoping every count to our own pid makes the *numbers*
  safe, but the reverse-map sweep is still cheaper and less surprising serial.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @space_topic_prefix "chat:space:"

  # ── Fixtures (invented names only — `core` is a PUBLIC repo) ────────────────

  # The roster and the presence set are BOTH org-scoped by
  # `Tenancy.scope/3`, so a user with no org membership resolves an empty
  # visibility and every branch under measurement no-ops. The membership is
  # fixture plumbing to make the code under test reachable at all — it is not
  # the thing being measured.
  defp create_user!(name) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "sub-census-#{n}@example.com",
        name: name,
        oidc_sub: "oidc-sub-census-#{n}",
        avatar_url: nil
      })

    Repo.insert!(%OrgMembership{
      user_id: user.id,
      org_id: Platform.Tenancy.get_org_by_slug!("acme").id,
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

  # ── Census (methods 1 and 2) ────────────────────────────────────────────────

  # METHOD 1 — forward map. Exact count of `pid`'s registrations on one named
  # topic. `Registry.lookup/2` on a `:duplicate` registry returns one
  # `{pid, value}` entry PER registration, so length-after-filter is the count.
  defp registration_count(pid, space_id) do
    Platform.PubSub
    |> Registry.lookup(ChatPubSub.space_topic(space_id))
    |> Enum.count(fn {entry_pid, _value} -> entry_pid == pid end)
  end

  # METHOD 2 — reverse map. Every `chat:space:` topic this pid holds at least
  # one registration on. `Registry.keys/2` DEDUPES, so this is a set, not a
  # multiset: it can never return the count.
  defp subscribed_space_topics(pid) do
    Platform.PubSub
    |> Registry.keys(pid)
    |> Enum.filter(&String.starts_with?(&1, @space_topic_prefix))
    |> Enum.sort()
  end

  # Cross-check: the forward map's count and the reverse map's multiplicity
  # must match. This is the assertion that would catch a future Elixir making
  # `Registry.keys/2` dedupe (which would quietly weaken method 2).
  defp assert_methods_agree(pid, space_id) do
    topic = ChatPubSub.space_topic(space_id)
    forward = registration_count(pid, space_id)
    reverse = Enum.count(subscribed_space_topics(pid), &(&1 == topic))

    assert forward == reverse,
           "methods disagree on #{topic}: forward map counted #{forward}, reverse map " <>
             "counted #{reverse}. If reverse is 1 while forward is >1, Registry.keys/2 " <>
             "has started deduping and method 2 is no longer a count."

    forward
  end

  # Settle the LV: `render_async/1` waits for the shell's `start_async` Task.
  # `resolve_chat_space_ids/2` `send/2`s its resolution message BEFORE
  # returning, so a completed `render_async` implies the LV has already
  # processed `{:presence_spaces_resolved, _}`. The trailing
  # `render/1` is a second round-trip for the handlers those messages queued.
  defp settle(view) do
    _ = render_async(view)
    _ = render(view)
    view
  end

  describe "chat:space registration census for a settled shell-bearing LiveView" do
    test "on /tasks: a space that is BOTH the roster space and in the presence set, versus a control space the viewer never joined",
         %{conn: conn} do
      viewer = create_user!("Census Viewer")
      agent = create_agent!("CensusBot")

      # OVERLAP space — viewer joined (so it is in the presence set) AND it
      # carries an agent participant (so it can be the roster space). This is
      # the space both `shell_live.ex:254` and `shell_live.ex:275` can reach.
      overlap = create_channel!("census-overlap")
      join!(overlap.id, viewer, "Census Viewer")
      Chat.set_principal_agent(overlap.id, agent.id)

      # CONTROL space — the viewer is deliberately NOT joined. Joining them
      # would put it in `list_member_space_ids/1` and the presence branch
      # would subscribe it, destroying the control. See the moduledoc.
      control = create_channel!("census-control")
      Chat.set_principal_agent(control.id, create_agent!("ControlBot").id)

      view =
        conn
        |> init_test_session(current_user_id: viewer.id)
        |> live(~p"/tasks")
        |> then(fn {:ok, view, _html} -> view end)
        |> settle()

      pid = view.pid

      # ANTI-VACUITY: the overlap space is in the presence branch's INPUT, so
      # the positive count below is that branch's. The roster branch that also
      # reached it (and that this case was written to catch doubling it) was
      # deleted with the agents meter in task 01a1557a-8f80 stage 3; the agent
      # stays on the fixture so the space is still the shape it used to pick.
      assert overlap.id in Chat.list_member_space_ids(viewer.id),
             "anti-vacuity failed: the overlap space is not in the shell's subscribe " <>
               "set, so the presence branch never reached it and the census is meaningless"

      # ── METHOD 1: forward map, exact counts ─────────────────────────────
      overlap_count = registration_count(pid, overlap.id)
      control_count = registration_count(pid, control.id)

      # POSITIVE CONTROL for the absence assertion below: the overlap topic is
      # reachable and non-zero, so a zero on `control` means "not subscribed",
      # not "this measurement reads zero for everything".
      assert overlap_count > 0,
             "positive control failed: the LV holds no registration at all on the " <>
               "overlap space, so the control's zero proves nothing"

      # THE MEASURED HEADLINE — 2, as hypothesised, and here is the mechanism:
      # the roster branch (`shell_live.ex:254`) and the presence branch
      # (`shell_live.ex:275`) both reach this space and neither consults the
      # other's bookkeeping. `release_roster_subscriptions/1`
      # (`shell_live.ex:748-762`) does check `shell_chat_space_ids` before
      # unsubscribing — but it only runs on a roster_space_id CHANGE, so it
      # never fires on a first mount and does nothing to prevent the pair.
      # Recorded as an equality so a later stage's fix moves this line
      # deliberately and has to say why. MOVED BY TASK 01a01a1b STAGE 2, and
      # here is the why: both branches now hold the space through
      # `PlatformWeb.SpaceTopics`, which subscribes only when the holder set
      # was empty, so the pair collapses to ONE registration. The stage-2
      # lifecycle assertions live in
      # `shell_live_space_topics_test.exs`; this line stays as the census
      # record that the headline 2 is gone.
      # Since task 01a1557a-8f80 stage 3 the roster holder is gone outright, so
      # the 1 is the presence branch alone.
      assert overlap_count == 1,
             "MEASURED HEADLINE moved: expected 1 registration for one pid on the " <>
               "overlap space (presence alone since the roster branch was deleted; " <>
               "roster + presence shared one hold from stage 2; it was 2 before), " <>
               "observed #{overlap_count}"

      # NEGATIVE: on /tasks, a space the viewer never joined draws no
      # chat:space subscription. This is a claim about SUBSCRIPTION only, not
      # about what the viewer may read. NOTE this holds on /tasks and is
      # FALSE on the chat surface — see the next test, where the sidebar's
      # channel loop subscribes never-joined public channels.
      assert control_count == 0

      # ── METHOD 2: reverse map, set membership only ──────────────────────
      topics = subscribed_space_topics(pid)

      assert ChatPubSub.space_topic(overlap.id) in topics
      refute ChatPubSub.space_topic(control.id) in topics

      # Methods 1 and 2 agree on the count. See the REFUTED PREMISE note in
      # the moduledoc: `Registry.keys/2` does NOT dedupe, so the overlap topic
      # appears in `topics` twice, matching the forward map's 2.
      assert_methods_agree(pid, overlap.id)
      assert_methods_agree(pid, control.id)
    end

    test "on a chat surface: the never-joined control is subscribed anyway, and every space carries exactly one registration",
         %{conn: conn} do
      viewer = create_user!("Chat Census Viewer")
      agent = create_agent!("ChatCensusBot")

      viewed = create_channel!("census-chat-viewed")
      join!(viewed.id, viewer, "Chat Census Viewer")
      Chat.set_principal_agent(viewed.id, agent.id)

      # A SECOND joined space the viewer participates in but is not viewing.
      other = create_channel!("census-chat-other")
      join!(other.id, viewer, "Chat Census Viewer")

      # The intended control: viewer NOT joined. See the finding below.
      control = create_channel!("census-chat-control")

      # POSITIVE CONTROL for the reverse map's discrimination: it must still
      # separate SOME space from the subscribed set, or its assertions here
      # are vacuous. An archived channel is invisible to every branch.
      # Archived BEFORE mount deliberately: `Chat.archive_space/1` broadcasts
      # `:space_archived`, and a live ChatLive handling that broadcast
      # re-queries the sidebar from the LV process, which collides with the
      # test's sandbox connection. Sequencing it ahead of the mount removes
      # the race without weakening the control.
      archived = create_channel!("census-chat-archived")
      {:ok, _} = Chat.archive_space(archived)

      view =
        conn
        |> init_test_session(current_user_id: viewer.id)
        |> live(~p"/chat/#{viewed.slug}")
        |> then(fn {:ok, view, _html} -> view end)
        |> settle()

      pid = view.pid

      viewed_count = assert_methods_agree(pid, viewed.id)
      other_count = assert_methods_agree(pid, other.id)
      control_count = assert_methods_agree(pid, control.id)

      # ── FINDING: THE CONTROL IS NOT A CONTROL ON THIS SURFACE ───────────
      # The brief predicted 0 here, on the reasoning that only the presence
      # branch subscribes `chat:space:` and it is fenced to joined spaces.
      # MEASURED: 1. `ChatLive.mount/3` builds `all_spaces = channels ++
      # pinned_task_spaces ++ dm_conversations` (`chat_live.ex:562`) and
      # subscribes each (`chat_live.ex:585-587`). `presence_subscribe_space_ids/2`
      # narrows that set for EXTERNAL users only — "Internal users are
      # unrestricted" (`chat_live.ex:578-583`) — so an internal viewer
      # subscribes every non-archived public channel in their org visibility,
      # joined or not.
      #
      # This is recorded as measured fact, NOT as a defect claim: a sidebar
      # that renders unread counts for channels you have not joined needs
      # their message stream, so the subscription may well be intended. What
      # it does mean is that "not joined" cannot serve as a subscription
      # control on the chat surface. The /tasks test above keeps a real
      # control precisely because TasksLive has no such sidebar loop.
      assert control_count == 1,
             "the never-joined channel measured #{control_count}; the sidebar " <>
               "channel-loop finding above may have changed"

      assert registration_count(pid, archived.id) == 0

      # ── The counts, and where each registration comes from ──────────────
      # MOVED BY TASK 01a01a1b STAGE 3: 2 -> 1. The shell's presence hold and
      # ChatLive's sidebar loop are now the SAME hold — `SpaceTopics.hold/3`
      # subscribes only when nobody on the pid already holds the topic — so a
      # joined-but-unviewed space carries one registration between the two
      # surfaces. This is the count the whole task exists to produce.
      assert other_count == 1,
             "expected 1 on a joined-but-not-viewed space (presence and the sidebar loop " <>
               "now share one SpaceTopics hold; it was 2 after stage 2 and 3 before it), " <>
               "observed #{other_count}"

      # viewed = 3: sidebar loop, + the shell's roster branch (this space
      # carries the agent), + the shell's presence branch. `handle_params`
      # DOES run an unsubscribe-then-subscribe on the active space
      # (`chat_live.ex:833-834`) whose comment claims it "guarantee[s] a
      # single active subscription here" — and at the instant it runs, it
      # does. But the shell's two subscribes arrive from Tasks AFTER
      # handle_params has completed (`shell_live.ex:971`, `:994`), so they
      # land on top of the collapsed single registration and the guarantee
      # the comment describes does not survive mount. That comment is
      # accurate about ChatLive in isolation and false about the pid.
      # MOVED BY TASK 01a01a1b STAGE 3: 3 -> 2 -> 1. Three holders now — the
      # sidebar loop's `:chat_rail`, `handle_params`'s `:chat_active` and the
      # shell's `:presence` — and ONE registration, which is
      # the invariant `PlatformWeb.SpaceTopics` was written to enforce. The
      # `handle_params` comment quoted above claimed exactly this guarantee and
      # was false about the pid; it is now true, and has been rewritten to
      # describe the mechanism that makes it true rather than the workaround
      # that briefly faked it.
      assert viewed_count == 1,
             "expected 1 on the viewed+roster+joined space: four holders, one registration " <>
               "(3 before stage 2, 2 after it), observed #{viewed_count}"

      # AMENDED BY TASK 01a01a1b STAGE 2. This used to read
      # `viewed_count > other_count`: the viewed space carried three
      # registrations against the joined-but-unviewed space's two, because the
      # viewed one collected the shell's roster branch on top of everything the
      # unviewed one already had. With roster and presence collapsed into one
      # SpaceTopics hold the two spaces are now level at 2 — viewed = sidebar
      # loop + shell hold, unviewed = sidebar loop + shell hold — so the strict
      # inequality is FALSE, and leaving it in place would assert a difference
      # the fix removed. INTERIM: `chat_live.ex` is stage 3, so the sidebar
      # loop's registration is still raw and both numbers are expected to fall
      # to 1 then. AS OF STAGE 3 they have: both are 1, and the equality now
      # says something stronger than "level" — it says the number of registrations
      # a space carries is independent of how many surfaces are interested in it.
      assert viewed_count == other_count,
             "viewed=#{viewed_count} unviewed=#{other_count}: every chat:space topic on " <>
               "this pid carries exactly one registration regardless of holder count"

      # ── DISCOVERY (method 2's actual unique value) ──────────────────────
      # Every `chat:space:` topic this pid holds, deduped to a set purely for
      # reporting. If this ever contains a space outside the fixture, that is
      # a finding about scope, not a flake.
      distinct = pid |> subscribed_space_topics() |> Enum.uniq()

      assert ChatPubSub.space_topic(viewed.id) in distinct
      assert ChatPubSub.space_topic(other.id) in distinct
      assert ChatPubSub.space_topic(control.id) in distinct
      refute ChatPubSub.space_topic(archived.id) in distinct
    end

    test "NAVIGATION: leaving a space no longer destroys registrations the leaving code never installed",
         %{conn: conn} do
      viewer = create_user!("Nav Census Viewer")
      agent = create_agent!("NavCensusBot")

      first = create_channel!("census-nav-first")
      join!(first.id, viewer, "Nav Census Viewer")
      Chat.set_principal_agent(first.id, agent.id)

      second = create_channel!("census-nav-second")
      join!(second.id, viewer, "Nav Census Viewer")

      view =
        conn
        |> init_test_session(current_user_id: viewer.id)
        |> live(~p"/chat/#{first.slug}")
        |> then(fn {:ok, view, _html} -> view end)
        |> settle()

      pid = view.pid

      before_nav = assert_methods_agree(pid, first.id)

      # MOVED BY TASK 01a01a1b STAGE 3: 3 -> 2 -> 1. The anti-vacuity role
      # this number used to play is GONE, and could not be otherwise: it
      # existed to prove there were extra registrations for the leave path to
      # destroy, and the point of the task is that there are none. What the
      # test measures has changed with it — from "leaving destroys somebody
      # else's registration" (the defect) to "leaving destroys nothing"
      # (the fix). The positive control at the end of the test is what keeps
      # the new shape non-vacuous.
      assert before_nav == 1,
             "expected 1 registration before navigating away (2 after stage 2, 3 before " <>
               "it), observed #{before_nav}"

      _ = render_patch(view, ~p"/chat/#{second.slug}")
      _ = render(view)

      after_nav = assert_methods_agree(pid, first.id)

      # ── THE FINDING THIS TEST RECORDED, AND ITS CLOSURE ────────────────
      # AS MEASURED BEFORE TASK 01a01a1b: leaving `first` ran a bare
      # `ChatPubSub.unsubscribe(prev.id)`, which is `Registry.unregister/2` and
      # therefore dropped ALL THREE registrations — including the two the SHELL
      # installed and which ChatLive had no knowledge of — then conditionally
      # re-subscribed exactly ONE, restoring the rail's registration only.
      #
      # Net effect then: after a single in-app navigation, the shell's roster
      # and presence subscriptions for the space you LEFT were silently gone
      # for the remaining life of the LiveView, because nothing re-installs
      # them — `{:roster_resolved, _}` and `{:presence_spaces_resolved, _}`
      # fire once per mount.
      #
      # STAGE 3 CLOSES IT. `handle_params/3` now releases only its own
      # `:chat_active` hold, so the registration is not destroyed at all: the
      # `:chat_rail` and `:presence` holders keep it, and the
      # conditional re-subscribe that used to paper over the damage is deleted.
      # The number below is unchanged at 1 and now means the opposite thing —
      # not "three were destroyed and one restored" but "the one there was
      # survived untouched". A count cannot distinguish those two on its own,
      # which is why the DELIVERY half is asserted in
      # test/platform_web/live/chat_live_space_topics_test.exs: it broadcasts on
      # the retained topic after the same navigation and pins that the message
      # arrives exactly once.
      assert after_nav == 1,
             "expected the retained registration to survive the navigation untouched, " <>
               "observed #{after_nav}"

      # Positive control in the same test: the space we navigated TO is
      # subscribed, so `after_nav`'s low number is not "this LV lost
      # everything" / a dead LiveView reading zero across the board.
      assert assert_methods_agree(pid, second.id) >= 1
    end

    test "MeetingState's topic is NOT a chat:space topic, so it is out of scope for this census" do
      # `shell_live.ex:1000` calls `MeetingState.subscribe(raw_user_id)`, which
      # is `Phoenix.PubSub.subscribe(@pubsub, topic(user_id))` with
      # `topic/1 == "meeting:state:<user_id>"` (`lib/platform/meetings/state.ex:83`).
      # It is keyed by USER, not by space, and carries no `chat:space:` prefix,
      # so the prefix filter in `subscribed_space_topics/1` excludes it by
      # construction. Recorded so the hypothesis list is closed rather than
      # left open: this call site is not part of the duplication.
      refute String.starts_with?(
               Platform.Meetings.State.topic("any-user-id"),
               @space_topic_prefix
             )

      # Anti-vacuity for the refute above: the prefix constant is the real one
      # and does match a real space topic, so the refute is not passing merely
      # because nothing could ever match it.
      assert String.starts_with?(ChatPubSub.space_topic("any-space-id"), @space_topic_prefix)
    end
  end
end
