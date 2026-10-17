defmodule PlatformWeb.ChatLive.ReadScope do
  @moduledoc """
  The read-scope and the guest flag `PlatformWeb.ChatLive` mounts with (task
  `01a1386d-e528` stage 3, the `ExternalScope` seam row of
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Permission model`).

  `resolve/3` returns `{scope, external?}`:

    * embedded (the meeting chat pane) → `{nil, false}`, as before;
    * LiveAuth's `@access_scope`, when it was built for THIS user → that
      `%Platform.Access.Scope{}`, so explicit `chat.read` / `canvas.read`
      grants compose into every rail read through `ExternalScope`'s Scope
      clauses (zero grants: the same rows as before);
    * otherwise `Platform.Chat.ExternalScope.for_user/1`, whose return type is
      unchanged.

  ## The switch hazard this module exists to hold

  ChatLive used to derive `external?` with
  `match?(%ExternalScope{external?: true}, scope)`. A `%Platform.Access.Scope{}`
  never matches that pattern, so once the scope is a Scope the old match reads
  EVERY guest as internal, and ChatLive hands them the unscoped
  archived-channel list, the pinned task-execution section and the internal
  discovery chrome. `guest?/1` therefore asks each struct its own question:
  `Platform.Access.Scope.guest?/1` for a Scope, the precomputed flag for an
  `%ExternalScope{}`. It never matches one struct to decide for the other.

  Guard: `test/platform_web/live/chat_live_access_scope_guest_test.exs` (a
  guest's mount holds ZERO archived channels while an internal user's holds
  them). It was shown to fail with `guest?/1`'s Scope clause replaced by the
  old struct match.
  """

  alias Platform.Access.Scope
  alias Platform.Chat.ExternalScope

  @doc "The `{read_scope, external?}` pair for a ChatLive mount. See the moduledoc."
  @spec resolve(term(), binary(), boolean()) :: {Scope.t() | ExternalScope.t() | nil, boolean()}
  def resolve(_access_scope, _user_id, true), do: {nil, false}

  def resolve(access_scope, user_id, _embedded?) do
    scope =
      if own_scope?(access_scope, user_id),
        do: access_scope,
        else: ExternalScope.for_user(user_id)

    {scope, guest?(scope)}
  end

  @doc """
  Is the read-scope a guest's? Asked of each struct on its own terms; see the
  moduledoc's switch hazard.
  """
  @spec guest?(term()) :: boolean()
  def guest?(%Scope{} = scope), do: Scope.guest?(scope)
  def guest?(%ExternalScope{external?: external?}), do: external? == true
  def guest?(_scope), do: false

  @doc """
  The org fence on the rail's listed-channel read (task 01a14721 stage 1,
  `Platform.Access.org_fence/1`). That read is deliberately unscoped (it
  feeds the locked restricted-channel entries), so a sub-org-only member's
  copy is narrowed to the fence alone: their own orgs' restricted channels
  still list as locked, a foreign org's never list. Unfenced: unchanged.
  """
  @spec within_org_fence([%{id: binary()}], term()) :: [%{id: binary()}]
  def within_org_fence(channels, access_scope) do
    case Platform.Access.fenced_ids(access_scope, :space) do
      :unfenced ->
        channels

      ids ->
        ids = MapSet.new(ids)
        Enum.filter(channels, &MapSet.member?(ids, &1.id))
    end
  end

  @doc """
  The scope for the mount's archived-channel read: `nil` (unscoped, as
  before) for an unfenced user, the Scope itself for a fenced one.
  """
  @spec fenced_scope(term()) :: Scope.t() | nil
  def fenced_scope(access_scope) do
    if Platform.Access.org_fence(access_scope) == :unfenced, do: nil, else: access_scope
  end

  # LiveAuth builds `@access_scope` from `:current_user_record`; ChatLive
  # mounts as the session's `current_user_id`. Use the Scope only when both
  # name the same user.
  defp own_scope?(%Scope{actor: %{id: id}}, user_id) when is_binary(id), do: id == user_id
  defp own_scope?(_scope, _user_id), do: false
end
