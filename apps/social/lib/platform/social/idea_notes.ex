defmodule Platform.Social.IdeaNotes do
  @moduledoc """
  An idea's notes thread (Social authoring 7/11, task 01a16c50-ea67): the
  one writer and reader of `social_idea_notes`.

  Humans post from the idea detail on the Ideas tab; agents post with
  `social_idea_note_add` and read the thread in `social_idea_list`. The
  idea is read through the scope (`Platform.Social.Ideas.get/2`), so an
  idea of another org is `:not_found`, identical to a missing id. A human
  must be an approver of the idea's profile (`Platform.Social.approver_check/3`);
  the author is always the caller, never an argument.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Idea, IdeaNote, Ideas, Profile}

  @type author :: {:human, Ecto.UUID.t()} | {:agent, Ecto.UUID.t()}

  @doc """
  Adds a note by `author` to the idea `idea_id` (read through `scope`).

  Refusals, each writing nothing: `:not_found` (missing or out-of-scope
  idea), `:not_an_approver` (a human off the profile's approver list),
  `:body_required`, `:body_too_long` (over #{IdeaNote.max_body()}
  characters). An archived idea still takes notes.
  """
  @spec add(Social.scope(), term(), author(), term()) :: {:ok, IdeaNote.t()} | {:error, atom()}
  def add(scope, idea_id, author, body) do
    with {:ok, body} <- body(body),
         %Idea{} = idea <- Ideas.get(scope, idea_id) || {:error, :not_found},
         :ok <- may_write(idea, author) do
      {kind, id} = author

      %IdeaNote{idea_id: idea.id, author_kind: to_string(kind), author_id: id}
      |> IdeaNote.changeset(%{body: body})
      |> Repo.insert()
      |> case do
        {:ok, note} ->
          Ideas.broadcast_changed(idea.profile_id)
          {:ok, note}

        {:error, %Changeset{}} ->
          {:error, :body_too_long}
      end
    end
  end

  defp body(body) when is_binary(body) do
    case String.trim(body) do
      "" ->
        {:error, :body_required}

      trimmed ->
        if String.length(trimmed) > IdeaNote.max_body(),
          do: {:error, :body_too_long},
          else: {:ok, trimmed}
    end
  end

  defp body(_), do: {:error, :body_required}

  defp may_write(%Idea{} = idea, {:human, user_id}) when is_binary(user_id) do
    case Social.get_profile(idea.org_id, idea.profile_id) do
      %Profile{} = profile -> Social.approver_check(profile.org_id, profile, user_id)
      nil -> {:error, :not_found}
    end
    |> case do
      :ok -> :ok
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} -> {:error, :not_an_approver}
    end
  end

  defp may_write(%Idea{}, {:agent, agent_id}) when is_binary(agent_id), do: :ok
  defp may_write(_idea, _author), do: {:error, :not_an_approver}

  @doc "The idea's notes, oldest first."
  @spec list(Ecto.UUID.t()) :: [IdeaNote.t()]
  def list(idea_id), do: list_for_ideas([idea_id]) |> Map.get(idea_id, [])

  @doc "Notes for many ideas, `%{idea_id => [note]}`, each list oldest first."
  @spec list_for_ideas([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [IdeaNote.t()]}
  def list_for_ideas([]), do: %{}

  def list_for_ideas(idea_ids) do
    from(n in IdeaNote,
      where: n.idea_id in ^idea_ids,
      order_by: [asc: n.inserted_at, asc: n.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.idea_id)
  end
end
