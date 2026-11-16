defmodule Platform.Goals.SpaceClaim do
  @moduledoc """
  Whether Goals drives a chat space's goal (task 01a1dfc1-dffb, Goals 7/8
  stage 4). Read by core through `Platform.Goals.Extension.claims_space_goal?/1`
  and `Platform.Extensions.space_goal_claimed?/1`; a claimed space no longer
  gets core's old single-goal heartbeat.

  A space is claimed while at least one goal whose status is "active" is
  opened to it (a `goal_grants` row of audience "space"). A paused or
  finished goal does not claim: it produces no stream of updates, and the
  space would otherwise get neither.

  This is the second actor-less query in apps/goals/lib, beside
  `Platform.Goals.Clock.due/2`. It returns a boolean and nothing else, so it
  tells core nothing about which goal or who can see it. With the switch off
  or an id that is not a UUID it answers false at once and runs no query; a
  query that raises is logged and answers false, which leaves core's own
  behaviour in place.
  """

  import Ecto.Query

  require Logger

  alias Platform.Goals.{Goal, Grant}
  alias Platform.Repo

  @doc "True while an active goal is opened to the space `space_id`."
  @spec claimed?(term()) :: boolean()
  def claimed?(space_id) do
    with true <- Platform.Goals.enabled?(),
         {:ok, id} <- Ecto.UUID.cast(space_id) do
      exists?(id)
    else
      _ -> false
    end
  end

  defp exists?(id) do
    Repo.exists?(
      from(gr in Grant,
        join: g in Goal,
        on: g.id == gr.goal_id,
        where: gr.audience_type == "space" and gr.space_id == ^id and g.status == "active"
      )
    )
  rescue
    error ->
      Logger.warning("[goals] space claim query raised: " <> Exception.message(error))
      false
  end
end
