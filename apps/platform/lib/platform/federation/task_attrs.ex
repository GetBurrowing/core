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
    * On `:create` with a truthy `auto_approve_plan` arg and an
      agent-typed flat pair, the flat agent FANS OUT into every ABSENT
      one of the three phase slots (`planning`, `execution`, `review`)
      instead of only the current-phase slot — the auto-approve
      precondition requires agent-resolved execution + review, which
      planning-only routing can never satisfy. Explicit
      `phase_assignees` entries (including an explicitly-nil slot) are
      never overwritten. On `:update` the same fill runs only when the
      caller passes the task's persisted slots via
      `existing_phase_assignees: map`: the fill is then keyed off the
      MERGED map (persisted slots overlaid by this call's routed
      slots), so a present slot is never a fill candidate — the clobber
      an update-mode fill was once feared to cause cannot occur, because
      `set_phase_assignees/2` merges per-slot and a merged-keyed fill
      never names an assigned slot. Without that opt, `:update` routing
      is byte-for-byte unchanged (planning-only).
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
        * `:existing_phase_assignees` — the task's persisted per-phase
          slots (string- or atom-keyed map), or `nil`. Consulted ONLY by
          the `:update` auto-approve fill; `:create` ignores it.

  ## Auto-approve fan-out (ADR 0044 §5, tasks 01a05877 + 01a0589b)

  When the auto-route opts are on, the args carry a truthy
  `auto_approve_plan`, and the flat pair is agent-typed (`assignee_id` a
  non-empty binary; `assignee_type` absent or exactly `"agent"`), the
  emitted `phase_attrs` fills every ABSENT one of `"planning"`,
  `"execution"`, `"review"` with the flat agent entry. The fill is
  keyed off the MERGED map — the task's persisted slots overlaid by
  this call's routed slots — so a present slot (including an
  explicitly-nil one) is never overwritten.

  The two modes differ only in what that merge sees. On `:create`
  there are no persisted slots, so the fill runs on the routed map
  exactly as before. On `:update` the merge runs only when the caller
  supplies the persisted slots via `:existing_phase_assignees` (a map);
  the merged-with-fills map is then the emitted `phase_attrs`, and
  re-emitting the persisted slots through it is harmless because
  `Tasks.set_phase_assignees/2` merges per-slot. With the opt absent,
  `:update` routing is byte-for-byte unchanged (planning-only) — the
  opt gate is the mutation-probe surface for that contract. The fill
  does no DB access — agent liveness stays the precondition's job: an
  unknown agent id filled into `execution` or `review` still refuses
  with `:agent_not_found` there.

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
    existing_phase_assignees = Keyword.get(opts, :existing_phase_assignees)

    with {:ok, phase_attrs_from_struct} <- extract_phase_assignees(args),
         {:ok, current_phase} <- resolve_current_phase(opts, args),
         {:ok, auto_route} <- resolve_auto_route(opts, current_phase),
         {:ok, flat_attrs, phase_attrs_from_flat} <-
           build_flat_attrs(args, mode, auto_route, current_phase, phase_attrs_from_struct) do
      merged_phase_attrs = merge_phase_attrs(phase_attrs_from_struct, phase_attrs_from_flat)

      {:ok, flat_attrs,
       maybe_fanout_auto_approve(
         merged_phase_attrs,
         args,
         mode,
         auto_route,
         existing_phase_assignees
       )}
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

  # ── Auto-approve fan-out (ADR 0044 §5, tasks 01a05877 + 01a0589b) ───────
  #
  # An agent-typed flat pair under `auto_approve_plan: true` fans out
  # into every ABSENT one of the planning / execution / review slots,
  # because the auto-approve precondition (below) requires agent-resolved
  # execution AND review slots that planning-only auto-routing can never
  # satisfy — task_create with the flag and a flat agent pair refused
  # unconditionally before this fill existed.
  #
  # The fill is keyed off the MERGED map — the task's persisted slots
  # overlaid by this call's routed slots — so a slot that is already
  # assigned is never a fill candidate. That is what makes the `:update`
  # fill safe: `Tasks.set_phase_assignees/2` merges per-slot over the
  # persisted map, so a fill keyed off the routed map alone would overlay
  # (clobber) live assignments, while a merged-keyed fill cannot name
  # one. On `:create` there are no persisted slots, so merged == routed
  # and the two are the same fill. Both modes share
  # `fill_absent_fanout_slots/2` — which phases count as "missing" IS the
  # whole precondition, so the slot-filling core must not drift between
  # them.
  #
  # The `:update` fill fires ONLY when the caller passes the persisted
  # slots via the `:existing_phase_assignees` opt; callers that do not
  # (every one of them until the task_update surface supplies it) keep
  # today's planning-only routing, byte-for-byte. The opt gate is the
  # mutation-probe surface for that contract.
  #
  # The fill does no DB access — agent liveness is the precondition's
  # job, so an unknown agent id filled into `execution` or `review`
  # still refuses with `:agent_not_found` there. Without the flag the
  # routing is byte-for-byte unchanged (planning-only) in BOTH modes.

  @auto_approve_fanout_phases ~w(planning execution review)

  defp maybe_fanout_auto_approve(phase_attrs, args, mode, auto_route, existing_phase_assignees) do
    cond do
      not auto_approve_fanout?(args, mode, auto_route, existing_phase_assignees) ->
        phase_attrs

      mode == :create ->
        # No persisted slots exist on :create — the fill runs on the
        # routed map exactly as before, and the opt is never consulted.
        fill_absent_fanout_slots(phase_attrs || %{}, flat_agent_entry(args))

      true ->
        # :update: fill the merged map. Persisted slots re-emitted
        # through it are harmless — set_phase_assignees/2 merges
        # per-slot — and an explicitly-nil routed slot still overlays
        # its persisted slot, stays nil, and trips the precondition.
        persisted = stringify_keys(existing_phase_assignees || %{})
        merged = Map.merge(persisted, phase_attrs || %{})

        fill_absent_fanout_slots(merged, flat_agent_entry(args))
    end
  end

  defp auto_approve_fanout?(args, mode, auto_route, existing_phase_assignees) do
    auto_route == true and
      auto_approve_flag_on?(args) and
      agent_typed_flat_pair?(args) and
      mode_gate_open?(mode, existing_phase_assignees)
  end

  # :create gates open unconditionally. :update opens only when the
  # caller supplied the persisted slots via :existing_phase_assignees —
  # the opt gate that keeps non-opting :update callers byte-for-byte
  # unchanged. A non-map value counts as not supplied.
  defp mode_gate_open?(:create, _existing), do: true
  defp mode_gate_open?(:update, existing), do: is_map(existing)

  # Truthy means the key is present and neither nil nor false.
  defp auto_approve_flag_on?(args) do
    case Map.get(args, "auto_approve_plan") do
      value when value in [nil, false] -> false
      _ -> true
    end
  end

  # Agent-typed flat pair: `assignee_id` a non-empty binary;
  # `assignee_type` absent or exactly "agent" (absent means agent,
  # mirroring `build_phase_entry_from_flat/1`). Any other value means no
  # fan-out — a user-typed flat assignee never satisfies the
  # auto-approve precondition.
  defp agent_typed_flat_pair?(%{"assignee_id" => id} = args)
       when is_binary(id) and id != "",
       do: Map.get(args, "assignee_type") in [nil, "agent"]

  defp agent_typed_flat_pair?(_args), do: false

  defp flat_agent_entry(args),
    do: %{"assignee_id" => args["assignee_id"], "assignee_type" => "agent"}

  defp fill_absent_fanout_slots(phase_attrs, entry) do
    Enum.reduce(@auto_approve_fanout_phases, phase_attrs, fn phase, acc ->
      # A key the caller supplied is never overwritten — including an
      # explicitly-nil slot, which stays nil and then trips the
      # precondition (the caller deliberately cleared a slot the flag
      # requires).
      if Map.has_key?(acc, phase), do: acc, else: Map.put(acc, phase, entry)
    end)
  end

  # ── Auto-approve precondition ───────────────────────────────────────────

  @auto_approve_required_phases ~w(execution review)

  @typedoc """
  Structured reject payload emitted when the auto-approve precondition
  fails. `missing_phases` keeps stable `[\"execution\", \"review\"]`
  ordering; `reasons` is a per-phase atom
  (`:absent | :non_agent_type | :agent_not_found`);
  `merged_phase_assignees` is the exact slot map the check read —
  existing task slots overlaid with the build's routed slots — so the
  caller can judge whether a mechanical correction (see
  `auto_approve_corrected_args/3`) can repair the refusal.
  """
  @type auto_approve_precondition_error ::
          {:auto_approve_precondition_missing,
           %{
             missing_phases: [String.t()],
             reasons: %{String.t() => atom()},
             merged_phase_assignees: %{String.t() => map() | nil}
           }}

  @doc """
  Hard-reject the write when `auto_approve_plan` is (or will be) `true`
  but the execution and/or review phases don't resolve to a live agent.

  Called by `Platform.Federation.ToolSurface` from both `task_create`
  and `task_update` after `build_task_attrs/3` has routed the flat
  `assignee_id + assignee_type` pair into `phase_attrs` per ADR 0044 —
  planning-only without the flag, every absent one of the three slots
  under the auto-approve fan-out (`:create` on the routed slots;
  `:update` only behind the `:existing_phase_assignees` opt, keyed off
  the merged map). The precondition inspects
  the execution + review slots
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
           {:auto_approve_precondition_missing,
            %{
              missing_phases: phases,
              reasons: reasons,
              merged_phase_assignees: merged
            }}}
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

  # ── Auto-approve corrected args (task 01a05877 stage 2) ─────────────────

  @doc """
  Mechanical `corrected_args` for a refused auto-approve precondition:
  the submitted tool arguments with `phase_assignees` completed so a
  resubmission satisfies the gate — or `nil` when no mechanical repair
  exists and the caller must choose an agent id.

  Called by `Platform.Federation.ToolSurface` from both the task_create
  and task_update `auto_approve_precondition_missing` envelope sites, so
  the two tools answer by one rule. The returned map travels in the
  RESPONSE ENVELOPE ONLY — never a log line, never telemetry (the args
  carry user content; docs/decisions/0005).

  ## Rule (all must hold for a non-nil return)

    * the submitted args carry a flat agent-typed assignee:
      `assignee_id` a non-empty binary with `assignee_type` absent or
      exactly `"agent"` (the same predicate the `:create` fan-out uses);
    * `auto_approve_plan` is truthy in the submitted args;
    * every failing phase is ABSENT in `merged_phase_assignees` — the
      same merge the precondition read (existing task slots overlaid
      with the build's routed slots). A failing slot that is
      present-but-invalid (user-typed, unknown id) or present-but-nil
      (explicitly cleared) cannot be repaired by filling, so the caller
      must choose an agent id and `nil` comes back.

  ## Completion

    * starts from the submitted `phase_assignees` (string-keyed);
    * fills every ABSENT one of `planning` / `execution` / `review`
      with the flat agent entry — explicit submitted keys are never
      overwritten (same posture as the `:create` fan-out);
    * returns the submitted args with `phase_assignees` replaced by the
      completed map, string-keyed.

  After the `:create` fan-out landed (task 01a05877 stage 1), a
  task_create refusal this repair could fix already succeeds. The
  `:update` fill (task 01a0589b, keyed off the merged map behind
  `:existing_phase_assignees`) pre-empts every mechanical repair the
  same way once the task_update surface supplies the persisted slots:
  a refusal it could fix already succeeds, so on that path this helper
  is DORMANT-BY-SUCCESS. It is KEPT — logic and tests unchanged — as
  the fallback for refusals the fill did not prevent: callers that do
  not opt in, and failing slots no fill can repair (present-but-invalid
  user-typed, unknown id, or an explicitly-cleared nil slot). Both call
  sites run the same rule regardless.
  """
  @spec auto_approve_corrected_args(map(), map() | nil, [String.t()]) ::
          %{String.t() => term()} | nil
  def auto_approve_corrected_args(args, merged_phase_assignees, missing_phases)
      when is_map(args) and is_list(missing_phases) do
    args = stringify_keys(args)
    merged = merged_phase_assignees || %{}

    mechanical_repair? =
      agent_typed_flat_pair?(args) and
        auto_approve_flag_on?(args) and
        Enum.all?(missing_phases, fn phase -> not Map.has_key?(merged, phase) end)

    if mechanical_repair? do
      submitted_slots =
        case Map.get(args, "phase_assignees") do
          slots when is_map(slots) -> stringify_keys(slots)
          _ -> %{}
        end

      completed = fill_absent_fanout_slots(submitted_slots, flat_agent_entry(args))

      Map.put(args, "phase_assignees", completed)
    else
      nil
    end
  end

  # ── Utilities ───────────────────────────────────────────────────────────

  defp stringify_keys(args) do
    for {k, v} <- args, into: %{} do
      {to_string(k), v}
    end
  end
end
