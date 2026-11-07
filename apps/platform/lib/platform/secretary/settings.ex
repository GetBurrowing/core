defmodule Platform.Secretary.Settings do
  @moduledoc """
  A person's settings for the triage agent, stored under
  `users.preferences["secretary"]` (task 01a1b721 stage 1).

  The defaults carry the sponsor's three calls of 2026-11-07, each one a
  setting rather than a constant:

    * `urgent_takes_top` (true): an urgent new item takes the top slot of the
      brief; between two urgent items the sooner deadline wins.
    * `interrupt_level` ("goals"): what may interrupt, one of
      `urgent | goals | anything`.
    * `hold_in_meetings` (true) and `evening_read_at` ("20:00"): reach-outs
      are held while the person is in a meeting, and FYIs are held for the
      evening read.

  Plus `time_zone` (IANA, validated against Tzdata), `family_placement`
  (`brief_and_list | list_only | off`), `family_private` (always true, and
  NOT settable to false: family items never leave the person's own view),
  `daily_token_ceiling` (nil means "use the experiment surface's payload")
  and `max_nudges_per_hour`.

  `get/1` merges the stored map over the defaults, so a key added later has
  its default for every existing person. `put/2` validates every key and
  refuses an unknown one; it never writes a partial map.
  """

  alias Platform.Accounts
  alias Platform.Accounts.User

  @preference_key "secretary"

  @defaults %{
    "urgent_takes_top" => true,
    "interrupt_level" => "goals",
    "hold_in_meetings" => true,
    "evening_read_at" => "20:00",
    "time_zone" => "Etc/UTC",
    "family_placement" => "brief_and_list",
    "family_private" => true,
    "daily_token_ceiling" => nil,
    "max_nudges_per_hour" => 3
  }

  @interrupt_levels ~w(urgent goals anything)
  @family_placements ~w(brief_and_list list_only off)

  @doc "The `users.preferences` key the settings live under."
  @spec preference_key() :: String.t()
  def preference_key, do: @preference_key

  @doc "The defaults, string-keyed."
  @spec defaults() :: map()
  def defaults, do: @defaults

  @doc "The interrupt levels `interrupt_level` accepts."
  @spec interrupt_levels() :: [String.t()]
  def interrupt_levels, do: @interrupt_levels

  @doc "The values `family_placement` accepts."
  @spec family_placements() :: [String.t()]
  def family_placements, do: @family_placements

  @doc """
  The person's settings: the stored map merged over the defaults. Takes a
  `%User{}` (no query) or a user id. A stored value that no longer validates
  falls back to its default rather than reaching a caller.
  """
  @spec get(User.t() | binary()) :: map()
  def get(%User{preferences: prefs}), do: from_preferences(prefs)

  def get(user_id) when is_binary(user_id),
    do: from_preferences(Accounts.get_user_preferences(user_id))

  defp from_preferences(prefs) do
    stored =
      case prefs do
        %{@preference_key => %{} = map} -> map
        _ -> %{}
      end

    Enum.reduce(@defaults, %{}, fn {key, default}, acc ->
      value = Map.get(stored, key, default)
      Map.put(acc, key, if(valid?(key, value), do: value, else: default))
    end)
  end

  @doc """
  Validates `changes` (string or atom keys) and merges them into the stored
  settings. `{:ok, settings}` with the merged, defaulted map, or
  `{:error, reasons}` with nothing written. Unknown keys are refused, and so
  is `family_private: false`.
  """
  @spec put(binary(), map()) :: {:ok, map()} | {:error, [String.t()] | :not_found}
  def put(user_id, changes) when is_binary(user_id) and is_map(changes) do
    changes = Map.new(changes, fn {k, v} -> {to_string(k), v} end)

    case errors(changes) do
      [] ->
        stored =
          case Accounts.get_user_preferences(user_id) do
            %{@preference_key => %{} = map} -> map
            _ -> %{}
          end

        case Accounts.update_user_preference(user_id, @preference_key, Map.merge(stored, changes)) do
          {:ok, %User{} = user} -> {:ok, get(user)}
          {:error, :not_found} -> {:error, :not_found}
          {:error, _changeset} -> {:error, ["could not save settings"]}
        end

      errors ->
        {:error, errors}
    end
  end

  defp errors(changes) do
    unknown = changes |> Map.keys() |> Enum.reject(&Map.has_key?(@defaults, &1)) |> Enum.sort()

    unknown_errors = if unknown == [], do: [], else: ["unknown keys: #{Enum.join(unknown, ", ")}"]

    value_errors =
      changes
      |> Enum.filter(fn {key, _} -> Map.has_key?(@defaults, key) end)
      |> Enum.reject(fn {key, value} -> valid?(key, value) end)
      |> Enum.map(fn {key, _} -> message(key) end)
      |> Enum.sort()

    unknown_errors ++ value_errors
  end

  defp valid?("urgent_takes_top", v), do: is_boolean(v)
  defp valid?("interrupt_level", v), do: v in @interrupt_levels
  defp valid?("hold_in_meetings", v), do: is_boolean(v)
  defp valid?("evening_read_at", v), do: clock?(v)
  defp valid?("time_zone", v), do: is_binary(v) and Tzdata.zone_exists?(v)
  defp valid?("family_placement", v), do: v in @family_placements
  defp valid?("family_private", v), do: v == true
  defp valid?("daily_token_ceiling", v), do: is_nil(v) or (is_integer(v) and v > 0)
  defp valid?("max_nudges_per_hour", v), do: is_integer(v) and v >= 0 and v <= 60
  defp valid?(_key, _value), do: false

  defp clock?(v) when is_binary(v) do
    Regex.match?(~r/\A\d{2}:\d{2}\z/, v) and match?({:ok, _}, Time.from_iso8601(v <> ":00"))
  end

  defp clock?(_v), do: false

  defp message("urgent_takes_top"), do: "urgent_takes_top must be a boolean"
  defp message("interrupt_level"), do: "interrupt_level must be one of: urgent, goals, anything"
  defp message("hold_in_meetings"), do: "hold_in_meetings must be a boolean"
  defp message("evening_read_at"), do: "evening_read_at must be a 24-hour HH:MM time"
  defp message("time_zone"), do: "time_zone must be an IANA time zone"

  defp message("family_placement"),
    do: "family_placement must be one of: brief_and_list, list_only, off"

  defp message("family_private"), do: "family_private cannot be turned off"

  defp message("daily_token_ceiling"),
    do: "daily_token_ceiling must be null or a positive integer"

  defp message("max_nudges_per_hour"), do: "max_nudges_per_hour must be an integer in 0..60"
end
