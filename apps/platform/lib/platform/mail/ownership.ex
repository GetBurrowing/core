defmodule Platform.Mail.Ownership do
  @moduledoc """
  The ONE decision point for who may read a mail account (task 01a1ea5b
  stage 1, Email privacy).

  ## Kinds

    * `"personal"` — exactly one owner (`owner_user_id`). Only the owner
      reads it. There are no co-owners: a user grant on a personal mailbox is
      refused by `grant/3` and, if one were ever written by hand, confers
      nothing. The owner may grant AGENTS.
    * `"shared"` — read by the users holding a user grant (its members). An
      org admin manages its members and agent grants. Being an admin does NOT
      make you a reader: an admin reads a shared mailbox only as a member.
    * `"unassigned"` — readable by NOBODY: no owner, no admin, no agent, no
      `install.admin`, no support session. Every account that existed before
      this stage is unassigned until `set_owner/3` runs with the owner
      mapping (stage 5). No mapping is inferred, and no grant is seeded from
      inbound-space participation.

  A reader must also hold a non-external membership in the account's org
  (`Platform.Tenancy.internal_member?/2`'s rule, inside the query), so a
  person who leaves the org stops reading on the next call.

  ## Why not `Platform.Access`

  Access grants inherit down the org lineage and role rules, so an org-level
  allow or root-admin `install.admin` (including a time-boxed vendor support
  session, task 01a1b362) would read every mailbox. Nothing here consults
  `Platform.Access`, a role, or `Platform.Tenancy.root_admin?/1`. The only
  admin rule is `Platform.Tenancy.org_admin?/2` in `can_manage_access?/2`
  and `set_owner/3`, and neither of those reads mail.

  ## No caching

  Every read hits the database on every call. Nothing is stored in
  `Platform.Access.Scope` (a Scope is a snapshot), and functions taking an
  `%Account{}` re-read its ownership by id rather than trusting the struct,
  so a revoke or an owner change takes effect on the next read.

  ## Writes

  `grant/3`, `revoke/3` and `set_owner/3` are actor-checked and return
  `{:error, :unauthorized}` for a refused actor, writing nothing. Each write
  and its `Platform.Audit` row (`event_type` `"platform.mail.ownership"`,
  `resource_type` `"mail_account"`) commit in one transaction. A grant is a
  permission, not data: revoke deletes the row. `set_owner/3` deletes every
  grant on the account whenever the kind or owner changes (each deletion
  audited), so a new owner inherits no reader the previous owner chose, and
  a shared-to-personal flip leaves no member row that a later flip back would
  revive.

  ## Deleting a principal

  `principal_id` has no FK (it names a user or an agent). DB triggers
  (migration `20261118010000_add_mailbox_ownership`) delete a principal's
  grants in the same statement that deletes the principal; deleting a user
  also returns any mailbox they own to `"unassigned"`, so it fails closed.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Audit
  alias Platform.Mail.{Account, AccountGrant}
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @event_type "platform.mail.ownership"

  @type principal :: {:user, binary()} | {:agent, binary()}

  # ── Reads ───────────────────────────────────────────────────────────────

  @doc """
  Ids of the accounts of `org_id` that `user` may read: the personal
  accounts they own plus the shared accounts they hold a user grant on.
  Unassigned accounts never appear.
  """
  @spec readable_account_ids(any(), any()) :: [binary()]
  def readable_account_ids(user, org_id) do
    case readable_query(user, org_id) do
      nil -> []
      query -> Repo.all(select(query, [a], a.id))
    end
  end

  @doc "May `user` read `account`? Re-reads ownership from the database."
  @spec can_read_account?(any(), Account.t() | any()) :: boolean()
  def can_read_account?(user, %Account{id: id, org_id: org_id}) when is_binary(id) do
    case readable_query(user, org_id) do
      nil -> false
      query -> Repo.exists?(where(query, [a], a.id == ^id))
    end
  end

  def can_read_account?(_user, _account), do: false

  @doc """
  Ids of the accounts of `org_id` that agent `agent_id` holds a grant on.
  An unassigned account is never returned, whatever rows exist.
  """
  @spec agent_granted_account_ids(any(), any()) :: [binary()]
  def agent_granted_account_ids(agent_id, org_id) do
    if uuid?(agent_id) and uuid?(org_id) do
      from(a in Account,
        join: g in AccountGrant,
        on: g.account_id == a.id,
        where: a.org_id == ^org_id,
        where: a.owner_kind != "unassigned",
        where: g.principal_type == "agent" and g.principal_id == ^agent_id,
        select: a.id,
        distinct: true
      )
      |> Repo.all()
    else
      []
    end
  end

  @doc """
  May `user` manage who reads `account` (grant and revoke)? The owner for a
  personal mailbox, an org admin of the account's org for a shared one,
  nobody for an unassigned one. Re-reads ownership from the database.
  """
  @spec can_manage_access?(any(), Account.t() | any()) :: boolean()
  def can_manage_access?(user, %Account{} = account) do
    case fresh(account) do
      %Account{} = current -> manager?(user, current)
      nil -> false
    end
  end

  def can_manage_access?(_user, _account), do: false

  @doc "The grant rows on `account`, oldest first (for the Access panel)."
  @spec list_grants(Account.t()) :: [AccountGrant.t()]
  def list_grants(%Account{id: id}) do
    from(g in AccountGrant, where: g.account_id == ^id, order_by: [asc: g.inserted_at])
    |> Repo.all()
  end

  # ── Writes ──────────────────────────────────────────────────────────────

  @doc """
  Grant `principal` (`{:user, id}` or `{:agent, id}`) read access to
  `account`, as `actor`. Refused with `{:error, :unauthorized}` unless
  `can_manage_access?/2`; `{:error, :not_shared}` for a user grant on a
  non-shared mailbox; `{:error, :unknown_principal}` for a user who is not an
  internal member of the account's org or an agent that does not exist;
  `{:error, :already_granted}` when the grant exists.
  """
  @spec grant(any(), Account.t(), principal()) :: {:ok, AccountGrant.t()} | {:error, term()}
  def grant(actor, %Account{} = account, principal) do
    with %Account{} = current <- fresh(account) || {:error, :not_found},
         :ok <- authorize_manage(actor, current),
         {:ok, {type, id}} <- normalize_principal(principal),
         :ok <- principal_allowed(current, type),
         :ok <- principal_exists(current, type, id) do
      Repo.transaction(fn ->
        changeset =
          AccountGrant.changeset(%AccountGrant{}, %{
            account_id: current.id,
            principal_type: type,
            principal_id: id,
            granted_by_user_id: actor.id
          })

        case Repo.insert(changeset) do
          {:ok, grant} ->
            audit!(actor, current, "grant", %{principal_type: type, principal_id: id})
            grant

          {:error, %Ecto.Changeset{errors: errors}} = error ->
            if Keyword.has_key?(errors, :account_id),
              do: Repo.rollback(:already_granted),
              else: Repo.rollback(elem(error, 1))
        end
      end)
    end
  end

  @doc """
  Revoke `principal`'s grant on `account`, as `actor` (same authorization as
  `grant/3`). Deletes the row; `{:error, :not_found}` when there is none.
  """
  @spec revoke(any(), Account.t(), principal()) :: {:ok, AccountGrant.t()} | {:error, term()}
  def revoke(actor, %Account{} = account, principal) do
    with %Account{} = current <- fresh(account) || {:error, :not_found},
         :ok <- authorize_manage(actor, current),
         {:ok, {type, id}} <- normalize_principal(principal) do
      Repo.transaction(fn ->
        query =
          from(g in AccountGrant,
            where:
              g.account_id == ^current.id and g.principal_type == ^type and
                g.principal_id == ^id
          )

        case Repo.one(query) do
          nil ->
            Repo.rollback(:not_found)

          grant ->
            Repo.delete!(grant)
            audit!(actor, current, "revoke", %{principal_type: type, principal_id: id})
            grant
        end
      end)
    end
  end

  @doc """
  Set `account`'s ownership, as `actor`: `%{kind: "personal", owner_user_id:
  id}`, `%{kind: "shared"}` or `%{kind: "unassigned"}`. Org admins of the
  account's org only (`{:error, :unauthorized}` otherwise). A personal owner
  must be an internal member of that org (`{:error, :unknown_principal}`).
  When the kind or owner changes, every grant on the account is deleted.
  Audited, with the previous and new owner.
  """
  @spec set_owner(any(), Account.t(), map()) :: {:ok, Account.t()} | {:error, term()}
  def set_owner(actor, %Account{} = account, attrs) when is_map(attrs) do
    kind = attrs |> Map.get(:kind, Map.get(attrs, "kind")) |> to_string()
    owner_id = if kind == "personal", do: Map.get(attrs, :owner_user_id, attrs["owner_user_id"])

    with %Account{} = current <- fresh(account) || {:error, :not_found},
         :ok <- authorize_admin(actor, current),
         :ok <- owner_allowed(current, kind, owner_id) do
      Repo.transaction(fn ->
        changeset =
          Account.ownership_changeset(current, %{owner_kind: kind, owner_user_id: owner_id})

        updated =
          case Repo.update(changeset) do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end

        if {current.owner_kind, current.owner_user_id} !=
             {updated.owner_kind, updated.owner_user_id} do
          clear_grants!(actor, current)
        end

        audit!(actor, updated, "set_owner", %{
          previous_kind: current.owner_kind,
          previous_owner_user_id: current.owner_user_id,
          kind: updated.owner_kind,
          owner_user_id: updated.owner_user_id
        })

        updated
      end)
    end
  end

  # ── Internals ───────────────────────────────────────────────────────────

  # The readable-accounts query for a user, or nil when nothing can match.
  # Each `where` is one rule; see the moduledoc.
  defp readable_query(%{id: user_id}, org_id) do
    if uuid?(user_id) and uuid?(org_id) do
      member =
        from(m in OrgMembership,
          where: m.user_id == ^user_id and m.org_id == ^org_id and m.external == false
        )

      user_grant =
        from(g in AccountGrant,
          where:
            g.account_id == parent_as(:account).id and g.principal_type == "user" and
              g.principal_id == ^user_id
        )

      from(a in Account,
        as: :account,
        where: a.org_id == ^org_id,
        where: exists(subquery(member)),
        where:
          (a.owner_kind == "personal" and a.owner_user_id == ^user_id) or
            (a.owner_kind == "shared" and exists(subquery(user_grant)))
      )
    end
  end

  defp readable_query(_user, _org_id), do: nil

  defp manager?(%{id: user_id} = user, %Account{} = account) when is_binary(user_id) do
    case account.owner_kind do
      "personal" ->
        account.owner_user_id == user_id and Tenancy.internal_member?(user, account.org_id)

      "shared" ->
        Tenancy.org_admin?(user, account.org_id)

      _unassigned ->
        false
    end
  end

  defp manager?(_user, _account), do: false

  defp authorize_manage(actor, account),
    do: if(manager?(actor, account), do: :ok, else: {:error, :unauthorized})

  defp authorize_admin(actor, account),
    do: if(Tenancy.org_admin?(actor, account.org_id), do: :ok, else: {:error, :unauthorized})

  defp principal_allowed(%Account{owner_kind: "shared"}, "user"), do: :ok
  defp principal_allowed(%Account{}, "user"), do: {:error, :not_shared}
  defp principal_allowed(%Account{}, "agent"), do: :ok

  defp principal_exists(%Account{org_id: org_id}, "user", id) do
    if Tenancy.internal_member?(%{id: id}, org_id), do: :ok, else: {:error, :unknown_principal}
  end

  defp principal_exists(%Account{}, "agent", id) do
    if Repo.exists?(from(a in Agent, where: a.id == ^id)),
      do: :ok,
      else: {:error, :unknown_principal}
  end

  defp owner_allowed(%Account{org_id: org_id}, "personal", owner_id) do
    if uuid?(owner_id) and Tenancy.internal_member?(%{id: owner_id}, org_id),
      do: :ok,
      else: {:error, :unknown_principal}
  end

  defp owner_allowed(%Account{}, kind, _owner_id) when kind in ["shared", "unassigned"], do: :ok
  defp owner_allowed(%Account{}, _kind, _owner_id), do: {:error, :invalid_kind}

  defp normalize_principal({:user, %User{id: id}}), do: normalize_principal({:user, id})
  defp normalize_principal({:agent, %Agent{id: id}}), do: normalize_principal({:agent, id})

  defp normalize_principal({type, id}) when type in [:user, :agent] do
    if uuid?(id), do: {:ok, {Atom.to_string(type), id}}, else: {:error, :unknown_principal}
  end

  defp normalize_principal(_), do: {:error, :unknown_principal}

  defp clear_grants!(actor, %Account{id: id} = account) do
    from(g in AccountGrant, where: g.account_id == ^id)
    |> Repo.all()
    |> Enum.each(fn grant ->
      Repo.delete!(grant)

      audit!(actor, account, "revoke", %{
        principal_type: grant.principal_type,
        principal_id: grant.principal_id,
        reason: "owner_changed"
      })
    end)
  end

  defp fresh(%Account{id: id}) when is_binary(id) do
    if uuid?(id), do: Repo.one(from(a in Account, where: a.id == ^id))
  end

  defp fresh(_), do: nil

  defp audit!(%{id: actor_id}, %Account{} = account, action, metadata) do
    {:ok, _event} =
      Audit.record(%{
        event_type: @event_type,
        actor_type: "user",
        actor_id: actor_id,
        actor_org_id: account.org_id,
        resource_type: "mail_account",
        resource_id: account.id,
        action: action,
        metadata: metadata
      })

    :ok
  end

  defp uuid?(value), do: Platform.UUID.valid?(value)
end
