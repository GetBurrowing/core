defmodule Platform.Mail.Digest do
  @moduledoc """
  What is happening across an org's mailboxes, from METADATA ONLY (task
  01a1ea5b stage 5, Email privacy). It is the mail section of the daily
  briefing (the owner's decision: "the digest should just be your morning
  briefing"), and the `mail_digest` agent tool. It is not a page in Email.

  ## Which mailboxes contribute

  A non-archived account of the org that is `"shared"`, or `"personal"` with
  `digest_opt_in` true (its owner opted in, `Ownership.set_digest_opt_in/3`).
  An `"unassigned"` account never contributes, and neither does a personal one
  whose owner has not opted in.

  ## Who sees which rows (the audience rule)

  Until the owner defines a hierarchy, the narrowest reading holds (task
  01a1ea5b's recorded decisions):

    * an ORG ADMIN sees the cross-mailbox view: every contributing account.
      A row of an account the admin cannot read (`Ownership.can_read_account?/2`)
      is labelled "<Owner>'s mailbox (private)" and carries no link;
    * EVERYONE ELSE sees rows only for contributing accounts they can read;
    * an external member, a non-member or a malformed id sees nothing.

  `for_audience/2` applies the rule to several people at once (the agent
  tool's audience: the humans of the space it answers in): an account is in
  view only if it is in view for EVERY one of them, and it is linked only if
  every one of them can read it. An empty audience sees nothing. The rule is
  applied IN THE QUERY: a non-admin's readable set constrains the account
  query by subquery, never by filtering afterwards.

  ## What a row carries, and what it never selects

  One row per (counterparty domain, mailbox):

    * `customer`: the counterparty's email DOMAIN. Burrow has no contact or
      customer record to name the org from, so it is always the domain. The
      mailbox's own domains (its login and sender addresses) are not
      customers and are left out;
    * `people` and `agents` ("Who's on it"): the mailbox's owner (personal) or
      members (shared), the people who sent an accepted reply to that domain
      from it, the agents granted it, and the agents who drafted those replies;
    * `open_threads`: counterparty addresses at that domain whose latest
      inbound mail is newer than the latest accepted delivery to them;
    * `last_activity_at`: the latest inbound or accepted outbound time.

  The SQL selects no subject, no body, no attachment and no sender display
  name or local part: an address is reduced to its domain inside the
  database and only the domain, counts and times leave it. Commitments are
  out of v1 (they need a model to read bodies).
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Mail.{Account, AccountGrant, Ownership}
  alias Platform.Repo
  alias Platform.Tenancy

  @row_limit 25

  @type row :: %{
          org_id: binary(),
          account_id: binary(),
          customer: String.t(),
          mailbox: String.t(),
          readable: boolean(),
          link: String.t() | nil,
          people: [String.t()],
          agents: [String.t()],
          open_threads: non_neg_integer(),
          last_activity_at: DateTime.t() | nil
        }

  @type result :: %{org_id: binary() | nil, mailboxes: non_neg_integer(), rows: [row()]}

  @doc "The most rows one org's digest returns, newest activity first."
  @spec row_limit() :: pos_integer()
  def row_limit, do: @row_limit

  @doc """
  The digest of `org_id` as `viewer` sees it (see the moduledoc's audience
  rule). `mailboxes` counts the contributing accounts in view, so a viewer
  with a mailbox in view but no traffic gets `rows: []` with `mailboxes > 0`
  (the "Nothing to show yet" state), and a viewer with none gets 0.
  """
  @spec for_org(any(), any()) :: result()
  def for_org(viewer, org_id), do: for_audience([viewer], org_id)

  @doc """
  The digest of `org_id` for a whole audience (a list of users): only what
  every one of them would see, linked only where every one of them can read.
  """
  @spec for_audience([any()], any()) :: result()
  def for_audience(users, org_id) when is_list(users) do
    if users != [] and Platform.UUID.valid?(org_id) and
         Enum.all?(users, &Tenancy.internal_member?(&1, org_id)) do
      build(users, org_id)
    else
      empty(org_id)
    end
  end

  def for_audience(_users, org_id), do: empty(org_id)

  @doc """
  The digest of every org `user` is an internal member of, for the briefing:
  `[%{org_id, org_name, mailboxes, rows}]`, orgs with no mailbox in view
  omitted.
  """
  @spec for_user(any()) :: [map()]
  def for_user(%{id: user_id} = user) when is_binary(user_id) do
    user
    |> Tenancy.list_user_memberships()
    |> Enum.reject(&(&1.external or is_nil(&1.org) or Map.get(&1.org, :archived_at)))
    |> Enum.uniq_by(& &1.org_id)
    |> Enum.sort_by(&String.downcase(&1.org.name || ""))
    |> Enum.map(fn membership ->
      membership.org_id |> then(&for_org(user, &1)) |> Map.put(:org_name, membership.org.name)
    end)
    |> Enum.filter(&(&1.mailboxes > 0))
  end

  def for_user(_user), do: []

  # ── Briefing section (Platform.Memory.Insights.BriefingSections provider) ──

  @doc """
  The mail section of the daily briefing, as a core provider of
  `Platform.Memory.Insights.BriefingSections`. None while the Email module is
  off (`Platform.Mail.Config.enabled?/0`, no query).
  """
  @spec briefing_sections() :: [map()]
  def briefing_sections do
    if Platform.Mail.Config.enabled?() do
      [
        %{
          key: "mail",
          component: PlatformWeb.Components.MailDigestSection,
          prepare: &briefing_prepare/2,
          summary: &briefing_summary/2
        }
      ]
    else
      []
    end
  end

  @doc """
  Delivery: 1 when the reader's digest has at least one row today (so a
  briefing is created for them even with no insight), else 0. Writes nothing,
  so it is idempotent per reader and date.
  """
  @spec briefing_prepare(binary(), Date.t()) :: 0 | 1
  def briefing_prepare(user_id, _date) do
    if Enum.any?(for_user(fetch_user(user_id)), &(&1.rows != [])), do: 1, else: 0
  end

  @doc """
  The section counts as ONE informational item (`open` 0, nothing to
  decide) while the reader has a contributing mailbox in view, rows or not;
  nil (section absent) when they have none.
  """
  @spec briefing_summary(binary(), Date.t()) :: map() | nil
  def briefing_summary(user_id, _date) do
    case for_user(fetch_user(user_id)) do
      [] -> nil
      _orgs -> %{total: 1, open: 0, calls: 0}
    end
  end

  defp fetch_user(user_id) when is_binary(user_id), do: Platform.Accounts.get_user(user_id)
  defp fetch_user(_), do: nil

  # ── Build ───────────────────────────────────────────────────────────────

  defp empty(org_id),
    do: %{org_id: if(Platform.UUID.valid?(org_id), do: org_id), mailboxes: 0, rows: []}

  defp build(users, org_id) do
    accounts = users |> accounts_query(org_id) |> Repo.all()

    readable =
      Enum.reduce(users, MapSet.new(accounts, & &1.id), fn user, acc ->
        MapSet.intersection(acc, MapSet.new(Ownership.readable_account_ids(user, org_id)))
      end)

    rows =
      case accounts do
        [] -> []
        _ -> rows(org_id, accounts, readable)
      end

    %{org_id: org_id, mailboxes: length(accounts), rows: rows}
  end

  # The contributing accounts in view for EVERY user: the admin sees every
  # contributing account; anyone else only those they can read, constrained
  # by subquery.
  defp accounts_query(users, org_id) do
    base =
      from(a in Account,
        where: a.org_id == ^org_id and is_nil(a.archived_at),
        where:
          a.owner_kind == "shared" or
            (a.owner_kind == "personal" and a.digest_opt_in == true),
        order_by: [asc: a.name, asc: a.id]
      )

    users
    |> Enum.reject(&Tenancy.org_admin?(&1, org_id))
    |> Enum.reduce(base, fn user, query ->
      where(query, [a], a.id in subquery(Ownership.readable_account_ids_query(user, org_id)))
    end)
  end

  defp rows(org_id, accounts, readable) do
    ids = Enum.map(accounts, & &1.id)
    by_id = Map.new(accounts, &{&1.id, &1})
    activity = activity(org_id, ids)
    repliers = repliers(org_id, ids)
    owners = owner_names(accounts)
    members = member_names(ids)
    granted = Ownership.granted_agent_names(ids)

    Enum.map(activity, fn %{account_id: id, domain: domain} = a ->
      account = Map.fetch!(by_id, id)
      readable? = MapSet.member?(readable, id)
      replied = Map.get(repliers, {id, domain}, %{people: [], agents: []})

      people =
        case account.owner_kind do
          "personal" -> List.wrap(Map.get(owners, account.owner_user_id))
          _ -> Map.get(members, id, [])
        end

      %{
        org_id: org_id,
        account_id: id,
        customer: domain,
        mailbox: mailbox_label(account, Map.get(owners, account.owner_user_id), readable?),
        readable: readable?,
        link: if(readable?, do: "/email?" <> URI.encode_query(account: id)),
        people: Enum.uniq(people ++ replied.people),
        agents: Enum.uniq(Map.get(granted, id, []) ++ replied.agents) |> Enum.sort(),
        open_threads: a.open_threads,
        last_activity_at: a.last_activity_at
      }
    end)
  end

  @doc false
  # "<Owner first name>'s mailbox" for a personal account, the account name
  # for a shared one; " (private)" when the viewer cannot read it.
  @spec mailbox_label(Account.t(), String.t() | nil, boolean()) :: String.t()
  def mailbox_label(%Account{owner_kind: "personal"}, owner, readable?) do
    "#{first_name(owner)}'s mailbox" <> private_suffix(readable?)
  end

  def mailbox_label(%Account{name: name}, _owner, readable?),
    do: (name || "Shared mailbox") <> private_suffix(readable?)

  defp private_suffix(true), do: ""
  defp private_suffix(false), do: " (private)"

  defp first_name(name) when is_binary(name) do
    name |> String.split("@") |> hd() |> String.split(~r/\s+/u, trim: true) |> List.first("Owner")
  end

  defp first_name(_), do: "Owner"

  # Per (account, counterparty domain): open threads and last activity. Each
  # address is reduced to its lowercased bare form inside the database and
  # only its DOMAIN is selected; no subject, body or local part leaves it.
  # The mailbox's own domains (login username, sender addresses) are not
  # counterparties.
  @activity_sql """
  WITH own AS (
    SELECT a.id AS account_id, split_part(lower(a.username), '@', 2) AS domain
      FROM mail_accounts a WHERE a.id = ANY($2) AND a.username LIKE '%@%'
    UNION
    SELECT s.account_id, split_part(lower(s.address), '@', 2)
      FROM mail_senders s WHERE s.account_id = ANY($2) AND s.address LIKE '%@%'
  ), inbound AS (
    SELECT m.account_id,
           btrim(lower(coalesce(substring(m.from_address FROM '<([^<>]+)>'), m.from_address))) AS addr,
           max(m.received_at) AS last_in
      FROM mail_inbound_messages m
     WHERE m.org_id = $1 AND m.account_id = ANY($2) AND m.from_address LIKE '%@%'
     GROUP BY 1, 2
  ), outbound AS (
    SELECT d.account_id,
           btrim(lower(coalesce(substring(r.addr FROM '<([^<>]+)>'), r.addr))) AS addr,
           max(coalesce(d.accepted_at, d.inserted_at)) AS last_out
      FROM mail_deliveries d CROSS JOIN LATERAL unnest(d.recipients) AS r(addr)
     WHERE d.org_id = $1 AND d.account_id = ANY($2) AND d.status = 'accepted'
       AND r.addr LIKE '%@%'
     GROUP BY 1, 2
  ), threads AS (
    SELECT coalesce(i.account_id, o.account_id) AS account_id,
           split_part(coalesce(i.addr, o.addr), '@', 2) AS domain,
           i.last_in, o.last_out
      FROM inbound i
      FULL OUTER JOIN outbound o ON o.account_id = i.account_id AND o.addr = i.addr
  )
  SELECT t.account_id, t.domain,
         count(*) FILTER (WHERE t.last_in IS NOT NULL
                            AND (t.last_out IS NULL OR t.last_in > t.last_out)) AS open_threads,
         max(greatest(t.last_in, t.last_out)) AS last_activity
    FROM threads t
   WHERE t.domain <> ''
     AND NOT EXISTS (SELECT 1 FROM own WHERE own.account_id = t.account_id AND own.domain = t.domain)
   GROUP BY 1, 2
   ORDER BY last_activity DESC NULLS LAST, t.domain ASC
   LIMIT $3
  """

  defp activity(org_id, ids) do
    %{rows: rows} =
      Repo.query!(@activity_sql, [dump(org_id), Enum.map(ids, &dump/1), @row_limit])

    Enum.map(rows, fn [account_id, domain, open, last] ->
      %{
        account_id: load(account_id),
        domain: domain,
        open_threads: open,
        last_activity_at: to_utc(last)
      }
    end)
  end

  # Who replied to each (account, domain): the user who sent an accepted
  # delivery and the agent that drafted it. Ids only; names resolved after.
  @repliers_sql """
  SELECT DISTINCT d.account_id,
         split_part(btrim(lower(coalesce(substring(r.addr FROM '<([^<>]+)>'), r.addr))), '@', 2),
         d.actor_type, d.actor_id, d.drafted_by_type, d.drafted_by_id
    FROM mail_deliveries d CROSS JOIN LATERAL unnest(d.recipients) AS r(addr)
   WHERE d.org_id = $1 AND d.account_id = ANY($2) AND d.status = 'accepted'
  """

  defp repliers(org_id, ids) do
    %{rows: rows} = Repo.query!(@repliers_sql, [dump(org_id), Enum.map(ids, &dump/1)])

    rows =
      Enum.map(rows, fn [account_id, domain, actor_type, actor_id, drafted_type, drafted_id] ->
        {{load(account_id), domain},
         [{actor_type, load(actor_id)}, {drafted_type, load(drafted_id)}]}
      end)

    principals = Enum.flat_map(rows, &elem(&1, 1))
    users = user_names(for {"user", id} <- principals, is_binary(id), do: id)
    agents = agent_names(for {"agent", id} <- principals, is_binary(id), do: id)

    rows
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, lists} ->
      list = List.flatten(lists)

      {key,
       %{
         people: for({"user", id} <- list, name <- [users[id]], name, uniq: true, do: name),
         agents: for({"agent", id} <- list, name <- [agents[id]], name, uniq: true, do: name)
       }}
    end)
  end

  defp owner_names(accounts) do
    accounts
    |> Enum.flat_map(fn
      %Account{owner_kind: "personal", owner_user_id: id} when is_binary(id) -> [id]
      _ -> []
    end)
    |> user_names()
  end

  # Shared mailbox members: the internal-member user grants. DISTINCT by
  # principal (task 01a1f5cc): a principal is named once per account
  # whatever purposes its grants carry. The ORDER BY columns are selected,
  # as SELECT DISTINCT requires.
  defp member_names(ids) do
    from(g in AccountGrant,
      join: u in User,
      on: u.id == g.principal_id,
      where: g.account_id in ^ids and g.principal_type == "user",
      distinct: true,
      order_by: [asc: u.name, asc: u.id],
      select: {g.account_id, coalesce(u.name, u.email), u.name, u.id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp user_names([]), do: %{}

  defp user_names(ids) do
    from(u in User, where: u.id in ^Enum.uniq(ids), select: {u.id, coalesce(u.name, u.email)})
    |> Repo.all()
    |> Map.new()
  end

  defp agent_names([]), do: %{}

  defp agent_names(ids) do
    from(a in Agent, where: a.id in ^Enum.uniq(ids), select: {a.id, a.name})
    |> Repo.all()
    |> Map.new()
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp load(nil), do: nil
  defp load(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp load(other), do: other

  defp to_utc(%DateTime{} = dt), do: dt
  defp to_utc(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")
  defp to_utc(_), do: nil
end
