defmodule Platform.Social.ClipVersions do
  @moduledoc """
  Immutable render snapshots and scoped history. Every render writer calls
  `append!/4` inside its transaction. The clip row lock serializes revision
  allocation and promotion, including writers using different render paths.
  Replacing the current file never deletes an older version's Files row.
  """
  import Ecto.Query
  alias Ecto.Changeset
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Clip, ClipRender}

  @doc "Recent versions, newest first; foreign clips and profiles are not found."
  def recent(scope, profile_id, clip_id, limit \\ 10) do
    with %{} <- Social.get_profile(scope, profile_id),
         %Clip{profile_id: ^profile_id} <- Social.get_clip(scope, clip_id) do
      {:ok,
       Repo.all(
         from(r in ClipRender,
           where: r.clip_id == ^clip_id and is_nil(r.removed_at),
           order_by: [desc: r.rev],
           limit: ^min(max(limit, 1), 50)
         )
       )}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "One selected version, with both org and profile scope enforced."
  def get(scope, profile_id, clip_id, version_id) do
    with {:ok, version_id} <- Ecto.UUID.cast(version_id),
         %{} <- Social.get_profile(scope, profile_id),
         %Clip{profile_id: ^profile_id} <- Social.get_clip(scope, clip_id),
         %ClipRender{} = render <-
           Repo.one(
             from(r in ClipRender,
               where: r.clip_id == ^clip_id and r.id == ^version_id and is_nil(r.removed_at)
             )
           ) do
      {:ok, render}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Append and promote under the clip lock. Caller owns the transaction."
  def append!(clip_id, file, attrs, snapshot) do
    unless Repo.in_transaction?(), do: raise("append! requires a transaction")
    clip = Repo.one!(from(c in Clip, where: c.id == ^clip_id, lock: "FOR UPDATE"))
    if clip.removed_at, do: Repo.rollback(:not_found)
    key = snapshot[:completion_key]

    duplicate =
      key &&
        Repo.exists?(
          from(r in ClipRender,
            where: r.clip_id == ^clip_id and r.completion_key == ^key
          )
        )

    if duplicate do
      clip
    else
      rev = next_rev(clip)

      clip =
        clip
        |> Clip.render_changeset(Map.take(attrs, ~w(status duration_s width height byte_size
          rendered_at error platforms start_s end_s requested_start_s requested_end_s)a))
        |> Changeset.change(Map.take(attrs, ~w(title caption speaker episode_code look
          trim_in_s trim_out_s source_label submitted_by_agent_id)a))
        |> Changeset.change(rev: rev, render_file_id: file.id, status: "rendered")
        |> Changeset.validate_length(:title, max: 200)
        |> Changeset.validate_length(:episode_code, max: 32)
        |> Clip.review_changeset(:reset_pending)
        |> update!()

      %ClipRender{}
      |> ClipRender.changeset(
        Map.merge(
          %{
            clip_id: clip.id,
            rev: rev,
            file_id: file.id,
            look: clip.look,
            trim_in_s: clip.trim_in_s,
            trim_out_s: clip.trim_out_s,
            duration_s: clip.duration_s,
            width: clip.width,
            height: clip.height,
            byte_size: file.byte_size,
            submitted_by_agent_id: clip.submitted_by_agent_id,
            snapshot_status: "recorded"
          },
          snapshot
        )
      )
      |> Repo.insert()
      |> case do
        {:ok, _render} -> clip
        {:error, cs} -> Repo.rollback(cs)
      end
    end
  end

  @doc "Next allocation includes removed snapshots, so deletion never reuses a revision."
  def next_rev(clip) do
    last = Repo.one(from(r in ClipRender, where: r.clip_id == ^clip.id, select: max(r.rev)))
    if last, do: max(last, clip.rev) + 1, else: clip.rev
  end

  defp update!(changeset) do
    case Repo.update(changeset) do
      {:ok, clip} -> clip
      {:error, cs} -> Repo.rollback(cs)
    end
  end

  @doc "Read-only tool representation, without Ecto metadata."
  def metadata(render) do
    render
    |> Map.from_struct()
    |> Map.drop([:__meta__, :clip, :file, :submitted_by_agent, :removed_by_user])
    |> Map.update!(:closing_video, fn
      nil -> nil
      snapshot -> Platform.Social.ClosingVideoSnapshot.dump(snapshot)
    end)
  end
end
