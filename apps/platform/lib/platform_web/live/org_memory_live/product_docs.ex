defmodule PlatformWeb.OrgMemoryLive.ProductDocs do
  @moduledoc """
  The Burrow Docs presentation layer of the Org Memory wiki (task 01a10a44
  stage 5).

  Burrow Docs are the product-owned `burrow/page/*` wiki rows that
  `Platform.Org.BurrowDocs` mirrors from the repo's `docs/burrow` on every
  boot. They are read-only in every surface (the domain backstop lives in
  `Platform.Org.Wiki`), so the wiki renders them as their own section:
  shown by frontmatter title in product `order`, never by filename or
  version, and marked with one signature element, the cyan spine.

  Design source: Saru's canvas "Burrow Docs in the wiki"
  (01a10a46-8fe5-7001-b652-8409c27f77c7). Copy and tokens are ported from it:

    * `--color-primary` is used ONLY as the spine fill.
    * `--color-interactive` carries the links (index rows, the selected leaf,
      the last path-chip segment). Cyan is never text.
    * `--color-base-200` is the ground of the tree section and the
      provenance strip.
    * The sha and notes are base-content at 60% or more, never /40.

  This module owns the pure helpers (splitting the page list, reading the
  frontmatter into entries, the set sha) and the function components the
  desktop panes and `MobileShell` share, so the copy exists once.
  """

  use Phoenix.Component

  alias Platform.Org.Wiki

  @index_key "burrow/page/index.md"

  @typedoc """
  One Burrow Docs page as the UI reads it. `index?` marks
  `burrow/page/index.md`, which renders as the Overview.
  """
  @type entry :: %{
          file_key: String.t(),
          title: String.t(),
          summary: String.t() | nil,
          order: integer() | nil,
          verified_at: String.t() | nil,
          index?: boolean()
        }

  # ── Pure helpers ────────────────────────────────────────────────────────

  @doc "The file_key of the Overview page."
  @spec index_key() :: String.t()
  def index_key, do: @index_key

  @doc """
  True for a page (or file_key) in the product-owned `burrow/` namespace.
  Delegates to `Platform.Org.Wiki.product_owned_key?/1`, the one predicate
  the domain backstop also uses.
  """
  @spec product_owned?(term()) :: boolean()
  def product_owned?(%{file_key: file_key}), do: Wiki.product_owned_key?(file_key)
  def product_owned?(file_key) when is_binary(file_key), do: Wiki.product_owned_key?(file_key)
  def product_owned?(_), do: false

  @doc """
  Splits the wiki page list into `{product_pages, org_pages}`. Every
  `burrow/` key goes to the first list, so it never appears in the Pages
  tree.
  """
  @spec split([struct()]) :: {[struct()], [struct()]}
  def split(pages) when is_list(pages), do: Enum.split_with(pages, &product_owned?/1)

  @doc """
  Entries for the product pages, in product order: the Overview first, then
  each topic by frontmatter `order` (a missing order sorts last), then title.
  """
  @spec entries([struct()]) :: [entry()]
  def entries(pages) when is_list(pages) do
    pages
    |> Enum.filter(&product_owned?/1)
    |> Enum.map(&entry/1)
    |> Enum.sort_by(fn e -> {not e.index?, e.order || :infinity, e.title} end)
  end

  @doc "The entry for one product page, read from its stored frontmatter."
  @spec entry(struct()) :: entry()
  def entry(%{file_key: file_key} = page) do
    fm = frontmatter(page)

    %{
      file_key: file_key,
      title: string_or_nil(fm["title"]) || basename_title(file_key),
      summary: string_or_nil(fm["summary"]),
      order: integer_or_nil(fm["order"]),
      verified_at: string_or_nil(fm["verified_at"]),
      index?: file_key == @index_key
    }
  end

  @doc "The entry for a page or file_key, or nil when it is not a product page."
  @spec find([entry()], term()) :: entry() | nil
  def find(entries, %{file_key: file_key}), do: find(entries, file_key)

  def find(entries, file_key) when is_list(entries) and is_binary(file_key),
    do: Enum.find(entries, &(&1.file_key == file_key))

  def find(_entries, _), do: nil

  @doc "The topics (every entry but the Overview), in product order."
  @spec topics([entry()]) :: [entry()]
  def topics(entries), do: Enum.reject(entries, & &1.index?)

  @doc """
  The tree and path-chip label: the Overview page reads "Overview", every
  topic its title.
  """
  @spec label(entry()) :: String.t()
  def label(%{index?: true}), do: "Overview"
  def label(%{title: title}), do: title

  @doc """
  The sha the set of topics was verified at: the most common `verified_at`
  among the topics, ties broken by the earliest topic in product order. The
  Overview names it once; a row adds its own sha only when it differs.
  """
  @spec set_sha([entry()]) :: String.t() | nil
  def set_sha(entries) do
    shas = entries |> topics() |> Enum.map(& &1.verified_at) |> Enum.reject(&is_nil/1)

    case shas do
      [] ->
        nil

      _ ->
        freq = Enum.frequencies(shas)
        top = freq |> Map.values() |> Enum.max()
        Enum.find(shas, &(freq[&1] == top))
    end
  end

  @doc """
  The page content as the viewer renders it. The page header already shows
  the frontmatter title, so a body whose first heading repeats that title
  drops it, rather than printing the title twice. Everything else renders
  unchanged.
  """
  @spec display_content(String.t(), String.t() | nil) :: String.t()
  def display_content(content, title) when is_binary(content) and is_binary(title) do
    {_fm, body} = Wiki.parse_frontmatter(content)
    heading = "# " <> title

    case String.split(String.trim_leading(body), "\n", parts: 2) do
      [^heading, rest] -> rest
      [^heading] -> ""
      _ -> body
    end
  end

  def display_content(content, _title) when is_binary(content) do
    {_fm, body} = Wiki.parse_frontmatter(content)
    body
  end

  def display_content(_content, _title), do: ""

  @doc """
  A search snippet for a product page hit: the hit content with its
  frontmatter, repeated title heading and heading markers removed, so the
  snippet starts at the prose.
  """
  @spec snippet_text(term(), String.t() | nil) :: String.t()
  def snippet_text(content, title) when is_binary(content) do
    content
    |> display_content(title)
    |> String.replace(~r/^\#{1,6}\s+/m, "")
    |> String.trim()
  end

  def snippet_text(_content, _title), do: ""

  defp frontmatter(%{frontmatter: fm}) when is_map(fm) and map_size(fm) > 0, do: fm

  defp frontmatter(%{content: content}) when is_binary(content) do
    {fm, _body} = Wiki.parse_frontmatter(content)
    fm
  end

  defp frontmatter(_), do: %{}

  defp basename_title(file_key) do
    file_key |> String.split("/") |> List.last() |> String.replace_suffix(".md", "")
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp string_or_nil(_), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp integer_or_nil(_), do: nil

  # ── Components ──────────────────────────────────────────────────────────

  attr(:class, :any, default: nil)

  @doc """
  The signature element: a 4px `--color-primary` bar with
  `--radius-selector` ends. Decoration only (it is 1.79:1 on white); the
  meaning is always also carried by text next to it.
  """
  def spine(assigns) do
    ~H"""
    <span
      class={["w-1 shrink-0 self-stretch rounded-[var(--radius-selector)] bg-primary", @class]}
      data-role="burrow-spine"
      aria-hidden="true"
    >
    </span>
    """
  end

  attr(:sha, :string, default: nil)

  @doc """
  The provenance strip under a product page's title, on the base-200 ground.
  Two lines at every width: the statement, then the sha and the repo note.
  The sha never wraps mid-token. Below `lg` the repo note shortens to
  "Product repo" (the canvas's mobile copy) so the second line fits 375px.
  "Maintained in the product repo" is plain text: there is no
  repo-reachability check to make it a link.
  """
  def provenance_strip(assigns) do
    ~H"""
    <div class="bg-base-200 px-4 py-2 text-xs lg:px-6" data-role="burrow-provenance">
      <p class="text-base-content">Product documentation. Updated with each release.</p>
      <p class="mt-0.5 flex flex-wrap items-baseline gap-x-1.5 text-subtle">
        <span :if={@sha} class="whitespace-nowrap" data-role="burrow-verified">
          Last verified at <span class="font-mono text-xs">{@sha}</span>
        </span>
        <span :if={@sha} aria-hidden="true">·</span>
        <span class="hidden whitespace-nowrap lg:inline">Maintained in the product repo</span>
        <span class="whitespace-nowrap lg:hidden">Product repo</span>
      </p>
    </div>
    """
  end

  attr(:entries, :list, required: true)

  @doc """
  `burrow/page/index.md` rendered as the Overview: an intro, the set sha
  once, then one full-row link per topic in product order. A row names its
  own sha only when it differs from the set's.
  """
  def overview(assigns) do
    assigns =
      assigns
      |> assign(:topics, topics(assigns.entries))
      |> assign(:set_sha, set_sha(assigns.entries))

    ~H"""
    <div class="flex flex-col" data-role="burrow-overview">
      <div class="flex border-b border-edge">
        <.spine />
        <div class="min-w-0 flex-1 px-4 py-3 lg:px-6">
          <h1 class="text-lg font-bold" data-role="burrow-page-title">Burrow Docs</h1>
          <p class="mt-1 text-sm text-base-content">
            How each part of the product works. Your org's own notes live under Pages.
          </p>
          <p :if={@set_sha} class="mt-1 text-xs text-subtle" data-role="burrow-set-sha">
            All topics verified at <span class="whitespace-nowrap font-mono text-xs">{@set_sha}</span>
          </p>
        </div>
      </div>

      <ul class="divide-y divide-edge">
        <li :for={topic <- @topics}>
          <button
            type="button"
            phx-click="select_page"
            phx-value-file_key={topic.file_key}
            data-burrow-topic={topic.file_key}
            class="flex min-h-14 w-full flex-col justify-center gap-0.5 px-4 py-2 text-left transition-colors hover:bg-base-200 lg:px-6"
          >
            <span class="flex w-full items-baseline gap-2">
              <span class="min-w-0 flex-1 text-sm font-medium text-[var(--color-interactive)]">
                {topic.title}
              </span>
              <span
                :if={topic.verified_at && topic.verified_at != @set_sha}
                class="shrink-0 whitespace-nowrap text-xs text-subtle"
                data-role="burrow-row-sha"
              >
                verified <span class="font-mono">{topic.verified_at}</span>
              </span>
            </span>
            <span :if={topic.summary} class="text-sm text-base-content">{topic.summary}</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end
end
