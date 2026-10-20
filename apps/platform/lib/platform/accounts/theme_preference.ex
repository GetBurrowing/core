defmodule Platform.Accounts.ThemePreference do
  @moduledoc """
  The registry of theme presets and modes a person can choose (task 01a1557a,
  Burrow redesign 2, stage 1).

  This module is the single list of presets. Later stages (the pre-paint
  script, the stylesheet, the settings picker) read it from here rather than
  keeping a second copy in JS or CSS.

  Stored on the user as `users.preferences["theme"] = %{"preset" => id,
  "mode" => mode}` through `Platform.Accounts.put_theme_preference/2`. No
  migration: `users.preferences` has been a JSONB column since
  `20260519134626_add_preferences_to_users`.

  ## Why five presets, not six

  The design masters ship `burrow-dark` and `burrow-light`, which differ only
  in their default mode. Direction canvas `01a1585a` (rule 1) collapses them
  into one `burrow` row plus the Mode control, so mode is a separate field.
  """

  @presets [
    %{id: "burrow", name: "Burrow"},
    %{id: "burrow-midnight", name: "Burrow midnight"},
    %{id: "burrow-sand", name: "Burrow sand"},
    %{id: "burrow-forest", name: "Burrow forest"},
    %{id: "high-contrast", name: "High contrast"}
  ]

  @preset_ids Enum.map(@presets, & &1.id)

  @modes ["light", "dark", "system"]

  @default %{"preset" => "burrow", "mode" => "dark"}

  @type t :: %{required(String.t()) => String.t()}

  @doc "Presets in display order, as `[%{id, name}]`."
  @spec presets() :: [%{id: String.t(), name: String.t()}]
  def presets, do: @presets

  @doc "Preset ids in display order."
  @spec preset_ids() :: [String.t()]
  def preset_ids, do: @preset_ids

  @doc "The modes a preset can be shown in."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc "The preference a person with no stored choice gets."
  @spec default() :: t()
  def default, do: @default

  @doc """
  The preset app.css paints with its own daisyUI blocks (task 01a1557a stage
  3). It declares no block in `theme_presets.css`, so it is the one preset
  that is shown by carrying NO `data-preset` attribute on `<html>`.
  """
  @spec base_preset() :: String.t()
  def base_preset, do: "burrow"

  @doc "Whether `id` names a registered preset."
  @spec valid_preset?(term()) :: boolean()
  def valid_preset?(id), do: id in @preset_ids

  @doc "Whether `mode` names a registered mode."
  @spec valid_mode?(term()) :: boolean()
  def valid_mode?(mode), do: mode in @modes

  @doc """
  Coerce any stored value into a full, valid preference.

  Lenient, for reads: each field that is missing or unregistered falls back to
  its default independently, so a stored `%{"preset" => "burrow-sand"}` keeps
  its preset and gains the default mode. Anything that is not a map yields
  `default/0`. Atom keys are accepted.
  """
  @spec normalize(term()) :: t()
  def normalize(value) when is_map(value) do
    preset = fetch(value, "preset")
    mode = fetch(value, "mode")

    %{
      "preset" => if(valid_preset?(preset), do: preset, else: @default["preset"]),
      "mode" => if(valid_mode?(mode), do: mode, else: @default["mode"])
    }
  end

  def normalize(_), do: @default

  @doc """
  Strict check, for writes. Merges `attrs` over `current` and returns
  `{:ok, preference}` only when every field `attrs` supplies is registered.
  A field `attrs` leaves out keeps its `current` value. Returns
  `{:error, :invalid}` for an unregistered preset or mode, an unknown key, or
  a non-map.
  """
  @spec validate(term(), t()) :: {:ok, t()} | {:error, :invalid}
  def validate(attrs, current \\ @default)

  def validate(attrs, current) when is_map(attrs) do
    stringified = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    current = normalize(current)

    cond do
      Map.keys(stringified) -- ["preset", "mode"] != [] ->
        {:error, :invalid}

      Map.has_key?(stringified, "preset") and not valid_preset?(stringified["preset"]) ->
        {:error, :invalid}

      Map.has_key?(stringified, "mode") and not valid_mode?(stringified["mode"]) ->
        {:error, :invalid}

      true ->
        {:ok, Map.merge(current, stringified)}
    end
  end

  def validate(_attrs, _current), do: {:error, :invalid}

  defp fetch(map, "preset"), do: Map.get(map, "preset", Map.get(map, :preset))
  defp fetch(map, "mode"), do: Map.get(map, "mode", Map.get(map, :mode))
end
