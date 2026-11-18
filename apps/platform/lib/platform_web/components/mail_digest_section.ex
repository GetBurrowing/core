defmodule PlatformWeb.Components.MailDigestSection do
  @moduledoc """
  The mail section of the daily briefing (task 01a1ea5b stage 5, Email
  privacy): `Platform.Mail.Digest` rendered for the reader. Mounted by the
  briefing through the section contract
  (`Platform.Memory.Insights.BriefingSections`), it receives only a user id
  and re-reads the user and the digest on every update, so the audience rule
  (admins see the cross-mailbox view, everyone else only mailboxes they can
  read) is decided by `Platform.Mail.Digest`, never by what was passed in.

  Metadata only: Customer (the counterparty domain), Who's on it, Open
  threads and Last activity. A row of a mailbox the reader cannot read reads
  "<Owner>'s mailbox (private)" with no link. A table at `sm` and up; a
  stacked card per row below it. Counts, times and the private label use
  `text-subtle` (see the stage report's design deviations).
  """

  use PlatformWeb, :live_component

  alias Platform.Mail.Digest

  @impl true
  def update(assigns, socket) do
    user =
      case assigns[:user_id] do
        id when is_binary(id) -> Platform.Accounts.get_user(id)
        _ -> nil
      end

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:orgs, Digest.for_user(user))}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :multi_org?, length(assigns.orgs) > 1)

    ~H"""
    <section
      id={@id}
      aria-labelledby={@id <> "-heading"}
      data-role="briefing-section"
      data-section="mail"
    >
      <div data-role="mail-digest">
        <h3
          id={@id <> "-heading"}
          class="mb-2 mt-6 text-xs font-bold uppercase tracking-wider text-subtle"
          data-role="mail-digest-heading"
        >
          Email
        </h3>

        <div :for={org <- @orgs} class="mb-4" data-role="mail-digest-org" data-org-id={org.org_id}>
          <p :if={@multi_org?} class="mb-1 text-xs font-medium text-base-content">
            {org.org_name}
          </p>

          <p
            :if={org.rows == []}
            class="rounded-box border border-edge bg-base-100 px-4 py-6 text-center text-sm text-subtle"
            data-role="mail-digest-empty"
          >
            Nothing to show yet
          </p>

          <div :if={org.rows != []}>
            <%!-- Desktop: a table. --%>
            <table
              class="hidden w-full table-fixed border-separate border-spacing-0 overflow-hidden rounded-box border border-edge bg-base-100 text-sm sm:table"
              data-role="mail-digest-table"
            >
              <thead>
                <tr class="text-left text-xs text-subtle">
                  <th class="w-[28%] px-3 py-2 font-medium">Customer</th>
                  <th class="px-3 py-2 font-medium">Who's on it</th>
                  <th class="w-[16%] px-3 py-2 text-right font-medium">Open threads</th>
                  <th class="w-[18%] px-3 py-2 text-right font-medium">Last activity</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- org.rows}
                  class="border-t border-edge align-top"
                  data-role="mail-digest-row"
                  data-readable={to_string(row.readable)}
                >
                  <td class="border-t border-edge px-3 py-2">
                    <p class="truncate font-medium text-base-content">{row.customer}</p>
                    <.mailbox row={row} />
                  </td>
                  <td class="border-t border-edge px-3 py-2 text-base-content">
                    <.who row={row} />
                  </td>
                  <td class="border-t border-edge px-3 py-2 text-right font-mono text-xs text-subtle">
                    {row.open_threads}
                  </td>
                  <td class="border-t border-edge px-3 py-2 text-right font-mono text-xs text-subtle">
                    <.when_ row={row} />
                  </td>
                </tr>
              </tbody>
            </table>

            <%!-- Mobile: a stacked card per row. --%>
            <ul role="list" class="space-y-2 sm:hidden" data-role="mail-digest-cards">
              <li
                :for={row <- org.rows}
                class="rounded-box border border-edge bg-base-100 px-4 py-3"
                data-role="mail-digest-card"
                data-readable={to_string(row.readable)}
              >
                <div class="flex items-baseline justify-between gap-3">
                  <p class="min-w-0 truncate text-sm font-medium text-base-content">
                    {row.customer}
                  </p>
                  <p class="shrink-0 font-mono text-xs text-subtle"><.when_ row={row} /></p>
                </div>
                <.mailbox row={row} />
                <dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
                  <dt class="text-xs text-subtle">Who's on it</dt>
                  <dd class="min-w-0 text-base-content"><.who row={row} /></dd>
                  <dt class="text-xs text-subtle">Open threads</dt>
                  <dd class="font-mono text-xs text-subtle">{row.open_threads}</dd>
                </dl>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :row, :map, required: true

  defp mailbox(%{row: %{readable: true}} = assigns) do
    ~H"""
    <.link
      navigate={@row.link}
      class="mt-0.5 inline-flex min-h-11 items-center gap-1 text-xs text-info hover:underline sm:min-h-0"
      data-role="mail-digest-mailbox-link"
    >
      <span class="hero-inbox size-3.5 shrink-0" aria-hidden="true"></span>
      <span class="truncate">{@row.mailbox}</span>
    </.link>
    """
  end

  defp mailbox(assigns) do
    ~H"""
    <p class="mt-0.5 flex items-center gap-1 text-xs text-subtle" data-role="mail-digest-private">
      <span class="hero-lock-closed size-3.5 shrink-0" aria-hidden="true"></span>
      <span class="truncate">{@row.mailbox}</span>
    </p>
    """
  end

  attr :row, :map, required: true

  defp who(assigns) do
    assigns = assign(assigns, :names, assigns.row.people ++ assigns.row.agents)

    ~H"""
    <span :if={@names == []} class="text-subtle">No one yet</span>
    <span :if={@names != []} class="break-words">{Enum.join(@names, ", ")}</span>
    """
  end

  attr :row, :map, required: true

  defp when_(assigns) do
    ~H"""
    <time
      :if={@row.last_activity_at}
      datetime={DateTime.to_iso8601(@row.last_activity_at)}
      title={Calendar.strftime(@row.last_activity_at, "%Y-%m-%d %H:%M UTC")}
    >
      {PlatformWeb.Components.InboxItem.relative_time(@row.last_activity_at)}
    </time>
    """
  end
end
