defmodule Platform.Federation.ToolAuthorization do
  @moduledoc """
  Compatibility facade for federation transports. The permission decision
  lives in `Platform.Access.Tools`: it preserves profile order, checks each
  tool's declared permission against the owner-capped runtime Scope, and
  applies any narrower experiment arm. HTTP, WebSocket and code mode call the
  same decision. This module keeps federation's denial wording and typo
  suggestions at the transport boundary.
  """

  alias Platform.Access.{Scope, ToolPermissions, Tools}
  alias Platform.Federation.ToolAliases
  alias Platform.Federation.ToolSurface

  @doc """
  The tool set a runtime may see AND call.

  Both `tools/list` and calls use `Platform.Access.Tools.effective_tools/1`.
  """
  def effective_tools(runtime), do: Tools.effective_tools(runtime)

  @doc "Convenience projection of `effective_tools/1` for tests and telemetry."
  def tool_names(runtime), do: Tools.tool_names(runtime)

  @doc """
  Is this runtime owned by an external principal?

  Guest status comes from the owner's Access Scope.
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

    * `:forbidden` — `name` is in the catalogue but the runtime does not
      hold its required permission or its tool profile omits the module.
    * `{:unknown_tool, suggestion}` — `name` is absent from the catalogue
      entirely. There is no grant to be missing — a typo, or a separator
      mismatch (`skill-list` vs `skill_list`) named something that was
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

  Case 1 (`:forbidden`) names the tool's required permission. Case 2
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

  # A hidden legacy alias (`Platform.Federation.ToolAliases`) is worded by
  # its canonical name's reason: it needs exactly that grant, so a refused
  # `suite_run` reads as the permission miss a refused `burrow_run` reads as,
  # not as an unknown name (task 01a14b9e-50a4 stage 1). Wording only;
  # `deny_reason/1` and `authorize/2` are unchanged. The sent name is kept.
  defp deny_message_for_reason(name) do
    {reason, permission_name} =
      case ToolAliases.resolve(name) do
        {:alias, canonical} -> {deny_reason(canonical), canonical}
        :canonical -> {deny_reason(name), name}
      end

    case reason do
      :forbidden ->
        permission = ToolPermissions.for_tool(permission_name) || "undeclared"

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
