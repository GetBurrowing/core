defmodule Platform.Memory.Provider do
  @moduledoc """
  Behaviour for memory-service provider adapters.

  A provider handles vector-based ingestion, search, and deletion of org
  memory entries against an external embedding/retrieval service. The
  default implementation (`Platform.Memory.Providers.StartupSuite`) targets
  the Startup Suite [memory-service](https://github.com/Startup-Suite/memory-service);
  a `Noop` provider is used when no service is configured so the app still
  starts and `append_memory_entry` + keyword search keep working.

  ## ADR 0042 scoping keys (Stage 4)

  Post-ADR-0042 (PR #438), entries and search opts carry `:project_id`
  (primary, nullable) and `:org_id` (tenant fallback, nullable). The
  legacy `:workspace_id` field is retained for back-compat — callers that
  still pass only `workspace_id` get a soft-deprecation `Logger.warning`
  one cycle. Removal is a follow-up; the provider behaviour will keep
  accepting the legacy key until every internal call site is migrated.
  """

  @type entry :: %{
          required(:id) => String.t(),
          required(:content) => String.t(),
          required(:date) => String.t() | Date.t(),
          optional(:memory_type) => String.t(),
          # @deprecated use :project_id instead. Retained for one
          # soft-deprecation cycle; callers that pass only this key
          # without :project_id surface a Logger.warning at runtime.
          optional(:workspace_id) => String.t() | nil,
          optional(:project_id) => String.t() | nil,
          optional(:org_id) => String.t() | nil,
          optional(:metadata) => map()
        }

  @type search_result :: %{entry_id: String.t(), score: float()}
  @type search_opts :: [
          # @deprecated — see entry doc above.
          workspace_id: String.t() | nil,
          project_id: String.t() | nil,
          org_id: String.t() | nil,
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
