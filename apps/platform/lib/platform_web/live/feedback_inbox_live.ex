defmodule PlatformWeb.FeedbackInboxLive do
  @moduledoc """
  `/admin/feedback-inbox`: the vendor's feedback inbox on the broker-host
  install (task 01a1b678 stage 4). Which requests the most installs share,
  and which have shipped.

  ## Who sees it

  Only on the broker host (`Platform.Feedback.BrokerServer.enabled?/0`) and
  only for an admin of the root org (`Tenancy.org_admin?/2`). Anywhere else
  `mount/3` raises `PlatformWeb.FeedbackInboxLive.NotFoundError`, a 404, so a
  normal install cannot even tell the page exists.

  ## Layout

  From the direction canvas (`01a1b678-ebbd-7000-81ae-2ede3b51b361`, layout
  node): `Request | Installs | Status`, sorted by the distinct-install count
  (`Platform.Feedback.Inbox.list/0`). The count is right-aligned JetBrains
  Mono and `shrink-0`; the request title is `min-w-0 truncate`, so it is
  what gives way on a phone. Status is "Open", or "Shipped · notice sent" in
  `--color-info`, the canvas's only slot for that state. Rows are a stream.
  """

  use PlatformWeb, :live_view

  alias Platform.Feedback.BrokerServer
  alias Platform.Feedback.Inbox
  alias Platform.Tenancy
  alias PlatformWeb.FeedbackInboxLive.NotFoundError

  @impl true
  def mount(_params, _session, socket) do
    unless visible?(socket.assigns[:current_user_record]), do: raise(NotFoundError)

    rows = Enum.map(Inbox.list(), &Map.put(&1, :id, "request-" <> &1.fingerprint))

    {:ok,
     socket
     |> assign(:page_title, "Feedback inbox")
     |> assign(:empty?, rows == [])
     |> stream(:requests, rows)}
  end

  @doc "Whether `user` may see the inbox on this node."
  @spec visible?(term()) :: boolean()
  def visible?(user) do
    BrokerServer.enabled?() and
      case Tenancy.get_root_org() do
        %{id: root_id} -> Tenancy.org_admin?(user, root_id)
        _ -> false
      end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full min-h-0 flex-col">
      <.breadcrumb segments={[
        %{label: "Admin", navigate: ~p"/admin"},
        %{label: "Feedback inbox", navigate: nil}
      ]} />
      <div class="flex items-center justify-between border-b border-edge px-4 py-3">
        <h1 class="text-sm font-semibold uppercase tracking-widest text-base-content">
          Admin · Feedback inbox
        </h1>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto p-4 clears-tab-bar">
        <div class="mx-auto max-w-3xl space-y-3">
          <p class="text-sm text-subtle">
            Requests from every install, most installs first.
          </p>

          <div class="rounded-xl border border-edge bg-base-100" data-role="feedback-inbox">
            <div
              class="flex items-center gap-3 border-b border-edge px-4 py-2 text-xs font-medium text-subtle"
              data-role="feedback-inbox-head"
            >
              <span class="min-w-0 flex-1">Request</span>
              <span class="w-14 shrink-0 text-right">Installs</span>
              <span class="w-24 shrink-0 sm:w-40">Status</span>
            </div>

            <p :if={@empty?} class="px-4 py-6 text-sm text-subtle" data-role="feedback-inbox-empty">
              No requests yet.
            </p>

            <ul id="feedback-inbox-rows" phx-update="stream" class="divide-y divide-edge">
              <li
                :for={{dom_id, row} <- @streams.requests}
                id={dom_id}
                class="flex items-center gap-3 px-4 py-3"
                data-role="feedback-inbox-row"
                data-fingerprint={row.fingerprint}
              >
                <span
                  class="min-w-0 flex-1 truncate text-sm text-base-content"
                  data-role="feedback-inbox-title"
                  title={row.title}
                >
                  {row.title || "Untitled request"}
                </span>
                <span
                  class="w-14 shrink-0 text-right font-mono text-sm tabular-nums text-base-content"
                  data-role="feedback-inbox-installs"
                >
                  {row.installs}
                </span>
                <span
                  class="w-24 shrink-0 text-xs sm:w-40 sm:text-sm"
                  data-role="feedback-inbox-status"
                >
                  <span :if={row.shipped} class="inline-flex items-center gap-1 text-info">
                    <span class="hero-check-circle size-3.5 shrink-0" aria-hidden="true"></span>
                    Shipped · notice sent
                  </span>
                  <span :if={!row.shipped} class="text-base-content">Open</span>
                </span>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
