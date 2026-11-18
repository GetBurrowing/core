defmodule Platform.Goals.Source do
  @moduledoc """
  A source names the population behind a goal's number without reading goal tables.
  Invalid settings return `{:cannot_measure, reason}` with only an atom reason.
  Sources never substitute a different population or return zero for an unread count.
  """
  @callback key() :: String.t()
  @callback label() :: String.t()
  @callback kind() :: :logged | :measured
  @callback population(Platform.Goals.Goal.t()) :: {:ok, String.t()} | {:cannot_measure, atom()}
  @callback measure(Platform.Goals.Goal.t()) ::
              {:ok,
               %{value: Decimal.t() | integer(), unit: String.t() | nil, population: String.t()}}
              | {:cannot_measure, atom()}
  @optional_callbacks measure: 1
end
