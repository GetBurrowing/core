defmodule PlatformWeb.Tasks.TaskDisplay do
  @moduledoc """
  Pure display helpers shared by the Tasks surface's shell template and its
  extracted LiveComponents (task 01a008f6 stage 4).

  Every function here is a pure `data -> string / tuple` mapping with no
  socket and no LiveView. They were private to `PlatformWeb.TasksLive` until
  the detail panel moved into `PlatformWeb.Tasks.TaskDetailComponent` — the
  board (shell) and the detail panel both render them, so they had to become
  a shared module rather than be duplicated into the component.

  Follows the same shape as `PlatformWeb.Tasks.StackStyles` and
  `PlatformWeb.Tasks.StatusLabels`, which stages 2 and 3 hoisted for the
  same reason.
  """

  alias Platform.Chat.SidebarMask
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias Platform.Tenancy

  import PlatformWeb.Tasks.StatusLabels, only: [status_label: 1]

  # The chip component (`core_components.ex` `chip/1`) emits exactly
  # `chip-soft chip-#{tone}`. This call site is a `{label, class}` TUPLE
  # shared by four render sites, so a component cannot be returned — we
  # emit the component's own classes instead so the rendered span is
  # byte-identical, dark mode included (declared canvas deviation,
  # approved on the design canvas rev 4).
  #
  # THE TWO CLASSES ARE A PAIR. `chip-warning` alone sets only
  # `--chip-label`: no tint, no padding, no radius — it renders as bare
  # amber text where a chip should be. The component made that
  # unrepresentable; a tuple of strings makes it a typo, one edit degrades
  # all four call sites at once, and it survives a screenshot. The
  # both-classes assertion in the test suite is the only thing that
  # catches it. Do not split this string.
  @needs_merge_chip_class "chip-soft chip-warning"

  @doc """
  Task-aware status badge, keyed on the ALREADY-RESOLVED human-action
  reason from `Tasks.needs_human_action_reason/2`.

  `action_reason` is the second argument on purpose. Before task 01a01a4a
  stage 5 this function re-derived the merge gate itself from
  `metadata["awaiting_human_action"] == "merge"`, which made it a SECOND
  decider alongside the resolver's precedence `cond`. The two disagreed
  exactly when precedence demoted the merge gate: a `deploying` task with
  BOTH the merge stamp and an open pending review_request resolved to
  `:review_request_pending` for every reason-keyed consumer, while this
  function still emitted the `needs merge` chip — so the card carried the
  chip AND the review badge, two "needs you" marks that overflowed the
  card at 1280px. The fix is not another clause; it is deleting the second
  decider. One resolver, consulted by every render site.

  Emits the warning-toned `needs merge` chip in place of the neutral
  `deploying` chip when — and only when — the resolved reason is
  `:awaiting_human_merge`. Replace, never add: `board_component.ex` has
  settled the doubled-chip question twice (`:1394-1400`, `:1406-1417`),
  and this one function feeds all four card call sites.

  Also: when a task is in `planning` AND has a plan waiting on human
  review, surface "Plan Ready" with a warning badge to signal
  action-needed. All other cases fall through to `status_label/1` with the
  neutral outline badge. Requires `:plans` preloaded — both
  `Tasks.list_all_tasks/1` and `Tasks.get_task_detail/1` do this.

  ## Why there is no default for `action_reason`

  This function is the single source of truth for "needs you" precedence
  (task 01a01a4a deleted the second decider that re-derived it from
  `metadata["awaiting_human_action"]`). It takes NO default on purpose: an
  omitted reason would resolve to `nil`, match no `:awaiting_human_merge`
  clause, and render the neutral `Deploying` chip — a wrong output that
  looks plausible, and that neither a screenshot nor a green suite would
  surface. Arity is the guard. A caller that cannot resolve a reason must
  pass an explicit value so the decision is visible at the call site; a
  caller that omits it fails to compile (`undefined function
  task_display_status/1`) instead of silently rendering the wrong chip.
  """
  def task_display_status(%Task{status: "deploying"} = _task, :awaiting_human_merge) do
    {"needs merge", @needs_merge_chip_class}
  end

  # Task 01a0665e stage 1: a merged PR on a task that is still open. Any
  # status — the resolver ranks it first — and the same chip pair as the
  # merge gate, for the same reason: a person has to act, not an agent.
  def task_display_status(%Task{} = _task, :delivered_but_open) do
    {"delivered, close it", @needs_merge_chip_class}
  end

  def task_display_status(%Task{status: "planning", plans: plans} = _task, _action_reason)
      when is_list(plans) do
    if Enum.any?(plans, &(&1.status == "pending_review")) do
      {"Plan Ready", "badge badge-warning"}
    else
      {status_label("planning"), "badge badge-outline"}
    end
  end

  def task_display_status(%Task{status: status} = _task, _action_reason) do
    {status_label(status), "badge badge-outline"}
  end

  def priority_badge_class("critical"), do: "badge badge-error badge-sm"
  def priority_badge_class("high"), do: "badge badge-error badge-outline badge-sm"
  def priority_badge_class("medium"), do: "badge badge-warning badge-outline badge-sm"
  def priority_badge_class("low"), do: "badge badge-success badge-outline badge-sm"
  def priority_badge_class(_), do: "badge badge-ghost badge-sm"

  def assignee_name(%Task{assignee_type: "agent", assignee_id: id}, agent_names)
      when is_binary(id) do
    Map.get(agent_names, id, "Agent")
  end

  def assignee_name(%Task{assignee_type: "user"}, _agent_names), do: "User"

  def assignee_name(_, _), do: nil

  def current_phase_label(%{} = task), do: Tasks.current_phase(task)

  def phase_assignee_id(%{phase_assignees: pa}, phase) when is_map(pa) do
    case Map.get(pa, phase) do
      %{"assignee_id" => id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  def phase_assignee_id(_, _), do: nil

  def agent_name_for(_agents_by_id, nil), do: nil

  def agent_name_for(agents_by_id, agent_id) when is_map(agents_by_id) do
    case Map.get(agents_by_id, agent_id) do
      %{name: name} -> name
      _ -> nil
    end
  end

  @doc """
  Display name for the sponsor if set, or `nil` so the template can `:if`
  the whole row away when there's no sponsor. Falls back to `email` when
  `name` is blank, and to a sentinel string when the FK points at a user
  that no longer exists in the local `users_by_id` map.
  """
  def sponsor_name(%Task{sponsor_user_id: nil}, _users_by_id), do: nil

  def sponsor_name(%Task{sponsor_user_id: id}, users_by_id) when is_binary(id) do
    case Map.get(users_by_id, id) do
      nil -> "Unknown user"
      user -> user.name || user.email
    end
  end

  def sponsor_name(_, _), do: nil

  @doc """
  Authoritative sponsor gate for BOTH the DOM `:if` (pin button rendered
  only for the task sponsor) AND the server-side re-check inside the
  pin/unpin handler.
  """
  def sponsor?(%Task{sponsor_user_id: sponsor_id}, user_id)
      when is_binary(sponsor_id) and is_binary(user_id),
      do: sponsor_id == user_id

  def sponsor?(_task, _user_id), do: false

  def pinned_by_me?(%Task{id: id}, user_id, %MapSet{} = pinned_ids)
      when is_binary(user_id),
      do: MapSet.member?(pinned_ids, id)

  def pinned_by_me?(_task, _user_id, _pinned_ids), do: false

  def project_deploy_targets(%{deploy_config: %{"deploy_targets" => targets}})
      when is_list(targets) do
    targets
    |> Enum.map(fn
      %{"name" => n} when is_binary(n) -> n
      n when is_binary(n) -> n
      _ -> nil
    end)
    |> Enum.filter(& &1)
  end

  def project_deploy_targets(_), do: []

  def deploy_target_label("hive_production"), do: "Hive Production"
  def deploy_target_label("github_pr"), do: "GitHub PR"
  def deploy_target_label("google_drive"), do: "Google Drive"
  def deploy_target_label(other), do: other

  def deletable_task?(%Task{} = task), do: Task.deletable?(task)
  def deletable_task?(_), do: false

  def relative_time(nil), do: ""

  def relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end

  def relative_time(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> relative_time()
  end

  # Cheap, per-card. Reads `metadata["unmet_dependencies"]` set by
  # `Tasks.create_task/_/transition_*` whenever a task is parked or
  # partially unblocked. No DB hit.
  #
  # Lives here rather than in a component because BOTH read it: the board's
  # card-face "Blocked · N" badge and the detail panel's
  # `blocked_explanation/1` dispatcher. It was private to `BoardComponent`
  # until task 01a004ad's explanation panel needed the same count from the
  # detail side; duplicating six pure lines across two components is the
  # only alternative and would let the two counts drift.
  def unmet_dependency_count(%Task{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("unmet_dependencies", [])
    |> length()
  end

  def unmet_dependency_count(_), do: 0

  # ── Screen-share masking for the Tasks rail (task 01a00cf1) ────────────

  @doc """
  ONE FLAT MAP of every masked string the Tasks rail needs, keyed
  `{:org, slug}`, `{:project, id}` and `{:epic, id}`.

  RESOLVE ONCE PER ENTRY. This map is the ONLY masked-string source for the
  rail: no render site may call `SidebarMask` itself. The sibling task
  `01a00c66` lost a full cycle to exactly that defect — `aria-label`, `title`
  and `data-*` kept the real name while the visible text was masked, because
  each surface resolved its own string and only the display form was covered
  by a test. A single map makes the attribute surface and the text surface the
  same value by construction.

  `project_sections` is the `{org_slug, org_name, projects}` three-tuple list
  produced by `PlatformWeb.Tasks.LifecycleHooks.project_sections/2`. Note the
  org's DISPLAY NAME is `Tenancy.scope_label(org_slug)`, which is what the rail
  actually renders — NOT the tuple's `org_name`, which the rail ignores. The
  unmasked branch must return what the rail would otherwise have shown, so the
  `scope_label/1` call is the real name here. It is pure and DB-free.

  Orgs letter in `project_sections` order; projects letter in FLATTENED RAIL
  ORDER across all orgs; epics letter in `epics` (display) order — each kind
  counts from `A` under its own prefix.

  EPICS ARE IN THIS MAP because an epic is an ENTITY WITH AN ID AND A NAME,
  structurally identical to a project and reachable by the same lookup. The
  breadcrumb renders one directly above the masked rail, so an unmasked epic
  name there does not merely leak — it makes the masked rail beside it read as
  broken. Task titles remain out of scope: they are free text with no lookup
  table behind them.
  """
  @spec mask_labels([{binary(), binary(), list()}], boolean(), MapSet.t() | [binary()], list()) ::
          map()
  def mask_labels(project_sections, masked?, revealed_ids, epics \\ [])
      when is_list(project_sections) and is_list(epics) do
    org_entries =
      Enum.map(project_sections, fn {slug, _org_name, _projects} ->
        {slug, Tenancy.scope_label(slug)}
      end)

    project_entries =
      Enum.flat_map(project_sections, fn {_slug, _org_name, projects} ->
        Enum.map(projects, &{&1.id, &1.name})
      end)

    epic_entries = Enum.map(epics, &{&1.id, &1.name})

    org_placeholders = SidebarMask.placeholders(org_entries, "Workspace")
    project_placeholders = SidebarMask.placeholders(project_entries, "Project")
    epic_placeholders = SidebarMask.placeholders(epic_entries, "Epic")

    orgs =
      Map.new(org_entries, fn {slug, name} ->
        {{:org, slug}, SidebarMask.label(org_placeholders, slug, name, masked?, revealed_ids)}
      end)

    epics_map =
      Map.new(epic_entries, fn {id, name} ->
        {{:epic, id}, SidebarMask.label(epic_placeholders, id, name, masked?, revealed_ids)}
      end)

    project_entries
    |> Map.new(fn {id, name} ->
      {{:project, id}, SidebarMask.label(project_placeholders, id, name, masked?, revealed_ids)}
    end)
    |> Map.merge(orgs)
    |> Map.merge(epics_map)
  end

  @doc """
  Read ONE label out of `mask_labels/3`'s map.

  FAIL-CLOSED, and this is the only reason the function exists rather than a
  bare `@mask_labels[key]` at each render site: a key with no entry returns the
  BARE PREFIX for its kind, never the real name and never `nil`. A miss is
  precisely the case where the rail and the map have desynced — a project
  created between the two assigns — and the wrong direction to be wrong in is
  the one that puts the real name on a shared screen.

  Mirrors `Platform.Chat.SidebarMask.label/5`'s fail-closed branch verbatim in
  effect; the branch is preserved here rather than re-derived so the two cannot
  drift.
  """
  @spec rail_label(map(), {:org, binary()} | {:project, binary()} | {:epic, binary()}) :: binary()
  def rail_label(mask_labels, {:org, _slug} = key) when is_map(mask_labels),
    do: Map.get(mask_labels, key) || "Workspace"

  def rail_label(mask_labels, {:project, _id} = key) when is_map(mask_labels),
    do: Map.get(mask_labels, key) || "Project"

  def rail_label(mask_labels, {:epic, _id} = key) when is_map(mask_labels),
    do: Map.get(mask_labels, key) || "Epic"

  @doc """
  `rail_label/2` for surfaces whose ENTITY SET IS WIDER than the rail's.

  The rail's rows come from `project_sections`, which is exactly what
  `mask_labels/3` was built from, so `rail_label/2` alone is right there: every
  key is present and a miss means a desync. Four other surfaces are not like
  that. The project-create sheet's org `<select>` lists `@orgs`, which includes
  orgs with no projects; the scope rail lists `Tasks.scope_keys/0`, which is a
  fixed enum. Both legitimately hold entities the map has never heard of.

  On those surfaces a bare `rail_label/2` would render `Workspace` for a real,
  unmasked org — the mask leaking into the UNMASKED mode, which is a plain bug
  and the sort that gets shipped because every masked test still passes. So the
  masked-ness is passed in explicitly:

    * `masked? == false` — return `real`, the string the surface would have
      rendered with no masking in the picture at all.
    * `masked? == true` — defer to `rail_label/2`, which is FAIL-CLOSED: a key
      with no entry yields the bare prefix, never `real`.

  `real` is a keyword rather than a positional argument so the call sites read
  as `real: project.name` — at four render sites the two strings are adjacent
  and a transposed pair would silently un-mask.
  """
  @spec label_for(
          map(),
          boolean(),
          {:org, binary()} | {:project, binary()} | {:epic, binary()},
          keyword()
        ) :: binary()
  def label_for(mask_labels, masked?, key, opts) when is_map(mask_labels) do
    if masked?, do: rail_label(mask_labels, key), else: Keyword.fetch!(opts, :real)
  end

  @doc """
  The `label` override for `PlatformWeb.Components.ScopePill`, or `nil`.

  `nil` is meaningful and is the unmasked answer: the pill's own
  `scope_label/1` then renders, unchanged, exactly as it did before this task.
  Returning a string in that case would hand the pill a second copy of a label
  it already knows how to compute — and the copy is what drifts.

  While masked this returns the SAME string the rail's org row shows, out of
  the same map, so a `Workspace B` chip in the scope rail and a `Workspace B`
  section in the sidebar are the same workspace. Scope keys the map has no
  entry for (an org with no projects, or one this viewer cannot see) fall
  through to the bare `Workspace` prefix — fail-closed, per `rail_label/2`.
  """
  @spec scope_pill_label(map(), boolean(), atom()) :: binary() | nil
  def scope_pill_label(_mask_labels, false, _scope), do: nil

  def scope_pill_label(mask_labels, true, scope) when is_map(mask_labels) and is_atom(scope),
    do: rail_label(mask_labels, {:org, Atom.to_string(scope)})

  @doc """
  The scope rail's `data-scope-chip` value — the same leak class as the rail's
  `data-org-slug`, and masked for the same reason.

  `data-scope-chip="wayne-tech"` survives `refute html =~ "Wayne-Tech"` untouched,
  and it is legible in the DOM inspector a screen share is quite likely to have
  open. Nothing in `lib/` or `assets/` reads it — only tests, as an inspection
  handle — so it is free to follow the label, exactly as `rail_org_slug/2`
  established for the sidebar.

  `phx-value-scope`, one attribute over on the same element, now carries THE
  SAME ALIAS. It is the filter's ARGUMENT, so it cannot simply be blanked — but
  an argument does not have to be spelled with the real slug.
  `FiltersComponent`'s `parse_scope/2` resolves the alias back through
  `real_org_slug/2` before filtering, so the chip still filters to the org it
  names while the raw slug never reaches the DOM at all.
  """
  @spec scope_pill_slug(map(), boolean(), atom()) :: binary()
  def scope_pill_slug(_mask_labels, false, scope) when is_atom(scope), do: Atom.to_string(scope)

  def scope_pill_slug(mask_labels, true, scope) when is_map(mask_labels) and is_atom(scope),
    do: rail_org_slug(mask_labels, Atom.to_string(scope))

  @doc """
  The value for the rail's `data-org-slug` attribute.

  A REAL LEAK IN ATTRIBUTE FORM. `data-org-slug="wayne-tech"` survives
  `refute html =~ "Wayne-Tech"` completely untouched: org slugs are stored
  underscored and rendered hyphenated, so an assertion written against the
  display form proves nothing at all about this attribute — and this attribute
  is legible in the DOM inspector a screen share is quite likely to have open.

  Nothing in the app READS it (checked: `assets/`, `lib/`, and the two Tasks
  test files that assert on it all treat it as an inspection handle only), so
  it is free to follow the label. While the org is masked it carries the
  PLACEHOLDER's slug — `workspace-a` — and while unmasked or individually
  revealed it carries the real slug unchanged.

  Derived from the resolved label rather than from a `masked?` boolean on
  purpose: the map is the single source of truth for whether this org is
  currently showing its real name, so the attribute cannot disagree with the
  text beside it.
  """
  @spec rail_org_slug(map(), binary()) :: binary()
  def rail_org_slug(mask_labels, org_slug) when is_map(mask_labels) do
    case Map.get(mask_labels, {:org, org_slug}) do
      nil -> "workspace"
      label -> if label == Tenancy.scope_label(org_slug), do: org_slug, else: slugify(label)
    end
  end

  @doc """
  Invert `rail_org_slug/2`: map an org identifier that CAME BACK FROM THE DOM
  onto the real org slug the server acts on.

  Org rows were the last surface in this feature still routing by a
  human-readable slug — `phx-value-id`, `phx-value-key`, `data-menu-key` and
  `phx-value-scope` all spelled `soylent` while the row above them read
  `Workspace B`. Project rows already route by UUID, so the inconsistency was
  with work this same feature had already done.

  The fix is an ALIAS, not a UUID, because the org slug genuinely IS the
  routing key here in a way a project's is not: `Tenancy.scope_label/1`,
  `Tasks.scope_keys/0`, the lifecycle resolver and this module's own
  `mask_labels/4` keys are all slug-keyed, and `revealed_rail_ids` matches on
  the same string. Re-keying all of them on an org UUID is a different change
  from closing this leak. So the DOM carries the per-session placeholder slug
  (`workspace-b`) out of the SAME map the label came from, and every handler
  that receives one resolves it here before acting.

  UNMASKED AND REVEALED ORGS ARE UNAFFECTED: `rail_org_slug/2` emits the real
  slug in both cases, so the lookup below finds it and returns it unchanged. An
  identifier this map has never heard of (a scope key with no org section, the
  literal `"all"`) is returned VERBATIM — the caller's own allowlist is what
  rejects it, exactly as before.
  """
  @spec real_org_slug(map(), binary()) :: binary()
  def real_org_slug(mask_labels, emitted) when is_map(mask_labels) and is_binary(emitted) do
    Enum.find_value(mask_labels, emitted, fn
      {{:org, slug}, _label} -> if rail_org_slug(mask_labels, slug) == emitted, do: slug
      _ -> nil
    end)
  end

  def real_org_slug(_mask_labels, emitted), do: emitted

  defp slugify(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
