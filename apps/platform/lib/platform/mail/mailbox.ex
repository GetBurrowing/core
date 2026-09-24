defmodule Platform.Mail.Mailbox do
  @moduledoc """
  What the Email module shows, and its one write from the Inbox: "Add to
  files" (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 4).

  Every read is scoped to ONE org id, which the caller has already checked
  the viewer may use (`Platform.Mail.can_use?/2`). Nothing here widens
  across orgs: an id that belongs to another org reads as absent.

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
  alias Platform.Mail.InboundMessage
  alias Platform.Repo
  alias Platform.Security.ExternalContent
  alias Platform.Tasks.Project

  @list_limit 200
  @line_cap 500

  # ── Inbox ───────────────────────────────────────────────────────────────

  @doc """
  Ingested mail of `org_id`, newest first. `opts[:account_id]` narrows to
  one account; a malformed account id narrows to nothing.
  """
  @spec list_inbound(binary(), keyword()) :: [InboundMessage.t()]
  def list_inbound(org_id, opts \\ []) do
    org_id
    |> inbound_query(opts)
    |> order_by([m], desc: m.received_at, desc: m.id)
    |> limit(^Keyword.get(opts, :limit, @list_limit))
    |> Repo.all()
  end

  @doc "How many ingested messages `list_inbound/2` would draw from."
  @spec count_inbound(binary(), keyword()) :: non_neg_integer()
  def count_inbound(org_id, opts \\ []) do
    org_id |> inbound_query(opts) |> select([m], count(m.id)) |> Repo.one()
  end

  defp inbound_query(org_id, opts) do
    if Platform.UUID.valid?(org_id) do
      from(m in InboundMessage, where: m.org_id == ^org_id)
      |> narrow_account(Keyword.get(opts, :account_id))
    else
      from(m in InboundMessage, where: false)
    end
  end

  @doc "The ingested message `id` IF it belongs to `org_id`, else `nil`."
  @spec get_inbound(binary(), binary()) :: InboundMessage.t() | nil
  def get_inbound(org_id, id) when is_binary(org_id) and is_binary(id) do
    if Platform.UUID.valid?(org_id) and Platform.UUID.valid?(id) do
      from(m in InboundMessage, where: m.id == ^id and m.org_id == ^org_id)
      |> Repo.one()
    end
  end

  def get_inbound(_, _), do: nil

  @doc """
  The org id an ingested message belongs to, or `nil`. Lets a deep link
  (`/email/messages/:id`) pick the org the viewer must be checked against.
  """
  @spec inbound_org_id(binary()) :: binary() | nil
  def inbound_org_id(id) when is_binary(id) do
    if Platform.UUID.valid?(id) do
      from(m in InboundMessage, where: m.id == ^id, select: m.org_id) |> Repo.one()
    end
  end

  def inbound_org_id(_), do: nil

  # ── Sent / Refused / Drafts ─────────────────────────────────────────────

  @doc """
  Deliveries of `org_id`, newest first. `:sent` is every status except
  `refused`; `:refused` is refused only.
  """
  @spec list_deliveries(binary(), :sent | :refused, keyword()) :: [Delivery.t()]
  def list_deliveries(org_id, which, opts \\ []) when which in [:sent, :refused] do
    org_id
    |> deliveries_query(which, opts)
    |> order_by([d], desc: d.inserted_at, desc: d.id)
    |> limit(^Keyword.get(opts, :limit, @list_limit))
    |> Repo.all()
  end

  @doc "How many deliveries `list_deliveries/3` would draw from."
  @spec count_deliveries(binary(), :sent | :refused, keyword()) :: non_neg_integer()
  def count_deliveries(org_id, which, opts \\ []) when which in [:sent, :refused] do
    org_id |> deliveries_query(which, opts) |> select([d], count(d.id)) |> Repo.one()
  end

  defp deliveries_query(org_id, which, opts) do
    if Platform.UUID.valid?(org_id) do
      query = from(d in Delivery, where: d.org_id == ^org_id)

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

  @doc "Open drafts (status `draft`) of `org_id`, newest first."
  @spec list_drafts(binary(), keyword()) :: [Draft.t()]
  def list_drafts(org_id, opts \\ []) do
    org_id
    |> drafts_query(opts)
    |> order_by([d], desc: d.updated_at, desc: d.id)
    |> limit(^Keyword.get(opts, :limit, @list_limit))
    |> Repo.all()
  end

  @doc "How many open drafts `list_drafts/2` would draw from."
  @spec count_drafts(binary(), keyword()) :: non_neg_integer()
  def count_drafts(org_id, opts \\ []) do
    org_id |> drafts_query(opts) |> select([d], count(d.id)) |> Repo.one()
  end

  defp drafts_query(org_id, opts) do
    if Platform.UUID.valid?(org_id) do
      from(d in Draft, where: d.org_id == ^org_id and d.status == "draft")
      |> narrow_account(Keyword.get(opts, :account_id))
    else
      from(d in Draft, where: false)
    end
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

    * `:not_found` — no such message;
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
    with org_id when is_binary(org_id) <- inbound_org_id(inbound_id) || {:error, :not_found},
         true <- Mail.can_use?(actor, org_id) || {:error, :unauthorized},
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
