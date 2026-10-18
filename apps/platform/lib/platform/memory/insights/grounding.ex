defmodule Platform.Memory.Insights.Grounding do
  @moduledoc """
  Grounding for dreaming insights: does an insight's `source` name material
  that exists? Task `01a13867-3213-7001-a128-6b4c6b34283f`, stage 2.

  ## The source grammar is closed

  A `source` ref is exactly one of:

    * `page:<file_key>`: `Platform.Org.Wiki.get_page/2` finds the page in
      the insight's workspace;
    * `journal:<path>`: a `<namespace>/journal/<YYYY-MM-DD>.md` path for
      which `Platform.Org.Wiki.Journal.get_for_date/2` has at least one
      entry;
    * `task:<uuid>`: a task row that is not soft-deleted;
    * `message:<uuid>`: a chat message that is not soft-deleted;
    * `query:<name>`: a NAMED query in `queries/0`. The name is a key, not
      free text: a `query:` ref whose name is not in the list does not
      resolve.

  Anything else (an unknown prefix, a blank ref, a malformed id) does not
  resolve.

  ## What grounding does at ingest

  `ground/1` runs on every parsed block before it is stored. `page_edit` is
  the only fact-writing action in this slice. A `page_edit` whose source is
  missing or does not resolve is rewritten into a `question` addressed to
  the owner of the fact (`owner/2`): `downgraded_from` is set to
  `"page_edit"`, the body becomes `"Is this still true? <insight>"` and the
  hunks are dropped, so nothing downstream can apply them. Other action
  types pass through unchanged, grounded or not.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Accounts.User
  alias Platform.Chat.Message
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Repo
  alias Platform.Tasks.Task

  @queries %{
    "agent_runtimes.last_connected_at" =>
      "slug and last_connected_at of every agent runtime, most recent first"
  }

  @hunk_regex ~r/<old>[\s\S]*?<\/old>\s*<new>[\s\S]*?<\/new>/

  @type source ::
          {:page, String.t()}
          | {:journal, String.t()}
          | {:task, String.t()}
          | {:message, String.t()}
          | {:query, String.t()}

  @doc "The named queries a `query:<name>` source may cite."
  @spec queries() :: [String.t()]
  def queries, do: @queries |> Map.keys() |> Enum.sort()

  @doc "One line describing what the named query returns, or nil."
  @spec describe_query(String.t()) :: String.t() | nil
  def describe_query(name), do: Map.get(@queries, name)

  @doc """
  Run a named query and return its rows, for a preview to cite. `:error`
  for a name that is not in `queries/0`.

  `agent_runtimes.last_connected_at` selects the agent slug (falling back to
  the runtime id when the runtime carries no agent) and `last_connected_at`
  of every runtime, most recently connected first.
  """
  @spec run_query(String.t()) :: {:ok, [map()]} | :error
  def run_query("agent_runtimes.last_connected_at") do
    rows =
      Repo.all(
        from(r in AgentRuntime,
          left_join: a in Agent,
          on: a.id == r.agent_id,
          order_by: [desc_nulls_last: r.last_connected_at, asc: r.runtime_id],
          select: %{slug: coalesce(a.slug, r.runtime_id), last_connected_at: r.last_connected_at}
        )
      )

    {:ok, rows}
  end

  def run_query(_name), do: :error

  @doc """
  Parse a source ref into its typed form, or `:error`. Pure: says nothing
  about whether the thing exists.
  """
  @spec parse(term()) :: {:ok, source()} | :error
  def parse(ref) when is_binary(ref) do
    case String.split(String.trim(ref), ":", parts: 2) do
      [kind, rest] when kind in ~w(page journal task message query) ->
        case String.trim(rest) do
          "" -> :error
          value -> {:ok, {String.to_existing_atom(kind), value}}
        end

      _ ->
        :error
    end
  end

  def parse(_ref), do: :error

  @doc """
  True when the insight's `source_ref` resolves (see the moduledoc). Takes
  an insight (or any map with `:source_ref` and `:workspace_id`) or a bare
  ref, which is resolved in the org workspace.
  """
  @spec grounded?(map() | String.t() | nil) :: boolean()
  def grounded?(ref) when is_binary(ref) or is_nil(ref),
    do: grounded?(%{source_ref: ref, workspace_id: nil})

  def grounded?(%{} = insight) do
    workspace_id = Map.get(insight, :workspace_id)

    case parse(Map.get(insight, :source_ref)) do
      {:ok, source} -> resolves?(source, workspace_id)
      :error -> false
    end
  end

  defp resolves?({:page, key}, workspace_id),
    do: not is_nil(Wiki.get_page(key, workspace_id: workspace_id))

  defp resolves?({:journal, path}, workspace_id) do
    case Journal.parse_virtual_path(path) do
      {:ok, %{namespace: ns, date: date}} ->
        Journal.get_for_date(date, namespace: ns, workspace_id: workspace_id) != []

      :error ->
        false
    end
  end

  defp resolves?({:task, id}, _workspace_id) do
    Platform.UUID.valid?(id) and
      Repo.exists?(from(t in Task, where: t.id == ^id and is_nil(t.deleted_at)))
  end

  defp resolves?({:message, id}, _workspace_id) do
    Platform.UUID.valid?(id) and
      Repo.exists?(from(m in Message, where: m.id == ^id and is_nil(m.deleted_at)))
  end

  defp resolves?({:query, name}, _workspace_id), do: Map.has_key?(@queries, name)

  @doc """
  Apply grounding to a parsed insight's attrs at ingest. A `page_edit` that
  is not `grounded?/1` comes back as a `question` to the fact's owner (see
  the moduledoc); everything else comes back unchanged.
  """
  @spec ground(map()) :: map()
  def ground(%{action_type: "page_edit"} = attrs) do
    if grounded?(attrs), do: attrs, else: downgrade(attrs)
  end

  def ground(attrs), do: attrs

  defp downgrade(attrs) do
    action = Map.get(attrs, :action) || %{}
    target = action["target"]
    {owner_id, reason} = owner(target, Map.get(attrs, :workspace_id))

    attrs
    |> Map.merge(%{
      action_type: "question",
      downgraded_from: "page_edit",
      body: "Is this still true? " <> claim(attrs.body),
      action: Map.drop(action, ["hunks"]),
      addressee_user_id: owner_id,
      addressee_reason: reason
    })
  end

  # The insight's prose, without the hunks. A body that is nothing but
  # hunks keeps them, so the question still says what was claimed.
  defp claim(body) do
    case body |> String.replace(@hunk_regex, "") |> String.trim() do
      "" -> String.trim(body)
      prose -> prose
    end
  end

  @doc """
  The owner of the fact at page `file_key`: `{user_id, reason}`, or
  `{nil, "unrouted"}`.

  The owner is the page's `updated_by` when that is a user, or the
  `owner_user_id` of the runtime of the agent that last wrote it. A missing
  page, a page with no `updated_by`, or an author that resolves to no user
  is unrouted.
  """
  @spec owner(String.t() | nil, binary() | nil) :: {binary() | nil, String.t()}
  def owner(file_key, workspace_id) when is_binary(file_key) do
    case Wiki.get_page(file_key, workspace_id: workspace_id) do
      %{updated_by: author} when is_binary(author) ->
        case author_user(author) do
          {:user, id} -> {id, "page owner"}
          {:agent_owner, id} -> {id, "page owner (owning agent's owner)"}
          :none -> {nil, "unrouted"}
        end

      _ ->
        {nil, "unrouted"}
    end
  end

  def owner(_file_key, _workspace_id), do: {nil, "unrouted"}

  @doc """
  Resolve an author id that may name a user or an agent: `{:user, id}` for
  a user, `{:agent_owner, owner_user_id}` for an agent whose runtime has an
  owner (the most recently connected runtime wins), else `:none`.
  """
  @spec author_user(term()) :: {:user, binary()} | {:agent_owner, binary()} | :none
  def author_user(id) when is_binary(id) do
    cond do
      not Platform.UUID.valid?(id) ->
        :none

      Repo.exists?(from(u in User, where: u.id == ^id)) ->
        {:user, id}

      true ->
        case agent_owner(id) do
          nil -> :none
          owner_id -> {:agent_owner, owner_id}
        end
    end
  end

  def author_user(_id), do: :none

  @doc """
  The `owner_user_id` of agent `agent_id`'s most recently connected runtime
  that has an owner, or nil.
  """
  @spec agent_owner(binary()) :: binary() | nil
  def agent_owner(agent_id) when is_binary(agent_id) do
    Repo.one(
      from(r in AgentRuntime,
        where: r.agent_id == ^agent_id and not is_nil(r.owner_user_id),
        order_by: [desc_nulls_last: r.last_connected_at, desc: r.inserted_at],
        limit: 1,
        select: r.owner_user_id
      )
    )
  end
end
