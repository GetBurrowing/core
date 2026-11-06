defmodule Platform.People.LegacyIndex do
  @moduledoc """
  Reads a people index (hand-written legacy or generated) back into rows, and
  derives the frontmatter a person card is missing from its own body and its
  index row. Pure: no database, no writes.

  ## `parse/1`

  Walks the index body. A `## <heading>` sets the current relation when the
  heading matches one of `Platform.People.Pages.relation_titles/0` by title
  or key, case-insensitively (`## Clients`, `## client`); any other heading
  (e.g. `## Contacts`) sets `"unknown"`. Rows before any heading are
  `"unknown"` too.

  Each markdown table is read by its header row. ONE data row is ONE person:

    * the Person column (header matching `person` or `name`, else the first
      column) gives the bold name (`**...**`) and, when present, the
      `[[org/page/people/<slug>.md]]` link; a row with no bold name is skipped;
    * `role` comes ONLY from a column whose header matches `~r/role/i`;
    * `last_seen` comes ONLY from a column whose header matches `~r/last seen/i`.

  No other column (phone, email, notes) is ever read, and free text outside
  tables is never carried.

  ## `derive_frontmatter/3`

  Returns ONLY the keys to add to a card. Precedence: existing frontmatter >
  card body > index row. A value that cannot be sourced is omitted, so an
  unknown relation stays unknown.
  """

  alias Platform.Org.Wiki
  alias Platform.People.Pages

  @type row :: %{
          name: String.t(),
          path: String.t() | nil,
          relation: String.t(),
          role: String.t() | nil,
          last_seen: String.t() | nil
        }

  @bold_re ~r/\*\*(?<name>[^*\n]+)\*\*/u
  @link_re ~r/\[\[(?<path>org\/page\/people\/[^\/\]|]+\.md)(?:\|[^\]]*)?\]\]/u
  @separator_re ~r/\A\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\z/
  @heading_re ~r/\A##\s+(?<title>.+?)\s*#*\s*\z/u
  @person_header_re ~r/\A(person|name)/i
  @role_header_re ~r/role/i
  @last_seen_header_re ~r/last seen/i

  @derived_keys ~w(name relation role last_seen)

  @doc "Index markdown (frontmatter allowed) to one row per person."
  @spec parse(String.t() | nil) :: [row()]
  def parse(markdown) when is_binary(markdown) do
    {_frontmatter, body} = Wiki.parse_frontmatter(markdown)

    body
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce(%{relation: "unknown", header: nil, rows: []}, &step/2)
    |> Map.fetch!(:rows)
    |> Enum.reverse()
  end

  def parse(_), do: []

  @doc """
  The frontmatter keys (`name`, `relation`, `role`, `last_seen`) to ADD to a
  card, given its body, its existing frontmatter and its index row (or `nil`).
  """
  @spec derive_frontmatter(String.t() | nil, map() | nil, row() | nil) :: %{
          optional(String.t()) => String.t()
        }
  def derive_frontmatter(card_body, existing_frontmatter, index_row) do
    body = if is_binary(card_body), do: card_body, else: ""
    existing = if is_map(existing_frontmatter), do: existing_frontmatter, else: %{}
    row = index_row || %{}

    candidates = %{
      "name" => first_present([Pages.h1(body), Map.get(row, :name)]),
      "relation" => row_relation(row),
      "role" => first_present([section_line(body, "role", true), Map.get(row, :role)]),
      "last_seen" =>
        first_present([section_line(body, "last seen", false), Map.get(row, :last_seen)])
    }

    for key <- @derived_keys,
        not present?(Map.get(existing, key)),
        value = Map.get(candidates, key),
        present?(value),
        into: %{},
        do: {key, value}
  end

  # -- parse internals --------------------------------------------------------

  defp step(line, acc) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "|") ->
        table_line(trimmed, acc)

      match = Regex.named_captures(@heading_re, trimmed) ->
        %{acc | relation: relation_for(match["title"]), header: nil}

      true ->
        %{acc | header: nil}
    end
  end

  defp table_line(line, %{header: nil} = acc) do
    %{acc | header: header(cells(line))}
  end

  defp table_line(line, acc) do
    if Regex.match?(@separator_re, line) do
      acc
    else
      case row(cells(line), acc.header, acc.relation) do
        nil -> acc
        row -> %{acc | rows: [row | acc.rows]}
      end
    end
  end

  defp header(cells) do
    person = Enum.find_index(cells, &Regex.match?(@person_header_re, &1)) || 0

    %{
      person: person,
      role: Enum.find_index(cells, &Regex.match?(@role_header_re, &1)),
      last_seen: Enum.find_index(cells, &Regex.match?(@last_seen_header_re, &1))
    }
  end

  defp row(cells, header, relation) do
    person = Enum.at(cells, header.person, "")

    case Regex.named_captures(@bold_re, person) do
      %{"name" => name} ->
        name = String.trim(name)

        if name == "" do
          nil
        else
          %{
            name: name,
            path: link_path(person),
            relation: relation,
            role: column(cells, header.role),
            last_seen: column(cells, header.last_seen)
          }
        end

      nil ->
        nil
    end
  end

  defp link_path(cell) do
    case Regex.named_captures(@link_re, cell) do
      %{"path" => path} -> path
      nil -> nil
    end
  end

  defp column(_cells, nil), do: nil

  defp column(cells, index) do
    case cells |> Enum.at(index) do
      nil -> nil
      value -> blank_to_nil(value)
    end
  end

  # Split a table row on unescaped pipes; `\|` inside a cell is unescaped.
  defp cells(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> trim_trailing_pipe()
    |> then(&Regex.split(~r/(?<!\\)\|/, &1))
    |> Enum.map(&(&1 |> String.replace("\\|", "|") |> String.trim()))
  end

  defp trim_trailing_pipe(text) do
    if String.ends_with?(text, "|") and not String.ends_with?(text, "\\|"),
      do: binary_part(text, 0, byte_size(text) - 1),
      else: text
  end

  defp relation_for(title) do
    wanted = title |> String.trim() |> String.downcase()

    Enum.find_value(Pages.relation_titles(), "unknown", fn {key, label} ->
      if wanted == key or wanted == String.downcase(label), do: key
    end)
  end

  # -- derive internals -------------------------------------------------------

  defp row_relation(row) do
    case Map.get(row, :relation) do
      relation when is_binary(relation) and relation != "unknown" -> relation
      _ -> nil
    end
  end

  # First non-blank line of the `## <title>` section (case-insensitive);
  # `strip_bullet?` drops a leading "- ".
  defp section_line(body, title, strip_bullet?) do
    body
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.drop_while(&(not section_heading?(&1, title)))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "#")))
    |> Enum.find(&(&1 != ""))
    |> case do
      nil ->
        nil

      line ->
        line = if strip_bullet?, do: Regex.replace(~r/\A-\s+/, line, ""), else: line
        blank_to_nil(line)
    end
  end

  defp section_heading?(line, title) do
    case Regex.named_captures(@heading_re, line) do
      %{"title" => found} -> String.downcase(String.trim(found)) == title
      nil -> false
    end
  end

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_other), do: true

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
