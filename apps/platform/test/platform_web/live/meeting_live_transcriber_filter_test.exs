defmodule PlatformWeb.MeetingLiveTranscriberFilterTest do
  @moduledoc """
  Task 01a0d4fe stage 2: the meeting transcriber is not a participant tile.

  The transcriber joins LiveKit with no user or agent FK, so before this
  stage `build_meeting_participants/1` mapped its row into a `"user"` view
  model and every LiveView surface drew it as an "Unknown participant"
  tile, sized the gallery for one cell too many and counted it in the top
  bar. `MeetingLive.meeting_presence/1` now splits the rows once on
  `Meetings.transcriber_participant?/1`, and `build_meeting_participants/1`
  delegates to it, so the gallery, strip, top-bar count and the /chat
  quick-meet roster all lose the row from one decision.

  `async: false` because the config-override cases `put_env` the
  `:transcriber_identity_markers` list, which is global app env.
  `meeting_live_test.exs` is `async: true` and must not do that.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Platform.{Chat, Meetings, Repo}
  alias Platform.Accounts.User
  alias Platform.Meetings.Meeting
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.ChatLive.Partials
  alias PlatformWeb.MeetingLive

  # ── Fixtures (mirroring meeting_live_test.exs) ──────────────────────────

  defp user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "transcriber_filter_#{n}@example.com",
      name: name,
      oidc_sub: "oidc-transcriber-filter-#{n}"
    })
  end

  defp authenticated_conn(conn) do
    viewer = user!("Viewer")

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: viewer.id,
      org_id: Platform.TenancyFixtures.fabrikam_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    init_test_session(conn, current_user_id: viewer.id)
  end

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Transcriber Filter Space #{n}",
        slug: "transcriber-filter-space-#{n}",
        kind: "channel"
      })

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Transcriber Filter Project #{n}",
        slug: "transcriber-filter-project-#{n}",
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
      })
      |> Repo.insert()

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "transcriber-filter-#{n}",
        name: "Transcriber Filter",
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    {meeting, space, room}
  end

  # A human row with a user FK, joined the way the LiveKit webhook joins
  # it. Neither human publishes a camera: no fixture here has a video track.
  defp human!(room, name) do
    user = user!(name)

    {:ok, _} =
      Meetings.upsert_live_participant(room, %{identity: "user:#{user.id}", name: name})

    user
  end

  # The production shape (org journal 2026-08-05): nil FKs, display name
  # "Transcription", identity "transcriber:space-<uuid>".
  defp transcriber!(room, space, identity \\ nil, name \\ "Transcription") do
    identity = identity || "transcriber:space-#{space.id}"

    {:ok, _} = Meetings.upsert_live_participant(room, %{identity: identity, name: name})

    identity
  end

  defp seed_room do
    {meeting, space, room} = meeting!()
    ada = human!(room, "Ada Human")
    grace = human!(room, "Grace Human")
    transcriber_identity = transcriber!(room, space)

    %{
      meeting: meeting,
      space: space,
      room: room,
      ada: ada,
      grace: grace,
      transcriber_identity: transcriber_identity
    }
  end

  defp put_markers(markers) do
    original = Application.get_env(:platform, :transcriber_identity_markers)
    Application.put_env(:platform, :transcriber_identity_markers, markers)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:platform, :transcriber_identity_markers)
        value -> Application.put_env(:platform, :transcriber_identity_markers, value)
      end
    end)
  end

  defp frag(html), do: LazyHTML.from_fragment(html)
  defp query(html, selector), do: html |> frag() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  defp gallery_tiles(html), do: query(html, "[data-gallery-grid] .meeting-video-tile")

  defp gallery_identities(html),
    do: html |> gallery_tiles() |> LazyHTML.attribute("data-participant") |> Enum.sort()

  # ── meeting_presence/1 ──────────────────────────────────────────────────

  describe "meeting_presence/1" do
    test "returns the two humans and reports the transcriber as present" do
      %{space: space, ada: ada, grace: grace} = seed_room()

      assert {participants, true} = MeetingLive.meeting_presence(space.id)

      assert participants |> Enum.map(& &1.participant_id) |> Enum.sort() ==
               Enum.sort([ada.id, grace.id])

      refute Enum.any?(participants, &(&1.identity =~ "transcriber:"))

      # build_meeting_participants/1 is the same list.
      assert MeetingLive.build_meeting_participants(space.id) == participants
    end

    test "a room with no transcriber reports false and keeps every human" do
      {_meeting, space, room} = meeting!()
      human!(room, "Solo Human")

      assert {[%{participant_type: "user"}], false} = MeetingLive.meeting_presence(space.id)
    end

    test "a non-binary space id is {[], false}" do
      assert MeetingLive.meeting_presence(nil) == {[], false}
      assert MeetingLive.build_meeting_participants(nil) == []
    end
  end

  # ── The mounted /meetings view ──────────────────────────────────────────

  describe "/meetings gallery with two humans and a transcriber" do
    setup %{conn: conn} do
      Map.put(seed_room(), :conn, authenticated_conn(conn))
    end

    test "renders exactly two tiles in the two-cell grid, with no transcriber anywhere", %{
      conn: conn,
      meeting: meeting,
      ada: ada,
      grace: grace
    } do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      assert html =~ ~s(data-stage-mode="gallery")
      assert gallery_identities(html) == Enum.sort(["user:#{ada.id}", "user:#{grace.id}"])
      assert count(html, ".meeting-video-tile") == 2

      assert query(html, "[data-gallery-grid]") |> LazyHTML.attribute("data-gallery-grid-shape") ==
               [MeetingLive.gallery_grid_class(2)]

      # `gallery_grid_class(3)` is ALSO "grid-cols-2", so the shape alone
      # cannot tell two cells from three. What does: the declared tile count
      # and the ghost cell, which renders at exactly three cells.
      assert query(html, "[data-gallery-tile-count]")
             |> LazyHTML.attribute("data-gallery-tile-count") ==
               ["2"]

      assert count(html, "[data-gallery-ghost-cell]") == 0

      assert count(html, ~s([data-participant^="transcriber:"])) == 0
      refute html =~ "Unknown participant"

      # Top bar: "2 people", not 3.
      readout = query(html, ~s([data-role="meeting-roster-count"]))
      assert LazyHTML.attribute(readout, "data-people") == ["2"]
      assert LazyHTML.text(readout) =~ "2 people"

      # The strip only renders outside gallery; its human count is 2 too.
      strip_html = view |> element(~s([data-stage-mode-button="canvas"])) |> render_click()

      assert query(strip_html, ~s([data-pane="bottom-strip"]))
             |> LazyHTML.attribute("data-tile-count-humans") == ["2"]

      assert count(strip_html, ~s([data-participant^="transcriber:"])) == 0
      refute strip_html =~ "Unknown participant"
    end

    test "a human with no camera keeps their tile, drawn with the avatar fallback", %{
      conn: conn,
      meeting: meeting,
      ada: ada
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      tile = query(html, ~s([data-gallery-grid] [data-participant="user:#{ada.id}"]))
      assert Enum.count(tile) == 1
      assert LazyHTML.attribute(tile, "data-has-video") == ["false"]

      fallback = LazyHTML.query(tile, "[data-avatar-fallback]")
      assert Enum.count(fallback) == 1
      refute fallback |> LazyHTML.attribute("class") |> hd() =~ "hidden"
    end

    test "a transcriber leaving and rejoining never changes the tile count", %{
      conn: conn,
      meeting: meeting,
      room: room,
      transcriber_identity: identity
    } do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
      assert count(html, "[data-gallery-grid] .meeting-video-tile") == 2
      assert :sys.get_state(view.pid).socket.assigns.transcriber_present? == true

      Meetings.mark_live_participant_left(room, %{identity: identity, name: "Transcription"})
      html = render(view)
      assert count(html, "[data-gallery-grid] .meeting-video-tile") == 2
      assert :sys.get_state(view.pid).socket.assigns.transcriber_present? == false

      {:ok, _} =
        Meetings.upsert_live_participant(room, %{identity: identity, name: "Transcription"})

      send(view.pid, {:meeting_presence_update, %{}})
      html = render(view)
      assert count(html, "[data-gallery-grid] .meeting-video-tile") == 2
      assert :sys.get_state(view.pid).socket.assigns.transcriber_present? == true
    end
  end

  describe "the configured marker list decides what is hidden" do
    setup %{conn: conn} do
      put_markers(["custom-scribe:"])
      Map.put(seed_room(), :conn, authenticated_conn(conn))
    end

    test "with markers overridden, the transcriber: row reappears as a third tile", %{
      conn: conn,
      meeting: meeting,
      space: space,
      transcriber_identity: identity
    } do
      assert {participants, false} = MeetingLive.meeting_presence(space.id)
      assert length(participants) == 3

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      assert count(html, "[data-gallery-grid] .meeting-video-tile") == 3
      assert identity in gallery_identities(html)
      assert count(html, "[data-gallery-ghost-cell]") == 1
    end

    test "with markers overridden, a custom-scribe: row is hidden", %{
      conn: conn,
      meeting: meeting,
      space: space,
      room: room
    } do
      # A distinct name: `upsert_live_participant/2` dedupes nil-FK rows by
      # display name, so a second "Transcription" would backfill the first.
      transcriber!(room, space, "custom-scribe:1", "Custom Scribe")

      assert {participants, true} = MeetingLive.meeting_presence(space.id)
      assert length(participants) == 3
      refute Enum.any?(participants, &(&1.identity == "custom-scribe:1"))

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
      assert count(html, "[data-gallery-grid] .meeting-video-tile") == 3
      assert count(html, ~s([data-participant="custom-scribe:1"])) == 0
    end
  end

  # ── The Transcribing pill (stage 4) ─────────────────────────────────────
  #
  # The pill is the transcriber's ONLY representation once stage 2 removed it
  # from every tile, roster and count. It is driven by `:transcriber_present?`,
  # which `refresh_participants/1` recomputes on every presence broadcast, so
  # it must appear and disappear in ONE mounted view.

  describe "top bar: transcribing pill (stage 4)" do
    @pill ~s([data-role="meeting-transcribing-pill"])
    @aria "This meeting is being transcribed"

    setup %{conn: conn} do
      %{conn: authenticated_conn(conn)}
    end

    test "a transcriber row renders one status pill, after the live pill, with its a11y", %{
      conn: conn
    } do
      %{meeting: meeting} = seed_room()

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      assert has_element?(view, ~s(header #{@pill}[role="status"][aria-label="#{@aria}"]))
      assert has_element?(view, ~s(#{@pill}[title="Meeting transcriber is in the room"]))
      assert count(html, @pill) == 1

      [class] = html |> query(@pill) |> LazyHTML.attribute("class")

      for token <- ~w(bg-info/10 border-info/40 rounded-full text-[10px] font-medium
                      leading-4 text-base-content flex-shrink-0) do
        assert class =~ token, "missing #{token} in #{inspect(class)}"
      end

      # State, not information: it never yields at narrow widths, and the word
      # is never painted in the pill's own hue (measured in the HEEx comment).
      refute class =~ "hidden"
      refute class =~ "text-info"

      # The dot is filled and static; below `sm` the word is sr-only and the
      # document icon paints, so the pill is never colour-only.
      [dot_class] =
        html
        |> query(~s(#{@pill} > span[aria-hidden="true"].bg-info))
        |> LazyHTML.attribute("class")

      refute dot_class =~ "animate"
      assert count(html, ~s(#{@pill} .hero-document-text.sm\\:hidden[aria-hidden="true"])) == 1
      assert count(html, ~s(#{@pill} .sr-only.sm\\:not-sr-only)) == 1
      assert html |> query(@pill) |> LazyHTML.text() |> String.trim() == "transcribing"

      # Order inside the title box: live, then transcribing (rec absent here).
      roles =
        html
        |> query(~s([data-role="meeting-title"] > [data-role]))
        |> LazyHTML.attribute("data-role")

      assert roles == ["meeting-live-pill", "meeting-transcribing-pill"]
    end

    # The pill sits INSIDE the basis-driven title box, so it costs the name
    # its width unless the box's shrink weight drops the way it does for the
    # rec pill (measured in the HEEx shrink note). Quiet path stays `shrink`.
    test "the pill lowers the title box's shrink weight, like the rec pill", %{conn: conn} do
      %{meeting: meeting} = seed_room()
      {quiet_meeting, _space, quiet_room} = meeting!()
      human!(quiet_room, "Ada Human")

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
      [class] = html |> query(~s([data-role="meeting-title"])) |> LazyHTML.attribute("class")
      assert class =~ "shrink-[0.2] sm:shrink"

      {:ok, _view, quiet} = live(conn, ~p"/meetings/#{quiet_meeting.slug}?no_autojoin=true")

      [quiet_class] =
        quiet |> query(~s([data-role="meeting-title"])) |> LazyHTML.attribute("class")

      refute quiet_class =~ "shrink-[0.2]"
      assert quiet_class =~ ~r/(^|\s)shrink(\s|$)/
    end

    test "no transcriber row means NO node, not a hidden one", %{conn: conn} do
      {meeting, _space, room} = meeting!()
      human!(room, "Ada Human")

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      refute has_element?(view, @pill)
      refute html =~ "meeting-transcribing-pill"
      refute html =~ @aria
      # Positive control: the header rendered, so the refutes could fire.
      assert has_element?(view, ~s(header [data-role="meeting-live-pill"]))
    end

    test "a human-only room with cameras off shows no pill", %{conn: conn} do
      {meeting, _space, room} = meeting!()
      ada = human!(room, "Ada Human")
      human!(room, "Grace Human")

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      tile = query(html, ~s([data-gallery-grid] [data-participant="user:#{ada.id}"]))
      assert LazyHTML.attribute(tile, "data-has-video") == ["false"]
      refute has_element?(view, @pill)
    end

    # BINDING: the pill disappears when the transcriber leaves, in the SAME
    # view process, driven only by `mark_live_participant_left/2`'s broadcast.
    test "the pill disappears when the transcriber leaves, with no remount", %{conn: conn} do
      %{meeting: meeting, room: room, transcriber_identity: identity} = seed_room()

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
      assert has_element?(view, @pill)
      pid = view.pid

      {:ok, _} =
        Meetings.mark_live_participant_left(room, %{identity: identity, name: "Transcription"})

      refute render(view) =~ "meeting-transcribing-pill"
      refute has_element?(view, @pill)
      assert view.pid == pid
    end

    test "under a custom-scribe: override, transcriber: does not light the pill and custom-scribe: does",
         %{conn: conn} do
      put_markers(["custom-scribe:"])
      %{meeting: meeting, room: room, space: space} = seed_room()

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
      refute has_element?(view, @pill)

      transcriber!(room, space, "custom-scribe:1", "Custom Scribe")
      send(view.pid, {:meeting_presence_update, %{}})

      assert has_element?(view, ~s(#{@pill}[role="status"]))
    end

    test "a mount with no meeting renders without the assign and without the pill", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/meetings")

      assert :sys.get_state(view.pid).socket.assigns.meeting == nil
      refute html =~ "meeting-transcribing-pill"
    end
  end

  # ── The marker list reaches MeetingClient (stage 3) ─────────────────────
  #
  # MeetingClient carries no copy of the marker list; it reads
  # `#meeting-client[data-transcriber-markers]`. These pin that both surfaces
  # render the attribute from `Meetings.transcriber_identity_markers/0`, and
  # that a config override reaches the rendered value.

  describe "#meeting-client[data-transcriber-markers]" do
    defp client_markers(html) do
      assert [raw] =
               html
               |> query("#meeting-client[data-transcriber-markers]")
               |> LazyHTML.attribute("data-transcriber-markers")

      Jason.decode!(raw)
    end

    defp chat_html(conn, space) do
      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")
      html
    end

    defp meetings_html(conn, meeting) do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
      html
    end

    test "/meetings and /chat decode to the server's marker list", %{conn: conn} do
      %{meeting: meeting, space: space} = seed_room()
      conn = authenticated_conn(conn)

      expected = Meetings.transcriber_identity_markers()
      assert expected != []

      assert client_markers(meetings_html(conn, meeting)) == expected
      assert client_markers(chat_html(conn, space)) == expected
    end

    test "a put_env override reaches both rendered attributes", %{conn: conn} do
      put_markers(["custom-scribe:"])
      %{meeting: meeting, space: space} = seed_room()
      conn = authenticated_conn(conn)

      assert Meetings.transcriber_identity_markers() == ["custom-scribe:"]
      assert client_markers(meetings_html(conn, meeting)) == ["custom-scribe:"]
      assert client_markers(chat_html(conn, space)) == ["custom-scribe:"]
    end

    # Stage 5, the task-level review's finding 1. The two tests above only
    # prove the MOUNT render reads the config. The reviewer's case changes
    # the config on a LIVE view and then re-renders it with a mic toggle; an
    # assign-free expression is static to change tracking and never re-sends,
    # so the attribute stayed at the old list. These drive that sequence on
    # both surfaces. `data-mic-enabled` flipping is the positive control that
    # the event really re-rendered `#meeting-client`.
    defp mic_enabled(html) do
      assert [raw] =
               html
               |> query("#meeting-client[data-mic-enabled]")
               |> LazyHTML.attribute("data-mic-enabled")

      raw
    end

    defp live_chat(conn, space) do
      {:ok, view, html} = live(conn, ~p"/chat/#{space.slug}")
      {view, html}
    end

    defp live_meetings(conn, meeting) do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
      {view, html}
    end

    for {surface, mount_fun} <- [{"/chat", :live_chat}, {"/meetings", :live_meetings}] do
      test "#{surface}: a put_env on a live view reaches the attribute on the next event",
           %{conn: conn} do
        %{meeting: meeting, space: space} = seed_room()
        conn = authenticated_conn(conn)
        target = if unquote(mount_fun) == :live_chat, do: space, else: meeting

        {view, html} = apply_mount(unquote(mount_fun), conn, target)
        default = Meetings.transcriber_identity_markers()
        assert client_markers(html) == default
        mic_before = mic_enabled(html)

        put_markers(["custom-scribe:"])

        html = render_hook(view, "meeting_toggle_mic", %{})

        refute mic_enabled(html) == mic_before
        assert client_markers(html) == ["custom-scribe:"]
      end

      test "#{surface}: with no config change the attribute is unchanged after the event",
           %{conn: conn} do
        %{meeting: meeting, space: space} = seed_room()
        conn = authenticated_conn(conn)
        target = if unquote(mount_fun) == :live_chat, do: space, else: meeting

        {view, html} = apply_mount(unquote(mount_fun), conn, target)
        before = client_markers(html)
        mic_before = mic_enabled(html)

        html = render_hook(view, "meeting_toggle_mic", %{})

        refute mic_enabled(html) == mic_before
        assert client_markers(html) == before
        assert before == Meetings.transcriber_identity_markers()
      end
    end

    # `{:meeting_presence_summary, _}` is one `MeetingHooks`' `:meeting_info`
    # hook HALTS, so this also pins that the recompute hook runs ahead of it.
    test "/chat: a put_env reaches the attribute on the next handle_info", %{conn: conn} do
      %{space: space} = seed_room()
      conn = authenticated_conn(conn)
      {view, _html} = live_chat(conn, space)

      put_markers(["custom-scribe:"])
      send(view.pid, {:meeting_presence_summary, %{space_id: space.id}})

      assert client_markers(render(view)) == ["custom-scribe:"]
    end

    defp apply_mount(:live_chat, conn, space), do: live_chat(conn, space)
    defp apply_mount(:live_meetings, conn, meeting), do: live_meetings(conn, meeting)
  end

  # ── The /chat quick-meet roster ─────────────────────────────────────────

  describe "/chat quick-meet roster" do
    defp render_roster(participants) do
      assigns = %{participants: participants}

      ~H"""
      <Partials.meeting_roster id="meeting-roster-test" participants={@participants} />
      """
      |> rendered_to_string()
    end

    test "excludes the transcriber from the rows and the count" do
      %{space: space, ada: ada, grace: grace} = seed_room()

      # `MeetingHooks.meeting_participants/1` delegates to exactly this call.
      html = space.id |> MeetingLive.build_meeting_participants() |> render_roster()

      assert html
             |> query(~s([data-role="meeting-roster-row"]))
             |> LazyHTML.attribute("data-identity")
             |> Enum.sort() ==
               Enum.sort(["user:#{ada.id}", "user:#{grace.id}"])

      assert html
             |> query(~s([data-role="meeting-roster-count"]))
             |> LazyHTML.text()
             |> String.trim() ==
               "2"

      refute html =~ "transcriber:"
      refute html =~ "Transcription"

      # Positive control: the unfiltered rows DO carry the transcriber, so the
      # refutes above can fire.
      unfiltered =
        space.id
        |> Meetings.active_participants_for_space()
        |> Enum.map(&MeetingLive.meeting_participant_view_model/1)
        |> render_roster()

      assert count(unfiltered, ~s([data-role="meeting-roster-row"])) == 3
    end
  end
end
