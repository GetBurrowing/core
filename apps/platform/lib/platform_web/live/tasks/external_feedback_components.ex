defmodule PlatformWeb.Tasks.ExternalFeedbackComponents do
  @moduledoc """
  Render pieces for external-feedback tasks on the Tasks board (task 01a11ec3
  stage 4): the trust badge on cards, the External Feedback lane banner, and
  the repository/issue provenance block in the detail panel.

  Everything here reads the PERSISTED `origin`, `trust`,
  `external_repository_identity` and `external_issue_number` columns and
  nothing else — not `kind`, not metadata, not the project's repository. An
  internal task renders none of it.

  Display only. Nothing in this module grants or checks authority: the
  promote control in `TaskDetailComponent` is shown only when
  `Platform.Tasks.can_promote_from_quarantine?/2` is true (it is rendered by
  that component into `provenance/1`'s `:actions` slot), and its event
  handler asks that same predicate again before calling
  `Platform.Tasks.promote_from_quarantine/3`.

  Colour comes from the brand's semantic slots through existing classes only
  (`chip-error` for destructive/quarantined, `chip-primary` for trusted,
  `border-accent` for the lane, `bg-base-*` surfaces, `text-base-content/60`
  muted text, `border-edge` borders). No raw colour values.
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [chip: 1]

  alias Platform.Tasks.Task

  @doc "True when the task's persisted origin is external feedback."
  @spec external?(term()) :: boolean()
  def external?(%Task{origin: "external_feedback"}), do: true
  def external?(%{origin: "external_feedback"}), do: true
  def external?(_), do: false

  @doc """
  The GitHub issue URL for a task's durable provenance, or nil. The identity
  is already constrained to `owner/repo` by `Task.changeset/2`'s format
  validation and the number to a positive integer, so neither can carry a
  scheme, a host, or a path segment of its own.
  """
  @spec issue_url(term()) :: String.t() | nil
  def issue_url(%{external_repository_identity: repo, external_issue_number: number})
      when is_binary(repo) and is_integer(number) and number > 0 do
    if String.match?(repo, ~r/\A[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9._-]+\z/),
      do: "https://github.com/#{repo}/issues/#{number}",
      else: nil
  end

  def issue_url(_), do: nil

  attr :task, :any, required: true
  attr :size, :string, default: "xs", values: ~w(xs sm)

  @doc "Quarantined/trusted chip. Renders nothing for an internal task."
  def trust_badge(assigns) do
    ~H"""
    <.chip
      :if={external?(@task)}
      tone={if @task.trust == "quarantined", do: "error", else: "primary"}
      data-role="task-trust-badge"
      data-trust={@task.trust}
      class={[
        "inline-flex items-center gap-1 whitespace-nowrap",
        if(@size == "xs", do: "text-[10px]", else: "text-xs")
      ]}
      title={
        if @task.trust == "quarantined",
          do: "External feedback, quarantined: cannot be planned or executed until promoted",
          else: "External feedback, promoted to trusted"
      }
    >
      <span
        class={[
          if(@task.trust == "quarantined", do: "hero-shield-exclamation", else: "hero-shield-check"),
          "size-3"
        ]}
        aria-hidden="true"
      >
      </span>
      {if @task.trust == "quarantined", do: "Quarantined", else: "Trusted"}
    </.chip>
    """
  end

  @doc "Header strip shown above the board while the External Feedback lane is active."
  def lane_banner(assigns) do
    ~H"""
    <div
      data-role="external-feedback-lane-banner"
      class="mx-4 mt-3 flex items-start gap-3 rounded-box border border-edge border-l-4 border-l-accent bg-base-200 px-3 py-2"
    >
      <span class="hero-inbox-arrow-down size-5 shrink-0 text-accent" aria-hidden="true"></span>
      <div class="min-w-0 text-xs">
        <p class="font-semibold text-base-content">External feedback</p>
        <p class="text-base-content/60">
          Filed from accepted GitHub issues. Quarantined items cannot be planned or
          executed until an org admin promotes them; promoted items stay here with their
          provenance.
        </p>
      </div>
    </div>
    """
  end

  attr :task, :any, required: true

  slot :actions,
    doc:
      "the caller's controls (the detail panel's promote button), rendered by the caller " <>
        "so its event stays targeted at the component that handles it"

  @doc "Repository/issue provenance, with the caller's actions slot underneath."
  def provenance(assigns) do
    assigns = assign(assigns, :url, issue_url(assigns.task))

    ~H"""
    <section
      :if={external?(@task)}
      data-role="detail-external-provenance"
      aria-label="External feedback provenance"
      class="rounded-box border border-edge border-l-4 border-l-accent bg-base-200 p-3 space-y-2"
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="hero-inbox-arrow-down size-4 text-accent" aria-hidden="true"></span>
        <span class="text-xs font-semibold uppercase tracking-widest text-base-content/60">
          External feedback
        </span>
        <.trust_badge task={@task} size="sm" />
      </div>

      <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs">
        <dt class="text-base-content/60">Repository</dt>
        <dd class="min-w-0 truncate font-mono" data-role="detail-external-repository">
          {@task.external_repository_identity}
        </dd>
        <dt class="text-base-content/60">Issue</dt>
        <dd data-role="detail-external-issue">
          <a
            :if={@url}
            href={@url}
            target="_blank"
            rel="noopener noreferrer"
            class="link link-primary inline-flex items-center gap-1"
          >
            #{@task.external_issue_number}
            <span class="hero-arrow-top-right-on-square size-3" aria-hidden="true"></span>
          </a>
          <span :if={is_nil(@url)}>#{@task.external_issue_number}</span>
        </dd>
      </dl>

      <p :if={@task.trust == "quarantined"} class="text-xs text-base-content/60">
        Quarantined: planning and execution are refused on the server until this task is
        promoted. Promotion changes trust only; the origin and issue link above stay.
      </p>

      {render_slot(@actions)}
    </section>
    """
  end
end
