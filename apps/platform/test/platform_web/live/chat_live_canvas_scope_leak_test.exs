defmodule PlatformWeb.ChatLiveCanvasScopeLeakTest do
  @moduledoc """
  Task 019ffca8 stage 5 — the CanvasHooks space guard, and the one clause that
  does not have it.

  ## The vector

  `ChatLive.mount/3` subscribes the session to the space topic of EVERY space on
  its rail, not just the active one, so background unread counts stay live
  (`chat_live.ex` "Subscribe to chat pubsub for unread counts in background
  conversations"). An internal rail carries every channel in the install, joined
  or not. So a canvas write in ANY space reaches EVERY connected session's
  `CanvasHooks.handle_info/2`, and the only thing keeping space B's canvas out of
  space A's canvas panel is the `MessagesHooks.same_active_space?/2` check inside
  each clause.

  Two clauses have it. `:canvas_restored` does not
  (`canvas_hooks.ex:538` — a bare `put/2`), and `Chat.restore_canvas/1`
  broadcasts `{:canvas_restored, canvas}` on the space topic from the Activity
  panel's Restore action.

  ## What is asserted, and why not on the HTML

  Hook state, both halves of it: `@canvases_by_id` AND `@canvases`. Never
  rendered HTML. Two reasons, both learned the hard way:

    * On task 019ffe65 a render assertion collapsed the MessagesHooks guard and
      the CanvasHooks guard into one observable, so whichever half was intact
      hid the other. Asserting on the assign each hook owns keeps them separate.

    * Stage 3 of this task found that the Live Canvases panel is a SECOND render
      observable for `@canvases` which the message stream does not gate:
      `canvas_hooks.ex` `put/2` appends to `@canvases`, and
      `chat_live.html.heex:3271-3292` renders that list as a panel row showing
      `canvas.title` with no message row involved. A test that only checked
      `@canvases_by_id` would miss a regression that populated the list.

  ## The escalation, for context

  `put/2` also calls `ChatPubSub.subscribe_canvas(canvas.id)`. So a canvas that
  lands through the unguarded clause does not just appear once: the session
  becomes a live subscriber to that canvas's own topic and keeps receiving its
  `:canvas_patched` and `:canvas_event` traffic afterwards.

  It compounds, too. The comment above that call (`canvas_hooks.ex:81-83`) says
  "Phoenix.PubSub dedups within a single pid, so re-subscribing on an
  already-known canvas is a no-op". That is wrong: the registry is
  `keys: :duplicate` and `subscribe/3` is a bare `Registry.register`, which
  `chat_live.ex:725-732` states correctly and works around with an explicit
  unsubscribe. So each `put/2` for the same canvas adds another registration and
  multiplies the delivery rate rather than being idempotent. Not fixed here —
  that comment is one of the findings already ticketed as
  `01a011e9-7811-74b7-9803-15200558f22a`.

  ## The skipped test

  `:canvas_restored` is knowingly unguarded and the test for it is EXPECTED to
  fail against `origin/main`. It is tagged `:skip` rather than softened or
  deleted, and the fix belongs to task `01a011a8-0038-76c5-8880-f41fa3dafaa8`.
  The two guarded siblings run green in the same file, which is what proves the
  test shape works and that the skip is about the code rather than the test.

  `async: false` — the file drives connected LiveViews and reads their process
  state, and shares the PubSub bus with every other test in the run.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp unique, do: System.unique_integer([:positive])

  defp create_user!(name) do
    n = unique()

    %User{}
    |> User.changeset(%{
      email: "canvas-scope-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-canvas-scope-#{n}"
    })
    |> Repo.insert!()
  end

  defp channel!(name) do
    {:ok, ch} =
      Chat.create_space(%{name: name, slug: "canvas-scope-#{unique()}", kind: "channel"})

    ch
  end

  defp join!(channel, user) do
    {:ok, _} =
      Chat.add_participant(channel.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    channel
  end

  defp participant_for(space, user) do
    space.id
    |> Chat.list_participants(participant_type: "user")
    |> Enum.find(&(&1.participant_id == user.id))
  end

  defp canvas!(space, participant, title) do
    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => title,
        "created_by_display_name" => "Ingrid Internal",
        "created_by_participant_type" => "user",
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{"id" => "root", "type" => "stack", "children" => []}
        }
      })

    canvas
  end

  defp authed(conn, user), do: init_test_session(conn, current_user_id: user.id)

  # ── Observables ────────────────────────────────────────────────────────────

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp held_canvas_ids(view), do: assigns(view).canvases_by_id |> Map.keys() |> MapSet.new()

  defp listed_canvas_ids(view), do: assigns(view).canvases |> MapSet.new(& &1.id)

  # Asserts against BOTH halves of the hook's state. `@canvases_by_id` is what
  # `chat_message.ex` reads for the inline card; `@canvases` is what the Live
  # Canvases panel enumerates. Either one alone is a partial observable.
  defp refute_held(view, canvas, context) do
    refute MapSet.member?(held_canvas_ids(view), canvas.id),
           "#{context} — the canvas entered @canvases_by_id"

    refute MapSet.member?(listed_canvas_ids(view), canvas.id),
           "#{context} — the canvas entered @canvases, which the Live Canvases panel renders"
  end

  defp assert_held(view, canvas, context) do
    assert MapSet.member?(held_canvas_ids(view), canvas.id),
           "#{context} — nothing entered @canvases_by_id"

    assert MapSet.member?(listed_canvas_ids(view), canvas.id),
           "#{context} — nothing entered @canvases"
  end

  # ── Shared setup ───────────────────────────────────────────────────────────

  setup %{conn: conn} do
    user = create_user!("Ingrid Internal")

    active = channel!("Active Channel") |> join!(user)
    background = channel!("Background Channel") |> join!(user)

    {:ok, view, _html} = conn |> authed(user) |> live("/chat/#{active.slug}")

    %{
      view: view,
      user: user,
      active: active,
      background: background,
      active_participant: participant_for(active, user),
      background_participant: participant_for(background, user)
    }
  end

  # THE FOUNDATION POSITIVE CONTROL. Called at the TOP OF EVERY TEST below, not
  # once for the file, and that distinction is load-bearing.
  #
  # Each test also carries an in-test control on the ACTIVE space's canvas, and
  # that control cannot stand in for this one. `chat_live.ex:725-732`
  # re-subscribes the active space inside `handle_params/3`
  # (unsubscribe-then-subscribe, because PubSub does not dedupe per pid),
  # INDEPENDENTLY of the mount-time loop over rail spaces at
  # `chat_live.ex:540-542`. So the active-space control stays green even on a
  # build where the rail loop was deleted outright — and in that build the
  # background topic delivers nothing, every `refute_held/3` passes, and the
  # file proves nothing while looking green.
  #
  # This asserts the one property those refutes actually rest on: a broadcast on
  # the BACKGROUND space's topic reaches this session.
  defp assert_background_topic_live(ctx) do
    other_user = create_user!("Owen Other")
    join!(ctx.background, other_user)
    other_participant = participant_for(ctx.background, other_user)

    before_unread = Map.get(assigns(ctx.view).unread_counts, ctx.background.id, 0)

    {:ok, _message} =
      Chat.post_message(%{
        space_id: ctx.background.id,
        participant_id: other_participant.id,
        content_type: "text",
        content: "background-space-traffic-#{unique()}"
      })

    _ = render(ctx.view)

    after_unread = Map.get(assigns(ctx.view).unread_counts, ctx.background.id, 0)

    assert after_unread > before_unread, """
    The mounted session did not react to a message broadcast on the BACKGROUND
    space's topic (unread count #{before_unread} -> #{after_unread}).

    Either the mount-time subscribe loop over rail spaces changed, or unread
    counts moved off the space topic. Until that is resolved every
    `refute_held/3` in this test is passing because nothing arrives, not because
    the canvas guard rejected it.
    """

    :ok
  end

  # The same assertion as its own test, so a build that breaks the rail
  # subscription reports it once as its own named failure rather than only as
  # three confusing canvas failures.
  describe "the background-space subscription that the rest of this file rests on" do
    test "a message posted in the background space moves that session's unread count", ctx do
      other_user = create_user!("Owen Other")
      join!(ctx.background, other_user)
      other_participant = participant_for(ctx.background, other_user)

      before_unread = Map.get(assigns(ctx.view).unread_counts, ctx.background.id, 0)

      {:ok, _message} =
        Chat.post_message(%{
          space_id: ctx.background.id,
          participant_id: other_participant.id,
          content_type: "text",
          content: "background-space-traffic-#{unique()}"
        })

      _ = render(ctx.view)

      after_unread = Map.get(assigns(ctx.view).unread_counts, ctx.background.id, 0)

      assert after_unread > before_unread, """
      The mounted session did not react to a message broadcast on the BACKGROUND
      space's topic (unread count #{before_unread} -> #{after_unread}).

      Either the mount-time subscribe loop over rail spaces changed, or unread
      counts moved off the space topic. Until that is resolved every
      `refute_held/3` in this file is passing because nothing arrives, not
      because the canvas guard rejected it.
      """
    end
  end

  # ── The two guarded clauses ────────────────────────────────────────────────

  describe "{:canvas_created, canvas}" do
    test "a canvas created in a background space stays out of the active space's hook state",
         ctx do
      # FOUNDATION CONTROL: this session is on the BACKGROUND space's topic.
      # The active-space control below cannot substitute for it — see the
      # comment on `assert_background_topic_live/1`.
      assert_background_topic_live(ctx)

      # POSITIVE CONTROL: the SAME clause, same broadcast, canvas in the ACTIVE
      # space. It must land in both assigns, or the refute below proves only
      # that the handler is broken.
      own = canvas!(ctx.active, ctx.active_participant, "Active Brief #{unique()}")
      _ = render(ctx.view)

      assert_held(
        ctx.view,
        own,
        "{:canvas_created, _} for the ACTIVE space did nothing, so the refute that follows " <>
          "would be passing for the wrong reason"
      )

      # THE LEAK ASSERTION. `Chat.create_canvas/1` broadcasts on the background
      # space's topic, which this session is subscribed to, so the event does
      # reach `CanvasHooks.handle_info/2`. `same_active_space?/2` is what stops
      # it there.
      foreign =
        canvas!(ctx.background, ctx.background_participant, "Background Brief #{unique()}")

      _ = render(ctx.view)

      refute_held(
        ctx.view,
        foreign,
        "a canvas created in a background space entered the active space's canvas state"
      )

      # And the active space's own canvas is still held, so the refute above is
      # not the side effect of the hook having dropped everything.
      assert_held(ctx.view, own, "the active space's own canvas was lost")
    end
  end

  describe "{:canvas_updated, canvas}" do
    test "an update to a background space's canvas stays out of the active space's hook state",
         ctx do
      # FOUNDATION CONTROL, per test. See `assert_background_topic_live/1`.
      assert_background_topic_live(ctx)

      own = canvas!(ctx.active, ctx.active_participant, "Active Brief #{unique()}")

      foreign =
        canvas!(ctx.background, ctx.background_participant, "Background Brief #{unique()}")

      _ = render(ctx.view)

      # The foreign canvas is out after `:canvas_created`, which is the previous
      # test's subject. Restate it as the starting condition rather than
      # assuming it, so a regression there cannot make this test's refute pass
      # by accident.
      assert_held(ctx.view, own, "setup: the active space's canvas never loaded")

      refute_held(
        ctx.view,
        foreign,
        "setup: the background canvas was already held before any update fired"
      )

      # `publish_canvas_updated/1` is the seam every update path funnels
      # through, including `Canvas.Server.do_persist/5`, which is why it is
      # public. Using it directly keeps this test on the topic contract instead
      # of on `update_canvas/2`'s authorization.
      renamed_own = %{own | title: "Active Renamed #{unique()}"}
      Chat.publish_canvas_updated(renamed_own)
      _ = render(ctx.view)

      # POSITIVE CONTROL: the active space's update was applied, title and all.
      assert_held(ctx.view, renamed_own, "{:canvas_updated, _} for the ACTIVE space did nothing")

      assert assigns(ctx.view).canvases_by_id[own.id].title == renamed_own.title,
             "the active space's canvas was not actually updated, only present, so the refute " <>
               "below would be passing for the wrong reason"

      # THE LEAK ASSERTION.
      renamed_foreign = %{foreign | title: "Background Renamed #{unique()}"}
      Chat.publish_canvas_updated(renamed_foreign)
      _ = render(ctx.view)

      refute_held(
        ctx.view,
        renamed_foreign,
        "an update to a background space's canvas entered the active space's canvas state"
      )
    end
  end

  # ── The clause with no guard ───────────────────────────────────────────────

  describe "{:canvas_restored, canvas}" do
    # EXPECTED TO FAIL against origin/main, and skipped rather than softened.
    #
    # `canvas_hooks.ex:538` is `defp handle_info({:canvas_restored, canvas},
    # socket), do: {:halt, put(socket, canvas)}` — the same unguarded `put/2`
    # vector as `:canvas_created` had, with no `same_active_space?/2` check, and
    # `Chat.restore_canvas/1` broadcasts `{:canvas_restored, c}` on the space
    # topic (`chat.ex:4689`) from the Activity panel's Restore action.
    #
    # The fix is owned by task 01a011a8-0038-76c5-8880-f41fa3dafaa8. Stage 5 of
    # 019ffca8 writes tests and does not add guards, so this stays red and
    # skipped; whoever lands 01a011a8 removes the tag and this test becomes the
    # regression net. The two guarded siblings above run green in this same
    # file, which is what shows the shape is sound and the skip is about the
    # code rather than the test.
    @tag :skip
    test "a restore in a background space stays out of the active space's hook state", ctx do
      # FOUNDATION CONTROL, per test. See `assert_background_topic_live/1`.
      assert_background_topic_live(ctx)

      own = canvas!(ctx.active, ctx.active_participant, "Active Brief #{unique()}")

      foreign =
        canvas!(ctx.background, ctx.background_participant, "Background Brief #{unique()}")

      _ = render(ctx.view)

      {:ok, deleted_foreign} = Chat.delete_canvas(foreign)
      {:ok, deleted_own} = Chat.delete_canvas(own)
      _ = render(ctx.view)

      # POSITIVE CONTROL: restoring the ACTIVE space's canvas puts it back.
      {:ok, restored_own} = Chat.restore_canvas(deleted_own)
      _ = render(ctx.view)

      assert_held(
        ctx.view,
        restored_own,
        "{:canvas_restored, _} for the ACTIVE space did nothing, so the refute that follows " <>
          "would be passing for the wrong reason"
      )

      # THE LEAK ASSERTION — currently FAILS, deliberately unfixed here.
      {:ok, restored_foreign} = Chat.restore_canvas(deleted_foreign)
      _ = render(ctx.view)

      refute_held(
        ctx.view,
        restored_foreign,
        "a canvas restored in a background space entered the active space's canvas state " <>
          "(the unguarded put/2 at canvas_hooks.ex:538 — task 01a011a8)"
      )
    end
  end
end
