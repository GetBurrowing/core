defmodule Platform.People do
  @moduledoc """
  Read API over the two people-page tiers.

  Every reader takes an `access_scope` (`%Platform.Access.Scope{}`, `nil`
  for an unscoped internal caller) and answers card data for everyone. The
  private tier is included only when `Platform.Org.Wiki.get_page/2` with
  that scope returns the private page — the generic `readers:` rule
  (`Platform.Org.Wiki.Readers`, stage 2) decides, and this module adds no
  second rule of its own.

    * `who_is/2` — the card (role, organisation, relation, current projects,
      agents) plus the private interactions and perspectives when visible;
    * `worked_on/2` — current projects from the card, plus the private
      interactions when visible;
    * `cares_about/2` — the perspectives on the private page, or `[]`.

  `who_is/2` accepts a slug or a free-text name; the name is resolved against
  the roster with `Platform.People.Identity.resolve/3`.
  """

  alias Platform.Org.Wiki
  alias Platform.People.{Identity, Pages, Visibility}

  @type scope :: Platform.Access.Scope.t() | nil

  @type profile :: %{
          slug: String.t(),
          name: String.t(),
          aliases: [String.t()],
          relation: String.t(),
          organisation: String.t() | nil,
          role: String.t() | nil,
          last_seen: String.t() | nil,
          role_notes: [String.t()],
          current_projects: [String.t()],
          agents: [String.t()],
          interactions: [String.t()] | nil,
          perspectives: [String.t()] | nil,
          private_visible?: boolean()
        }

  @doc "The profile for a slug or name, or `nil`; `{:ambiguous, slugs}` for an ambiguous name."
  @spec who_is(String.t(), scope(), keyword()) :: profile() | {:ambiguous, [String.t()]} | nil
  def who_is(slug_or_name, scope, opts \\ []) when is_binary(slug_or_name) do
    workspace_id = Keyword.get(opts, :workspace_id)
    roster = Pages.roster(workspace_id)

    case find_card(slug_or_name, roster, opts) do
      {:ok, card} -> profile(card, scope, workspace_id)
      {:ambiguous, slugs} -> {:ambiguous, slugs}
      :none -> nil
    end
  end

  @doc "Current projects (card) and, when the private page is visible, interactions."
  @spec worked_on(String.t(), scope(), keyword()) ::
          %{projects: [String.t()], interactions: [String.t()]} | nil
  def worked_on(slug, scope, opts \\ []) when is_binary(slug) do
    case who_is(slug, scope, opts) do
      %{} = profile ->
        %{projects: profile.current_projects, interactions: profile.interactions || []}

      _ ->
        nil
    end
  end

  @doc "Perspectives in the subject's own words — only when the private page is visible to `scope`."
  @spec cares_about(String.t(), scope(), keyword()) :: [String.t()]
  def cares_about(slug, scope, opts \\ []) when is_binary(slug) do
    case who_is(slug, scope, opts) do
      %{perspectives: perspectives} when is_list(perspectives) -> perspectives
      _ -> []
    end
  end

  # ── resolution ───────────────────────────────────────────────────────────

  defp find_card(slug_or_name, roster, opts) do
    case Enum.find(roster, &(&1.slug == slug_or_name)) do
      %{} = card ->
        {:ok, card}

      nil ->
        case Identity.resolve(slug_or_name, roster, Keyword.take(opts, [:threshold])) do
          {:match, slug} -> {:ok, Enum.find(roster, &(&1.slug == slug))}
          {:ambiguous, slugs} -> {:ambiguous, slugs}
          :unknown -> :none
        end
    end
  end

  # ── assembly ─────────────────────────────────────────────────────────────

  defp profile(card, scope, workspace_id) do
    card_sections =
      sections(Wiki.get_page(card.path, workspace_id: workspace_id, access_scope: scope))

    private_page =
      Wiki.get_page(Visibility.private_path(card.slug),
        workspace_id: workspace_id,
        access_scope: scope
      )

    private_sections = if private_page, do: sections(private_page), else: nil

    %{
      slug: card.slug,
      name: card.name,
      aliases: card.aliases,
      relation: card.relation,
      organisation: card.organisation,
      role: card.role,
      last_seen: card.last_seen,
      role_notes: Map.get(card_sections, "role", []),
      current_projects: Map.get(card_sections, "current projects", []),
      agents: Map.get(card_sections, "agents", []),
      interactions: private_sections && Map.get(private_sections, "interactions", []),
      perspectives: private_sections && Map.get(private_sections, "perspectives", []),
      private_visible?: not is_nil(private_page)
    }
  end

  # `## Heading` → non-blank lines under it, bullets stripped of their dash.
  defp sections(nil), do: %{}

  defp sections(%{content: content}) do
    {_frontmatter, body} = Wiki.parse_frontmatter(content || "")

    body
    |> String.split("\n")
    |> Enum.reduce({nil, %{}}, fn line, {current, acc} ->
      case Regex.run(~r/\A##\s+(.+?)\s*\z/u, line) do
        [_, heading] ->
          {heading |> String.trim() |> String.downcase(),
           Map.put_new(acc, String.downcase(String.trim(heading)), [])}

        nil ->
          text = line |> String.trim() |> String.replace(~r/\A[-*]\s+/u, "")

          if is_nil(current) or text == "" do
            {current, acc}
          else
            {current, Map.update(acc, current, [text], &(&1 ++ [text]))}
          end
      end
    end)
    |> elem(1)
  end
end
