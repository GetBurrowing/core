defmodule Platform.Mail.InboundAccess do
  @moduledoc """
  Agent reads of stored inbound mail, by PULL. Backs the `mail_inbound_list`
  / `mail_inbound_get` tools (`Platform.Federation.MailInboundTools`). The
  pull design is task 01a13ba5 stage 2's: a backfill imports mail with no
  chat post, so agents read on request instead of being posted to.

  ## Who may read a row (task 01a1ea5b stage 3, Email privacy)

  The old rule, "a current participant of the account's inbound space",
  is GONE. Inbound-space participation confers nothing (stage 2 gates the
  space itself). An agent's right to a mailbox comes only from a
  `mail_account_grants` row its owner (or, for a shared mailbox, an org
  admin) wrote through `Platform.Mail.Ownership.grant/3`.

  A grant alone is not enough, because an agent answers SOMEONE. Burrow has
  no authenticated record of which person asked: an MCP call's context
  carries only `agent_id` and `runtime_id`, and `space_id` is read from the
  caller's arguments (`Platform.Federation.ToolArguments`). So every read
  names the space the answer is for (`space_id`, required), and:

    1. the agent must be a CURRENT participant (a `chat_participants` row;
       removal deletes it) of that NON-ARCHIVED space, else `:not_found`
       (the PARTICIPANT check);
    2. the AUDIENCE is that space's current human participants
       (`participant_type` `"user"`);
    3. the readable accounts are the agent's granted accounts (the GRANT
       term) intersected with the accounts EVERY audience member may read
       (the AUDIENCE term), all in one query
       (`Platform.Mail.Ownership.audience_account_ids_query/3`);
    4. an empty audience (no human in the space) yields nothing: fail
       closed. Background understanding goes through the morning-briefing
       digest (stage 5) instead.

  When the intersection removed rows the agent's grant alone would have
  read, the result carries `withheld_notice`, verbatim
  "I can't share mail from a mailbox you don't have access to", and NOTHING
  else about them: no count, no subject, no placeholder, since each of those
  would tell the audience that the mail exists. Each result also carries
  `audience` (the humans' display names) and `access_line` (the text form of
  the Email page's access line: `Visible to you · <agents>` for one person,
  `Visible to <n> people · <agents>` for more, naming the agents granted the
  mailboxes in view).

  A space's chat-history bound (`history_visible_from`) no longer applies:
  it bounded the old rule's inbound-space history, and the audience space
  is a different space. The mailbox grant is the bound.

  Every miss is the same `:not_found`: an unknown or malformed id, a row of
  a mailbox the agent is not granted, an unassigned mailbox, a space the
  agent is not in or that is archived, a missing `space_id`. A caller cannot
  tell a row it may not read from one that does not exist. A row the agent
  IS granted but the audience may not read is `:withheld`, never its
  content.

  ## Audit

  Every `list/4` and `get/3` with a well-formed agent id writes one
  `Platform.Audit` row (`event_type` `"platform.mail.agent_read"`,
  `actor_type` `"agent"`, `resource_type` `"chat_space"`, `resource_id` the
  named space), whose metadata holds the outcome, the audience user ids, the
  account ids in view and the row ids returned. Never a subject, a sender,
  a body or a count of withheld rows.

  ## Where this CANNOT be enforced

    1. `space_id` is asserted by the agent. An agent that names a DM with the
       owner and then posts the answer elsewhere defeats it. The audit row
       makes that traceable, not impossible.
    2. Mail an agent read earlier stays in its context and memory, and can
       be paraphrased in an unrelated later reply.
    3. An agent can copy what it read into the journal, a canvas, a file or
       a task that others read. Burrow does not trace content provenance.
    4. A federated agent's operator can see its transcripts.

  ## Read-only, and the body stays untrusted

  Nothing here posts, flags, broadcasts or summons; the only write is the
  audit row. The body is rendered by `Platform.Mail.Inbound.render_content/3`,
  the chat post's own renderer, so the cap, the truncation note, the
  SECURITY NOTICE wrapper and mention escaping cannot drift from the live
  path.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Audit
  alias Platform.Chat.Participant
  alias Platform.Chat.Space
  alias Platform.Mail.Account
  alias Platform.Mail.Inbound
  alias Platform.Mail.InboundMessage
  alias Platform.Mail.Ownership
  alias Platform.Repo
  alias Platform.Security.ExternalContent

  @default_limit 50
  @max_limit 200
  @withheld_notice "I can't share mail from a mailbox you don't have access to"
  @event_type "platform.mail.agent_read"

  @doc "The default and maximum page size of `list/4`."
  @spec limits() :: %{default: pos_integer(), max: pos_integer()}
  def limits, do: %{default: @default_limit, max: @max_limit}

  @doc "The withheld notice, verbatim (design canvas copy)."
  @spec withheld_notice() :: String.t()
  def withheld_notice, do: @withheld_notice

  @doc """
  The rows of `org_id` agent `agent_id` may read for the audience of
  `space_id`, newest first, with the total count of rows matching the same
  filters. Metadata only, no body.

  `{:ok, %{messages, total, audience, access_line}}`, plus `withheld_notice`
  when the audience term removed rows. `:not_found` when the agent is not a
  current participant of the non-archived space, or the agent, org or
  space id is malformed.

  Options: `:account_id` (narrows to one account; a malformed one to
  nothing), `:since` (a `Date`; `received_at` on or after that day, UTC),
  `:limit` (clamped to 1..#{@max_limit}), `:offset`.
  """
  @spec list(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | :not_found
  def list(agent_id, org_id, space_id, opts \\ []) do
    account_id = Keyword.get(opts, :account_id)

    with true <- Platform.UUID.valid?(agent_id) and Platform.UUID.valid?(org_id),
         {:ok, audience} <- audience(agent_id, space_id) do
      limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(1, @max_limit)
      offset = opts |> Keyword.get(:offset, 0) |> clamp(0, nil)
      since = Keyword.get(opts, :since)

      visible_accounts =
        Ownership.audience_account_ids_query(agent_id, org_id, Enum.map(audience, & &1.id))

      query = rows_query(org_id, visible_accounts, account_id, since)
      total = Repo.aggregate(query, :count)

      rows =
        query
        |> order_by([m], desc: m.received_at, desc: m.id)
        |> limit(^limit)
        |> offset(^offset)
        |> select([m], %{
          id: m.id,
          account_id: m.account_id,
          folder: m.folder,
          received_at: m.received_at,
          from_address: m.from_address,
          subject: m.subject,
          ingest_source: m.ingest_source
        })
        |> Repo.all()
        |> Enum.map(&summary/1)

      in_view = visible_accounts |> narrow_ids(account_id) |> Repo.all()

      withheld? =
        org_id
        |> rows_query(
          Ownership.agent_granted_account_ids_query(agent_id, org_id),
          account_id,
          since
        )
        |> where([m], m.account_id not in subquery(visible_accounts))
        |> Repo.exists?()

      audit!(agent_id, org_id, space_id, "list", %{
        outcome: if(withheld?, do: "withheld", else: "ok"),
        audience_user_ids: Enum.map(audience, & &1.id),
        account_ids: in_view,
        row_ids: Enum.map(rows, & &1.id)
      })

      {:ok,
       %{messages: rows, total: total}
       |> Map.merge(framing(audience, in_view))
       |> maybe_withheld(withheld?)}
    else
      _ ->
        audit_miss(agent_id, org_id, space_id, "list")
        :not_found
    end
  end

  @doc """
  One row agent `agent_id` may read for the audience of `space_id`,
  rendered: `{:ok, map}` with the metadata of `list/4`, `content` (the chat
  post's exact rendering), `audience` and `access_line`.

  `{:withheld, %{org_id, withheld_notice, audience, access_line}}` when the
  agent is granted the row's mailbox but the audience may not read it: no
  content, no metadata of the row. `:not_found` for every other miss (see
  the moduledoc).
  """
  @spec get(String.t(), String.t() | nil, String.t()) ::
          {:ok, map()} | {:withheld, map()} | :not_found
  def get(agent_id, space_id, id) do
    with true <- Platform.UUID.valid?(agent_id) and Platform.UUID.valid?(id),
         {:ok, audience} <- audience(agent_id, space_id),
         {%InboundMessage{} = inbound, %Account{} = account} <-
           from(m in InboundMessage,
             join: acct in Account,
             on: acct.id == m.account_id,
             where: m.id == ^id,
             select: {m, acct}
           )
           |> Repo.one() do
      audience_ids = Enum.map(audience, & &1.id)

      visible? =
        agent_id
        |> Ownership.audience_account_ids_query(inbound.org_id, audience_ids)
        |> where([a], a.id == ^inbound.account_id)
        |> Repo.exists?()

      granted? =
        visible? or
          agent_id
          |> Ownership.agent_granted_account_ids_query(inbound.org_id)
          |> where([a], a.id == ^inbound.account_id)
          |> Repo.exists?()

      cond do
        visible? ->
          audit!(agent_id, inbound.org_id, space_id, "get", %{
            outcome: "ok",
            audience_user_ids: audience_ids,
            account_ids: [inbound.account_id],
            row_ids: [inbound.id]
          })

          {:ok, render(inbound, account) |> Map.merge(framing(audience, [inbound.account_id]))}

        granted? ->
          audit!(agent_id, inbound.org_id, space_id, "get", %{
            outcome: "withheld",
            audience_user_ids: audience_ids,
            account_ids: [],
            row_ids: []
          })

          {:withheld,
           %{org_id: inbound.org_id}
           |> Map.merge(framing(audience, []))
           |> maybe_withheld(true)}

        true ->
          audit_miss(agent_id, inbound.org_id, space_id, "get")
          :not_found
      end
    else
      _ ->
        audit_miss(agent_id, nil, space_id, "get")
        :not_found
    end
  end

  # ── The PARTICIPANT check and the audience ──────────────────────────────

  # `{:ok, [%{id, name}]}` — the space's current human participants — when
  # `agent_id` is a current participant of the non-archived `space_id`;
  # `:not_found` otherwise.
  defp audience(agent_id, space_id) do
    if Platform.UUID.valid?(space_id) and agent_in_space?(agent_id, space_id) do
      {:ok,
       from(p in Participant,
         left_join: u in User,
         on: u.id == p.participant_id,
         where: p.space_id == ^space_id and p.participant_type == "user",
         order_by: [asc: p.joined_at, asc: p.id],
         select: %{id: p.participant_id, name: coalesce(u.name, p.display_name)}
       )
       |> Repo.all()
       |> Enum.uniq_by(& &1.id)}
    else
      :not_found
    end
  end

  defp agent_in_space?(agent_id, space_id) do
    from(s in Space,
      join: p in Participant,
      on: p.space_id == s.id and p.participant_type == "agent" and p.participant_id == ^agent_id,
      where: s.id == ^space_id and is_nil(s.archived_at)
    )
    |> Repo.exists?()
  end

  # ── Queries ─────────────────────────────────────────────────────────────

  defp rows_query(org_id, account_ids_query, account_id, since) do
    from(m in InboundMessage,
      where: m.org_id == ^org_id,
      where: m.account_id in subquery(account_ids_query)
    )
    |> narrow_account(account_id)
    |> narrow_since(since)
  end

  # A malformed `account_id` narrows to nothing; it never drops the filter.
  defp narrow_account(query, nil), do: query

  defp narrow_account(query, account_id) do
    if Platform.UUID.valid?(account_id),
      do: where(query, [m], m.account_id == ^account_id),
      else: where(query, false)
  end

  defp narrow_ids(query, nil), do: query

  defp narrow_ids(query, account_id) do
    if Platform.UUID.valid?(account_id),
      do: where(query, [a], a.id == ^account_id),
      else: where(query, false)
  end

  defp narrow_since(query, %Date{} = date) do
    since = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    where(query, [m], m.received_at >= ^since)
  end

  defp narrow_since(query, _), do: query

  # ── Results ─────────────────────────────────────────────────────────────

  defp render(%InboundMessage{} = inbound, %Account{} = account) do
    content = Inbound.render_content(account, inbound, %{text: inbound.text_body})

    inbound
    |> Map.take([
      :id,
      :account_id,
      :folder,
      :received_at,
      :from_address,
      :subject,
      :ingest_source
    ])
    |> summary()
    |> Map.merge(%{
      org_id: inbound.org_id,
      body_bytes: byte_size(inbound.text_body || ""),
      truncated: byte_size(inbound.text_body || "") > Inbound.body_cap_bytes(),
      content: content
    })
  end

  # `audience` and `access_line` for the accounts in view.
  defp framing(audience, account_ids) do
    names = Enum.map(audience, &(&1.name || "a person"))

    who =
      case names do
        [] -> "Visible to no one"
        [_one] -> "Visible to you"
        many -> "Visible to #{length(many)} people"
      end

    agents =
      account_ids
      |> Ownership.granted_agent_names()
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    %{audience: names, access_line: Enum.join([who | agents], " · ")}
  end

  defp maybe_withheld(result, true), do: Map.put(result, :withheld_notice, @withheld_notice)
  defp maybe_withheld(result, false), do: result

  defp summary(row) do
    %{
      id: row.id,
      account_id: row.account_id,
      folder: row.folder,
      received_at: row.received_at && DateTime.to_iso8601(row.received_at),
      from: line(row.from_address),
      subject: line(row.subject),
      ingest_source: row.ingest_source
    }
  end

  # Sender-controlled header text, as the chat post's provenance shows it,
  # with no mention token left in it.
  defp line(value) do
    case Inbound.one_line(value) do
      nil -> nil
      text -> ExternalContent.escape_mentions(text)
    end
  end

  # ── Audit ───────────────────────────────────────────────────────────────

  defp audit_miss(agent_id, org_id, space_id, action) do
    audit!(agent_id, org_id, space_id, action, %{
      outcome: "not_found",
      audience_user_ids: [],
      account_ids: [],
      row_ids: []
    })
  end

  # One row per call with a well-formed agent id. Ids only, never content.
  defp audit!(agent_id, org_id, space_id, action, metadata) do
    if Platform.UUID.valid?(agent_id) do
      space_id = if Platform.UUID.valid?(space_id), do: space_id
      org_id = if Platform.UUID.valid?(org_id), do: org_id

      {:ok, _event} =
        Audit.record(%{
          event_type: @event_type,
          actor_type: "agent",
          actor_id: agent_id,
          actor_org_id: org_id,
          resource_type: "chat_space",
          resource_id: space_id,
          action: action,
          metadata: Map.put(metadata, :space_id, space_id)
        })
    end

    :ok
  end

  defp clamp(n, lo, nil) when is_integer(n), do: max(n, lo)
  defp clamp(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, lo, nil), do: lo
  defp clamp(_, _lo, _hi), do: @default_limit
end
