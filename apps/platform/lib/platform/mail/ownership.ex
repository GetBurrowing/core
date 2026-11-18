defmodule Platform.Mail.Ownership do
  @moduledoc """
  The ONE decision point for who may read a mail account (task 01a1ea5b
  stage 1, Email privacy), and the gate every surface that can show mail
  asks (stage 2, "Gated surfaces" below).

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
  revive. Moving a personal mailbox away from its owner tells that previous
  owner, and only them, through one Inbox row that carries no mail content
  (stage 4).

  ## Gated surfaces (stage 2)

  Ownership is enforced in the query of every Mail read: `Platform.Mail.Mailbox`
  (inbox, sent, refused, drafts, deep links, Add to files),
  `Platform.Mail.Drafts` (visibility and editing), `Platform.Mail.Dispatch`
  (a sender must read the account) and `Platform.Mail.list_readable_accounts/2`.

  Mail also lands in chat (each inbound post) and in Files (Add to files).
  Those are gated through two seams:

    * `restricted_space_ids/2`, a RESTRICTION PROVIDER of `Platform.Access`
      (`config :platform, Platform.Access, restriction_providers:`). Access
      never names Mail; it merges a provider's ids into
      `Platform.Access.restricted_space_ids/2`, which feeds `can?/3`,
      `within?/4`, `check/3` and `restriction_ids/3` / `Platform.Access.Query`.
      A mail-bound space is gated as a WHOLE: its name stays listed (as a
      restricted row), nothing is deleted, nobody is removed, and joining it
      grants nothing.
    * `mail_file_ids_unreadable_by/2` / `unreadable_mail_file_ids_query/1`,
      for every file read.

  ## Consumers of chat messages (git grep at stage 2 base 4f81547b6)

  `git grep -l "Chat.Message\|chat_messages\|list_messages\|search_messages"
  -- lib` names 62 files. The ones that put message TEXT in front of a
  person or an agent, each honouring the gate, with the test that pins it
  (`test/platform_web/live/mail_privacy_surfaces_test.exs` unless noted):

    * ChatLive opening a space (`internal_read_denied?/2` → `Access.within?/4`,
      `restricted_space_denied?/2`): "opening the inbound space".
    * Chat list excerpts (`PlatformWeb.ChatLive.ChatListData` via
      `@restricted_channel_ids`): "the chat list excerpt".
    * Chat search (`PlatformWeb.ChatLive.SearchHooks`, re-asked every search):
      "chat search in an open space".
    * Mobile API message routes (`Platform.Mobile.AppEntities.authorize_space/2`
      → `Access.check/3`; `AppMessagesController`, `AppApiController`):
      "the mobile API's space authorization".
    * Inbox rows for a message (`Platform.Inbox.emit/1` → `Access.check/3`):
      "an inbox row for a mail post".
    * Meeting synthesis citations (`Platform.Meetings.Synthesis.Visibility`,
      `:message`, `:canvas`, `:mail`): "meeting synthesis citations".
    * Agent tools `space_get_messages`, `space_search_messages`,
      `space_get_context` (`assert_agent_in_space/2` → `Access.can?/3`) and
      `space_list`: "space_get_messages, space_search_messages,
      space_get_context", "space_list marks the inbound space restricted".
    * Waking an agent (`Platform.Access.AgentWake`: `@`-mention summon,
      `Platform.Chat.AttentionRouter`, `PhaseRuntime`), so an ungranted
      participant is never handed the space's context: "waking an agent".
    * `memory_search` message hits (`Platform.Org.Wiki.Search`,
      `drop_provider_restricted/3` on both lexical and semantic paths):
      "memory_search message hits". The Org Memory pane searches as a person
      (`agent: nil`), which gets no message hit at all: "the Org Memory pane".
    * The Historian / activity digest and the friction watch
      (`Platform.Chat.digest_eligible_messages_query/1`, which excludes every
      mail-bound space): "the Historian / activity digest".
    * Federation peer relay (`Platform.Federation.Peers.Relay.relayable?/1`
      never relays an `email_inbound` post): "a federation peer relay".
    * Canvas reads in a mail-bound space (`Platform.Chat.CanvasAccess`,
      `Access.Query` via `restriction_ids/3`):
      `test/platform/access/restriction_providers_test.exs`.

  The rest read a message only inside a space the reader was already
  admitted to (reply, quote, thread, edit, reaction and version hooks,
  `Platform.Chat.ContextSummary`, `ReplyContext`, `ThreadActivity`), write
  messages (`Chat.post_message`, `Messages.Edit`, `MentionBackfill`, deploy
  and orchestration notices, onboarding, showrunner), or read metadata only
  (`Platform.Inbox.mention_authors/1` on rows already reachable,
  `Platform.Mobile.AppPeople` activity timestamps,
  `Platform.Memory.Insights.Grounding` existence checks,
  `Platform.Habits.LearnedAttention` on a person's own message,
  `Platform.Sharing.Friction` on an agent's question,
  `Platform.Responsibilities.Router`, which never fires on an
  `email_inbound` post).

  Files: FilesLive list, open and semantic search, `Platform.Files.Browser`
  (recents, by type, search, one project, a direct fetch, stars), the
  download route `/files/blob/:id`, and the agent tools `file_list`,
  `file_get_text`, `file_get_metadata`, `file_search`. `memory_search`
  never returns a `document` hit (`Platform.Org.Wiki.Search.semantic_corpus/1`
  refuses the tag; tool_surface_files_test.exs holds it).

  ## Agents (stage 3)

  An agent reads a mailbox only through a grant row; inbound-space
  participation confers nothing. The agent mail tools read through
  `audience_account_ids_query/3`: the agent's grants intersected with what
  every human in the space the agent names may read. Who that audience is,
  the withheld notice, the audit row and the four places this cannot be
  enforced are `Platform.Mail.InboundAccess`'s. Agent drafts
  (`Platform.Mail.Drafts`) may name only a granted account.

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
  alias Platform.Chat.Message
  alias Platform.Mail.{Account, AccountGrant, InboundMessage}
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

  @doc """
  `readable_account_ids/2` as a query selecting account ids, for a read to
  constrain IN ITS QUERY (`account_id in subquery(...)`). Matches nothing
  when `user` or `org_id` is not a valid id.
  """
  @spec readable_account_ids_query(any(), any()) :: Ecto.Query.t()
  def readable_account_ids_query(user, org_id) do
    case readable_query(user, org_id) do
      nil -> from(a in Account, where: false, select: a.id)
      query -> select(query, [a], a.id)
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
  The agent-side read rule of stage 3, as a query selecting account ids of
  `org_id`: the accounts agent `agent_id` holds a grant on (the GRANT term),
  intersected with the accounts EVERY user in `audience_user_ids` may read
  by `readable_account_ids/2`'s rule (the AUDIENCE term). One SQL query, one
  subquery per audience member, for a read to constrain IN ITS QUERY.

  An empty audience matches nothing: there is no person to answer, so the
  rule fails closed. So does a malformed agent, org or audience id.
  `Platform.Mail.InboundAccess` is the caller; it derives the audience from
  the space the agent names (see its moduledoc for what that can and cannot
  enforce).
  """
  @spec audience_account_ids_query(any(), any(), [any()]) :: Ecto.Query.t()
  def audience_account_ids_query(agent_id, org_id, audience_user_ids)
      when is_list(audience_user_ids) do
    if uuid?(agent_id) and uuid?(org_id) and audience_user_ids != [] and
         Enum.all?(audience_user_ids, &uuid?/1) do
      granted = readable_ids_query({:agent, agent_id})

      base =
        from(a in Account,
          where: a.org_id == ^org_id,
          where: a.id in subquery(granted),
          select: a.id
        )

      Enum.reduce(audience_user_ids, base, fn user_id, query ->
        where(query, [a], a.id in subquery(readable_ids_query({:user, user_id})))
      end)
    else
      none_query()
    end
  end

  def audience_account_ids_query(_agent_id, _org_id, _audience), do: none_query()

  @doc """
  `agent_granted_account_ids/2` as a query selecting account ids, for a read
  to constrain in its query. Matches nothing for a malformed id.
  """
  @spec agent_granted_account_ids_query(any(), any()) :: Ecto.Query.t()
  def agent_granted_account_ids_query(agent_id, org_id) do
    if uuid?(agent_id) and uuid?(org_id) do
      from(a in Account,
        where: a.org_id == ^org_id,
        where: a.id in subquery(readable_ids_query({:agent, agent_id})),
        select: a.id
      )
    else
      none_query()
    end
  end

  @doc """
  `%{account_id => [agent display name]}` for the agents granted each of
  `account_ids`, sorted by name. Metadata for the stage 3 `access_line`; it
  reads grants, never mail. One query.
  """
  @spec granted_agent_names([binary()]) :: %{binary() => [String.t()]}
  def granted_agent_names([]), do: %{}

  def granted_agent_names(account_ids) when is_list(account_ids) do
    ids = Enum.filter(account_ids, &uuid?/1)

    from(g in AccountGrant,
      join: ag in Agent,
      on: ag.id == g.principal_id,
      where: g.account_id in ^ids and g.principal_type == "agent",
      order_by: [asc: ag.name, asc: ag.id],
      select: {g.account_id, ag.name}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp none_query, do: from(a in Account, where: false, select: a.id)

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

  @doc """
  The grant rows on `account`, oldest first (for the Access panel), as
  `actor`. `{:error, :unauthorized}` unless `can_manage_access?/2`: who can
  read a personal mailbox is itself private, so a non-owner member and an
  org admin of a personal mailbox are refused.
  """
  @spec list_grants(any(), Account.t() | any()) ::
          {:ok, [AccountGrant.t()]} | {:error, :unauthorized}
  def list_grants(actor, %Account{} = account) do
    with %Account{} = current <- fresh(account) || {:error, :unauthorized},
         :ok <- authorize_manage(actor, current) do
      {:ok,
       from(g in AccountGrant, where: g.account_id == ^current.id, order_by: [asc: g.inserted_at])
       |> Repo.all()}
    end
  end

  def list_grants(_actor, _account), do: {:error, :unauthorized}

  @doc """
  Who can read `account`, for a READER of it (task 01a1ea5b stage 4: the
  Email access line and the read-only Access panel). `{:ok, %{kind, people,
  agents}}` where `people` are the users who read it (the owner of a
  personal mailbox; the internal members holding a user grant on a shared
  one) and `agents` the agents granted it, each `%{id, name, avatar_url}`
  sorted by name. `{:error, :unauthorized}` unless `can_read_account?/2`:
  a mailbox you cannot read does not tell you who can. Grant rows (who
  granted, when) stay behind `list_grants/2`. Reads grants and names, never
  mail.
  """
  @spec audience(any(), Account.t() | any()) ::
          {:ok, %{kind: String.t(), people: [map()], agents: [map()]}}
          | {:error, :unauthorized}
  def audience(viewer, %Account{} = account) do
    with %Account{} = current <- fresh(account) || {:error, :unauthorized},
         true <- can_read_account?(viewer, current) || {:error, :unauthorized} do
      {:ok,
       %{kind: current.owner_kind, people: readers(current), agents: granted_agents(current)}}
    end
  end

  def audience(_viewer, _account), do: {:error, :unauthorized}

  @doc """
  `%{{type, id} => %{id, name, avatar_url}}` for the principals of `grants`
  (`%AccountGrant{}` rows from `list_grants/2`), so the Access panel can name
  them. Names only; a principal whose row is gone is absent. Two queries at
  most, whatever the count.
  """
  @spec principal_names([AccountGrant.t()]) :: %{{String.t(), binary()} => map()}
  def principal_names(grants) when is_list(grants) do
    ids = fn type ->
      for %AccountGrant{principal_type: ^type, principal_id: id} <- grants, uuid?(id), do: id
    end

    agents =
      case ids.("agent") do
        [] ->
          []

        agent_ids ->
          from(ag in Agent,
            where: ag.id in ^agent_ids,
            select: %{id: ag.id, name: ag.name, avatar_url: ag.avatar_url}
          )
          |> Repo.all()
          |> Enum.map(&{{"agent", &1.id}, &1})
      end

    users =
      case ids.("user") do
        [] ->
          []

        user_ids ->
          from(u in User,
            where: u.id in ^user_ids,
            select: %{id: u.id, name: coalesce(u.name, u.email), avatar_url: u.avatar_url}
          )
          |> Repo.all()
          |> Enum.map(&{{"user", &1.id}, &1})
      end

    Map.new(agents ++ users)
  end

  def principal_names(_grants), do: %{}

  defp readers(%Account{owner_kind: "personal", owner_user_id: owner_id})
       when is_binary(owner_id) do
    from(u in User,
      where: u.id == ^owner_id,
      select: %{id: u.id, name: coalesce(u.name, u.email), avatar_url: u.avatar_url}
    )
    |> Repo.all()
  end

  defp readers(%Account{owner_kind: "shared", id: id, org_id: org_id}) do
    from(u in User,
      join: g in AccountGrant,
      on: g.principal_type == "user" and g.principal_id == u.id,
      join: m in OrgMembership,
      on: m.user_id == u.id and m.org_id == ^org_id and m.external == false,
      where: g.account_id == ^id,
      distinct: true,
      order_by: [asc: coalesce(u.name, u.email), asc: u.id],
      select: %{id: u.id, name: coalesce(u.name, u.email), avatar_url: u.avatar_url}
    )
    |> Repo.all()
  end

  defp readers(%Account{}), do: []

  defp granted_agents(%Account{id: id}) do
    from(g in AccountGrant,
      join: ag in Agent,
      on: ag.id == g.principal_id,
      where: g.account_id == ^id and g.principal_type == "agent",
      order_by: [asc: ag.name, asc: ag.id],
      select: %{id: ag.id, name: ag.name, avatar_url: ag.avatar_url}
    )
    |> Repo.all()
  end

  # ── Gated surfaces (stage 2) ────────────────────────────────────────────

  @doc """
  Restriction provider for `Platform.Access` (`config :platform,
  Platform.Access, restriction_providers:`): the MAIL-BOUND spaces among
  `ids` (or all of them, for `:all`) that `scope`'s actor may not read.

  A space is mail-bound when it is any account's `inbound_space_id`
  (archived accounts included) or holds a chat message referenced by
  `mail_inbound_messages.chat_message_id` (so moving `inbound_space_id`
  later releases no old post). It is restricted unless the actor can read
  EVERY account bound to it: a user by `readable_account_ids/2`'s rule, an
  agent runtime by a grant on a non-unassigned account. Any other actor (a
  meeting invitee, a role preview, an empty Scope) reads no mailbox, so
  every mail-bound space is restricted for it. `:system` never reaches
  here (`Platform.Access` short-circuits it).

  ONE query whatever `ids` is: the union of the two binding clauses, each
  constrained to accounts the actor cannot read.
  """
  @spec restricted_space_ids(Platform.Access.Scope.t() | any(), [binary()] | :all) :: [binary()]
  def restricted_space_ids(_scope, []), do: []

  def restricted_space_ids(scope, ids) do
    readable = readable_ids_query(principal(scope))

    by_inbound =
      from(a in Account,
        where: not is_nil(a.inbound_space_id) and a.id not in subquery(readable),
        select: a.inbound_space_id
      )

    by_post =
      from(i in InboundMessage,
        join: m in Message,
        on: m.id == i.chat_message_id,
        where: i.account_id not in subquery(readable),
        select: m.space_id
      )

    {by_inbound, by_post} =
      case ids do
        :all ->
          {by_inbound, by_post}

        ids when is_list(ids) ->
          ids = Enum.filter(ids, &uuid?/1)

          {where(by_inbound, [a], a.inbound_space_id in ^ids),
           where(by_post, [_i, m], m.space_id in ^ids)}
      end

    by_inbound |> union(^by_post) |> Repo.all()
  end

  @doc """
  The ids among `inbound_ids` (`mail_inbound_messages`) whose account
  `principal` may read, as a MapSet. Same principals as
  `mail_file_ids_unreadable_by/2`. One query.
  """
  @spec readable_inbound_ids(any(), [binary()]) :: MapSet.t()
  def readable_inbound_ids(_principal, []), do: MapSet.new()

  def readable_inbound_ids(principal, inbound_ids) when is_list(inbound_ids) do
    ids = Enum.filter(inbound_ids, &uuid?/1)
    readable = readable_ids_query(principal(principal))

    from(i in InboundMessage,
      where: i.id in ^ids and i.account_id in subquery(readable),
      select: i.id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  The file ids among `file_ids` that mail was added to (`mail_inbound_messages.file_id`)
  and that `principal` may not read, as a MapSet. `principal` is a user
  (`%{id: _}` or `{:user, id}`), `{:agent, id}`, or a `%Platform.Access.Scope{}`
  (its actor). Any other value reads no mailbox. One query.
  """
  @spec mail_file_ids_unreadable_by(any(), [binary()]) :: MapSet.t()
  def mail_file_ids_unreadable_by(_principal, []), do: MapSet.new()

  def mail_file_ids_unreadable_by(principal, file_ids) when is_list(file_ids) do
    ids = Enum.filter(file_ids, &uuid?/1)

    principal
    |> unreadable_mail_file_ids_query()
    |> where([i], i.file_id in ^ids)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  The query form of `mail_file_ids_unreadable_by/2`: selects every mail-derived
  file id `principal` may not read, for a file listing to exclude IN ITS
  QUERY (`file.id not in subquery(...)`).
  """
  @spec unreadable_mail_file_ids_query(any()) :: Ecto.Query.t()
  def unreadable_mail_file_ids_query(principal) do
    readable = readable_ids_query(principal(principal))

    from(i in InboundMessage,
      where: not is_nil(i.file_id) and i.account_id not in subquery(readable),
      select: i.file_id
    )
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
  Audited, with the previous and new owner. When a personal mailbox leaves
  its owner, that previous owner gets ONE Inbox notice (kind
  `"mailbox_reassigned"`) naming the admin, the address and the new owner,
  with no mail content; nobody else is notified.
  """
  @spec set_owner(any(), Account.t(), map()) :: {:ok, Account.t()} | {:error, term()}
  def set_owner(actor, %Account{} = account, attrs) when is_map(attrs) do
    kind = attrs |> Map.get(:kind, Map.get(attrs, "kind")) |> to_string()
    owner_id = if kind == "personal", do: Map.get(attrs, :owner_user_id, attrs["owner_user_id"])

    with %Account{} = current <- fresh(account) || {:error, :not_found},
         :ok <- authorize_admin(actor, current),
         :ok <- owner_allowed(current, kind, owner_id),
         {:ok, updated} <- write_owner(actor, current, kind, owner_id) do
      notify_previous_owner(actor, current, updated)
      {:ok, updated}
    end
  end

  defp write_owner(actor, current, kind, owner_id) do
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

  # The previous owner of a personal mailbox hears that it moved (task
  # 01a1ea5b stage 4; Ryan accepted the plan's question-4 proposal). ONE
  # Inbox row, to that person only, carrying no mail content: "<admin>
  # reassigned <address> to <new owner>". Nobody else is told: not the new
  # owner, not the actor, not the old owner when the owner did not change or
  # when they made the change themselves. Sent after the write commits; a
  # notice that fails to insert never undoes the reassignment.
  defp notify_previous_owner(actor, %Account{} = before, %Account{} = updated) do
    previous = before.owner_kind == "personal" && before.owner_user_id

    if is_binary(previous) and previous != updated.owner_user_id and
         previous != Map.get(actor, :id) do
      names = user_names([Map.get(actor, :id), updated.owner_user_id])

      title =
        "#{Map.get(names, Map.get(actor, :id), "An org admin")} reassigned " <>
          "#{mailbox_address(updated)} to #{new_owner_text(updated, names)}"

      Platform.Inbox.emit(%{
        user_id: previous,
        kind: "mailbox_reassigned",
        source_type: "mail_account",
        source_id: updated.id,
        title: title,
        url: "/email"
      })
    end

    :ok
  end

  defp new_owner_text(%Account{owner_kind: "personal", owner_user_id: id}, names),
    do: Map.get(names, id, "another person")

  defp new_owner_text(%Account{owner_kind: "shared"}, _names), do: "a shared mailbox"
  defp new_owner_text(%Account{}, _names), do: "no owner"

  @doc """
  The address a person knows a mailbox by: its login username, else its
  name. Metadata only; used in the reassignment notice.
  """
  @spec mailbox_address(Account.t()) :: String.t()
  def mailbox_address(%Account{username: username}) when is_binary(username) and username != "",
    do: username

  def mailbox_address(%Account{name: name}), do: name || "a mailbox"

  defp user_names(ids) do
    ids = Enum.filter(ids, &uuid?/1)

    from(u in User, where: u.id in ^ids, select: {u.id, coalesce(u.name, u.email)})
    |> Repo.all()
    |> Map.new()
  end

  # ── Internals ───────────────────────────────────────────────────────────

  # The readable-accounts query for a user, or nil when nothing can match.
  # Each `where` is one rule; see the moduledoc.
  defp readable_query(%{id: user_id}, org_id) do
    if uuid?(user_id) and uuid?(org_id) do
      user_id
      |> user_readable_query()
      |> where([a], a.org_id == ^org_id)
    end
  end

  defp readable_query(_user, _org_id), do: nil

  # Every account (any org) `user_id` reads: the membership is correlated on
  # the account's own org.
  defp user_readable_query(user_id) do
    member =
      from(m in OrgMembership,
        where:
          m.user_id == ^user_id and m.org_id == parent_as(:account).org_id and
            m.external == false
      )

    user_grant =
      from(g in AccountGrant,
        where:
          g.account_id == parent_as(:account).id and g.principal_type == "user" and
            g.principal_id == ^user_id
      )

    from(a in Account,
      as: :account,
      where: exists(subquery(member)),
      where:
        (a.owner_kind == "personal" and a.owner_user_id == ^user_id) or
          (a.owner_kind == "shared" and exists(subquery(user_grant)))
    )
  end

  # The ids of every account (any org) a principal reads, as a query.
  defp readable_ids_query({:user, user_id}),
    do: user_id |> user_readable_query() |> select([a], a.id)

  defp readable_ids_query({:agent, agent_id}) do
    from(a in Account,
      join: g in AccountGrant,
      on: g.account_id == a.id,
      where: a.owner_kind != "unassigned",
      where: g.principal_type == "agent" and g.principal_id == ^agent_id,
      select: a.id
    )
  end

  defp readable_ids_query(:nobody), do: from(a in Account, where: false, select: a.id)

  # Who a Scope, a user or a tagged principal is, for the gated surfaces.
  defp principal(%Platform.Access.Scope{actor: actor}), do: principal(actor)

  defp principal(%Platform.Agents.AgentRuntime{agent_id: id}),
    do: if(uuid?(id), do: {:agent, id}, else: :nobody)

  defp principal(%Agent{id: id}), do: principal({:agent, id})

  defp principal({type, id}) when type in [:user, :agent],
    do: if(uuid?(id), do: {type, id}, else: :nobody)

  defp principal(%{id: id}) when is_binary(id),
    do: if(uuid?(id), do: {:user, id}, else: :nobody)

  defp principal(_), do: :nobody

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
