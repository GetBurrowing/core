defmodule Platform.Chat.ExternalScope do
  @moduledoc """
  The composable read-scope for external users (rbac-external-users, M7).

  An `%ExternalScope{}` is an opaque value carrying a `user_id` and a
  precomputed `external?` flag. It is the single primitive the Chat read
  paths thread through their queries to guarantee **defense in depth**: given
  the external caller, a Chat read returns only allowlisted rows — the spaces
  the user is a `chat_participants` member of — even when M6's authorization
  plug is bypassed.

  ## Ownership boundary

    * M7 (this module) owns `Chat.ExternalScope` and consumes
      `Platform.Tenancy.external_user?/1` (which M1 shipped). M7 does **not**
      redefine that predicate.
    * M6 (auth plug) also calls `Tenancy.external_user?/1` for its fast-fail —
      it must not redefine it either.
    * M8 (per-org DM allowlist) owns `may_dm_org?/2` and the DM-creation gate.
      M7's read scope is `chat_participants` membership — the tightest set: a
      DM the external user already participates in is in-scope by definition —
      so M7 does not re-implement the allowlist. `authorized_space?/2` below
      CONSUMES `may_dm_org?/2` for its DM branch; it does not redefine it.
    * M9 (attachments) owns the signed-URL / presigner scope. M7 stops at the
      context read-query filter.

  ## Design: threaded scope, not a global implicit filter

  The scope is passed explicitly as a `:scope` opt (option A from the design
  canvas §8). This makes the caller identity a first-class query input the e2e
  can exercise directly, and a nil / absent scope preserves today's behavior
  for every internal and system caller — backwards compatible, zero churn to
  the existing call sites that don't pass it.

  `external?` is computed **once** in `for_user/1` (a single membership
  `EXISTS`), not per read call, so each downstream query stays a single
  membership subquery rather than paying an extra probe per call. The external
  LiveView (M5) / plug (M6) build this once per session and pass it down.

  Internal and system (nil) scopes are pass-through everywhere — this is
  external-user-only, so no internal read path regresses.

  ## Accepting a `%Platform.Access.Scope{}`

  Every `:scope` taker here also accepts a `%Platform.Access.Scope{}`
  (task `01a1386d-cb5c` stage 3,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Permission model`), so
  `:scope` is "`%ExternalScope{}` or `%Platform.Access.Scope{}`". A Scope
  whose `chat.read` comes ONLY from the guest role's `participant_spaces`
  rule, with a user actor, filters through the SAME live
  `member_space_ids/1` subquery an external `%ExternalScope{}` uses. It never
  filters from the Scope's participant id list: that list is a build-time
  snapshot, and a socket that mounted before a participant row was added must
  still see the new space (`chat_live.ex` builds its scope once per mount).
  Any other Scope passes through, exactly like an internal scope: a member or
  admin (`implicit_or_participant`), a zero-membership user, `for_user(nil)`,
  `system/0`, a meeting invitee, and a runtime (its actor is not a user, which
  is also what `for_user/1` gives a runtime today). `from_scope/1` is the
  conversion; every Scope clause goes through it.

  `for_user/1` still returns `%ExternalScope{}`. Callers pattern-match
  `external?: true` on it (`chat_live.ex`, `Chat.ContextSummary`), and a
  Scope would read as non-external there. Switching those call sites is
  resource scoping (stack position 3), not this bridge.

  `authorized_space?/2` takes a user, not a scope, and is unchanged.

  The Scope clauses match `%{__struct__: Scope}` rather than `%Scope{}` on
  purpose: `Platform.Access.Scope` builds an `%ExternalScope{}` for its
  participant snapshot, and a struct literal in each direction would make
  the two modules wait on each other's struct at compile time.

  ## Read scope vs admission gate

  Two different questions live in this module and collapsing them is a bug in
  both directions:

    * `visible_space_id?/2`, and the query scopers above it, answer
      MEMBERSHIP — the filter a read query wants.
    * `authorized_space?/2` answers ADMISSION — may this external user open
      this space at all. That is membership OR the per-org DM allowlist.

  Admission is the wider set. Using the read scope as the gate refuses a DM
  the allowlist admits; using the gate as the read filter returns rows the
  user is not a member of. Pick by the question asked.
  """

  import Ecto.Query

  alias Platform.Access.Scope
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo
  alias Platform.Tenancy

  @enforce_keys []
  defstruct user_id: nil, external?: false

  @type t :: %__MODULE__{user_id: binary() | nil, external?: boolean()}

  @doc """
  Build a scope for a user.

  Accepts a `%Platform.Accounts.User{}` (or any struct/map carrying a binary
  `:id`), a bare `user_id` binary, or `nil`. Computes `external?` once via
  `Tenancy.external_user?/1`. `for_user(nil)` (and any non-user input) returns
  the unrestricted / system scope (`external?: false`).
  """
  @spec for_user(struct() | map() | binary() | nil) :: t()
  def for_user(user_id) when is_binary(user_id), do: build(user_id)

  def for_user(%{id: user_id}) when is_binary(user_id), do: build(user_id)

  def for_user(_), do: %__MODULE__{user_id: nil, external?: false}

  defp build(user_id) when is_binary(user_id) do
    %__MODULE__{user_id: user_id, external?: Tenancy.external_user?(%{id: user_id})}
  end

  @doc """
  Convert a `%Platform.Access.Scope{}` to the `%ExternalScope{}` it filters as.

  `external?: true` exactly when the actor carries a binary `:id` and the
  Scope's contributing roles carry `chat.read` only through the
  `participant_spaces` rule (`Scope.rules_for/2`, which reads a user's
  memberships through the same `Scope.guest_dominates/1` path `for_user/1`
  builds from). For the built-in roles that is a guest-restricted user: an
  external member, external admin, external root-org member, and a mixed user
  (guest dominates). Everything else converts to a pass-through scope. The
  result carries no participant ids; `member_space_ids/1` reads
  `chat_participants` live on every call.

  An `%AgentRuntime{}` also carries a binary `:id`, so an external-owned
  runtime's Scope converts to `user_id: <runtime id>, external?: true` and
  filters to nothing: no `participant_type: "user"` row carries a runtime id.
  No caller passes a runtime Scope to a Chat read today (task `01a1386d-cb5c`
  stage 4 pins this in `test/platform/access/equivalence_test.exs`).
  """
  @spec from_scope(Scope.t()) :: t()
  def from_scope(%{__struct__: Scope, actor: %{id: user_id}} = scope) when is_binary(user_id) do
    %__MODULE__{user_id: user_id, external?: participant_restricted?(scope)}
  end

  def from_scope(%{__struct__: Scope}), do: %__MODULE__{user_id: nil, external?: false}

  defp participant_restricted?(scope) do
    Scope.rules_for(scope, "chat.read") == ["participant_spaces"]
  end

  @doc """
  The composable subquery yielding the set of `space_id`s the scope's user is
  a `participant_type: "user"` member of. This is the authoritative external
  read-scope. Mirrors the membership check in `Chat.principal_is_member?/2`,
  expressed as a set-returning subquery.
  """
  @spec member_space_ids(t() | Scope.t()) :: Ecto.Query.t()
  def member_space_ids(%{__struct__: Scope} = scope),
    do: scope |> from_scope() |> member_space_ids()

  def member_space_ids(%__MODULE__{user_id: user_id}) do
    from(p in Participant,
      where: p.participant_type == "user" and p.participant_id == ^user_id,
      select: p.space_id
    )
  end

  @doc """
  Scope a query whose first binding is `Platform.Chat.Space` to the external
  user's member spaces. Identity for internal and nil (system) scopes.
  """
  @spec scope_spaces(Ecto.Query.t() | module(), t() | Scope.t() | nil) ::
          Ecto.Query.t() | module()
  def scope_spaces(query, %{__struct__: Scope} = scope),
    do: scope_spaces(query, from_scope(scope))

  def scope_spaces(query, %__MODULE__{external?: true} = scope) do
    where(query, [s], s.id in subquery(member_space_ids(scope)))
  end

  def scope_spaces(query, _scope), do: query

  @doc """
  Scope a query whose first binding carries a `space_id` field (Message /
  Attachment / Canvas) to the external user's member spaces. Identity for
  internal and nil (system) scopes.
  """
  @spec scope_by_space_id(Ecto.Query.t() | module(), t() | Scope.t() | nil) ::
          Ecto.Query.t() | module()
  def scope_by_space_id(query, %{__struct__: Scope} = scope),
    do: scope_by_space_id(query, from_scope(scope))

  def scope_by_space_id(query, %__MODULE__{external?: true} = scope) do
    where(query, [x], x.space_id in subquery(member_space_ids(scope)))
  end

  def scope_by_space_id(query, _scope), do: query

  @doc """
  Boolean guard for single-row `get_*` helpers: is `space_id` visible under
  `scope`? Always `true` for internal and nil (system) scopes. For an external
  scope, `true` iff the user is a member of that space — letting `get_*` return
  `nil` for out-of-scope ids without re-issuing the full query.
  """
  @spec visible_space_id?(binary() | nil, t() | Scope.t() | nil) :: boolean()
  def visible_space_id?(space_id, %{__struct__: Scope} = scope),
    do: visible_space_id?(space_id, from_scope(scope))

  def visible_space_id?(space_id, %__MODULE__{external?: true} = scope)
      when is_binary(space_id) do
    Repo.exists?(where(member_space_ids(scope), [p], p.space_id == ^space_id))
  end

  def visible_space_id?(_space_id, _scope), do: true

  @doc """
  May this external user open `space`? The single ADMISSION predicate behind
  every external entry point to a chat space.

  `true` when the user holds a real `chat_participants` row for the space
  (channels, groups, and DMs they already belong to — `apply_grant` and DM
  creation materialize the row), or when the space is a DM whose counterpart
  belongs to an org on the user's per-org DM allowlist.

  Both gates call THIS function: the HTTP plug
  (`PlatformWeb.Plugs.ExternalUserScope`) and the LiveView mount. It was
  private to the plug until task 01a011ed; the LiveView had no equivalent,
  and that gap is the defect this move closes. Do not grow a second copy.
  Two gates answering the same question is how they drift apart.

  `nil` is `false`. Callers must render the SAME denial for a `nil` space as
  for an out-of-scope one: an off-limits slug has to be indistinguishable
  from a missing one, or the denial becomes an existence oracle.

  See the moduledoc on why this is not `visible_space_id?/2`.
  """
  @spec authorized_space?(map(), map() | nil) :: boolean()
  def authorized_space?(_user, nil), do: false

  def authorized_space?(user, %{id: space_id} = space) do
    Chat.participant?(space_id, user.id) or dm_allowlisted?(user, space)
  end

  # DM ACCESS branch: let an external user open a DM surface with a counterpart
  # whose org is on their per-org DM allowlist. This gates ACCESS to an
  # existing space only — M8 (task 019f8837-4663) owns server-side enforcement
  # of DM *initiation* (rejecting a create to a non-allowlisted org). Keep this
  # branch to access, not creation.
  defp dm_allowlisted?(user, %{kind: "dm", id: space_id}) do
    space_id
    |> Chat.list_participants(participant_type: "user")
    |> Enum.reject(fn p -> p.participant_id == user.id end)
    |> Enum.any?(fn p -> counterpart_org_allowed?(user, p.participant_id) end)
  end

  defp dm_allowlisted?(_user, _space), do: false

  defp counterpart_org_allowed?(user, counterpart_user_id) do
    %{id: counterpart_user_id}
    |> Tenancy.list_user_memberships()
    |> Enum.any?(fn m -> Tenancy.may_dm_org?(user, m.org_id) end)
  end
end
