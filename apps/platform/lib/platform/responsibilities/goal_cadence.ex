defmodule Platform.Responsibilities.GoalCadence do
  @moduledoc """
  The ONE place a human cadence ("Once a day") and a cron `trigger_config`
  meet (task 01a0e882 stage 2).

  The UI and the write API speak in cadences; the Router speaks cron.
  Nothing outside this module builds a cron string from a cadence or
  reads one back, so the UI never has to print or accept an expression.

  Cadences:

    * `:hourly` — `0 * * * *`
    * `:every_4h` — `0 */4 * * *`
    * `:twice_daily` — `0 0,12 * * *`
    * `:daily` — `0 H * * *`, `H` the UTC hour in `0..23`
    * `:off` — `enabled: false`; the stored expression is kept as it was

  Every config `to_trigger/3` writes for an ON cadence carries
  `"cadence"`, `"hour_utc"` (daily only) and `"operator_set" => true`.
  The marker is what makes `Platform.Responsibilities.upsert_by_key/1`
  keep the config across the boot-time re-registration instead of
  reverting it to the provider's declared default.

  `from_row/1` reads a row back. A stored expression that none of the
  cadences produce reads as `:custom`, which the UI renders by name only.
  """

  alias Platform.Responsibilities.Responsibility

  @cadences [:hourly, :every_4h, :twice_daily, :daily, :off]

  @fixed_expressions %{
    hourly: "0 * * * *",
    every_4h: "0 */4 * * *",
    twice_daily: "0 0,12 * * *"
  }

  @daily_regex ~r/\A0 (\d{1,2}) \* \* \*\z/

  @type cadence :: :hourly | :every_4h | :twice_daily | :daily | :off
  @type reading :: %{cadence: cadence() | :custom, hour_utc: 0..23 | nil}

  @doc "The five settable cadences, in display order."
  @spec cadences() :: [cadence()]
  def cadences, do: @cadences

  @doc """
  Build the `%{enabled, trigger_config}` attrs for `cadence`.

  `hour_utc` is required for `:daily` (an integer in `0..23`) and ignored
  otherwise. `current_config` is the row's existing `trigger_config`;
  only `:off` reads it, returning it unchanged so the expression survives
  and turning the cadence back on is a plain write.
  """
  @spec to_trigger(cadence(), integer() | nil, map()) ::
          {:ok, %{enabled: boolean(), trigger_config: map()}}
          | {:error, :bad_hour | :bad_cadence}
  def to_trigger(cadence, hour_utc \\ nil, current_config \\ %{})

  def to_trigger(:off, _hour_utc, current_config) when is_map(current_config) do
    {:ok, %{enabled: false, trigger_config: current_config}}
  end

  def to_trigger(:daily, hour_utc, _current_config)
      when is_integer(hour_utc) and hour_utc in 0..23 do
    {:ok,
     %{
       enabled: true,
       trigger_config: %{
         "expression" => "0 #{hour_utc} * * *",
         "cadence" => "daily",
         "hour_utc" => hour_utc,
         "operator_set" => true
       }
     }}
  end

  def to_trigger(:daily, _hour_utc, _current_config), do: {:error, :bad_hour}

  def to_trigger(cadence, _hour_utc, _current_config)
      when is_map_key(@fixed_expressions, cadence) do
    {:ok,
     %{
       enabled: true,
       trigger_config: %{
         "expression" => Map.fetch!(@fixed_expressions, cadence),
         "cadence" => Atom.to_string(cadence),
         "operator_set" => true
       }
     }}
  end

  def to_trigger(_cadence, _hour_utc, _current_config), do: {:error, :bad_cadence}

  @doc """
  Read a row's cadence. `enabled == false` is `:off` whatever the config
  says. Otherwise the stored `"cadence"` is trusted only when it agrees
  with the stored expression; the expression is what the Router actually
  runs, so a hand-edited row reads as what it will do. An expression no
  cadence produces is `:custom`.
  """
  @spec from_row(Responsibility.t()) :: reading()
  def from_row(%Responsibility{enabled: false}), do: %{cadence: :off, hour_utc: nil}

  def from_row(%Responsibility{trigger_config: config}) when is_map(config) do
    expression = Map.get(config, "expression") || Map.get(config, :expression)
    from_expression(normalize(expression))
  end

  def from_row(%Responsibility{}), do: %{cadence: :custom, hour_utc: nil}

  @doc "Human words for a cadence. Never a cron string."
  @spec label(cadence() | :custom) :: String.t()
  def label(:hourly), do: "Every hour"
  def label(:every_4h), do: "Every 4 hours"
  def label(:twice_daily), do: "Twice a day"
  def label(:daily), do: "Once a day"
  def label(:off), do: "Off"
  def label(:custom), do: "Custom schedule"

  defp normalize(expression) when is_binary(expression) do
    expression |> String.split(~r/\s+/, trim: true) |> Enum.join(" ")
  end

  defp normalize(_), do: nil

  defp from_expression(nil), do: %{cadence: :custom, hour_utc: nil}

  defp from_expression(expression) do
    fixed = Enum.find(@fixed_expressions, fn {_cadence, expr} -> expr == expression end)

    cond do
      fixed != nil ->
        %{cadence: elem(fixed, 0), hour_utc: nil}

      match = Regex.run(@daily_regex, expression) ->
        case Integer.parse(Enum.at(match, 1)) do
          {hour, ""} when hour in 0..23 -> %{cadence: :daily, hour_utc: hour}
          _ -> %{cadence: :custom, hour_utc: nil}
        end

      true ->
        %{cadence: :custom, hour_utc: nil}
    end
  end
end
