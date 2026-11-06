defmodule Mix.Tasks.Platform.HrBackfill do
  @moduledoc """
  Brings legacy people pages into line with the two-tier grammar
  (task 01a1aa47 stage 5).

  A legacy card is an `org/page/people/<slug>.md` page with no `tier:` in
  its frontmatter — written before `Platform.People.PageGuard` existed. The
  task:

    1. prints every legacy card and every name that appears only in the
       index (bold or linked there, but with no card);
    2. runs `Platform.People.PageGuard.enforce(:card, body)` over each legacy
       card and writes the result back through `Platform.People.Pages.write_card/4`,
       so the page gains `tier: card`, loses any `## Perspectives` /
       `## Interactions` section and any trait-language line, and has contact
       details scrubbed;
    3. enriches EVERY card under the people prefix (legacy or already
       `tier: card`) that is missing `name:`, `relation:`, `role:` or
       `last_seen:` frontmatter, deriving the missing keys with
       `Platform.People.LegacyIndex.derive_frontmatter/3` from the card's own
       body (`# ` H1, `## Role`, `## Last seen`) and its row in the previous
       index (see below); existing keys and the body are left alone and the
       card is written back through `Platform.People.Pages.write_card/4`;
    4. regenerates `org/page/people/index.md` from the cards only, which drops
       the free-text `## Contacts` row the legacy index carried;
    5. appends one org journal line listing what was rewritten and enriched.

  No LLM is involved and nothing is deleted: a legacy card is rewritten in
  place, the index is re-rendered, and index-only names are reported, not
  removed from anywhere but the generated index.

  ## The third-party phone number

  The legacy data carries a third party's phone number twice: in the free
  text of a card and in the `Contacts` table of the hand-written index. The
  enforce pass removes the first (`Platform.People.Privacy.scrub/1` runs
  last inside `PageGuard.enforce/2` and replaces it with
  `[REDACTED: phone]`); the index regeneration removes the second, because
  the index is rendered from the card frontmatter alone and never carries
  free text forward. Running the task once is enough; a second run finds no
  legacy card and leaves the index unchanged.

  ## The previous index

  The index renders relation, role and last-seen from card frontmatter only,
  and a legacy card carries those in body sections or nowhere. The
  hand-written index that preceded the first backfill grouped people by
  relation and listed roles, so it is the source for what the card body
  lacks. Core keeps no page-content history (`org_wiki_pages` stores only the
  current content and a version counter), so the backfill cannot fetch an
  earlier index version itself: the operator hands the saved markdown in
  with `--previous-index PATH` (or `previous_index:`). Without it the
  currently stored index is used, which only helps while it is still the
  hand-written one.

  From the index only the Person cell (bold name and card link), a column
  headed `Role...` and a column headed `Last seen` are read; a section
  heading that is not a relation (e.g. `## Contacts`) maps to an unknown
  relation, never a guess. Cards are matched to rows by link path, then by
  case-insensitive name.

  ## Usage

      mix platform.hr_backfill
      mix platform.hr_backfill --workspace-id <uuid>
      mix platform.hr_backfill --dry-run
      mix platform.hr_backfill --previous-index /path/to/saved-index.md

  `--dry-run` prints the report and writes nothing.

  ## In production

  Releases have no Mix. Call the task's entry point directly:

      podman exec core-platform /app/bin/platform rpc \\
        "Mix.Tasks.Platform.HrBackfill.backfill(workspace_id: nil) |> inspect() |> IO.puts()"

  With a saved copy of the previous index (copy the file into the container
  first):

      Mix.Tasks.Platform.HrBackfill.backfill(previous_index: File.read!("/path/to/saved-index.md"))
  """

  use Mix.Task

  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.People.{LegacyIndex, Pages, Visibility}

  @shortdoc "Rewrite legacy people cards through the page guard and regenerate the index"

  @journal_source "people:hr_backfill"

  @type report :: %{
          legacy_cards: [String.t()],
          index_only_names: [String.t()],
          rewritten: [%{path: String.t(), counts: map()}],
          enriched: [%{path: String.t(), added: [String.t()]}],
          index: :regenerated | :unchanged | :skipped | {:error, term()},
          dry_run: boolean()
        }

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [workspace_id: :string, dry_run: :boolean, previous_index: :string]
      )

    Mix.Task.run("app.start")

    previous_index =
      case opts[:previous_index] do
        nil -> nil
        path -> File.read!(path)
      end

    report =
      backfill(
        workspace_id: opts[:workspace_id],
        dry_run: opts[:dry_run] || false,
        previous_index: previous_index
      )

    shell = Mix.shell()
    Enum.each(lines(report), &shell.info/1)
  end

  @doc """
  The backfill itself, callable without Mix. Options: `:workspace_id`
  (default `nil`), `:updated_by` (default `nil`), `:dry_run` (default `false`),
  `:previous_index` (index markdown; default the currently stored index).
  """
  @spec backfill(keyword()) :: report()
  def backfill(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    updated_by = Keyword.get(opts, :updated_by)
    dry_run? = Keyword.get(opts, :dry_run, false)

    # Read before anything is written: the regeneration below overwrites it.
    index_rows =
      opts
      |> Keyword.get(:previous_index)
      |> Kernel.||(stored_index(workspace_id))
      |> LegacyIndex.parse()

    roster = Pages.roster(workspace_id)
    legacy = roster |> Enum.filter(& &1.legacy) |> Enum.sort_by(& &1.path)
    index_only = index_only_names(roster, Pages.index_names(workspace_id))

    base = %{
      legacy_cards: Enum.map(legacy, & &1.path),
      index_only_names: index_only,
      rewritten: [],
      enriched: [],
      index: :skipped,
      dry_run: dry_run?
    }

    if dry_run? do
      base
    else
      rewritten = Enum.flat_map(legacy, &rewrite_card(&1, workspace_id, updated_by))

      enriched =
        workspace_id
        |> Pages.roster()
        |> Enum.sort_by(& &1.path)
        |> Enum.flat_map(&enrich_card(&1, index_rows, workspace_id, updated_by))

      index =
        case Pages.regenerate_index(workspace_id, updated_by) do
          {:ok, :unchanged} -> :unchanged
          {:ok, _page} -> :regenerated
          {:error, _} = err -> err
        end

      report = %{base | rewritten: rewritten, enriched: enriched, index: index}
      journal(report, workspace_id, updated_by)
      report
    end
  end

  @doc false
  def lines(report) do
    legacy =
      case report.legacy_cards do
        [] -> ["Legacy cards: none"]
        paths -> ["Legacy cards (#{length(paths)}):" | Enum.map(paths, &"  #{&1}")]
      end

    index_only =
      case report.index_only_names do
        [] -> ["Index-only names: none"]
        names -> ["Index-only names (#{length(names)}):" | Enum.map(names, &"  #{&1}")]
      end

    rewritten =
      Enum.map(report.rewritten, fn %{path: path, counts: counts} ->
        "  rewrote #{path} #{inspect(counts)}"
      end)

    enriched =
      Enum.map(report.enriched, fn %{path: path, added: added} ->
        "  enriched #{path} +#{Enum.join(added, ", ")}"
      end)

    tail =
      if report.dry_run,
        do: ["Dry run: nothing written."],
        else:
          ["Rewritten: #{length(report.rewritten)}" | rewritten] ++
            ["Enriched: #{length(report.enriched)}" | enriched] ++
            ["Index: #{inspect(report.index)}"]

    legacy ++ index_only ++ tail
  end

  # -- internals --------------------------------------------------------------

  defp rewrite_card(%{slug: slug, path: path}, workspace_id, updated_by) do
    case Wiki.get_page(path, workspace_id: workspace_id) do
      %{content: content} when is_binary(content) ->
        case Pages.write_card(workspace_id, slug, content, updated_by) do
          {:ok, _page, counts} -> [%{path: path, counts: counts}]
          {:error, _} -> []
        end

      _ ->
        []
    end
  end

  defp stored_index(workspace_id) do
    case Wiki.get_page(Visibility.index_path(), workspace_id: workspace_id) do
      %{content: content} when is_binary(content) -> content
      _ -> ""
    end
  end

  defp enrich_card(%{slug: slug, path: path, name: name}, rows, workspace_id, updated_by) do
    with %{content: content} when is_binary(content) <-
           Wiki.get_page(path, workspace_id: workspace_id),
         {frontmatter, body} = Wiki.parse_frontmatter(content),
         row = index_row(rows, path, name),
         added when added != %{} <- LegacyIndex.derive_frontmatter(body, frontmatter, row),
         {:ok, _page, _counts} <-
           Pages.write_card(workspace_id, slug, add_frontmatter(content, added), updated_by) do
      [%{path: path, added: added |> Map.keys() |> Enum.sort()}]
    else
      _ -> []
    end
  end

  defp index_row(rows, path, name) do
    Enum.find(rows, &(&1.path == path)) ||
      Enum.find(rows, &(String.downcase(&1.name) == String.downcase(name || "")))
  end

  # Insert `added` as quoted YAML lines at the end of the frontmatter block
  # (creating one when the card has none); existing lines and the body are
  # kept byte for byte.
  defp add_frontmatter(content, added) do
    new_lines =
      added
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> "#{key}: #{yaml_string(value)}" end)

    lines = content |> String.replace("\r\n", "\n") |> String.split("\n")

    case lines do
      ["---" | rest] ->
        case Enum.split_while(rest, &(String.trim(&1) != "---")) do
          {frontmatter, ["---" | body]} ->
            Enum.join(["---"] ++ frontmatter ++ new_lines ++ ["---"] ++ body, "\n")

          _unterminated ->
            Enum.join(["---"] ++ new_lines ++ ["---", "" | lines], "\n")
        end

      _ ->
        Enum.join(["---"] ++ new_lines ++ ["---", "" | lines], "\n")
    end
  end

  defp yaml_string(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"" <> escaped <> "\""
  end

  defp index_only_names(roster, %{names: names, paths: paths}) do
    card_names = roster |> Enum.map(&String.downcase(&1.name)) |> MapSet.new()
    card_paths = roster |> Enum.map(& &1.path) |> MapSet.new()

    from_names = Enum.reject(names, &MapSet.member?(card_names, String.downcase(&1)))

    from_paths =
      paths
      |> Enum.reject(&MapSet.member?(card_paths, &1))
      |> Enum.map(&(Visibility.slug_of(&1) || &1))

    Enum.uniq(from_names ++ from_paths)
  end

  defp journal(%{rewritten: [], enriched: [], index: :unchanged}, _workspace_id, _updated_by),
    do: :ok

  defp journal(report, workspace_id, updated_by) do
    paths = Enum.map(report.rewritten, & &1.path)
    rewrote = if paths == [], do: "none", else: Enum.join(paths, ", ")

    index_only =
      if report.index_only_names == [],
        do: "none",
        else: Enum.join(report.index_only_names, ", ")

    enriched =
      if report.enriched == [],
        do: "none",
        else:
          Enum.map_join(report.enriched, ", ", fn %{path: path, added: added} ->
            "#{path} (+#{Enum.join(added, " ")})"
          end)

    attrs =
      %{
        content:
          "HR backfill: rewrote legacy cards #{rewrote}; enriched #{enriched}; index #{inspect(report.index)}; index-only names #{index_only}",
        date: Date.utc_today(),
        workspace_id: workspace_id,
        metadata: %{
          "source" => @journal_source,
          "rewritten" => paths,
          "enriched" => Enum.map(report.enriched, &%{"path" => &1.path, "added" => &1.added}),
          "index_only_names" => report.index_only_names
        }
      }

    attrs = if updated_by, do: Map.put(attrs, :authored_by, updated_by), else: attrs

    case Journal.append(attrs) do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  end
end
