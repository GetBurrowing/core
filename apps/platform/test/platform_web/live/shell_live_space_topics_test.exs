defmodule PlatformWeb.ShellLiveSpaceTopicsTest do
  @moduledoc """
  Task 01a01a1b stage 2 — ShellLive's presence branch holds `chat:space:<id>`
  through `PlatformWeb.SpaceTopics` instead of subscribing raw.

  ## What this module pins

  Stage 1's census (`shell_live_subscription_enumeration_test.exs`) recorded
  **2** registrations on one LiveView pid for a space that was both the shell's
  agents-meter (roster) space and in the viewer's presence set. That meter and
  its roster branch were deleted in task 01a1557a-8f80 stage 3, and so were
  the cases here that drove it. What is left is the lifecycle property the
  holder map buys for the presence branch:

    * a presence set that SHRINKS releases exactly the ids that dropped out and
      RETAINS the rest (before stage 2 the presence branch was append-only:
      `Enum.each(space_ids -- already, &subscribe/1)` with no release path at
      all, so a departed space kept its live subscription for the life of the
      LiveView);
    * a presence set that GROWS adds only the new ids.

  ## Measurement discipline

  Counts are read ONLY through `Registry.lookup(Platform.PubSub, topic)`,
  filtered to the LiveView pid. They are deliberately NOT read through a
  `Platform.Chat.PubSub` helper, and NOT through the `:shell_chat_space_ids` or
  `:chat_space_holders` assigns — those assigns are written by the very code
  under test, so reading them to check that code would be circular. The topic
  string itself comes from `Platform.Chat.PubSub.space_topic/1` rather than
  being hardcoded here.

  ## A COUNT OF 1 IS NOT DELIVERY

  A registration count is a claim about the registry, not about the mailbox. A
  release that corrupted the *surviving* registration would still read as 1.
  So the shrink test posts for real on the topic that survived a release and
  asserts the message ARRIVES, observed through the shell's chat-unread
  recompute, which on `/tasks` only a `{:new_message, _}` on that topic can
  trigger.

  ## CONTROL-SPACE TRAP

  The presence branch subscribes `chat:space:<id>` for EVERY space in the
  shell's chat subscribe set, and that set is `Chat.list_member_space_ids/1`:
  every non-archived space the viewer participates in, with no org fence (task
  01a01f4c). Joining the viewer to a "control" space would make the shell
  subscribe to it and DESTROY THE CONTROL. Every control below is therefore a
  space the viewer is deliberately NOT joined to, and its assertion is a claim
  about subscription only, never about what the viewer may read.

  Tests that drive the branch directly (by sending `{:presence_spaces_resolved,
  _}`, the exact message the subscribe-set Task sends) hand it NOT-joined
  spaces where they need a space outside the resolved set.

  `async: false` — the registry is VM-global; a concurrently mounted LiveView
  in another test would add its own pid's registrations to the same topics.
  Scoping every count to our own pid makes the numbers safe regardless, but
  serial keeps the failure messages readable.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
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

  # ── Reading the registry (never the assigns) ───────────────────────────────

  defp registration_count(pid, space_id) do
    Platform.PubSub
    |> Registry.lookup(ChatPubSub.space_topic(space_id))
    |> Enum.count(fn {entry_pid, _value} -> entry_pid == pid end)
  end

  # `render_async/1` waits for the shell's `start_async` Task, which sends
  # `{:presence_spaces_resolved, _}` before returning, so the trailing
  # `render/1` round-trip guarantees the LiveView has processed it.
  # Never `Process.sleep/1` — that would pin the box's timing, not the code's
  # ordering.
  defp settle(view) do
    _ = render_async(view)
    _ = render(view)
    view
  end

  # Drive the branch with the exact message the subscribe-set Task sends, then
  # round-trip so the handler has definitely run.
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

  # The delivery proof. A message from a stranger in `space` moves the shell's
  # chat-unread total only if `{:new_message, _}` reached this pid on that
  # space's topic: on `/tasks` nothing else queues the recompute. Two
  # barriers: the first handles the message, which QUEUES the refresh; the
  # second lands after the queued refresh.
  defp assert_topic_delivers(view, space) do
    before = :sys.get_state(view.pid).socket.assigns.chat_unread_count

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Ozgur Onlooker",
        joined_at: DateTime.utc_now()
      })

    {:ok, _message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: author.id,
        content_type: "text",
        content: "delivery probe"
      })

    _ = render(view)
    _ = render(view)

    assert :sys.get_state(view.pid).socket.assigns.chat_unread_count == before + 1,
           "the surviving registration on #{ChatPubSub.space_topic(space.id)} did not " <>
             "DELIVER: a post on it produced no unread recompute. A count of 1 is a claim " <>
             "about the registry, not about the mailbox."
  end

  describe "presence set reconciliation" do
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

      # The exact message `resolve_chat_space_ids/2` sends, now carrying a SMALLER
      # set — the case the pre-stage-2 append-only branch could not express.
      drive(view, {:presence_spaces_resolved, [kept.id]})

      assert registration_count(pid, dropped.id) == 0,
             "the dropped space is still subscribed: the presence branch is still " <>
               "append-only and never releases"

      assert registration_count(pid, kept.id) == 1,
             "the retained space lost its registration — a release of one id must not " <>
               "disturb another"

      assert_topic_delivers(view, kept)
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
end
