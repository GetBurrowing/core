defmodule Platform.Secretary.Context do
  @moduledoc """
  What the triage agent knows about the person it works for (task 01a1b721
  stage 1): their role and profile, their goals, and, when those features
  are present, their habits and recent handoffs.

  ## Optional inputs are read, never re-implemented

    * **Profile** — `Platform.People.who_is/3` on the person's OWN card (the
      roster entry whose `user_id` is theirs), with their own Scope, so the
      private tier is included only when the generic readers rule shows it to
      them. Nobody else's card is read.
    * **Goals** — `Space.goal` of every space they are a participant of.
      `Space.goals` (an array of up to three, task 01a1b6de) is read ONLY
      when `:goals in Platform.Chat.Space.__schema__(:fields)`. Keys are
      `"space_goal:<space_id>:<index>"`.
    * **Habits** — read ONLY when `Code.ensure_loaded?(Platform.Habits)`
      (task 01a1b6a1), through `apply/3` so `--warnings-as-errors` holds
      while the module is absent.
    * **Handoffs** — the per-agent manners task 01a1b733 ships prompt
      rules, not a data module. The module named below is read only when it
      exists, by the same `apply/3` rule; today it does not.

  Never blocks on any of them, and never fails because one is missing.
  """

  import Ecto.Query

  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Chat.{Participant, Space}
  alias Platform.Repo

  @habits_module Platform.Habits
  @handoffs_module Platform.Agents.Handoffs

  @type goal :: %{
          key: String.t(),
          space_id: Ecto.UUID.t(),
          space_name: String.t() | nil,
          text: String.t()
        }
  @type t :: %{profile: map() | nil, goals: [goal()], habits: term(), handoffs: term()}

  @doc "The person's context. See the moduledoc for each part."
  @spec for_user(User.t()) :: t()
  def for_user(%User{id: user_id} = user) when is_binary(user_id) do
    scope = Scope.for_user(user)

    %{
      profile: profile(user, scope),
      goals: goals(user_id),
      habits: optional(@habits_module, :list_patterns, [user_id]),
      handoffs: optional(@handoffs_module, :recent_for_user, [user_id])
    }
  end

  @doc "The goal key for a space's goal at `index`."
  @spec goal_key(Ecto.UUID.t(), non_neg_integer()) :: String.t()
  def goal_key(space_id, index), do: "space_goal:#{space_id}:#{index}"

  @doc "Does this build carry the `Space.goals` array (task 01a1b6de)?"
  @spec goals_field?() :: boolean()
  def goals_field?, do: :goals in Space.__schema__(:fields)

  defp profile(%User{id: user_id}, scope) do
    case Enum.find(Platform.People.Pages.roster(nil), &(&1.user_id == user_id)) do
      %{slug: slug} ->
        case Platform.People.who_is(slug, scope) do
          %{} = profile -> profile
          _ -> nil
        end

      nil ->
        nil
    end
  end

  defp goals(user_id) do
    from(s in Space,
      join: p in Participant,
      on: p.space_id == s.id,
      where:
        p.participant_type == "user" and p.participant_id == ^user_id and is_nil(s.archived_at),
      order_by: [asc: s.inserted_at, asc: s.id]
    )
    |> Repo.all()
    |> Enum.flat_map(&space_goals/1)
  end

  defp space_goals(%Space{} = space) do
    texts =
      case goals_field?() and Map.get(space, :goals) do
        [_ | _] = list -> list
        _ -> [space.goal]
      end

    texts
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.take(3)
    |> Enum.with_index()
    |> Enum.map(fn {text, index} ->
      %{key: goal_key(space.id, index), space_id: space.id, space_name: space.name, text: text}
    end)
  end

  defp optional(module, function, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)),
      do: apply(module, function, args),
      else: nil
  end
end
