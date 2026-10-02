defmodule PlatformWeb.ChatLiveGroupAddedAfterMountTest do
  @moduledoc """
  Task 01a01ccf: a DM or group conversation the viewer is added to AFTER their
  session mounted reaches the rail live.

  Task 01a017a3 made `:sidebar_changed` reconcile the PubSub subscribe set, but
  the handler re-read only `@channels` and `@archived_channels`. Two of the
  three arms `rail_subscribe_space_ids/1` unions were left reading a mount-time
  assign, and `@dm_conversations` is the arm a group add moves. The reported
  symptom is the pair: no rail row and no badge until a reload, so every
  message posted in between is missed with no signal at all.

  The observable is deliberately BOTH halves. `@dm_conversations` feeds
  `channel_sections/5` (the row) and `rail_subscribe_space_ids/1` (the
  subscription), and a fix that assigned it after `recompute_pinned/1` would
  paint the row while leaving the badge dead — the same silent miss, one layer
  down. `MessagesHooks.handle_info({:new_message, msg}, _)` increments
  `@unread_counts` with no membership check of its own, so the count moves if
  and only if this session holds that space's topic.

  ## Anti-vacuity notes

  Every step below was a way the sibling task's test passed against a fix that
  did not work:

    * The add happens AFTER the mount. Adding first passes against this defect,
      because the mount-time derivation already covers it.
    * The viewer mounts on a channel they already have. With nothing
      accessible `@active_space` is nil and `MessagesHooks` treats every
      arriving message as a background DM, which changes what the unread
      assertions measure.
    * `render/1` between the add and the post. `Phoenix.PubSub.broadcast`
      resolves subscribers by `Registry.lookup` in the CALLING process at
      broadcast time, and this LiveView only appears in that registry once it
      has PROCESSED `:sidebar_changed`. `render/1` is a synchronous call and
      therefore a mailbox barrier; posting without one races the registration.
    * The message author is a different participant. `increment_unread/2`
      skips a message whose participant is the viewer's own.
    * Registration COUNT, not just the badge. `Phoenix.PubSub`'s registry runs
      `keys: :duplicate`, so two registrations deliver every broadcast twice
      and still satisfy the badge assertion. Counted on the ADDED conversation
      and never on the landing space. `PlatformWeb.ShellLive.on_mount/4`
      attaches a `:roster_updates` hook INTO this LiveView's own process and
      subscribes the presence set from there, outside ChatLive's accounting, so
      a freshly mounted session already holds two registrations for whatever
      space it landed on. That is pre-existing and belongs to whoever
      reconciles ShellLive's subscriptions; the landing count is therefore
      captured and re-asserted rather than predicted.
    * `:sidebar_changed` fires twice. Nine sites emit it, so the reconcile runs
      repeatedly in a normal session and a single-shot test cannot see a double
      subscribe.
    * A negative-control group the viewer is never added to. Without it,
      "subscribe to everything" passes every other assertion here.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo

  describe "a group conversation the viewer is added to after mount" do
    test "the rail row appears, the badge moves, and exactly one registration is held",
         %{conn: conn} do
      viewer = insert_user("Vera Viewer")
      conn = authed(conn, viewer)

      # `@active_space` must be non-nil — see the moduledoc.
      landing = create_channel("larkspur") |> join!(viewer)

      # THE CASE. Created with its own roster and WITHOUT the viewer, so the
      # mount-time `@dm_conversations` cannot list it and the `:space_created`
      # broadcast is a no-op for it (`handle_info({:space_created, _space}, _)`
      # returns unchanged for every kind but "channel").
      group = create_group("Design huddle")
      insider = insert_user("Ivy Insider")
      join!(group, insider)

      # NEGATIVE CONTROL. Same shape, same kind, never added to the viewer.
      never = create_group("Escrow huddle")
      never_author = insert_user("Nadia Never")
      join!(never, never_author)

      {:ok, view, html} = live(conn, ~p"/chat/#{Chat.space_path_segment(landing)}")

      # The fixture starts where the assertions expect it to: neither
      # conversation is on the rail and neither carries a badge, so the
      # assertions at the end measure a change and not the seed state.
      refute rail_row?(html, group)
      refute rail_row?(html, never)
      assert unread_pill(html, group) == nil

      before_unread = assigns(view).unread_counts

      # Captured, never predicted. See the moduledoc's note on ShellLive.
      landing_registrations = registrations(view, landing)

      assert registrations(view, group) == 0,
             "the session already held the group's topic before the add, so nothing below " <>
               "this line is measuring the defect"

      _ = render(view)

      # THE ADD. `Chat.add_participant/2` (-> `do_add_participant/2`) is the
      # in-chat add_participant path, which emits
      # `broadcast_sidebar_changed_from(p.participant_id, self())`. The
      # excluded pid is the TEST process here, so the viewer's LiveView gets it.
      join!(group, viewer)

      # Mailbox barrier before the post. See the moduledoc.
      _ = render(view)

      post_from(group, insider, "added-after-mount-body")
      post_from(never, never_author, "never-added-body")

      _ = render(view)
      after_unread = assigns(view).unread_counts
      html = render(view)

      # ── The badge half ──────────────────────────────────────────────────
      assert Map.get(after_unread, group.id, 0) > Map.get(before_unread, group.id, 0),
             "the badge stayed dead for a group conversation this session was added to " <>
               "after it mounted: :sidebar_changed never refreshed @dm_conversations, so " <>
               "the reconcile could not see the new space"

      assert Map.get(after_unread, never.id, 0) == Map.get(before_unread, never.id, 0),
             "a group conversation this session was never added to moved its unread count, " <>
               "so the reconcile is subscribing outside the viewer's rail"

      # ── The row half ────────────────────────────────────────────────────
      assert rail_row?(html, group),
             "the group conversation never appeared in the Direct Messages section, so the " <>
               "viewer has no way to reach the messages the badge is counting"

      refute rail_row?(html, never)

      assert unread_pill(html, group) == "1",
             "the rendered pill did not move even though @unread_counts did, so the row and " <>
               "the count disagree"

      # ── The registration half ───────────────────────────────────────────
      assert registrations(view, group) == 1,
             "the session holds more than one registration for the added conversation: " <>
               "every broadcast on its topic is delivered twice"

      assert registrations(view, never) == 0

      assert registrations(view, landing) == landing_registrations,
             "the reconcile added a registration to the landing space it already held"

      # ── Idempotence ─────────────────────────────────────────────────────
      # `:sidebar_changed` fires from nine sites; the reconcile has to survive
      # being run again on an unchanged rail.
      ChatPubSub.broadcast_sidebar_changed(viewer.id)
      _ = render(view)
      ChatPubSub.broadcast_sidebar_changed(viewer.id)
      _ = render(view)

      assert registrations(view, group) == 1,
             "a repeated :sidebar_changed added a second registration for the same space"

      assert registrations(view, landing) == landing_registrations

      assert assigns(view).unread_counts == after_unread,
             "a repeated :sidebar_changed moved the unread counts on its own, which is the " <>
               "double-delivery signature"
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp unique, do: System.unique_integer([:positive])

  defp insert_user(name) do
    n = unique()

    Repo.insert!(%User{
      email: "group-after-mount-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-group-after-mount-#{n}",
      avatar_url: nil
    })
  end

  defp authed(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp create_channel(slug) do
    {:ok, channel} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: "#{slug}-#{unique()}",
        kind: "channel"
      })

    channel
  end

  # A multi-person conversation, the shape the reported defect names. `kind:
  # "group"` and `is_direct: false` are what `list_user_conversations/2`'s
  # consumer filters on, and what routes the row into the rail's "dms" section.
  defp create_group(name) do
    {:ok, space} = Chat.create_space(%{name: name, kind: "group", is_direct: false})
    space
  end

  defp join!(space, user) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    space
  end

  defp post_from(space, user, body) do
    participant =
      space.id
      |> Chat.list_participants(participant_type: "user")
      |> Enum.find(&(&1.participant_id == user.id))

    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: body
      })

    message
  end

  # ── Observables ───────────────────────────────────────────────────────────

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # How many PubSub registrations the LiveView process holds for a space's
  # topic. `Phoenix.PubSub.subscribe/2` is `Registry.register/3` on a
  # `keys: :duplicate` registry, so this counts entries rather than answering a
  # yes/no — which is the whole point: two entries fire `handle_info` twice.
  defp registrations(view, space) do
    Platform.PubSub
    |> Registry.lookup(ChatPubSub.space_topic(space.id))
    |> Enum.count(fn {pid, _meta} -> pid == view.pid end)
  end

  # The conversation's row in the desktop rail's Direct Messages section.
  # Scoped to `#chat-sidebar` and to `[data-section-key="dms"]` because the
  # same space id renders again in the mobile drawer and the switcher, and an
  # unscoped query would answer "somewhere on the page" instead of "on the
  # rail".
  defp rail_row?(html, space) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(#chat-sidebar [data-section-key="dms"] [data-space-id="#{space.id}"]))
    |> LazyHTML.to_tree()
    |> Enum.any?()
  end

  # The unread pill ON that rail row, or nil when the row carries none. Read
  # from the row itself rather than the page so a badge rendered by the mobile
  # chrome cannot stand in for the one the report is about.
  defp unread_pill(html, space) do
    pills =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(
        ~s(#chat-sidebar [data-section-key="dms"] [data-space-id="#{space.id}"] .channel-row-unread-pill)
      )

    case LazyHTML.to_tree(pills) do
      [] -> nil
      [_single] -> pills |> LazyHTML.text() |> String.trim()
      many -> flunk("expected at most one rail pill for #{space.id}, found #{length(many)}")
    end
  end
end
