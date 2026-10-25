defmodule PlatformWeb.SpaceTopicsCrossSurfaceTest do
  @moduledoc """
  Task `01a01a1b` stage 5 — the `chat:space:<id>` lifecycle across MORE THAN
  ONE SURFACE in ONE process.

  ## Why the per-surface tests cannot cover this

  Stages 2, 3 and 4 each pin one surface: `ShellLive`'s roster and presence
  branches, `ChatLive`'s rail/active holds, `TasksLive`'s execution-space hold.
  None of them can see the failure that actually shipped, because it is not a
  property of any one surface.

  `PlatformWeb.ShellLive` is an `on_mount` hook on `live_session
  :authenticated` (`router.ex`), not a separate process. So the shell and
  `ChatLive` / `TasksLive` are **one pid**, and `Phoenix.PubSub` keys its
  registry by pid: one process, one registration identity. `Phoenix.PubSub`
  starts that registry with `keys: :duplicate`, `subscribe/2` is
  `Registry.register/3` (adds ONE entry) and `unsubscribe/2` is
  `Registry.unregister/2` (removes ALL of the pid's entries for the topic).
  A holder map maintained by the shell alone is therefore unsound while chat is
  a second writer: chat's `unsubscribe_space/2` teardown dropped the shell's
  registration along with its own, which is the measured collapse from 3
  registrations to 1 when navigating away from a chat space the roster also
  held.

  These tests fail loudly if any surface is ever reintroduced as an independent
  writer, because they assert on the registrations left behind AFTER one
  surface lets go while another still holds.

  ## Measurement discipline

  Every count is read DIRECTLY off `Registry.lookup(Platform.PubSub,
  ChatPubSub.space_topic(id))`, filtered to the LiveView pid. Deliberately NOT
  through a `Platform.Chat.PubSub` helper, and NOT through
  `:chat_space_holders`, `:shell_chat_space_ids` or `:subscribed_space_ids` —
  all three are written by the code under test, so reading them back to check
  it would be circular. The one place an assign is read is an ANTI-VACUITY
  precondition, never a result.

  ## A COUNT OF 1 IS NOT DELIVERY

  A registration count is a claim about the registry, not about the mailbox.
  So every retained count in this module is paired with a REAL broadcast on the
  retained topic and an observation that it arrived:

    * on `/chat`, through a roster recomputation that only a `chat:space:<id>`
      delivery could have triggered (the agent is seeded with a direct `Repo`
      insert, which fans nothing out, so the LiveView has no other way to learn
      of it);
    * on `/tasks`, through `:erlang.trace/3` on the LiveView pid, because after
      a project switch the retained space is not rendered at all.

  ## CONTROL-SPACE TRAP

  ShellLive's presence branch holds `chat:space:<id>` for EVERY space in the
  shell's chat subscribe set, and that set is `Chat.list_member_space_ids/1`:
  every non-archived space the viewer participates in, with no org fence (task
  01a01f4c). Joining the viewer to
  a "control" space would make the shell subscribe to it and DESTROY THE
  CONTROL. Every control here is a space the viewer is deliberately NOT joined
  to, and each zero is asserted in the same test body as a positive count, so
  a harness that could not see any registration at all cannot pass.

  On `/chat` there is a SECOND trap, and it was measured here rather than
  reasoned about: chat's mount loop takes a `:chat_rail` hold on every row the
  rail renders, and the rail lists every visible org channel whether or not the
  viewer joined it. An unjoined channel control therefore read **1**, not 0. A
  control on this surface must clear both traps, so it is an EXECUTION space —
  off every rail, reachable only by URL.

  ## VACUITY FENCE

  Case 1 asserts the subject is in the shell's presence input
  (`Chat.list_viewer_presence_space_ids/1`) before any count is trusted. It
  used to assert the shell's roster had resolved to it; that roster was
  deleted in task 01a1557a-8f80 stage 3.

  `async: false` — `Platform.PubSub`'s registry is VM-global.

  Fixture names are invented; `core` is a PUBLIC repo.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  describe "shell and chat in one pid" do
    # The shell's roster holder went with the utility bar's agents meter in
    # task 01a1557a-8f80; presence and the rail are the shell-and-chat
    # holders left.
    test "a space held by presence and the rail keeps exactly one registration when chat navigates away — and it still delivers",
         %{conn: conn} do
      viewer = create_user!("Hollowbrook Viewer")

      # S: joined (=> presence set, => rail).
      subject = create_channel!("hollowbrook")
      join!(subject.id, viewer)

      elsewhere = create_channel!("marram")
      join!(elsewhere.id, viewer)

      # CONTROL — see CONTROL-SPACE TRAP. On `/chat` a control has to clear
      # BOTH traps: not joined (or the shell's presence branch holds it) and
      # not on the rail (or chat's mount loop takes a `:chat_rail` hold on it).
      # An unjoined CHANNEL fails the second one — the rail lists every visible
      # org channel, joined or not, and this control read 1 as a channel. An
      # execution space is on nobody's rail and is reachable only by URL.
      control = create_execution_space!("Saltmarsh Control")

      view = mount_chat(conn, viewer, subject)
      pid = view.pid

      # ANTI-VACUITY: the shell really is a holder of S, read off the INPUT to
      # its presence branch rather than anything the holder map wrote.
      assert subject.id in Chat.list_viewer_presence_space_ids(viewer)

      # Holders on ONE pid — `:presence` (shell), `:chat_rail` + `:chat_active`
      # (chat) — and ONE registration. Stage 1 measured 3 here, with the
      # deleted roster holder.
      assert registrations(pid, subject) == 1,
             "presence and chat must SHARE one registration on a shared pid"

      render_patch(view, ~p"/chat/#{Chat.space_path_segment(elsewhere)}")
      _ = :sys.get_state(pid)

      # THE CROSS-SURFACE CASE. Chat released `:chat_active`, so that hold is
      # gone — but `:presence` and `:chat_rail` still hold S. Before this task chat's teardown was a
      # bare `Registry.unregister/2` and this read 0, silently, for the rest of
      # the session.
      assert registrations(pid, subject) == 1,
             "navigating away destroyed a registration chat does not own: presence and " <>
               "the rail still hold this space"

      assert registrations(pid, elsewhere) == 1

      # ABSENCE + PRESENCE in one body: the control is untouched, and the
      # non-zero above proves the instrument can read a registration at all.
      assert registrations(pid, control) == 0

      # A COUNT OF 1 IS NOT DELIVERY. S is a background rail row now, so a
      # message on it moves its pill only if the surviving registration
      # delivers — and moves it by exactly one.
      post_from_a_stranger(subject, "hollowbrook delivery probe")

      assert unread_pill(render(view), subject) == "1",
             "the surviving registration on S did not deliver exactly once"
    end

    test "single delivery: a rail space the shell also holds increments unread ONCE per message",
         %{conn: conn} do
      # Stage 3's single-delivery audit found two handlers that ACCUMULATED per
      # delivery and so silently double-counted whenever ShellLive held the same
      # topic as chat: `MessagesHooks.increment_unread/2` (`unread + 1`) and
      # PinHooks' `{:pin_added, _}` (`pins ++ [pin]`). Every other
      # `chat:space:<id>` handler re-reads database truth and was already
      # idempotent. This is the regression case for the first of the two: it is
      # a counter that moves once per DELIVERY, so a returning duplicate
      # registration renders "2" and reds this line. `assert_receive` could not
      # see that — it answers "at least one".
      viewer = create_user!("Tarnbeck Viewer")

      background = create_channel!("tarnbeck")
      join!(background.id, viewer)

      foreground = create_channel!("windlass")
      join!(foreground.id, viewer)

      view = mount_chat(conn, viewer, foreground)
      pid = view.pid

      # ANTI-VACUITY: the shell really is a second holder of this space, so the
      # overlap that doubled the badge exists in this fixture. Read off
      # `Chat.list_viewer_presence_space_ids/1` — the INPUT to the presence
      # branch, not anything the holder map wrote.
      assert background.id in Chat.list_viewer_presence_space_ids(viewer)

      post_from_a_stranger(background, "fixture probe message")

      # The delivery-side assertion FIRST, and deliberately so. Under the
      # `hold/3` mutation probe (subscribe unconditionally) a leading
      # registration-count assertion reds before this line is ever reached,
      # which would leave the badge claim unprobed. Ordered this way the probe
      # kills THIS assertion: two registrations render "2".
      assert unread_pill(render(view), background) == "1",
             "the unread badge counted a message more than once: the background space " <>
               "carries a second registration on this pid"

      # The registry-side diagnostic, second: it says WHY the badge is right.
      assert registrations(pid, background) == 1
    end
  end

  describe "shell and tasks in one pid" do
    test "a project switch leaves presence's registration on the execution space intact, and it still delivers",
         %{conn: conn} do
      viewer = create_user!("Fernbrook Viewer")
      project_a = create_project!()
      project_b = create_project!()
      task_a = create_task!(project_a, "Marlowe Freight Audit")
      _task_b = create_task!(project_b, "Quillon Intake Rewrite")

      {:ok, exec_space} = ExecutionSpace.find_or_create(task_a.id)
      join!(exec_space.id, viewer)

      # CONTROL — never joined and off the rail (`/tasks` does not render the
      # chat rail at all, but an execution space keeps the control valid on any
      # surface), so no holder on this pid ever takes it. It exists to prove the
      # trace can report ABSENCE.
      control = create_execution_space!("Alder Control")

      {:ok, view, _html} =
        conn
        |> init_test_session(current_user_id: viewer.id)
        |> live(~p"/tasks/#{task_a.id}")

      view = settle(view)
      pid = view.pid

      # ANTI-VACUITY, both halves separately: without the presence hold the
      # post-switch 1 would be 0 for an unrelated reason, and without the
      # `:tasks_exec` hold the switch would release nothing at all.
      assert exec_space.id in Chat.list_viewer_presence_space_ids(viewer),
             "anti-vacuity failed: the execution space is outside the viewer's presence " <>
               "set, so the shell never held it and the switch has nothing to spare"

      assert :sys.get_state(pid).socket.assigns[:subscribed_execution_space_id] ==
               exec_space.id,
             "anti-vacuity failed: TasksLive never took the execution-space hold"

      assert registrations(pid, exec_space) == 1

      # POSITIVE CONTROL for the trace: the same probe DOES land before the
      # switch, so a later observation is not measuring a dead instrument.
      assert_traced_delivery(pid, exec_space.id, "Marlowe control ping")

      _ =
        render_click(with_target(view, "#tasks-sidebar"), "sidebar_select_project", %{
          "id" => project_b.id
        })

      _ = :sys.get_state(pid)

      assert registrations(pid, exec_space) == 1,
             "the project switch destroyed a registration TasksLive does not own — " <>
               "`:presence` still holds this execution space"

      assert_traced_delivery(pid, exec_space.id, "Marlowe post-switch ping")

      assert registrations(pid, control) == 0
      refute_traced_delivery(pid, control.id, "Alder control ping")
    end
  end

  # ── Reading the registry (never the assigns) ──────────────────────────────

  # `Registry.lookup/2` on a `:duplicate` registry returns one `{pid, value}`
  # entry PER registration, so counting entries for our pid IS the count. A
  # boolean "subscribed?" could not tell one registration from two, and two is
  # the defect.
  defp registrations(pid, space) do
    Platform.PubSub
    |> Registry.lookup(ChatPubSub.space_topic(space.id))
    |> Enum.count(fn {entry_pid, _value} -> entry_pid == pid end)
  end

  # ── Delivery probes ───────────────────────────────────────────────────────

  # Proof that the registration which survived a release is LIVE, observed on
  # the SHELL's side of the shared pid.
  #
  # The agent is inserted straight through `Repo` because
  # `Chat.add_participant/2` and `Chat.set_principal_agent/2` fan out
  # `{:roster_changed_any, _}` on `Chat.global_roster_topic/0`, which this
  # LiveView is also subscribed to — a refresh triggered by THAT topic would
  # happen whether or not the `chat:space:<id>` registration survived, and the
  # assertion would pass for the wrong reason.
  # Arrival AT THE PROCESS, via the VM's receive trace. Used on `/tasks`, where
  # the retained execution space is not rendered after the switch and there is
  # no downstream observable to read.
  defp assert_traced_delivery(pid, space_id, body) do
    :erlang.trace(pid, true, [:receive])

    try do
      {:ok, _} = ExecutionSpace.post_engagement(space_id, body)
      assert_receive {:trace, ^pid, :receive, {:new_message, _}}, 1_000
    after
      :erlang.trace(pid, false, [:receive])
    end
  end

  defp refute_traced_delivery(pid, space_id, body) do
    :erlang.trace(pid, true, [:receive])

    try do
      {:ok, _} = ExecutionSpace.post_engagement(space_id, body)
      refute_receive {:trace, ^pid, :receive, {:new_message, _}}, 300
    after
      :erlang.trace(pid, false, [:receive])
    end
  end

  # The unread pill on one rail row, or nil when the row carries none. Scoped
  # to `#chat-sidebar` because the same row renders again in the mobile drawer
  # and the switcher, and an unscoped query would concatenate their texts into
  # a number that is not the badge.
  # Burrow redesign 22 stage 2 deleted the desktop channel rail: the badge is
  # now the Chat list row's unread count, scoped to `#chat-list-scroller`
  # because the search sheet and popover rows carry the same data-role.
  defp unread_pill(html, space) do
    pills =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(
        ~s(#chat-list-scroller a[data-role="chat-list-row"][data-space-id="#{space.id}"] [data-role="chat-list-unread-count"] [aria-hidden="true"])
      )

    case LazyHTML.to_tree(pills) do
      [] -> nil
      [_single] -> pills |> LazyHTML.text() |> String.trim()
      many -> flunk("expected at most one list badge for #{space.id}, found #{length(many)}")
    end
  end

  # ── Mount helpers ─────────────────────────────────────────────────────────

  # `render_async/1` waits for ShellLive's `start_async` Task, which
  # `send/2`s its resolution before returning, and the trailing round trips
  # guarantee the LiveView has processed `{:presence_spaces_resolved, _}`. Never `Process.sleep/1` — that pins the
  # box's timing rather than the code's ordering.
  defp settle(view) do
    _ = render_async(view)
    _ = render(view)
    _ = :sys.get_state(view.pid)
    view
  end

  defp mount_chat(conn, viewer, space) do
    {:ok, view, _html} =
      conn
      |> init_test_session(current_user_id: viewer.id)
      |> live(~p"/chat/#{Chat.space_path_segment(space)}")

    settle(view)
  end

  # ── Fixtures (invented names only — `core` is PUBLIC) ─────────────────────

  # The ROSTER is org-scoped by `Tenancy.scope/3`, so a user with no org
  # membership resolves an empty visibility and the roster branch no-ops. The
  # membership is plumbing that makes the code reachable. Since task 01a01f4c
  # the shell's chat subscribe set is NOT org-scoped, so it no longer depends
  # on this membership; the roster assertions here still do.
  defp create_user!(name) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "cross-surface-#{n}@example.com",
        name: name,
        oidc_sub: "oidc-cross-surface-#{n}",
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

  # A space the chat rail never lists: not a channel, not a DM, not pinned to a
  # task. Reachable only by typing its URL, so nothing on this pid holds it
  # unless a test asks for it.
  defp create_execution_space!(name) do
    {:ok, space} = Chat.create_space(%{name: name, kind: "execution"})
    space
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

  defp create_project! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Fernbrook Ledger #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:example/fernbrook.git"
      })

    project
  end

  defp create_task!(project, title) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        status: "in_progress",
        priority: "medium"
      })

    task
  end

  # A message from somebody who is not the viewer: the `{:new_message, _}`
  # handler skips the unread increment for the viewer's own participant row, so
  # a viewer-authored message would read 0 on every tree and the assertion
  # would go vacuously red.
  defp post_from_a_stranger(space, body) do
    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Fixture Author",
        joined_at: DateTime.utc_now()
      })

    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: author.id,
        content_type: "text",
        content: body
      })

    message
  end
end
