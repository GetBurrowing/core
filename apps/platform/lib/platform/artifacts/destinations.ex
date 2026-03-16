defmodule Platform.Artifacts.Destinations do
  @moduledoc """
  Built-in destination registry for the first artifact substrate pass.

  The concrete modules currently provide the shared contract and destination ids
  without hardwiring external APIs into the execution domain. Real adapter work
  can fill these modules in during follow-up tasks while the rest of the system
  already targets one stable publishing interface.
  """

  @builtin %{
    github: Platform.Artifacts.Destinations.GitHub,
    docker_registry: Platform.Artifacts.Destinations.DockerRegistry,
    google_drive: Platform.Artifacts.Destinations.GoogleDrive,
    preview_route: Platform.Artifacts.Destinations.PreviewRoute,
    canvas: Platform.Artifacts.Destinations.Canvas
  }

  @doc "Returns the built-in destination registry."
  @spec builtin() :: %{atom() => module()}
  def builtin, do: @builtin

  @doc "Resolves a destination id to its module, if known."
  @spec fetch(atom()) :: {:ok, module()} | {:error, :unknown_destination}
  def fetch(destination) when is_atom(destination) do
    case Map.fetch(@builtin, destination) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_destination}
    end
  end
end

defmodule Platform.Artifacts.Destinations.GitHub do
  @behaviour Platform.Artifacts.Destination
  def id, do: :github
  def publish(_artifact, _opts), do: {:error, {:unconfigured_destination, id()}}
end

defmodule Platform.Artifacts.Destinations.DockerRegistry do
  @behaviour Platform.Artifacts.Destination
  def id, do: :docker_registry
  def publish(_artifact, _opts), do: {:error, {:unconfigured_destination, id()}}
end

defmodule Platform.Artifacts.Destinations.GoogleDrive do
  @behaviour Platform.Artifacts.Destination
  def id, do: :google_drive
  def publish(_artifact, _opts), do: {:error, {:unconfigured_destination, id()}}
end

defmodule Platform.Artifacts.Destinations.PreviewRoute do
  @behaviour Platform.Artifacts.Destination
  def id, do: :preview_route
  def publish(_artifact, _opts), do: {:error, {:unconfigured_destination, id()}}
end

defmodule Platform.Artifacts.Destinations.Canvas do
  @behaviour Platform.Artifacts.Destination
  def id, do: :canvas
  def publish(_artifact, _opts), do: {:error, {:unconfigured_destination, id()}}
end
