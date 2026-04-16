defmodule Platform.Memory.Provider do
  @moduledoc """
  Behaviour for external memory service providers.

  Providers handle indexing and semantic search over org memory entries.
  The main application stores entries in Postgres; providers maintain an
  external index (e.g. vector embeddings) for richer search capabilities.

  See ADR 0033 for architecture details.
  """

  @type entry :: %{
          id: binary(),
          content: String.t(),
          memory_type: String.t(),
          date: Date.t(),
          workspace_id: binary() | nil,
          metadata: map() | nil
        }

  @type search_result :: %{entry_id: binary(), score: float()}

  @callback ingest(entry()) :: :ok | {:error, term()}
  @callback search(query :: String.t(), opts :: keyword()) ::
              {:ok, [search_result()]} | {:error, term()}
  @callback delete(entry_id :: binary()) :: :ok | {:error, term()}

  @doc "Returns the currently configured memory provider module."
  def configured do
    Application.get_env(:platform, :memory_provider, Platform.Memory.Providers.Null)
  end
end
