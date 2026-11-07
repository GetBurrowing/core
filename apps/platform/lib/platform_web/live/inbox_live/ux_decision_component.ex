defmodule PlatformWeb.InboxLive.UxDecisionComponent do
  @moduledoc """
  The UX role's question, open in the Inbox's detail pane (task 01a1af00
  stage 3, design canvas `01a1b684-c1dd` node `layout`, "Open item").
  Mounted by `PlatformWeb.InboxLive` on `/inbox/ux/:finding_id`; modelled
  on `PlatformWeb.InboxLive.BriefingComponent`.

  ## One way in

  The finding loads ONLY through `Platform.Ux.Decisions.get_for_recipient/2`
  (id AND recipient in the query). Anything else, another person's finding
  or a malformed id included, renders the same "There's no question here."

  ## What it renders, in order

    * the `UX` chip and the time;
    * the question as the title (never truncated);
    * the evidence line, "Seen N× this week across M channels", with at most
      two short quotes, collapsed. "show the messages" expands to the source
      messages the viewer can read, each with a link into chat;
    * the mockup, when the finding carries one: before | after on a
      `bg-base-200` mat, side by side from `lg`, a horizontal swipe (CSS
      scroll-snap) on a phone. Each image is an attachment link carrying
      `data-image-viewer`, so a tap opens the shared image viewer
      (`assets/js/lib/image_layer.js`), which closes with back, Escape,
      swipe-down or its X. No second viewer is built here;
    * at most three answers (`Decisions.answers/1`): EXACTLY one primary,
      "Build it", labelled "Recommended"; "Try the other option" secondary;
      "Not now" ghost. Never approve / reject;
    * an optional note.

  No severity badge.

  ## Answering

  Every answer goes through `Decisions.answer/4`, which records it on the
  finding, dismisses the Inbox row and posts the outcome to the linked
  task. On success this sends `{:ux_answered, %{message: ...}}` to the
  parent, which raises its toast and returns to `/inbox`. A stale click
  (answered on another tab first) re-renders as answered.
  """

  use PlatformWeb, :live_component

  import PlatformWeb.Components.UxDecisionRow, only: [ux_chip: 1]

  alias Platform.Ux.Decisions
  alias Platform.Ux.Finding
  alias PlatformWeb.Components.InboxItem

  @btn "btn btn-sm min-h-11 focus-visible-ring lg:min-h-0"
  @btn_primary @btn <> " btn-primary"
  @btn_secondary @btn <> " border-edge bg-base-300 text-base-content"
  @btn_ghost @btn <> " btn-ghost text-subtle lg:hover:text-base-content"

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:finding, nil)
     |> assign(:show_messages, false)
     |> assign(:notice, nil)
     |> assign(:form, note_form(""))
     |> stream_configure(:messages, dom_id: &"ux-source-#{&1.id}")
     |> stream(:messages, [])}
  end

  @impl true
  def update(%{reload: _} = _assigns, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    {:ok, socket |> assign(Map.take(assigns, [:id, :finding_id, :user_id])) |> load()}
  end

  defp load(socket) do
    finding = Decisions.get_for_recipient(socket.assigns.finding_id, socket.assigns.user_id)
    socket = assign(socket, :finding, finding)

    if socket.assigns.show_messages, do: load_messages(socket), else: socket
  end

  defp load_messages(%{assigns: %{finding: %Finding{} = finding, user_id: user_id}} = socket) do
    stream(socket, :messages, Decisions.source_messages(finding, user_id), reset: true)
  end

  defp load_messages(socket), do: stream(socket, :messages, [], reset: true)

  defp note_form(note), do: to_form(%{"note" => note}, as: :ux_answer)

  @impl true
  def handle_event("toggle_messages", _params, socket) do
    socket = update(socket, :show_messages, &(!&1))

    socket =
      if socket.assigns.show_messages,
        do: load_messages(socket),
        else: stream(socket, :messages, [], reset: true)

    {:noreply, socket}
  end

  def handle_event("note", %{"ux_answer" => %{"note" => note}}, socket) do
    {:noreply, assign(socket, :form, note_form(note))}
  end

  def handle_event("note", _params, socket), do: {:noreply, socket}

  def handle_event("answer", %{"choice" => choice}, socket) do
    note = socket.assigns.form.params["note"]

    case Decisions.answer(socket.assigns.finding_id, socket.assigns.user_id, choice, note) do
      {:ok, finding} ->
        send(self(), {:ux_answered, %{message: toast_message(finding)}})
        {:noreply, socket |> assign(:finding, finding) |> assign(:notice, nil)}

      {:error, :already_answered} ->
        {:noreply, socket |> load() |> assign(:notice, "Already answered.")}

      {:error, _reason} ->
        {:noreply, socket |> load() |> assign(:notice, "That answer didn't go through.")}
    end
  end

  defp toast_message(%Finding{status: "dismissed"}), do: "Not now. Cleared from your Inbox."
  defp toast_message(%Finding{}), do: "Answer sent to the task."

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        btn_primary: @btn_primary,
        btn_secondary: @btn_secondary,
        btn_ghost: @btn_ghost
      )

    ~H"""
    <div id={@id} data-role="ux-decision-detail">
      <div
        :if={is_nil(@finding)}
        class="py-10 text-center text-sm text-subtle"
        data-role="ux-decision-not-found"
      >
        There's no question here.
      </div>

      <article
        :if={@finding}
        class="rounded-2xl border border-edge bg-base-100 p-4 lg:p-5"
        data-role="ux-decision"
        data-finding-id={@finding.id}
        data-status={@finding.status}
      >
        <div class="flex items-center gap-2">
          <.ux_chip />
          <time class="text-xs tabular-nums text-subtle" data-role="ux-decision-time">
            {InboxItem.relative_time(@finding.inserted_at)}
          </time>
        </div>

        <h2
          class="mt-2 break-words text-lg font-semibold text-base-content"
          data-role="ux-decision-question"
        >
          {@finding.question}
        </h2>

        <div class="mt-1 flex flex-wrap items-baseline gap-x-3 gap-y-1 text-sm text-subtle">
          <span data-role="ux-decision-evidence">{Decisions.evidence_line(@finding.evidence)}</span>
          <button
            type="button"
            phx-click="toggle_messages"
            phx-target={@myself}
            aria-expanded={to_string(@show_messages)}
            aria-controls={"#{@id}-messages"}
            class="focus-visible-ring rounded font-semibold text-interactive"
            data-role="ux-decision-show-messages"
          >
            {if @show_messages, do: "▾ hide the messages", else: "▸ show the messages"}
          </button>
        </div>

        <ul
          :if={!@show_messages and Decisions.quotes(@finding.evidence) != []}
          class="mt-2 space-y-1"
          data-role="ux-decision-quotes"
        >
          <li
            :for={quote <- Decisions.quotes(@finding.evidence)}
            class="truncate text-sm italic text-subtle"
          >
            “{quote}”
          </li>
        </ul>

        <ol
          id={"#{@id}-messages"}
          phx-update="stream"
          class={["mt-3 space-y-2", !@show_messages && "hidden"]}
          data-role="ux-decision-messages"
        >
          <li
            :for={{dom_id, m} <- @streams.messages}
            id={dom_id}
            class="rounded-lg bg-base-200 px-3 py-2 text-sm"
            data-role="ux-decision-message"
          >
            <span :if={m.author} class="font-semibold text-base-content">{m.author}</span>
            <p class="mt-0.5 line-clamp-3 break-words text-base-content">{m.content}</p>
            <.link
              navigate={m.url}
              class="focus-visible-ring mt-1 inline-flex min-h-11 items-center rounded text-xs font-semibold text-interactive lg:min-h-0"
              data-role="ux-decision-message-link"
            >
              Open in chat
            </.link>
          </li>
        </ol>

        <div
          :if={mockups(@finding) != []}
          class="mt-4 rounded-xl bg-base-200 p-3"
          data-role="ux-decision-mockup"
        >
          <div class="flex snap-x snap-mandatory gap-3 overflow-x-auto overscroll-x-contain lg:grid lg:grid-cols-2 lg:overflow-visible">
            <figure
              :for={{label, src} <- mockups(@finding)}
              class="w-full shrink-0 snap-center lg:w-auto"
              data-role="ux-decision-mockup-image"
              data-side={String.downcase(label)}
            >
              <a
                href={src}
                {Platform.Chat.LinkTargets.open_attrs(src)}
                data-image-viewer
                data-filename={label}
                title="Tap to enlarge"
                class="focus-visible-ring block cursor-zoom-in rounded-lg"
              >
                <img
                  src={src}
                  alt={"#{label}: #{@finding.question}"}
                  class="max-h-64 w-full rounded-lg object-contain lg:max-h-96"
                  loading="lazy"
                />
              </a>
              <figcaption class="mt-1 text-center text-xs text-subtle">{label}</figcaption>
            </figure>
          </div>
        </div>

        <%= if @finding.status == "open" do %>
          <dl class="mt-4 space-y-1 text-sm" data-role="ux-decision-options">
            <div :for={a <- Enum.filter(Decisions.answers(@finding), & &1.option)} class="flex gap-2">
              <dt class="shrink-0 text-subtle">{a.label}:</dt>
              <dd class="min-w-0 text-base-content">
                {a.option["label"]}<span
                  :if={a.option["detail"] not in [nil, ""]}
                  class="text-subtle"
                > · {a.option["detail"]}</span>
              </dd>
            </div>
          </dl>

          <div class="mt-4 flex flex-wrap items-start gap-2" data-role="ux-decision-answers">
            <div :for={a <- Decisions.answers(@finding)} class="flex flex-col items-center gap-1">
              <button
                type="button"
                phx-click="answer"
                phx-value-choice={a.key}
                phx-target={@myself}
                class={answer_class(a, @btn_primary, @btn_secondary, @btn_ghost)}
                data-role="ux-decision-answer"
                data-answer={a.key}
                data-primary={to_string(a.primary?)}
              >
                {a.label}
              </button>
              <span
                :if={a.primary?}
                class="text-xs text-subtle"
                data-role="ux-decision-recommended"
              >
                Recommended
              </span>
            </div>
          </div>

          <.form
            for={@form}
            phx-change="note"
            phx-submit="note"
            phx-target={@myself}
            class="mt-3"
            data-role="ux-decision-note"
          >
            <.input
              field={@form[:note]}
              type="textarea"
              rows="2"
              maxlength="1000"
              placeholder="Optional note…"
              aria-label="Optional note"
              class="w-full rounded-lg border border-edge bg-base-200 px-3 py-2 text-sm text-base-content placeholder:text-subtle"
            />
          </.form>
        <% else %>
          <p class="mt-4 text-sm text-subtle" data-role="ux-decision-answered">
            {answered_line(@finding)}
          </p>
        <% end %>

        <p :if={@notice} class="mt-2 text-sm text-base-content" data-role="ux-decision-notice">
          {@notice}
        </p>
      </article>
    </div>
    """
  end

  defp answer_class(%{primary?: true}, primary, _secondary, _ghost), do: primary
  defp answer_class(%{key: "not_now"}, _primary, _secondary, ghost), do: ghost
  defp answer_class(_answer, _primary, secondary, _ghost), do: secondary

  # The mockup refs that resolve to an attachment, before first.
  defp mockups(%Finding{mockup_refs: refs}) do
    refs = refs || %{}

    for {key, label} <- [{"before", "Before"}, {"after", "After"}],
        src = Decisions.mockup_src(refs[key]),
        do: {label, src}
  end

  defp answered_line(%Finding{status: "dismissed"}), do: "Not now."
  defp answered_line(%Finding{answer: answer}), do: "Answered: " <> (answer || "")
end
