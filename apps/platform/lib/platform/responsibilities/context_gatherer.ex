defmodule Platform.Responsibilities.ContextGatherer do
  @moduledoc """
  Materialises the symbolic context names declared on
  `responsibility.context_provided` into a real context map the
  Dispatcher can substitute into a prompt template (ADR-0041 M6 stage 6).

  ## Built-in symbolic names

    * `:org_identity`     → `Platform.Org.Context.get_file("ORG_IDENTITY.md")`
    * `:recent_journal`   → `Platform.Org.Context.recent_memory(7, [])`
    * `:current_message`  → `Platform.Chat.get_message(trigger_meta[:message_id])`
    * `:current_meeting`  → `Platform.Meetings.get_meeting(trigger_meta[:meeting_id])`
    * `:trigger_payload`  → `trigger_meta[:payload]`

  Names are deliberately atoms (not strings) so we can pattern-match on
  them without `String.to_atom/1` churn. The Router can pass the
  declared list of strings through `Enum.map(&String.to_existing_atom/1)`
  before calling `gather/2` — unknown atoms log a warning and resolve to
  `nil` rather than crashing the dispatch pipeline.

  ## Adding new symbolic names

  M8+ providers can extend the recognised set by implementing
  `Platform.Responsibilities.Provider.gather_context/2` directly and
  returning a fully populated context map without going through this
  module. ContextGatherer covers the cross-cutting, platform-owned
  names; per-provider context (e.g. meeting transcript, project
  metadata) belongs in the provider's own `gather_context/2`.

  ## Tolerant lookup

  Every call site is wrapped in defensive guards:

    * Each upstream lookup is wrapped in `try/rescue` so an upstream
      raise (e.g. `Platform.Org.Context` not loaded in a stripped
      build, or a chat message id pointing at a stale row) degrades to
      `nil` in the returned map rather than aborting the gather.
    * Missing IDs in `trigger_meta` (e.g. `:current_message` with no
      `:message_id`) skip the lookup and emit `nil`.
    * Unknown symbolic names log a `:warning` and put `nil` in the map
      so providers can ship new `context_provided` entries without a
      synchronous ContextGatherer release.
  """

  require Logger

  @typedoc "Context map keyed by the symbolic name as an atom."
  @type context_map :: %{optional(atom()) => term()}

  @doc """
  Gather the supplied list of symbolic names into a single context map.

  `symbolic_names` may be a list of atoms or strings. String entries
  are coerced to atoms via `String.to_existing_atom/1`; unknown strings
  log a warning and resolve to `nil` (no atom-table leak).

  Always returns a map. Never raises.
  """
  @spec gather([atom() | String.t()], map()) :: context_map()
  def gather(symbolic_names, trigger_meta)
      when is_list(symbolic_names) and is_map(trigger_meta) do
    Enum.reduce(symbolic_names, %{}, fn raw_name, acc ->
      case coerce_name(raw_name) do
        {:ok, name} -> Map.put(acc, name, resolve(name, trigger_meta))
        :error -> acc
      end
    end)
  end

  def gather(_symbolic_names, _trigger_meta), do: %{}

  # ── name coercion ─────────────────────────────────────────────────────────

  defp coerce_name(name) when is_atom(name), do: {:ok, name}

  defp coerce_name(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError ->
      Logger.warning(
        "[ContextGatherer] unknown symbolic name=#{inspect(name)} (no existing atom), skipping"
      )

      :error
  end

  defp coerce_name(_), do: :error

  # ── resolvers ─────────────────────────────────────────────────────────────

  defp resolve(:org_identity, _trigger_meta) do
    safe_call(fn ->
      if Code.ensure_loaded?(Platform.Org.Context) and
           function_exported?(Platform.Org.Context, :get_file, 1) do
        Platform.Org.Context.get_file("ORG_IDENTITY.md")
      else
        nil
      end
    end)
  end

  defp resolve(:recent_journal, _trigger_meta) do
    safe_call(fn ->
      if Code.ensure_loaded?(Platform.Org.Context) and
           function_exported?(Platform.Org.Context, :recent_memory, 2) do
        Platform.Org.Context.recent_memory(7, [])
      else
        nil
      end
    end)
  end

  defp resolve(:current_message, trigger_meta) do
    case Map.get(trigger_meta, :message_id) || Map.get(trigger_meta, "message_id") do
      id when is_binary(id) ->
        safe_call(fn ->
          if Code.ensure_loaded?(Platform.Chat) and
               function_exported?(Platform.Chat, :get_message, 1) do
            Platform.Chat.get_message(id)
          else
            nil
          end
        end)

      _ ->
        nil
    end
  end

  defp resolve(:current_meeting, trigger_meta) do
    case Map.get(trigger_meta, :meeting_id) || Map.get(trigger_meta, "meeting_id") do
      id when is_binary(id) ->
        safe_call(fn ->
          if Code.ensure_loaded?(Platform.Meetings) and
               function_exported?(Platform.Meetings, :get_meeting, 1) do
            Platform.Meetings.get_meeting(id)
          else
            nil
          end
        end)

      _ ->
        nil
    end
  end

  defp resolve(:trigger_payload, trigger_meta) do
    Map.get(trigger_meta, :payload) || Map.get(trigger_meta, "payload")
  end

  defp resolve(name, _trigger_meta) do
    Logger.warning("[ContextGatherer] unknown name=#{inspect(name)}, returning nil")
    nil
  end

  # Wrap upstream lookups so a missing module / raised exception
  # degrades to `nil` in the gathered context rather than killing the
  # entire dispatch pipeline.
  defp safe_call(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error ->
      Logger.warning(
        "[ContextGatherer] lookup raised: #{Exception.message(error)} — returning nil"
      )

      nil
  catch
    :exit, reason ->
      Logger.warning("[ContextGatherer] lookup exited: #{inspect(reason)} — returning nil")

      nil
  end
end
