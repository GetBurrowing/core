defmodule PlatformWeb.ChatLive.MessagesHooksAnchoredTest do
  @moduledoc """
  Tests for the anchored history window
  (`PlatformWeb.ChatLive.MessagesHooks.enter_space_anchored/4`).

  The default entry point loads only the newest `@message_limit` (50)
  top-level messages, so an inbox deep-link at a message older than that
  is not in the DOM at all and no amount of client-side scrolling can
  reach it. `enter_space_anchored/4` builds a window centred on the
  anchor instead.

  These are socket-level tests rather than LiveView integration tests
  because stage 1 ships the loader only — nothing routes to it yet
  (`?message=` wiring is stage 2). The bare-socket builder mirrors
  `PlatformWeb.ChatLive.MeetingHooksTest`.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo
  alias PlatformWeb.ChatLive.MessagesHooks

  # `@message_limit` in messages_hooks.ex — the default (unanchored)
  # window size. Mirrored here so the tests read as "outside the default
  # window" rather than as bare numbers.
  @message_limit 50

  # Half-window size used by `enter_space_anchored/4` on each side of the
  # anchor.
  @anchor_half 25

  # `stream/4` attaches an `:after_render` hook the first time a stream is
  # configured, so the socket needs a lifecycle in `:private` — a bare
  # `%Phoenix.LiveView.Socket{}` has only `%{live_temp: %{}}` and blows up
  # with `key :lifecycle not found`.
  defp build_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, drafts: %{}},
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end

  defp create_space do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "anchored-#{n}",
        slug: "anchored-#{n}",
        kind: "channel"
      })

    space
  end

  defp add_participant(space, label) do
    n = System.unique_integer([:positive])

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "#{label}-#{n}",
        joined_at: DateTime.utc_now()
      })

    participant
  end

  # Seed `count` top-level messages in post order. UUIDv7 ids sort
  # lexicographically by time, so the returned list is ASC by both
  # `inserted_at` and `id` — which is exactly the ordering the keyset
  # cursors in `Chat.list_messages/2` rely on.
  defp seed_messages(space, participant, count) do
    for i <- 1..count do
      {:ok, msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: participant.id,
          content_type: "text",
          content: "msg-#{String.pad_leading(Integer.to_string(i), 3, "0")}"
        })

      msg
    end
  end

  defp reload_last_read(participant) do
    Repo.get!(Participant, participant.id).last_read_message_id
  end

  # The id the naive implementation would have written — the last message
  # of the anchored window, which is older than the channel tip.
  defp naive_window_tail(messages, anchor) do
    idx = Enum.find_index(messages, &(&1.id == anchor.id))
    Enum.at(messages, idx + @anchor_half).id
  end

  describe "enter_space_anchored/4 window" do
    setup do
      space = create_space()
      participant = add_participant(space, "author")
      messages = seed_messages(space, participant, 120)

      %{space: space, participant: participant, messages: messages}
    end

    test "window straddles the anchor and is contiguous with it", ctx do
      # msg-040 sits 80 messages back from the tip — far outside the
      # newest-50 default window.
      anchor = Enum.at(ctx.messages, 39)

      socket =
        MessagesHooks.enter_space_anchored(
          build_socket(),
          ctx.space,
          ctx.participant,
          anchor.id
        )

      rendered = socket.assigns.rendered_message_ids

      # The window must be the CONTIGUOUS slice around the anchor:
      # 25 older, the anchor, 25 newer. A naive `after_id:` fetch returns
      # the newest 25 in the whole space (Chat.list_messages/2 orders
      # DESC and then limits), which would leave a hole between the
      # anchor and the "newer" half — this equality is what catches it.
      expected =
        ctx.messages
        |> Enum.slice(39 - @anchor_half, @anchor_half * 2 + 1)
        |> Enum.map(& &1.id)

      assert Enum.sort(MapSet.to_list(rendered)) == Enum.sort(expected)

      assert socket.assigns.earliest_message_id == List.first(expected)
      assert socket.assigns.latest_message_id == List.last(expected)

      # The anchor is in the window, and so are messages on BOTH sides of
      # it — "read in context" is the whole point.
      assert MapSet.member?(rendered, anchor.id)
      assert MapSet.member?(rendered, Enum.at(ctx.messages, 38).id)
      assert MapSet.member?(rendered, Enum.at(ctx.messages, 40).id)

      # ...and the live tail is NOT, which is what distinguishes an
      # anchored window from the default one.
      refute MapSet.member?(rendered, List.last(ctx.messages).id)
    end

    test "mid-history anchor sets both boundary flags", ctx do
      anchor = Enum.at(ctx.messages, 39)

      socket =
        MessagesHooks.enter_space_anchored(
          build_socket(),
          ctx.space,
          ctx.participant,
          anchor.id
        )

      # `:has_more_older` renders the top sentinel; `:newest_evicted?`
      # renders the bottom sentinel and gates `load_newer_messages/2`.
      # Both must be true or the reader is stranded in the window.
      assert socket.assigns.has_more_older
      assert socket.assigns.newest_evicted?
    end

    test "anchor at the live tip degenerates to a tail-anchored window", ctx do
      anchor = List.last(ctx.messages)

      socket =
        MessagesHooks.enter_space_anchored(
          build_socket(),
          ctx.space,
          ctx.participant,
          anchor.id
        )

      assert socket.assigns.latest_message_id == anchor.id
      refute socket.assigns.newest_evicted?
      assert socket.assigns.has_more_older
      assert MapSet.member?(socket.assigns.rendered_message_ids, anchor.id)
    end

    test "unresolvable anchor falls back to the default newest window", ctx do
      socket =
        MessagesHooks.enter_space_anchored(
          build_socket(),
          ctx.space,
          ctx.participant,
          Ecto.UUID.generate()
        )

      newest = List.last(ctx.messages)

      assert socket.assigns.latest_message_id == newest.id
      refute socket.assigns.newest_evicted?
      assert MapSet.size(socket.assigns.rendered_message_ids) == @message_limit
    end

    test "anchor from a different space is refused and falls back", ctx do
      other_space = create_space()
      other_participant = add_participant(other_space, "other")
      [foreign | _] = seed_messages(other_space, other_participant, 3)

      socket =
        MessagesHooks.enter_space_anchored(
          build_socket(),
          ctx.space,
          ctx.participant,
          foreign.id
        )

      refute MapSet.member?(socket.assigns.rendered_message_ids, foreign.id)
      assert socket.assigns.latest_message_id == List.last(ctx.messages).id
    end
  end

  describe "enter_space_anchored/4 read cursor" do
    setup do
      space = create_space()
      author = add_participant(space, "author")
      reader = add_participant(space, "reader")
      messages = seed_messages(space, author, 120)

      %{space: space, author: author, reader: reader, messages: messages}
    end

    test "anchored entry marks read at the channel tip, never backward", ctx do
      tip = List.last(ctx.messages)
      anchor = Enum.at(ctx.messages, 39)

      # Cursor starts unset.
      assert reload_last_read(ctx.reader) == nil

      # POSITIVE CONTROL: the ordinary (unanchored) entry point must
      # still ADVANCE the cursor to the channel tip. Without this
      # assertion a loader that marked nothing read at all would satisfy
      # the "never moves backward" check vacuously.
      MessagesHooks.enter_space(build_socket(), ctx.space, ctx.reader)
      assert reload_last_read(ctx.reader) == tip.id

      # THE GUARD: `Chat.mark_space_read/2` is a blind `update_all` with
      # no monotonic check, and an anchored window's last message is
      # OLDER than the tip. Reusing `List.last(window).id` here would
      # rewind the cursor and resurrect unread counts on a channel the
      # reader just visited.
      MessagesHooks.enter_space_anchored(
        build_socket(),
        ctx.space,
        ctx.reader,
        anchor.id
      )

      assert reload_last_read(ctx.reader) == tip.id
      refute reload_last_read(ctx.reader) == naive_window_tail(ctx.messages, anchor)
    end

    test "anchored entry from an unread channel advances the cursor to the tip", ctx do
      tip = List.last(ctx.messages)
      anchor = Enum.at(ctx.messages, 39)

      assert reload_last_read(ctx.reader) == nil

      MessagesHooks.enter_space_anchored(
        build_socket(),
        ctx.space,
        ctx.reader,
        anchor.id
      )

      # Anchored entry preserves today's semantics byte-for-byte:
      # entering a space marks it fully read, regardless of where in
      # history the reader landed.
      assert reload_last_read(ctx.reader) == tip.id
    end

    test "anchored entry with no participant does not touch any cursor", ctx do
      anchor = Enum.at(ctx.messages, 39)

      socket =
        MessagesHooks.enter_space_anchored(build_socket(), ctx.space, nil, anchor.id)

      assert reload_last_read(ctx.reader) == nil
      assert MapSet.member?(socket.assigns.rendered_message_ids, anchor.id)
    end
  end

  describe "resolve_anchor/1" do
    setup do
      space = create_space()
      participant = add_participant(space, "author")
      [parent | _] = seed_messages(space, participant, 1)

      %{space: space, participant: participant, parent: parent}
    end

    test "a top-level message anchors the main window", ctx do
      assert MessagesHooks.resolve_anchor(ctx.parent) == {:top_level, ctx.parent.id}
    end

    test "a thread reply routes to its thread instead", ctx do
      {:ok, thread} = Chat.create_thread_for_message(ctx.space.id, ctx.parent.id)

      {:ok, reply} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.participant.id,
          content_type: "text",
          content: "in-thread mention",
          thread_id: thread.id
        })

      # The anchored window is `top_level_only: true`, so a mention
      # posted as a thread reply can NEVER appear in it. Callers must
      # take the thread branch instead of building a window that cannot
      # contain the target.
      assert MessagesHooks.resolve_anchor(reply) == {:thread, thread.id}
    end

    test "nil resolves to no anchor" do
      assert MessagesHooks.resolve_anchor(nil) == :none
    end
  end
end
