defmodule PlatformWeb.ChatUnreadBackgroundChannelTest do
  @moduledoc """
  Task 01a01d10 stage 2. The regression pin for the user-visible symptom: a
  channel the viewer has never opened counts every message TWICE, then
  silently halves the first time they visit it.

  ## Why it halves on the first visit

  `handle_params/3`'s teardown runs `unsubscribe_space` then `subscribe_space`.
  `Phoenix.PubSub.unsubscribe/2` is `Registry.unregister/2`, which drops EVERY
  entry the pid holds for the topic, and the re-subscribe adds one back. Two
  registrations become one, so the count that had been moving by two starts
  moving by one. The number the user reads is wrong until they look at it,
  which is the worst possible shape for a badge.

  ## Two assertions, and only one of them is about the cause

  The unread count and the registration count are asserted TOGETHER on the
  same channel, and the pairing is the point.

    * `unread_pill/2` reads the number the user actually sees. On its own it
      passes against a symptom-level fix: anything that made
      `increment_unread/2` idempotent, or de-duplicated by message id, would
      green this line while every reaction, pin, canvas and presence event on
      the space carried on being handled twice.
    * `registrations/2` reads `Registry.lookup/2` DIRECTLY and counts entries
      belonging to the view's pid. That is the cause.

  The registry read deliberately does not go through a `Chat.PubSub` helper
  and deliberately does not go through `PlatformWeb.SpaceTopics`'
  `:chat_space_holders` assign. The holder ledger is part of what is under
  test here, and a test that reads its subject's own bookkeeping cannot tell a
  correct record from one that has drifted away from the registry it claims to
  describe.

  ## The four conditions this fixture has to carry, or it sees nothing

  Every pre-existing test in this area fails at least one of these, which is
  why the defect survived all of them. Each is named at its fixture below and
  asserted as an executable precondition, so a future edit that breaks one
  reds a labelled line instead of quietly making the whole file vacuous.

    1. The viewer holds an `OrgMembership` row. AMENDED by task 01a01f4c: this
       condition no longer decides whether ShellLive subscribes, and it is
       kept for a narrower reason.

       As written, the reason was that `Tenancy.visibility/1` resolves `:none`
       for zero memberships (`tenancy.ex:462`, `[] -> :none` at `:464`) and
       `scope(q, :none, _)` is `where fragment("false")` (`:510`), so a
       zero-org viewer's set came back `[]`, ShellLive subscribed NOTHING, and
       the channel took one registration whatever the code did. That held
       while ShellLive read the org-fenced query.

       ShellLive now reads `Chat.list_member_space_ids/1`
       (`shell_live.ex:1190`), which carries no org fence, so a zero-org
       viewer takes the second registration too and would reproduce this
       defect. The membership stays in the fixture because condition 2 states
       the overlap through the fenced query as well as the unfenced one, and
       because an org-affiliated viewer is the shape this file was measured
       on. Nothing here needs it to see the defect any more.
    2. The background channel carries `org_id` set to THAT SAME org, and the
       viewer holds a `participant_type: "user"` row on it.
       `Chat.list_viewer_presence_space_ids/1` (`chat.ex:532`) scopes on
       `chat_spaces.org_id`, and a NULL `org_id` is excluded because
       `NULL in ^ids` is NULL rather than false.
    3. The session mounts `/chat` on a DIFFERENT channel and never opens the
       background one. Opening it normalises the count to 1 through the
       unsubscribe-then-subscribe round trip, so the defect self-heals and a
       test that posts into the ACTIVE channel passes against every version of
       this code.
    4. The message author is NOT the viewer. `MessagesHooks` skips the
       increment for the viewer's own participant row
       (`messages_hooks.ex:1017-1019`), so a self-authored message makes every
       assertion here vacuously red.

  ## The controls

  `rail_only` is a channel on the same rail, in the same org, that the viewer
  holds NO participant row on. It is in ChatLive's rail set and NOT in
  ShellLive's presence set, so it takes exactly one registration before and
  after the fix. It does two jobs: it proves the harness can see a badge move
  at all (without it, a red on the subject is equally consistent with a test
  that cannot read pills), and it localises the defect, because on a broken
  build the asymmetry between the two channels is the finding.

  `active` is the channel the session is mounted on. Its pill must stay
  absent: `is_background_dm` is false for the active space
  (`messages_hooks.ex:1001`), so a fix that incremented everywhere would red
  it, and a fix that suppressed increments everywhere would red `rail_only`.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.{Org, OrgMembership}

  describe "a background channel the viewer has never opened" do
    test "counts one message once, and holds one registration for it", %{conn: conn} do
      %{viewer: viewer, org: org} = org_affiliated_viewer!()

      # CONDITION 3. The session lives on `active`; `background` is never
      # opened, so it never gets the unsubscribe-then-subscribe round trip
      # that would launder the count back to 1.
      active = channel!("larkspur", org)
      background = channel!("marigold", org)
      rail_only = channel!("nasturtium", org)

      # CONDITION 2, for the subject only. The participant row is what puts
      # `background` in ShellLive's presence set on top of ChatLive's rail.
      # `rail_only` deliberately does not get one.
      join!(background, viewer)

      view = mount_chat(conn, viewer, active)

      # ── Preconditions. The fixture is asserted, not assumed. ──────────────

      # CONDITION 1. Since task 01a01f4c this pins the fixture's SHAPE rather
      # than a fence the registration depends on: see the amended condition 1
      # in the moduledoc.
      assert {:orgs, _} = Tenancy.visibility(viewer),
             "the viewer resolved to :none or :root_all, so the org fence under test is " <>
               "not the thing being exercised"

      # CONDITION 2, as the overlap itself. THIS is the anti-vacuity keystone:
      # if `background` were not in ShellLive's subscribe set, ShellLive would
      # never take its second registration and the whole file would pass
      # against a broken build.
      #
      # AMENDED by task 01a01f4c. The set ShellLive actually subscribes is
      # `Chat.list_member_space_ids/1`, so that is read here and asserted
      # first. The org-fenced `Chat.list_viewer_presence_space_ids/1` is kept
      # alongside it, with its assertions unchanged: this viewer is
      # org-affiliated on a same-org channel, so the two sets coincide here,
      # and holding both pins the coincidence instead of assuming it.
      subscribe_set = Chat.list_member_space_ids(viewer.id)
      presence_set = Chat.list_viewer_presence_space_ids(viewer)

      assert background.id in subscribe_set,
             "the background channel is not in ShellLive's chat subscribe set, so this " <>
               "fixture cannot produce the double registration it exists to pin"

      refute rail_only.id in subscribe_set,
             "the control channel is in the subscribe set too, so it is a second subject " <>
               "rather than a control and the asymmetry below proves nothing"

      assert background.id in presence_set,
             "the background channel is not in ShellLive's presence set, so this fixture " <>
               "cannot produce the double registration it exists to pin"

      refute rail_only.id in presence_set,
             "the control channel is in the presence set too, so it is a second subject " <>
               "rather than a control and the asymmetry below proves nothing"

      # CONDITION 3, as an assertion.
      assert active_space_id(view) == active.id
      refute active_space_id(view) == background.id

      # Both rail rows start with no pill, so the assertions at the end
      # measure a change rather than restating the fixture.
      assert unread_pill(render(view), background) == nil
      assert unread_pill(render(view), rail_only) == nil

      # ── One message each, from somebody who is not the viewer. ────────────

      # CONDITION 4 is inside `post_from_a_stranger/2`.
      post_from_a_stranger(background, "subject fixture message")
      post_from_a_stranger(rail_only, "control fixture message")
      post_from_a_stranger(active, "active fixture message")

      html = render(view)

      # ── The control first, deliberately. ─────────────────────────────────

      assert unread_pill(html, rail_only) == "1",
             "positive control: a rail channel the viewer does not participate in did not " <>
               "increment, so the harness cannot see badges move and the subject " <>
               "assertions below prove nothing"

      assert registrations(view, rail_only) == 1,
             "the control channel is only ever reached by ChatLive's rail, so it should " <>
               "hold exactly one registration on every build"

      # ── The symptom. ─────────────────────────────────────────────────────

      assert unread_pill(html, background) == "1",
             "one message moved the badge on a never-opened channel by more than one: " <>
               "the LiveView holds two registrations on chat:space:#{background.id} and " <>
               "increment_unread/2 ran once per delivery"

      # ── The cause. The line above passes against a symptom-level fix. ────

      assert registrations(view, background) == 1,
             "the LiveView holds more than one registration for a channel that is both " <>
               "in ShellLive's presence set and on ChatLive's rail, so EVERY broadcast " <>
               "on it (reactions, pins, canvases, presence) is handled more than once"

      # ── Anti-vacuity: BOTH branches actually reached this space. ─────────

      # A count of 1 is the right answer for two different reasons, and only
      # one of them is the fix. It is also what a build produces when
      # ShellLive's presence branch never resolved at all, in which case the
      # subject channel took ChatLive's single rail registration and this file
      # would pass green over a defect it can no longer see.
      #
      # Read deliberately off the holder map and labelled as such: this is an
      # assign WRITTEN BY the code under test, so it is NOT evidence about the
      # registry. The `registrations/2` line above is. This is evidence that
      # two distinct owners arrived, which is the precondition that makes the
      # line above meaningful.
      #
      # It also catches the specific gap the ticket names as highest-risk: a
      # `hold/3` call site that DISCARDS the returned socket registers on the
      # registry without recording the holder, which reproduces the bug while
      # looking fixed. That build reds here rather than passing.
      holders = :sys.get_state(view.pid).socket

      assert PlatformWeb.SpaceTopics.held_by?(holders, background.id, :chat_rail),
             "ChatLive's rail never took a hold on the background channel, so the single " <>
               "registration counted above is not the shared one this file exists to pin"

      assert PlatformWeb.SpaceTopics.held_by?(holders, background.id, :presence),
             "ShellLive's presence branch never took a hold on the background channel, so " <>
               "the count of 1 above means the second subscriber never arrived rather " <>
               "than that the two of them shared a registration"

      # ── The channel being read does not count itself. ────────────────────

      assert unread_pill(html, active) == nil,
             "the channel the session is mounted on grew an unread pill, so increments " <>
               "are no longer gated on the space being in the background"
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  # A viewer holding a plain membership in a CHILD org of the root. A
  # membership in the root org resolves to `:root_all`, which leaves the query
  # unscoped and would make condition 1 untestable.
  defp org_affiliated_viewer! do
    org =
      Repo.insert!(
        Org.changeset(%Org{}, %{
          name: "Unread Fixture Tenant #{unique()}",
          slug: "unread_fixture_tenant_#{unique()}",
          parent_org_id: Tenancy.get_org_by_slug!("acme").id
        })
      )

    viewer =
      Repo.insert!(%User{
        email: "unread-background-#{unique()}@example.test",
        name: "Unread Fixture Viewer",
        oidc_sub: "oidc-unread-background-#{unique()}",
        avatar_url: nil
      })

    Repo.insert!(
      OrgMembership.changeset(%OrgMembership{}, %{
        user_id: viewer.id,
        org_id: org.id,
        role: "member"
      })
    )

    %{viewer: viewer, org: org}
  end

  # CONDITION 2's other half: `org_id` on the space. A channel with a NULL
  # `org_id` is dropped by `Tenancy.scope` however many memberships the viewer
  # holds, which is precisely how an existing test file in this area ends up
  # blind.
  defp channel!(slug, org) do
    {:ok, channel} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: "#{slug}-#{unique()}",
        kind: "channel",
        org_id: org.id
      })

    channel
  end

  defp join!(space, user) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  # CONDITION 4. `handle_info({:new_message, _})` skips the increment when the
  # message carries the viewer's own participant row, so the author has to be
  # somebody else or the badge never moves.
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

  defp mount_chat(conn, viewer, space) do
    {:ok, view, _html} =
      conn
      |> init_test_session(current_user_id: viewer.id)
      |> live(~p"/chat/#{Chat.space_path_segment(space)}")

    settle(view)
  end

  # `render_async/1` waits for the shell's `assign_async` loaders; each sends
  # its resolution message before returning and both travel the same mailbox
  # in order, so the trailing `render/1` round trip guarantees the LiveView
  # has processed `{:roster_resolved, _}` AND `{:presence_spaces_resolved, _}`.
  # Never `Process.sleep/1`: that pins the box's timing rather than the code's
  # ordering, and this file's whole subject is the second of those two
  # messages arriving.
  defp settle(view) do
    _ = render_async(view)
    _ = render(view)
    view
  end

  defp unique, do: System.unique_integer([:positive])

  # ── Reading the registry, never the holder assign ─────────────────────────

  # How many PubSub registrations the LiveView process holds for a space's
  # topic. `Phoenix.PubSub.subscribe/2` is `Registry.register/3` on a
  # `keys: :duplicate` registry, so this counts ENTRIES rather than answering
  # a yes/no, which is the whole point: two entries fire `handle_info` twice.
  defp registrations(view, space) do
    Platform.PubSub
    |> Registry.lookup(Platform.Chat.PubSub.space_topic(space.id))
    |> Enum.count(fn {pid, _meta} -> pid == view.pid end)
  end

  defp active_space_id(view) do
    case :sys.get_state(view.pid).socket.assigns[:active_space] do
      nil -> nil
      space -> space.id
    end
  end

  # ── Assertions ────────────────────────────────────────────────────────────

  # The unread pill on one channel's desktop rail row, or nil when the row
  # carries no pill. Scoped to `#chat-sidebar` because the same row renders
  # again in the mobile drawer and the switcher, and an unscoped query would
  # concatenate their texts into a number that is not the badge.
  defp unread_pill(html, space) do
    href = "/chat/#{Chat.space_path_segment(space)}"

    pills =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(#chat-sidebar a[href="#{href}"] .channel-row-unread-pill))

    case LazyHTML.to_tree(pills) do
      [] -> nil
      [_single] -> pills |> LazyHTML.text() |> String.trim()
      many -> flunk("expected at most one rail pill for #{href}, found #{length(many)}")
    end
  end
end
