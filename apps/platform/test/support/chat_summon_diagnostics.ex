defmodule Platform.ChatSummonDiagnostics do
  @moduledoc """
  Failure-only diagnostics for the tests that bring an agent into a channel
  as a root or org admin (`ChatLiveMembersTest` and `ChatLiveRefusedSummonTest`,
  the `root_admin` and `org_admin` cases).

  Those tests have failed on a first CI pass and passed on the serial retry,
  each time with a bare empty participant list and nothing to say why. The cause is not known.

  `describe/4` runs only AFTER an assertion has already failed, and is meant to
  be appended to that failure's message. Every line is an OBSERVATION taken
  after the failed action. It says what the database and the view show now, not
  what the action saw when it ran, so it can point at a cause but never proves
  one. Nothing here reads tokens, session data or message bodies: it reports
  booleans, counts, participant kinds and the text of the page's flash
  elements. Each observation is guarded, so a failing read is reported as
  "unavailable" and cannot hide the original failure.
  """

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo
  alias Platform.Tenancy

  @doc """
  The diagnostics text for a failed attempt by `actor` to bring `agent` into
  `space`, observed through `view` (the actor's LiveView).
  """
  @spec describe(struct(), %{id: binary()}, %{id: binary()}, term()) ::
          String.t()
  def describe(space, actor, agent, view) do
    participants =
      safe(fn -> Repo.all(from(p in Participant, where: p.space_id == ^space.id)) end)

    [
      "Observed AFTER the failed assertion; this is the state now, not necessarily what the action saw:",
      line("flash text on the page", fn -> flash_text(view) end),
      line("can_summon_agents?", fn -> Chat.can_summon_agents?(space, actor.id) end),
      line("root_admin?", fn -> Tenancy.root_admin?(%{id: actor.id}) end),
      line("org_admin? (space org)", fn -> Tenancy.org_admin?(%{id: actor.id}, space.org_id) end),
      line("external_user?", fn -> Tenancy.external_user?(%{id: actor.id}) end),
      line("agent in summonable_agents_query", fn ->
        space
        |> Chat.summonable_agents_query()
        |> where([a], a.id == ^agent.id)
        |> Repo.exists?()
      end),
      line("participant rows for this agent", fn ->
        count(participants, &agent_row?(&1, agent))
      end),
      line("participant rows in the space (all)", fn -> count(participants, fn _ -> true end) end),
      line("  of which agents", fn -> count(participants, &(&1.participant_type == "agent")) end),
      line("actor has a participant row", fn ->
        count(participants, &(&1.participant_type == "user" and &1.participant_id == actor.id)) >
          0
      end)
    ]
    |> Enum.join("\n")
  end

  defp agent_row?(participant, agent),
    do: participant.participant_type == "agent" and participant.participant_id == agent.id

  defp count(participants, fun) when is_list(participants), do: Enum.count(participants, fun)
  defp count(other, _fun), do: other

  defp flash_text(view) do
    view
    |> Phoenix.LiveViewTest.render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#flash-info, #flash-error")
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 200)
  end

  defp line(label, fun), do: "  #{label}: #{inspect(safe(fun))}"

  defp safe(fun) do
    fun.()
  rescue
    error -> {:unavailable, error.__struct__}
  catch
    kind, _reason -> {:unavailable, kind}
  end
end
