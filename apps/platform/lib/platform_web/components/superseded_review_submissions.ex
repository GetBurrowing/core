defmodule PlatformWeb.Components.SupersededReviewSubmissions do
  @moduledoc """
  The collapsed "N earlier submissions" disclosure under the review panel
  (task `019fed8d` stage 3).

  A pure presentation component over a list of superseded
  `Platform.Tasks.ReviewRequest` rows. Whether a row is superseded at all
  is decided in `Platform.Tasks.ReviewRequests` — the create path marks a
  still-pending sibling `"superseded"` in the same transaction, and
  `approve_item/2` / `reject_item/3` refuse one server-side. Nothing here
  decides state; it renders what it is handed.

  ## This block is a SUBTRACTION

  A superseded request renders no Approve and no Send-feedback control,
  because the failure being fixed is a silent wrong click, not a
  misreading: a `Superseded` badge explains the mistake to someone who has
  already made it while leaving the button clickable. No
  `--color-warning` / `--color-error` either — resubmitting is what
  correction looks like, and colouring it as a fault spends the palette's
  loudest slot on routine behaviour.

  It lives in its own module rather than in `tasks_live.ex` for the same
  reason `PlatformWeb.Components.TaskMergeControls` does: the shell is
  under a non-accretion guard, and presentation logic is what that guard
  exists to keep out of it. What stayed behind in the shell is only what
  cannot live in a function component — the `:superseded_reviews` and
  `:superseded_reviews_expanded` assigns and the
  `"toggle_superseded_reviews"` event clause.
  """

  use Phoenix.Component

  attr(:reviews, :list, required: true, doc: "superseded `ReviewRequest` rows, items preloaded")
  attr(:expanded, :boolean, required: true, doc: "disclosure state held by the caller")

  attr(:target, :any,
    required: true,
    doc: """
    `@myself` of the LiveComponent that owns the disclosure. Required, not
    optional-with-nil-default: the owner moved from the shell LiveView to
    `PlatformWeb.Tasks.GatePanelComponent` in task 01a008f6 stage 6, and a
    defaulted `phx-target` would have let the toggle keep compiling while
    firing into a LiveView that no longer has the clause.
    """
  )

  def superseded_review_submissions(assigns) do
    ~H"""
    <div data-role="superseded-reviews" class="space-y-2">
      <div class="border-t border-edge"></div>
      <button
        type="button"
        class="flex items-center gap-1 text-xs text-base-content/60"
        phx-click="gate_toggle_superseded"
        phx-target={@target}
        aria-expanded={to_string(@expanded)}
      >
        <span class={"size-3 #{if @expanded, do: "hero-chevron-down", else: "hero-chevron-right"}"}>
        </span>
        {earlier_submissions_label(@reviews)}
      </button>

      <div :if={@expanded} class="space-y-2">
        <div
          :for={review <- @reviews}
          data-role="superseded-review"
          class="rounded-lg border border-edge p-3 space-y-1 text-base-content/60"
        >
          <div :for={item <- review.items} class="text-sm">{item.label}</div>
          <div class="text-xs">{superseded_timestamps(review)}</div>
        </div>
      </div>
    </div>
    """
  end

  # Sentence case, and the word is "submission" — not "superseded",
  # "outdated" or "archived". The line describes what happened (someone sent
  # a newer one), not a judgement on the entry.
  defp earlier_submissions_label(reviews) do
    case length(reviews) do
      1 -> "1 earlier submission"
      n -> "#{n} earlier submissions"
    end
  end

  # Both timestamps, because either alone is ambiguous: "submitted 19:14"
  # does not say it was replaced, and "superseded 19:20" does not say what
  # it was replacing. `superseded_at` is nil for rows written before the
  # column existed, so the label degrades rather than crashing the panel.
  defp superseded_timestamps(review) do
    submitted = Calendar.strftime(review.inserted_at, "%b %d, %H:%M")

    case review.superseded_at do
      %DateTime{} = at ->
        "submitted #{submitted} · superseded #{Calendar.strftime(at, "%b %d, %H:%M")}"

      _ ->
        "submitted #{submitted}"
    end
  end
end
