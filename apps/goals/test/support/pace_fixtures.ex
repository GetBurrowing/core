defmodule Platform.Goals.PaceFixtures do
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  alias Platform.Goals.{Clock, Entry}
  import Ecto.Query
  alias Platform.Repo

  def ignore_brief(c, attrs \\ %{}) do
    ask = queued(c, attrs)
    {:ok, _} = Goals.prepare_brief(c.owner, date())
    advance()
    {:ok, _} = Goals.prepare_brief(c.owner, date())
    ask
  end

  def notices(goal),
    do:
      Repo.all(
        from(e in Entry,
          where: e.goal_id == ^goal.id and fragment("?->>'pace'", e.details) == "slowed"
        )
      )

  def with_limits(overrides) do
    old = Application.fetch_env(:goals, :limits)

    Application.put_env(
      :goals,
      :limits,
      Map.merge(Application.get_env(:goals, :limits, %{}), overrides)
    )

    ExUnit.Callbacks.on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:goals, :limits, value)
        :error -> Application.delete_env(:goals, :limits)
      end
    end)
  end

  def retro(c, details \\ %{}) do
    {:ok, entry} =
      Goals.add_entry(c.coach, c.goal.id, %{
        kind: "retro",
        title: "Looked back",
        body: "A useful review",
        occurred_at: Clock.now(),
        details:
          Map.merge(
            %{"verdicts" => [], "window" => %{"flat_retros" => 1}, "stalled" => false},
            details
          )
      })

    entry
  end
end

