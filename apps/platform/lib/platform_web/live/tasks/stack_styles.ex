defmodule PlatformWeb.Tasks.StackStyles do
  @moduledoc """
  Presentation tokens for stack UI — SVG fills, captions and Tailwind class
  strings for the dep DAG and the numbered member nodes.

  Split out of `PlatformWeb.TasksLive` alongside `Platform.Tasks.StackGraph`
  (task 01a008f6 stage 3). The graph math went to the domain layer; these
  did NOT, because they emit Tailwind classes and hex fills and belong on
  the web side of that boundary.

  They live in their own module rather than inside `StacksComponent` because
  `member_node_class/1` and `stack_position_glyph/1` are also consumed by the
  board-card inline expansion, which stays in the shell until the Board
  extraction. One home beats two copies.
  """

  import PlatformWeb.Tasks.StatusLabels, only: [status_label: 1]

  @doc """
  Tone class for the dep-edges meta cell value: success-tinted when the
  subgraph is acyclic, error-tinted when a cycle is detected.
  """
  def dep_edges_class(%{valid?: true}), do: "text-base-content"
  def dep_edges_class(%{valid?: false}), do: "text-error"

  @doc """
  Status → fill / stroke / caption / dasharray for a DAG node rect.

  Mirrors the mock canvas 019e1a16 rev 2 palette:
  done → green tint, in_review → yellow tint, in_progress → blue tint,
  deploying → purple tint, waiting (stack_pending / backlog) → dashed gray,
  else → neutral gray.

  Captions are uppercase short codes (DONE / REVIEW / PROGRESS / WAITING /
  status-string) — chosen to fit inside the 140px rect.
  """
  def dag_node_style("done") do
    %{
      fill: "rgba(0,255,157,0.12)",
      stroke: "#3aa97c",
      text: "#e6e9ee",
      num_color: "#7df0c0",
      caption_color: "#7df0c0",
      caption: "DONE",
      dasharray: nil
    }
  end

  def dag_node_style("in_review") do
    %{
      fill: "rgba(255,190,0,0.12)",
      stroke: "#a37c3a",
      text: "#e6e9ee",
      num_color: "#ffd66e",
      caption_color: "#ffd66e",
      caption: "REVIEW",
      dasharray: nil
    }
  end

  def dag_node_style("in_progress") do
    %{
      fill: "rgba(58,191,248,0.12)",
      stroke: "#3a7ca3",
      text: "#e6e9ee",
      num_color: "#7fd4f9",
      caption_color: "#7fd4f9",
      caption: "PROGRESS",
      dasharray: nil
    }
  end

  def dag_node_style("deploying") do
    %{
      fill: "rgba(186,112,255,0.12)",
      stroke: "#7b5cff",
      text: "#e6e9ee",
      num_color: "#bba1ff",
      caption_color: "#bba1ff",
      caption: "DEPLOY",
      dasharray: nil
    }
  end

  def dag_node_style(status) when status in ["stack_pending", "backlog"] do
    %{
      fill: "rgba(255,255,255,0.03)",
      stroke: "#3d4451",
      text: "#a6adba",
      num_color: "#6e7681",
      caption_color: "#6e7681",
      caption: "WAITING",
      dasharray: "4,3"
    }
  end

  def dag_node_style(other) do
    %{
      fill: "rgba(255,255,255,0.04)",
      stroke: "#3d4451",
      text: "#a6adba",
      num_color: "#6e7681",
      caption_color: "#6e7681",
      caption: other |> to_string() |> String.upcase(),
      dasharray: nil
    }
  end

  @doc """
  Truncate a node label to roughly the rect width (140px). Falls back to a
  14-char hard cap with ellipsis. Empty/nil labels render blank.
  """
  def dag_node_label(nil), do: ""
  def dag_node_label(""), do: ""

  def dag_node_label(label) when is_binary(label) do
    if String.length(label) > 14 do
      String.slice(label, 0, 13) <> "…"
    else
      label
    end
  end

  @doc """
  Styling for the round numbered node next to a member's title.

  Varies by status per mock canvas 019e1a16 rev 2: done → success tint,
  in_review → warning tint, stack_pending / backlog → dashed gray,
  everything else → neutral base-300 ring.
  """
  def member_node_class("done"), do: "bg-success/20 text-success border border-success/40"

  def member_node_class("in_review"),
    do: "bg-warning/20 text-warning border border-warning/40"

  def member_node_class("stack_pending"),
    do: "bg-base-300 text-base-content/40 border border-base-300 border-dashed"

  def member_node_class("backlog"),
    do: "bg-base-300 text-base-content/40 border border-base-300 border-dashed"

  def member_node_class(_),
    do: "bg-base-200 text-base-content/70 border border-base-300"

  @doc """
  Colour tone for the stack status meta-cell value text.

  Mirrors the badge palette used elsewhere (in_review→warning,
  in_progress→info, done→success, deploying→secondary). `forming` and
  `abandoned` are dimmed since they're transient/terminal-without-ship states.
  """
  def stack_status_text_class("in_review"), do: "text-warning"
  def stack_status_text_class("in_progress"), do: "text-info"
  def stack_status_text_class("done"), do: "text-success"
  def stack_status_text_class("deploying"), do: "text-secondary"
  def stack_status_text_class("blocked"), do: "text-error"
  def stack_status_text_class(_), do: "text-base-content/50"

  @doc """
  Status pill `{label, class}` for a stack member row in the linear list.

  Mirrors the four mock tones (.b-status-done / -rev / -prog / -wait) so the
  right-column pills colour-match the DAG node fills exactly.
  """
  def member_status_pill("done"),
    do: {"Done", "bg-success/20 text-success"}

  def member_status_pill("in_review"),
    do: {"Review", "bg-warning/20 text-warning"}

  def member_status_pill("in_progress"),
    do: {"In Progress", "bg-info/20 text-info"}

  def member_status_pill("deploying"),
    do: {"Deploying", "bg-secondary/20 text-secondary"}

  def member_status_pill(status) when status in ["stack_pending", "backlog"],
    do:
      {"Waiting", "bg-base-300 text-base-content/50 border border-dashed border-base-content/20"}

  def member_status_pill(other),
    do: {status_label(other), "bg-base-300 text-base-content/70"}

  @doc """
  Maps the `Tasks.needs_human_action_reason/2` atom to a
  `{label, data-action-reason-string}` tuple used by the stack-detail
  member-row badge (stage 2 of task 019e2c25).

  The string is what we expose via `data-action-reason` so tests + dataview
  drilldowns can target the exact predicate branch. `nil` reason →
  `{nil, nil}`, which the template's `:if` condition uses to suppress the
  badge.
  """
  def stack_member_action_label(:plan_pending_review), do: {"Plan ready", "plan_pending_review"}

  def stack_member_action_label(:review_request_pending),
    do: {"Needs review", "review_request_pending"}

  def stack_member_action_label(:awaiting_human_merge),
    do: {"needs merge", "awaiting_human_merge"}

  # Task 01a0665e stage 1. Stack members return from the webhook before the
  # stamp is ever written (`stack_ships_atomically`), so this is reached
  # only by a member stamped while stackless and stacked afterwards — but
  # this function has no catch-all, and a new resolver atom without a
  # clause here is a `FunctionClauseError` on the stack detail page.
  def stack_member_action_label(:delivered_but_open),
    do: {"delivered, close it", "delivered_but_open"}

  def stack_member_action_label(:validation_failed), do: {"Needs review", "validation_failed"}
  def stack_member_action_label(nil), do: {nil, nil}
end
