defmodule Platform.Branding.InstallBranding do
  @moduledoc """
  Schema for the `install_branding` singleton row — this install's PWA
  identity (task 01a0879a stage 1).

  One row, ever. `singleton` is pinned `true` by a DB CHECK and covered by
  a unique index; see the migration for why that is enforced in storage
  rather than by convention here.

  `identity_changeset/2` casts app name and colours ONLY. The icon columns
  (`source_storage_key`, `derived`, `version`) are written by the upload and
  derivation paths in later stages, never by the identity form — an admin
  editing the app name must not be able to blank the uploaded artwork by
  submitting a form that happens to omit those fields.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  # A web app manifest colour is a literal CSS colour. We accept only the
  # 6-digit hex form: shorthand (`#fff`) and named colours are legal CSS but
  # inconsistently honoured by installers, and a value the manifest parser
  # rejects silently falls back to a default splash rather than erroring.
  @hex_colour ~r/^#[0-9a-fA-F]{6}$/

  @type t :: %__MODULE__{}

  schema "install_branding" do
    field(:singleton, :boolean, default: true)
    field(:app_name, :string)
    field(:theme_color, :string)
    field(:background_color, :string)
    field(:source_storage_key, :string)
    field(:derived, :map, default: %{})
    field(:version, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for the admin-editable identity fields.
  """
  @spec identity_changeset(t(), map()) :: Ecto.Changeset.t()
  def identity_changeset(%__MODULE__{} = branding, attrs) do
    branding
    |> cast(attrs, [:app_name, :theme_color, :background_color])
    |> validate_required([:app_name, :theme_color, :background_color])
    |> validate_length(:app_name, min: 1, max: 60)
    |> validate_format(:theme_color, @hex_colour, message: "must be a 6-digit hex colour")
    |> validate_format(:background_color, @hex_colour, message: "must be a 6-digit hex colour")
  end
end
