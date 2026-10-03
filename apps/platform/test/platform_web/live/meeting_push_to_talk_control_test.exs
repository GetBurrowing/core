defmodule PlatformWeb.MeetingPushToTalkControlTest do
  @moduledoc """
  The PER-AGENT push-to-talk control, rendered through the real member
  mount (task 01a03f4e stage 5; re-homed to the roster per the prototype).

  The sponsor's prototype has the human press-and-hold a SPECIFIC agent's
  row to talk to it — not one generic "hold to talk" button — and the card
  comes back bylined to that agent. So the control now lives on each agent
  row in `ParticipantRail.participant_rail/1` (the desktop LEFT rail here),
  carrying the agent id it addresses.

  ## What this file deliberately does NOT assert

  It never asserts that the control LOOKS pressed, armed, or active. A
  control whose appearance changes while no audio is being captured is
  this feature's headline failure mode, and an assertion on appearance is
  green in exactly that case. Whether a press was accepted is decided by
  the `MeetingPushToTalk` hook against the live LiveKit publication and is
  asserted next door in `assets/test/hooks/meeting_push_to_talk.test.js`
  on MEASURED LEVELS and PUSHED EVENTS.

  What is asserted here is the server's half: that the control renders on
  the agent's row for a participant, that it names the agent it addresses,
  that the waveform the hook paints into exists, and that its colour comes
  from semantic token slots. The component-level markup is exercised more
  finely in `participant_rail_test.exs`; this file proves it reaches the
  page through the real mount.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  # Raw hex, and Tailwind's fixed palette. `lib/platform_web` currently
  # contains zero of the former, and semantic tokens beat fixed palette
  # colours there by a wide margin — this control does not become the
  # exception.
  @raw_hex ~r/#[0-9a-fA-F]{3,8}\b/
  @fixed_palette ~r/\b(?:bg|text|border|fill|stroke)-(?:slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-\d{2,3}\b/

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "ptt_#{n}@example.com",
        name: "PTT User #{n}",
        oidc_sub: "oidc-ptt-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.fabrikam_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    agent =
      %Agent{}
      |> Agent.changeset(%{slug: "octavius-#{n}", name: "Octavius #{n}", status: "active"})
      |> Repo.insert!()

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "PTT Project #{n}",
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "PTT Meeting #{n}",
        slug: "ptt-meeting-#{n}"
      })

    {:ok, _} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    # The rail sources from LIVE meeting presence
    # (`Meetings.active_participants_for_space/1`), not durable chat
    # membership — so the agent has to be a `Meetings.Participant` in an
    # active room for its row (and its hold control) to render.
    {:ok, room} = Meetings.ensure_room(meeting.chat_space_id)
    {:ok, room} = Meetings.activate_room(room)
    {:ok, _} = Meetings.participant_joined(room, %{agent_id: agent.id, display_name: agent.name})

    conn = init_test_session(conn, current_user_id: user.id)

    {:ok, _view, html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true")

    %{html: html, user: user, meeting: meeting, agent: agent}
  end

  defp controls(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-role='meeting-agent-hold-to-talk']")
  end

  test "a per-agent hold control renders, wired to its hook and carrying the agent id",
       %{html: html, agent: agent} do
    nodes = controls(html)
    # At least one (the agent in the room). The desktop People tab does not
    # add a second set here — the left rail already carries the controls.
    assert Enum.count(nodes) >= 1

    # The hook is the whole feature — the server renders an inert button
    # and every capture decision happens client-side.
    assert nodes |> LazyHTML.attribute("phx-hook") |> List.first() == "MeetingPushToTalk"

    # The hook writes inline transforms onto the bars; without this, any
    # re-render (an activity tick) wipes the waveform mid-sentence.
    assert nodes |> LazyHTML.attribute("phx-update") |> List.first() == "ignore"

    # The addressed agent's id — what the server reads to know WHO up front.
    assert agent.id in LazyHTML.attribute(nodes, "data-agent-id")
  end

  test "the waveform has bars for the hook to paint", %{html: html} do
    bars =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-role='meeting-agent-hold-to-talk'] [data-ptt-bar]")

    # Four per control (round 5, Dalton's PR #1178 re-check, item 6 — both
    # reference canvases draw exactly four 3px bars; twelve squeezed into
    # the 36px slot regardless of their declared width).
    assert Enum.count(bars) >= 4
  end

  test "it is reachable by keyboard and named for the agent", %{html: html, agent: agent} do
    nodes = controls(html)

    assert nodes |> LazyHTML.attribute("type") |> List.first() == "button"

    label = nodes |> LazyHTML.attribute("aria-label") |> List.first()
    assert is_binary(label) and label != ""
    assert label =~ agent.name
  end

  # On a phone a long press on the bare button raises the OS text-selection
  # / callout menu instead of holding, and the browser claims the touch for
  # scrolling before the hook can capture it. The fix is one named utility
  # in app.css (`touch-action: none`, `-webkit-touch-callout: none`,
  # `user-select: none`); the control must wear it, or the hook's pointer
  # capture is arming a control the OS has already taken.
  test "the hold control carries the touch utility and a 44px short axis", %{html: html} do
    nodes = controls(html)
    classes = nodes |> LazyHTML.attribute("class") |> List.first() |> String.split()

    assert "meeting-hold-target" in classes,
           "hold control is missing the meeting-hold-target utility; classes: " <>
             inspect(classes)

    # 44px minimum on the short axis (min-h-11 = 2.75rem = 44px).
    assert "min-h-11" in classes

    # The refused state the hook surfaces when pointer capture throws must
    # have a slot to render into, on the error token like every other refusal.
    assert "data-[rejected=pointer-lost]:text-error" in classes
  end

  # The utility must exist in the stylesheet, not just be named in the
  # markup — a class with no rule behind it is the silent version of the
  # bug this test exists to catch.
  test "the touch-action utility is defined in app.css with all three declarations" do
    css = File.read!(Path.join([File.cwd!(), "assets", "css", "app.css"]))

    [rule] = Regex.run(~r/\.meeting-hold-target\s*\{[^}]*\}/, css)

    assert rule =~ ~r/touch-action:\s*none/
    assert rule =~ ~r/-webkit-touch-callout:\s*none/
    assert rule =~ ~r/(?<!-webkit-)user-select:\s*none/
  end

  test "its colour comes from semantic token slots, not raw hex or fixed palette",
       %{html: html} do
    markup = controls(html) |> LazyHTML.to_html()

    refute Regex.match?(@raw_hex, markup),
           "hold control carries a raw hex colour: #{inspect(Regex.run(@raw_hex, markup))}"

    refute Regex.match?(@fixed_palette, markup),
           "hold control carries a fixed Tailwind palette colour: " <>
             "#{inspect(Regex.run(@fixed_palette, markup))}"

    # Positive control: the regexes above are only meaningful if they can
    # fire at all.
    assert Regex.match?(@raw_hex, ~s(<span class="text-[#ff0000]">))
    assert Regex.match?(@fixed_palette, ~s(<span class="bg-red-500">))

    # And it does use tokens, so "no hex" is not simply "no colour".
    # Task 01a0d3cd stage 2 (canvas 01a0d3cf-a424): the rest-state fill is
    # `--color-primary` with a `--color-primary-content` label — not
    # `--color-base-content`, which flips to near-white in the dark theme
    # and would be the white-on-cyan the canvas rules out. This fixture is
    # a resolvable, un-held agent, so it renders in that rest state; the
    # disabled fill's `--color-base-300` / `--color-neutral` pair is
    # covered in `participant_rail_test.exs`, which reaches both boundaries
    # that disable the control.
    assert markup =~ "primary"
    assert markup =~ "primary-content"
  end
end
