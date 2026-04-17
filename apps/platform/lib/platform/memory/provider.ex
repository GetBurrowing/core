defmodule Platform.Memory.Provider do
  @moduledoc """
  Behaviour for memory-service provider adapters.

  A provider handles vector-based ingestion, search, and deletion of org
  memory entries against an external embedding/retrieval service. The
  default implementation (`Platform.Memory.Providers.StartupSuite`) targets
  the Startup Suite [memory-service](https://github.com/Startup-Suite/memory-service);
  a `Noop` provider is used when no service is configured so the app still
  starts and `append_memory_entry` + keyword search keep working.
  """

  @type entry :: %{
          required(:id) => String.t(),
          required(:content) => String.t(),
          required(:date) => String.t() | Date.t(),
          optional(:memory_type) => String.t(),
          optional(:workspace_id) => String.t() | nil,
          optional(:metadata) => map()
        }

  @type search_result :: %{entry_id: String.t(), score: float()}
  @type search_opts :: [
          workspace_id: String.t() | nil,
          memory_type: String.t() | nil,
          date_from: String.t() | nil,
          date_to: String.t() | nil,
          limit: pos_integer()
        ]

  @callback ingest([entry()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback search(String.t(), search_opts(), keyword()) ::
              {:ok, [search_result()]} | {:error, term()}
  @callback delete([String.t()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback health(keyword()) :: :ok | {:error, term()}
end
