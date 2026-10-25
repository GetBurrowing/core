defmodule Platform.Theming.OrgTheme do
  @moduledoc """
  An org's colour theme (task 01a1557a-fe9b stage 1), table `org_themes`.

  ## What it stores

    * `light` / `dark` — every key in `Platform.Theming.Tokens.color_keys/0`
      (the masters' theme keys that have an app slot), plus any of the
      optional slot overrides (`Tokens.override_slots/0`), each a lowercase
      `#rrggbb`. Input may be `#rgb`, any-case `#rrggbb`, or `oklch(L% C H)`;
      it is normalised to the painted `#rrggbb` (`WcagContrast.to_hex/1`, the
      8-bit value the compositor writes).
    * `shape` — `radius` (integer px, 4..28), `density` (0.8..1.3),
      `glass_alpha` (`glass_alpha_floor/0`..1), `glass_blur` (integer px,
      0..40) and `font` (one of the five chip stacks, or a stack matching
      `Tokens.font_format/0`).

  Unknown keys are refused, never dropped and never converted to atoms: the
  maps are string-keyed and checked against the lists above.

  ## The glass floor

  `glass_alpha_floor/0` is the lowest `--glass-alpha` any shipped non-High
  contrast variant declares, each of which is a painted, measured floor
  (`bottom_nav_glass_guard_test.exs`). An org palette has no painted fixture of
  its own, so its alpha may not go under the lowest one measured.

  `preset_id/1` is the id a person's theme preference names it by:
  `"org-" <> id`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Design.WcagContrast, as: W
  alias Platform.Theming.Tokens

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(draft published)
  @modes ~w(dark light)

  @radius 4..28
  @density {0.8, 1.3}
  @glass_alpha_floor 0.86
  @glass_blur 0..40

  @type t :: %__MODULE__{}

  schema "org_themes" do
    belongs_to(:org, Platform.Tenancy.Org)
    field(:name, :string)
    field(:status, :string, default: "draft")
    field(:default_mode, :string, default: "dark")
    field(:light, :map, default: %{})
    field(:dark, :map, default: %{})
    field(:shape, :map, default: %{})
    field(:published_at, :utc_datetime_usec)
    belongs_to(:published_by, Platform.Accounts.User)

    timestamps()
  end

  @doc "The lowest glass alpha an org theme may declare."
  def glass_alpha_floor, do: @glass_alpha_floor

  @doc "The preset id a theme preference names this theme by."
  @spec preset_id(t() | binary()) :: String.t()
  def preset_id(%__MODULE__{id: id}), do: preset_id(id)
  def preset_id(id) when is_binary(id), do: "org-" <> id

  @doc "Changeset for a draft's editable fields: name, default mode, palettes, shape."
  def changeset(theme, attrs) do
    theme
    |> cast(attrs, [:name, :default_mode, :light, :dark, :shape])
    |> validate_required([:org_id, :name, :status, :default_mode])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 80)
    |> validate_inclusion(:default_mode, @modes)
    |> validate_palette(:light)
    |> validate_palette(:dark)
    |> validate_shape()
    |> unique_constraint([:org_id, :name])
    |> foreign_key_constraint(:org_id)
    |> check_constraint(:status, name: :org_themes_status_check)
    |> check_constraint(:default_mode, name: :org_themes_default_mode_check)
  end

  @doc "Marks a theme published by `user_id` at `now`."
  def publish_changeset(theme, user_id, now) do
    theme
    |> change(status: "published", published_at: now, published_by_id: user_id)
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:status, name: :org_themes_status_check)
  end

  # ── palette ─────────────────────────────────────────────────────────────

  defp validate_palette(changeset, field) do
    palette = get_field(changeset, field) || %{}

    case normalise_palette(palette) do
      {:ok, normalised} -> put_change(changeset, field, normalised)
      {:error, message} -> add_error(changeset, field, message)
    end
  end

  @doc """
  Normalises a palette map: string keys, every colour key present, no key
  outside `Tokens.palette_keys/0` (the optional slot overrides are
  allowed), every value a lowercase `#rrggbb`. `{:ok, map}` or `{:error, message}`.
  """
  @spec normalise_palette(map()) :: {:ok, map()} | {:error, String.t()}
  def normalise_palette(palette) when is_map(palette) do
    with {:ok, palette} <- string_keys(palette),
         :ok <- known_keys(palette, Tokens.palette_keys()),
         :ok <- all_keys(palette, Tokens.color_keys()) do
      Enum.reduce_while(palette, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case normalise_color(value) do
          {:ok, hex} -> {:cont, {:ok, Map.put(acc, key, hex)}}
          {:error, why} -> {:halt, {:error, "#{key}: #{why}"}}
        end
      end)
    end
  end

  def normalise_palette(_), do: {:error, "must be a map"}

  @doc """
  One colour, normalised to lowercase `#rrggbb`. Accepts `#rgb`, `#rrggbb`
  (any case) and `oklch(L% C H)`; an oklch value becomes the 8-bit sRGB it
  paints as.
  """
  @spec normalise_color(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalise_color(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    cond do
      Regex.match?(~r/^#[0-9a-f]{6}$/, value) ->
        {:ok, value}

      Regex.match?(~r/^#[0-9a-f]{3}$/, value) ->
        <<"#", r, g, b>> = value
        {:ok, <<"#", r, r, g, g, b, b>>}

      Regex.match?(~r/^oklch\(\s*[\d.]+%\s+[\d.]+\s+[\d.]+\s*\)$/, value) ->
        try do
          {:ok, value |> W.parse!() |> W.to_hex() |> String.downcase()}
        rescue
          ArgumentError -> {:error, "is not a colour"}
        end

      true ->
        {:error, "must be #rgb, #rrggbb or oklch(L% C H)"}
    end
  end

  def normalise_color(_), do: {:error, "must be a string"}

  # ── shape ───────────────────────────────────────────────────────────────

  defp validate_shape(changeset) do
    case normalise_shape(get_field(changeset, :shape) || %{}) do
      {:ok, shape} -> put_change(changeset, :shape, shape)
      {:error, message} -> add_error(changeset, :shape, message)
    end
  end

  @doc "Normalises a shape map. `{:ok, map}` or `{:error, message}`."
  @spec normalise_shape(map()) :: {:ok, map()} | {:error, String.t()}
  def normalise_shape(shape) when is_map(shape) do
    with {:ok, shape} <- string_keys(shape),
         :ok <- known_keys(shape, Tokens.shape_keys()),
         :ok <- all_keys(shape, Tokens.shape_keys()),
         {:ok, radius} <- integer_in(shape["radius"], @radius, "radius"),
         {:ok, density} <- number_in(shape["density"], @density, "density"),
         {:ok, alpha} <- number_in(shape["glass_alpha"], {@glass_alpha_floor, 1.0}, "glass_alpha"),
         {:ok, blur} <- integer_in(shape["glass_blur"], @glass_blur, "glass_blur"),
         {:ok, font} <- font(shape["font"]) do
      {:ok,
       %{
         "radius" => radius,
         "density" => density,
         "glass_alpha" => alpha,
         "glass_blur" => blur,
         "font" => font
       }}
    end
  end

  def normalise_shape(_), do: {:error, "must be a map"}

  defp integer_in(value, range, key) do
    case to_number(value) do
      {:ok, n} when n == trunc(n) ->
        if trunc(n) in range,
          do: {:ok, trunc(n)},
          else: {:error, "#{key} must be #{range.first}..#{range.last}"}

      _ ->
        {:error, "#{key} must be a whole number"}
    end
  end

  defp number_in(value, {lo, hi}, key) do
    case to_number(value) do
      {:ok, n} when n >= lo and n <= hi -> {:ok, n / 1}
      {:ok, _} -> {:error, "#{key} must be #{lo}..#{hi}"}
      :error -> {:error, "#{key} must be a number"}
    end
  end

  defp to_number(n) when is_integer(n) or is_float(n), do: {:ok, n}

  defp to_number(text) when is_binary(text) do
    case Float.parse(String.trim(text)) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp to_number(_), do: :error

  defp font(value) when is_binary(value) do
    value = String.trim(value)

    if value in Tokens.font_chips() or Regex.match?(Tokens.font_format(), value),
      do: {:ok, value},
      else: {:error, "font must be a chip stack or match #{inspect(Tokens.font_format().source)}"}
  end

  defp font(_), do: {:error, "font must be a string"}

  # ── keys ────────────────────────────────────────────────────────────────

  # Atom keys are read as their names (Atom.to_string); a string never
  # becomes an atom.
  defp string_keys(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {k, v}, {:ok, acc} when is_binary(k) -> {:cont, {:ok, Map.put(acc, k, v)}}
      {k, v}, {:ok, acc} when is_atom(k) -> {:cont, {:ok, Map.put(acc, Atom.to_string(k), v)}}
      {k, _}, _ -> {:halt, {:error, "key #{inspect(k)} is not a name"}}
    end)
  end

  defp known_keys(map, allowed) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> {:error, "unknown keys: #{Enum.join(Enum.sort(unknown), ", ")}"}
    end
  end

  defp all_keys(map, required) do
    case required -- Map.keys(map) do
      [] -> :ok
      missing -> {:error, "missing keys: #{Enum.join(missing, ", ")}"}
    end
  end
end
