defmodule Platform.Responsibilities.Handlers.Dreaming do
  @moduledoc """
  `memory.dreaming` responsibility provider (ADR-0041 M8 stage 2).

  Implements the M1 `Platform.Responsibilities.Provider` behaviour for
  the 03:00 UTC "dreaming" run that consolidates recent journal entries
  into long-term curated knowledge. Historically lived in
  `Platform.Agents.SystemEventScheduler`'s legacy `dreaming` event
  (collapsed into `historian` by T6), now owns its own responsibility
  row so an agent can be assigned to "curate org memory overnight"
  independently of the broader historian bundle.

  ## Spec

    * `key` — `"memory.dreaming"`
    * `feature` — `"memory"`
    * `trigger_kind` — `cron` with `expression: "0 3 * * *"` (03:00 UTC daily)
    * `scope` — `per_org`
    * `context_provided` — `["recent_journal", "org_identity"]`

  ## Output handling

  `handle_output/3` upserts the parsed LLM response into the
  `org/page/memory.md` context file via
  `Platform.Org.Context.upsert_file/1`. The plan calls for
  "optimistic-lock retry"; `upsert_file/1` is itself a single
  transaction with a version bump and returns `{:error, ...}` on
  Postgres unique-violation. We retry once on transient conflicts to
  cover the narrow window where two concurrent dreamers (e.g. dev +
  staging restart races) both land at 03:00.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Org.Context, as: OrgContext
  alias Platform.Responsibilities.ContextProviders
  alias Platform.Responsibilities.Responsibility

  @key "memory.dreaming"
  @memory_file_key "org/page/memory.md"
  @max_retries 1

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "The org context file key this handler writes to."
  @spec memory_file_key() :: String.t()
  def memory_file_key, do: @memory_file_key

  # ── Provider callbacks ─────────────────────────────────────────────────────

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: "memory",
        trigger_kind: "cron",
        # 03:00 UTC daily — preserves the legacy SystemEventScheduler
        # `dreaming` event timing.
        trigger_config: %{"expression" => "0 3 * * *"},
        scope: "per_org",
        context_provided: ["recent_journal", "org_identity"],
        output_contract: %{"memory_body" => "string"},
        default_prompt_template: "memory.dreaming.v1",
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.memory",
          "legacy_event" => "dreaming",
          "target_file_key" => @memory_file_key
        }
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{} = _responsibility, ctx) when is_map(ctx) do
    opts =
      case Map.get(ctx, :workspace_id) || Map.get(ctx, "workspace_id") do
        nil -> []
        ws_id -> [workspace_id: ws_id]
      end

    with {:ok, %{recent_journal: journal}} <-
           ContextProviders.gather_context(:recent_journal, opts),
         {:ok, %{org_identity: identity}} <-
           ContextProviders.gather_context(:org_identity, opts) do
      {:ok, %{recent_journal: journal, org_identity: identity}}
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed) do
    # Behaviour-required arity-2; Router prefers the 3-arity variant.
    handle_output(responsibility, parsed, %{kind: :unknown})
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    with {:ok, body} <- extract_body(parsed) do
      upsert_with_retry(responsibility, body, trigger_meta, @max_retries)
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp extract_body(%{"memory_body" => text}) when is_binary(text) and text != "",
    do: {:ok, text}

  defp extract_body(%{memory_body: text}) when is_binary(text) and text != "", do: {:ok, text}
  defp extract_body(%{"summary" => text}) when is_binary(text) and text != "", do: {:ok, text}
  defp extract_body(%{summary: text}) when is_binary(text) and text != "", do: {:ok, text}
  defp extract_body(text) when is_binary(text) and text != "", do: {:ok, text}

  defp extract_body(other) do
    Logger.warning(
      "[memory.dreaming] handler rejected output — expected %{memory_body: string}; got " <>
        inspect(other)
    )

    {:error, :invalid_output_shape}
  end

  defp upsert_with_retry(%Responsibility{} = responsibility, body, trigger_meta, retries_left) do
    updated_by = Map.get(trigger_meta, :updated_by) || Map.get(trigger_meta, "updated_by")

    attrs = %{
      file_key: @memory_file_key,
      content: body,
      updated_by: updated_by
    }

    case OrgContext.upsert_file(attrs) do
      {:ok, file} ->
        Logger.info(
          "[memory.dreaming] upserted #{@memory_file_key} version=#{file.version} " <>
            "responsibility=#{responsibility.key}"
        )

        :ok

      {:error, _reason} when retries_left > 0 ->
        Logger.warning(
          "[memory.dreaming] upsert conflict — retrying " <>
            "responsibility=#{responsibility.key} retries_left=#{retries_left}"
        )

        upsert_with_retry(responsibility, body, trigger_meta, retries_left - 1)

      {:error, reason} ->
        Logger.warning(
          "[memory.dreaming] upsert failed after retries: #{inspect(reason)} " <>
            "responsibility=#{responsibility.key}"
        )

        {:error, {:upsert_failed, reason}}
    end
  end
end
