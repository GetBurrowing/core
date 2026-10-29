defmodule PlatformWeb.InboxLive.MeetingBriefingComponent do
  @moduledoc """
  A concluded meeting's briefing in the Inbox's detail pane (task 01a1694a
  stage 4), mounted by `PlatformWeb.InboxLive` on
  `/inbox/meeting/:meeting_id`.

  ## One way in

  The briefing loads ONLY through
  `Platform.Meetings.MeetingBriefings.get_for_attendee/2`, whose attendee
  check is in the query. When it answers nil — a non-attendee, a meeting id
  that names no briefing, a malformed id — this renders the same
  "There's no briefing here." for every case, so the page is no oracle for
  whether a meeting exists.

  ## What it renders

  `MeetingBriefings.view/2` is the only read. Sections, in order, each
  hidden when empty: Summary (or "Summary unavailable"), Open (with
  Revert / Ask for tasks), Resolved ("Reverted by Ada · 14:05"), Open
  questions, Action items not filed, and the Transcript link. Every word
  comes from `PlatformWeb.InboxLive.MeetingBriefingCopy`.

  ## Synthesis findings (task 01a16974 stage 5)

  An item of kind `"finding"` renders its label ("Alignment needed",
  "Possible duplicate", "Contradicts a decision", "Related work"), its
  body, and its citations as links, with Seek alignment / Looks right /
  Not a conflict (Revert first when `view/2` offers it). The citations are
  exactly those `view/2` gives, which drops a finding whose citations the
  viewer cannot all read, so nothing here filters again. Resolved, it
  reads "Aligned by <name>" / "Dismissed by <name>" from the finding's
  shared receipt, which every briefing carrying it shows.

  ## Every button goes through `MeetingBriefings.act/5`

  With a Scope rebuilt from the user row on EVERY click (`scope/1`), never
  kept from mount. Ask opens an inline textarea under the card, not a
  sheet. A stale click — the item was resolved by someone else first —
  comes back `{:error, :already_resolved, briefing}`; the card re-renders
  from that briefing as resolved and says "Already handled by <name>".
  Other refusals stay on the card, under its buttons.

  ## Live

  `PlatformWeb.InboxLive` `send_update/3`s this component with
  `reload: true` on every `{:inbox_changed, _}`, and `act/5` broadcasts
  that to every attendee: when A resolves an item, B's open detail
  repaints it as resolved, with no buttons, without a reload.
  """

  use PlatformWeb, :live_component

  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Meetings.MeetingBriefing
  alias Platform.Meetings.MeetingBriefings
  alias PlatformWeb.InboxLive.MeetingBriefingCopy, as: Copy

  # The daily briefing's button and field classes
  # (`PlatformWeb.InboxLive.BriefingComponent`), so the two details read as
  # one surface: 44px tall below lg, the compact `btn-sm` height from lg up.
  @btn "btn btn-sm min-h-11 focus-visible-ring lg:min-h-0"
  @btn_primary @btn <> " btn-primary"
  @btn_secondary @btn <> " border-edge bg-base-300 text-base-content"
  @btn_ghost @btn <> " btn-ghost text-subtle lg:hover:text-base-content"
  @field "w-full rounded-lg border border-edge bg-base-200 px-3 py-2 text-sm text-base-content placeholder:text-subtle"
  @link "focus-visible-ring rounded font-semibold text-interactive"

  # ── Lifecycle ─────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:asking, MapSet.new())
     |> assign(:blank, MapSet.new())
     |> assign(:errors, %{})
     |> assign(:notices, %{})
     |> assign(:view, nil)}
  end

  @impl true
  def update(%{reload: true}, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(Map.take(assigns, [:id, :meeting_id, :user_id, :time_zone, :item_key]))
     |> load()}
  end

  defp load(socket) do
    %{meeting_id: meeting_id, user_id: user_id} = socket.assigns

    case MeetingBriefings.get_for_attendee(meeting_id, user_id) do
      %MeetingBriefing{} = briefing -> assign_view(socket, briefing)
      nil -> assign(socket, :view, nil)
    end
  end

  defp assign_view(socket, %MeetingBriefing{} = briefing) do
    view = MeetingBriefings.view(briefing, scope(socket))
    open = MapSet.new(view.open, & &1.key)

    socket
    |> assign(:briefing, briefing)
    |> assign(:view, view)
    |> update(:asking, &MapSet.intersection(&1, open))
    |> update(:blank, &MapSet.intersection(&1, open))
    |> update(:errors, &Map.filter(&1, fn {key, _} -> MapSet.member?(open, key) end))
  end

  # Rebuilt per click from the user row: never the Scope built at mount.
  defp scope(socket) do
    case Accounts.get_user(socket.assigns.user_id) do
      nil -> Scope.for_user(nil)
      user -> Scope.for_user(user)
    end
  end

  # ── Events ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("ask_open", %{"key" => key}, socket),
    do: {:noreply, update(socket, :asking, &MapSet.put(&1, key))}

  def handle_event("ask_close", %{"key" => key}, socket) do
    {:noreply,
     socket
     |> update(:asking, &MapSet.delete(&1, key))
     |> update(:blank, &MapSet.delete(&1, key))}
  end

  def handle_event("act", %{"key" => key, "verb" => verb} = params, socket)
      when verb in ~w(revert confirm ask align dismiss) do
    case socket.assigns[:briefing] do
      %MeetingBriefing{} = briefing ->
        verb = String.to_existing_atom(verb)
        params = Map.take(params, ["question"])
        result = MeetingBriefings.act(briefing, key, verb, scope(socket), params)
        {:noreply, after_act(socket, key, verb, result)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("act", _params, socket), do: {:noreply, socket}

  defp after_act(socket, key, _verb, {:ok, briefing}) do
    socket
    |> update(:errors, &Map.delete(&1, key))
    |> update(:blank, &MapSet.delete(&1, key))
    |> assign_view(briefing)
  end

  defp after_act(socket, key, _verb, {:error, :already_resolved, %MeetingBriefing{} = briefing}) do
    socket = assign_view(socket, briefing)
    by = Enum.find(socket.assigns.view.resolved, &(&1.key == key))
    name = by && by.receipt && by.receipt.by_name
    update(socket, :notices, &Map.put(&1, key, Copy.already_handled(name)))
  end

  defp after_act(socket, key, _verb, {:error, :blank}),
    do: socket |> update(:blank, &MapSet.put(&1, key)) |> update(:asking, &MapSet.put(&1, key))

  defp after_act(socket, key, verb, {:error, reason}),
    do: update(socket, :errors, &Map.put(&1, key, Copy.error_text(reason, verb)))

  # ── Render ────────────────────────────────────────────────────────────

  @impl true
  def render(%{view: nil} = assigns) do
    ~H"""
    <div id={@id} class="py-10 text-center text-sm text-subtle" data-role="meeting-briefing-not-found">
      {Copy.not_found()}
    </div>
    """
  end

  def render(%{item_key: key} = assigns) when is_binary(key) do
    assigns =
      assign(
        assigns,
        :item,
        case Enum.find(assigns.view.open ++ assigns.view.resolved, &(&1.key == key)) do
          nil -> nil
          item -> Map.put(item, :dom_key, assigns.id <> "-" <> item.key)
        end
      )

    ~H"""
    <div id={@id} data-role="meeting-briefing-task" data-meeting-id={@meeting_id}>
      <.open_card
        :if={@item && is_nil(@item.receipt)}
        item={@item}
        myself={@myself}
        asking?={MapSet.member?(@asking, @item.key)}
        blank?={MapSet.member?(@blank, @item.key)}
        error={Map.get(@errors, @item.key)}
      />
      <.resolved_card
        :if={@item && @item.receipt}
        item={@item}
        time_zone={@time_zone}
        notice={Map.get(@notices, @item.key)}
        transcript_url={@view.transcript_url}
      />
      <p :if={is_nil(@item)} class="text-sm text-subtle">This task is unavailable.</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id={@id} data-role="meeting-briefing-detail" data-meeting-id={@view.meeting.id}>
      <header>
        <p class="text-xs font-medium uppercase tracking-wide text-subtle">
          {Copy.kind_label()}
        </p>
        <h2 class="mt-1 text-2xl font-bold text-base-content" data-role="meeting-briefing-title">
          {@view.meeting.name}
        </h2>
        <p class="mt-1 text-sm text-subtle" data-role="meeting-briefing-meta">
          {Copy.ended(@view.meeting.ended_at, @time_zone)} · {Copy.receipt_line(@view.counts)}
        </p>
      </header>

      <p
        :for={part <- Enum.reject(Map.get(@view, :missing_prerequisites, []), &(&1 == "summary"))}
        class="mt-3 text-sm text-subtle"
        data-role="meeting-briefing-missing-part"
      >
        {Copy.missing_part(part)}
      </p>

      <section class="mt-6" data-role="meeting-briefing-summary">
        <h3 class={heading_class()}>{Copy.heading(:summary)}</h3>
        <p
          :if={summary_available?(@view)}
          class="whitespace-pre-line text-sm text-base-content"
          data-role="meeting-briefing-summary-text"
          phx-no-format
        >{String.trim(@view.summary)}</p>
        <p
          :if={!summary_available?(@view)}
          class="text-sm text-subtle"
          data-role="meeting-briefing-summary-pending"
        >
          {Copy.summary_pending()}
        </p>
      </section>

      <section :if={@view.open != []} class="mt-6" data-role="meeting-briefing-open">
        <h3 class={heading_class()}>{Copy.heading(:open)}</h3>
        <ul role="list" class="space-y-3">
          <li :for={item <- @view.open}>
            <.open_card
              item={item}
              myself={@myself}
              asking?={MapSet.member?(@asking, item.key)}
              blank?={MapSet.member?(@blank, item.key)}
              error={Map.get(@errors, item.key)}
            />
          </li>
        </ul>
      </section>

      <section :if={@view.resolved != []} class="mt-6" data-role="meeting-briefing-resolved">
        <h3 class={heading_class()}>{Copy.heading(:resolved)}</h3>
        <ul role="list" class="space-y-3">
          <li :for={item <- @view.resolved}>
            <.resolved_card
              item={item}
              time_zone={@time_zone}
              notice={Map.get(@notices, item.key)}
              transcript_url={@view.transcript_url}
            />
          </li>
        </ul>
      </section>

      <section :if={@view.open_questions != []} class="mt-6" data-role="meeting-briefing-questions">
        <h3 class={heading_class()}>{Copy.heading(:open_questions)}</h3>
        <ul role="list" class="list-disc space-y-1 pl-5 text-sm text-base-content">
          <li :for={q <- @view.open_questions}>{q["text"]}</li>
        </ul>
      </section>

      <section
        :if={@view.unfiled_action_items != []}
        class="mt-6"
        data-role="meeting-briefing-unfiled"
      >
        <h3 class={heading_class()}>{Copy.heading(:unfiled)}</h3>
        <ul role="list" class="list-disc space-y-1 pl-5 text-sm text-base-content">
          <li :for={a <- @view.unfiled_action_items}>{a["text"]}</li>
        </ul>
      </section>

      <section class="mt-6" data-role="meeting-briefing-transcript">
        <h3 class={heading_class()}>{Copy.heading(:transcript)}</h3>
        <.link
          navigate={@view.transcript_url}
          class={["inline-flex min-h-11 items-center text-sm lg:min-h-0", link()]}
          data-role="meeting-briefing-transcript-link"
        >
          Open the meeting and its transcript
        </.link>
      </section>
    </div>
    """
  end

  attr(:item, :map, required: true)
  attr(:myself, :any, required: true)
  attr(:asking?, :boolean, required: true)
  attr(:blank?, :boolean, required: true)
  attr(:error, :string, default: nil)

  defp open_card(assigns) do
    ~H"""
    <article
      id={"meeting-briefing-item-" <> dom_key(@item)}
      class="rounded-xl border border-edge bg-base-100 px-4 py-3.5"
      data-role="meeting-briefing-card"
      data-key={@item.key}
      data-kind={@item.kind}
    >
      <.finding :if={@item[:finding]} finding={@item.finding} dom_key={dom_key(@item)} />
      <p
        :if={!@item[:finding]}
        class="mb-1 text-xs font-bold uppercase tracking-wide text-subtle"
      >
        {Copy.kind_tag(@item.kind)}
      </p>
      <h4
        :if={!@item[:finding]}
        class="text-base font-semibold text-base-content"
        data-role="meeting-briefing-card-title"
      >
        {@item.title}
      </h4>

      <p
        :if={@item.availability}
        class="mt-1 text-sm text-subtle"
        data-role="meeting-task-availability"
      >
        {@item.availability}
      </p>
      <div class="mt-3 flex flex-wrap items-center gap-2" data-role="meeting-briefing-actions">
        <button
          :for={action <- @item.actions}
          type="button"
          class={button_class(action, @item.kind)}
          phx-click={if(action == :ask, do: "ask_open", else: "act")}
          phx-value-key={@item.key}
          phx-value-verb={action}
          phx-target={@myself}
          data-role="meeting-briefing-action"
          data-action={action}
        >
          {Copy.action_label(action)}
        </button>
      </div>

      <form
        :if={@asking?}
        id={"meeting-briefing-ask-" <> dom_key(@item)}
        phx-submit="act"
        phx-target={@myself}
        class="mt-3"
        data-role="meeting-briefing-ask-form"
      >
        <input type="hidden" name="key" value={@item.key} />
        <input type="hidden" name="verb" value="ask" />
        <label
          class="mb-1 block text-xs text-subtle"
          for={"meeting-briefing-question-" <> dom_key(@item)}
        >
          Your question, posted in the meeting's chat
        </label>
        <textarea
          id={"meeting-briefing-question-" <> dom_key(@item)}
          name="question"
          rows="2"
          class={field()}
          placeholder={Copy.ask_placeholder(@blank?)}
          data-role="meeting-briefing-question"
        ></textarea>
        <p
          :if={@blank?}
          class="mt-1 text-xs text-base-content"
          data-role="meeting-briefing-blank-hint"
        >
          {Copy.ask_placeholder(true)}
        </p>
        <div class="mt-2 flex flex-wrap gap-2">
          <button type="submit" class={btn_secondary()} data-role="meeting-briefing-ask-submit">
            Post question
          </button>
          <button
            type="button"
            class={btn_ghost()}
            phx-click="ask_close"
            phx-value-key={@item.key}
            phx-target={@myself}
          >
            Cancel
          </button>
        </div>
      </form>

      <p
        :if={@error}
        role="alert"
        class="mt-2 flex items-center gap-1.5 text-sm text-base-content"
        data-role="meeting-briefing-card-error"
      >
        <span class="hero-exclamation-circle size-4 shrink-0 text-error" aria-hidden="true"></span>
        {@error}
      </p>
    </article>
    """
  end

  attr(:item, :map, required: true)
  attr(:time_zone, :string, default: nil)
  attr(:notice, :string, default: nil)
  attr(:transcript_url, :string, required: true)

  defp resolved_card(assigns) do
    {lead, time} = Copy.receipt(assigns.item.receipt, assigns.time_zone)
    assigns = assigns |> assign(:lead, lead) |> assign(:time, time)

    ~H"""
    <article
      id={"meeting-briefing-item-" <> dom_key(@item)}
      class="rounded-xl border border-edge bg-base-100 px-4 py-3.5"
      data-role="meeting-briefing-resolved-card"
      data-key={@item.key}
      data-kind={@item.kind}
    >
      <.finding :if={@item[:finding]} finding={@item.finding} dom_key={dom_key(@item)} />
      <p
        :if={!@item[:finding]}
        class="mb-1 text-xs font-bold uppercase tracking-wide text-subtle"
      >
        {Copy.kind_tag(@item.kind)}
      </p>
      <p :if={!@item[:finding]} class="text-sm font-semibold text-base-content">{@item.title}</p>
      <p class="mt-1 text-sm text-subtle" data-role="meeting-briefing-receipt">
        <span class="font-semibold text-base-content" data-role="meeting-briefing-receipt-lead">
          {@lead}
        </span>
        <span :if={@time != ""} data-role="meeting-briefing-receipt-time">· {@time}</span>
      </p>
      <%!-- On its own line, with the transcript link's touch target: 44px tall
           below lg (the phone rule), the compact inline height from lg up. --%>
      <.link
        :if={@item.receipt.verb == "asked"}
        navigate={@transcript_url}
        class={["inline-flex min-h-11 items-center text-sm lg:min-h-0", link()]}
        data-role="meeting-briefing-receipt-link"
      >
        See the question
      </.link>
      <p
        :if={@notice}
        role="status"
        class="mt-2 flex items-center gap-1.5 text-sm text-base-content"
        data-role="meeting-briefing-notice"
      >
        <span class="hero-information-circle size-4 shrink-0 text-interactive" aria-hidden="true">
        </span>
        {@notice}
      </p>
    </article>
    """
  end

  attr(:finding, :map, required: true)
  attr(:dom_key, :string, required: true)

  # A synthesis finding (task 01a16974 stage 5): its label, its body, and
  # its citations. Every citation here is one the viewer can read:
  # `MeetingBriefings.view/2` drops the whole item otherwise. A citation
  # links only to an internal path; anything else is plain text.
  defp finding(assigns) do
    ~H"""
    <p
      class="mb-1 flex items-center gap-1.5 text-xs font-bold uppercase tracking-wide text-subtle"
      data-role="meeting-briefing-finding-label"
      data-finding-kind={@finding.kind}
    >
      <span class={[finding_icon(@finding.kind), "size-4 shrink-0"]} aria-hidden="true"></span>
      {Copy.finding_label(@finding.kind)}
    </p>
    <p
      class="whitespace-pre-line text-base font-semibold text-base-content"
      data-role="meeting-briefing-finding-body"
      phx-no-format
    >{@finding.body}</p>
    <div :if={@finding.citations != []} class="mt-2" data-role="meeting-briefing-citations">
      <p
        class="text-xs font-medium uppercase tracking-wide text-subtle"
        id={"meeting-briefing-citations-" <> @dom_key}
      >
        {Copy.citations_heading()}
      </p>
      <ul
        role="list"
        class="mt-1 space-y-1 text-sm"
        aria-labelledby={"meeting-briefing-citations-" <> @dom_key}
      >
        <li
          :for={citation <- @finding.citations}
          data-role="meeting-briefing-citation"
          data-ref={citation.ref}
        >
          <.link
            :if={internal_path?(citation.url)}
            navigate={citation.url}
            class={["inline-flex min-h-11 items-center lg:min-h-0", link()]}
            data-role="meeting-briefing-citation-link"
          >
            {citation_title(citation)}
          </.link>
          <span :if={!internal_path?(citation.url)} class="text-base-content">
            {citation_title(citation)}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  defp finding_icon("conflicts_with"), do: "hero-arrows-right-left"
  defp finding_icon("duplicates"), do: "hero-document-duplicate"
  defp finding_icon("contradicts"), do: "hero-exclamation-triangle"
  defp finding_icon(_), do: "hero-link"

  defp citation_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp citation_title(_citation), do: "Source"

  # Only a same-origin path: never `//host`, a scheme, or a model-written url.
  defp internal_path?("/" <> rest), do: not String.starts_with?(rest, ["/", "\\"])
  defp internal_path?(_url), do: false

  defp present?(text), do: is_binary(text) and String.trim(text) != ""

  # A daily briefing may reference one shared task more than once. The
  # server key stays canonical; only DOM ids belong to this component instance.
  defp dom_key(item), do: Map.get(item, :dom_key, item.key)

  defp heading_class, do: "mb-2 text-xs font-bold uppercase tracking-wider text-subtle"

  # A finding's lead action is Seek alignment; Looks right is secondary.
  defp button_class(:align, "finding"), do: @btn_primary
  defp button_class(:confirm, "finding"), do: @btn_secondary
  defp button_class(:revert, _kind), do: @btn_secondary
  defp button_class(:confirm, _kind), do: @btn_primary
  defp button_class(_action, _kind), do: @btn_ghost

  defp btn_secondary, do: @btn_secondary
  defp btn_ghost, do: @btn_ghost
  defp field, do: @field
  defp link, do: @link

  defp summary_available?(view),
    do: present?(view.summary) and "summary" not in Map.get(view, :missing_prerequisites, [])
end
