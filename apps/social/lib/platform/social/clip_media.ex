defmodule Platform.Social.ClipMedia do
  @moduledoc """
  The facts core's Files does not store about a rendered clip (Social 5/7):
  `platform_files` has no duration or dimensions, so the clip row carries
  them, and a post that attaches the render gets them copied into its
  `media_meta` (member 2's column) where `Platform.Social.MediaRules` reads
  them at publish.

  `meta_for/2` answers only for files that are a RENDERED clip's
  `render_file_id` in the given profile; any other file id is simply absent
  from the map (its facts stay unknown, as before).
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Social.Clip

  @doc "`%{file_id => %{\"duration_s\", \"width\", \"height\"}}` for the profile's rendered clips."
  @spec meta_for(Ecto.UUID.t() | nil, [Ecto.UUID.t()] | nil) :: %{String.t() => map()}
  def meta_for(nil, _file_ids), do: %{}
  def meta_for(_profile_id, nil), do: %{}
  def meta_for(_profile_id, []), do: %{}

  def meta_for(profile_id, file_ids) when is_list(file_ids) do
    ids =
      Enum.flat_map(file_ids, fn id ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> [uuid]
          :error -> []
        end
      end)

    from(c in Clip,
      where: c.profile_id == ^profile_id and c.status == "rendered" and c.render_file_id in ^ids,
      select: {c.render_file_id, c.duration_s, c.width, c.height}
    )
    |> Repo.all()
    |> Map.new(fn {file_id, duration_s, width, height} ->
      {file_id, %{"duration_s" => duration_s, "width" => width, "height" => height}}
    end)
  end

  @doc """
  Merges the rendered-clip facts for a changeset's `media_file_ids` into its
  `media_meta`, keeping any facts already there for other files.
  """
  @spec put_media_meta(Ecto.Changeset.t(), Ecto.UUID.t() | nil) :: Ecto.Changeset.t()
  def put_media_meta(%Ecto.Changeset{} = changeset, profile_id) do
    ids = Ecto.Changeset.get_field(changeset, :media_file_ids) || []

    case meta_for(profile_id, ids) do
      meta when meta == %{} ->
        changeset

      meta ->
        existing = Ecto.Changeset.get_field(changeset, :media_meta) || %{}
        Ecto.Changeset.put_change(changeset, :media_meta, Map.merge(existing, meta))
    end
  end
end
