defmodule Platform.Responsibilities.ContextGatherer do
  @moduledoc """
  **Batch adapter over `Platform.Responsibilities.ContextProviders`.**
  This module resolves nothing. It fans a list of symbolic context names
  across the single per-slot resolver and folds the results into the flat,
  tolerant `%{name => payload}` map the Dispatcher's template render
  expects (ADR-0041 M6 stage 6).

  Adding a new symbolic name is a one-file change in `ContextProviders`;
  it becomes reachable from this path by construction. There is nothing
  to add here.

  ## Tolerant lookup

  `gather/2`'s contract is unchanged and every call site still depends on
  it:

    * **Always returns a map, never raises.** Any `{:error, reason}` from
      the resolver — missing id, unknown row, upstream raise — degrades to
      `nil` under the requested key. A resolver that raises outright is
      caught here too.
    * **Unknown symbolic names** log a `:warning` and put `nil` in the
      map, so a provider can ship a new `context_provided` entry without a
      synchronous release of the resolver.
    * **Unknown strings with no existing atom** log a warning and are
      dropped entirely (no atom-table leak, and no key to hang `nil` on).

  ## `:__slot_errors__`

  Degrading an error to `nil` throws the reason away, which is how "the
  transcript id was missing" and "the transcript row is gone" became the
  same value. The reason is now retained under the `:__slot_errors__` key
  — a `%{name => reason}` map — which is present **only when at least one
  slot failed.** Callers that just want the tolerant map are unaffected;
  callers that need to tell a refusal from an absence have somewhere to
  look. An unknown symbolic name is not recorded there: it is a wiring
  bug, already logged, and not a slot that failed to resolve.
  """

  require Logger

  alias Platform.Responsibilities.ContextProviders

  @slot_errors_key :__slot_errors__

  @typedoc "Context map keyed by the symbolic name as an atom."
  @type context_map :: %{optional(atom()) => term()}

  @doc """
  Gather the supplied list of symbolic names into a single context map.

  `symbolic_names` may be a list of atoms or strings. String entries
  are coerced to atoms via `String.to_existing_atom/1`; unknown strings
  log a warning and are dropped (no atom-table leak).

  Always returns a map. Never raises.
  """
  @spec gather([atom() | String.t()], map()) :: context_map()
  def gather(symbolic_names, trigger_meta)
      when is_list(symbolic_names) and is_map(trigger_meta) do
    Enum.reduce(symbolic_names, %{}, fn raw_name, acc ->
      case coerce_name(raw_name) do
        {:ok, name} -> put_slot(acc, name, trigger_meta)
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

  # ── adaptation ────────────────────────────────────────────────────────────

  defp put_slot(acc, name, trigger_meta) do
    case safe_gather(name, trigger_meta) do
      {:ok, %{^name => payload}} ->
        Map.put(acc, name, payload)

      {:ok, other} when is_map(other) ->
        # The resolver keyed its payload under something other than the
        # requested name. Merge it rather than dropping it, but still
        # honour "the requested key is always present".
        acc |> Map.put(name, nil) |> Map.merge(other)

      {:error, {:unknown_slot, _}} ->
        Logger.warning("[ContextGatherer] unknown name=#{inspect(name)}, returning nil")
        Map.put(acc, name, nil)

      {:error, reason} ->
        acc |> Map.put(name, nil) |> record_slot_error(name, reason)

      other ->
        Logger.warning(
          "[ContextGatherer] resolver returned an unexpected shape for name=#{inspect(name)} " <>
            "result=#{inspect(other)} — returning nil"
        )

        acc |> Map.put(name, nil) |> record_slot_error(name, {:unexpected_shape, other})
    end
  end

  defp record_slot_error(acc, name, reason) do
    Map.update(acc, @slot_errors_key, %{name => reason}, &Map.put(&1, name, reason))
  end

  # The per-slot resolver is contracted to return `{:ok, map}` /
  # `{:error, term}`, but `gather/2` promises it never raises regardless
  # of what a future slot does. Belt and braces.
  defp safe_gather(name, trigger_meta) do
    ContextProviders.gather_context(name, trigger_meta)
  rescue
    error ->
      Logger.warning(
        "[ContextGatherer] lookup raised: #{Exception.message(error)} — returning nil"
      )

      {:error, {:exception, Exception.message(error)}}
  catch
    :exit, reason ->
      Logger.warning("[ContextGatherer] lookup exited: #{inspect(reason)} — returning nil")

      {:error, {:exit, reason}}
  end
end
