defmodule Platform.Memory.Providers.Null do
  @moduledoc """
  No-op memory provider. Returns empty results and silently accepts ingests.

  This is the default provider when no external memory service is configured.
  """

  @behaviour Platform.Memory.Provider

  @impl true
  def ingest(_entry), do: :ok

  @impl true
  def search(_query, _opts), do: {:ok, []}

  @impl true
  def delete(_entry_id), do: :ok
end
