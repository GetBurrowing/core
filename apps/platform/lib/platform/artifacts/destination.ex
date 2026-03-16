defmodule Platform.Artifacts.Destination do
  @moduledoc """
  Behaviour implemented by artifact publishers.

  Destinations are intentionally isolated from execution control. Providers and
  run servers register artifacts, but publication is always delegated through a
  destination module so GitHub, preview routes, Docker registries, Drive, and
  canvas handoffs all share one contract.
  """

  alias Platform.Artifacts.Artifact

  @type publish_result :: {:ok, map()} | {:error, term()}

  @callback id() :: atom()
  @callback publish(Artifact.t(), keyword()) :: publish_result()
end
