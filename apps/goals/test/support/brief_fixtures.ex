defmodule Platform.Goals.BriefFixtures do
  import Platform.Goals.OutcomeFixtures
  alias Platform.Goals
  alias Platform.Goals.Clock

  def setup_brief do
    c = setup_outcome()
    # Brief/practice fixtures exercise check-in delivery separately from retros.
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{retro_every: 60})
    c = %{c | goal: goal}
    put_now(DateTime.add(c.goal.inserted_at, 86_400, :second))
    c
  end

  def date,
    do:
      Clock.now()
      |> DateTime.shift_zone!(Platform.Memory.Insights.Disseminator.timezone())
      |> DateTime.to_date()

  def advance(days \\ 1) do
    put_now(DateTime.add(Clock.now(), days * 86_400, :second))
    date()
  end

  def queued(c, attrs \\ %{}) do
    wake = fire(c.goal)
    {:ok, %{ask: ask}} = Goals.close_wake_up(c.coach, wake.id, "ask", ask_attrs(attrs))
    ask
  end

  def action(c, attrs \\ %{}) do
    {:ok, entry} =
      Goals.add_entry(
        c.coach,
        c.goal.id,
        Map.merge(
          %{kind: "action", title: "Drafted the outline", occurred_at: Clock.now()},
          attrs
        )
      )

    entry
  end

  def cards(n \\ 5),
    do: for(i <- 0..(n - 1), do: %{"front" => "Front #{i}", "back" => "Back #{i}"})

  def results(got, missed),
    do:
      Enum.map(got, &%{"index" => &1, "result" => "got"}) ++
        Enum.map(missed, &%{"index" => &1, "result" => "missed"})
end
