defmodule Platform.Mail.Mailbox do
  @moduledoc """
  What the Email module shows, and its one write from the Inbox: "Add to
  files" (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 4).

  Every read is scoped to ONE org id, which the caller has already checked
  the viewer may use (`Platform.Mail.can_use?/2`). Nothing here widens
  across orgs: an id that belongs to another org reads as absent.

  Every read also takes the VIEWER and is constrained, in its query, to the
  accounts that viewer may read (`Platform.Mail.Ownership`, task 01a1ea5b
  stage 2). A row of an unreadable account reads exactly as an unknown id.

  ## Add to files

  `add_to_files/3` renders an ingested email as a `text/markdown` document
  and stores it through `Platform.Files.add_bytes/5` — the same path the
  `file_add` MCP tool uses, so there is no second store. The row's `file_id`
  is set in the same transaction, under a row lock, so a second click (or a
  second tab) returns the existing file instead of creating another.

  The rendition is read later by agents (`file_get_text`, `file_search`,
  memory). The header block (From / To / Date / Subject / Message-ID /
  Account) sits OUTSIDE the untrusted-content wrapper, each value collapsed
  to one sanitized line; the body sits INSIDE
  `Platform.Security.ExternalContent.wrap/2` — the SECURITY NOTICE, random-id
  markers, forged markers neutralised, LLM special tokens stripped — and
  every `@[` in the document is made inert.
  """

  import Ecto.Query

  alias Platform.Files
  alias Platform.Mail
  alias Platform.Mail.Account
  alias Platform.Mail.Delivery
  alias Platform.Mail.Draft
  alias Platform.Mail.Drafts
  alias Platform.Mail.InboundMessage
  alias Platform.Mail.Ownership
  alias Platform.Repo
  alias Platform.Security.ExternalContent
  alias Platform.Tasks.Project

  @list_limit 200
  @line_cap 500

  # ── Inbox ───────────────────────────────────────────────────────────────

  @doc """
  Ingested mail of `org_id` that `viewer` may read, newest first.
  `opts[:account_id]` narrows to one account; a malformed account id
  narrows to nothing. Constrained to
  `Platform.Mail.Ownership.readable_account_ids_query/2` in the query.
  """
  @spec list_inbound(any(), binary(), keyword()) :: [InboundMessage.t()]
  def list_inbound(viewer, org_id, opts \\ []) do
    viewer
    |> inbound_query(org_id, opts)
    |> order_by([m], desc: m.received_at, desc: m.id)
    |> limit(^Keyword.get(opts, :limit, @list_limit))
    |> Repo.all()
  end

  @doc "How many ingested messages `list_inbound/3` would draw from."
  @spec count_inbound(any(), binary(), keyword()) :: non_neg_integer()
  def count_inbound(viewer, org_id, opts \\ []) do
    viewer |> inbound_query(org_id, opts) |> select([m], count(m.id)) |> Repo.one()
  end

  defp inbound_query(viewer, org_id, opts) do
    if Platform.UUID.valid?(org_id) do
      from(m in InboundMessage,
        where: m.org_id == ^org_id and m.account_id in subquery(readable(viewer, org_id))
      )
      |> narrow_account(Keyword.get(opts, :account_id))
    else
      from(m in InboundMessage, where: false)
    end
  end

  @doc """
  The ingested message `id` IF it belongs to `org_id` and `viewer` may read
  its account, else `nil`: an unreadable message is indistinguishable from
  an unknown one.
  """
  @spec get_inbound(any(), binary(), binary()) :: InboundMessage.t() | nil
  def get_inbound(viewer, org_id, id) when is_binary(org_id) and is_binary(id) do
    if Platform.UUID.valid?(org_id) and Platform.UUID.valid?(id) do
      from(m in InboundMessage,
        where:
          m.id == ^id and m.org_id == ^org_id and
            m.account_id in subquery(readable(viewer, org_id))
      )
      |> Repo.one()
    end
  end

  def get_inbound(_, _, _), do: nil

  @doc """
  The org id of an ingested message `viewer` may read, or `nil` (unknown and
  unreadable alike). Lets a deep link (`/email/messages/:id`) pick the org
  without becoming an existence oracle.
  """
  @spec inbound_org_id(any(), binary()) :: binary() | nil
  def inbound_org_id(viewer, id) when is_binary(id) do
    with true <- Platform.UUID.valid?(id),
         org_id when is_binary(org_id) <- raw_inbound_org_id(id),
         %InboundMessage{} <- get_inbound(viewer, org_id, id) do
      org_id
    else
      _ -> nil
    end
  end

  def inbound_org_id(_, _), do: nil

  defp raw_inbound_org_id(id),
    do: from(m in InboundMessage, where: m.id == ^id, select: m.org_id) |> Repo.one()

  defp readable(viewer, org_id), do: Ownership.readable_account_ids_query(viewer, org_id)

  # ── Sent / Refused / Drafts ─────────────────────────────────────────────

  @doc """
  Deliveries of `org_id` from accounts `viewer` may read, newest first.
  `:sent` is every status except `refused`; `:refused` is refused only.
  """
  @spec list_deliveries(any(), binary(), :sent | :refused, keyword()) :: [Delivery.t()]
  def list_deliveries(viewer, org_id, which, opts \\ []) when which in [:sent, :refused] do
    viewer
    |> deliveries_query(org_id, which, opts)
    |> order_by([d], desc: d.inserted_at, desc: d.id)
    |> limit(^Keyword.get(opts, :limit, @list_limit))
    |> Repo.all()
  end

  @doc "How many deliveries `list_deliveries/4` would draw from."
  @spec count_deliveries(any(), binary(), :sent | :refused, keyword()) :: non_neg_integer()
  def count_deliveries(viewer, org_id, which, opts \\ []) when which in [:sent, :refused] do
    viewer |> deliveries_query(org_id, which, opts) |> select([d], count(d.id)) |> Repo.one()
  end

  defp deliveries_query(viewer, org_id, which, opts) do
    if Platform.UUID.valid?(org_id) do
      query =
        from(d in Delivery,
          where: d.org_id == ^org_id and d.account_id in subquery(readable(viewer, org_id))
        )

      query =
        case which do
          :sent -> where(query, [d], d.status != "refused")
          :refused -> where(query, [d], d.status == "refused")
        end

      narrow_account(query, Keyword.get(opts, :account_id))
    else
      from(d in Delivery, where: false)
    end
  end

  @doc """
  Open drafts (status `draft`) of `org_id` that `viewer` may see
  (`Platform.Mail.Drafts.visible_query/2`), newest first.
  """
  @spec list_drafts(any(), binary(), keyword()) :: [Draft.t()]
  def list_drafts(viewer, org_id, opts \\ []) do
    viewer
    |> drafts_query(org_id, opts)
    |> order_by([d], desc: d.updated_at, desc: d.id)
    |> limit(^Keyword.get(opts, :limit, @list_limit))
    |> Repo.all()
  end

  @doc "How many open drafts `list_drafts/3` would draw from."
  @spec count_drafts(any(), binary(), keyword()) :: non_neg_integer()
  def count_drafts(viewer, org_id, opts \\ []) do
    viewer |> drafts_query(org_id, opts) |> select([d], count(d.id)) |> Repo.one()
  end

  defp drafts_query(viewer, org_id, opts) do
    viewer
    |> Drafts.visible_query(org_id)
    |> where([d], d.status == "draft")
    |> narrow_account(Keyword.get(opts, :account_id))
  end

  # A malformed account id narrows to nothing — dropping the filter would
  # widen a scoped list to every account of the org.
  defp narrow_account(query, nil), do: query

  defp narrow_account(query, account_id) when is_binary(account_id) do
    if Platform.UUID.valid?(account_id),
      do: where(query, [r], r.account_id == ^account_id),
      else: where(query, [r], false)
  end

  # ── Pickers ─────────────────────────────────────────────────────────────

  @doc "Non-archived projects owned by `org_id`, by name — Add to files targets."
  @spec org_projects(binary()) :: [Project.t()]
  def org_projects(org_id) when is_binary(org_id) do
    if Platform.UUID.valid?(org_id) do
      from(p in Project,
        where: p.org_id == ^org_id and is_nil(p.archived_at),
        order_by: [asc: p.name]
      )
      |> Repo.all()
    else
      []
    end
  end

  @doc """
  Non-archived, non-direct channels owned by `org_id`, by name — the only
  spaces an account may post incoming mail to.
  """
  @spec org_channels(binary()) :: [Platform.Chat.Space.t()]
  def org_channels(org_id) when is_binary(org_id) do
    if Platform.UUID.valid?(org_id) do
      from(s in Platform.Chat.Space,
        where:
          s.org_id == ^org_id and s.kind == "channel" and is_nil(s.archived_at) and
            s.is_direct == false,
        order_by: [asc: s.name]
      )
      |> Repo.all()
    else
      []
    end
  end

  # ── Add to files ────────────────────────────────────────────────────────

  @doc """
  Store ingested message `inbound_id` as a markdown file in `project_id`,
  as `actor`.

  Refusals, before anything is written:

    * `:not_found` — no such message, or one whose account `actor` may not
      read (`Platform.Mail.Ownership.can_read_account?/2`): the same answer;
    * `:unauthorized` — `actor` is not a non-external member of the
      message's org;
    * `:project_not_found` — the project is missing, archived, or owned by
      another org.

  Returns `{:ok, :created, file}` when this call created (or deduplicated
  onto) a file, `{:ok, :existing, file}` when the message was already in
  files. Ingest is enqueued only after the transaction commits, because the
  ingester reads the row from another process.
  """
  @spec add_to_files(any(), binary(), binary()) ::
          {:ok, :created | :existing, Files.File.t()} | {:error, term()}
  def add_to_files(actor, inbound_id, project_id) do
    with true <-
           (is_binary(inbound_id) and Platform.UUID.valid?(inbound_id)) || {:error, :not_found},
         org_id when is_binary(org_id) <- raw_inbound_org_id(inbound_id) || {:error, :not_found},
         true <- Mail.can_use?(actor, org_id) || {:error, :unauthorized},
         true <- readable_inbound?(actor, org_id, inbound_id) || {:error, :not_found},
         {:ok, project} <- fetch_org_project(org_id, project_id) do
      result =
        Repo.transaction(fn ->
          inbound = lock_inbound!(inbound_id)

          case existing_file(inbound) do
            %Files.File{} = file ->
              {:existing, file}

            nil ->
              store(inbound, project, actor)
          end
        end)

      case result do
        {:ok, {:existing, file}} ->
          {:ok, :existing, file}

        {:ok, {:created, file, dedup?}} ->
          unless dedup?, do: :ok = Files.Ingester.ingest_async(file)
          {:ok, :created, file}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # `can_read_account?/2` on the message's account, re-read here so the
  # check is not only the lookup above.
  defp readable_inbound?(actor, org_id, inbound_id) do
    case from(m in InboundMessage,
           where: m.id == ^inbound_id and m.org_id == ^org_id,
           select: m.account_id
         )
         |> Repo.one() do
      account_id when is_binary(account_id) ->
        Ownership.can_read_account?(actor, %Account{id: account_id, org_id: org_id})

      _ ->
        false
    end
  end

  defp fetch_org_project(org_id, project_id) when is_binary(project_id) do
    if Platform.UUID.valid?(project_id) do
      case from(p in Project,
             where: p.id == ^project_id and p.org_id == ^org_id and is_nil(p.archived_at)
           )
           |> Repo.one() do
        %Project{} = project -> {:ok, project}
        nil -> {:error, :project_not_found}
      end
    else
      {:error, :project_not_found}
    end
  end

  defp fetch_org_project(_org_id, _project_id), do: {:error, :project_not_found}

  defp lock_inbound!(id) do
    from(m in InboundMessage, where: m.id == ^id, lock: "FOR UPDATE") |> Repo.one!()
  end

  # A file that was since deleted does not count as "in files": the next
  # click stores it again and repoints the row.
  @doc """
  The live (not soft-deleted) file an ingested message was added as, or
  `nil`. A file deleted since does not count as "in files".
  """
  @spec inbound_file(InboundMessage.t()) :: Files.File.t() | nil
  def inbound_file(%InboundMessage{file_id: nil}), do: nil
  def inbound_file(%InboundMessage{file_id: file_id}), do: Files.get_file(file_id)

  defp existing_file(inbound), do: inbound_file(inbound)

  defp store(%InboundMessage{} = inbound, %Project{} = project, actor) do
    account = from(a in Account, where: a.id == ^inbound.account_id) |> Repo.one!()
    bytes = render_markdown(account, inbound)

    case Files.add_bytes(project, bytes, filename(inbound), "text/markdown",
           uploaded_by_user_id: actor_user_id(actor),
           ingest: false
         ) do
      {:ok, file, dedup?} ->
        inbound |> Ecto.Changeset.change(file_id: file.id) |> Repo.update!()
        {:created, file, dedup?}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp actor_user_id(%{id: id}) when is_binary(id), do: id
  defp actor_user_id(_), do: nil

  @doc """
  The markdown rendition of an ingested email. Public for tests.

  Header block outside the wrapper, one sanitized line per value; the body
  inside `ExternalContent.wrap/2`; every `@[` escaped.
  """
  @spec render_markdown(Account.t(), InboundMessage.t()) :: String.t()
  def render_markdown(%Account{} = account, %InboundMessage{} = inbound) do
    subject = one_line(inbound.subject) || "(no subject)"

    headers =
      [
        {"From", one_line(inbound.from_address) || "(unknown sender)"},
        {"To", one_line(Enum.join(inbound.to_addresses || [], ", ")) || "(none)"},
        {"Date", DateTime.to_iso8601(inbound.received_at)},
        {"Subject", subject},
        {"Message-ID", one_line(inbound.message_id_header) || "(none)"},
        {"Account", one_line(Platform.Mail.Inbound.account_address(account, inbound))}
      ]
      |> Enum.map_join("\n", fn {label, value} -> "- #{label}: #{value}" end)

    wrapped =
      ExternalContent.wrap(inbound.text_body || "",
        source: :email,
        sender: inbound.from_address,
        subject: inbound.subject
      )

    ["# Email: #{subject}", headers, wrapped]
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
    |> ExternalContent.escape_mentions()
  end

  @doc "`<YYYY-MM-DD>-<subject-slug>.md` for an ingested email."
  @spec filename(InboundMessage.t()) :: String.t()
  def filename(%InboundMessage{} = inbound) do
    date = inbound.received_at |> DateTime.to_date() |> Date.to_iso8601()

    slug =
      (inbound.subject || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 60)
      |> String.trim("-")

    "#{date}-#{if slug == "", do: "email", else: slug}.md"
  end

  defp one_line(nil), do: nil

  defp one_line(value) when is_binary(value) do
    case value
         |> ExternalContent.sanitize_line()
         |> String.trim()
         |> String.slice(0, @line_cap) do
      "" -> nil
      line -> line
    end
  end
end
