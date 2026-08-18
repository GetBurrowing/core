defmodule PlatformWeb.OrgMemoryLive.ProposalsPane do
  @moduledoc """
  Proposals tab for the Org Memory wiki (ADR-0041 T7 stage 4 — task
  019f70e9).

  Renders pending `Platform.Memory.MemoryProposal` rows from the
  Historian's dreaming synthesis pipeline as a 5-column table
  (Category | Confidence | Evidence | Source | Age | Actions). Each row
  offers two icon-only actions:

    * Approve (checkmark) → `phx-click="approve_proposal"` — flips
      status to `:approved` and delegates promotion to
      `Platform.Memory.Proposals.queue_promotion/1`.
    * Reject (X) → `phx-click="show_reject_form"` — expands an inline
      sub-row (colspan across the table) carrying a feedback textarea +
      Cancel + Submit. The feedback text feeds the next dreaming run's
      few-shot exemplars per
      `Platform.Memory.Proposals.rejected_exemplars/1`.

  Empty state renders a friendly "the Historian's dreaming is quiet"
  message — rejected + expired proposals persist in the DB for post-hoc
  analysis but never surface here.

  Rows render as a plain list (not a Phoenix stream) because the
  inline reject-form expansion row must nest inside the same tbody as
  the primary row, and `phx-update="stream"` rejects non-stream
  children. Approve/reject re-fetches the pending list — cheap because
  the pending set is bounded (default `list_pending/1` limit == 50,
  and Rowan's typical inbox is single-digit).

  Stateless — the pending list, `show_reject_form_for`, and the
  workspace scope all live on `PlatformWeb.OrgMemoryLive`.
  """

  use Phoenix.Component

  attr(:proposals, :list, required: true, doc: "[MemoryProposal.t()] newest first")

  attr(:show_reject_form_for, :any,
    default: nil,
    doc: "id of the proposal whose inline reject textarea is expanded"
  )

  def proposals_pane(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-hidden" data-role="proposals-pane">
      <%!-- Header --%>
      <div class="flex items-center justify-between border-b border-base-300 px-6 py-3">
        <div>
          <h1 class="text-lg font-bold">Proposals</h1>
          <p class="text-xs text-base-content/40">
            Historian synthesis suggestions awaiting your review
          </p>
        </div>
        <span :if={@proposals != []} class="badge badge-warning badge-sm">
          {length(@proposals)} pending
        </span>
      </div>

      <div class="flex-1 overflow-y-auto">
        <%= if @proposals == [] do %>
          <div class="flex flex-col items-center justify-center py-16 px-6">
            <div
              class="max-w-md rounded-xl border border-base-300 bg-base-100 p-8 text-center"
              data-role="proposals-empty-state"
            >
              <span class="hero-sparkles mb-3 size-12 text-base-content/30 block mx-auto"></span>
              <h3 class="text-base font-medium text-base-content/70">
                Nothing to review — the Historian's dreaming is quiet.
              </h3>
              <p class="mt-2 text-sm text-base-content/40">
                Rejected + expired proposals remain in the DB for post-hoc analysis
                but don't appear here.
              </p>
            </div>
          </div>
        <% else %>
          <table
            id="org-memory-proposals-table"
            class="w-full text-sm"
            data-role="proposals-table"
          >
            <thead class="sticky top-0 z-10 bg-base-200/60 text-xs uppercase tracking-wider text-base-content/50">
              <tr>
                <th class="px-4 py-2 text-left font-medium">Category</th>
                <th class="px-4 py-2 text-left font-medium">Confidence</th>
                <th class="px-4 py-2 text-left font-medium">Evidence</th>
                <th class="px-4 py-2 text-left font-medium">Source</th>
                <th class="px-4 py-2 text-left font-medium">Age</th>
                <th class="px-4 py-2 text-right font-medium">Actions</th>
              </tr>
            </thead>
            <tbody id="proposals-tbody">
              <%= for proposal <- @proposals do %>
                <tr
                  id={"proposal-row-#{proposal.id}"}
                  data-proposal-id={proposal.id}
                  class={[
                    "border-b border-base-300 transition-colors hover:bg-base-200",
                    "md:even:bg-base-100/50",
                    @show_reject_form_for == proposal.id &&
                      "bg-warning/5 border-l-2 border-l-warning"
                  ]}
                >
                  <td class="px-4 py-3">
                    <span class={[
                      "badge badge-xs whitespace-nowrap",
                      category_badge_class(proposal.category)
                    ]}>
                      {proposal.category}
                    </span>
                  </td>
                  <td class="px-4 py-3">
                    <span class={["badge badge-xs", confidence_badge_class(proposal.confidence)]}>
                      {proposal.confidence}
                    </span>
                  </td>
                  <td
                    class="px-4 py-3 max-w-xs truncate text-base-content/70"
                    title={proposal.evidence}
                    data-role="evidence-cell"
                  >
                    {proposal.evidence || "—"}
                  </td>
                  <td class="px-4 py-3 font-mono text-xs text-base-content/50">
                    <a
                      href={"/org_memory/#{proposal.journal_path}"}
                      class="hover:text-primary hover:underline"
                    >
                      {source_label(proposal.journal_path)}
                    </a>
                  </td>
                  <td class="px-4 py-3 text-xs text-base-content/50 whitespace-nowrap">
                    {relative_age(proposal.inserted_at)}
                  </td>
                  <td class="px-4 py-3 text-right whitespace-nowrap">
                    <button
                      phx-click="approve_proposal"
                      phx-value-id={proposal.id}
                      class="btn btn-primary btn-xs"
                      data-action="approve"
                      title="Approve — promote to page"
                      aria-label="Approve proposal"
                    >
                      <span class="hero-check size-4"></span>
                    </button>
                    <button
                      phx-click="show_reject_form"
                      phx-value-id={proposal.id}
                      class="btn btn-ghost btn-xs ml-1"
                      data-action="reject"
                      title="Reject with feedback"
                      aria-label="Reject proposal"
                    >
                      <span class="hero-x-mark size-4"></span>
                    </button>
                  </td>
                </tr>

                <%!-- Inline reject-form expansion row --%>
                <tr
                  :if={@show_reject_form_for == proposal.id}
                  id={"proposal-reject-row-#{proposal.id}"}
                  data-role="reject-form-row"
                  class="bg-warning/5 border-b border-base-300"
                >
                  <td colspan="6" class="px-4 py-4">
                    <form
                      id={"proposal-reject-form-#{proposal.id}"}
                      phx-submit="reject_proposal"
                    >
                      <%!-- `name="_id"`, not `name="id"`: on an input, name="id"
                           overrides the DOM id of the enclosing form element, which
                           LiveView warns about at compile time. The handler in
                           `view.ex` matches `"_id"` for both proposal reject
                           forms. --%>
                      <input type="hidden" name="_id" value={proposal.id} />
                      <div class="mb-2 text-xs font-medium text-base-content/70">
                        Why is this proposal being rejected? Your feedback trains the next dreaming run.
                      </div>
                      <textarea
                        name="feedback"
                        rows="3"
                        placeholder="Optional feedback — e.g. 'Not novel; already captured in org/page/pricing.md.'"
                        class="textarea textarea-bordered w-full text-sm"
                      ></textarea>
                      <div class="mt-2 flex justify-end gap-2">
                        <button
                          type="button"
                          phx-click="cancel_reject"
                          phx-value-id={proposal.id}
                          class="btn btn-ghost btn-xs"
                        >
                          Cancel
                        </button>
                        <button type="submit" class="btn btn-warning btn-xs">
                          Submit rejection
                        </button>
                      </div>
                    </form>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Category → tone mapping per Saru's approved design brief.
  defp category_badge_class("emerging-risk"), do: "badge-warning"
  defp category_badge_class("stale-fact-candidate-retirement"), do: "badge-warning"
  defp category_badge_class("strategic-insight"), do: "badge-info"
  defp category_badge_class("recurring-theme"), do: "badge-info"
  defp category_badge_class("cross-project-pattern"), do: "badge-neutral"
  defp category_badge_class("unresolved-question"), do: "badge-neutral"
  defp category_badge_class(_), do: "badge-ghost"

  defp confidence_badge_class("high"), do: "badge-success"
  defp confidence_badge_class("medium"), do: "badge-warning"
  defp confidence_badge_class("low"), do: "badge-ghost"
  defp confidence_badge_class(_), do: "badge-ghost"

  # `org/journal/2026-07-18.md` → `2026-07-18` (just the date).
  # `project/<uuid>/journal/<date>.md` → `project/<short>/<date>`.
  defp source_label(nil), do: "—"

  defp source_label(path) when is_binary(path) do
    case String.split(path, "/") do
      ["org", "journal", date_md] ->
        String.replace_suffix(date_md, ".md", "")

      [kind, id, "journal", date_md] ->
        "#{kind}/#{short_id(id)}/#{String.replace_suffix(date_md, ".md", "")}"

      _ ->
        path
    end
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: "?"

  defp relative_age(%DateTime{} = ts) do
    seconds = DateTime.diff(DateTime.utc_now(), ts, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp relative_age(_), do: "—"
end
