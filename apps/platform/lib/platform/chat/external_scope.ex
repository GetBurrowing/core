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
      so M7 does not re-implement the allowlist.
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
  """

  import Ecto.Query

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
  The composable subquery yielding the set of `space_id`s the scope's user is
  a `participant_type: "user"` member of. This is the authoritative external
  read-scope. Mirrors the membership check in `Chat.principal_is_member?/2`,
  expressed as a set-returning subquery.
  """
  @spec member_space_ids(t()) :: Ecto.Query.t()
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
  @spec scope_spaces(Ecto.Query.t() | module(), t() | nil) :: Ecto.Query.t() | module()
  def scope_spaces(query, %__MODULE__{external?: true} = scope) do
    where(query, [s], s.id in subquery(member_space_ids(scope)))
  end

  def scope_spaces(query, _scope), do: query

  @doc """
  Scope a query whose first binding carries a `space_id` field (Message /
  Attachment / Canvas) to the external user's member spaces. Identity for
  internal and nil (system) scopes.
  """
  @spec scope_by_space_id(Ecto.Query.t() | module(), t() | nil) :: Ecto.Query.t() | module()
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
  @spec visible_space_id?(binary() | nil, t() | nil) :: boolean()
  def visible_space_id?(space_id, %__MODULE__{external?: true} = scope)
      when is_binary(space_id) do
    Repo.exists?(where(member_space_ids(scope), [p], p.space_id == ^space_id))
  end

  def visible_space_id?(_space_id, _scope), do: true
end
