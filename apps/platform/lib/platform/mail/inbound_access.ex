defmodule Platform.Mail.InboundAccess do
  @moduledoc """
  Agent reads of stored inbound mail, by PULL (task
  01a13ba5-42a7-7000-8f2b-4c63003f3f92 stage 2). Backs the
  `mail_inbound_list` / `mail_inbound_get` tools
  (`Platform.Federation.MailInboundTools`).

  ## Why pull

  On the live path the only agent-readable form of an email is its chat post
  in `account.inbound_space_id`: agents participating in that space read the
  provenance header and the `ExternalContent.wrap/2` body, capped at
  `Platform.Mail.Inbound.body_cap_bytes/0`, mentions escaped. A backfill
  (`Platform.Mail.Inbound.Backfill`) imports older mail quietly, with no chat
  post, so it must reach the SAME audience another way: agents read on
  request instead of being posted to. Rejected: one post per backfilled
  message (the flood the backfill exists to avoid), bulk Add-to-files
  (thousands of files and their ingest load), and a single digest post
  (it carries no content).

  ## Who may read a row

  Exactly the agents that could read its chat post: an agent that is a
  CURRENT participant (a `chat_participants` row exists; removal deletes it)
  of the row's account's NON-ARCHIVED `inbound_space_id`. When that
  participant's history is bounded (`history_visible_from`, a mention grant),
  a row is visible only when BOTH its `received_at` (the sender-controlled
  Date header) and its `inserted_at` fall at or after that bound, so neither
  a backfilled old message nor a forged future Date header reaches past it.
  An account whose `inbound_space_id` is nil has no agent audience: its mail,
  live or backfilled, stays human-only (Inbox, Add to files). The backfill
  widens nobody's access. Live and backfilled rows are read alike.

  Every miss is the same `:not_found`: an unknown id, a malformed id, a row
  in a space the agent is not in, an archived space, a nil inbound space. A
  caller cannot tell a row it may not read from one that does not exist.

  ## Read-only, and the body stays untrusted

  Nothing here writes, posts, flags, broadcasts or summons. The body is
  rendered by `Platform.Mail.Inbound.render_content/3`, the chat post's own
  renderer, so the cap, the truncation note, the SECURITY NOTICE wrapper and
  mention escaping cannot drift from the live path.
  """

  import Ecto.Query

  alias Platform.Chat.Participant
  alias Platform.Chat.Space
  alias Platform.Mail.Account
  alias Platform.Mail.Inbound
  alias Platform.Mail.InboundMessage
  alias Platform.Repo
  alias Platform.Security.ExternalContent

  @default_limit 50
  @max_limit 200

  @doc "The default and maximum page size of `list/3`."
  @spec limits() :: %{default: pos_integer(), max: pos_integer()}
  def limits, do: %{default: @default_limit, max: @max_limit}

  @doc """
  The rows of `org_id` the agent `agent_id` may read, newest first, with the
  total count of rows matching the same filters. Metadata only, no body.

  Options: `:account_id` (narrows to one account), `:since` (a `Date`;
  `received_at` on or after that day, UTC), `:limit` (clamped to
  1..#{@max_limit}), `:offset`. A malformed `agent_id`, `org_id` or
  `account_id` yields `{[], 0}`.
  """
  @spec list(String.t(), String.t(), keyword()) :: {[map()], non_neg_integer()}
  def list(agent_id, org_id, opts \\ []) do
    account_id = Keyword.get(opts, :account_id)

    if Platform.UUID.valid?(agent_id) and Platform.UUID.valid?(org_id) and
         (is_nil(account_id) or Platform.UUID.valid?(account_id)) do
      limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(1, @max_limit)
      offset = opts |> Keyword.get(:offset, 0) |> clamp(0, nil)

      query =
        agent_id
        |> readable()
        |> where([m], m.org_id == ^org_id)
        |> narrow_account(account_id)
        |> narrow_since(Keyword.get(opts, :since))

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

      {rows, total}
    else
      {[], 0}
    end
  end

  @doc """
  One row the agent may read, rendered. `{:ok, map}` with the metadata of
  `list/3` plus `content`, the chat post's exact rendering; `:not_found` for
  every miss (see the moduledoc).
  """
  @spec get(String.t(), String.t()) :: {:ok, map()} | :not_found
  def get(agent_id, id) do
    with true <- Platform.UUID.valid?(agent_id) and Platform.UUID.valid?(id),
         {%InboundMessage{} = inbound, %Account{} = account} <-
           agent_id
           |> readable()
           |> where([m], m.id == ^id)
           |> select([m, acct], {m, acct})
           |> Repo.one() do
      content = Inbound.render_content(account, inbound, %{text: inbound.text_body})

      {:ok,
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
       })}
    else
      _ -> :not_found
    end
  end

  # The authorisation, as a query: rows whose account's inbound space is
  # live and has `agent_id` as a participant, within that participant's
  # visible history. Both `list/3` and `get/2` start here.
  defp readable(agent_id) do
    from(m in InboundMessage,
      join: acct in Account,
      on: acct.id == m.account_id,
      join: s in Space,
      on: s.id == acct.inbound_space_id and is_nil(s.archived_at),
      join: p in Participant,
      on: p.space_id == s.id and p.participant_type == "agent" and p.participant_id == ^agent_id,
      where:
        is_nil(p.history_visible_from) or
          (m.received_at >= p.history_visible_from and m.inserted_at >= p.history_visible_from)
    )
  end

  defp narrow_account(query, nil), do: query
  defp narrow_account(query, account_id), do: where(query, [m], m.account_id == ^account_id)

  defp narrow_since(query, %Date{} = date) do
    since = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    where(query, [m], m.received_at >= ^since)
  end

  defp narrow_since(query, _), do: query

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

  defp clamp(n, lo, nil) when is_integer(n), do: max(n, lo)
  defp clamp(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, lo, nil), do: lo
  defp clamp(_, _lo, _hi), do: @default_limit
end
