defmodule Platform.Federation.ToolAuthorization do
  @moduledoc """
  The single enforcement point for "which tools may this runtime see and call".

  Both federation transports — the streamable-HTTP MCP endpoint
  (`PlatformWeb.MCPController`) and the WebSocket runtime channel
  (`PlatformWeb.RuntimeChannel`) — resolve capability through this module,
  so the advertised surface and the callable surface cannot drift apart
  either *within* a transport or *between* the two.

  ## Why the boundary lives here and not inside `ToolSurface`

  `Platform.Federation.ToolSurface` is a catalogue-plus-executor with no
  notion of a principal: `list_tools/1` and `scope_for_external/2` are pure
  list transforms. Authorization is policy *over a principal* — it needs a
  `%Platform.Agents.AgentRuntime{}` and a `Repo.exists?` through
  `Platform.Tenancy.external_user?/1`. Folding that into `ToolSurface` would
  make the pure catalogue depend on tenancy and on a database read. This
  sibling module composes the two pure primitives and owns the
  principal-shaped decision.

  ## Why `%AgentRuntime{}` is the input

  `PlatformWeb.Plugs.RuntimeBearerAuth` already hands the controller the full
  struct at `conn.assigns.runtime`, and the channel can load the same row via
  `Platform.Federation.get_runtime/1`. One shape, no adapter, no drift.

  ## Undeclared tool names are denied — including the legacy canvas aliases

  `ToolSurface` carries two `execute/3` clauses that are *executable but
  unlisted*: `canvas_create` and `canvas_update` are absent from
  `tool_definitions/0`. They are NOT special-cased here. The catalogue is the
  authorization vocabulary, so a name that is not in `tool_definitions/0` is
  not in any bundle and is therefore denied on both transports.

  This is a deliberate, owner-directed breakage rather than an oversight.
  `openclaw-suite-channel/src/channel.ts` still contains `tool_call` frames
  for `canvas_create` (line 102) and `canvas_update` (line 114) over
  WebSocket, but openclaw plugins are transitioning to MCP-only and the sole
  active openclaw agent is configured for MCP, not WebSocket. If a client ever
  does invoke those names over either transport it will get
  `tool '<name>' not in allowed bundles`; the fix is to call the declared
  names `canvas.create` / `canvas.patch`.

  ## Deliberate non-dependency

  This module reads the per-row `allowed_bundles` array only. It never calls
  `AgentRuntime.valid_bundles/0`.

  That list used to disagree with `ToolSurface.all_bundles/0` — it rejected the
  `files` bundle the surface registers. The two are reconciled as of task
  019ff110 and held equal by a set-equality test in
  `test/platform/agents/agent_runtime_test.exs`. The non-dependency stands on
  its own merits regardless: what a row *may* hold and what it *does* hold are
  different questions, and only the second one authorizes a call.
  """

  alias Platform.Federation.ToolSurface
  alias Platform.Tenancy

  @doc """
  The tool set a runtime may see AND call.

  Single source of truth. `tools/list` (HTTP) and the `capabilities` push
  (WebSocket) map over this, and `authorize/2` checks membership against it,
  so the visible set and the callable set are provably identical — a tool can
  never be listed-but-blocked or blocked-but-listed. For an external principal
  the bundle-scoped list is further intersected with the chat allowlist
  (fail-closed, only removes); for an internal principal
  `scope_for_external(_, false)` is identity.

  A runtime with no bundles (or a nil column) resolves to an empty list —
  fail-closed, never the full surface.
  """
  def effective_tools(runtime) do
    runtime
    |> allowed_bundles()
    |> ToolSurface.list_tools()
    |> ToolSurface.scope_for_external(external_principal?(runtime))
  end

  @doc "Convenience projection of `effective_tools/1` for tests and telemetry."
  def tool_names(runtime) do
    runtime |> effective_tools() |> Enum.map(& &1.name)
  end

  @doc """
  Is this runtime owned by an external principal?

  An external principal is a runtime whose owner holds any org_membership
  marked `external: true`. One indexed `Repo.exists?` per call.
  `Tenancy.external_user?/1` matches a map carrying `:id`, so we wrap the raw
  `owner_user_id` — a nil owner falls through to `false`.
  """
  def external_principal?(runtime),
    do: Tenancy.external_user?(%{id: runtime.owner_user_id})

  @doc """
  May `runtime` call the tool named `name`?

  Returns `:ok` or `{:error, :forbidden}`. Straight membership of `name` in
  `effective_tools/1` — no alias resolution, no fuzzy matching. A name absent
  from the catalogue is absent from every bundle and is denied. Anything that
  is not a binary name is denied.
  """
  def authorize(name, runtime) when is_binary(name) do
    if Enum.any?(effective_tools(runtime), &(&1.name == name)),
      do: :ok,
      else: {:error, :forbidden}
  end

  def authorize(_name, _runtime), do: {:error, :forbidden}

  defp allowed_bundles(%{allowed_bundles: bundles}) when is_list(bundles), do: bundles
  defp allowed_bundles(_runtime), do: []
end
