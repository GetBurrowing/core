defmodule PlatformWeb.ChatLiveFirstFrameBackfillTest do
  @moduledoc """
  The smaller chat first frame (task 01a17bf4 stage 2).

  A default (non-anchored) space entry puts only the newest
  `initial_message_count` top-level messages in the join reply. The connected
  mount then backfills the rest of the 50-message window through the same
  prepend path infinite scroll uses (`MessagesHooks.prepend_older_batch/3`).

    (a) first frame holds exactly N rows; after `render_async/1`, exactly 50,
        oldest first, no duplicate ids;
    (b) the top sentinel firing while the backfill is in flight neither
        double-loads nor duplicates (the backfill is HELD through the
        dev/test fault seam so the race is deterministic, not timing luck);
    (c) a backfill that fails leaves the view alive, keeps the first frame,
        and sets `:has_more_older` true so the sentinel can fetch it;
    (d) the anchored deep link is unchanged: 25 / anchor / 25.

  `async: false`: N is set with `Application.put_env/3` (a VM-wide value the
  view reads at call time), and so is the fault seam. Both are restored in
  `on_exit`.

  N is written here as a literal (12), not read from config: the test pins the
  behaviour for a given N, and config/config.exs carries the measured value.
  """

  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  @n 12
  @window 50
  @seeded 60

  setup %{conn: conn} do
    prev_cfg = Application.get_env(:platform, PlatformWeb.ChatLive)
    prev_fault = Application.get_env(:platform, :chat_async_fault)

    Application.put_env(
      :platform,
      PlatformWeb.ChatLive,
      Keyword.put(prev_cfg || [], :initial_message_count, @n)
    )

    on_exit(fn ->
      if prev_cfg,
        do: Application.put_env(:platform, PlatformWeb.ChatLive, prev_cfg),
        else: Application.delete_env(:platform, PlatformWeb.ChatLive)

      if prev_fault,
        do: Application.put_env(:platform, :chat_async_fault, prev_fault),
        else: Application.delete_env(:platform, :chat_async_fault)
    end)

    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "first_frame_#{n}@example.com",
        name: "First Frame #{n}",
        oidc_sub: "oidc-first-frame-#{n}",
        avatar_url: nil
      })

    {:ok, space} =
      Chat.create_space(%{name: "First frame #{n}", slug: "first-frame-#{n}", kind: "channel"})

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "author-#{n}",
        joined_at: DateTime.utc_now()
      })

    messages =
      for i <- 1..@seeded do
        {:ok, msg} =
          Chat.post_message(%{
            space_id: space.id,
            participant_id: author.id,
            content_type: "text",
            content: "ff-#{String.pad_leading(Integer.to_string(i), 3, "0")}"
          })

        msg
      end

    {:ok,
     conn: init_test_session(conn, current_user_id: user.id), space: space, messages: messages}
  end

  # Message ids in the order the list renders them (LiveViewTest applies the
  # stream ops to its DOM). NOT de-duplicated: a duplicate row must show.
  defp row_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#message-list > [data-message-id]")
    |> LazyHTML.attribute("data-message-id")
  end

  defp newest(messages, k), do: messages |> Enum.take(-k) |> Enum.map(& &1.id)

  test "(a) the join render holds exactly N rows; after the backfill, the 50-row window",
       %{conn: conn, space: space, messages: messages} do
    {:ok, view, first_html} = live(conn, ~p"/chat/#{space.slug}")

    assert row_ids(first_html) == newest(messages, @n)

    render_async(view)
    ids = row_ids(render(view))

    assert length(ids) == @window
    assert ids == Enum.uniq(ids), "duplicate rows after backfill"
    assert ids == newest(messages, @window), "not the newest 50, oldest first"
    refute :sys.get_state(view.pid).socket.assigns.loading_older
  end

  test "(b) the top sentinel firing while the backfill is in flight does not double-load",
       %{conn: conn, space: space, messages: messages} do
    Application.put_env(:platform, :chat_async_fault, [{:hold, :history_backfill, self()}])

    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
    assert_receive {:chat_async_held, :history_backfill, task}, 2_000

    # The sentinel is visible because N rows do not fill a tall viewport.
    render_hook(view, "load_older_messages", %{})
    assert row_ids(render(view)) == newest(messages, @n), "the sentinel loaded during backfill"

    send(task, :release)
    render_async(view)
    ids = row_ids(render(view))

    assert ids == Enum.uniq(ids), "duplicate rows"
    assert length(ids) == @window
    assert ids == newest(messages, @window)
  end

  test "(c) a failed backfill leaves the view alive with the sentinel armed",
       %{conn: conn, space: space, messages: messages} do
    Application.put_env(:platform, :chat_async_fault, [:history_backfill])

    log =
      capture_log(fn ->
        {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
        render_async(view)

        assert Process.alive?(view.pid)
        html = render(view)
        assert row_ids(html) == newest(messages, @n)

        assigns = :sys.get_state(view.pid).socket.assigns
        assert assigns.has_more_older
        refute assigns.loading_older
        assert has_element?(view, "#chat-scroll-sentinel-top")
        refute has_element?(view, ~s(#chat-scroll-sentinel-top[data-loading="true"]))

        # And the sentinel can then fetch the history itself.
        Application.delete_env(:platform, :chat_async_fault)
        render_hook(view, "load_older_messages", %{})
        assert row_ids(render(view)) == Enum.map(messages, & &1.id)
      end)

    assert log =~ "chat history backfill failed"
  end

  test "(d) an anchored deep link still renders 25 / anchor / 25 and starts no backfill",
       %{conn: conn, space: space, messages: messages} do
    anchor = Enum.at(messages, 29)

    {:ok, view, html} = live(conn, ~p"/chat/#{space.slug}?message=#{anchor.id}")
    expected = messages |> Enum.slice(4, 51) |> Enum.map(& &1.id)

    assert row_ids(html) == expected
    assert Enum.find_index(row_ids(html), &(&1 == anchor.id)) == 25
    assert :sys.get_state(view.pid).socket.assigns.history_backfill == nil

    render_async(view)
    assert row_ids(render(view)) == expected
  end

  # The audit's N+1 (task 01a17bf4 stage 2): `enrich_versions_count/1` ran a
  # COUNT per message, 50 of the window's 62 queries. The window loaders now
  # batch it. Counted on the view's own process and the backfill task (whose
  # $callers lead back to the view), by query source.
  test "(e) the window costs one versions query per batch, not one per message",
       %{conn: conn, space: space} do
    test_pid = self()
    handler = "first-frame-versions-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:platform, :repo, :query],
        fn _event, _m, meta, _ ->
          if meta[:source] == "chat_message_versions" do
            send(test_pid, {:versions_query, self(), Process.get(:"$callers", [])})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
    render_async(view)
    _ = render(view)

    count = count_versions_queries(view.pid, 0)
    # One for the N-row first frame, one for the backfilled batch.
    assert count == 2, "#{count} chat_message_versions queries for a #{@window}-row window"
  end

  defp count_versions_queries(view_pid, acc) do
    receive do
      {:versions_query, pid, callers} ->
        if pid == view_pid or view_pid in callers,
          do: count_versions_queries(view_pid, acc + 1),
          else: count_versions_queries(view_pid, acc)
    after
      0 -> acc
    end
  end
end
