defmodule Platform.Social.ClosingVideoSnapshot do
  @moduledoc "Immutable closing contract, distinct from the mutable show setting (task 01a18ab6)."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    field(:file_id, Platform.Types.UUIDv7)
    field(:enabled, :boolean, default: false)
    field(:audio, Ecto.Enum, values: [:keep, :mute], default: :mute)
    field(:org_id, Platform.Types.UUIDv7)
    field(:project_id, Platform.Types.UUIDv7)
    field(:profile_id, Platform.Types.UUIDv7)
    field(:content_hash, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:duration_s, :float)
    field(:width, :integer)
    field(:height, :integer)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, __schema__(:fields))
    |> validate_required([:enabled, :audio, :org_id, :project_id, :profile_id])
    |> validate_number(:byte_size,
      greater_than: 0,
      less_than_or_equal_to: Platform.Social.ClipClosingVideo.max_bytes()
    )
    |> validate_number(:duration_s, greater_than: 0)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> then(fn cs ->
      if get_field(cs, :enabled),
        do:
          validate_required(cs, [
            :file_id,
            :content_hash,
            :content_type,
            :byte_size,
            :duration_s,
            :width,
            :height
          ]),
        else: cs
    end)
  end

  def dump(%__MODULE__{} = snapshot) do
    snapshot
    |> Map.from_struct()
    |> Map.new(fn {k, v} ->
      {to_string(k),
       if(is_atom(v) and not is_boolean(v) and not is_nil(v), do: to_string(v), else: v)}
    end)
  end
end
