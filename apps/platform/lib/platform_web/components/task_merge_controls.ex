defmodule PlatformWeb.Components.TaskMergeControls do
  @moduledoc """
  The `Merge` / `Open PR` cluster pinned to the bottom of the task detail
  panel (task `019ff182` stage 1).

  A pure presentation component over `Platform.Tasks.MergeControl.t()`.
  Everything about WHETHER it may render — `pr_merge`, `auto_merge:
  false`, not a stack member, a live `pr_merged` gate — is decided in the
  context. Everything about how a state LOOKS is decided here, and
  nowhere else.

  ## The colour rule, which is the whole point of the component

  GitHub reports `mergeable: MERGEABLE` when zero checks ran, identically
  to when every check passed. So:

  | band tone  | means                     | treatment |
  | ---------- | ------------------------- | --------- |
  | `:warning` | nothing verified this branch | `--color-warning` |
  | `:success` | every configured check passed | `--color-success` |
  | `:error`   | a check FAILED, or a merge was REFUSED | `--color-error` |

  "No status checks configured" is `:warning`. Never success, never
  neutral grey: grey reads *not applicable* and green reads *verified*,
  and the true statement is that nothing checked this branch.
  `--color-error` never marks the ABSENCE of checks — absence is not
  failure, and conflating them teaches people to ignore red.
  `--color-info` is deliberately unused; nothing in this cluster is
  informational.

  The Merge button's classes do not appear in any of those rows. They do
  not vary at all. A button that changes colour teaches people to read
  the button for safety, and the button is exactly what lies when zero
  checks ran.

  It lives in its own module rather than in `tasks_live.ex` for the same
  reason `PlatformWeb.Components.PlanningStepExtension` does: the shell is
  under a non-accretion guard, and presentation logic is what that guard
  exists to keep out of it.
  """

  use Phoenix.Component

  attr(:control, :map, required: true, doc: "a `Platform.Tasks.MergeControl.t()`")

  attr(:target, :any,
    default: nil,
    doc:
      "`phx-target` for the Merge click. Task 01a008f6 stage 5 promoted the cluster's " <>
        "state and event onto `PlatformWeb.Tasks.MergeControlComponent`, so the click " <>
        "must be addressed to that LiveComponent rather than to the shell."
  )

  def task_merge_controls(assigns) do
    ~H"""
    <%!-- Pinned bottom action bar, same shape as the stack detail panel's
         `stack-detail-actions`: the last, non-shrinking child of the
         panel's flex column. The panel container's
         `bottom-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))]`
         already keeps it clear of the iOS bottom-tab nav, so no
         defensive bottom padding belongs here. --%>
    <div class="shrink-0 border-t border-edge bg-base-100" data-role="task-merge-controls">
      <%!-- Full-width state band, above the buttons so it is read before
           the hand reaches the control rather than sitting beside it
           where it degrades into decoration. --%>
      <div
        class={[
          "mx-4 mt-3 flex items-start gap-2 rounded-[var(--radius-field)] border px-3 py-2",
          band_class(@control.band.tone)
        ]}
        data-role="merge-check-state"
        data-tone={to_string(@control.band.tone)}
      >
        <span class={[
          band_icon(@control.band.tone),
          "size-4 shrink-0 mt-0.5",
          band_text_class(@control.band.tone)
        ]}>
        </span>
        <%!-- A full SENTENCE, not a status word. "No checks" is a label a
             person skims past; "Nothing has verified this branch" is a
             claim they have to disagree with in order to click on. --%>
        <p class="text-sm text-base-content">
          <span class="font-medium">{@control.band.headline}</span>
          {@control.band.sentence}
        </p>
      </div>

      <%!-- Truncation order: the SOURCE ref truncates, the arrow and the
           TARGET never do. A task branch name is long and generated;
           `main` is four characters and the only part that says where
           this is going, so a layout that truncates it has dropped the
           most consequential word on the screen. --%>
      <div
        class="flex items-center gap-1 px-4 pt-2 font-mono text-sm text-base-content/70"
        data-role="merge-branch-pair"
      >
        <span class="min-w-0 truncate" data-role="merge-source-ref">{@control.branch}</span>
        <span class="hero-arrow-right size-3 shrink-0"></span>
        <span class="shrink-0" data-role="merge-target-ref">{@control.base_ref}</span>
      </div>

      <%!-- Full-width and stacked below `sm`, Merge first. Never a bottom
           sheet: sheets are mobile-only per the design system and this
           cluster is inline in the panel at every width. --%>
      <div class="flex flex-col gap-2 px-4 py-3 sm:flex-row">
        <%!-- Never disabled by mergeability, and never tinted by it. The
             control surfaces state; it does not block. A human
             overriding a red check deliberately is legitimate, and
             `MergeControl.merge/3` records it in the audit trail. --%>
        <button
          type="button"
          class="btn btn-primary btn-sm flex-1"
          phx-click="merge_task_branch"
          phx-target={@target}
          data-role="task-merge-button"
        >
          Merge
        </button>
        <a
          :if={@control.pr_url}
          href={@control.pr_url}
          target="_blank"
          rel="noopener"
          class="btn btn-ghost btn-sm flex-1"
          data-role="task-open-pr"
        >
          Open PR <span class="hero-arrow-top-right-on-square size-4"></span>
        </a>
        <%!-- Explicit disabled fallback for "no PR resolved", mirroring
             the stack bar's rollup-PR fallback. `Open PR` must never be a
             dead link, and the reason it is unavailable is already
             spelled out in the band above. --%>
        <button
          :if={is_nil(@control.pr_url)}
          type="button"
          class="btn btn-ghost btn-sm flex-1 btn-disabled"
          disabled
          data-role="task-open-pr-disabled"
        >
          Open PR
        </button>
      </div>
    </div>
    """
  end

  defp band_class(:success), do: "border-success bg-success/10"
  defp band_class(:warning), do: "border-warning bg-warning/10"
  defp band_class(:error), do: "border-error bg-error/10"

  defp band_text_class(:success), do: "text-success"
  defp band_text_class(:warning), do: "text-warning"
  defp band_text_class(:error), do: "text-error"

  defp band_icon(:success), do: "hero-check-circle"
  defp band_icon(:warning), do: "hero-exclamation-triangle"
  defp band_icon(:error), do: "hero-x-circle"
end
