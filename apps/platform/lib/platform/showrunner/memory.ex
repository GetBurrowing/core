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
  writes `[show]`-tagged journal entries (`journal_entry/1`) and the Historian
  curates them into the pages. There is deliberately no bypass here.
  """

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

  defp page_slug(page), do: page |> Atom.to_string() |> String.replace("_", "-")
end
