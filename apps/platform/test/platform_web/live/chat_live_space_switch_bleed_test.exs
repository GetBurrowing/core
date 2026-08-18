defmodule PlatformWeb.ChatLiveSpaceSwitchBleedTest do
  @moduledoc """
  Task 01a0119e stage 2: the reported walk, as a test.

  The report was that messages from the channel just left keep showing in the
  channel switched to. `:rendered_message_ids` and `:msg_day_labels` are keyed
  by message id with no space in them, and `PresenceHooks.enter_space/4`
  re-hydrates the stream from that set one line BEFORE the incoming space's
  loader resets it. `LiveStream.reset/1` only sets a flag; it leaves pending
  inserts alone, so the outgoing space's rows ride through the reset and land
  in the new space's DOM.

  Every test here NAVIGATES: land on B, go to A, come BACK to B. A test that
  mounts B directly passes against this defect, because a fresh mount starts
  with an empty MapSet. That is exactly why a hard refresh looked healthy
  while the bug was live, and it is the reason the shape of the walk is the
  whole point of the file.

  Each absence assertion is paired, in the same test, with a positive control
  proving B's own rows did render. "No message from A" is trivially true of a
  page that rendered nothing at all.

  Two of these four tests REPRODUCE the defect and two are GUARDS, recorded
  per test rather than left for a reader to work out. Against `1c89a1d5` (the
  pre-fix tree) the rendered-output test and the date-separator test fail; the
  `:rendered_message_ids` test and the embedded test pass. That split is the
  mechanism rather than a weakness in the tests: the incoming space's loader
  REPLACES both assigns wholesale a moment after the stale re-insert, so once
  the pipeline returns the assigns already read correctly and only the stream
  is polluted.

  The embedded pane gets the last test, and it is a PURITY test rather than a
  reproduction: `bootstrap_embedded_space/2` is reached once, from
  `ChatLive.embedded_mount/3`, and the embed defines no `handle_params/3`
  (see `PlatformWeb.ChatLive.Embedded`), so it cannot be navigated in-session
  and its MapSet is empty by construction. Its `clear_rendered_messages/1`
  call is a guard against a future re-entry path, and nothing that exists
  today can make that test go red.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.ExternalUserFixtures, as: Fixtures
  alias Platform.Repo

  setup %{conn: conn} do
    user = Fixtures.create_user!()

    # Two different calendar days, both far enough back that
    # `format_day_label/1` renders a date rather than "Today"/"Yesterday",
    # so the two channels' separators are distinguishable from each other.
    quay = channel_with_messages!(user, "quay", Date.add(Date.utc_today(), -40))
    mesa = channel_with_messages!(user, "mesa", Date.add(Date.utc_today(), -12))

    %{conn: Fixtures.login(conn, user.id), user: user, quay: quay, mesa: mesa}
  end

  describe "switching away and back (the reported walk)" do
    test "the returned-to channel renders its own messages and none of the other's",
         %{conn: conn, quay: quay, mesa: mesa} do
      {:ok, view, landing} = open(conn, mesa.space)

      # Baseline. The landing render is already clean, so whatever the walk
      # below produces is the walk's doing and not the fixture's.
      assert_body_present(landing, mesa)
      assert_body_absent(landing, quay)

      switch_to(view, quay.space)
      assert_patched(view, path(quay.space))

      # We really were in the other channel, so the return trip has something
      # to carry. A walk that never left proves nothing about coming back.
      assert render(view) =~ hd(quay.bodies)

      back = switch_to(view, mesa.space)
      assert_patched(view, path(mesa.space))

      # POSITIVE CONTROL, first and in this same test: the page we are about
      # to make absence claims about did render its own messages.
      assert_body_present(back, mesa)

      assert_body_absent(back, quay)
      assert_rows_absent(back, quay)
    end

    # GUARD, not a reproduction. Pre-fix this passes: `assign_message_window/4`
    # replaces `:rendered_message_ids` with the incoming space's ids, so the
    # stale window is closed by the time the pipeline returns. What it catches
    # is a future change that makes the loader MERGE instead of replace, which
    # would turn the carrier permanent instead of momentary.
    test "the id set the re-insert re-hydrates from holds only the channel on screen",
         %{conn: conn, quay: quay, mesa: mesa} do
      {:ok, view, _landing} = open(conn, mesa.space)
      switch_to(view, quay.space)
      switch_to(view, mesa.space)

      ids = rendered_message_ids(view)

      # Positive control at the assign level: the set is populated at all.
      for msg <- mesa.messages do
        assert MapSet.member?(ids, msg.id),
               "the channel on screen is missing its own message from :rendered_message_ids"
      end

      for msg <- quay.messages do
        refute MapSet.member?(ids, msg.id),
               "an id from the channel we left is still in :rendered_message_ids, " <>
                 "which is the carrier the presence re-insert reads"
      end
    end

    test "the date separators shown belong to the channel on screen",
         %{conn: conn, quay: quay, mesa: mesa} do
      {:ok, view, _landing} = open(conn, mesa.space)
      switch_to(view, quay.space)
      back = switch_to(view, mesa.space)

      dates = separator_dates(back)

      # `:msg_day_labels` was stale alongside `:rendered_message_ids`, so a
      # carried-over row kept the separator of the day it was posted in the
      # OTHER channel. Positive control, then the bleed, then the whole set.
      assert mesa.day in dates, "the channel on screen rendered no separator of its own"
      refute quay.day in dates, "a date separator from the channel we left is on screen"
      assert dates == [mesa.day]
    end
  end

  describe "the embedded meeting pane" do
    # PURITY, not a reproduction — see the moduledoc. The embed mounts once
    # and has no in-session navigation, so this cannot go red against the
    # pre-fix tree. It pins that the pane lands showing one channel's rows
    # and nothing else.
    test "mounts showing only its own channel's messages and separator",
         %{conn: conn, user: user, quay: quay, mesa: mesa} do
      {:ok, view, html} =
        live_isolated(conn, PlatformWeb.ChatLive.Embedded,
          session: %{"current_user_id" => user.id, "chat_space_slug" => mesa.space.slug}
        )

      assert_body_present(html, mesa)
      assert_body_absent(html, quay)
      assert_rows_absent(html, quay)
      assert separator_dates(html) == [mesa.day]

      assert MapSet.equal?(rendered_message_ids(view), MapSet.new(mesa.messages, & &1.id))
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────

  defp channel_with_messages!(user, label, %Date{} = day) do
    n = System.unique_integer([:positive])
    space = Fixtures.channel!(%{name: "#{String.capitalize(label)} #{n}", slug: "#{label}-#{n}"})
    participant = Fixtures.add_user!(space.id, user.id)

    bodies = ["#{label} sentinel one #{n}", "#{label} sentinel two #{n}"]

    messages =
      Enum.map(bodies, fn body ->
        space.id |> Fixtures.post!(participant.id, body) |> backdate!(day)
      end)

    %{
      space: space,
      participant: participant,
      messages: messages,
      bodies: bodies,
      day: Date.to_iso8601(day)
    }
  end

  # `message_day/1` buckets on `inserted_at`, so the fixture has to move the
  # row's timestamp rather than just claim a date. Midday UTC keeps the
  # calendar date the same however the runner's clock is set.
  defp backdate!(%Message{} = msg, %Date{} = day) do
    at = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")
    {1, _} = Repo.update_all(from(m in Message, where: m.id == ^msg.id), set: [inserted_at: at])
    %{msg | inserted_at: at}
  end

  # ── navigation ────────────────────────────────────────────────────────

  defp path(space), do: "/chat/" <> Chat.space_path_segment(space)

  defp open(conn, space) do
    case live(conn, path(space)) do
      {:error, {:live_redirect, %{to: to}}} -> live(conn, to)
      ok -> ok
    end
  end

  # The rail row is an ordinary `<.link patch=…>` anchor, so this is the
  # click the reporter made, not a `render_patch/2` shortcut past the markup.
  defp switch_to(view, space) do
    view
    |> element(~s(#chat-sidebar a[href="#{path(space)}"]))
    |> render_click()
  end

  # ── assertions ────────────────────────────────────────────────────────

  defp assert_body_present(html, channel) do
    for body <- channel.bodies do
      assert html =~ body, "expected this channel's own message #{inspect(body)} to render"
    end
  end

  defp assert_body_absent(html, channel) do
    for body <- channel.bodies do
      refute html =~ body,
             "a message from the other channel (#{inspect(body)}) is rendered here"
    end
  end

  defp assert_rows_absent(html, channel) do
    for msg <- channel.messages do
      refute html =~ ~s(data-message-id="#{msg.id}"),
             "a message row from the other channel is in the DOM"

      refute html =~ ~s(id="messages-#{msg.id}"),
             "a stream item from the other channel is in the DOM"
    end
  end

  defp rendered_message_ids(view) do
    :sys.get_state(view.pid).socket.assigns.rendered_message_ids
  end

  # Separator dates only. The message ROW also carries a `data-date`, so a
  # bare scan for the attribute would answer a different question than
  # "which day dividers are on screen".
  defp separator_dates(html) do
    ~r/<div[^>]*js-date-separator[^>]*>/
    |> Regex.scan(html)
    |> Enum.flat_map(fn [tag] ->
      case Regex.run(~r/data-date="([^"]+)"/, tag) do
        [_, date] -> [date]
        _ -> []
      end
    end)
  end
end
