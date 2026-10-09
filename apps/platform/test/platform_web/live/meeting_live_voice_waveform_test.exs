defmodule PlatformWeb.MeetingLiveVoiceWaveformTest do
  @moduledoc """
  Task 01a1117f stage 4: the voice-only waveform, rendered through
  MeetingLive end to end.

    * Burrow joined by voice (`agent:<uuid>`, the stage 2 worker shape) shows
      the 4-bar rail glyph in EVERY rendered rail, in place of its initials;
    * once Burrow is in `@speaking_identities` it is promoted to ONE gallery
      tile, and that tile shows the 8-bar tile glyph and no avatar;
    * when it stops speaking the tile leaves the grid (the tiled-only-while-
      speaking rule is unchanged) and the rail row still carries the glyph;
    * an invited Burrow that has not joined keeps its initials and renders
      no glyph anywhere;
    * no "Unknown participant" anywhere on the page.

  `async: false`: the LiveKit dispatch target is resolved through a runtime
  registered in application-wide state, as in the stage 3 presence test this
  file borrows its fixtures from.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.{Chat, Federation, Meetings, Repo}
  alias Platform.Meetings.Meeting
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.MeetingLive

  @livekit_agent_name "meeting-voice-agent"

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "voice_worker_presence_#{n}@example.com",
      name: name,
      oidc_sub: "oidc-voice-worker-presence-#{n}"
    })
  end

  defp authenticated_conn(conn) do
    viewer = user!("Viewer")

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: viewer.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    init_test_session(conn, current_user_id: viewer.id)
  end

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Voice Worker Presence #{n}",
        slug: "voice-worker-presence-#{n}",
        kind: "channel"
      })

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Voice Worker Presence Project #{n}",
        slug: "voice-worker-presence-project-#{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "voice-worker-presence-#{n}",
        name: "Voice Worker Presence",
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    {meeting, space, room}
  end

  defp human!(room, name) do
    user = user!(name)

    {:ok, _} =
      Meetings.upsert_live_participant(room, %{identity: "user:#{user.id}", name: name})

    user
  end

  # Burrow's shape: a voice runtime declaring `client_info.livekit_agent_name`,
  # so `livekit_dispatch_target/1` resolves it and stage 1's fold applies.
  defp burrow! do
    owner = user!("Burrow Owner")
    n = System.unique_integer([:positive])
    agent = Repo.insert!(%Agent{slug: "vwf-burrow-#{n}", name: "Burrow", status: "active"})

    {:ok, _runtime, _raw_token} =
      Federation.register_voice_runtime(owner.id, agent, %{
        metadata: %{
          "client_info" => %{
            "features" => ["meeting_voice"],
            "livekit_agent_name" => @livekit_agent_name
          }
        }
      })

    Repo.reload(agent)
  end

  # The invite row as `invite_participant_row/2` writes it: agent FK, NO
  # identity yet.
  defp invite_row!(room, %Agent{} = agent) do
    {:ok, row} =
      Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})

    row
  end

  defp frag(html), do: LazyHTML.from_fragment(html)
  defp query(html, selector), do: html |> frag() |> LazyHTML.query(selector)

  defp mount(conn, meeting) do
    {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
    {view, html}
  end

  defp rail_glyphs(html), do: query(html, ~s([data-section="agents"] [data-voice-waveform]))
  defp gallery_tiles(html), do: query(html, "[data-gallery-cell] [data-agent-tile]")

  describe "Burrow joined by voice (agent:<uuid>)" do
    setup %{conn: conn} do
      {meeting, space, room} = meeting!()
      _host = human!(room, "Rowan")
      burrow = burrow!()
      invite = invite_row!(room, burrow)

      {:ok, joined} =
        Meetings.upsert_live_participant(room, %{identity: "agent:#{burrow.id}", name: nil})

      assert joined.id == invite.id
      assert joined.metadata["identity"] == "agent:#{burrow.id}"

      %{conn: authenticated_conn(conn), meeting: meeting, space: space, burrow: burrow}
    end

    test "voice_present_agent?/1 is true for its roster row", %{space: space} do
      {participants, _} = MeetingLive.meeting_presence(space.id)
      assert [agent] = Enum.filter(participants, &(&1.participant_type == "agent"))
      assert MeetingLive.voice_present_agent?(agent)
    end

    test "every rendered rail shows the 4-bar glyph for Burrow, and no initials", %{
      conn: conn,
      meeting: meeting,
      burrow: burrow
    } do
      {_view, html} = mount(conn, meeting)

      sections = query(html, ~s([data-section="agents"]))
      assert Enum.count(sections) >= 1

      for section <- sections do
        glyphs = LazyHTML.query(section, "[data-voice-waveform]")
        assert Enum.count(glyphs) == 1
        assert LazyHTML.attribute(glyphs, "data-size") == ["rail"]
        assert LazyHTML.attribute(glyphs, "data-identity") == ["agent:#{burrow.id}"]
        assert glyphs |> LazyHTML.query("[data-wave-bar]") |> Enum.count() == 4

        av = LazyHTML.query(section, ~s([data-role="agent-activity-avatar"]))
        assert LazyHTML.attribute(av, "data-voice") == ["true"]
      end

      # Distinct dom ids across the rails (a hook id must be unique).
      ids =
        html
        |> query(~s([data-section="agents"] [data-voice-waveform-root]))
        |> LazyHTML.attribute("id")

      assert length(ids) == Enum.count(sections)
      assert ids == Enum.uniq(ids)

      # Silent: no agent tile in the grid.
      assert html |> gallery_tiles() |> Enum.count() == 0
      refute html =~ "Unknown participant"
    end

    test "speaking promotes ONE Burrow tile with the 8-bar waveform and no avatar; silence removes it",
         %{conn: conn, meeting: meeting, burrow: burrow} do
      {view, _html} = mount(conn, meeting)

      html = render_hook(view, "active_speakers", %{"identities" => ["agent:#{burrow.id}"]})

      tiles = gallery_tiles(html)
      assert Enum.count(tiles) == 1

      wave = LazyHTML.query(tiles, "[data-voice-waveform]")
      assert Enum.count(wave) == 1
      assert LazyHTML.attribute(wave, "data-size") == ["tile"]
      assert wave |> LazyHTML.query("[data-wave-bar]") |> Enum.count() == 8
      assert tiles |> LazyHTML.query("[data-avatar-kind]") |> Enum.count() == 0
      assert tiles |> LazyHTML.query("img") |> Enum.count() == 0

      # The rail row keeps its glyph while the tile is up.
      assert html |> rail_glyphs() |> Enum.count() >= 1
      refute html =~ "Unknown participant"

      html = render_hook(view, "active_speakers", %{"identities" => []})
      assert html |> gallery_tiles() |> Enum.count() == 0
      assert html |> rail_glyphs() |> Enum.count() >= 1
    end
  end

  describe "Burrow invited but not joined" do
    setup %{conn: conn} do
      {meeting, space, room} = meeting!()
      _host = human!(room, "Rowan")
      burrow = burrow!()
      _invite = invite_row!(room, burrow)

      %{conn: authenticated_conn(conn), meeting: meeting, space: space, burrow: burrow}
    end

    test "keeps its initials and renders no glyph", %{conn: conn, meeting: meeting, space: space} do
      {participants, _} = MeetingLive.meeting_presence(space.id)
      assert [agent] = Enum.filter(participants, &(&1.participant_type == "agent"))
      refute MeetingLive.voice_present_agent?(agent)

      {_view, html} = mount(conn, meeting)

      assert html |> rail_glyphs() |> Enum.count() == 0

      for av <- query(html, ~s([data-section="agents"] [data-role="agent-activity-avatar"])) do
        assert LazyHTML.attribute(av, "data-voice") == []
      end

      assert html =~ ~s(<span aria-hidden="true">B</span>)
    end
  end

  describe "voice_present_agent?/1" do
    test "agent rows with an agent LiveKit identity are voice-present; anything else is not" do
      assert MeetingLive.voice_present_agent?(%{participant_type: "agent", identity: "agent:abc"})

      assert MeetingLive.voice_present_agent?(%{
               participant_type: "agent",
               identity: "agent-AJ_job1"
             })

      refute MeetingLive.voice_present_agent?(%{participant_type: "agent", identity: nil})
      refute MeetingLive.voice_present_agent?(%{participant_type: "agent"})
      refute MeetingLive.voice_present_agent?(%{participant_type: "agent", identity: "agent:"})
      refute MeetingLive.voice_present_agent?(%{participant_type: "agent", identity: "user:x"})
      # A human is never voice-present in this sense, whatever its identity.
      refute MeetingLive.voice_present_agent?(%{participant_type: "user", identity: "agent:abc"})
    end
  end
end
