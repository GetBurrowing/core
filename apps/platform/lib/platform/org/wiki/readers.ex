defmodule Platform.Org.Wiki.Readers do
  @moduledoc """
  Generic page-level reader restriction, keyed off a page's own frontmatter.

  A page whose frontmatter carries a `readers:` key (a list drawn from
  `subject` and `admins`) is readable by:

    * `%Platform.Access.Scope{actor: :system}`,
    * any `%Platform.Agents.AgentRuntime{}` actor,
    * a `nil` scope (the caller asked no access question),

  and by a USER actor iff

    * `admins` is listed and `Platform.Tenancy.org_admin?(actor, scope.org.id)`
      holds (an internal `admin` membership in the scope's org), or
    * `subject` is listed and the frontmatter's `subject_user_id` equals the
      actor's id — and the actor is an internal member of the scope's org.

  A page WITHOUT `readers:` is readable by everyone: byte-for-byte today's
  behaviour. An external member never passes either branch: `org_admin?/2`
  and `internal_member?/2` both require `external == false`, and a scope with
  no org passes neither.

  A restricted page a user may not read does not exist for them — `nil` from
  `Platform.Org.Wiki.get_page/2`, absent from `list_pages/1` and from
  `Platform.Org.Wiki.Search` — never an error that confirms existence. The
  seam is `Platform.Org.Wiki.maybe_scope_by/2`, which runs `restrict/2`
  BEFORE the RBAC `scope_by/3`.

  This module knows nothing about who sets the keys. It never references
  paths, slugs or any People module: whoever writes a page with `readers:`
  (today the HR responsibility) owns the policy; the Wiki only enforces the
  key. The dependency is one-directional and `readers_dependency_test.exs`
  pins it.
  """

  import Ecto.Query, only: [where: 3]

  alias Platform.Access.Scope
  alias Platform.Agents.AgentRuntime
  alias Platform.Org.WikiPage
  alias Platform.Tenancy

  @readers_key "readers"
  @subject_key "subject_user_id"

  @doc """
  Does this scope ask a readers question at all? `true` only for a user
  actor; system, runtime and `nil` scopes read every page.
  """
  @spec applies?(Scope.t() | nil) :: boolean()
  def applies?(nil), do: false
  def applies?(%Scope{actor: :system}), do: false
  def applies?(%Scope{actor: %AgentRuntime{}}), do: false
  def applies?(%Scope{}), do: true
  def applies?(_), do: false

  @doc """
  Restrict a `WikiPage` query (its root binding) to the pages `scope` may
  read under the `readers:` rule. A no-op for system, runtime and `nil`
  scopes; a user actor keeps unrestricted pages plus the branch(es) it
  passes. Any other actor keeps unrestricted pages only.
  """
  @spec restrict(Ecto.Queryable.t(), Scope.t() | nil) :: Ecto.Queryable.t()
  def restrict(query, nil), do: query
  def restrict(query, %Scope{actor: :system}), do: query
  def restrict(query, %Scope{actor: %AgentRuntime{}}), do: query

  def restrict(query, %Scope{actor: %{id: user_id}} = scope) when is_binary(user_id) do
    %{admin?: admin?, internal?: internal?} = standing(scope)

    where(
      query,
      [p],
      is_nil(fragment("? -> ?", p.frontmatter, ^@readers_key)) or
        (^admin? and fragment("(? -> ?) @> '[\"admins\"]'::jsonb", p.frontmatter, ^@readers_key)) or
        (^internal? and
           fragment("(? -> ?) @> '[\"subject\"]'::jsonb", p.frontmatter, ^@readers_key) and
           fragment("? ->> ?", p.frontmatter, ^@subject_key) == ^user_id)
    )
  end

  def restrict(query, %Scope{}) do
    where(query, [p], is_nil(fragment("? -> ?", p.frontmatter, ^@readers_key)))
  end

  @doc "Does the page carry a `readers:` key at all?"
  @spec restricted?(WikiPage.t() | map()) :: boolean()
  def restricted?(%{frontmatter: %{} = frontmatter}),
    do: not is_nil(Map.get(frontmatter, @readers_key))

  def restricted?(_), do: false

  @doc "May `scope` read `page`? The in-memory twin of `restrict/2`."
  @spec readable?(WikiPage.t() | map(), Scope.t() | nil) :: boolean()
  def readable?(page, scope) do
    cond do
      not restricted?(page) -> true
      not applies?(scope) -> true
      true -> user_passes?(page, scope)
    end
  end

  defp user_passes?(%{frontmatter: frontmatter}, %Scope{actor: %{id: user_id}} = scope)
       when is_binary(user_id) do
    readers = frontmatter |> Map.get(@readers_key) |> List.wrap() |> Enum.map(&to_string/1)
    %{admin?: admin?, internal?: internal?} = standing(scope)

    (admin? and "admins" in readers) or
      (internal? and "subject" in readers and Map.get(frontmatter, @subject_key) == user_id)
  end

  defp user_passes?(_page, _scope), do: false

  defp standing(%Scope{actor: actor, org: %{id: org_id}}) when is_binary(org_id) do
    %{
      admin?: Tenancy.org_admin?(actor, org_id),
      internal?: Tenancy.internal_member?(actor, org_id)
    }
  end

  defp standing(_scope), do: %{admin?: false, internal?: false}
end
