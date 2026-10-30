defmodule PlatformWeb.SocialWeeklyNoteTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  alias Platform.{Repo, Social}
  alias Platform.Social.{WeeklyNote, WeeklyNotes, Voice}

  setup do
    w = render_world!()
    {:ok, li} = Social.create_account(w.org_id, w.profile, %{platform: "linkedin"})
    today = DateTime.utc_now() |> DateTime.shift_zone!(w.profile.timezone) |> DateTime.to_date()
    %{w: w, li: li, week: Date.add(today, 1 - Date.day_of_week(today))}
  end

  defp note(w, week, items, attrs \\ %{}) do
    %WeeklyNote{org_id: w.org_id, profile_id: w.profile.id, author_kind: "system"}
    |> Ecto.Changeset.change(attrs)
    |> WeeklyNote.changeset(%{
      week_start: week,
      summary: String.duplicate("A useful weekly summary. ", 15),
      items: items
    })
    |> Repo.insert!()
  end

  defp voice,
    do: %{
      kind: "voice",
      text: "Questions worked better.",
      payload: %{text: "Lead with a concrete question."}
    }

  defp timing(li),
    do: %{
      kind: "timing",
      text: "Try Tuesday afternoon.",
      payload: %{account_id: li.id, weekday: 2, time: "14:00"}
    }

  defp open(conn, w, user \\ nil, query \\ "") do
    conn = Plug.Test.init_test_session(conn, current_user_id: (user || w.approver).id)
    {:ok, parent, _} = live(conn, "/m/social?tab=results&profile_id=#{w.profile.id}#{query}")
    find_live_child(parent, "ext-page-social")
  end

  defp click(view, action, note, item \\ nil),
    do:
      view
      |> with_target("#social-weekly-notes")
      |> render_click(action, %{"note" => note.id, "item" => if(item, do: item.id)})

  test "summary expands, voice use and undo show true attribution", %{conn: c, w: w, week: week} do
    note = note(w, week, [voice()])
    view = open(c, w)
    assert has_element?(view, "[data-role=system-author]", "Written by Burrow (system)")
    assert has_element?(view, "[data-role=weekly-note-summary].line-clamp-3")
    click(view, "summary", note)
    refute has_element?(view, "[data-role=weekly-note-summary].line-clamp-3")
    click(view, "use", note, hd(note.items))

    assert [%{text: "Lead with a concrete question."}] =
             Voice.of(Repo.reload!(w.profile)).learnings

    assert has_element?(view, "[data-role=weekly-note-decision]", "Used by #{w.approver.name}")
    click(view, "undo", note, hd(note.items))
    assert Voice.of(Repo.reload!(w.profile)).learnings == []
    refute has_element?(view, "[data-role=weekly-note-decision]")
  end

  test "timing requires inline confirmation, cancel writes nothing and confirm adds slot", %{
    conn: c,
    w: w,
    li: li,
    week: week
  } do
    note = note(w, week, [timing(li)])
    view = open(c, w)
    click(view, "confirm", note, hd(note.items))
    assert has_element?(view, "[role=alert]")
    assert Repo.reload!(li).posting_slots == []
    click(view, "use", note, hd(note.items))
    assert has_element?(view, "[data-role=weekly-note-consequence]", "Add Tue 14:00 to LinkedIn?")
    refute has_element?(view, "dialog")
    view |> element("#social-weekly-notes button", "Cancel") |> render_click()
    assert Repo.reload!(li).posting_slots == []
    click(view, "use", note, hd(note.items))
    click(view, "confirm", note, hd(note.items))
    assert [%{weekday: 2, time: "14:00"}] = Repo.reload!(li).posting_slots
    assert has_element?(view, "[data-role=weekly-note-decision]", "Used by")
  end

  test "read-only viewers have no controls and forged use cannot mutate", %{
    conn: c,
    w: w,
    week: week
  } do
    note = note(w, week, [voice()])
    viewer = member!(user!(), w.org_id)
    view = open(c, w, viewer)
    assert has_element?(view, "[data-role=weekly-note-consequence]", "Adds to brand voice")
    refute has_element?(view, "[data-role=weekly-note-actions]")
    click(view, "use", note, hd(note.items))
    assert Voice.of(Repo.reload!(w.profile)).learnings == []
    assert hd(Repo.reload!(note).items).decision == nil

    assert {:ok, _} =
             WeeklyNotes.decide(w.scope, note.id, hd(note.items).id, "ignore", w.approver.id)

    click(view, "summary", note)
    assert has_element?(view, "[data-role=weekly-note-decision]", "Ignored by")
    refute has_element?(view, "#social-weekly-notes button", "Undo")
  end

  test "empty current week leaves only collapsed history; expired undo absent", %{
    conn: c,
    w: w,
    week: week
  } do
    old = note(w, Date.add(week, -7), [voice()])

    assert {:ok, _} =
             WeeklyNotes.decide(w.scope, old.id, hd(old.items).id, "ignore", w.approver.id)

    view = open(c, w)
    refute has_element?(view, "[data-role=weekly-note]")

    assert has_element?(
             view,
             "[data-role=weekly-note-older] button[aria-expanded=false]",
             "0 used, 1 ignored"
           )

    click(view, "older", old)
    assert has_element?(view, "[data-role=weekly-note]")
    refute has_element?(view, "#social-weekly-notes button", "Undo")
  end

  test "no current note or history leaves no visible note block", %{conn: c, w: w} do
    view = open(c, w)
    assert has_element?(view, "#social-weekly-notes[hidden]")
    refute has_element?(view, "[data-role=weekly-note]")
    refute has_element?(view, "[data-role=weekly-note-older]")
  end

  test "All brands and scope switching exclude foreign notes; revoked access clears active component",
       %{conn: c, w: w, week: week} do
    note = note(w, week, [voice()])
    foreign = render_world!()
    secret = note(foreign, week, [voice()], %{summary: "Secret"})
    {:ok, p} = Social.create_profile(w.org_id, %{name: "Other visible brand"})
    other = note(%{w | profile: p}, week, [voice()])
    view = open(c, w)
    refute has_element?(view, "#weekly-note-#{other.id}")
    render_click(view, "switch_profile", %{"profile_id" => "all"})
    assert has_element?(view, "#weekly-note-#{note.id}")
    assert has_element?(view, "#weekly-note-#{other.id}")
    refute has_element?(view, "#weekly-note-#{secret.id}")
    click(view, "use", secret, hd(secret.items))
    assert hd(Repo.reload!(secret).items).decision == nil
    render_click(view, "switch_profile", %{"profile_id" => p.id})
    refute has_element?(view, "#weekly-note-#{note.id}")
    w.approver |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()
    click(view, "use", other, hd(other.items))
    refute has_element?(view, "[data-role=weekly-note]")
  end

  test "facts links use authorized profile_id and delivery week; foreign targets stay private", %{
    conn: c,
    w: w,
    week: week
  } do
    view = open(c, w, nil, "&weekly_note_week=#{week}&weekly_note_target=facts")
    assert has_element?(view, "[data-role=weekly-note-facts]", "0 published posts")
    assert has_element?(view, "[data-role=weekly-note-facts]", "Delivery week #{week}")
    foreign = render_world!()

    view =
      open(
        c,
        w,
        nil,
        "&profile=#{foreign.profile.id}&weekly_note_week=#{week}&weekly_note_target=facts"
      )

    refute has_element?(view, "[data-role=weekly-note-facts]")
  end

  test "old note deep link expands only an authorized note", %{conn: c, w: w, week: week} do
    old = note(w, Date.add(week, -7), [voice()], %{author_kind: "agent", author_id: w.agent.id})
    view = open(c, w, nil, "&weekly_note_week=#{old.week_start}&weekly_note_target=#{old.id}")
    assert has_element?(view, "#weekly-note-#{old.id}")
    assert has_element?(view, "[data-role=agent-author]", w.agent.name)
    click(view, "older", old)
    refute has_element?(view, "#weekly-note-#{old.id}")
  end

  test "unsafe undo retains the decision and gives a readable refusal", %{
    conn: c,
    w: w,
    week: week
  } do
    note = note(w, week, [voice()])
    view = open(c, w)
    click(view, "use", note, hd(note.items))
    profile = Repo.reload!(w.profile)
    [learning] = Voice.of(profile).learnings

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE social_profiles SET voice = jsonb_set(voice, '{learnings,0,text}', to_jsonb($2::text)) WHERE id = $1",
      [Ecto.UUID.dump!(profile.id), "A human edited this learning."]
    )

    assert hd(Voice.of(Repo.reload!(profile)).learnings).id == learning.id
    click(view, "undo", note, hd(note.items))

    assert render(view) |> Floki.parse_document!() |> Floki.find("[role=alert]") |> Floki.text() =~
             "Undo cannot safely remove it"

    assert has_element?(view, "[data-role=weekly-note-decision]", "Used by")
    assert [%{text: "A human edited this learning."}] = Voice.of(Repo.reload!(profile)).learnings
    assert hd(Repo.reload!(note).items).decision == "use"
  end
end
