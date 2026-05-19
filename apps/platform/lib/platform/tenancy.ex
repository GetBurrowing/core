defmodule Platform.Tenancy do
  @moduledoc """
  Context module for the MT/RBAC foundation — orgs, memberships, and the
  pure-function scope display helpers used by UI surfaces.

  Lands stack member 1 of the MT/RBAC foundation per Plan 1 v3
  (task 019e3c49-c1b1-75f1-9f61-e62877ef1641). Subsequent stack members
  layer on `effective_value/3` resolution, MCP tools, and UI surfaces.

  ## Why `Platform.Tenancy` and not `Platform.Orgs`?

  The `Platform.Org` namespace is the legacy single-org memory / context
  system (`Platform.Org.Context`, `Platform.Org.MemoryEntry`, etc.). To
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
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  # ── Org finders ───────────────────────────────────────────────────────

  @doc "Fetch an org by id, raising on not found."
  @spec get_org!(binary()) :: Org.t() | no_return()
  def get_org!(id), do: Repo.get!(Org, id)

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
    Enum.any?(memberships, fn
      %OrgMembership{role: "admin", org: %Org{parent_org_id: nil}} -> true
      _ -> false
    end)
  end

  def fabrikam_admin_preloaded?(_), do: false

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
    query =
      from(m in OrgMembership,
        join: o in Org,
        on: o.id == m.org_id,
        where: m.user_id == ^user_id and m.role == "admin" and is_nil(o.parent_org_id),
        select: 1
      )

    Repo.exists?(query)
  end

  def fabrikam_admin?(_), do: false

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

  defp uuid?(s) when is_binary(s) do
    case Ecto.UUID.cast(s) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp uuid?(_), do: false

  @doc """
  Classify an org as `:root` or `:tenant` based on `parent_org_id`.
  """
  @spec tier(Org.t()) :: :root | :tenant
  def tier(%Org{parent_org_id: nil}), do: :root
  def tier(%Org{}), do: :tenant

  @doc """
  Fetch the parent org for a tenant. Returns `nil` for the root.
  """
  @spec parent_org(Org.t()) :: Org.t() | nil
  def parent_org(%Org{parent_org_id: nil}), do: nil
  def parent_org(%Org{parent_org_id: parent_id}), do: Repo.get(Org, parent_id)

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
end
