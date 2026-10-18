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

  `colors_changeset/2` casts the seven in-app colour fields ONLY (task
  01a0dbee-f598-7001-b450-7890103f44c4), for the same reason in the other
  direction: saving the name form must never blank the colours, and saving
  the colours must never touch the name, the manifest colours or the icons.
  `identity_changeset/2` deliberately does not gain these fields.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Branding.Contrast
  alias Platform.Branding.Palette

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  # A web app manifest colour is a literal CSS colour. We accept only the
  # 6-digit hex form: shorthand (`#fff`) and named colours are legal CSS but
  # inconsistently honoured by installers, and a value the manifest parser
  # rejects silently falls back to a default splash rather than erroring.
  @hex_colour ~r/^#[0-9a-fA-F]{6}$/

  @app_colour_fields [
    :light_action,
    :light_surface,
    :light_accent,
    :dark_action,
    :dark_surface,
    :dark_accent
  ]

  @type t :: %__MODULE__{}

  schema "install_branding" do
    field(:singleton, :boolean, default: true)
    field(:app_name, :string)
    field(:theme_color, :string)
    field(:background_color, :string)
    field(:source_storage_key, :string)
    field(:derived, :map, default: %{})
    field(:version, :string)

    # In-app theme colours, lowercase `#rrggbb`. nil = Burrow default for that
    # slot. See `colors_changeset/2`.
    field(:light_action, :string)
    field(:light_surface, :string)
    field(:light_accent, :string)
    field(:dark_action, :string)
    field(:dark_surface, :string)
    field(:dark_accent, :string)
    field(:color_preset, :string)

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

  @doc "The six in-app colour fields `colors_changeset/2` normalises."
  @spec app_colour_fields() :: [atom()]
  def app_colour_fields, do: @app_colour_fields

  @doc """
  Changeset for the in-app theme colours. Casts ONLY the six colour fields and
  `color_preset`; see the moduledoc.

  Each colour accepts `#RGB` or `#RRGGBB`, with or without the `#`, and is
  stored as lowercase `#rrggbb`. A blank value casts to nil, which means
  "Burrow default" for that slot; an accent left nil follows the action colour.

  The palette each mode would render is then checked with
  `Platform.Branding.Palette.checks/2`, and every `:block` becomes a changeset
  error. That is the server-side refusal: a palette whose text would be
  unreadable cannot be saved even by a caller that bypasses the admin UI.
  Warnings are not errors; they are the UI's to show.
  """
  @spec colors_changeset(t(), map()) :: Ecto.Changeset.t()
  def colors_changeset(%__MODULE__{} = branding, attrs) do
    changeset =
      branding
      |> cast(attrs, [:color_preset | @app_colour_fields])
      |> validate_length(:color_preset, max: 64)

    changeset =
      Enum.reduce(@app_colour_fields, changeset, fn field, cs ->
        case get_change(cs, field) do
          nil ->
            cs

          value ->
            case Contrast.normalize_hex(value) do
              {:ok, hex} -> put_change(cs, field, hex)
              :error -> add_error(cs, field, "must be a hex colour like #1a2b3c")
            end
        end
      end)

    if changeset.valid?, do: validate_palette(changeset), else: changeset
  end

  # Which field a block is pinned to, so the form can show it next to the
  # input that caused it.
  @block_field %{
    body_text: :surface,
    link_text: :surface,
    button_text: :action,
    accent_text: :accent
  }

  defp validate_palette(changeset) do
    Enum.reduce([:light, :dark], changeset, fn mode, cs ->
      colours = %{
        action: get_field(cs, :"#{mode}_action"),
        surface: get_field(cs, :"#{mode}_surface"),
        accent: get_field(cs, :"#{mode}_accent")
      }

      mode
      |> Palette.checks(colours)
      |> Enum.filter(&(&1.level == :block))
      |> Enum.reduce(cs, fn check, acc ->
        slot = Map.get(@block_field, check.id, :surface)
        add_error(acc, :"#{mode}_#{slot}", check.message, check: check.id, mode: mode)
      end)
    end)
  end
end
