defmodule Platform.Federation.TaskAttrs do
  @moduledoc """
  Shared shape decisions for the assignee / sponsor / deploy-target /
  auto-approve-plan family of task fields. Documented in ADR 0044.

  This module is a pure-function attrs builder: it normalizes a raw args
  map (from the MCP tool surface OR from a LiveView form submit) into a
  pair `{flat_attrs, phase_attrs}` where:

  - `flat_attrs` is safe to pass to `Platform.Tasks.create_task/1` or
    `Platform.Tasks.update_task/2`.
  - `phase_attrs` is either `nil` (no per-phase intent from this caller)
    or a map suitable for `Platform.Tasks.set_phase_assignees/2`.

  The routing decision — whether to call `set_phase_assignees/2` after
  the changeset writer — stays at the caller. This module only owns the
  shape.

  ## Canonical rules (see ADR 0044 for the full audit)

    * `sponsor_user_id` is EXPLICITLY nilable in `:update` mode: an
      explicit `nil` propagates as `nil` (clears the sponsor per ADR
      0042). In `:create` mode, `nil` is dropped (no sponsor to clear).
    * `deploy_target` empty string is normalized to `nil` in both modes.
      In `:update` mode, `nil` propagates (clears). In `:create` mode,
      `nil` is dropped.
    * `phase_assignees` (structured jsonb map) is passed through as-is
      when supplied. It emits into `phase_attrs`, NOT `flat_attrs`.
    * Flat `assignee_id` + `assignee_type` are auto-routed to the
      current-phase slot of `phase_attrs` when the caller opts in via
      `auto_route_flat_assignee_current_phase: true` AND supplies
      `current_phase: "<phase>"`. In that case they are REMOVED from
      `flat_attrs`.
    * When BOTH structured `phase_assignees` AND flat `assignee_*` are
      supplied, structured wins — flat is dropped.
    * Every other field: `nil` means "untouched" and is dropped from
      the emitted attrs map.
    * Unknown keys are silently dropped (safety — matches the existing
      `Map.take/2` posture at the MCP boundary).

  See `Platform.Federation.ToolSurface` for the MCP surfaces that will
  consume this helper (stage 2 of task 019f42fd) and
  `PlatformWeb.TasksLive` for the LiveView surface (stage 4).
  """

  @typedoc "Task attrs consumable by `Tasks.create_task/1` or `Tasks.update_task/2`."
  @type flat_attrs :: %{atom() => any()}

  @typedoc """
  Per-phase assignee map consumable by `Tasks.set_phase_assignees/2`.
  Keys are phase names (`"planning" | "execution" | "review"`), values
  are `%{"assignee_id" => uuid, "assignee_type" => "agent" | "user"}`.
  """
  @type phase_attrs :: %{String.t() => map()}

  @typedoc """
  Builder mode. `:create` drops nils for every field (no changeset has
  something to clear). `:update` propagates explicit nils for the
  `@explicitly_nilable` allowlist.
  """
  @type mode :: :create | :update

  @canonical_field_keys ~w(
    title
    description
    status
    priority
    epic_id
    project_id
    assignee_id
    assignee_type
    sponsor_user_id
    deploy_target
    auto_approve_plan
    reported_by
  )

  @explicitly_nilable ~w(sponsor_user_id deploy_target)

  @emptystring_clears ~w(deploy_target)

  @valid_phases ~w(planning execution review)

  @doc """
  Fields the `:update` mode will propagate as explicit `nil` to clear.
  Every other key with a nil value is dropped from `flat_attrs`.

  Named as a function (not a module attribute) so tests can assert the
  contract by calling it — the exact SAME data the builder branches on.
  """
  @spec explicitly_nilable() :: [String.t()]
  def explicitly_nilable, do: @explicitly_nilable

  @doc """
  Fields where an empty string is normalized to `nil` on entry.
  """
  @spec emptystring_clears() :: [String.t()]
  def emptystring_clears, do: @emptystring_clears

  @doc """
  Normalize a raw args map into a `{flat_attrs, phase_attrs}` pair.

  ## Args

    * `args` — the raw params map. Keys may be strings (typical from
      MCP JSON) or atoms; this function tolerates both.
    * `mode` — `:create` or `:update`. Governs nil propagation.
    * `opts`:
        * `:auto_route_flat_assignee_current_phase` — when `true`, flat
          `assignee_id` + `assignee_type` are moved out of `flat_attrs`
          and into `phase_attrs` at the current-phase slot.
        * `:current_phase` — the phase name to use as the slot. Required
          when `auto_route_flat_assignee_current_phase: true`.

  ## Returns

    * `{:ok, flat_attrs, phase_attrs}` where `phase_attrs` may be `nil`.
    * `{:error, reason}` on shape violations (e.g. `auto_route` opted
      in without a `current_phase`, or `phase_assignees` supplied with
      an unknown phase key).
  """
  @spec build_task_attrs(map(), mode(), keyword()) ::
          {:ok, flat_attrs(), phase_attrs() | nil} | {:error, term()}
  def build_task_attrs(args, mode, opts \\ [])
      when is_map(args) and mode in [:create, :update] do
    args = stringify_keys(args)

    with {:ok, phase_attrs_from_struct} <- extract_phase_assignees(args),
         {:ok, current_phase} <- resolve_current_phase(opts, args),
         {:ok, auto_route} <- resolve_auto_route(opts, current_phase),
         {:ok, flat_attrs, phase_attrs_from_flat} <-
           build_flat_attrs(args, mode, auto_route, current_phase, phase_attrs_from_struct) do
      merged_phase_attrs = merge_phase_attrs(phase_attrs_from_struct, phase_attrs_from_flat)
      {:ok, flat_attrs, merged_phase_attrs}
    end
  end

  # ── Phase-assignees extraction ──────────────────────────────────────────

  defp extract_phase_assignees(args) do
    case Map.get(args, "phase_assignees") do
      nil ->
        {:ok, nil}

      map when is_map(map) ->
        stringified = for {k, v} <- map, into: %{}, do: {to_string(k), v}

        invalid_keys = Map.keys(stringified) -- @valid_phases

        cond do
          invalid_keys != [] ->
            {:error, {:invalid_phase_keys, invalid_keys}}

          map_size(stringified) == 0 ->
            {:ok, nil}

          true ->
            {:ok, stringified}
        end

      other ->
        {:error, {:invalid_phase_assignees_shape, other}}
    end
  end

  # ── Current-phase / auto-route opts ─────────────────────────────────────

  defp resolve_current_phase(opts, _args) do
    case Keyword.get(opts, :current_phase) do
      nil -> {:ok, nil}
      phase when phase in @valid_phases -> {:ok, phase}
      other -> {:error, {:invalid_current_phase, other}}
    end
  end

  defp resolve_auto_route(opts, current_phase) do
    case {Keyword.get(opts, :auto_route_flat_assignee_current_phase, false), current_phase} do
      {false, _} -> {:ok, false}
      {true, nil} -> {:error, :auto_route_requires_current_phase}
      {true, _phase} -> {:ok, true}
    end
  end

  # ── Flat attrs builder ──────────────────────────────────────────────────

  defp build_flat_attrs(args, mode, auto_route, current_phase, phase_attrs_from_struct) do
    # Structured phase_assignees wins over flat assignee_*. If the caller
    # supplied both, we strip the flat pair before it can influence
    # anything downstream.
    strip_flat_assignee? = auto_route or not is_nil(phase_attrs_from_struct)

    taken =
      args
      |> Map.take(@canonical_field_keys)
      |> then(fn m ->
        # Empty-string-to-nil normalization for the emptystring_clears
        # allowlist (currently `deploy_target`).
        Enum.reduce(@emptystring_clears, m, fn key, acc ->
          case Map.get(acc, key) do
            "" -> Map.put(acc, key, nil)
            _ -> acc
          end
        end)
      end)

    {flat_pair, taken_without_flat} = Map.split(taken, ~w(assignee_id assignee_type))

    flat_attrs =
      taken_without_flat
      |> Enum.reduce(%{}, fn {k, v}, acc ->
        cond do
          # Explicitly-nilable keys in :update propagate nil. In :create
          # they still drop nil — there's no existing value to clear on
          # a fresh row.
          k in @explicitly_nilable and mode == :update ->
            Map.put(acc, String.to_existing_atom(k), v)

          is_nil(v) ->
            acc

          true ->
            Map.put(acc, String.to_existing_atom(k), v)
        end
      end)

    # Assignee routing: either strip the flat pair entirely (structured
    # wins OR we're auto-routing to phase_attrs), or emit it as flat.
    {flat_attrs, phase_attrs_from_flat} =
      cond do
        strip_flat_assignee? and auto_route ->
          # Auto-route: lift the flat pair into a phase_attrs entry.
          case build_phase_entry_from_flat(flat_pair) do
            nil -> {flat_attrs, nil}
            entry -> {flat_attrs, %{current_phase => entry}}
          end

        strip_flat_assignee? ->
          # Structured phase_assignees was supplied — drop the flat pair
          # silently (they lose the tie).
          {flat_attrs, nil}

        true ->
          # No auto-route, no structured input — emit the flat pair as-is
          # (drop nil values per the standard rule).
          merged =
            Enum.reduce(flat_pair, flat_attrs, fn {k, v}, acc ->
              if is_nil(v),
                do: acc,
                else: Map.put(acc, String.to_existing_atom(k), v)
            end)

          {merged, nil}
      end

    {:ok, flat_attrs, phase_attrs_from_flat}
  end

  defp build_phase_entry_from_flat(%{"assignee_id" => id, "assignee_type" => type})
       when is_binary(id) and is_binary(type),
       do: %{"assignee_id" => id, "assignee_type" => type}

  defp build_phase_entry_from_flat(%{"assignee_id" => id}) when is_binary(id),
    do: %{"assignee_id" => id, "assignee_type" => "agent"}

  defp build_phase_entry_from_flat(_), do: nil

  # ── Phase attrs merge ───────────────────────────────────────────────────

  defp merge_phase_attrs(nil, nil), do: nil
  defp merge_phase_attrs(struct, nil), do: struct
  defp merge_phase_attrs(nil, from_flat), do: from_flat

  defp merge_phase_attrs(struct, _from_flat) do
    # Structured phase_assignees wins; the auto-route branch never fires
    # in this case (see `strip_flat_assignee? and auto_route` guard) but
    # keep the merge defensive.
    struct
  end

  # ── Auto-approve precondition ───────────────────────────────────────────

  @auto_approve_required_phases ~w(execution review)

  @typedoc """
  Structured reject envelope emitted when the auto-approve precondition
  fails. `missing_phases` keeps stable `[\"execution\", \"review\"]`
  ordering; `reasons` is a per-phase atom
  (`:absent | :non_agent_type | :agent_not_found`).
  """
  @type auto_approve_precondition_error ::
          {:auto_approve_precondition_missing,
           %{missing_phases: [String.t()], reasons: %{String.t() => atom()}}}

  @doc """
  Hard-reject the write when `auto_approve_plan` is (or will be) `true`
  but the execution and/or review phases don't resolve to a live agent.

  Called by `Platform.Federation.ToolSurface` from both `task_create`
  and `task_update` after `build_task_attrs/3` has auto-routed the flat
  `assignee_id + assignee_type` pair into `phase_attrs[\"planning\"]`
  per ADR 0044. The precondition inspects the execution + review slots
  (never planning) because auto-approve exists to save Rowan the click on
  the plan-review gate that runs immediately AFTER planning, and the
  execution + review agents are the ones actually dispatched.

  ## Gate

    * `flat_attrs[:auto_approve_plan] == false` → `:ok` (explicit-false
      always skips; regression trap for tasks toggling auto-approve off).
    * `flat_attrs[:auto_approve_plan] == true` → gate opens (create path
      or update flipping to true).
    * Key absent AND `existing_task.auto_approve_plan == true` AND
      `phase_attrs != nil` → gate opens (an update that rewrites a
      phase slot under a still-true flag still has to satisfy the
      invariant).
    * Otherwise → `:ok`.

  ## Check

  For each phase in `[\"execution\", \"review\"]`, read the merged slot
  (`(existing_task && existing_task.phase_assignees) || %{}` merged over
  `phase_attrs || %{}`). Reject when any of:

    * slot is `nil` / absent / not a map → reason `:absent`
    * `slot[\"assignee_type\"] != \"agent\"` → reason `:non_agent_type`
      (users NEVER satisfy the precondition even if the id resolves)
    * resolver returns `nil` for `slot[\"assignee_id\"]` → reason
      `:agent_not_found`

  ## Opts

    * `:agent_resolver` — 1-arity function called with a binary agent
      id, returning the agent struct or `nil`. Defaults to
      `&Platform.Repo.get(Platform.Agents.Agent, &1)`. Tests inject a
      stub to stay Repo-free.

  Returns `:ok` or `{:error, {:auto_approve_precondition_missing, %{...}}}`.
  """
  @spec check_auto_approve_preconditions(
          map(),
          map() | nil,
          Platform.Tasks.Task.t() | nil,
          keyword()
        ) ::
          :ok | {:error, auto_approve_precondition_error()}
  def check_auto_approve_preconditions(flat_attrs, phase_attrs, existing_task, opts \\ [])
      when is_map(flat_attrs) do
    if auto_approve_gate_open?(flat_attrs, phase_attrs, existing_task) do
      resolver = Keyword.get(opts, :agent_resolver, &default_agent_resolver/1)
      merged = merged_phase_assignees(existing_task, phase_attrs)

      {missing_phases, reasons} =
        Enum.reduce(@auto_approve_required_phases, {[], %{}}, fn phase, {missing, reasons} ->
          case classify_phase_slot(Map.get(merged, phase), resolver) do
            :ok ->
              {missing, reasons}

            {:missing, reason} ->
              {missing ++ [phase], Map.put(reasons, phase, reason)}
          end
        end)

      case missing_phases do
        [] ->
          :ok

        phases ->
          {:error,
           {:auto_approve_precondition_missing, %{missing_phases: phases, reasons: reasons}}}
      end
    else
      :ok
    end
  end

  defp auto_approve_gate_open?(flat_attrs, phase_attrs, existing_task) do
    case Map.get(flat_attrs, :auto_approve_plan, :missing) do
      false ->
        false

      true ->
        true

      :missing ->
        # Update that leaves auto_approve_plan alone. Only open the gate
        # if the existing task already has auto_approve_plan=true AND the
        # caller is modifying phase_assignees in this call (otherwise the
        # invariant is already satisfied by whatever created the row).
        case existing_task do
          %{auto_approve_plan: true} -> not is_nil(phase_attrs)
          _ -> false
        end
    end
  end

  defp merged_phase_assignees(existing_task, phase_attrs) do
    existing =
      case existing_task do
        %{phase_assignees: %{} = m} -> m
        _ -> %{}
      end

    Map.merge(existing, phase_attrs || %{})
  end

  defp classify_phase_slot(nil, _resolver), do: {:missing, :absent}
  defp classify_phase_slot(slot, _resolver) when not is_map(slot), do: {:missing, :absent}

  defp classify_phase_slot(slot, resolver) do
    cond do
      Map.get(slot, "assignee_type") != "agent" ->
        {:missing, :non_agent_type}

      not is_binary(Map.get(slot, "assignee_id")) ->
        {:missing, :agent_not_found}

      is_nil(resolver.(Map.get(slot, "assignee_id"))) ->
        {:missing, :agent_not_found}

      true ->
        :ok
    end
  end

  defp default_agent_resolver(id), do: Platform.Repo.get(Platform.Agents.Agent, id)

  # ── Utilities ───────────────────────────────────────────────────────────

  defp stringify_keys(args) do
    for {k, v} <- args, into: %{} do
      {to_string(k), v}
    end
  end
end
