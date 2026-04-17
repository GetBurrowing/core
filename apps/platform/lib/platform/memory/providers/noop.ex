defmodule Platform.Memory.Providers.Noop do
  @moduledoc """
  No-op memory provider used when `MEMORY_SERVICE_URL` is not configured.

  `ingest` and `delete` succeed with `0` so callers don't need to branch
  on whether a memory service is wired up. `search` returns an empty list
  (callers fall back to keyword search). `health` returns an error so
  operators can detect the missing configuration.
  """

  @behaviour Platform.Memory.Provider

  @impl true
  def ingest(_entries, _config), do: {:ok, 0}

  @impl true
  def search(_query, _opts, _config), do: {:ok, []}

  @impl true
  def delete(_entry_ids, _config), do: {:ok, 0}

  @impl true
  def health(_config), do: {:error, :not_configured}
end
