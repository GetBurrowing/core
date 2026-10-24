defmodule Platform.Social.PostEvents do
  @moduledoc """
  The post change log's one writer and reader (Social authoring 2/11, task
  01a16c4e). Typefully's rule: the log says whether an agent or a human made
  each change.

  `record!/3` is called by the write paths themselves (`AgentDrafts`,
  `Approvals.decide_*`, `Publishing`, `ClipDecisions.approve_clip/5`,
  `Ideas.request_revision/4`), inside the transaction that changes the
  post, so the entry commits or rolls back with it. It raises on a bad
  entry, which rolls that transaction back: a state change is never logged
  half. It is deliberately NOT a telemetry handler (a raising handler is
  detached VM-wide).
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Social.{Post, PostEvent}

  @type actor :: {:agent, Ecto.UUID.t() | nil} | {:human, Ecto.UUID.t()} | :system

  @doc """
  Records `action` on `post` by `actor`. `opts`: `:note`, and for
  `edited` only, `:body_before` / `:body_after`. The idea is the post's.
  Call inside the transaction that wrote the post.
  """
  @spec record!(Post.t(), String.t(), actor(), keyword()) :: PostEvent.t()
  def record!(%Post{} = post, action, actor, opts \\ []) do
    {kind, id} = actor_fields(actor)

    attrs = %{
      post_id: post.id,
      idea_id: post.idea_id,
      actor_kind: kind,
      actor_id: id,
      action: action,
      note: Keyword.get(opts, :note)
    }

    attrs =
      if action == "edited",
        do:
          Map.merge(attrs, %{
            body_before: Keyword.get(opts, :body_before),
            body_after: Keyword.get(opts, :body_after)
          }),
        else: attrs

    event = %PostEvent{} |> PostEvent.changeset(attrs) |> Repo.insert!()
    broadcast(post)
    event
  end

  # Social authoring 7/11: the Ideas board re-derives its lanes on every
  # entry (`Platform.Social.Ideas.posts_topic/1`). Sent from inside the
  # writer's transaction; the board re-reads after a short delay.
  defp broadcast(%Post{account_id: account_id}) when is_binary(account_id) do
    from(a in Platform.Social.Account, where: a.id == ^account_id, select: a.profile_id)
    |> Repo.one()
    |> Platform.Social.Ideas.broadcast_changed()
  end

  defp broadcast(_post), do: :ok

  defp actor_fields({:agent, id}), do: {"agent", id}
  defp actor_fields({:human, id}) when is_binary(id), do: {"human", id}
  defp actor_fields(:system), do: {"system", nil}

  @doc "A post's events, oldest first."
  @spec list_for_post(Ecto.UUID.t()) :: [PostEvent.t()]
  def list_for_post(post_id), do: list_for_posts([post_id]) |> Map.get(post_id, [])

  @doc "Events for many posts, `%{post_id => [event]}`, each list oldest first."
  @spec list_for_posts([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [PostEvent.t()]}
  def list_for_posts([]), do: %{}

  def list_for_posts(post_ids) do
    from(e in PostEvent,
      where: e.post_id in ^post_ids,
      order_by: [asc: e.inserted_at, asc: e.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.post_id)
  end

  @doc """
  The open revision request among `events` (one post's, oldest first): the
  last `revision_requested` with no later agent `edited`, `submitted`,
  `approved` or `rejected` (a human's own edit leaves it open). Nil when
  none is open.
  """
  @spec open_revision([PostEvent.t()]) :: PostEvent.t() | nil
  def open_revision(events) do
    Enum.reduce(events, nil, fn
      %PostEvent{action: "revision_requested"} = e, _ -> e
      %PostEvent{action: "edited", actor_kind: "agent"}, _ -> nil
      %PostEvent{action: a}, _ when a in ~w(submitted approved rejected) -> nil
      _, open -> open
    end)
  end

  @doc "Whether `post_id` has an open revision request (`open_revision/1`)."
  @spec revision_open?(Ecto.UUID.t()) :: boolean()
  def revision_open?(post_id), do: post_id |> list_for_post() |> open_revision() != nil

  @doc """
  The agent that drafted `post`: its `generated_by_agent_id`, else the agent
  that recorded its `created` event. Nil when no agent drafted it.
  """
  @spec drafting_agent_id(Post.t()) :: Ecto.UUID.t() | nil
  def drafting_agent_id(%Post{generated_by_agent_id: id}) when is_binary(id), do: id

  def drafting_agent_id(%Post{id: post_id}) do
    Repo.one(
      from(e in PostEvent,
        where:
          e.post_id == ^post_id and e.action == "created" and e.actor_kind == "agent" and
            not is_nil(e.actor_id),
        order_by: [asc: e.inserted_at, asc: e.id],
        limit: 1,
        select: e.actor_id
      )
    )
  end
end
