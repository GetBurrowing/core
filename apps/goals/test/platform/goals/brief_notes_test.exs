defmodule Platform.Goals.BriefNotesTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.BriefFixtures
  import Platform.Goals.PaceFixtures
  alias Platform.Goals
  alias Platform.Goals.{Clock, BriefItem}
  setup do: setup_brief()

  test "one retro reaches exactly one owner brief, can be noted, never reaches audience", c do
    reader = member!(c.org)
    Goals.open_goal(c.owner, c.goal.id, {:user, reader.id})
    entry = retro(c)
    day = date()
    assert {:ok, %{new: 1}} = Goals.prepare_brief(c.owner, day)
    assert {:ok, %{new: 0}} = Goals.prepare_brief(c.owner, day)
    assert {:ok, [item]} = Goals.brief_items(c.owner, day)
    assert item.kind == :retro
    assert item.entry.id == entry.id
    assert item.state == :open
    assert {:ok, _} = Goals.set_report_noted(c.owner, item.id, true)
    assert {:ok, [done]} = Goals.brief_items(c.owner, day)
    assert done.state == :done
    advance()
    assert {:ok, %{new: 0}} = Goals.prepare_brief(c.owner, date())
    assert {:ok, %{new: 0}} = Goals.prepare_brief(reader, day)
    assert {:ok, []} = Goals.brief_items(reader, day)
    assert Repo.aggregate(from(i in BriefItem, where: i.entry_id == ^entry.id), :count) == 1
  end

  test "a change is directly after its retro and remains a call until decided", c do
    entry =
      retro(c, %{
        "check_in_change" => %{"summary" => "Fewer days", "set" => %{"rhythm" => "weekdays"}}
      })

    day = date()
    Goals.prepare_brief(c.owner, day)
    assert {:ok, [review, change]} = Goals.brief_items(c.owner, day)
    assert review.kind == :retro
    assert change.kind == :retro_change
    assert change.change.state == :open
    assert {:ok, %{calls: 1}} = Goals.brief_summary(c.owner, day)
    Repo.insert!(%Platform.Memory.Briefing{user_id: c.owner.id, digest_date: day, items: %{}})
    Platform.Inbox.subscribe(c.owner.id)
    assert {:ok, _} = Goals.decide_retro_change(c.owner, c.goal.id, entry.id, "keep")
    assert_receive {:inbox_changed, user_id}
    assert user_id == c.owner.id
    assert {:ok, [_, change]} = Goals.brief_items(c.owner, day)
    assert change.state == :done
    assert change.change.state == :kept
    assert {:ok, %{calls: 0}} = Goals.brief_summary(c.owner, day)
  end

  test "report pace comes from expected pace and is nil without a measurable due stop", c do
    today = Clock.now() |> DateTime.to_date()
    start = DateTime.add(Clock.now(), -40, :day)
    Goals.log_reading(c.owner, c.goal.id, %{value: 500, measured_at: start})

    {:ok, [stop]} =
      Goals.put_stops(c.owner, c.goal.id, [
        %{label: "Finish", target_value: 1000, due_on: Date.add(today, 60)}
      ])

    Goals.log_reading(c.owner, c.goal.id, %{value: 699, measured_at: Clock.now()})
    action(c)
    day = date()
    Goals.prepare_brief(c.owner, day)
    assert {:ok, [item]} = Goals.brief_items(c.owner, day)
    assert item.pace == :behind
    put_now(DateTime.add(Clock.now(), 1))
    Goals.log_reading(c.owner, c.goal.id, %{value: 700, measured_at: Clock.now()})
    assert {:ok, [item]} = Goals.brief_items(c.owner, day)
    assert item.pace == :on_track
    Goals.update_stop(c.owner, c.goal.id, stop.id, %{due_on: nil})
    assert {:ok, [item]} = Goals.brief_items(c.owner, day)
    assert item.pace == nil
    Goals.update_goal(c.owner, c.goal.id, %{source_key: nil})
    assert {:ok, [item]} = Goals.brief_items(c.owner, day)
    assert item.number == nil
    assert item.pace == nil
  end

  test "personal notes and pacing are hidden from other users, admin and non-coach agent", c do
    for _ <- 1..3, do: ignore_brief(c)
    retro(c)
    Goals.prepare_brief(c.owner, date())
    admin = root_admin!()

    for actor <- [member!(c.org), admin, agent!()] do
      assert {:error, :not_found} = Goals.clock_status(actor, c.goal.id)
      assert {:ok, []} = Goals.brief_items(actor, date())
      assert {:ok, %{new: 0}} = Goals.prepare_brief(actor, date())
    end
  end
end
