defmodule PlatformWeb.ChatLiveMessageAnchorTest do
  @moduledoc """
  Coverage for the `?message=<id>` deep link in `ChatLive.handle_params/3`
  (task 019fabe8 stage 2).

  `Platform.Chat` has always written the message id into the inbox url
  (`/chat/<slug>?message=<id>`) and `InboxLive` push_navigates to it
  verbatim — but `handle_params/3` destructured only `"space_slug"` and
  dropped the identity on the floor, so a mention click landed at the
  channel's default position with no indication of which message was
  meant. Stage 1 shipped the anchored loader; this wires the URL to it.

  Every case here pairs its negative with a positive control in the same
  run, because most of the failure modes ("nothing happened") are
  indistinguishable from "the mechanism is not installed":

    * the anchored-window case first records a BASELINE plain entry, and
      asserts the anchored entry contains a message the baseline does not
      and omits one the baseline has;
    * the deleted-anchor case clicks an intact sibling immediately after
      and asserts it still anchors;
    * the cross-space case asserts the reader still lands in the right
      channel with its own newest window;
    * the highlight-expiry case asserts the ring is present BEFORE the
      timer lapses, so a build that never highlighted at all would fail
      the same test.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  # `@message_limit` in messages_hooks.ex — the default (unanchored)
  # window size. An anchor older than this is not in the DOM at all
  # without stage 1's anchored loader.
  @message_limit 50

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "anchor_#{n}@example.com",
        name: "Anchor Tester",
        oidc_sub: "oidc-anchor-#{n}",
        avatar_url: nil
      })

    space = create_channel("anchor-#{n}")
    author = add_participant(space, "author")

    {:ok, conn: init_test_session(conn, current_user_id: user.id), space: space, author: author}
  end

  defp create_channel(slug) do
    {:ok, space} =
      Chat.create_space(%{name: String.capitalize(slug), slug: slug, kind: "channel"})

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
  # `inserted_at` and `id`.
  defp seed_messages(space, participant, count, prefix \\ "msg") do
    for i <- 1..count do
      {:ok, msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: participant.id,
          content_type: "text",
          content: "#{prefix}-#{String.pad_leading(Integer.to_string(i), 3, "0")}"
        })

      msg
    end
  end

  defp soft_delete(msg) do
    msg
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp row_html(view, message_id) do
    view |> element(~s([data-message-id="#{message_id}"])) |> render()
  end

  # Message ids in the order the message list actually renders them.
  # `Phoenix.LiveViewTest` applies stream operations to its DOM, so this
  # reflects the client's resulting order — including any row a
  # same-diff `stream_insert` moved to the end.
  defp rendered_message_order(html) do
    ~r/data-message-id="([0-9a-f-]{36})"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.uniq()
  end

  defp anchor_assign(view) do
    :sys.get_state(view.pid).socket.assigns.anchor_message_id
  end

  defp highlight_assign(view) do
    :sys.get_state(view.pid).socket.assigns.highlighted_message_id
  end

  describe "?message= anchoring a top-level message" do
    test "loads a window around a target older than the default window", %{
      conn: conn,
      space: space,
      author: author
    } do
      msgs = seed_messages(space, author, @message_limit + 60)
      anchor = Enum.at(msgs, 4)
      newest = List.last(msgs)

      # BASELINE (positive control for the assertions below): a plain
      # entry loads the newest window, which contains `newest` and does
      # NOT contain `anchor`.
      {:ok, plain, _html} = live(conn, "/chat/#{space.slug}")
      plain_html = render(plain)
      assert plain_html =~ newest.content
      refute plain_html =~ anchor.content
      refute_push_event(plain, "chat:scroll-to-message", %{})
      assert anchor_assign(plain) == nil

      {:ok, view, _html} = live(conn, "/chat/#{space.slug}?message=#{anchor.id}")

      anchor_id = anchor.id
      assert_push_event(view, "chat:scroll-to-message", %{id: ^anchor_id})

      html = render(view)
      # The anchored window rendered instead of the default one: the
      # target is present and the channel tip — present in the baseline —
      # is not.
      assert html =~ anchor.content
      refute html =~ newest.content

      assert anchor_assign(view) == anchor.id
      assert highlight_assign(view) == anchor.id
      assert row_html(view, anchor.id) =~ "ring-primary/20"
    end

    test "anchors a target that is inside the default window too", %{
      conn: conn,
      space: space,
      author: author
    } do
      msgs = seed_messages(space, author, 10)
      anchor = Enum.at(msgs, 3)

      {:ok, view, _html} = live(conn, "/chat/#{space.slug}?message=#{anchor.id}")

      anchor_id = anchor.id
      assert_push_event(view, "chat:scroll-to-message", %{id: ^anchor_id})
      assert anchor_assign(view) == anchor.id
      assert row_html(view, anchor.id) =~ "ring-primary/20"

      # Positive control that the ring is target-scoped, not blanket:
      # a sibling row in the same window carries no highlight.
      sibling = Enum.at(msgs, 5)
      refute row_html(view, sibling.id) =~ "ring-primary/20"
    end

    # Found in the browser while capturing stage 3's evidence: the
    # anchored message rendered at the BOTTOM of its window rather than
    # between its neighbours, so "read the message in context" showed
    # the wrong context entirely.
    #
    # Cause: `enter_space_window/4` streams the window with
    # `reset: true`, and `mark_arrival/2` then applied the ring via
    # `SearchHooks.set_highlights/2`, whose `reinsert_for_highlight_change`
    # issues a `stream_insert` at the default `at: -1`. Both land in the
    # SAME diff, so the client applies the reset and then re-appends the
    # anchor row to the end of the container. (A LATER standalone
    # reinsert — the 6s clear — updates in place and does not move
    # anything; only the same-diff pairing is broken.)
    test "the anchored row keeps its chronological position in the window", %{
      conn: conn,
      space: space,
      author: author
    } do
      msgs = seed_messages(space, author, 20)
      anchor = Enum.at(msgs, 9)

      {:ok, view, _html} = live(conn, "/chat/#{space.slug}?message=#{anchor.id}")

      rendered_order = rendered_message_order(render(view))
      expected_order = Enum.map(msgs, & &1.id)

      assert rendered_order == expected_order,
             """
             The anchored window rendered out of chronological order.
             The reader is meant to read the target IN CONTEXT; a row
             displaced to the end of the container is surrounded by
             messages that are not its neighbours.

             anchor at index #{Enum.find_index(rendered_order, &(&1 == anchor.id))}, \
             expected #{Enum.find_index(expected_order, &(&1 == anchor.id))}
             """

      # Positive controls in the same run, so a build that rendered no
      # window at all (or dropped the highlight) fails here too.
      assert highlight_assign(view) == anchor.id
      assert row_html(view, anchor.id) =~ "ring-primary/20"
    end
  end

  describe "unresolvable ?message= targets" do
    test "a soft-deleted target flashes and falls back to the default window", %{
      conn: conn,
      space: space,
      author: author
    } do
      msgs = seed_messages(space, author, @message_limit + 60)
      deleted = Enum.at(msgs, 4)
      intact = Enum.at(msgs, 6)
      newest = List.last(msgs)

      soft_delete(deleted)

      {:ok, view, _html} = live(conn, "/chat/#{space.slug}?message=#{deleted.id}")

      html = render(view)
      assert html =~ "That message is no longer available."
      refute html =~ deleted.content
      # Landed in the right channel at its normal position.
      assert html =~ newest.content
      assert anchor_assign(view) == nil
      refute_push_event(view, "chat:scroll-to-message", %{})

      # POSITIVE CONTROL: the anchoring path is live in this run — an
      # intact sibling in the same channel still anchors.
      {:ok, ok_view, _html} = live(conn, "/chat/#{space.slug}?message=#{intact.id}")
      intact_id = intact.id
      assert_push_event(ok_view, "chat:scroll-to-message", %{id: ^intact_id})
      assert anchor_assign(ok_view) == intact.id
    end

    test "a target in another space is refused and leaks nothing", %{
      conn: conn,
      space: space,
      author: author
    } do
      _mine = seed_messages(space, author, 5, "mine")

      other = create_channel("other-#{System.unique_integer([:positive])}")
      other_author = add_participant(other, "other-author")
      [foreign | _] = seed_messages(other, other_author, 3, "foreign")

      {:ok, view, _html} = live(conn, "/chat/#{space.slug}?message=#{foreign.id}")

      html = render(view)
      assert html =~ "That message is no longer available."
      refute html =~ foreign.content
      assert html =~ "mine-005"
      assert anchor_assign(view) == nil
      refute_push_event(view, "chat:scroll-to-message", %{})
    end

    test "an unknown or malformed id is refused", %{conn: conn, space: space, author: author} do
      _msgs = seed_messages(space, author, 5)

      for bad <- [Ecto.UUID.generate(), "not-a-uuid"] do
        {:ok, view, _html} = live(conn, "/chat/#{space.slug}?message=#{bad}")

        assert render(view) =~ "That message is no longer available."
        assert anchor_assign(view) == nil
        refute_push_event(view, "chat:scroll-to-message", %{})
      end
    end

    test "no ?message= at all neither flashes nor anchors", %{
      conn: conn,
      space: space,
      author: author
    } do
      _msgs = seed_messages(space, author, 5)

      {:ok, view, _html} = live(conn, "/chat/#{space.slug}")

      refute render(view) =~ "That message is no longer available."
      assert anchor_assign(view) == nil
      assert highlight_assign(view) == nil
    end
  end

  describe "?message= pointing at a thread reply" do
    test "expands the parent's inline thread and highlights the parent", %{
      conn: conn,
      space: space,
      author: author
    } do
      msgs = seed_messages(space, author, 5)
      parent = Enum.at(msgs, 2)

      {:ok, thread} = Chat.create_thread(space.id, %{parent_message_id: parent.id})

      {:ok, reply} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          thread_id: thread.id,
          content_type: "text",
          content: "thread-reply-body"
        })

      # BASELINE: the reply is not rendered on a plain entry — the main
      # window is top_level_only and the thread is collapsed.
      {:ok, plain, _html} = live(conn, "/chat/#{space.slug}")
      refute render(plain) =~ "thread-reply-body"

      {:ok, view, _html} = live(conn, "/chat/#{space.slug}?message=#{reply.id}")

      html = render(view)
      assert html =~ "thread-reply-body"
      # The highlight and the scroll target are the PARENT, mirroring
      # `search_open_result` — the reply has no row of its own in the
      # main list.
      assert highlight_assign(view) == parent.id
      assert anchor_assign(view) == parent.id
      parent_id = parent.id
      assert_push_event(view, "chat:scroll-to-message", %{id: ^parent_id})
    end
  end

  describe "arrival highlight lifetime" do
    test "the scheduled clear removes the ring", %{conn: conn, space: space, author: author} do
      prev = Application.get_env(:platform, :anchor_highlight_ms)
      Application.put_env(:platform, :anchor_highlight_ms, 60)
      on_exit(fn -> restore_env(prev) end)

      msgs = seed_messages(space, author, 10)
      anchor = Enum.at(msgs, 3)

      {:ok, view, _html} = live(conn, "/chat/#{space.slug}?message=#{anchor.id}")

      # POSITIVE CONTROL: the ring is there before the timer lapses.
      assert highlight_assign(view) == anchor.id

      assert eventually(fn -> is_nil(highlight_assign(view)) end)
      refute row_html(view, anchor.id) =~ "ring-primary/20"
      # The anchor assign itself survives — the scroll hook (stage 3)
      # keys its once-per-id guard off it.
      assert anchor_assign(view) == anchor.id
    end

    test "a stale clear does not steal a newer highlight", %{
      conn: conn,
      space: space,
      author: author
    } do
      msgs = seed_messages(space, author, 10)
      anchor = Enum.at(msgs, 3)
      other = Enum.at(msgs, 7)

      {:ok, view, _html} = live(conn, "/chat/#{space.slug}?message=#{anchor.id}")
      assert highlight_assign(view) == anchor.id

      # A search jump lands on a different message before the anchor
      # timer fires.
      render_hook(view, "search_open_result", %{"message-id" => other.id})
      assert highlight_assign(view) == other.id

      # The anchor's timer now fires late.
      send(view.pid, {:clear_anchor_highlight, anchor.id})
      _ = render(view)

      assert highlight_assign(view) == other.id
      assert row_html(view, other.id) =~ "ring-primary/20"
    end
  end

  describe "unread semantics on an anchored entry" do
    test "landing mid-history still marks read at the channel tip", %{
      conn: conn,
      space: space,
      author: author
    } do
      msgs = seed_messages(space, author, @message_limit + 60)
      anchor = Enum.at(msgs, 4)
      newest = List.last(msgs)

      {:ok, view, _html} = live(conn, "/chat/#{space.slug}?message=#{anchor.id}")

      participant = :sys.get_state(view.pid).socket.assigns.current_participant
      reloaded = Repo.get!(Chat.Participant, participant.id)

      assert reloaded.last_read_message_id == newest.id
      refute reloaded.last_read_message_id == List.last(rendered_ids(view))
    end
  end

  # ── Deep links resolve for every space kind (stage 4) ─────────────────
  #
  # Stage 2 wired the param; it could only ever fire for a url that
  # RESOLVES. The producer built the url from `space.slug`, and DM/group
  # spaces have none — so a DM mention emitted "/chat/?message=<uuid>",
  # missed `/chat/:space_slug` entirely, hit the catch-all clause and
  # pushed the reader to their FIRST CHANNEL. Not the right conversation
  # at the wrong position: the wrong conversation.

  describe "deep link addressing" do
    test "a DM mention url lands IN the DM, anchored on the message", %{conn: conn} do
      {:ok, dm} = Chat.create_space(%{kind: "dm", is_direct: true, name: nil})
      assert is_nil(dm.slug), "the shape create_dm_space/3 produces"

      peer = add_participant(dm, "peer")
      msgs = seed_messages(dm, peer, @message_limit + 20, "dm")
      anchor = Enum.at(msgs, 3)

      # The url the inbox producer now writes, built the same way.
      url = "/chat/#{Chat.space_path_segment(dm)}?message=#{anchor.id}"
      refute url =~ "/chat/?", "the pre-fix url shape must be unreachable"

      {:ok, view, _html} = live(conn, url)

      # In the DM itself — not redirected anywhere.
      assert :sys.get_state(view.pid).socket.assigns.active_space.id == dm.id

      # And anchored: the target is rendered even though it sits well
      # outside the default newest-50 window, and the newest message is
      # NOT, which is only true of the anchored window.
      ids = rendered_ids(view)
      assert anchor.id in ids
      refute List.last(msgs).id in ids
    end

    test "the pre-fix url shape would NOT have resolved to the DM", %{conn: conn} do
      # The control for the case above: prove the old url was actually
      # broken rather than merely ugly. `/chat/?message=…` has no space
      # segment, so it is the paramless route and the reader is bounced
      # to their first channel.
      {:ok, dm} = Chat.create_space(%{kind: "dm", is_direct: true, name: nil})
      peer = add_participant(dm, "peer")
      [msg | _] = seed_messages(dm, peer, 1, "dm")

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/chat/?message=#{msg.id}")
      refute to =~ dm.id
    end

    test "a deep link never auto-creates a channel", %{conn: conn} do
      before = Repo.aggregate(Chat.Space, :count, :id)

      # A channel-shaped slug that does not exist. Without the guard this
      # is exactly the string `bootstrap_space/2` happily mints a channel
      # from — and stage 3 hit it for real: an org-less space's slug url,
      # opened by a reader whose active org is set, misses the org-scoped
      # lookup and MINTS a second empty channel the deep link is then
      # refused from.
      assert {:error, {:live_redirect, _}} =
               live(conn, "/chat/ghost-channel?message=#{Ecto.UUID.generate()}")

      assert Repo.aggregate(Chat.Space, :count, :id) == before
      assert Chat.get_space_by_slug("ghost-channel", []) == nil
    end

    test "POSITIVE CONTROL: the same slug WITHOUT ?message= still bootstraps", %{conn: conn} do
      # The guard must be scoped to deep links only. Friendly-slug
      # auto-create is a deliberate product behaviour on the plain route
      # and this stage does not change it.
      before = Repo.aggregate(Chat.Space, :count, :id)

      {:ok, view, _html} = live(conn, "/chat/ghost-channel")

      assert Repo.aggregate(Chat.Space, :count, :id) == before + 1
      assert %Chat.Space{} = created = Chat.get_space_by_slug("ghost-channel", [])
      assert :sys.get_state(view.pid).socket.assigns.active_space.id == created.id
    end
  end

  # The ids actually streamed into the DOM, ASC. Used as the "window
  # tail" comparison in the unread test so the assertion fails if the
  # read cursor is set from the window instead of the channel.
  defp rendered_ids(view) do
    view
    |> render()
    |> then(&Regex.scan(~r/data-message-id="([0-9a-f-]{36})"/, &1))
    |> Enum.map(fn [_, id] -> id end)
  end

  defp restore_env(nil), do: Application.delete_env(:platform, :anchor_highlight_ms)
  defp restore_env(prev), do: Application.put_env(:platform, :anchor_highlight_ms, prev)

  defp eventually(fun, attempts \\ 40) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(25) && eventually(fun, attempts - 1)
    end
  end
end
