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

  alias Platform.Access.{Scope, ToolPermissions, Tools}
  alias Platform.Federation.ToolSurface

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
  def effective_tools(runtime), do: Tools.effective_tools(runtime)

  @doc "Convenience projection of `effective_tools/1` for tests and telemetry."
  def tool_names(runtime), do: Tools.tool_names(runtime)

  @doc """
  Is this runtime owned by an external principal?

  An external principal is a runtime whose owner holds any org_membership
  marked `external: true`. One indexed `Repo.exists?` per call.
  `Tenancy.external_user?/1` matches a map carrying `:id`, so we wrap the raw
  `owner_user_id` — a nil owner falls through to `false`.
  """
  def external_principal?(runtime),
    do: Scope.guest?(Scope.for_user(%{id: runtime.owner_user_id}))

  @doc """
  May `runtime` call the tool named `name`?

  Returns `:ok` or `{:error, :forbidden}`. Straight membership of `name` in
  `effective_tools/1` — no alias resolution, no fuzzy matching. A name absent
  from the catalogue is absent from every bundle and is denied. Anything that
  is not a binary name is denied.
  """
  def authorize(name, runtime) when is_binary(name), do: Tools.authorize(name, runtime)

  def authorize(_name, _runtime), do: {:error, :forbidden}

  @doc """
  Classifies a name `authorize/2` has ALREADY denied.

  Consult this only after `authorize/2` returns `{:error, :forbidden}` — it
  does not decide whether a call is allowed and does not change
  `authorize/2`'s behaviour or two-value signature (`:ok` /
  `{:error, :forbidden}`) in any way. It answers a purely diagnostic
  question so a denial message can stop conflating two different failures:

    * `:forbidden` — `name` IS in `ToolSurface.tool_definitions/0` (the full
      catalogue, independent of any runtime's grant). The tool exists; this
      runtime's `allowed_bundles` just doesn't cover it. The grant tables are
      the right place to look.
    * `{:unknown_tool, suggestion}` — `name` is absent from the catalogue
      entirely. There is no grant to be missing — a typo, or a separator
      mismatch (`canvas.create` vs `canvas_create`) named something that was
      never registered. `suggestion` is a catalogue name reachable by
      separator-normalised equality, or `nil` if none matches.

  `ToolSurface.tool_definitions/0` is resolved at call time, every call —
  never cached into a module attribute, which would freeze the catalogue at
  compile time and silently stop tracking additions/removals.
  """
  def deny_reason(name) when is_binary(name) do
    catalogue = ToolSurface.tool_definitions()

    if Enum.any?(catalogue, &(&1.name == name)) do
      :forbidden
    else
      {:unknown_tool, suggest(name, catalogue)}
    end
  end

  def deny_reason(_name), do: :forbidden

  @doc """
  Formats the denial message for a name `authorize/2` has already denied.

  Both transports (`PlatformWeb.MCPController` and `PlatformWeb.RuntimeChannel`)
  call this rather than building their own sentence, so a denial reads
  identically on both — the same "cannot answer differently" property this
  module already holds for the authorization decision, extended to the
  message text.

  Case 1 (`:forbidden`) keeps the pre-existing wording verbatim — a genuine
  missing-grant denial must still read as one. Case 2
  (`{:unknown_tool, suggestion}`) says plainly that this is a name lookup
  miss, not a permissions problem, and appends the closest declared name
  only when `deny_reason/1` found one — never an empty
  `Closest declared name: ''`.
  """
  def deny_message(name) do
    # An extension may word the denial of a tool it owns (ADR 0055): e.g. a
    # tool whose module is switched off is absent from the catalogue, so
    # core's wording would read as a name-lookup miss, true but useless.
    # Message text only: `authorize/2` and `deny_reason/1` are unchanged,
    # and both transports still call this one formatter, so they cannot
    # disagree.
    extension_deny_message(name) || deny_message_for_reason(name)
  end

  defp extension_deny_message(name) do
    case Platform.Extensions.tool_owner(name) do
      %{deny_message: deny_message} when is_function(deny_message, 1) -> deny_message.(name)
      _ -> nil
    end
  end

  defp deny_message_for_reason(name) do
    case deny_reason(name) do
      :forbidden ->
        permission = ToolPermissions.for_tool(name) || "undeclared"
        "tool '#{name}' requires permission '#{permission}', which this agent does not hold or is capped at its owner"

      {:unknown_tool, nil} ->
        "unknown tool '#{name}' (no such tool in the catalogue — this is a name lookup miss, not a permissions problem)."

      {:unknown_tool, suggestion} ->
        "unknown tool '#{name}' (no such tool in the catalogue — this is a name lookup miss, not a permissions problem). Closest declared name: '#{suggestion}'."
    end
  end

  # Separator-normalised equality only — downcase, strip `.`, `_`, `-`, then
  # look for a catalogue name whose normalised form matches exactly.
  # Deliberately NOT Jaro/Levenshtein or any edit-distance threshold: an
  # edit-distance match can invent a plausible-but-wrong suggestion, but
  # normalised equality either matches the one name a separator swap or
  # typo-in-case could produce, or it matches nothing.
  defp suggest(name, catalogue) do
    target = normalize_separators(name)

    Enum.find_value(catalogue, fn %{name: candidate} ->
      if normalize_separators(candidate) == target, do: candidate
    end)
  end

  defp normalize_separators(name) do
    name
    |> String.downcase()
    |> String.replace([".", "_", "-"], "")
  end

end
