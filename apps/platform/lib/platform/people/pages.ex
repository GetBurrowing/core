defmodule Platform.People.Pages do
  @moduledoc """
  Reads and writes the two people-page tiers through `Platform.Org.Wiki`.

    * `roster/1` — the person cards (tier `card` or absent) under
      `org/page/people/`, parsed into roster entries; an absent `tier:` is a
      legacy card (`legacy: true`).
    * `index_names/1` — the bold names and `[[org/page/people/<slug>.md]]`
      links in the current index, for reconciling a legacy index.
    * `write_card/4` / `write_private/4` — `Platform.People.PageGuard.enforce/2`
      then `Wiki.upsert_page/3`; the private tier gets
      `Platform.People.Visibility.private_frontmatter/1` first.
    * `regenerate_index/2` — rebuilds `org/page/people/index.md` from the
      cards ONLY, grouped by relation, never carrying free text from the old
      index; idempotent.

  Every successful write emits `[:platform, :people, :page_written]` with
  `%{paths: [path]}` in the metadata.
  """

  alias Platform.Org.Wiki
  alias Platform.People.{PageGuard, Visibility}

  @relations ~w(team client prospect investor collaborator former unknown)
  @relation_titles %{
    "team" => "Team",
    "client" => "Clients",
    "prospect" => "Prospects",
    "investor" => "Investors",
    "collaborator" => "Collaborators",
    "former" => "Former",
    "unknown" => "Unknown relation"
  }
  @index_footer "_Generated from the person cards by HR; edit the card, not this index._"
  @bold_re ~r/\*\*(?<name>[^*\n]+)\*\*/u
  @link_re ~r/\[\[(?<path>org\/page\/people\/[^\/\]|]+\.md)(?:\|[^\]]*)?\]\]/u

  @type roster_entry :: %{
          slug: String.t(),
          path: String.t(),
          name: String.t(),
          aliases: [String.t()],
          user_id: String.t() | nil,
          relation: String.t(),
          organisation: String.t() | nil,
          role: String.t() | nil,
          last_seen: String.t() | nil,
          updated_at: DateTime.t() | nil,
          legacy: boolean()
        }

  @doc """
  The relation keys in index order mapped to their index section titles
  (`"client" => "Clients"`, ..., `"unknown" => "Unknown relation"`).
  """
  @spec relation_titles() :: [{String.t(), String.t()}]
  def relation_titles, do: Enum.map(@relations, &{&1, Map.fetch!(@relation_titles, &1)})

  @doc "The person cards under the people prefix. Private pages and the index are skipped."
  @spec roster(binary() | nil) :: [roster_entry()]
  def roster(workspace_id) do
    Visibility.prefix()
    |> Wiki.list_pages_under(workspace_id: workspace_id)
    |> Enum.filter(&(Visibility.tier_of(&1.file_key) == :card))
    |> Enum.flat_map(fn page ->
      {frontmatter, body} = Wiki.parse_frontmatter(page.content || "")

      case Map.get(frontmatter, "tier") do
        nil -> [entry(page, frontmatter, body, true)]
        "card" -> [entry(page, frontmatter, body, false)]
        _other_tier -> []
      end
    end)
  end

  @doc "Bold names and `[[org/page/people/<slug>.md]]` links in the current index."
  @spec index_names(binary() | nil) :: %{names: [String.t()], paths: [String.t()]}
  def index_names(workspace_id) do
    case Wiki.get_page(Visibility.index_path(), workspace_id: workspace_id) do
      nil ->
        %{names: [], paths: []}

      %{content: content} ->
        {_frontmatter, body} = Wiki.parse_frontmatter(content || "")

        %{
          names: captures(@bold_re, body),
          paths: captures(@link_re, body)
        }
    end
  end

  @doc "Guard then upsert the card for `slug`."
  @spec write_card(binary() | nil, String.t(), String.t(), String.t() | nil) ::
          {:ok, Platform.Org.WikiPage.t(), PageGuard.counts()} | {:error, term()}
  def write_card(workspace_id, slug, markdown, updated_by)
      when is_binary(slug) and is_binary(markdown) do
    {content, counts} = PageGuard.enforce(:card, markdown)
    write(workspace_id, Visibility.card_path(slug), content, updated_by, counts)
  end

  @doc """
  Guard then upsert the private page for `slug`. The `readers:` and
  `subject_user_id` keys come from `Visibility.private_frontmatter/1` over
  the page's own `user_id:`; whatever the caller wrote for them is replaced.
  """
  @spec write_private(binary() | nil, String.t(), String.t(), String.t() | nil) ::
          {:ok, Platform.Org.WikiPage.t(), PageGuard.counts()} | {:error, term()}
  def write_private(workspace_id, slug, markdown, updated_by)
      when is_binary(slug) and is_binary(markdown) do
    {content, counts} = PageGuard.enforce(:private, with_private_keys(markdown))
    write(workspace_id, Visibility.private_path(slug), content, updated_by, counts)
  end

  @doc """
  Rebuild the index from the cards. Returns `{:ok, :unchanged}` when the
  rendered index equals the stored one, so a second run writes nothing.
  """
  @spec regenerate_index(binary() | nil, String.t() | nil) ::
          {:ok, Platform.Org.WikiPage.t()} | {:ok, :unchanged} | {:error, term()}
  def regenerate_index(workspace_id, updated_by) do
    content = render_index(roster(workspace_id))
    path = Visibility.index_path()

    current =
      case Wiki.get_page(path, workspace_id: workspace_id) do
        nil -> nil
        %{content: existing} -> existing
      end

    if current == content do
      {:ok, :unchanged}
    else
      case write(workspace_id, path, content, updated_by, %{}) do
        {:ok, page, _counts} -> {:ok, page}
        {:error, _} = err -> err
      end
    end
  end

  @doc false
  def render_index(cards) do
    groups = Enum.group_by(cards, &relation_of/1)

    sections =
      for relation <- @relations, members = Map.get(groups, relation, []), members != [] do
        rows =
          members
          |> Enum.sort_by(&String.downcase(&1.name))
          |> Enum.map(fn card ->
            "| **#{cell(card.name)}** [[#{card.path}]] | #{cell(role_org(card))} | #{cell(card.last_seen)} |"
          end)

        [
          "## #{Map.fetch!(@relation_titles, relation)}",
          "",
          "| Person | Role / organisation | Last seen |",
          "| --- | --- | --- |"
        ] ++ rows ++ [""]
      end

    body =
      case sections do
        [] -> ["_No person cards yet._", ""]
        sections -> List.flatten(sections)
      end

    (["---", "tier: index", "---", "", "# People", ""] ++ body ++ [@index_footer])
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # -- internals --------------------------------------------------------------

  defp write(workspace_id, path, content, updated_by, counts) do
    attrs = %{content: content, updated_by: updated_by}

    case Wiki.upsert_page(path, attrs, workspace_id: workspace_id) do
      {:ok, page} ->
        :telemetry.execute(
          [:platform, :people, :page_written],
          %{count: 1, system_time: System.system_time()},
          %{paths: [path], workspace_id: workspace_id, updated_by: updated_by}
        )

        {:ok, page, counts}

      {:error, _} = err ->
        err
    end
  end

  defp with_private_keys(markdown) do
    lines = markdown |> String.replace("\r\n", "\n") |> String.split("\n")

    case lines do
      ["---" | rest] ->
        case Enum.split_while(rest, &(String.trim(&1) != "---")) do
          {frontmatter, ["---" | body]} ->
            user_id = frontmatter_value(frontmatter, "user_id")

            kept =
              Enum.reject(frontmatter, fn line ->
                key?(line, "readers") or key?(line, "subject_user_id")
              end)

            Enum.join(["---"] ++ kept ++ private_lines(user_id) ++ ["---"] ++ body, "\n")

          _unterminated ->
            Enum.join(["---"] ++ private_lines(nil) ++ ["---", "" | lines], "\n")
        end

      _ ->
        Enum.join(["---"] ++ private_lines(nil) ++ ["---", "" | lines], "\n")
    end
  end

  defp private_lines(user_id) do
    fm = Visibility.private_frontmatter(user_id)
    readers = "readers: [" <> Enum.join(Map.fetch!(fm, "readers"), ", ") <> "]"

    case Map.get(fm, "subject_user_id") do
      nil -> [readers]
      id -> [readers, "subject_user_id: #{id}"]
    end
  end

  defp frontmatter_value(lines, key) do
    case Enum.find(lines, &key?(&1, key)) do
      nil ->
        nil

      line ->
        value = line |> String.split(":", parts: 2) |> Enum.at(1, "") |> String.trim()
        if value == "", do: nil, else: value
    end
  end

  defp key?(line, key), do: String.starts_with?(String.trim_leading(line), key <> ":")

  defp entry(page, frontmatter, body, legacy?) do
    slug = Visibility.slug_of(page.file_key)

    %{
      slug: slug,
      path: page.file_key,
      name: display_name(frontmatter, body, slug),
      aliases: aliases(Map.get(frontmatter, "aliases")),
      user_id: string_or(Map.get(frontmatter, "user_id"), nil),
      relation: relation_of(%{relation: Map.get(frontmatter, "relation")}),
      organisation: string_or(Map.get(frontmatter, "organisation"), nil),
      role: string_or(Map.get(frontmatter, "role"), nil),
      last_seen: string_or(Map.get(frontmatter, "last_seen"), nil),
      updated_at: page.updated_at,
      legacy: legacy?
    }
  end

  defp relation_of(%{relation: relation}) when is_binary(relation) do
    key = relation |> String.trim() |> String.downcase()
    if key in @relations, do: key, else: "unknown"
  end

  defp relation_of(_), do: "unknown"

  defp aliases(nil), do: []

  defp aliases(list) when is_list(list),
    do: list |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1)

  defp aliases(text) when is_binary(text),
    do: text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp aliases(other), do: [to_string(other)]

  defp string_or(nil, default), do: default
  defp string_or("", default), do: default
  defp string_or(value, _default) when is_binary(value), do: value
  defp string_or(%Date{} = date, _default), do: Date.to_iso8601(date)
  defp string_or(value, _default), do: to_string(value)

  # The displayed name keeps the case the card was written in: a non-blank
  # `name:` key, else the card's `# ` H1 (legacy cards carry no `name:`),
  # else the humanized slug. Never downcased; sorting downcases on its own.
  defp display_name(frontmatter, body, slug) do
    case Map.get(frontmatter, "name") do
      name when is_binary(name) ->
        if String.trim(name) == "",
          do: h1(body) || humanize(slug),
          else: String.trim(name)

      nil ->
        h1(body) || humanize(slug)

      other ->
        string_or(other, humanize(slug))
    end
  end

  @h1_re ~r/\A#\s+(.+?)\s*\z/

  @doc """
  The card body's `# ` H1 text, or `nil`. Only lines before the first `##`
  heading are considered.
  """
  @spec h1(String.t() | nil) :: String.t() | nil
  def h1(body) when is_binary(body) do
    body
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce_while(nil, fn line, nil ->
      line = String.trim(line)

      cond do
        String.starts_with?(line, "##") -> {:halt, nil}
        match = Regex.run(@h1_re, line, capture: :all_but_first) -> {:halt, hd(match)}
        true -> {:cont, nil}
      end
    end)
  end

  def h1(_body), do: nil

  defp humanize(nil), do: "Unknown"
  defp humanize(slug), do: slug |> String.replace(["-", "_"], " ") |> String.trim()

  defp role_org(card) do
    [card.role, card.organisation]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end

  defp cell(nil), do: ""
  defp cell(text), do: text |> to_string() |> String.replace("|", "\\|") |> String.trim()

  defp captures(regex, text) do
    regex
    |> Regex.scan(text, capture: :all_names)
    |> Enum.map(fn [value] -> String.trim(value) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
