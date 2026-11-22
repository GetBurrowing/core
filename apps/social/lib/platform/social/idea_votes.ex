defmodule Platform.Social.IdeaVotes do
  @moduledoc """
  Agent-only votes and author-only agent archiving. Historical human votes
  remain stored but do not count toward summaries, ordering or shortlisting. Actor IDs come from the
  authenticated caller, never tool arguments. Profile then idea locks serialize
  votes, withdrawals and archive; authority is read again after both locks.
  """
  import Ecto.Query

  alias Platform.{Repo, Social}
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Social.{Idea, Ideas, IdeaVote, Post, Profile}

  def vote(scope, id, actor, opts \\ [])
  def vote(scope, id, {:agent, _} = actor, opts), do: mutate(scope, id, actor, :vote, opts)
  def vote(_, _, _, _), do: {:error, :agent_only}
  def unvote(scope, id, actor, opts \\ [])
  def unvote(scope, id, {:agent, _} = actor, opts), do: mutate(scope, id, actor, :unvote, opts)
  def unvote(_, _, _, _), do: {:error, :agent_only}
  def archive(scope, id, actor, opts \\ [])
  def archive(scope, id, {:agent, _} = actor, opts), do: mutate(scope, id, actor, :archive, opts)
  def archive(_, _, _, _), do: {:error, :not_idea_author}

  @doc "Vote summaries for ideas the caller has already read through its visible profiles. Only count and the current actor's vote are returned."
  def summaries(ideas, actor \\ nil)
  def summaries([], _actor), do: %{}

  def summaries(ideas, actor) do
    ids = Enum.map(ideas, & &1.id)

    votes =
      Repo.all(from(v in IdeaVote, where: v.idea_id in ^ids and not is_nil(v.voter_agent_id)))

    by_idea = Enum.group_by(votes, & &1.idea_id)

    Map.new(ideas, fn idea ->
      rows =
        Enum.filter(
          Map.get(by_idea, idea.id, []),
          &(&1.profile_id == idea.profile_id and
              &1.org_id == idea.org_id)
        )

      voted =
        Enum.any?(rows, fn vote ->
          (not is_nil(vote.voter_user_id) and vote.voter_user_id == actor_id(actor, :user)) or
            (not is_nil(vote.voter_agent_id) and vote.voter_agent_id == actor_id(actor, :agent))
        end)

      {idea.id, %{vote_count: length(rows), voted: voted}}
    end)
  end

  @doc "Votes shortlist only the Inbox; post-derived stages always take precedence."
  def stage(posts, count) do
    case Ideas.stage(posts) do
      "inbox" when count >= 3 -> "shortlisted"
      stage -> stage
    end
  end

  @doc "Inbox and shortlist order: votes descending, then oldest timestamp and id."
  def order_key(idea, count),
    do: {-count, DateTime.to_unix(idea.inserted_at, :microsecond), idea.id}

  defp mutate(scope, id, actor, operation, opts) do
    with %Idea{} = initial <- Ideas.get(scope, id) do
      result =
        Repo.transaction(fn ->
          with %Profile{} = profile <- Social.lock_profile(scope, initial.profile_id, :share),
               %Idea{} = idea <-
                 Repo.one(from(i in Idea, where: i.id == ^initial.id, lock: "FOR UPDATE")),
               true <- idea.profile_id == profile.id and idea.org_id == profile.org_id,
               true <- allowed?(profile, actor),
               :ok <- Keyword.get(opts, :authorize, fn _ -> :ok end).(profile),
               :ok <- eligible(idea, actor, operation) do
            case operation do
              :archive ->
                if Repo.exists?(from(p in Post, where: p.idea_id == ^idea.id)),
                  do: Repo.rollback(:idea_has_posts)

                idea |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()
                %{idea_id: idea.id, archived: true}

              :vote ->
                Repo.insert!(
                  %IdeaVote{
                    idea_id: idea.id,
                    org_id: idea.org_id,
                    profile_id: idea.profile_id,
                    voter_user_id: actor_id(actor, :user),
                    voter_agent_id: actor_id(actor, :agent)
                  },
                  on_conflict: :nothing
                )

                result(idea.id, actor)

              :unvote ->
                idea.id |> actor_votes(actor) |> Repo.delete_all()
                result(idea.id, actor)
            end
          else
            {:error, reason} -> Repo.rollback(reason)
            _ -> Repo.rollback(:not_found)
          end
        end)

      if match?({:ok, _}, result), do: Ideas.broadcast_changed(initial.profile_id)
      result
    else
      _ -> {:error, :not_found}
    end
  end

  defp eligible(idea, actor, :archive) do
    if actor_id(actor, :agent) == idea.created_by_agent_id,
      do: :ok,
      else: {:error, :not_idea_author}
  end

  defp eligible(%Idea{archived_at: at}, _actor, _) when not is_nil(at),
    do: {:error, :idea_archived}

  defp eligible(idea, actor, _) do
    if (actor_id(actor, :user) == idea.created_by_user_id and not is_nil(idea.created_by_user_id)) or
         (actor_id(actor, :agent) == idea.created_by_agent_id and
            not is_nil(idea.created_by_agent_id)), do: {:error, :own_idea}, else: :ok
  end

  defp actor_id({kind, id}, kind), do: id
  defp actor_id(_, _), do: nil

  defp actor_votes(id, {:user, user_id}),
    do: from(v in IdeaVote, where: v.idea_id == ^id and v.voter_user_id == ^user_id)

  defp actor_votes(id, {:agent, agent_id}),
    do: from(v in IdeaVote, where: v.idea_id == ^id and v.voter_agent_id == ^agent_id)

  defp result(id, actor),
    do: %{
      idea_id: id,
      vote_count:
        Repo.aggregate(
          from(v in IdeaVote, where: v.idea_id == ^id and not is_nil(v.voter_agent_id)),
          :count
        ),
      voted: Repo.exists?(actor_votes(id, actor))
    }

  @doc "Current actor access to the profile; no cached actor or caller-supplied org can widen it."
  def allowed?(%Profile{} = profile, {:user, id}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %User{archived_at: nil} = user <- Repo.get(User, id),
         true <-
           Platform.Access.module_access?(
             Platform.Access.Scope.for_user(user),
             :social,
             "social.use"
           ) do
      Enum.any?(Social.list_profiles_for_user(user), &(&1.id == profile.id))
    else
      _ -> false
    end
  end

  def allowed?(%Profile{} = profile, {:agent, id}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Agent{status: status} = agent <- Repo.get(Agent, id),
         true <- status != "archived" do
      case agent.metadata["org_id"] || agent.metadata[:org_id] do
        nil ->
          true

        org_id ->
          case Ecto.UUID.cast(org_id) do
            {:ok, org_id} ->
              case Repo.get(Platform.Tenancy.Org, org_id) do
                %{parent_org_id: nil} -> true
                %{} -> org_id == profile.org_id
                _ -> false
              end

            _ ->
              false
          end
      end
    else
      _ -> false
    end
  end

  def allowed?(_, _), do: false
end
