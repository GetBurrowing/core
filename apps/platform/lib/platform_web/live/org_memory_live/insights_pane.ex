defmodule PlatformWeb.OrgMemoryLive.InsightsPane do
  @moduledoc """
  The Insights tab of Org Memory (task `01a13867-3213-7001-a128-6b4c6b34283f`
  stage 5), renamed from Proposals. Built to the direction canvas
  `01a14a73-9058-7000-8695-d0753117c384` (elements, states and copy, not
  layout). Replaces `ProposalsPane`.

  Each row (`data-role="insight-row"`) is the insight sentence in medium
  weight, `Evidence: … · <confidence>` in sm, the JetBrains Mono type label
  (`insight-type-label`, no per-type colour) and the expiry (`insight-expiry`,
  `Nd left` in neutral, warning on the last day), then the action preview
  (`PlatformWeb.OrgMemoryLive.InsightPreview`), then the buttons: Reject,
  Reroute, Edit, Dismiss and ONE `btn-primary` named for the action
  (`insight-primary`).

  A `needs_call` row (`insight-needs-call`) is on warning, and its buttons
  render only when the viewer may handle it (`Insights.may_handle?/2`: a
  root admin in this slice). Everyone else sees why there are none. That
  is presentation: every handler in `PlatformWeb.OrgMemoryLive` re-checks
  through `Platform.Memory.Insights` with a freshly loaded scope.

  Reject opens an inline form whose reason is required
  (`insight-reject-form`). Reroute opens a person picker defaulting to the
  suggested addressee and showing why it was suggested (`insight-reroute`).
  Edit opens an inline form over the sentence and, for a page_edit, each
  hunk's new text.

  "Already done" (`insights-already-done`) renders only while dissemination
  is on. While it is off, a one-line notice says so instead
  (`insights-off-notice`), with "Settings" linking to `/admin/insights` for
  an admin. There is no archive filter: an expired insight is simply gone.

  The personal opt-out ("Insight briefings and questions") sits in this
  tab's header because the install has no profile page (stated deviation).

  Stateless. Rendered twice into one document (desktop and the `lg:hidden`
  mobile branch), so every DOM id is prefixed by `surface`.
  """

  use Phoenix.Component

  alias PlatformWeb.OrgMemoryLive.InsightPreview

  @off_notice_lead "Insights stay on this tab. An admin can send them to people in"

  @doc "The dissemination-off notice, verbatim."
  def off_notice, do: @off_notice_lead <> " Settings."

  attr(:surface, :atom, values: [:desktop, :mobile], required: true)
  attr(:insights, :list, required: true, doc: "open, unexpired, filtered")
  attr(:done, :list, default: [], doc: "acted, unexpired; shown only while dissemination is on")
  attr(:dissemination_on, :boolean, default: false)
  attr(:admin?, :boolean, default: false)
  attr(:receives?, :boolean, default: true, doc: "the viewer's own delivery opt-in")
  attr(:handle_ids, :any, default: nil, doc: "MapSet of insight ids the viewer may handle")
  attr(:filter_type, :string, default: "all")
  attr(:filter_confidence, :string, default: "any")
  attr(:reject_for, :any, default: nil)
  attr(:reroute_for, :any, default: nil)
  attr(:edit_for, :any, default: nil)
  attr(:people, :list, default: [])
  attr(:names, :map, default: %{})
  attr(:now, :any, default: nil)

  def insights_pane(assigns) do
    assigns =
      assigns
      |> assign(:p, if(assigns.surface == :mobile, do: "m-", else: ""))
      |> assign(:handle_ids, assigns.handle_ids || MapSet.new())
      |> assign(:now, assigns.now || DateTime.utc_now())
      |> assign(:off_notice_lead, @off_notice_lead)

    ~H"""
    <div
      class={[
        "flex flex-col",
        @surface == :desktop && "flex-1 overflow-hidden",
        @surface == :mobile && "min-h-0 flex-1"
      ]}
      data-role="insights-pane"
      data-surface={@surface}
    >
      <div class={[
        "border-b border-edge",
        if(@surface == :desktop, do: "px-6 py-3", else: "px-3 py-2")
      ]}>
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h1 :if={@surface == :desktop} class="text-lg font-bold">Insights</h1>
          <form
            id={@p <> "insight-delivery-form"}
            phx-change="insight_toggle_delivery"
            class="flex min-h-11 items-center gap-2 text-sm"
            data-role="insight-opt-out"
          >
            <input type="hidden" name="receive" value="false" />
            <label class="flex cursor-pointer items-center gap-2">
              <span class="text-base-content/70">Insight briefings and questions</span>
              <input
                type="checkbox"
                name="receive"
                value="true"
                checked={@receives?}
                class="toggle toggle-sm"
                aria-label="Insight briefings and questions"
              />
            </label>
          </form>
        </div>
        <form
          id={@p <> "insight-filter-form"}
          phx-change="insight_filter"
          class="mt-2 flex flex-wrap items-center gap-2 text-sm"
          data-role="insight-filters"
        >
          <span class="text-xs text-subtle">Filter:</span>
          <select
            name="type"
            class="select select-sm min-h-11 w-auto sm:min-h-0"
            aria-label="Insight type"
          >
            <option
              :for={{value, label} <- type_options()}
              value={value}
              selected={value == @filter_type}
            >
              {label}
            </option>
          </select>
          <select
            name="confidence"
            class="select select-sm min-h-11 w-auto sm:min-h-0"
            aria-label="Confidence"
          >
            <option
              :for={{value, label} <- confidence_options()}
              value={value}
              selected={value == @filter_confidence}
            >
              {label}
            </option>
          </select>
        </form>
      </div>

      <div class={[@surface == :desktop && "flex-1 overflow-y-auto"]}>
        <p
          :if={not @dissemination_on}
          class={[
            "border-b border-edge text-sm text-base-content/70",
            if(@surface == :desktop, do: "px-6 py-2", else: "px-3 py-2")
          ]}
          data-role="insights-off-notice"
        >
          {@off_notice_lead}
          <%= if @admin? do %>
            <.link navigate="/admin/insights" class="link font-medium">Settings</.link>.
          <% else %>
            Settings.
          <% end %>
        </p>

        <div class={if(@surface == :desktop, do: "space-y-3 px-6 py-4", else: "space-y-3 px-3 py-3")}>
          <%= if @insights == [] do %>
            <div
              class="rounded-xl border border-edge bg-base-100 p-6 text-center"
              data-role="insights-empty-state"
            >
              <span class="hero-light-bulb mx-auto mb-2 block size-10 text-subtle"></span>
              <p class="text-sm font-medium text-base-content/70">
                Nothing open. Dreaming has nothing for you to act on right now.
              </p>
            </div>
          <% else %>
            <.insight_row
              :for={insight <- @insights}
              insight={insight}
              p={@p}
              may_handle?={MapSet.member?(@handle_ids, insight.id)}
              rejecting?={@reject_for == insight.id}
              rerouting?={@reroute_for == insight.id}
              editing?={@edit_for == insight.id}
              people={@people}
              names={@names}
              now={@now}
            />
          <% end %>

          <section
            :if={@dissemination_on}
            class="pt-2"
            data-role="insights-already-done"
          >
            <h2 class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content">
              Already done
            </h2>
            <p :if={@done == []} class="text-sm text-subtle">
              Nothing has been applied yet.
            </p>
            <div
              :for={insight <- @done}
              class="mb-2 rounded-xl border border-info/40 bg-info/10 p-3"
              data-role="insight-done-row"
              data-insight-id={insight.id}
            >
              <div class="flex flex-wrap items-center gap-2">
                <span class="min-w-0 flex-1 text-sm font-medium text-base-content">
                  {InsightPreview.sentence(insight)}
                </span>
                <span class="font-mono text-xs text-subtle">
                  {InsightPreview.type_label(insight.action_type)}
                </span>
              </div>
              <div class="mt-1 flex flex-wrap items-center justify-between gap-2">
                <span class="text-xs text-base-content/70" data-role="insight-done-status">
                  {done_status(insight)}
                </span>
                <button
                  :if={revertible?(insight)}
                  type="button"
                  phx-click="insight_revert"
                  phx-value-id={insight.id}
                  class="btn btn-sm btn-outline btn-info min-h-11 sm:min-h-0"
                  data-role="insight-revert"
                >
                  Revert
                </button>
              </div>
            </div>
          </section>
        </div>
      </div>
    </div>
    """
  end

  attr(:insight, :map, required: true)
  attr(:p, :string, required: true)
  attr(:may_handle?, :boolean, default: false)
  attr(:rejecting?, :boolean, default: false)
  attr(:rerouting?, :boolean, default: false)
  attr(:editing?, :boolean, default: false)
  attr(:people, :list, default: [])
  attr(:names, :map, default: %{})
  attr(:now, :any, required: true)

  defp insight_row(assigns) do
    assigns =
      assigns
      |> assign(:needs_call?, assigns.insight.tier == "needs_call")
      |> assign(:days_left, days_left(assigns.insight, assigns.now))

    ~H"""
    <article
      id={@p <> "insight-row-" <> @insight.id}
      class={[
        "rounded-xl border p-3",
        if(@needs_call?,
          do: "border-warning/60 bg-warning/5",
          else: "border-edge bg-base-100"
        )
      ]}
      data-role="insight-row"
      data-insight-id={@insight.id}
      data-tier={@insight.tier}
    >
      <p
        :if={@needs_call?}
        class="mb-1 flex items-center gap-1 text-xs font-semibold text-warning"
        data-role="insight-needs-call"
      >
        <span class="hero-exclamation-triangle size-4 text-warning"></span> Needs your call
      </p>
      <p class="font-medium text-base-content" data-role="insight-sentence">
        {InsightPreview.sentence(@insight)}
      </p>
      <p class="mt-0.5 text-sm text-subtle" data-role="insight-evidence">
        Evidence: {evidence(@insight)} · {@insight.confidence}
      </p>
      <div class="mt-1 flex items-center justify-between gap-2">
        <span class="font-mono text-xs text-base-content/70" data-role="insight-type-label">
          {InsightPreview.type_label(@insight.action_type)}
        </span>
        <span
          class={[
            "font-mono text-xs",
            if(@days_left <= 1, do: "font-semibold text-warning", else: "text-subtle")
          ]}
          data-role="insight-expiry"
          data-last-day={to_string(@days_left <= 1)}
        >
          {@days_left}d left
        </span>
      </div>

      <InsightPreview.preview insight={@insight} names={@names} />

      <%= if @may_handle? do %>
        <div class="mt-3 flex flex-wrap justify-end gap-2" data-role="insight-actions">
          <button
            type="button"
            phx-click="insight_dismiss"
            phx-value-id={@insight.id}
            class="btn btn-ghost btn-sm min-h-11 sm:min-h-0"
            data-role="insight-dismiss"
          >
            Dismiss
          </button>
          <button
            type="button"
            phx-click="insight_show_reject"
            phx-value-id={@insight.id}
            class="btn btn-ghost btn-sm min-h-11 sm:min-h-0"
            data-role="insight-reject"
          >
            Reject
          </button>
          <button
            type="button"
            phx-click="insight_show_reroute"
            phx-value-id={@insight.id}
            class="btn btn-ghost btn-sm min-h-11 sm:min-h-0"
            data-role="insight-reroute-button"
          >
            Reroute
          </button>
          <button
            type="button"
            phx-click="insight_show_edit"
            phx-value-id={@insight.id}
            class="btn btn-ghost btn-sm min-h-11 sm:min-h-0"
            data-role="insight-edit-button"
          >
            Edit
          </button>
          <button
            type="button"
            phx-click="insight_act"
            phx-value-id={@insight.id}
            class="btn btn-primary btn-sm min-h-11 sm:min-h-0"
            data-role="insight-primary"
          >
            {InsightPreview.primary_label(@insight.action_type)}
          </button>
        </div>
      <% else %>
        <p class="mt-3 text-xs text-subtle" data-role="insight-no-actions">
          An install admin decides this one.
        </p>
      <% end %>

      <form
        :if={@may_handle? and @rejecting?}
        id={@p <> "insight-reject-form-" <> @insight.id}
        phx-submit="insight_reject"
        class="mt-3 rounded-lg border border-edge bg-base-200/40 p-3"
        data-role="insight-reject-form"
      >
        <input type="hidden" name="_id" value={@insight.id} />
        <label
          class="block text-sm font-medium text-base-content"
          for={@p <> "insight-reason-" <> @insight.id}
        >
          Why is this wrong?
        </label>
        <p class="text-xs text-subtle">
          Required. Your reason is kept and used to teach dreaming.
        </p>
        <textarea
          id={@p <> "insight-reason-" <> @insight.id}
          name="reason"
          rows="2"
          required
          class="textarea textarea-bordered mt-2 w-full text-sm"
        ></textarea>
        <div class="mt-2 flex justify-end gap-2">
          <button
            type="button"
            phx-click="insight_cancel_form"
            class="btn btn-ghost btn-sm min-h-11 sm:min-h-0"
          >
            Cancel
          </button>
          <button type="submit" class="btn btn-neutral btn-sm min-h-11 sm:min-h-0">
            Reject
          </button>
        </div>
      </form>

      <form
        :if={@may_handle? and @rerouting?}
        id={@p <> "insight-reroute-form-" <> @insight.id}
        phx-submit="insight_reroute"
        class="mt-3 rounded-lg border border-edge bg-base-200/40 p-3"
        data-role="insight-reroute"
      >
        <input type="hidden" name="_id" value={@insight.id} />
        <label
          class="block text-sm font-medium text-base-content"
          for={@p <> "insight-addressee-" <> @insight.id}
        >
          Send to
        </label>
        <p class="text-xs text-subtle" data-role="insight-reroute-reason">
          Suggested: {InsightPreview.addressee_name(@insight, @names)} ({@insight.addressee_reason ||
            "unrouted"})
        </p>
        <select
          id={@p <> "insight-addressee-" <> @insight.id}
          name="addressee"
          class="select select-sm mt-2 min-h-11 w-full sm:min-h-0"
        >
          <option value="" disabled selected={is_nil(@insight.addressee_user_id)}>
            Choose a person
          </option>
          <option
            :for={person <- @people}
            value={person.id}
            selected={person.id == @insight.addressee_user_id}
          >
            {person.name || person.email}
          </option>
        </select>
        <div class="mt-2 flex justify-end gap-2">
          <button
            type="button"
            phx-click="insight_cancel_form"
            class="btn btn-ghost btn-sm min-h-11 sm:min-h-0"
          >
            Cancel
          </button>
          <button type="submit" class="btn btn-neutral btn-sm min-h-11 sm:min-h-0">
            Reroute
          </button>
        </div>
      </form>

      <form
        :if={@may_handle? and @editing?}
        id={@p <> "insight-edit-form-" <> @insight.id}
        phx-submit="insight_edit"
        class="mt-3 rounded-lg border border-edge bg-base-200/40 p-3"
        data-role="insight-edit-form"
      >
        <input type="hidden" name="_id" value={@insight.id} />
        <label
          class="block text-sm font-medium text-base-content"
          for={@p <> "insight-body-" <> @insight.id}
        >
          Insight
        </label>
        <textarea
          id={@p <> "insight-body-" <> @insight.id}
          name="body"
          rows="3"
          class="textarea textarea-bordered mt-1 w-full text-sm"
        >{@insight.body}</textarea>
        <%= for {{old, new}, index} <- Enum.with_index(InsightPreview.hunks(@insight)) do %>
          <input type="hidden" name={"hunks[#{index}][old]"} value={old} />
          <label class="mt-2 block text-xs font-medium text-base-content/70">
            Replacement text {index + 1}
          </label>
          <textarea
            name={"hunks[#{index}][new]"}
            rows="2"
            class="textarea textarea-bordered mt-1 w-full font-mono text-xs"
          >{new}</textarea>
        <% end %>
        <div class="mt-2 flex justify-end gap-2">
          <button
            type="button"
            phx-click="insight_cancel_form"
            class="btn btn-ghost btn-sm min-h-11 sm:min-h-0"
          >
            Cancel
          </button>
          <button type="submit" class="btn btn-neutral btn-sm min-h-11 sm:min-h-0">
            Save
          </button>
        </div>
      </form>
    </article>
    """
  end

  @doc "Whole days left before an insight expires, rounded up; 0 when it has passed."
  @spec days_left(map(), DateTime.t()) :: non_neg_integer()
  def days_left(%{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    seconds = DateTime.diff(expires_at, now, :second)
    if seconds <= 0, do: 0, else: div(seconds + 86_399, 86_400)
  end

  def days_left(_insight, _now), do: 0

  defp evidence(%{evidence: evidence}) when is_binary(evidence) and evidence != "", do: evidence
  defp evidence(%{source_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp evidence(_insight), do: "none cited"

  defp revertible?(%{action_type: "page_edit", state: "done", pre_image: %{"file_key" => _}}),
    do: true

  defp revertible?(_insight), do: false

  @doc false
  def done_status(insight) do
    time =
      case insight.acted_at do
        %DateTime{} = at -> Calendar.strftime(at, "%H:%M")
        _ -> "--:--"
      end

    if revertible?(insight), do: "Applied #{time} · revertible", else: "Applied #{time}"
  end

  @doc false
  def type_options do
    [
      {"all", "All types"},
      {"page_edit", "Page edits"},
      {"question", "Questions"},
      {"briefing", "Briefings"},
      {"task", "Tasks"}
    ]
  end

  @doc false
  def confidence_options, do: [{"any", "Any confidence"}, {"high", "High confidence"}]
end
