defmodule Platform.Showrunner.Memory do
  @moduledoc """
  Memory path conventions for the How to Computer showrunner. Task 01a1eaf6
  stage 1.

  The showrunner keeps the show's long memory in the space's memory tree:

    * a daily journal, `space/<space_id>/journal/<YYYY-MM-DD>.md`, the shape
      `Platform.Memory.Insights.journal_path?/1` recognises;
    * four curated pages under `space/<space_id>/page/show/`: `episodes`,
      `guests`, `running-bits` and `clip-performance`.

  Page writes are Historian-only. The showrunner does not write a page: it
  writes `[show]`-tagged journal entries (`journal_entry/1`, appended by
  `append_journal/3`) and the Historian curates them into the pages. There is
  deliberately no bypass here.

  ## Episode lines (task 01a1eaf6 stage 3)

  A journal line that starts `[show] Episode <n>` is about episode `n`.
  `recent_episodes/2` reads the space's journal files newest first and groups
  those lines by episode number: it is how the weekly pitch sees the last
  four episodes without reading a curated page.
  """

  import Ecto.Query

  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.WikiPage
  alias Platform.Repo

  @pages [:episodes, :guests, :running_bits, :clip_performance]
  @tag "[show]"

  @typedoc "A curated show page."
  @type page :: :episodes | :guests | :running_bits | :clip_performance

  @doc "The journal path for `space_id` on `date` (a `Date` or a `DateTime`, taken in UTC)."
  @spec journal_path(String.t(), Date.t() | DateTime.t()) :: String.t()
  def journal_path(space_id, %DateTime{} = at),
    do: journal_path(space_id, at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date())

  def journal_path(space_id, %Date{} = date) when is_binary(space_id) and space_id != "",
    do: "space/#{space_id}/journal/#{Date.to_iso8601(date)}.md"

  @doc "Every curated page name, in order."
  @spec pages() :: [page()]
  def pages, do: @pages

  @doc "The curated page key for `page` in `space_id`."
  @spec page_path(String.t(), page()) :: String.t()
  def page_path(space_id, page) when is_binary(space_id) and space_id != "" and page in @pages,
    do: "space/#{space_id}/page/show/#{page_slug(page)}.md"

  @doc "Every curated page key for `space_id`, in `pages/0` order."
  @spec page_paths(String.t()) :: [String.t()]
  def page_paths(space_id), do: Enum.map(@pages, &page_path(space_id, &1))

  @doc "The tag every showrunner journal entry carries."
  @spec tag() :: String.t()
  def tag, do: @tag

  @doc "A `[show]`-tagged journal line. Leading/trailing whitespace is trimmed."
  @spec journal_entry(String.t()) :: String.t()
  def journal_entry(text) when is_binary(text), do: "#{@tag} #{String.trim(text)}"

  @doc "A `[show] Episode <n>` journal line about episode `number`."
  @spec episode_entry(pos_integer(), String.t()) :: String.t()
  def episode_entry(number, text) when is_integer(number) and number > 0 and is_binary(text),
    do: journal_entry("Episode #{number}: #{String.trim(text)}")

  @doc """
  Appends `[show]`-tagged `text` (one line) to the space's journal for the day
  of `at` (default now). Org-scoped, like every `space/<id>/journal/` file.
  Returns `{:ok, file_key}` or `{:error, reason}`; never raises.
  """
  @spec append_journal(String.t(), String.t(), DateTime.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def append_journal(space_id, text, at \\ nil) when is_binary(space_id) and is_binary(text) do
    key = journal_path(space_id, at || DateTime.utc_now())
    line = if String.starts_with?(text, @tag), do: String.trim(text), else: journal_entry(text)
    line = line |> String.replace(~r/\s*\n\s*/, " ") |> String.trim()

    content =
      case OrgContext.get_context_file(key) do
        %WikiPage{content: existing} when is_binary(existing) and existing != "" ->
          String.trim_trailing(existing) <> "\n" <> line <> "\n"

        _ ->
          line <> "\n"
      end

    case OrgContext.upsert_context_file(key, %{content: content}) do
      {:ok, _page} -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  end

  @doc """
  The last `limit` episodes the space's journal mentions, newest first, each
  `%{number: n, lines: [line]}` with its `[show] Episode <n>` lines in journal
  order. Reads at most the 90 newest journal files. Never raises: a read
  failure is `[]`.
  """
  @spec recent_episodes(String.t(), pos_integer()) :: [
          %{number: pos_integer(), lines: [String.t()]}
        ]
  def recent_episodes(space_id, limit \\ 4)
      when is_binary(space_id) and space_id != "" and is_integer(limit) and limit > 0 do
    prefix = "space/#{space_id}/journal/"

    from(p in WikiPage,
      where: is_nil(p.workspace_id) and like(p.file_key, ^(prefix <> "%")),
      order_by: [desc: p.file_key],
      limit: 90,
      select: {p.file_key, p.content}
    )
    |> Repo.all()
    |> Enum.filter(fn {key, _} -> Regex.match?(~r/\/journal\/\d{4}-\d{2}-\d{2}\.md$/, key) end)
    |> Enum.reverse()
    |> Enum.flat_map(fn {_key, content} -> String.split(content || "", "\n", trim: true) end)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\[show\] Episode (\d+)\b/, String.trim(line)) do
        [_, n] -> [{String.to_integer(n), String.trim(line)}]
        _ -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {number, lines} -> %{number: number, lines: lines} end)
  rescue
    _ -> []
  end

  defp page_slug(page), do: page |> Atom.to_string() |> String.replace("_", "-")
end
