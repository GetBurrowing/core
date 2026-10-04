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
  that the mockup's bars exist, and that its colour comes from the Ask
  section's custom properties rather than from markup. The component-level markup is exercised more
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

  test "the key carries the mockup's four bars", %{html: html} do
    bars =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-role='meeting-agent-hold-to-talk'] .bars > i")

    # Four per control, as the Ask mockup draws them; `meeting_ask.css`
    # animates them while the key is `data-held`.
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
  # scrolling before the hook can capture it. The Ask mockup's `.ask` rule
  # carries the three declarations itself; the control must wear that
  # class inside the `.meeting-ask` section, or the hook's pointer capture
  # is arming a control the OS has already taken.
  test "the hold control is the mockup's .ask inside the .meeting-ask section", %{html: html} do
    keys =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(".meeting-ask [data-role='meeting-agent-hold-to-talk']")

    assert Enum.count(keys) >= 1
    assert keys |> LazyHTML.attribute("class") |> Enum.uniq() == ["ask"]
  end

  # The declarations must exist in the stylesheet, not just be implied by
  # the class — a class with no rule behind it is the silent version of the
  # bug this test exists to catch.
  test "the .ask rule in meeting_ask.css carries all three touch declarations" do
    css = File.read!(Path.join([File.cwd!(), "assets", "css", "meeting_ask.css"]))

    [rule] = Regex.run(~r/\.meeting-ask \.ask\{[^}]*\}/, css)

    assert rule =~ ~r/touch-action:\s*none/
    assert rule =~ ~r/-webkit-touch-callout:\s*none/
    assert rule =~ ~r/(?<!-webkit-)user-select:\s*none/
  end

  test "its colour comes from the section's custom properties, not raw hex or palette utilities",
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

    # And it does have a colour, so "no hex in the markup" is not simply
    # "no colour": the Ask mockup's fill and label are the section's
    # `--a` / `--ai` custom properties, declared once in `meeting_ask.css`.
    css = File.read!(Path.join([File.cwd!(), "assets", "css", "meeting_ask.css"]))
    [rule] = Regex.run(~r/\.meeting-ask \.ask\{[^}]*\}/, css)
    assert rule =~ "background:var(--a);color:var(--ai);"
  end
end
