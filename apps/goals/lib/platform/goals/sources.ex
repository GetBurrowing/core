defmodule Platform.Goals.Sources do
  @moduledoc "Registry of number sources; add a behaviour module and register it here."
  def all do
    Application.get_env(:goals, :sources, [
      Platform.Goals.Sources.SelfReported,
      Platform.Goals.Sources.TaskCount
    ])
  end

  def fetch(key) when is_binary(key) do
    case Enum.find(all(), &(&1.key() == key)) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  def fetch(_), do: :error
  def describe, do: Enum.map(all(), &%{key: &1.key(), label: &1.label(), kind: &1.kind()})
end
