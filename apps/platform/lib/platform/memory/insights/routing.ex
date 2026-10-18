defmodule Platform.Memory.Insights.Routing do
  @moduledoc """
  Who an insight is for. Task `01a13867-3213-7001-a128-6b4c6b34283f`,
  stage 2.

  `resolve/1` returns `{user_id | nil, reason}`, trying these rungs in
  order and stopping at the first that names a user:

  | Rung | Reason |
  |---|---|
  | the explicit `addressee` attribute, a user's email | `"named addressee"` |
  | the explicit `addressee` attribute, an agent slug, mapped to its runtime's owner | `"named agent's owner"` |
  | the evidence's source author: a `journal:` source's entry `authored_by`, a user | `"journal author"` |
  | the same, when the author is an agent, mapped to its runtime's owner | `"owning agent's owner"` |
  | a cited task's sponsor (`task:<uuid>` source) | `"task sponsor"` |
  | the target page's `updated_by` | `"page editor"` |
  | nobody | `"unrouted"` (the insight sits on the tab and needs Reroute) |

  Projects carry no sponsor, so there is no project rung: the sponsor rung
  reads the cited TASK's sponsor.

  The journal rung reads the entries of the cited day (`journal:` source,
  else an `evidence` pointer that is itself a journal path) in insertion
  order and takes the first whose author resolves.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Memory.Insights.Grounding
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Repo
  alias Platform.Tasks.Task

  @unrouted "unrouted"

  @doc "The reason string `resolve/1` returns when no rung names a user."
  @spec unrouted() :: String.t()
  def unrouted, do: @unrouted

  @doc "Resolve an insight's addressee. See the moduledoc."
  @spec resolve(map()) :: {binary() | nil, String.t()}
  def resolve(%{} = insight) do
    action = Map.get(insight, :action) || %{}
    workspace_id = Map.get(insight, :workspace_id)

    [
      fn -> addressee(action["addressee"]) end,
      fn -> journal_author(insight, workspace_id) end,
      fn -> task_sponsor(Map.get(insight, :source_ref)) end,
      fn -> page_editor(action["target"], workspace_id) end
    ]
    |> Enum.find_value({nil, @unrouted}, fn rung ->
      case rung.() do
        {id, _reason} = hit when is_binary(id) -> hit
        _ -> nil
      end
    end)
  end

  @doc """
  Resolve an explicit addressee string: a user's email (case-insensitive),
  a user id, or an agent slug (mapped to its runtime's owner). `nil` when it
  names nobody.
  """
  @spec addressee(term()) :: {binary(), String.t()} | nil
  def addressee(raw) when is_binary(raw) do
    value = String.trim(raw)

    cond do
      value == "" ->
        nil

      String.contains?(value, "@") ->
        email = String.downcase(value)

        case Repo.one(
               from(u in User,
                 where: fragment("lower(?)", u.email) == ^email,
                 select: u.id,
                 limit: 1
               )
             ) do
          nil -> nil
          id -> {id, "named addressee"}
        end

      Platform.UUID.valid?(value) and Repo.exists?(from(u in User, where: u.id == ^value)) ->
        {value, "named addressee"}

      true ->
        agent_slug_owner(value)
    end
  end

  def addressee(_raw), do: nil

  @doc """
  The people an insight in `org_id` can be rerouted to: the org's
  NON-EXTERNAL members, by name (task 01a13867 stage 5, the Insights tab's
  person picker). A guest is never offered, because Tier treats an external
  addressee as `needs_call`. `nil` org is no one.
  """
  @spec candidates(binary() | nil) :: [%{id: binary(), name: String.t(), email: String.t()}]
  def candidates(org_id) when is_binary(org_id) do
    Repo.all(
      from(u in User,
        join: m in Platform.Tenancy.OrgMembership,
        on: m.user_id == u.id,
        where: m.org_id == ^org_id and m.external == false,
        distinct: u.id,
        select: %{id: u.id, name: u.name, email: u.email}
      )
    )
    |> Enum.sort_by(&String.downcase(&1.name || &1.email || ""))
  end

  def candidates(_org_id), do: []

  @doc """
  `user_id => display name` for the given ids (name, else email). Ids that
  are not uuids, or name no user, are left out.
  """
  @spec names([binary() | nil]) :: %{binary() => String.t()}
  def names(user_ids) when is_list(user_ids) do
    ids = user_ids |> Enum.filter(&(is_binary(&1) and Platform.UUID.valid?(&1))) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      from(u in User, where: u.id in ^ids, select: {u.id, u.name, u.email})
      |> Repo.all()
      |> Map.new(fn {id, name, email} -> {id, if(name in [nil, ""], do: email, else: name)} end)
    end
  end

  defp agent_slug_owner(slug) do
    case Repo.one(from(a in Agent, where: a.slug == ^slug, select: a.id, limit: 1)) do
      nil ->
        nil

      agent_id ->
        case Grounding.agent_owner(agent_id) do
          nil -> nil
          owner -> {owner, "named agent's owner"}
        end
    end
  end

  defp journal_author(insight, workspace_id) do
    with path when is_binary(path) <- journal_path(insight),
         {:ok, %{namespace: ns, date: date}} <- Journal.parse_virtual_path(path) do
      date
      |> Journal.get_for_date(namespace: ns, workspace_id: workspace_id)
      |> Enum.find_value(fn entry ->
        case Grounding.author_user(entry.authored_by) do
          {:user, id} -> {id, "journal author"}
          {:agent_owner, id} -> {id, "owning agent's owner"}
          :none -> nil
        end
      end)
    else
      _ -> nil
    end
  end

  defp journal_path(insight) do
    case Grounding.parse(Map.get(insight, :source_ref)) do
      {:ok, {:journal, path}} ->
        path

      _ ->
        insight
        |> Map.get(:evidence)
        |> evidence_journal_path()
    end
  end

  defp evidence_journal_path(evidence) when is_binary(evidence) do
    evidence
    |> String.split(~r/[\s,;]+/, trim: true)
    |> Enum.map(&(&1 |> String.replace_prefix("journal:", "") |> String.replace(~r/[:#].*$/, "")))
    |> Enum.find(&match?({:ok, _}, Journal.parse_virtual_path(&1)))
  end

  defp evidence_journal_path(_evidence), do: nil

  defp task_sponsor(source_ref) do
    with {:ok, {:task, id}} <- Grounding.parse(source_ref),
         true <- Platform.UUID.valid?(id),
         sponsor when is_binary(sponsor) <-
           Repo.one(
             from(t in Task,
               where: t.id == ^id and is_nil(t.deleted_at),
               select: t.sponsor_user_id
             )
           ) do
      {sponsor, "task sponsor"}
    else
      _ -> nil
    end
  end

  defp page_editor(target, workspace_id) when is_binary(target) do
    with %{updated_by: author} when is_binary(author) <-
           Wiki.get_page(target, workspace_id: workspace_id) do
      case Grounding.author_user(author) do
        {:user, id} -> {id, "page editor"}
        {:agent_owner, id} -> {id, "page editor"}
        :none -> nil
      end
    else
      _ -> nil
    end
  end

  defp page_editor(_target, _workspace_id), do: nil
end
