defmodule Platform.Extensions do
  @moduledoc """
  The registry of build-time modules (ADR 0055, task 01a0ee08). Every core
  seam a module plugs into reads it through here, so core never names a
  module.

  ## Read per call, never captured

  The list is `Application.get_env(:platform, :extensions, [])`, read on
  EVERY call. No caller may capture any function here into a module
  attribute: an attribute is evaluated at compile time, so it would ignore a
  release host's config and a test's `Application.put_env/3` alike (the same
  rule `Platform.Chat.Canvas.Kinds` states for its gated list).

  ## Nothing here trusts a module to be running

  `runtime_disconnected/1` rescues and returns `:ok` whatever a module does:
  it runs from a runtime channel's `terminate/2`, which can run after the
  module's own processes have stopped
  (`0055-extension-contract-and-build-time-modules.md § 3. Supervision is the module's own`).
  """

  require Logger

  @doc "The configured extension modules, in configuration order."
  @spec list() :: [module()]
  def list, do: Application.get_env(:platform, :extensions, [])

  @doc "Canvas kind modules every extension contributes."
  @spec canvas_kinds() :: [module()]
  def canvas_kinds, do: Enum.flat_map(list(), & &1.canvas_kinds())

  @doc "Every extension's MCP tool bundles (see `t:Platform.Extension.tool_bundle/0`)."
  @spec tool_bundles() :: [Platform.Extension.tool_bundle()]
  def tool_bundles, do: Enum.flat_map(list(), & &1.mcp_tool_bundles())

  @doc "The names of every extension tool bundle, in order."
  @spec tool_bundle_names() :: [String.t()]
  def tool_bundle_names, do: Enum.map(tool_bundles(), & &1.name)

  @doc "The extension bundle named `name`, or nil."
  @spec tool_bundle(String.t()) :: Platform.Extension.tool_bundle() | nil
  def tool_bundle(name), do: Enum.find(tool_bundles(), &(&1.name == name))

  @doc """
  The extension bundle that owns tool `name`, or nil.

  Looked up first by exact name, in a map built from every bundle's
  `:tool_names` and `:definitions`; core matches no prefix. `:tool_names` is
  what lets a module answer a call to a tool it owns but does not list right
  now (a switched-off module's refusal). Only then is a bundle's own optional
  `:owns_tool?` claim asked, for a name space a module reserves beyond its
  listed names (Play answers an unknown `play_session_*` name with its own
  `unknown_tool` refusal, as on main). A name no bundle claims falls through
  to core's unknown-tool error. `validate/0` refuses a claim that covers a
  core tool name.
  """
  @spec tool_owner(String.t()) :: Platform.Extension.tool_bundle() | nil
  def tool_owner(name) when is_binary(name) do
    Map.get(tool_index(), name) || Enum.find(tool_bundles(), &claims_tool?(&1, name))
  end

  def tool_owner(_name), do: nil

  defp claims_tool?(%{owns_tool?: claim}, name) when is_function(claim, 1),
    do: claim.(name) == true

  defp claims_tool?(_bundle, _name), do: false

  defp tool_index do
    for bundle <- tool_bundles(), name <- owned_tool_names(bundle), reduce: %{} do
      index -> Map.put_new(index, name, bundle)
    end
  end

  defp owned_tool_names(bundle) do
    Enum.uniq(Map.get(bundle, :tool_names, []) ++ Enum.map(bundle.definitions, & &1.name))
  end

  @doc "The extension that owns runtime-channel `event`, or nil."
  @spec runtime_event_owner(String.t()) :: module() | nil
  def runtime_event_owner(event) when is_binary(event),
    do: Enum.find(list(), &(event in &1.runtime_channel_events()))

  def runtime_event_owner(_event), do: nil

  @doc """
  Tells every extension that `runtime_id`'s socket went away. Always `:ok`:
  a callback that raises or exits is logged and skipped.
  """
  @spec runtime_disconnected(String.t()) :: :ok
  def runtime_disconnected(runtime_id) do
    for ext <- list() do
      try do
        ext.runtime_disconnected(runtime_id)
      rescue
        error ->
          Logger.warning(
            "[Extensions] #{inspect(ext)}.runtime_disconnected(#{runtime_id}) raised: " <>
              Exception.message(error)
          )
      catch
        kind, reason ->
          Logger.warning(
            "[Extensions] #{inspect(ext)}.runtime_disconnected(#{runtime_id}) #{kind}: " <>
              inspect(reason)
          )
      end
    end

    :ok
  end

  @doc "LiveView lifecycle hooks every extension contributes, as `{module, function}`."
  @spec live_hooks() :: [{module(), atom()}]
  def live_hooks, do: Enum.flat_map(list(), & &1.live_hooks())

  @doc "Experiment surface modules every extension contributes."
  @spec experiment_surfaces() :: [module()]
  def experiment_surfaces, do: Enum.flat_map(list(), & &1.experiment_surfaces())

  @doc "Experiment metric registry entries every extension contributes, merged."
  @spec experiment_metrics() :: %{String.t() => map()}
  def experiment_metrics,
    do: Enum.reduce(list(), %{}, &Map.merge(&2, &1.experiment_metrics()))

  @doc "Rail destinations every extension contributes (`rail_items/0` is optional)."
  @spec rail_items() :: [map()]
  def rail_items do
    Enum.flat_map(list(), fn ext ->
      if implements?(ext, :rail_items, 0), do: ext.rail_items(), else: []
    end)
  end

  @doc """
  Every extension's migrations path, in configuration order, without core's.
  Callers put core's path first: `[core_path | migrations_paths()]`.
  """
  @spec migrations_paths() :: [String.t()]
  def migrations_paths do
    list()
    |> Enum.map(& &1.migrations_path())
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Every extension's `assets/0`, in configuration order, as
  `{extension, %{js_hooks:, css:, tailwind_sources:}}` with absent keys
  filled (`nil`, `nil`, `[]`). An extension without `assets/0` is skipped.
  Read at build time by `mix platform.extensions.assets`.

  Core starts no extension process: a module's supervision tree is its own
  `Application.start/2`'s
  (`0055-extension-contract-and-build-time-modules.md § 3. Supervision is the module's own`).
  """
  @spec assets() :: [{module(), map()}]
  def assets do
    for ext <- list(), implements?(ext, :assets, 0) do
      {ext, Map.merge(%{js_hooks: nil, css: nil, tailwind_sources: []}, ext.assets())}
    end
  end

  @doc """
  Checks that no extension reuses a name core already owns, and that no two
  extensions share one, across every registry the extensions merge into:
  tool bundle names, tool names, runtime-channel event names, canvas kind
  names, experiment surface keys and experiment metric slugs.

  Returns `:ok` or `{:error, messages}`, one message per clash, each naming
  both owners. Checks what each callback answers NOW: a kind a module lists
  only while its flag is on is checked while it is on.
  """
  @spec validate() :: :ok | {:error, [String.t()]}
  def validate do
    extensions = list()

    checks = [
      {"tool bundle name", Platform.Federation.ToolSurface.core_bundles(),
       fn ext -> Enum.map(ext.mcp_tool_bundles(), & &1.name) end},
      {"tool name", core_tool_names(),
       fn ext -> Enum.flat_map(ext.mcp_tool_bundles(), &owned_tool_names/1) end},
      {"tool name claim", core_tool_names(),
       fn ext ->
         for bundle <- ext.mcp_tool_bundles(),
             name <- core_tool_names(),
             claims_tool?(bundle, name),
             do: name
       end},
      {"runtime event name", PlatformWeb.RuntimeChannel.core_events(),
       & &1.runtime_channel_events()},
      {"canvas kind name", Enum.map(Platform.Chat.Canvas.Kinds.core_modules(), & &1.name()),
       fn ext -> Enum.map(ext.canvas_kinds(), & &1.name()) end},
      {"experiment surface key",
       Enum.map(Platform.Experiments.Surfaces.core_surfaces(), & &1.key()),
       fn ext -> Enum.map(ext.experiment_surfaces(), & &1.key()) end},
      {"experiment metric slug", Platform.Experiments.Metrics.core_metric_slugs(),
       fn ext -> Map.keys(ext.experiment_metrics()) end}
    ]

    case Enum.flat_map(checks, &clashes(&1, extensions)) do
      [] -> :ok
      messages -> {:error, messages}
    end
  end

  @doc "`validate/0`, raising `ArgumentError` listing every clash. Called at boot."
  @spec validate!() :: :ok
  def validate! do
    case validate() do
      :ok ->
        :ok

      {:error, messages} ->
        raise ArgumentError,
              "config :platform, :extensions has name clashes:\n  " <>
                Enum.join(messages, "\n  ")
    end
  end

  defp clashes({kind, core_names, names_of}, extensions) do
    owners = Map.new(core_names, &{&1, "core"})

    {_owners, messages} =
      for ext <- extensions, name <- Enum.uniq(names_of.(ext)), reduce: {owners, []} do
        {owners, messages} ->
          case Map.fetch(owners, name) do
            {:ok, owner} ->
              message = "#{kind} #{inspect(name)} is claimed by #{owner} and by #{inspect(ext)}"
              {owners, [message | messages]}

            :error ->
              {Map.put(owners, name, inspect(ext)), messages}
          end
      end

    Enum.reverse(messages)
  end

  defp core_tool_names do
    Platform.Federation.ToolSurface.core_bundles()
    |> Platform.Federation.ToolSurface.list_tools()
    |> Enum.map(& &1.name)
  end

  defp implements?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end
end
