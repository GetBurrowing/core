defmodule Platform.Mail.Drafts do
  @moduledoc """
  Writing email: create, edit and discard drafts, and the read models the
  Email module's editor and confirm pane show (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 5).

  There is no send here. The one way a draft becomes mail is
  `Platform.Mail.Dispatch.dispatch/3`, which refuses an agent actor: agents
  draft, people send.

  ## Who may write

    * `{:user, id}` / `%User{}` — any non-external member of the draft's org
      (`Platform.Mail.can_use?/2`), on any open draft of that org.
    * `{:agent, id}` — the `mail_draft_create` / `mail_draft_update` MCP
      tools. The tenant pin (a tenant-pinned agent may only write into its
      own org) is checked by the tool surface with the same rule the files
      tools use; this module checks that the agent exists and, on update,
      that the draft is one THAT agent created. An agent never edits a
      person's draft.

  Every write re-checks the actor against the org read from the database,
  never from a struct the caller handed in.

  ## Content is stored verbatim

  `subject` and `body` are stored exactly as given — not trimmed, not
  unwrapped, not rendered. An agent-written body is untrusted text; the
  Email module shows it escaped and lets a person read and edit it before
  anything is sent.

  ## References are validated, never guessed

  An `account_id` must be a non-archived account of the draft's org; a
  `sender_key` must exist on that account; `to_user_ids` must name existing
  users; `on_behalf_of_user_id` must be a non-external member of the org; a
  `task_id` must be a task whose project belongs to the org. Anything else
  is a named refusal and nothing is written.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Mail
  alias Platform.Mail.Account
  alias Platform.Mail.Draft
  alias Platform.Mail.Internal
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tasks.Task
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  @address ~r/^[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+$/
  @editable ~w(account_id sender_key to_addresses to_user_ids subject body
               on_behalf_of_user_id responsibility task_id)a

  @type actor :: {:user, binary()} | {:agent, binary()} | User.t()
  @type error ::
          :unauthorized
          | :org_not_found
          | :draft_not_found
          | :draft_not_editable
          | :account_not_found
          | :sender_key_not_found
          | :sender_key_without_account
          | :on_behalf_of_not_member
          | :task_not_found
          | {:invalid_addresses, [String.t()]}
          | {:unknown_recipient_user_ids, [String.t()]}
          | {:invalid, String.t()}

  # ── Writes ──────────────────────────────────────────────────────────────

  @doc """
  Create a draft in `org_id` as `actor`. `attrs` may use atom or string
  keys; see the moduledoc for what is validated.
  """
  @spec create(actor(), binary(), map()) :: {:ok, Draft.t()} | {:error, error()}
  def create(actor, org_id, attrs) when is_map(attrs) do
    with {:ok, actor} <- normalize_actor(actor),
         {:ok, org_id} <- fetch_org(org_id),
         :ok <- authorize_create(actor, org_id),
         {:ok, changes} <- validate(org_id, %{}, normalize(attrs)) do
      {type, id} = actor

      %Draft{}
      |> Draft.changeset(
        Map.merge(changes, %{
          org_id: org_id,
          created_by_type: Atom.to_string(type),
          created_by_id: id,
          status: "draft"
        })
      )
      |> Repo.insert()
    end
  end

  def create(_actor, _org_id, _attrs), do: {:error, {:invalid, "attrs must be a map"}}

  @doc """
  Create a draft written by the platform itself — the email deploy
  strategy's (task 01a0cf21 stage 6). Validated exactly as `create/3`
  validates a person's draft (account and sender key of `org_id`,
  recipients, `on_behalf_of_user_id` a member, `task_id` a task of the org),
  plus `stage_id`, which only the system sets. Not reachable from any tool:
  the MCP draft tools and the Email module build `{:agent, _}` / user
  actors, which `create/3` handles.

  `opts`: `log: false` keeps the draft insert out of the query log (Ecto's
  :debug line prints CAST params, i.e. the body). Default unchanged.
  """
  @spec create_system(binary(), map(), keyword()) :: {:ok, Draft.t()} | {:error, error()}
  def create_system(org_id, attrs, opts \\ []) when is_map(attrs) do
    stage_id = fetch_attr(attrs, :stage_id)

    with {:ok, org_id} <- fetch_org(org_id),
         {:ok, stage_id} <- system_stage_id(stage_id),
         {:ok, changes} <- validate(org_id, %{}, normalize(attrs)) do
      %Draft{}
      |> Draft.changeset(
        Map.merge(changes, %{
          org_id: org_id,
          stage_id: stage_id,
          created_by_type: "system",
          created_by_id: nil,
          status: "draft"
        })
      )
      |> Repo.insert(query_log_opts(opts))
    end
  end

  # `log: false` only when asked: an explicit `log: true` is not a valid
  # Ecto option value, so the default passes no option at all.
  defp query_log_opts(opts),
    do: if(Keyword.get(opts, :log, true) == false, do: [log: false], else: [])

  defp system_stage_id(:error), do: {:ok, nil}
  defp system_stage_id({:ok, nil}), do: {:ok, nil}

  defp system_stage_id({:ok, id}) do
    if Platform.UUID.valid?(id),
      do: {:ok, id},
      else: {:error, {:invalid, "stage_id must be a uuid"}}
  end

  @doc """
  Update the open draft `draft_id` as `actor`. Only the keys present in
  `attrs` change. A draft that is no longer `draft` is not editable.
  """
  @spec update(actor(), binary(), map()) :: {:ok, Draft.t()} | {:error, error()}
  def update(actor, draft_id, attrs) when is_map(attrs) do
    with {:ok, actor} <- normalize_actor(actor),
         {:ok, draft} <- fetch_draft(draft_id),
         :ok <- authorize_edit(actor, draft),
         :ok <- editable(draft),
         {:ok, changes} <- validate(draft.org_id, draft, normalize(attrs)) do
      draft |> Draft.changeset(changes) |> Repo.update()
    end
  end

  def update(_actor, _draft_id, _attrs), do: {:error, {:invalid, "attrs must be a map"}}

  @doc "Discard the open draft `draft_id` as `actor`."
  @spec discard(actor(), binary()) :: {:ok, Draft.t()} | {:error, error()}
  def discard(actor, draft_id) do
    with {:ok, actor} <- normalize_actor(actor),
         {:ok, draft} <- fetch_draft(draft_id),
         :ok <- authorize_edit(actor, draft),
         :ok <- editable(draft) do
      draft |> Draft.changeset(%{status: "discarded"}) |> Repo.update()
    end
  end

  # ── Reads ───────────────────────────────────────────────────────────────

  @doc "The draft `id` IF it belongs to `org_id` (any status), else `nil`."
  @spec get(binary(), binary()) :: Draft.t() | nil
  def get(org_id, id) when is_binary(org_id) and is_binary(id) do
    if Platform.UUID.valid?(org_id) and Platform.UUID.valid?(id) do
      from(d in Draft, where: d.id == ^id and d.org_id == ^org_id) |> Repo.one()
    end
  end

  def get(_, _), do: nil

  @doc """
  The draft `id` in any org, or `nil`. For the agent tool, which checks the
  caller's tenant pin against the returned row's `org_id`.
  """
  @spec fetch(binary()) :: {:ok, Draft.t()} | {:error, :draft_not_found}
  def fetch(id), do: fetch_draft(id)

  @doc """
  `{account, sender}` pairs a draft of `org_id` may be sent from: every
  sender of every non-archived account with Send on, by account name then
  sender key.
  """
  @spec sendable_senders(binary()) :: [{Account.t(), Platform.Mail.Sender.t()}]
  def sendable_senders(org_id) do
    for account <- Mail.list_accounts(org_id),
        account.send_enabled,
        sender <- account.senders,
        do: {account, sender}
  end

  @doc """
  Non-external, non-archived members of `org_id` with an email address, by
  name — the To picker.
  """
  @spec org_people(binary()) :: [%{id: binary(), name: String.t() | nil, email: String.t()}]
  def org_people(org_id) when is_binary(org_id) do
    if Platform.UUID.valid?(org_id) do
      from(u in User,
        join: m in OrgMembership,
        on: m.user_id == u.id,
        where:
          m.org_id == ^org_id and m.external == false and is_nil(u.archived_at) and
            not is_nil(u.email),
        distinct: true,
        order_by: [asc: u.name, asc: u.email],
        select: %{id: u.id, name: u.name, email: u.email}
      )
      |> Repo.all()
    else
      []
    end
  end

  def org_people(_), do: []

  @doc """
  Every recipient of a draft-shaped map, in order, user ids expanded to
  their addresses, each flagged `outside?` by `Platform.Mail.Internal` —
  the SAME function the send path's internal-only check calls.

  Returns `[%{kind: :address | :user, value: address_or_user_id, address:
  address, name: name_or_nil, outside?: boolean}]`. A user id with no row
  is kept with `address: nil` and `outside?: true`, so it is never silently
  dropped from what a person sees.
  """
  @spec recipients(binary(), [String.t()], [String.t()]) :: [map()]
  def recipients(org_id, to_addresses, to_user_ids) do
    users = users_by_id(to_user_ids || [])

    rows =
      Enum.map(to_addresses || [], &%{kind: :address, value: &1, address: &1, name: nil}) ++
        Enum.map(to_user_ids || [], fn id ->
          user = Map.get(users, id)

          %{
            kind: :user,
            value: id,
            address: user && user.email,
            name: user && user.name
          }
        end)

    addresses = rows |> Enum.map(& &1.address) |> Enum.reject(&is_nil/1)
    {_internal, external} = Internal.partition(org_id, addresses)
    external = MapSet.new(external, &String.downcase/1)

    rows
    |> Enum.map(fn row ->
      Map.put(
        row,
        :outside?,
        is_nil(row.address) or MapSet.member?(external, String.downcase(row.address))
      )
    end)
    |> Enum.uniq_by(fn
      %{address: nil, value: value} -> {:unresolved, value}
      %{address: address} -> String.downcase(address)
    end)
  end

  @doc """
  `%{draft_id => %{drafted_by: name, task_title: title_or_nil}}` for a list
  of drafts, in three queries whatever the list length.
  """
  @spec provenance([Draft.t()]) :: %{binary() => %{drafted_by: String.t(), task_title: any()}}
  def provenance(drafts) when is_list(drafts) do
    agent_ids =
      for d <- drafts, d.created_by_type == "agent", d.created_by_id, do: d.created_by_id

    user_ids = for d <- drafts, d.created_by_type == "user", d.created_by_id, do: d.created_by_id
    task_ids = for d <- drafts, d.task_id, do: d.task_id

    agents = names_by_id(Agent, agent_ids)
    users = names_by_id(User, user_ids)
    tasks = titles_by_id(task_ids)

    Map.new(drafts, fn d ->
      drafted_by =
        case d.created_by_type do
          "agent" -> Map.get(agents, d.created_by_id) || "an agent"
          "user" -> Map.get(users, d.created_by_id) || "a person"
          _ -> "the system"
        end

      {d.id, %{drafted_by: drafted_by, task_title: d.task_id && Map.get(tasks, d.task_id)}}
    end)
  end

  @doc "Is `value` shaped like one email address? The editor's add-check."
  @spec valid_address?(any()) :: boolean()
  def valid_address?(value) when is_binary(value), do: Regex.match?(@address, value)
  def valid_address?(_), do: false

  # ── Private: actors and authorization ───────────────────────────────────

  defp normalize_actor(%User{id: id}) when is_binary(id), do: {:ok, {:user, id}}
  defp normalize_actor({:user, id}) when is_binary(id), do: {:ok, {:user, id}}
  defp normalize_actor({:agent, id}) when is_binary(id), do: {:ok, {:agent, id}}
  defp normalize_actor(_), do: {:error, :unauthorized}

  defp authorize_create({:user, id}, org_id) do
    if Mail.can_use?(%{id: id}, org_id), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_create({:agent, id}, _org_id) do
    if agent_exists?(id), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_edit({:user, id}, %Draft{org_id: org_id}) do
    if Mail.can_use?(%{id: id}, org_id), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_edit({:agent, id}, %Draft{created_by_type: "agent", created_by_id: id}) do
    if agent_exists?(id), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_edit({:agent, _id}, %Draft{}), do: {:error, :unauthorized}

  defp agent_exists?(id) do
    Platform.UUID.valid?(id) and
      from(a in Agent, where: a.id == ^id, select: 1) |> Repo.exists?()
  end

  defp editable(%Draft{status: "draft"}), do: :ok
  defp editable(%Draft{}), do: {:error, :draft_not_editable}

  defp fetch_org(org_id) when is_binary(org_id) do
    if Platform.UUID.valid?(org_id) and
         from(o in Org, where: o.id == ^org_id, select: 1) |> Repo.exists?(),
       do: {:ok, org_id},
       else: {:error, :org_not_found}
  end

  defp fetch_org(_), do: {:error, :org_not_found}

  defp fetch_draft(id) when is_binary(id) do
    with true <- Platform.UUID.valid?(id),
         %Draft{} = draft <- from(d in Draft, where: d.id == ^id) |> Repo.one() do
      {:ok, draft}
    else
      _ -> {:error, :draft_not_found}
    end
  end

  defp fetch_draft(_), do: {:error, :draft_not_found}

  # ── Private: validation ─────────────────────────────────────────────────

  defp normalize(attrs) do
    Enum.reduce(@editable, %{}, fn key, acc ->
      case fetch_attr(attrs, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  # `existing` is the draft being updated (or `%{}` on create): the account
  # a sender key is checked against is the new one if given, else the
  # draft's current one.
  defp validate(org_id, existing, changes) do
    with {:ok, changes} <- blank_ids_to_nil(changes),
         :ok <- check_strings(changes),
         {:ok, changes} <- check_addresses(changes),
         :ok <- check_user_ids(changes),
         :ok <- check_account_and_sender(org_id, existing, changes),
         :ok <- check_on_behalf_of(org_id, changes),
         :ok <- check_task(org_id, changes) do
      {:ok, changes}
    end
  end

  @id_keys ~w(account_id sender_key on_behalf_of_user_id task_id responsibility)a

  defp blank_ids_to_nil(changes) do
    {:ok,
     Enum.reduce(@id_keys, changes, fn key, acc ->
       case Map.fetch(acc, key) do
         {:ok, ""} -> Map.put(acc, key, nil)
         _ -> acc
       end
     end)}
  end

  defp check_strings(changes) do
    bad =
      Enum.find(~w(subject body sender_key responsibility)a, fn key ->
        case Map.fetch(changes, key) do
          {:ok, value} -> not (is_nil(value) or is_binary(value))
          :error -> false
        end
      end)

    if bad, do: {:error, {:invalid, "#{bad} must be a string"}}, else: :ok
  end

  defp check_addresses(%{to_addresses: addresses} = changes) when is_list(addresses) do
    if Enum.all?(addresses, &is_binary/1) do
      trimmed =
        addresses
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq_by(&String.downcase/1)

      case Enum.reject(trimmed, &valid_address?/1) do
        [] -> {:ok, %{changes | to_addresses: trimmed}}
        bad -> {:error, {:invalid_addresses, bad}}
      end
    else
      {:error, {:invalid, "to_addresses must be a list of strings"}}
    end
  end

  defp check_addresses(%{to_addresses: nil} = changes), do: {:ok, %{changes | to_addresses: []}}

  defp check_addresses(%{to_addresses: _}),
    do: {:error, {:invalid, "to_addresses must be a list of strings"}}

  defp check_addresses(changes), do: {:ok, changes}

  defp check_user_ids(%{to_user_ids: ids}) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1) do
      found = users_by_id(ids)

      case Enum.reject(ids, &Map.has_key?(found, &1)) do
        [] -> :ok
        missing -> {:error, {:unknown_recipient_user_ids, missing}}
      end
    else
      {:error, {:invalid, "to_user_ids must be a list of user ids"}}
    end
  end

  defp check_user_ids(%{to_user_ids: nil}), do: :ok

  defp check_user_ids(%{to_user_ids: _}),
    do: {:error, {:invalid, "to_user_ids must be a list of user ids"}}

  defp check_user_ids(_), do: :ok

  defp check_account_and_sender(org_id, existing, changes) do
    account_id =
      case Map.fetch(changes, :account_id) do
        {:ok, id} -> id
        :error -> Map.get(existing, :account_id)
      end

    sender_key =
      case Map.fetch(changes, :sender_key) do
        {:ok, key} -> key
        :error -> Map.get(existing, :sender_key)
      end

    account_touched? = Map.has_key?(changes, :account_id) or Map.has_key?(changes, :sender_key)

    cond do
      not account_touched? ->
        :ok

      is_nil(account_id) and is_nil(sender_key) ->
        :ok

      is_nil(account_id) ->
        {:error, :sender_key_without_account}

      true ->
        case Mail.get_account(org_id, account_id) do
          %Account{archived_at: nil} = account ->
            if is_nil(sender_key) or Enum.any?(account.senders, &(&1.key == sender_key)),
              do: :ok,
              else: {:error, :sender_key_not_found}

          _ ->
            {:error, :account_not_found}
        end
    end
  end

  defp check_on_behalf_of(org_id, %{on_behalf_of_user_id: id}) when is_binary(id) do
    if Platform.UUID.valid?(id) and Mail.can_use?(%{id: id}, org_id),
      do: :ok,
      else: {:error, :on_behalf_of_not_member}
  end

  defp check_on_behalf_of(_org_id, %{on_behalf_of_user_id: nil}), do: :ok

  defp check_on_behalf_of(_org_id, %{on_behalf_of_user_id: _}),
    do: {:error, :on_behalf_of_not_member}

  defp check_on_behalf_of(_org_id, _changes), do: :ok

  defp check_task(org_id, %{task_id: id}) when is_binary(id) do
    in_org? =
      Platform.UUID.valid?(id) and
        from(t in Task,
          join: p in Project,
          on: p.id == t.project_id,
          where: t.id == ^id and p.org_id == ^org_id,
          select: 1
        )
        |> Repo.exists?()

    if in_org?, do: :ok, else: {:error, :task_not_found}
  end

  defp check_task(_org_id, %{task_id: nil}), do: :ok
  defp check_task(_org_id, %{task_id: _}), do: {:error, :task_not_found}
  defp check_task(_org_id, _changes), do: :ok

  # ── Private: lookups ────────────────────────────────────────────────────

  defp users_by_id(ids) do
    ids = ids |> Enum.filter(&(is_binary(&1) and Platform.UUID.valid?(&1))) |> Enum.uniq()

    case ids do
      [] ->
        %{}

      ids ->
        from(u in User, where: u.id in ^ids, select: {u.id, %{email: u.email, name: u.name}})
        |> Repo.all()
        |> Map.new()
    end
  end

  defp names_by_id(_schema, []), do: %{}

  defp names_by_id(schema, ids) do
    ids = ids |> Enum.filter(&Platform.UUID.valid?/1) |> Enum.uniq()

    from(r in schema, where: r.id in ^ids, select: {r.id, r.name})
    |> Repo.all()
    |> Map.new()
  end

  defp titles_by_id([]), do: %{}

  defp titles_by_id(ids) do
    ids = ids |> Enum.filter(&Platform.UUID.valid?/1) |> Enum.uniq()

    from(t in Task, where: t.id in ^ids, select: {t.id, t.title})
    |> Repo.all()
    |> Map.new()
  end
end
