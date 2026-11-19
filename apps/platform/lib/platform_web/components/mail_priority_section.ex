defmodule PlatformWeb.Components.MailPrioritySection do
  @moduledoc """
  The called-out email section at the top of the daily briefing (task
  01a1f426 stage 2, Level 1 surface): `Platform.Mail.Triage.section_view/3`
  rendered for the reader. Mounted by the briefing through the section
  contract (`Platform.Memory.Insights.BriefingSections`, key
  `mail_priority`), it receives only a user id and a date and re-reads the
  user, the triage agent and the items on every update and every event, so
  which mailboxes are in view (readable by the reader AND granted to the
  triage agent) is decided by `Platform.Mail.Triage`, never by what was
  passed in or by a client-supplied id.

  Per called-out email: a tier chip (Needs you / Action), the sender's name
  and address, the subject (a link to the message in Email), the mailbox,
  ONE line of why, the received time, and two actions: "Done" (status
  acted) and "Not important" (feedback `not_important`, item dismissed).
  Below, a collapsed "N other emails" disclosure lists the routine and promo
  items (sender and subject only), each with "This needed me" (feedback
  `missed`). The inbound body is never rendered.

  Level 2 (task 01a1f426 stage 5): an item whose drafter reply is ready
  shows "Draft ready", a two-line preview of the draft and a link that
  opens it in Email's editor (`/email/drafts/:id`, where
  `Platform.Mail.Drafts.get_visible/3` decides again); a sent one shows
  "Draft sent". An item with a fulfilment plan shows its summary and an
  expandable, numbered step list. Which draft an item shows is decided by
  `Triage.section_view/3` (the item's own mailbox, this reader as the
  on-behalf person, the draft visibility rule); a forged or stale draft id
  renders nothing and links nowhere. There is no send control here, and
  no event of this component reaches `Platform.Mail.Dispatch`: drafts
  only, and sending happens in Email's confirm pane, by a person.

  Every event handler resolves the item as the reader's OWN item
  (`Triage.reader_item/2`) and then re-checks `Triage.eligible?/2` (the
  item's account in `Triage.eligible_account_ids/2`) BEFORE it writes, then
  calls `BriefingSections.changed/2`. A forged id (another reader's item,
  or an item of a mailbox no longer readable or granted) writes nothing.

  States: no triage agent assigned; mailboxes the reader may read that are
  not granted to the agent (named, with where to grant access: metadata
  only); nothing needs you today; items. Stacked cards at every width,
  44px tap targets below `sm`; times and labels use `text-subtle`.
  """

  use PlatformWeb, :live_component

  alias Platform.Mail.Triage
  alias Platform.Mail.Triage.Context
  alias Platform.Memory.Insights.BriefingSections

  @verbs ~w(triage_done triage_not_important triage_missed)

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:user_id, assigns[:user_id])
     |> assign(:date, assigns[:date] || Triage.briefing_today())
     |> reload()}
  end

  defp reload(socket) do
    user = fetch_user(socket.assigns.user_id)

    assign(socket, :view, Triage.section_view(user, socket.assigns.date))
  end

  @impl true
  def handle_event(event, %{"item_id" => item_id}, socket) when event in @verbs do
    user = fetch_user(socket.assigns.user_id)

    with %{id: user_id} <- user,
         %Triage.Item{} = item <- Triage.reader_item(user, item_id),
         true <- Triage.eligible?(user, item),
         {:ok, _} <- write(event, user, item) do
      BriefingSections.changed(user_id, socket.assigns.date)
    end

    {:noreply, reload(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, reload(socket)}

  defp write("triage_done", user, %{tier: tier} = item) when tier in ~w(top action),
    do: Triage.mark_done(user, item)

  defp write("triage_not_important", user, %{tier: tier, status: "open"} = item)
       when tier in ~w(top action),
       do: Triage.record_feedback(user, item, "not_important")

  defp write("triage_missed", user, %{tier: tier} = item) when tier in ~w(routine promo),
    do: Triage.record_feedback(user, item, "missed")

  defp write(_event, _user, _item), do: {:error, :not_allowed}

  defp fetch_user(id) when is_binary(id), do: Platform.Accounts.get_user(id)
  defp fetch_user(_), do: nil

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      aria-labelledby={@id <> "-heading"}
      data-role="briefing-section"
      data-section="mail_priority"
    >
      <div data-role="mail-priority">
        <h3
          id={@id <> "-heading"}
          class="mb-2 mt-6 text-xs font-bold uppercase tracking-wider text-subtle"
          data-role="mail-priority-heading"
        >
          Emails that need you
        </h3>

        <p
          :if={is_nil(@view.agent)}
          class="rounded-box border border-edge bg-base-100 px-4 py-3 text-sm text-base-content"
          data-role="mail-priority-no-agent"
        >
          No agent is assigned to triage your email yet, so nothing is called out.
        </p>

        <ul
          :if={@view.agent && @view.ungranted != []}
          role="list"
          class="mb-2 space-y-1"
          data-role="mail-priority-ungranted"
        >
          <li
            :for={box <- @view.ungranted}
            class="flex items-start gap-2 rounded-box border border-edge bg-base-100 px-4 py-2 text-sm text-base-content"
            data-role="mail-priority-ungranted-mailbox"
            data-account-id={box.id}
          >
            <span class="hero-lock-closed mt-0.5 size-4 shrink-0 text-subtle" aria-hidden="true">
            </span>
            <span class="min-w-0">
              <span class="font-medium">{box.name}</span>
              is not triaged. To include it, grant {@view.agent.name} access in
              <.link navigate="/email/accounts" class="text-info hover:underline">
                Email &gt; Accounts &gt; Access
              </.link>
            </span>
          </li>
        </ul>

        <p
          :if={@view.agent && @view.called_out == []}
          class="rounded-box border border-edge bg-base-100 px-4 py-6 text-center text-sm text-subtle"
          data-role="mail-priority-empty"
        >
          Nothing needs you today
        </p>

        <ul :if={@view.called_out != []} role="list" class="space-y-2" data-role="mail-priority-list">
          <li
            :for={item <- @view.called_out}
            id={"mail-priority-item-" <> item.id}
            class={[
              "scroll-mt-20 rounded-box border border-edge bg-base-100 px-4 py-3",
              item.status != "open" && "opacity-70"
            ]}
            data-role="mail-priority-item"
            data-item-id={item.id}
            data-tier={item.tier}
            data-status={item.status}
          >
            <div class="flex items-start justify-between gap-3">
              <div class="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-1">
                <.tier_chip tier={item.tier} />
                <.sender from={item.from} />
              </div>
              <.received at={item.received_at} />
            </div>

            <.link
              navigate={"/email/messages/" <> item.inbound_id}
              class="mt-1 block min-h-11 break-words py-2 text-sm font-semibold text-base-content hover:underline sm:min-h-0 sm:py-0"
              data-role="mail-priority-subject"
            >
              {item.subject || "(no subject)"}
            </.link>

            <p
              :if={item.why}
              class="mt-0.5 line-clamp-2 text-sm text-base-content"
              data-role="mail-priority-why"
            >
              {item.why}
            </p>

            <.draft_ready :if={item.draft} draft={item.draft} />
            <.plan :if={item.plan} plan={item.plan} item_id={item.id} />

            <p
              class="mt-1 flex items-center gap-1 text-xs text-subtle"
              data-role="mail-priority-mailbox"
            >
              <span class="hero-inbox size-3.5 shrink-0" aria-hidden="true"></span>
              <span class="truncate">{item.mailbox}</span>
            </p>

            <div
              :if={item.status == "open"}
              class="mt-2 flex flex-wrap gap-2"
              data-role="mail-priority-actions"
            >
              <button
                type="button"
                phx-click="triage_done"
                phx-value-item_id={item.id}
                phx-target={@myself}
                class="btn btn-sm min-h-11 sm:min-h-8"
                data-role="mail-priority-done"
              >
                <span class="hero-check size-4" aria-hidden="true"></span> Done
              </button>
              <button
                type="button"
                phx-click="triage_not_important"
                phx-value-item_id={item.id}
                phx-target={@myself}
                class="btn btn-ghost btn-sm min-h-11 sm:min-h-8"
                data-role="mail-priority-not-important"
              >
                Not important
              </button>
            </div>

            <p
              :if={item.status != "open"}
              class="mt-2 text-xs text-subtle"
              data-role="mail-priority-receipt"
            >
              {if(item.status == "acted", do: "Marked done", else: "Marked not important")}
            </p>
          </li>
        </ul>

        <details
          :if={@view.others != []}
          class="mt-2 rounded-box border border-edge bg-base-100"
          data-role="mail-priority-others"
        >
          <summary class="flex min-h-11 cursor-pointer items-center px-4 text-sm text-base-content">
            {others_label(length(@view.others))}
          </summary>
          <ul role="list" class="divide-y divide-edge border-t border-edge">
            <li
              :for={item <- @view.others}
              class="flex flex-col gap-2 px-4 py-2 sm:flex-row sm:items-center sm:justify-between"
              data-role="mail-priority-other"
              data-item-id={item.id}
            >
              <div class="min-w-0">
                <p class="truncate text-xs text-subtle">{sender_label(item.from)}</p>
                <.link
                  navigate={"/email/messages/" <> item.inbound_id}
                  class="block truncate text-sm text-base-content hover:underline"
                >
                  {item.subject || "(no subject)"}
                </.link>
              </div>
              <button
                type="button"
                phx-click="triage_missed"
                phx-value-item_id={item.id}
                phx-target={@myself}
                class="btn btn-ghost btn-sm min-h-11 shrink-0 self-start sm:min-h-8 sm:self-auto"
                data-role="mail-priority-missed"
              >
                This needed me
              </button>
            </li>
          </ul>
        </details>
      </div>
    </section>
    """
  end

  attr :draft, :map, required: true

  defp draft_ready(%{draft: %{status: "draft"}} = assigns) do
    ~H"""
    <div
      class="mt-2 rounded-box border border-edge bg-base-200/40 px-3 py-2"
      data-role="mail-priority-draft"
      data-draft-id={@draft.id}
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <span class="inline-flex items-center gap-1 text-xs font-semibold text-success">
          <span class="hero-pencil-square size-4" aria-hidden="true"></span> Draft ready
        </span>
        <.link
          navigate={"/email/drafts/" <> @draft.id}
          class="btn btn-sm min-h-11 sm:min-h-8"
          data-role="mail-priority-draft-open"
        >
          Open draft <span class="hero-arrow-right size-4" aria-hidden="true"></span>
        </.link>
      </div>
      <p
        :if={@draft.preview != []}
        class="mt-1 min-w-0 text-sm text-base-content"
        data-role="mail-priority-draft-preview"
      >
        <span :for={line <- @draft.preview} class="block truncate">{line}</span>
      </p>
    </div>
    """
  end

  defp draft_ready(assigns) do
    ~H"""
    <p
      class="mt-2 inline-flex items-center gap-1 text-xs text-subtle"
      data-role="mail-priority-draft-sent"
    >
      <span class="hero-paper-airplane size-3.5" aria-hidden="true"></span> Draft sent
    </p>
    """
  end

  attr :plan, :map, required: true
  attr :item_id, :string, required: true

  defp plan(assigns) do
    ~H"""
    <details
      class="mt-2 rounded-box border border-edge bg-base-200/40"
      data-role="mail-priority-plan"
    >
      <summary class="flex min-h-11 cursor-pointer items-start gap-2 px-3 py-2 text-sm sm:min-h-0">
        <span class="hero-list-bullet mt-0.5 size-4 shrink-0 text-subtle" aria-hidden="true"></span>
        <span class="min-w-0 flex-1">
          <span class="block font-medium text-base-content" data-role="mail-priority-plan-summary">
            {@plan.summary || "A plan to fulfil this"}
          </span>
          <span class="block text-xs text-subtle">{steps_label(length(@plan.steps))}</span>
        </span>
      </summary>
      <ol
        class="list-decimal space-y-1 border-t border-edge py-2 pl-9 pr-3 text-sm text-base-content"
        data-role="mail-priority-plan-steps"
      >
        <li :for={step <- @plan.steps} class="break-words">{step}</li>
      </ol>
    </details>
    """
  end

  defp steps_label(1), do: "1 step"
  defp steps_label(n), do: "#{n} steps"

  attr :tier, :string, required: true

  defp tier_chip(%{tier: "top"} = assigns) do
    ~H"""
    <span
      class="inline-flex shrink-0 items-center rounded-full border border-warning px-2 py-0.5 text-xs font-semibold text-warning"
      data-role="mail-priority-tier"
    >
      Needs you
    </span>
    """
  end

  defp tier_chip(assigns) do
    ~H"""
    <span
      class="inline-flex shrink-0 items-center rounded-full border border-info px-2 py-0.5 text-xs font-semibold text-info"
      data-role="mail-priority-tier"
    >
      Action
    </span>
    """
  end

  attr :from, :string, default: nil

  defp sender(assigns) do
    assigns =
      assigns
      |> assign(:name, display_name(assigns.from))
      |> assign(:address, Context.address(assigns.from))

    ~H"""
    <span class="min-w-0 text-sm" data-role="mail-priority-sender">
      <span :if={@name} class="font-medium text-base-content">{@name}</span>
      <span class={["break-all", if(@name, do: "text-xs text-subtle", else: "text-base-content")]}>
        {@address || @from || "(unknown sender)"}
      </span>
    </span>
    """
  end

  attr :at, :any, default: nil

  defp received(assigns) do
    ~H"""
    <time
      :if={@at}
      class="shrink-0 font-mono text-xs text-subtle"
      datetime={DateTime.to_iso8601(@at)}
      title={Calendar.strftime(@at, "%Y-%m-%d %H:%M UTC")}
      data-role="mail-priority-received"
    >
      {PlatformWeb.Components.InboxItem.relative_time(@at)}
    </time>
    """
  end

  @doc false
  def display_name(from) when is_binary(from) do
    case Regex.run(~r/^\s*"?([^"<]*?)"?\s*<[^<>]+>\s*$/, from) do
      [_, name] when name != "" -> name
      _ -> nil
    end
  end

  def display_name(_), do: nil

  defp sender_label(from), do: display_name(from) || Context.address(from) || "(unknown sender)"

  defp others_label(1), do: "1 other email"
  defp others_label(n), do: "#{n} other emails"
end
