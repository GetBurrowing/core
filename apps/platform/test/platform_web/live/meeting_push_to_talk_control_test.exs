defmodule PlatformWeb.MeetingPushToTalkControlTest do
  @moduledoc """
  The push-to-talk control in the meeting bar (task 01a03f4e stage 5).

  ## What this file deliberately does NOT assert

  It never asserts that the button LOOKS pressed, armed, or active. A
  control whose appearance changes while no audio is being captured is
  this feature's headline failure mode, and an assertion on appearance is
  green in exactly that case. Whether a press was accepted is decided by
  the `MeetingPushToTalk` hook against the live LiveKit publication and is
  asserted next door in `assets/test/hooks/meeting_push_to_talk.test.js`
  on MEASURED LEVELS and PUSHED EVENTS.

  What is asserted here is the server's half: that the control is on the
  page for a participant, that the waveform the hook paints into exists to
  be painted, and that its colour comes from semantic token slots.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
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

    conn = init_test_session(conn, current_user_id: user.id)

    {:ok, _view, html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true")

    %{html: html, user: user, meeting: meeting}
  end

  defp control(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-role='meeting-push-to-talk']")
  end

  test "the control renders in the meeting bar, wired to its hook", %{html: html} do
    nodes = control(html)
    assert Enum.count(nodes) == 1

    # The hook is the whole feature — the server renders an inert button
    # and every capture decision happens client-side. A control rendered
    # without its hook is a button that does nothing.
    assert nodes |> LazyHTML.attribute("phx-hook") |> List.first() == "MeetingPushToTalk"

    # The hook writes inline transforms onto the bars; without this, any
    # re-render during a press wipes the waveform mid-sentence.
    assert nodes |> LazyHTML.attribute("phx-update") |> List.first() == "ignore"
  end

  test "the waveform has bars for the hook to paint", %{html: html} do
    bars =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-role='meeting-push-to-talk'] [data-ptt-bar]")

    # Twelve, matching the hook's own expectation. Zero bars would leave
    # `_paintBars` a silent no-op and the level would be measured and then
    # thrown away.
    assert Enum.count(bars) == 12
  end

  test "it is reachable by keyboard and named for a screen reader", %{html: html} do
    nodes = control(html)

    assert nodes |> LazyHTML.attribute("type") |> List.first() == "button"

    label = nodes |> LazyHTML.attribute("aria-label") |> List.first()
    assert is_binary(label) and label != ""
  end

  test "its colour comes from semantic token slots, not raw hex or fixed palette",
       %{html: html} do
    markup = control(html) |> LazyHTML.to_html()

    refute Regex.match?(@raw_hex, markup),
           "push-to-talk control carries a raw hex colour: #{inspect(Regex.run(@raw_hex, markup))}"

    refute Regex.match?(@fixed_palette, markup),
           "push-to-talk control carries a fixed Tailwind palette colour: " <>
             "#{inspect(Regex.run(@fixed_palette, markup))}"

    # Positive control: the regexes above are only meaningful if they can
    # fire at all. If these ever stop matching, the two refutes above have
    # silently become unfalsifiable.
    assert Regex.match?(@raw_hex, ~s(<span class="text-[#ff0000]">))
    assert Regex.match?(@fixed_palette, ~s(<span class="bg-red-500">))

    # And it does use tokens, so "no hex" is not simply "no colour".
    assert markup =~ "primary"
    assert markup =~ "base-content"
  end
end
