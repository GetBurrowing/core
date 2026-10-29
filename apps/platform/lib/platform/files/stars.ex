defmodule Platform.Files.Stars do
  @moduledoc """
  Explicit, idempotent personal stars with private session invalidation.
  All reads reauthorize targets; soft deletion retains the bookmark for Undo.
  """
  import Ecto.Query
  alias Platform.Files.{Browser, BrowserActions, Star}
  alias Platform.Repo

  def topic(user_id), do: "files:stars:#{user_id}"

  def subscribe(actor) do
    with {:ok, viewer} <- BrowserActions.viewer(actor) do
      Phoenix.PubSub.subscribe(Platform.PubSub, topic(viewer.user.id))
    end
  end

  def set(actor, target, starred?) when is_boolean(starred?) do
    with {:ok, viewer} <- BrowserActions.viewer(actor),
         {:ok, _source} <- Browser.fetch_source(viewer, target),
         {:ok, field, id} <- target_field(target) do
      result =
        if starred? do
          %Star{}
          |> Star.changeset(%{field => id, :user_id => viewer.user.id})
          |> Repo.insert(on_conflict: :nothing)
        else
          Repo.delete_all(
            from(s in Star, where: s.user_id == ^viewer.user.id and field(s, ^field) == ^id)
          )

          {:ok, nil}
        end

      case result do
        {:ok, _} ->
          Phoenix.PubSub.broadcast(
            Platform.PubSub,
            topic(viewer.user.id),
            {:stars_changed, target}
          )

          :ok

        error ->
          error
      end
    end
  end

  def set(_actor, _target, _starred?), do: {:error, :invalid_action}

  def starred?(actor, target) do
    with {:ok, viewer} <- BrowserActions.viewer(actor),
         {:ok, _} <- Browser.fetch_source(viewer, target),
         {:ok, field, id} <- target_field(target) do
      Repo.exists?(
        from(s in Star, where: s.user_id == ^viewer.user.id and field(s, ^field) == ^id)
      )
    else
      _ -> false
    end
  end

  def list_items(actor, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    with {:ok, viewer} <- BrowserActions.viewer(actor) do
      items =
        from(s in Star,
          where: s.user_id == ^viewer.user.id,
          order_by: [desc: s.inserted_at, desc: s.id]
        )
        |> Repo.all()
        |> Enum.reduce_while([], fn star, acc ->
          case Browser.fetch_item(viewer, target(star)) do
            {:ok, item} when length(acc) < limit + 1 -> {:cont, [item | acc]}
            {:ok, _} -> {:halt, acc}
            _ -> {:cont, acc}
          end
        end)
        |> Enum.reverse()

      %{items: Enum.take(items, limit), capped?: length(items) > limit}
    else
      _ -> %{items: [], capped?: false}
    end
  end

  defp target(%{canvas_id: id}) when is_binary(id), do: {:canvas, id}
  defp target(%{file_id: id}) when is_binary(id), do: {:file, id}
  defp target(%{attachment_id: id}), do: {:space_file, id}

  defp target_field({:canvas, id}), do: {:ok, :canvas_id, id}
  defp target_field({:file, id}), do: {:ok, :file_id, id}
  defp target_field({:space_file, id}), do: {:ok, :attachment_id, id}
end
