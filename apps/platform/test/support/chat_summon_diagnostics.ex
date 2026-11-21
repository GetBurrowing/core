defmodule Platform.ChatSummonDiagnostics do
  @moduledoc """
  Failure-only diagnostics for the tests that bring an agent into a channel
  as a root or org admin (`ChatLiveMembersTest`, `ChatLiveRefusedSummonTest`
  and `ChatLiveRoomAgentPickerTest`, the `root_admin` and `org_admin` cases).

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

  The second group says where the agent's and the actor's participant rows are
  if they are not in the expected space, and how many spaces share its slug. A
  lookup scoped to a different org could land the view on another space with
  the same slug, which these counts would show. They are evidence of location,
  not proof of which click wrote a row or of which space the view mounted.
  """

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Chat.Space
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
      end),
      "Where else the rows are (counts only; none of these names the space the view mounted, which is inferred from where the rows are):",
      line("agent participant rows in OTHER spaces", fn ->
        rows_elsewhere("agent", agent.id, space.id)
      end),
      line("actor participant rows in OTHER spaces", fn ->
        rows_elsewhere("user", actor.id, space.id)
      end),
      line("spaces sharing this space's slug (all orgs)", fn -> slug_spaces(space).total end),
      line("  of which is this space", fn -> slug_spaces(space).includes_this end),
      line("actor's first preloaded membership org is this space's org (a fresh read now)", fn ->
        first_membership_is_space_org?(actor, space)
      end)
    ]
    |> Enum.join("\n")
  end

  defp agent_row?(participant, agent),
    do: participant.participant_type == "agent" and participant.participant_id == agent.id

  defp rows_elsewhere(type, principal_id, space_id) do
    Repo.aggregate(
      from(p in Participant,
        where:
          p.participant_type == ^type and p.participant_id == ^principal_id and
            p.space_id != ^space_id
      ),
      :count
    )
  end

  defp slug_spaces(space) do
    ids = Repo.all(from(s in Space, where: s.slug == ^space.slug, select: s.id))
    %{total: length(ids), includes_this: space.id in ids}
  end

  # The preload that picks a session's active org is unordered, so this fresh
  # read need not match the membership a failed mount saw.
  defp first_membership_is_space_org?(actor, space) do
    case Tenancy.load_membership(Platform.Accounts.get_user(actor.id)) do
      %{org: %{id: org_id}} -> org_id == space.org_id
      _ -> false
    end
  end

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
