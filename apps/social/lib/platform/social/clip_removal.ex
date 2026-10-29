defmodule Platform.Social.ClipRemoval do
  @moduledoc """
  Human-only removal from Review/Library. Tombstones retain immutable render
  identities, revision allocation, completion deduplication and Files retention.
  This operation never deletes posts, Files rows or storage bytes.
  """
  import Ecto.Query
  alias Ecto.Changeset
  alias Platform.{Repo, Social}
  alias Platform.Social.{Clip, ClipJob, ClipRender, ClipVersions, Post}

  def remove_clip(scope, profile_id, clip_id, user_id),
    do: remove(scope, profile_id, clip_id, nil, user_id)

  def remove_clip_render(scope, profile_id, clip_id, render_id, user_id) do
    with {:ok, id} <- Ecto.UUID.cast(render_id) do
      remove(scope, profile_id, clip_id, id, user_id)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Scoped history includes all selectable versions, not just the latest page."
  def history(scope, profile_id, clip_id) do
    with %Clip{profile_id: ^profile_id} <- Social.get_clip(scope, clip_id) do
      Repo.all(
        from(r in ClipRender,
          where: r.clip_id == ^clip_id and is_nil(r.removed_at),
          order_by: [desc: r.rev]
        )
      )
    else
      _ -> []
    end
  end

  @doc "Advisory UI reason only; writes recheck everything under the clip lock."
  def status(scope, profile_id, clip_id, render_id \\ nil) do
    with %Clip{profile_id: ^profile_id} = clip <- Social.get_clip(scope, clip_id),
         {:ok, targets} <- targets(scope, profile_id, clip, render_id) do
      eligible(clip, targets, is_nil(render_id))
    else
      _ -> {:error, :not_found}
    end
  end

  defp remove(scope, profile_id, clip_id, render_id, user_id) do
    with %Clip{profile_id: ^profile_id} = found <- Social.get_clip(scope, clip_id) do
      Repo.transaction(fn ->
        clip =
          Repo.one(
            from(c in Clip, where: c.id == ^found.id and is_nil(c.removed_at), lock: "FOR UPDATE")
          )

        if is_nil(clip), do: Repo.rollback(:not_found)
        profile = Social.get_profile(scope, profile_id)
        unless profile, do: Repo.rollback(:not_found)
        check!(Social.approver_check(profile.org_id, profile, user_id))
        targets = value!(targets(scope, profile_id, clip, render_id))
        check!(eligible(clip, targets, is_nil(render_id)))
        at = DateTime.utc_now()
        ids = Enum.map(targets, & &1.id)

        Repo.update_all(from(r in ClipRender, where: r.id in ^ids),
          set: [removed_at: at, removed_by_user_id: user_id]
        )

        clip =
          if is_nil(render_id),
            do: hide!(clip, at, user_id),
            else: fallback!(clip, targets, at, user_id)

        %{clip: clip, removed_clip?: not is_nil(clip.removed_at), render_id: render_id}
      end)
      |> case do
        {:ok, %{clip: clip}} = ok ->
          Social.broadcast_clip(clip)
          ok

        error ->
          error
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp targets(scope, profile_id, clip, nil),
    do: {:ok, history(scope, profile_id, clip.id)}

  defp targets(scope, profile_id, clip, render_id) do
    case ClipVersions.get(scope, profile_id, clip.id, render_id) do
      {:ok, render} -> {:ok, [render]}
      error -> error
    end
  end

  # No job locks here: completion locks job then clip. Taking job locks in the
  # reverse order would deadlock. Enqueue and completion share this clip lock;
  # a committed open job makes deletion refuse before it can race completion.
  defp eligible(clip, targets, whole?) do
    ids = Enum.map(targets, & &1.id)

    files =
      (Enum.map(targets, & &1.file_id) ++ if(whole?, do: [clip.render_file_id], else: []))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    current? = Enum.any?(targets, &(&1.rev == clip.rev))

    cond do
      clip.status == "rendering" or
          Repo.exists?(
            from(j in ClipJob,
              where: j.clip_id == ^clip.id and j.status in ~w(queued claimed running)
            )
          ) ->
        {:error, :job_in_flight}

      clip.reviewed_render_id in ids or
          ((whole? or current?) and
             (not is_nil(clip.reviewed_render_id) or clip.review_status == "approved")) ->
        {:error, :version_in_use}

      referenced?(clip, ids, files, whole?) ->
        {:error, :post_reference}

      true ->
        :ok
    end
  end

  defp referenced?(clip, ids, files, whole?) do
    Repo.exists?(
      from(p in Post,
        where:
          p.clip_render_id in ^ids or
            fragment("? && ?", p.media_file_ids, type(^files, {:array, :binary_id})) or
            p.cover_file_id in ^files or
            (p.clip_id == ^clip.id and (^whole? or is_nil(p.clip_render_id)))
      )
    )
  end

  defp fallback!(clip, targets, at, user_id) do
    if Enum.any?(targets, &(&1.rev == clip.rev)) do
      remaining =
        Repo.all(
          from(r in ClipRender,
            where: r.clip_id == ^clip.id and is_nil(r.removed_at) and not is_nil(r.file_id),
            order_by: [desc: r.rev]
          )
        )

      case Enum.find(remaining, &Platform.Files.get_file(&1.file_id)) do
        nil ->
          hide!(clip, at, user_id)

        render ->
          clip
          |> Clip.review_changeset(:reset_pending)
          |> Changeset.change(%{
            rev: render.rev,
            render_file_id: render.file_id,
            title: render.headline,
            caption: render.caption,
            look: render.look,
            trim_in_s: render.trim_in_s,
            trim_out_s: render.trim_out_s,
            duration_s: render.duration_s,
            width: render.width,
            height: render.height,
            byte_size: render.byte_size,
            status: "rendered"
          })
          |> Repo.update!()
      end
    else
      clip
    end
  end

  defp hide!(clip, at, user_id),
    do:
      clip
      |> Changeset.change(removed_at: at, removed_by_user_id: user_id)
      |> Repo.update!()

  defp check!(:ok), do: :ok
  defp check!({:error, reason}), do: Repo.rollback(reason)
  defp value!({:ok, value}), do: value
  defp value!({:error, reason}), do: Repo.rollback(reason)
end
