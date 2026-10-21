defmodule PlatformWeb.OrgMemoryLive.JournalPane do
  @moduledoc """
  Journal tab for the Org Memory wiki (ADR-0041 T7 stage 6).

  Append-only by contract: an append form (single textarea,
  `phx-submit="append_journal"`, draft tracked via
  `phx-change="update_journal_draft"`) above a date-grouped feed of
  `Platform.Org.Wiki.Journal.list_recent/1` entries. The date-grouping
  pattern (sticky day header + entry count) is carried over from the V1
  `OrgContextLive` memory feed.

  Deliberately NO delete affordance anywhere — the data layer rejects
  journal mutation (`:journal_immutable`), so the UI must not surface
  one.

  Stateless — entries, draft, namespace, and the focused date all live
  on `PlatformWeb.OrgMemoryLive`.
  """

  use Phoenix.Component

  attr(:groups, :list,
    required: true,
    doc: "[{Date.t(), [WikiJournalEntry.t()]}] newest day first"
  )

  attr(:draft, :string, default: "")
  attr(:namespace, :string, required: true, doc: "namespace entries are read from / appended to")
  attr(:focus_date, :any, default: nil, doc: "Date.t() highlighted after a search click-through")

  def journal_pane(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-hidden" data-role="journal-pane">
      <%!-- Header --%>
      <div class="flex items-center justify-between border-b border-edge px-6 py-3">
        <div>
          <h1 class="text-lg font-bold">Journal</h1>
          <p class="text-xs text-subtle">
            Append-only notes, last 14 days
          </p>
        </div>
        <span class="badge badge-ghost badge-sm font-mono">{@namespace}</span>
      </div>

      <%!-- Append form (top) --%>
      <form
        id="org-memory-journal-form"
        phx-submit="append_journal"
        phx-change="update_journal_draft"
        class="border-b border-edge px-6 py-4"
      >
        <textarea
          name="content"
          rows="3"
          placeholder="Append a journal note…"
          class="textarea textarea-bordered w-full text-sm"
        >{@draft}</textarea>
        <div class="mt-2 flex justify-end">
          <button
            type="submit"
            class="btn btn-primary btn-sm gap-1"
            disabled={String.trim(@draft) == ""}
          >
            <span class="hero-plus size-4"></span> Append
          </button>
        </div>
      </form>

      <%!-- Date-grouped feed --%>
      <div class="flex-1 overflow-y-auto px-6 py-4">
        <%= if @groups == [] do %>
          <div class="flex flex-col items-center justify-center py-16">
            <span class="hero-book-open mb-3 size-12 text-subtle block"></span>
            <h3 class="text-base font-medium text-base-content">No journal entries yet</h3>
            <p class="mt-1 text-sm text-subtle max-w-sm text-center">
              Notes appended here (or by agents via <code>memory_create</code>)
              show up grouped by day.
            </p>
          </div>
        <% else %>
          <div class="space-y-6">
            <div :for={{date, entries} <- @groups} id={"journal-day-#{Date.to_iso8601(date)}"}>
              <%!-- Date header --%>
              <div class={[
                "sticky top-0 z-10 flex items-center gap-3 bg-base-100 py-2",
                @focus_date == date && "text-primary"
              ]}>
                <span class="text-sm font-semibold text-base-content">
                  {format_journal_date(date)}
                </span>
                <div class="flex-1 border-t border-edge"></div>
                <span class="text-xs text-subtle">
                  {length(entries)} {if length(entries) == 1, do: "entry", else: "entries"}
                </span>
              </div>

              <%!-- Day's entries --%>
              <div class="space-y-3 pl-2">
                <div
                  :for={entry <- entries}
                  class={[
                    "rounded-lg border bg-base-100 p-4",
                    if(@focus_date == date,
                      do: "border-primary/40 ring-1 ring-primary/20",
                      else: "border-edge"
                    )
                  ]}
                >
                  <div class="mb-2 flex items-center gap-2">
                    <span class="inline-block size-2 rounded-full bg-info"></span>
                    <span class="ml-auto text-xs text-subtle">
                      {Calendar.strftime(entry.inserted_at, "%H:%M")}
                    </span>
                  </div>
                  <p class="whitespace-pre-wrap text-sm text-base-content">{entry.content}</p>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp format_journal_date(date) do
    today = Date.utc_today()

    cond do
      date == today -> "Today"
      date == Date.add(today, -1) -> "Yesterday"
      true -> Calendar.strftime(date, "%A, %b %-d")
    end
  end
end
