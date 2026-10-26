defmodule PlatformWeb.ChatLive.MessagesHooksOwnMessageBooleanTest do
  @moduledoc """
  Regression tests for the `is_own_message` boolean in
  `PlatformWeb.ChatLive.MessagesHooks.handle_info({:new_message, msg}, socket)`.

  The expression is

      is_own_message =
        current_participant && msg.participant_id == current_participant.id

  which yields `nil` — not `false` — whenever `current_participant` is nil.
  It is then fed straight to `not/1`:

      if is_background_dm and not is_own_message do

  `not/1` accepts booleans only, so `not nil` is an `ArgumentError`/`:badarg`.

  Two mechanics shape these tests and neither is optional:

  1. `and/2` short-circuits. If `is_background_dm` is false the `not` is never
     evaluated and nothing raises — such a test would be green on both the
     fixed and the unfixed tree and would prove nothing. Both tests below
     therefore force `is_background_dm` to be TRUE (test (a) via a nil
     `active_space`, test (b) via a message whose `space_id` differs from the
     active space).

  2. `handle_info/2` here is private and installed with `attach_hook/4`, so it
     cannot be called directly. Both tests drive it through the process:
     mount `ChatLive` and `send(view.pid, {:new_message, msg})`.

  The observable is the assign that the not-own branch writes —
  `:unread_counts`, bumped by `increment_unread/2`. "Did not crash" alone
  cannot tell the not-own branch from the else branch, so test (a) asserts the
  increment happened and test (b) asserts it did not.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  describe "{:new_message, msg} with no participant in scope" do
    # (a) Negative / defect case. The viewer landed on /chat with no space
    # selected: `chat_live.ex` assigns `:current_participant` to nil at mount
    # and only `enter_space` ever fills it, so this is the real nil state, not
    # a hand-forced assign. `active_space` is nil too, which makes
    # `is_background_dm` true and therefore forces `not is_own_message` to be
    # evaluated.
    test "a message from someone else does not kill the LiveView", %{conn: conn} do
      viewer = create_user!("viewer")
      other = create_user!("other")

      # A DM, not a channel: `@channels` is the org's channel list and is not
      # scoped to the viewer's memberships, so any channel at all would send
      # `handle_params/3` off to it and there would be no no-space landing
      # state left to test. A DM is also the surface the defect was reported
      # on — a background DM arriving while nothing is open.
      space = create_space!(kind: "dm")
      {:ok, _viewer_participant} = add_participant!(space, viewer)
      {:ok, other_participant} = add_participant!(space, other)

      {:ok, msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: other_participant.id,
          content_type: "text",
          content: "a message from somebody else"
        })

      conn = init_test_session(conn, current_user_id: viewer.id)

      # /chat, NOT /chat/:space_slug — no space is entered, so
      # `active_space` and `current_participant` are both nil.
      {:ok, view, _html} = live(conn, ~p"/chat")

      # `handle_params/3` for the :index action push_navigates to the first
      # channel when the viewer has one, so a viewer with no channels is what
      # keeps the surface on the no-space landing state this test needs.
      assert assigns(view).channels == [],
             "fixture failed: a viewer with channels is redirected off /chat"

      assert assigns(view).active_space == nil,
             "fixture failed: active_space must be nil for is_background_dm to be true"

      assert assigns(view).current_participant == nil,
             "fixture failed: current_participant must be nil to reach the defect"

      before = Map.get(assigns(view).unread_counts, space.id, 0)

      send(view.pid, {:new_message, msg})

      # A synchronising round-trip: `render/1` is a call, so it cannot return
      # until the message above has been processed. Deliberately NOT wrapped in
      # a rescue — if the hook raised, the process is gone and this test must
      # fail rather than swallow the crash.
      _ = render(view)

      assert Process.alive?(view.pid),
             "the LiveView died handling {:new_message, _} with a nil current_participant"

      # Not merely "it survived": the message must have been treated as
      # not-own, which is observable only as the unread bump that
      # `increment_unread/2` writes on that branch. The else branch touches
      # `:streaming_replies` and never `:unread_counts`.
      assert Map.get(assigns(view).unread_counts, space.id, 0) == before + 1,
             "the not-own branch did not run: unread_counts was not incremented"
    end

    # (b) Positive control, same conditions except the one field under test.
    # Without this, "did not crash" in (a) is indistinguishable from "the
    # branch was never reached": this test proves that with a genuine
    # `is_own_message == true` the not-own branch is skipped, so the branch
    # selection really is being driven by that boolean.
    test "the viewer's own message in a background space takes the else branch",
         %{conn: conn} do
      viewer = create_user!("self")

      active = create_space!()
      background = create_space!()

      {:ok, _active_participant} = add_participant!(active, viewer)
      {:ok, background_participant} = add_participant!(background, viewer)

      {:ok, posted} =
        Chat.post_message(%{
          space_id: background.id,
          participant_id: background_participant.id,
          content_type: "text",
          content: "something the viewer wrote elsewhere"
        })

      conn = init_test_session(conn, current_user_id: viewer.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{active.slug}")

      current_participant = assigns(view).current_participant

      assert current_participant != nil,
             "fixture failed: entering a space must fill current_participant"

      assert assigns(view).active_space.id == active.id

      # A participant row is per-space, so the row the viewer holds in the
      # background space is a different row from the one the socket carries for
      # the active space. Only `participant_id` is restated here — on a real
      # row, at the single field the branch reads — so that
      # `msg.participant_id == current_participant.id` is genuinely true while
      # `msg.space_id != active_space.id` keeps `is_background_dm` true.
      msg = %{posted | participant_id: current_participant.id}

      assert msg.space_id != assigns(view).active_space.id,
             "fixture failed: the message must be in a background space"

      before = Map.get(assigns(view).unread_counts, background.id, 0)

      send(view.pid, {:new_message, msg})

      _ = render(view)

      assert Process.alive?(view.pid)

      assert Map.get(assigns(view).unread_counts, background.id, 0) == before,
             "the not-own branch ran for the viewer's own message: unread_counts moved"
    end
  end

  # Task 01a174f5 stage 1. The persisted main-log unread (`count_unread/3`)
  # excludes thread replies, but the live path bumped `:unread_counts` for ANY
  # background message, so the badge drifted until a reload. Control first:
  # a top-level message from someone else in the same background space bumps
  # it by exactly one, so the thread-reply assertion cannot pass on a socket
  # that never counts anything.
  describe "{:new_message, msg} unread for a background space" do
    test "a thread reply leaves :unread_counts unchanged; a top-level message bumps it by 1",
         %{conn: conn} do
      viewer = create_user!("viewer")
      second = create_user!("second")

      active = create_space!()
      background = create_space!()

      {:ok, _} = add_participant!(active, viewer)
      {:ok, _} = add_participant!(background, viewer)
      {:ok, second_participant} = add_participant!(background, second)

      {:ok, parent} =
        Chat.post_message(%{
          space_id: background.id,
          participant_id: second_participant.id,
          content_type: "text",
          content: "a parent elsewhere"
        })

      {:ok, thread} = Chat.create_thread_for_message(background.id, parent.id)

      {:ok, reply} =
        Chat.reply_to_thread(thread.id, second_participant.id, %{content: "a reply elsewhere"})

      conn = init_test_session(conn, current_user_id: viewer.id)
      {:ok, view, _html} = live(conn, ~p"/chat/#{active.slug}")

      assert assigns(view).active_space.id == active.id
      before = Map.get(assigns(view).unread_counts, background.id, 0)

      send(view.pid, {:new_message, parent})
      _ = render(view)

      assert Map.get(assigns(view).unread_counts, background.id, 0) == before + 1,
             "control failed: a top-level background message did not bump unread"

      send(view.pid, {:new_message, reply})
      _ = render(view)

      assert Map.get(assigns(view).unread_counts, background.id, 0) == before + 1,
             "a thread reply moved the main-log unread count"
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp create_user!(tag) do
    unique = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "own-msg-#{tag}-#{unique}@example.com",
      name: "Own Msg #{tag} #{unique}",
      oidc_sub: "oidc-own-msg-#{tag}-#{unique}"
    })
  end

  defp create_space!(opts \\ []) do
    unique = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "own-msg-#{unique}",
        slug: "own-msg-#{unique}",
        kind: Keyword.get(opts, :kind, "channel")
      })

    space
  end

  defp add_participant!(space, user) do
    Chat.add_participant(space.id, %{
      participant_type: "user",
      participant_id: user.id,
      display_name: user.name,
      joined_at: DateTime.utc_now()
    })
  end
end
