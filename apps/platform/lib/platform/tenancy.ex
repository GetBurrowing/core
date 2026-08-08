defmodule Platform.Tenancy do
  @moduledoc """
  Context module for the MT/RBAC foundation — orgs, memberships, and the
  pure-function scope display helpers used by UI surfaces.

  Lands stack member 1 of the MT/RBAC foundation per Plan 1 v3
  (task 019e3c49-c1b1-75f1-9f61-e62877ef1641). Subsequent stack members
  layer on `effective_value/3` resolution, MCP tools, and UI surfaces.

  ## Why `Platform.Tenancy` and not `Platform.Orgs`?

  The `Platform.Org` namespace is the legacy single-org memory / context
  system (`Platform.Org.Context`, `Platform.Org.WikiJournalEntry`, etc.). To
  avoid name collision and to make the multi-tenant intent clear in the
  call sites that adopt it, the multi-tenant API lives under
  `Platform.Tenancy.*`.

  ## Two-tier hierarchy

    * Root org (Fabrikam) — `parent_org_id IS NULL`. Exactly one row, enforced
      at the DB level via a partial unique index.
    * Tenant orgs (Soylent, Wayne-Tech, SXI, Paragon, future tenants) —
      `parent_org_id` references the root.

  ## Scope display helpers

  `scope_color/1` and `scope_label/1` are **pure functions** — they
  consult a static map keyed by slug atom. They do NOT hit the DB. This
  makes them safe to call from hot LiveView render paths (e.g. activity
  feeds, task lists). Adding a new tenant slug requires:

    1. seeding the org row (data migration)
    2. adding the slug → class / label entries below
    3. (later, when the design-system token lands) adding the
       `text-<slug>` and `bg-<slug>` utilities to `app.css`.

  ## Email-domain admin rule (Stage 2 self-healing hook)

  `derive_role_from_email/1` is the single source of truth for the
  email-domain admin rule. The Stage 1 migration backfilled existing
  users; the Stage 2 hook in `Platform.Accounts.find_or_create_from_oidc/1`
  re-evaluates the rule on every user INSERT and on every email-change
  UPDATE so new Fabrikam hires auto-inherit `:admin` without re-running the
  migration.

  > WARNING: the rule is locked to the literal `@example.com` suffix.
  > Future Fabrikam alias domains (e.g. `example.com`, `kobo-ai.co`) need explicit
  > additions to `derive_role_from_email/1` AND the matching SQL in
  > `priv/repo/migrations/20260519160000_refine_fabrikam_admin_membership_by_email_domain.exs`
  > — keep the two in sync. Contractors temporarily on `@example.com`
  > should be denylisted via the `roles_locked_at` column (Stage 3 of
  > this task).

  ## Manual-override overlay (Stage 3)

  When `roles_locked_at` is non-nil on a membership row, the Stage 2
  self-healing hook treats that row as **manually managed** and does
  NOT re-evaluate the email-domain rule. Use `promote_to_admin/2` /
  `revoke_admin/2` to set the lock; clearing the lock requires a
  deliberate ops action (not exposed in this stage).

  The lock-aware entry point that the accounts hook calls is
  `apply_derived_role/1` — it consults `roles_locked_at` BEFORE
  delegating to `set_membership_role/3`. `set_membership_role/3` itself
  remains an unconditional setter, used by `promote_to_admin/2` and
  `revoke_admin/2` to forcibly set both the role and the lock.

  ## Audit pipeline

  Every `promote_to_admin/2` and `revoke_admin/2` call emits a
  `:telemetry` event `[:platform, :tenancy, :role_change]` which is
  bridged to the canonical audit store by `Platform.Audit.TelemetryHandler`.
  Subscribers can listen on `Platform.Audit.subscribe/1` (default topic
  `"audit:all"`) or on `"audit:platform.tenancy.role_change"`.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy.ExternalDmAllowlistEntry
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  # ── Org finders ───────────────────────────────────────────────────────

  @doc "Fetch an org by id, raising on not found."
  @spec get_org!(binary()) :: Org.t() | no_return()
  def get_org!(id) do
    # Bang twin of get_org/1: documented contract is `Ecto.NoResultsError`, so
    # a malformed id raises THAT rather than `Ecto.Query.CastError`.
    if Platform.UUID.valid?(id) do
      Repo.get!(Org, id)
    else
      raise Ecto.NoResultsError, queryable: Org
    end
  end

  @doc "Fetch an org by id. Returns `nil` if not found."
  @spec get_org(binary()) :: Org.t() | nil
  def get_org(id) when is_binary(id) do
    # Reached with caller-supplied org ids from lifecycle_actions.ex:165,
    # recovery_live.ex and chat_live.ex. Malformed folds into the existing nil.
    if Platform.UUID.valid?(id), do: Repo.get(Org, id), else: nil
  end

  def get_org(_), do: nil

  @doc "Fetch an org by slug. Returns `nil` if not found."
  @spec get_org_by_slug(String.t()) :: Org.t() | nil
  def get_org_by_slug(slug) when is_binary(slug), do: Repo.get_by(Org, slug: slug)

  @doc "Fetch an org by slug, raising on not found."
  @spec get_org_by_slug!(String.t()) :: Org.t() | no_return()
  def get_org_by_slug!(slug) when is_binary(slug), do: Repo.get_by!(Org, slug: slug)

  @doc "List every org (root + tenants)."
  @spec list_orgs() :: [Org.t()]
  def list_orgs, do: Repo.all(Org)

  @doc """
  List tenant orgs (excludes the root). Ordered by slug for stable display.
  """
  @spec list_tenants() :: [Org.t()]
  def list_tenants do
    Org
    |> where([o], not is_nil(o.parent_org_id))
    |> order_by([o], asc: o.slug)
    |> Repo.all()
  end

  @doc """
  List the **active scopes** for the scope rail: the root org (Fabrikam) plus
  every tenant whose `archived_at` is `nil`, in canonical tenant-priority
  order (Fabrikam first — see `tenant_priority/0`).

  Deletion-scheduled tenants are excluded too: scheduling also stamps
  `archived_at` (see `Platform.Tenancy.Lifecycle.schedule_org_deletion/2`),
  so the single `is_nil(archived_at)` filter hides both the archived and
  the pending-deletion states.

  The root org can never be archived — `Lifecycle` refuses it with
  `{:error, :not_deletable}` — so Fabrikam is always present.

  > #### Returned slugs are NOT limited to the seeded five {: .warning}
  >
  > This returns EVERY non-archived org, including tenants created at
  > runtime. `Org.changeset/2` accepts any slug matching
  > `^[a-z][a-z0-9_-]*$` and the query above filters only on `archived_at`,
  > so a returned slug may be arbitrary user input.
  >
  > Callers must therefore NOT assume a returned slug has a static entry in
  > `@scope_labels`/`@scope_classes` (or in `ScopePill`'s `scope_label/1` /
  > `slug/1`, which are non-total), and must NOT feed these slugs to
  > `String.to_existing_atom/1` — it raises `ArgumentError` for any slug
  > never compiled as an atom. Filter against the canonical allowlist
  > (`Platform.Tasks.scope_keys/0`) comparing as strings instead; see
  > `TasksLive.active_scope_keys/0`. An earlier version of this docstring
  > asserted the opposite invariant and that false claim took `/tasks` down
  > for every user in the deployment (task 019fa209).

  Contrast with `list_tenants/0`, which returns tenants only (no root) and
  every row regardless of archive state — background callers that must see
  archived tenants (org-summary walkers, preamble builder, federation tool
  surface) keep using that one. `list_active_tenants/0` is the data-driven
  source for the scope-rail chips; the `.heex` render swap lands in a later
  stage.
  """
  @spec list_active_tenants() :: [Org.t()]
  def list_active_tenants do
    Org
    |> where([o], is_nil(o.archived_at))
    |> Repo.all()
    |> sort_by_tenant_priority(& &1.slug)
  end

  @doc """
  List the active orgs a viewer is allowed to see (ADR-0042).

  The viewer-scoped counterpart to `list_active_tenants/0`, which is
  unscoped and returns every non-archived org. Any surface that renders
  org **names or section headers** to a user must read through this
  function.

  > #### An empty section header is still a leak {: .warning}
  >
  > `list_active_tenants/0` renders every org, so a sidebar grouping a
  > correctly-scoped project list by it still discloses the *existence*
  > and *name* of every foreign org as a header with a `0` count. Scoping
  > only the project read is not enough; the org read has to be scoped
  > too.

  ## Semantics

    * The membership filter is applied **in the query**
      (`o.id in subquery(viewer_org_ids_query/1)`), not after the fetch,
      so the database is the enforcement point.
    * A `nil` user — or anything without a binary `:id` — returns `[]`.
      An anonymous caller is never authorized. Mirrors
      `Platform.Tasks.list_projects_for_user/2`.
    * Root (Fabrikam) admins bypass the membership filter and see every
      active org. Admin status is read from the preloaded
      `:org_memberships` when they are loaded (`fabrikam_admin_preloaded?/1`,
      zero queries — the live path), else via `fabrikam_admin?/1`.
    * Archive semantics, ordering and the "slugs are arbitrary user
      input" warning are all identical to `list_active_tenants/0`.
  """
  @spec list_active_tenants_for_user(map() | nil) :: [Org.t()]
  def list_active_tenants_for_user(%{id: user_id} = user) when is_binary(user_id) do
    Org
    |> where([o], is_nil(o.archived_at))
    |> maybe_filter_orgs_viewer(user_id, root_admin?(user))
    |> Repo.all()
    |> sort_by_tenant_priority(& &1.slug)
  end

  def list_active_tenants_for_user(_user), do: []

  defp maybe_filter_orgs_viewer(query, _user_id, true = _root_admin?), do: query

  defp maybe_filter_orgs_viewer(query, user_id, false = _root_admin?) do
    where(query, [o], o.id in subquery(viewer_org_ids_query(user_id)))
  end

  defp root_admin?(%{org_memberships: memberships} = user) when is_list(memberships),
    do: fabrikam_admin_preloaded?(user)

  defp root_admin?(user), do: fabrikam_admin?(user)

  @doc """
  List the **inactive** tenant orgs for the recovery surface — every
  non-root org with `archived_at` set (both the purely-archived and the
  deletion-scheduled states; scheduling also stamps `archived_at`).

  The root org can never be archived, so this only ever yields tenants.
  Ordered deletion-scheduled first (soonest deadline first — the rows the
  admin most needs to act on), then the purely-archived tenants in
  canonical tenant-priority order. The recovery LiveView buckets the two
  states apart for display; the ordering here means each bucket is already
  in the right order once split.

  Read-only companion to `list_active_tenants/0` — the lifecycle mutators
  (`archive_org/2`, `schedule_org_deletion/2`, …) live in
  `Platform.Tenancy.Lifecycle`.
  """
  @spec list_archived_tenants() :: [Org.t()]
  def list_archived_tenants do
    Org
    |> where([o], not is_nil(o.archived_at))
    |> Repo.all()
    |> Enum.sort_by(fn org ->
      {org.deletion_scheduled_at || ~U[9999-01-01 00:00:00.000000Z],
       tenant_priority_index(org.slug), org.slug}
    end)
  end

  @doc """
  Canonical tenant ordering for UI surfaces (ADR-0042).

  Returns slugs in seed order — `fabrikam` first (root), then tenants in
  their original seed insertion order: `soylent, wayne_tech, sxi,
  paragon`. This is the "tenant-priority" ordering that both the
  sidebar project picker and the project-create FAB should agree on,
  rather than alphabetizing-by-name (which moves Paragon to the
  front) or alphabetizing-by-slug (which moves paragon to the front).

  Unknown slugs fall to the end in slug-alphabetical order so adding a
  new tenant without updating this list still produces a stable sort.
  """
  @spec tenant_priority() :: [String.t()]
  def tenant_priority, do: ["fabrikam", "soylent", "wayne_tech", "sxi", "paragon"]

  @doc """
  Index helper for `tenant_priority/0`. Returns the position of a slug in the
  canonical list, or a large sentinel for unknown slugs so they sort after
  every known tenant.
  """
  @spec tenant_priority_index(String.t()) :: integer()
  def tenant_priority_index(slug) when is_binary(slug) do
    Enum.find_index(tenant_priority(), &(&1 == slug)) || 9_999
  end

  @doc """
  List every org in canonical tenant-priority order (ADR-0042). Use this
  for any UI surface that should agree with the sidebar grouping.
  """
  @spec list_orgs_in_priority_order() :: [Org.t()]
  def list_orgs_in_priority_order do
    list_orgs() |> sort_by_tenant_priority(& &1.slug)
  end

  @doc """
  Sort an enumerable by canonical tenant priority. The accessor should
  return the org slug for an element.
  """
  @spec sort_by_tenant_priority(Enumerable.t(), (any() -> String.t())) :: list()
  def sort_by_tenant_priority(enum, slug_fn) do
    Enum.sort_by(enum, fn item ->
      slug = slug_fn.(item)
      {tenant_priority_index(slug), String.downcase(slug || "")}
    end)
  end

  # ── Membership finders ────────────────────────────────────────────────

  @doc """
  List all memberships for a user, with the `:org` association preloaded.

  Accepts either a `%Platform.Accounts.User{}` struct or any map/struct
  carrying an `:id` field.
  """
  @spec list_user_memberships(%{:id => binary(), optional(atom()) => any()}) ::
          [OrgMembership.t()]
  def list_user_memberships(%{id: user_id}) do
    OrgMembership
    |> where([m], m.user_id == ^user_id)
    |> preload(:org)
    |> Repo.all()
  end

  @doc """
  Composable query selecting the org ids a viewer belongs to.

  This is the single definition of "orgs this viewer is a member of".
  It returns an `Ecto.Query` (not rows) so callers can drop it into a
  `subquery/1` and let the database do the filtering — the enforcement
  point stays in SQL and no unauthorized row ever lands in memory.

  Unlike `list_user_memberships/1`, which loads full structs, nothing is
  fetched here until the composing query runs.

      where: p.org_id in subquery(Tenancy.viewer_org_ids_query(user_id))

  Callers that grant root (Fabrikam) admins a bypass must check
  `fabrikam_admin?/1` (or `fabrikam_admin_preloaded?/1`) themselves — this query
  is membership only and knows nothing about roles.

  Prefer `scope/3` over calling this directly: `scope/3` layers the
  root-member bypass and the fail-closed `:none` case on top of this
  query. Reach for `viewer_org_ids_query/1` only when you genuinely need
  the raw membership ids.
  """
  @spec viewer_org_ids_query(binary()) :: Ecto.Query.t()
  def viewer_org_ids_query(user_id) when is_binary(user_id) do
    from(om in OrgMembership, where: om.user_id == ^user_id, select: om.org_id)
  end

  # ── Viewer visibility: one choke point ────────────────────────────────

  @typedoc """
  The resolved answer to "what is this viewer allowed to see", in org
  terms. Feed it to `scope/3`.
  """
  @type visibility :: :root_all | {:orgs, [binary()]} | :none

  @doc """
  Resolve a viewer to a `t:visibility/0` — the single answer to "which
  orgs may this viewer see".

    * A member of the **root** org at ANY role → `:root_all`. Rowan's
      2026-08-05 ruling: sub-orgs are filtering mechanisms, so a Fabrikam
      member sees Fabrikam *and* SXI content. This is deliberately wide.
    * Otherwise, the viewer's memberships → `{:orgs, ids}`, sorted and
      deduped so the value is directly comparable in tests.
    * `nil`, anything without a binary `:id`, or a user with zero
      membership rows → `:none`.

  ## Fail closed, and why

  A fail-open default is wrong regardless of how wide the intended
  audience is, **because a deliberate wide audience and an accidental
  one are different things and only the first is a decision.** The
  historical default answer to "I don't know who you are" was "show
  them everything" (`filter_org(queryable, [])` returning the queryable
  untouched). `:none` makes the unknown-viewer case explicit and empty.

  Note the flip side, equally deliberate: `scope/3`'s job is to make
  visibility EXPLICIT, not to make it NARROW. `:root_all` returns the
  queryable untouched, on purpose.

  ## Resolution paths

  Resolves from the preloaded `:org_memberships` (with nested `:org`)
  when they are a loaded list — zero queries, and that is the live path
  since `Accounts.get_user/1` preloads them. Otherwise falls back to the
  `Repo` path. Mirrors the `fabrikam_admin_preloaded?/1` vs `fabrikam_admin?/1`
  split.

  **Resolve once per request and thread the resolved value** through to
  each `scope/3` call — do not re-call `visibility/1` per query.
  """
  @spec visibility(map() | nil) :: visibility()
  def visibility(%{org_memberships: memberships} = user) when is_list(memberships) do
    if root_member_preloaded?(user) do
      :root_all
    else
      memberships
      |> Enum.map(fn
        %OrgMembership{org_id: org_id} -> org_id
        %{org_id: org_id} -> org_id
        _ -> nil
      end)
      |> to_visibility()
    end
  end

  def visibility(%{id: user_id} = user) when is_binary(user_id) do
    if root_member?(user) do
      :root_all
    else
      user_id
      |> viewer_org_ids_query()
      |> Repo.all()
      |> to_visibility()
    end
  end

  def visibility(_user), do: :none

  defp to_visibility(org_ids) do
    case org_ids |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort() do
      [] -> :none
      ids -> {:orgs, ids}
    end
  end

  @doc """
  Apply a resolved `t:visibility/0` to a queryable. The one choke point
  every viewer-scoped read should go through.

      vis = Tenancy.visibility(current_user)
      Project |> Tenancy.scope(vis) |> Repo.all()

  Three clauses, no others:

    * `:root_all` — the queryable **unchanged**. Correct and intended.
    * `{:orgs, ids}` — `r.org_id in ^ids`.
    * `:none` — a query that can never match a row. **`:none` NEVER
      returns an unfiltered query.**

  ## Options

    * `:field` — the org column to filter on (default `:org_id`).
    * `:binding` — which binding to filter against. `nil` (default) is
      the first binding; `:last` targets the last (`[..., r]`); an atom
      names an `as:` binding, so a joined `projects` alias can be
      targeted directly.

  ## Scope boundary

  This answers **which orgs** only. Contexts keep owning "plus which
  specific rows" — Meetings' live-invite union, Chat's
  `chat_participants`. Do not add domain clauses here.
  """
  @spec scope(Ecto.Queryable.t(), visibility(), keyword()) :: Ecto.Queryable.t()
  def scope(queryable, visibility, opts \\ [])

  def scope(queryable, :root_all, _opts), do: queryable

  def scope(queryable, {:orgs, ids}, opts) when is_list(ids) do
    case Enum.filter(ids, &is_binary/1) do
      # An empty allow-list is "no orgs", not "all orgs".
      [] -> scope(queryable, :none, opts)
      ids -> scope_to_org_ids(queryable, ids, opts)
    end
  end

  def scope(queryable, :none, _opts) do
    where(queryable, [_r], fragment("false"))
  end

  defp scope_to_org_ids(queryable, ids, opts) do
    field = Keyword.get(opts, :field, :org_id)

    case Keyword.get(opts, :binding) do
      nil -> where(queryable, [r], field(r, ^field) in ^ids)
      :last -> where(queryable, [..., r], field(r, ^field) in ^ids)
      name when is_atom(name) -> where(queryable, [{^name, r}], field(r, ^field) in ^ids)
    end
  end

  @doc """
  Pure-function variant of `fabrikam_admin?/1` that consumes the already-
  preloaded `org_memberships` (with nested `:org`) on a user struct
  instead of hitting the DB.

  Returns `true` iff the preloaded list contains a membership with
  `role == "admin"` joined to the root org (`parent_org_id == nil`).
  Returns `false` for `nil`, unloaded associations, and any other shape.

  Used on the hot authentication path (RequireAuth plug + LiveAuth
  `on_mount`) where `Accounts.get_user/1` has already preloaded
  memberships — calling `fabrikam_admin?/1` there would issue a redundant
  query.
  """
  @spec fabrikam_admin_preloaded?(any()) :: boolean()
  def fabrikam_admin_preloaded?(%{org_memberships: memberships}) when is_list(memberships) do
    Enum.any?(memberships, &root_membership_struct?(&1, "admin"))
  end

  def fabrikam_admin_preloaded?(_), do: false

  @doc """
  Pure-function variant of `root_member?/1` — is the user a member of the
  root org at ANY role, read from the already-preloaded
  `org_memberships` (with nested `:org`)?

  Peer of `fabrikam_admin_preloaded?/1`, and deliberately a DIFFERENT
  question: root membership is the calendar/visibility rule ("any Fabrikam
  employee sees everything"), root admin is the operator bypass. A
  `role: "member"` membership on the root org is `true` here and `false`
  in `fabrikam_admin_preloaded?/1`.
  """
  @spec root_member_preloaded?(any()) :: boolean()
  def root_member_preloaded?(%{org_memberships: memberships}) when is_list(memberships) do
    Enum.any?(memberships, &root_membership_struct?(&1, :any))
  end

  def root_member_preloaded?(_), do: false

  # The ONE "is this a membership on the root org" predicate for preloaded
  # structs. `wanted` is either a role string or `:any`.
  defp root_membership_struct?(%OrgMembership{org: %Org{parent_org_id: nil}, role: role}, wanted),
    do: wanted == :any or role == wanted

  defp root_membership_struct?(_membership, _wanted), do: false

  @doc """
  Pure function — extracts the user's primary membership from an
  already-preloaded user struct. **No DB call**.

  Expects `Platform.Accounts.get_user/1` (or equivalent) to have
  preloaded `:org_memberships` with the nested `:org` so the call sites
  on the hot authentication path (RequireAuth plug, LiveAuth `on_mount`)
  can derive membership without an extra round-trip.

  Returns `%{org: %Org{}, role: :admin | :member}` for a user with at
  least one membership, picking the first membership in the preloaded
  list. Returns `nil` for:

    * a user with no memberships (`org_memberships: []`)
    * an unloaded association (`%Ecto.Association.NotLoaded{}`)
    * a `nil` user
    * any other shape

  When a user has multiple memberships (multi-tenant power user) the
  ordering is whatever the preload returned — which today is unordered.
  Downstream call sites should NOT rely on the choice; a follow-up
  stack member will add explicit org selection (Plan 3 in the MT/RBAC
  roadmap).
  """
  @spec load_membership(any()) :: %{org: Org.t(), role: :admin | :member} | nil
  def load_membership(%{org_memberships: [%OrgMembership{org: %Org{} = org, role: role} | _]})
      when is_binary(role) do
    %{org: org, role: String.to_existing_atom(role)}
  end

  def load_membership(_), do: nil

  # ── External-user marker (stack member 1, rbac-external-users) ─────────
  #
  # `external` is an ADDITIVE boolean on org_memberships, ORTHOGONAL to
  # `role` — never a role value, never touched by the email-domain
  # self-healing machinery. See `Platform.Tenancy.OrgMembership` @moduledoc.

  @doc """
  Upsert an `org_memberships` row for `{user_id, org_id}` with
  `external: true`.

  Accepts an attrs map with `:user_id` and `:org_id` (both required) and
  an optional `:role` (defaults to `"member"` — external users are
  member-level participants). If a membership already exists for the pair
  its `external` flag is flipped to `true`; the existing `role` is
  preserved unless `:role` is supplied. If none exists a new row is
  inserted at the given/default role with `external: true`.

  Idempotent — re-calling on an already-external row is a no-op write that
  still returns `{:ok, membership}`, so the pending-grant apply path (and a
  double login) can't double-provision.

  Returns `{:ok, membership}` or `{:error, changeset}`.

  ## Examples

      iex> Platform.Tenancy.mark_membership_external(%{user_id: u.id, org_id: o.id})
      {:ok, %OrgMembership{external: true, role: "member"}}
  """
  @spec mark_membership_external(%{
          :user_id => binary(),
          :org_id => binary(),
          optional(:role) => String.t()
        }) :: {:ok, OrgMembership.t()} | {:error, Ecto.Changeset.t()}
  def mark_membership_external(%{user_id: user_id, org_id: org_id} = attrs)
      when is_binary(user_id) and is_binary(org_id) do
    role = Map.get(attrs, :role, "member")

    case Repo.get_by(OrgMembership, user_id: user_id, org_id: org_id) do
      nil ->
        %OrgMembership{}
        |> OrgMembership.changeset(%{
          user_id: user_id,
          org_id: org_id,
          role: role,
          external: true
        })
        |> Repo.insert()

      %OrgMembership{external: true} = existing ->
        # Already external — idempotent no-op.
        {:ok, existing}

      %OrgMembership{} = existing ->
        existing
        |> OrgMembership.changeset(%{external: true})
        |> Repo.update()
    end
  end

  @doc """
  List the external memberships for an org (`external == true`), most
  recent first. Accepts an `%Org{}` struct or an org id string.
  """
  @spec list_external_memberships(Org.t() | binary()) :: [OrgMembership.t()]
  def list_external_memberships(%Org{id: org_id}), do: list_external_memberships(org_id)

  def list_external_memberships(org_id) when is_binary(org_id) do
    OrgMembership
    |> where([m], m.org_id == ^org_id and m.external == true)
    |> order_by([m], desc: m.inserted_at)
    |> Repo.all()
  end

  @doc """
  List the distinct users who hold at least one `external == true`
  membership (in any org) — the already-provisioned external users. Backs
  the admin add-channels surface, since `ExternalAdmission.awaiting_setup/0`
  deliberately drops provisioned users from its queue.
  """
  @spec list_external_users() :: [User.t()]
  def list_external_users do
    from(m in OrgMembership,
      join: u in User,
      on: u.id == m.user_id,
      where: m.external == true,
      order_by: [asc: u.name, asc: u.email],
      select: u
    )
    |> Repo.all()
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Is the user an external user? Returns `true` iff they hold at least one
  membership with `external == true` (in any org).

  This is the by-user predicate downstream segregation enforcement
  (M6/M7/M8) keys off. Accepts a `%User{}` or any map/struct carrying an
  `:id`. Returns `false` for `nil` or non-user input.
  """
  @spec external_user?(any()) :: boolean()
  def external_user?(%{id: user_id}) when is_binary(user_id) do
    Repo.exists?(
      from(m in OrgMembership, where: m.user_id == ^user_id and m.external == true, select: 1)
    )
  end

  def external_user?(_), do: false

  @doc """
  The subset of `user_ids` that are external users, as a `MapSet`.

  `external_user?/1` asked once per row is a query per row, and the
  callers that need this — a rendered invitee list, a participant rail —
  ask about every row they draw on every render. This is the same
  predicate answered for a whole list in one round trip.

  Ids are not validated: `m.user_id in ^user_ids` pins a UUID column, so a
  malformed id raises `Ecto.Query.CastError` exactly as `external_user?/1`
  would. Callers pass ids they read off rows they already loaded.

  An empty list short-circuits — a `WHERE ... IN ()` query to learn
  nothing is still a round trip.
  """
  @spec external_user_ids([binary()]) :: MapSet.t(binary())
  def external_user_ids([]), do: MapSet.new()

  def external_user_ids(user_ids) when is_list(user_ids) do
    from(m in OrgMembership,
      where: m.user_id in ^user_ids and m.external == true,
      select: m.user_id,
      distinct: true
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # ── Per-org DM allowlist (stack member 1, rbac-external-users) ─────────
  #
  # One `external_dm_allowlist_entries` row means "this user may DM anyone
  # in `allowed_org_id`". M8 consumes `may_dm_org?/2`.

  @doc """
  Allow `user` to DM anyone in `org` (per-org granularity).

  Idempotent — a duplicate `(user, org)` pair does not error and leaves a
  single row (upsert via the unique index). Accepts `%User{}`/`%Org{}`
  structs or bare id strings for either argument.

  Returns `{:ok, entry}` or `{:error, changeset}`.
  """
  @spec allow_dm(map() | binary(), map() | binary()) ::
          {:ok, ExternalDmAllowlistEntry.t()} | {:error, Ecto.Changeset.t()}
  def allow_dm(user, org) do
    user_id = id_of(user)
    org_id = id_of(org)

    %ExternalDmAllowlistEntry{}
    |> ExternalDmAllowlistEntry.changeset(%{user_id: user_id, allowed_org_id: org_id})
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_id, :allowed_org_id]
    )
    |> case do
      # on_conflict: :nothing returns a struct with a nil id when the row
      # already existed — re-read the canonical row so callers always get a
      # persisted entry.
      {:ok, %ExternalDmAllowlistEntry{id: nil}} ->
        {:ok, Repo.get_by!(ExternalDmAllowlistEntry, user_id: user_id, allowed_org_id: org_id)}

      other ->
        other
    end
  end

  @doc """
  May `user` DM members of `org`? Returns a boolean — the exact existence
  check M8 issues. Accepts structs or bare id strings.
  """
  @spec may_dm_org?(map() | binary(), map() | binary()) :: boolean()
  def may_dm_org?(user, org) do
    user_id = id_of(user)
    org_id = id_of(org)

    if is_binary(user_id) and is_binary(org_id) do
      Repo.exists?(
        from(e in ExternalDmAllowlistEntry,
          where: e.user_id == ^user_id and e.allowed_org_id == ^org_id,
          select: 1
        )
      )
    else
      false
    end
  end

  @doc """
  List the orgs `user` may DM (as `%Org{}` structs), oldest allow first.
  Accepts a `%User{}`/struct with `:id` or a bare user id string.
  """
  @spec list_dm_allowlist(map() | binary()) :: [Org.t()]
  def list_dm_allowlist(user) do
    user_id = id_of(user)

    from(e in ExternalDmAllowlistEntry,
      join: o in Org,
      on: o.id == e.allowed_org_id,
      where: e.user_id == ^user_id,
      order_by: [asc: e.inserted_at],
      select: o
    )
    |> Repo.all()
  end

  @doc """
  Revoke `user`'s DM access to `org`. Idempotent — revoking a
  non-existent entry is a no-op. Returns `{:ok, count}` where `count` is
  the number of rows deleted (0 or 1).
  """
  @spec revoke_dm(map() | binary(), map() | binary()) :: {:ok, non_neg_integer()}
  def revoke_dm(user, org) do
    user_id = id_of(user)
    org_id = id_of(org)

    {count, _} =
      from(e in ExternalDmAllowlistEntry,
        where: e.user_id == ^user_id and e.allowed_org_id == ^org_id
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  # Extract an id from a struct/map (`%{id: ...}`) or pass through a bare
  # id string.
  defp id_of(%{id: id}) when is_binary(id), do: id
  defp id_of(id) when is_binary(id), do: id
  defp id_of(_), do: nil

  # ── Role helpers ──────────────────────────────────────────────────────

  @doc """
  Is the user a Fabrikam (root) admin?

  Returns `true` only if there is a membership row with `role == "admin"`
  joined to the root org (`parent_org_id IS NULL`). Sub-org admins return
  `false` from this check — they're admins of their tenant, not of the
  root.

  Returns `false` for `nil` or any non-user input.
  """
  @spec fabrikam_admin?(any()) :: boolean()
  def fabrikam_admin?(%{id: user_id}) when is_binary(user_id) do
    Repo.exists?(root_membership_query(user_id, "admin"))
  end

  def fabrikam_admin?(_), do: false

  @doc """
  Is the user a member of the root (Fabrikam) org at ANY role?

  Distinct from `fabrikam_admin?/1` and both are legitimate: root membership
  is the visibility rule ("any Fabrikam employee sees everything" — it is
  what makes `visibility/1` return `:root_all`), root admin is the
  operator bypass. A `role: "member"` on the root org answers `true`
  here and `false` to `fabrikam_admin?/1`.

  Returns `false` for `nil` or any non-user input.
  """
  @spec root_member?(any()) :: boolean()
  def root_member?(%{id: user_id}) when is_binary(user_id) do
    Repo.exists?(root_membership_query(user_id, :any))
  end

  def root_member?(_), do: false

  # The ONE "which org is the root org" predicate, in query form. Both
  # `fabrikam_admin?/1` and `root_member?/1` compose it so the definition of
  # root is written exactly once.
  defp root_org_ids_query do
    from(o in Org, where: is_nil(o.parent_org_id), select: o.id)
  end

  defp root_membership_query(user_id, wanted_role) do
    query =
      from(m in OrgMembership,
        where: m.user_id == ^user_id and m.org_id in subquery(root_org_ids_query()),
        select: 1
      )

    case wanted_role do
      :any -> query
      role when is_binary(role) -> where(query, [m], m.role == ^role)
    end
  end

  @doc """
  Is the user a member of the given org? Accepts either an org id (UUID
  string) or a slug. Slug match is tried first, then UUID.

  Strings that match neither a known slug nor the UUID-string shape
  return `false` (rather than blowing up on an Ecto cast error). UUIDs
  that don't reference a real org also return `false`.

  Returns `false` for unknown users, unknown orgs, or non-string input.
  """
  @spec member_of?(any(), String.t()) :: boolean()
  def member_of?(%{id: _} = user, org_id_or_slug) when is_binary(org_id_or_slug) do
    case get_org_by_slug(org_id_or_slug) do
      %Org{id: org_id} -> member_of_by_id?(user, org_id)
      nil -> if uuid?(org_id_or_slug), do: member_of_by_id?(user, org_id_or_slug), else: false
    end
  end

  def member_of?(_, _), do: false

  defp member_of_by_id?(%{id: user_id}, org_id)
       when is_binary(user_id) and is_binary(org_id) do
    query =
      from(m in OrgMembership,
        where: m.user_id == ^user_id and m.org_id == ^org_id,
        select: 1
      )

    Repo.exists?(query)
  end

  defp member_of_by_id?(_, _), do: false

  # Platform.UUID.valid?/1, NOT a bare Ecto.UUID.cast/1. `member_of?/2`
  # resolves an org SLUG or a uuid, and its uuid branch pins the ORIGINAL
  # value (`where: o.id == ^org_id`) against Org's strict UUIDv7 key. A bare
  # cast accepts any 16-byte binary, so a 16-character org slug took the uuid
  # branch and raised inside Repo — RAISE-exposed despite looking guarded.
  defp uuid?(s), do: Platform.UUID.valid?(s)

  @doc """
  Classify an org as `:root` or `:tenant` based on `parent_org_id`.
  """
  @spec tier(Org.t()) :: :root | :tenant
  def tier(%Org{parent_org_id: nil}), do: :root
  def tier(%Org{}), do: :tenant

  # ── Org lifecycle (archive / schedule-deletion / restore) ─────────────
  #
  # Task 019f4eaa stage 3. Implemented in `Platform.Tenancy.Lifecycle`
  # (which also owns the provenance-aware cascade over child projects and
  # chat_spaces); delegated here so callers use the natural context API.
  # All four require a Fabrikam admin actor and refuse the root org.

  @doc "See `Platform.Tenancy.Lifecycle.archive_org/2`."
  defdelegate archive_org(actor, org), to: Platform.Tenancy.Lifecycle

  @doc "See `Platform.Tenancy.Lifecycle.unarchive_org/2`."
  defdelegate unarchive_org(actor, org), to: Platform.Tenancy.Lifecycle

  @doc "See `Platform.Tenancy.Lifecycle.schedule_org_deletion/2`."
  defdelegate schedule_org_deletion(actor, org), to: Platform.Tenancy.Lifecycle

  @doc "See `Platform.Tenancy.Lifecycle.cancel_org_deletion/2`."
  defdelegate cancel_org_deletion(actor, org), to: Platform.Tenancy.Lifecycle

  @doc """
  Fetch the parent org for a tenant. Returns `nil` for the root.
  """
  @spec parent_org(Org.t()) :: Org.t() | nil
  def parent_org(%Org{parent_org_id: nil}), do: nil
  def parent_org(%Org{parent_org_id: parent_id}), do: Repo.get(Org, parent_id)

  # ── Inheritance resolver ──────────────────────────────────────────────

  # Maximum number of org ancestors we'll walk before giving up. The
  # current two-tier design only ever needs 1 step (tenant → Fabrikam), but
  # the resolver is written to support arbitrary depth for future use,
  # so we cap at 16 as a defensive guard against a corrupt
  # parent_org_id cycle (FK design prevents this, but belt + braces).
  @effective_value_max_depth 16

  @doc """
  Inheritance resolver. Walks the `parent_org_id` chain upward from
  `org` to find where `key` is defined and returns a tagged tuple
  describing the resolution outcome.

  Storage-agnostic via the required `:lookup_fn` opt — a 2-arity
  function `(org, key) -> {:ok, value} | :error` the caller provides.
  This keeps the resolver decoupled from the underlying store; Skills,
  Context, Memory, and Prompts each pass their own lookup function over
  their own table.

  ## Return shapes

    * `{:defined_here, value}` — `org` has its own value for `key` and
      no ancestor defines it (or this is the root org).
    * `{:overridden, value, parent_value}` — `org` has its own value
      AND the nearest ancestor that defines `key` has a different (or
      same — caller decides what "shadow" means) value, surfaced as
      `parent_value`. Useful for an "overrides Fabrikam default" pill.
    * `{:inherited, source_org, value}` — `org` does not define `key`,
      but an ancestor does; `source_org` is the nearest ancestor that
      defines it and `value` is that ancestor's value.
    * `{:defined_here, default}` — no org in the chain defines `key`,
      so the caller's `default` applies. We tag this as `:defined_here`
      (with the default substituted) so call sites can render
      "no inheritance" uniformly with the genuine `:defined_here` case.

  ## Safety

  Walks at most `#{@effective_value_max_depth}` ancestors before
  bailing out and treating the chain as "no ancestor defines it".
  Protects against a malformed `parent_org_id` cycle that bypasses the
  FK design.

  ## Example

      iex> lookup = fn org, :skill -> Map.fetch(skills_by_org_id, org.id) end
      iex> Tenancy.effective_value(soylent, :skill, "fallback", lookup_fn: lookup)
      {:inherited, %Org{slug: "fabrikam"}, "fabrikam-default-skill"}

  """
  @spec effective_value(Org.t(), term(), term(), keyword()) ::
          {:defined_here, term()}
          | {:overridden, term(), term()}
          | {:inherited, Org.t(), term()}
  def effective_value(%Org{} = org, key, default, opts) do
    lookup_fn = Keyword.fetch!(opts, :lookup_fn)

    case lookup_fn.(org, key) do
      {:ok, own_value} ->
        case find_ancestor_value(org, key, lookup_fn, @effective_value_max_depth) do
          {:ok, _source, parent_value} -> {:overridden, own_value, parent_value}
          :error -> {:defined_here, own_value}
        end

      :error ->
        case find_ancestor_value(org, key, lookup_fn, @effective_value_max_depth) do
          {:ok, source_org, value} -> {:inherited, source_org, value}
          :error -> {:defined_here, default}
        end
    end
  end

  # Walks the parent chain starting from `org`'s parent (NOT `org`
  # itself), returning the first ancestor that defines `key`. Returns
  # `:error` if the chain ends (root reached) or the depth budget runs
  # out (cycle defense).
  defp find_ancestor_value(_org, _key, _lookup_fn, 0), do: :error
  defp find_ancestor_value(%Org{parent_org_id: nil}, _key, _lookup_fn, _depth), do: :error

  defp find_ancestor_value(%Org{parent_org_id: parent_id}, key, lookup_fn, depth) do
    case Repo.get(Org, parent_id) do
      nil ->
        :error

      %Org{} = parent ->
        case lookup_fn.(parent, key) do
          {:ok, value} -> {:ok, parent, value}
          :error -> find_ancestor_value(parent, key, lookup_fn, depth - 1)
        end
    end
  end

  # ── Scope display (pure, DB-free) ─────────────────────────────────────

  @scope_classes %{
    fabrikam: "text-fabrikam",
    soylent: "text-soylent",
    wayne_tech: "text-wayne-tech",
    sxi: "text-sxi",
    paragon: "text-paragon"
  }

  @scope_labels %{
    fabrikam: "Fabrikam",
    soylent: "Soylent",
    wayne_tech: "Wayne-Tech",
    sxi: "SXI",
    paragon: "Paragon"
  }

  @doc """
  Tailwind text-color class for a scope slug.

  Returns the fallback `"text-muted"` for unknown slugs (including unknown
  binaries that would otherwise blow up `String.to_existing_atom/1`).
  """
  @spec scope_color(atom() | String.t()) :: String.t()
  def scope_color(slug) when is_atom(slug), do: Map.get(@scope_classes, slug, "text-muted")
  def scope_color(slug) when is_binary(slug), do: scope_color(safe_atom(slug))
  def scope_color(_), do: "text-muted"

  @doc """
  Human-readable label for a scope slug.

  Unknown slugs fall back to a capitalised echo of the input so UIs
  don't render an empty string. (`String.capitalize/1` doesn't know
  about hyphens — that's fine here, the unknown-slug path is a
  defensive fallback only.)
  """
  @spec scope_label(atom() | String.t()) :: String.t()
  def scope_label(slug) when is_atom(slug),
    do: Map.get(@scope_labels, slug, slug |> to_string() |> String.capitalize())

  def scope_label(slug) when is_binary(slug) do
    case safe_atom(slug) do
      :__unknown__ -> String.capitalize(slug)
      atom -> Map.get(@scope_labels, atom, String.capitalize(slug))
    end
  end

  def scope_label(_), do: ""

  # Convert a binary slug to its atom representation IF the atom already
  # exists in the runtime; otherwise return `:__unknown__` so the
  # caller's fallback can fire. Using `String.to_existing_atom/1`
  # prevents atom-table pollution from unbounded user input.
  defp safe_atom(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> :__unknown__
  end

  # ── Email-domain admin rule (Stage 2 self-healing hook) ──────────────

  # Anchored at the end of string so a literal `@example.com` suffix is
  # required. Matches the migration's SQL `LIKE '%@example.com'` semantic:
  # `example.com@example.com` → :member (suffix is `@gmail.com`)
  # `alice@us.example.com` → :member (subdomain in middle, not suffix)
  # `Alice@example.com` → :admin (downcase normalizes the host)
  @fabrikam_email_suffix_regex ~r/@example\.com$/

  @doc """
  Single source of truth for the email-domain admin rule.

  Returns `:admin` when `String.downcase(email)` ends in `@example.com`,
  `:member` otherwise. Nil, empty, and non-binary input return `:member`.

  Mirrors the SQL anchor `LIKE '%@example.com'` used by the Stage 1
  backfill migration (`20260519160000_refine_fabrikam_admin_membership_by_email_domain.exs`).
  Keep this function and the migration's WHERE clause in lockstep —
  see the WARNING in the module `@moduledoc`.

  ## Examples

      iex> Platform.Tenancy.derive_role_from_email("alice@example.com")
      :admin

      iex> Platform.Tenancy.derive_role_from_email("ALICE@example.com")
      :admin

      iex> Platform.Tenancy.derive_role_from_email("alice@us.example.com")
      :member

      iex> Platform.Tenancy.derive_role_from_email("example.com@example.com")
      :member

      iex> Platform.Tenancy.derive_role_from_email(nil)
      :member
  """
  @spec derive_role_from_email(any()) :: :admin | :member
  def derive_role_from_email(email) when is_binary(email) and email != "" do
    if Regex.match?(@fabrikam_email_suffix_regex, String.downcase(email)),
      do: :admin,
      else: :member
  end

  def derive_role_from_email(_), do: :member

  @doc """
  Upsert an `org_memberships` row for `{user_id, org_id}` to the given
  role. `org_slug` defaults to `:fabrikam` (the root org).

  Idempotent: re-calling with the same role on an existing row is a no-op
  and still returns `{:ok, membership}`. A role change updates the
  existing row in place.

  Returns `{:error, :org_not_found}` if the slug doesn't resolve, and
  `{:error, changeset}` for any DB-level rejection (invalid role, FK
  violation, …).

  ## Examples

      iex> {:ok, _membership} = Platform.Tenancy.set_membership_role(user, :fabrikam, :admin)
      iex> {:ok, _membership} = Platform.Tenancy.set_membership_role(user, :fabrikam, :admin)
      # ^ second call is a no-op idempotent return

      iex> Platform.Tenancy.set_membership_role(user, "definitely-not-a-real-slug", :admin)
      {:error, :org_not_found}
  """
  @spec set_membership_role(
          %{:id => binary(), optional(atom()) => any()},
          atom() | String.t(),
          :admin | :member
        ) ::
          {:ok, OrgMembership.t()} | {:error, :org_not_found} | {:error, Ecto.Changeset.t()}
  def set_membership_role(%{id: user_id}, org_slug, role)
      when is_binary(user_id) and role in [:admin, :member] do
    slug_str = normalize_slug(org_slug)
    role_str = Atom.to_string(role)

    case get_org_by_slug(slug_str) do
      nil ->
        {:error, :org_not_found}

      %Org{id: org_id} ->
        upsert_membership(user_id, org_id, role_str)
    end
  end

  def set_membership_role(_, _, _), do: {:error, :invalid_input}

  defp normalize_slug(slug) when is_atom(slug), do: Atom.to_string(slug)
  defp normalize_slug(slug) when is_binary(slug), do: slug

  defp upsert_membership(user_id, org_id, role_str) do
    case Repo.get_by(OrgMembership, user_id: user_id, org_id: org_id) do
      nil ->
        %OrgMembership{}
        |> OrgMembership.changeset(%{user_id: user_id, org_id: org_id, role: role_str})
        |> Repo.insert()

      %OrgMembership{role: ^role_str} = existing ->
        # Idempotent: same role, no write.
        {:ok, existing}

      %OrgMembership{} = existing ->
        existing
        |> OrgMembership.changeset(%{role: role_str})
        |> Repo.update()
    end
  end

  # ── Manual-override overlay (Stage 3) ────────────────────────────────

  @doc """
  Lock-aware caller used by `Platform.Accounts.find_or_create_from_oidc/1`.

  If a membership row exists for `{user, :fabrikam}` AND its `roles_locked_at`
  is non-nil, this is a no-op and returns `{:ok, existing}` — the manual
  grant wins. Otherwise the email-domain rule is evaluated and the row is
  upserted via `set_membership_role/3`.

  This is the function the accounts hook should call. `set_membership_role/3`
  remains the unconditional setter for `promote_to_admin/2` /
  `revoke_admin/2`.
  """
  @spec apply_derived_role(%{:id => binary(), :email => any(), optional(atom()) => any()}) ::
          {:ok, OrgMembership.t() | :noop}
          | {:error, :org_not_found}
          | {:error, Ecto.Changeset.t()}
  def apply_derived_role(%{id: user_id, email: email} = user) when is_binary(user_id) do
    slug_str = normalize_slug(:fabrikam)

    case get_org_by_slug(slug_str) do
      nil ->
        {:error, :org_not_found}

      %Org{id: org_id} ->
        case Repo.get_by(OrgMembership, user_id: user_id, org_id: org_id) do
          %OrgMembership{roles_locked_at: %DateTime{}} = locked ->
            # Manual grant wins — skip evaluation entirely.
            {:ok, locked}

          _ ->
            role = derive_role_from_email(email)
            set_membership_role(user, :fabrikam, role)
        end
    end
  end

  def apply_derived_role(_), do: {:error, :invalid_input}

  @doc """
  Promote `user` to `:admin` on the Fabrikam root org and set `roles_locked_at`
  so the email-domain rule no longer overrides this row.

  Use for non-Fabrikam collaborators who should hold admin (e.g. a partner
  engineer who needs full operator access despite an external email).

  ## Idempotency

  Re-calling on a row that is already `{role: :admin, roles_locked_at: <non-nil>}`
  is a no-op and returns `{:ok, membership}` without a DB write. Calling
  on a `:member`-with-lock row promotes AND refreshes the lock timestamp.

  ## Options

    * `:org_slug` — defaults to `"fabrikam"`.
    * `:actor_id` — UUID of the user/agent making the change. Defaults to
      `nil` and `actor_type` defaults to `"system"`.
    * `:actor_type` — one of `Platform.Audit.Event.actor_types/0`. Defaults
      to `"system"` when no `:actor_id` is given, `"user"` otherwise.
    * `:reason` — free-form audit string. Defaults to `nil`.

  ## Audit

  Emits `[:platform, :tenancy, :role_change]` telemetry with action
  `"promote_to_admin"`, which the `Audit.TelemetryHandler` bridges into a
  persisted `Platform.Audit.Event` and broadcasts on PubSub. See the
  `## Audit pipeline` section in the module `@moduledoc`.
  """
  @spec promote_to_admin(
          %{:id => binary(), optional(atom()) => any()},
          keyword()
        ) ::
          {:ok, OrgMembership.t()} | {:error, :org_not_found} | {:error, Ecto.Changeset.t()}
  def promote_to_admin(user, opts \\ []), do: set_managed_role(user, :admin, opts)

  @doc """
  Revoke admin on `user`'s Fabrikam membership — sets `role: :member` AND
  `roles_locked_at` so the email-domain rule cannot re-promote them on
  the next OIDC refresh.

  Use for contractors on a `@example.com` email who should NOT have admin.

  ## Idempotency

  Re-calling on a row that is already `{role: :member, roles_locked_at: <non-nil>}`
  is a no-op. Calling on `:admin` demotes AND sets the lock.

  ## Options

  Same shape as `promote_to_admin/2` — see there for details.

  ## Audit

  Emits `[:platform, :tenancy, :role_change]` telemetry with action
  `"revoke_admin"`.
  """
  @spec revoke_admin(
          %{:id => binary(), optional(atom()) => any()},
          keyword()
        ) ::
          {:ok, OrgMembership.t()} | {:error, :org_not_found} | {:error, Ecto.Changeset.t()}
  def revoke_admin(user, opts \\ []), do: set_managed_role(user, :member, opts)

  # Core implementation for promote_to_admin / revoke_admin. Force-sets
  # both `role` and `roles_locked_at` on the user's Fabrikam membership row
  # and emits an audit event. Idempotent on already-target rows.
  defp set_managed_role(%{id: user_id} = user, target_role, opts)
       when is_binary(user_id) and target_role in [:admin, :member] do
    slug_str = opts |> Keyword.get(:org_slug, "fabrikam") |> normalize_slug()
    role_str = Atom.to_string(target_role)
    now = DateTime.utc_now()

    case get_org_by_slug(slug_str) do
      nil ->
        {:error, :org_not_found}

      %Org{id: org_id} ->
        existing = Repo.get_by(OrgMembership, user_id: user_id, org_id: org_id)

        case write_managed_membership(existing, user_id, org_id, role_str, now) do
          {:ok, membership, from_role} ->
            emit_role_change_audit(
              user_id: user_id,
              membership: membership,
              from_role: from_role,
              to_role: role_str,
              action: managed_action_name(target_role),
              opts: opts
            )

            {:ok, membership}

          {:error, _} = err ->
            err
        end
    end
  end

  defp set_managed_role(_, _, _), do: {:error, :invalid_input}

  defp managed_action_name(:admin), do: "promote_to_admin"
  defp managed_action_name(:member), do: "revoke_admin"

  # No row → insert with role + lock.
  defp write_managed_membership(nil, user_id, org_id, role_str, now) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user_id,
      org_id: org_id,
      role: role_str,
      roles_locked_at: now
    })
    |> Repo.insert()
    |> case do
      {:ok, m} -> {:ok, m, nil}
      {:error, _} = err -> err
    end
  end

  # Row exists, already at target role AND locked → no-op (idempotent).
  defp write_managed_membership(
         %OrgMembership{role: same, roles_locked_at: %DateTime{}} = existing,
         _user_id,
         _org_id,
         same,
         _now
       ) do
    {:ok, existing, same}
  end

  # Row exists, target role but no lock → set the lock only (write).
  defp write_managed_membership(
         %OrgMembership{role: same, roles_locked_at: nil} = existing,
         _user_id,
         _org_id,
         same,
         now
       ) do
    existing
    |> OrgMembership.changeset(%{roles_locked_at: now})
    |> Repo.update()
    |> case do
      {:ok, m} -> {:ok, m, same}
      {:error, _} = err -> err
    end
  end

  # Row exists, role differs (or no lock) → set both.
  defp write_managed_membership(
         %OrgMembership{role: from_role} = existing,
         _user_id,
         _org_id,
         role_str,
         now
       ) do
    existing
    |> OrgMembership.changeset(%{role: role_str, roles_locked_at: now})
    |> Repo.update()
    |> case do
      {:ok, m} -> {:ok, m, from_role}
      {:error, _} = err -> err
    end
  end

  # Emit telemetry on the canonical audit pipeline. The
  # `Audit.TelemetryHandler` persists to `audit_events` and broadcasts to
  # PubSub. Registered in @events on that handler so it actually flows.
  defp emit_role_change_audit(
         user_id: user_id,
         membership: %OrgMembership{} = membership,
         from_role: from_role,
         to_role: to_role,
         action: action,
         opts: opts
       ) do
    actor_id = Keyword.get(opts, :actor_id)

    actor_type =
      Keyword.get(opts, :actor_type, if(actor_id, do: "user", else: "system"))

    reason = Keyword.get(opts, :reason)

    :telemetry.execute(
      [:platform, :tenancy, :role_change],
      %{system_time: System.system_time()},
      %{
        actor_id: actor_id,
        actor_type: actor_type,
        action: action,
        resource_type: "org_membership",
        resource_id: membership.id,
        target_user_id: user_id,
        org_id: membership.org_id,
        from_role: from_role,
        to_role: to_role,
        # ISO 8601 string (not a DateTime struct) because the audit
        # handler's JSON-safe coercion can't traverse arbitrary structs.
        locked_at: iso_or_nil(membership.roles_locked_at),
        reason: reason
      }
    )

    :ok
  end

  defp iso_or_nil(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso_or_nil(_), do: nil
end
