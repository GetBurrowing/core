defmodule PlatformWeb.InstallStatusLive do
  @moduledoc """
  `/install-status/:token`: the customer's install progress and the
  shown-once credentials hand-over (task 01a10315 stage 3; design direction
  canvas 01a13c97-98c6-7000-91f3-96b8ccfe8af4, screens 1 and 2).

  No login. The status token is the capability: `Platform.Installs.get_by_token/2`
  answers only for the sha256 of a token `create/2` returned once, rate-limited
  by the caller's address. An unknown token, a malformed one and a rate-limited
  lookup all render the same "This link isn't valid" page, so the page is never
  an oracle about whether an install exists.

  The route sits in its own `live_session :install_status` on `:guest_browser`
  with the `:guest` layout (no shell, no auth chrome), modelled on
  `:guest_meeting`; `router_install_status_placement_test.exs` pins where it
  resolves.

  ## Screens

    * **progress** (any status but `ready`): the four steps in business terms,
      live over `"install:<id>"`. A failed step shows its plain-words reason,
      Retry (`Platform.Installs.retry/2` with the token) and "Retrying won't
      create a second server." A customer-domain install waiting in `connect`
      lists the two records to add (`Platform.Installs.dns_instructions/1`).
    * **hand-over** (`ready`, not yet acknowledged): the credentials card.
    * **done** (acknowledged, or the hand-over expired): the URL only.
    * **removed** (`destroying`/`destroyed`) and **invalid**.

  ## The credentials are never a long-lived assign

  `@install` is the row with `handover_sealed` set to nil (`put_install/2`):
  `Platform.Vault.EncryptedBinary` decrypts it on load, so the row as read
  holds the private key.

  `reveal_handover/1` mints a fresh sign-in link and returns the private key;
  the result goes into `:handover`, a `temporary_assigns` slot that LiveView
  resets to nil right after the render that sends it. The card that shows it
  is a function component whose only dynamic input is `@handover`, so later
  renders (ticking the checkbox, a broadcast) skip it and never re-read the
  emptied slot; the browser keeps the DOM it was sent. Nothing is persisted:
  a reconnect remounts and reveals again. The reveal runs only on the
  CONNECTED mount, so the credentials are never in the plain HTTP response.

  The sealed blob also carries the box's OIDC client secret; it is never
  revealed here (`reveal_handover/1` does not return it).
  """
  use PlatformWeb, :live_view

  alias Platform.Installs
  alias Platform.Installs.Install

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Your install")
      |> assign(:token, token)
      |> assign(:saved, false)
      |> assign(:handover, nil)
      |> assign(:handover_error, nil)

    socket =
      case Installs.get_by_token(token, rate_key: rate_key(socket)) do
        nil ->
          assign(socket, install: nil, screen: :invalid)

        %Install{} = install ->
          if connected?(socket), do: Installs.subscribe(install.id)
          socket |> put_install(install) |> enter_screen()
      end

    {:ok, socket, temporary_assigns: [handover: nil]}
  end

  # The schema decrypts `handover_sealed` on load, so a row read from the
  # database carries the private key in plaintext. It never enters an assign:
  # every Installs call that needs it re-reads the row by id.
  defp put_install(socket, %Install{} = install),
    do: assign(socket, :install, %{install | handover_sealed: nil})

  defp rate_key(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} -> address |> :inet.ntoa() |> to_string()
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  @impl true
  def handle_info({:install_updated, id}, %{assigns: %{install: %Install{id: id}}} = socket) do
    case Installs.get(id) do
      nil ->
        {:noreply, assign(socket, install: nil, screen: :removed)}

      install ->
        previous = socket.assigns.screen
        socket = put_install(socket, install)

        # Already showing the hand-over: never reveal (mint) again for a
        # broadcast. Anything else re-derives the screen.
        if previous == :handover and screen_for(install) == :handover,
          do: {:noreply, socket},
          else: {:noreply, enter_screen(socket)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry", _params, %{assigns: %{install: %Install{} = install}} = socket) do
    case Installs.retry(install, socket.assigns.token) do
      {:ok, install} ->
        {:noreply, socket |> put_install(install) |> enter_screen()}

      {:error, _} ->
        {:noreply, socket |> put_install(Installs.get(install.id)) |> enter_screen()}
    end
  end

  def handle_event("saved", params, socket) do
    {:noreply, assign(socket, :saved, params["saved"] == "true")}
  end

  def handle_event("open_burrow", _params, %{assigns: %{saved: true}} = socket) do
    install = socket.assigns.install

    case Installs.acknowledge_handover(install) do
      {:ok, install} ->
        {:noreply,
         socket
         |> put_install(install)
         |> assign(:screen, :done)
         |> redirect(external: "https://#{install.primary_host}/setup/connect-ai")}

      {:error, _} ->
        {:noreply, socket |> put_install(Installs.get(install.id)) |> enter_screen()}
    end
  end

  def handle_event("open_burrow", _params, socket), do: {:noreply, socket}

  def handle_event("reveal_again", _params, socket), do: {:noreply, enter_screen(socket)}

  # ---------------------------------------------------------------------------
  # Screens
  # ---------------------------------------------------------------------------

  defp screen_for(%Install{status: status}) when status in ~w(destroying destroyed), do: :removed

  defp screen_for(%Install{status: "ready"} = install) do
    if install.handover_acknowledged_at || install.handover_expired_at,
      do: :done,
      else: :handover
  end

  defp screen_for(%Install{}), do: :progress

  defp enter_screen(socket) do
    install = socket.assigns.install

    case screen_for(install) do
      :handover -> reveal(socket, install)
      screen -> assign(socket, :screen, screen)
    end
  end

  defp reveal(socket, install) do
    if connected?(socket) do
      case Installs.reveal_handover(install) do
        {:ok, handover} ->
          socket
          |> assign(:screen, :handover)
          |> assign(:handover, handover)
          |> assign(:handover_error, nil)

        {:error, reason} when reason in [:already_handed_over, :handover_expired] ->
          socket |> put_install(Installs.get(install.id)) |> assign(:screen, :done)

        {:error, _reason} ->
          socket |> assign(:screen, :handover) |> assign(:handover_error, :unavailable)
      end
    else
      assign(socket, :screen, :handover)
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full overflow-y-auto bg-base-100">
      <div class="mx-auto w-full max-w-[560px] px-4 pt-10 pb-[calc(2.5rem+env(safe-area-inset-bottom))]">
        <.invalid :if={@screen == :invalid} />
        <.removed :if={@screen == :removed} />
        <.progress :if={@screen == :progress} install={@install} />
        <section :if={@screen == :handover} id="install-handover" class="space-y-6">
          <div
            :if={@handover_error == nil}
            class="rounded-box border-2 border-warning bg-base-100 p-5 sm:p-6"
          >
            <div class="flex items-start gap-3 rounded-box bg-warning/15 p-3 text-base-content">
              <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-warning" />
              <h1 class="text-lg font-bold">Save these now. We don't keep a copy.</h1>
            </div>
            <.credentials handover={@handover} />
            <form
              id="handover-ack"
              phx-change="saved"
              class="mt-6 flex flex-col gap-3 border-t border-base-300 pt-5 sm:flex-row sm:items-center sm:justify-between"
            >
              <label class="flex cursor-pointer items-center gap-3 text-base text-base-content">
                <input type="hidden" name="saved" value="false" />
                <input
                  type="checkbox"
                  name="saved"
                  value="true"
                  checked={@saved}
                  class="checkbox checkbox-primary"
                  id="handover-saved"
                /> I've saved these
              </label>
              <button
                type="button"
                id="open-burrow"
                phx-click="open_burrow"
                disabled={!@saved}
                class="btn btn-primary min-h-11"
              >
                Open Burrow
              </button>
            </form>
          </div>
          <div
            :if={@handover_error}
            class="rounded-box border border-error/40 bg-error/10 p-5 text-base-content"
          >
            <p class="font-medium text-error">We couldn't prepare your details just now.</p>
            <p class="mt-1 text-sm text-base-content/70">
              Your server is ready and nothing was lost.
            </p>
            <button type="button" phx-click="reveal_again" class="btn btn-primary mt-4 min-h-11">
              Try again
            </button>
          </div>
        </section>
        <section :if={@screen == :done} id="install-done" class="space-y-4">
          <h1 class="text-2xl font-semibold text-base-content">Your Burrow is ready</h1>
          <a
            href={"https://#{@install.primary_host}"}
            class="link font-mono text-sm text-base-content break-all"
          >
            https://{@install.primary_host}
          </a>
        </section>
      </div>
    </div>
    """
  end

  defp invalid(assigns) do
    ~H"""
    <section id="install-invalid" class="space-y-2">
      <h1 class="text-2xl font-semibold text-base-content">This link isn't valid</h1>
      <p class="text-base text-base-content/70">
        Check that you copied the whole link, or ask whoever sent it for a new one.
      </p>
    </section>
    """
  end

  defp removed(assigns) do
    ~H"""
    <section id="install-removed" class="space-y-2">
      <h1 class="text-2xl font-semibold text-base-content">This install has been removed</h1>
      <p class="text-base text-base-content/70">Its server and address no longer exist.</p>
    </section>
    """
  end

  attr(:install, Install, required: true)

  defp progress(assigns) do
    assigns =
      assigns
      |> assign(:failed, Enum.find(assigns.install.steps, &(&1["state"] == "failed")))
      |> assign(:records, waiting_records(assigns.install))
      |> assign(:price, Installs.price_label(Installs.monthly_prices()[assigns.install.size]))

    ~H"""
    <section id="install-progress" class="space-y-6">
      <h1 class="text-2xl font-semibold text-base-content break-words">
        Setting up {@install.business_name}
      </h1>

      <ol id="install-steps" class="rounded-box border border-base-300 bg-base-100">
        <li
          :for={step <- @install.steps}
          id={"step-#{step["key"]}"}
          data-state={step["state"]}
          class={[
            "flex items-center gap-3 border-base-300 px-4 py-3 [&:not(:first-child)]:border-t",
            step["state"] == "running" && "bg-info/10",
            step["state"] == "failed" && "bg-error/10"
          ]}
        >
          <.step_icon state={step["state"]} />
          <span class={["min-w-0 flex-1 break-words text-base", label_class(step["state"])]}>
            {step_label(step["key"], @install)}
          </span>
          <span class="shrink-0 font-mono text-sm tabular-nums text-base-content/60">
            {elapsed(step)}
          </span>
        </li>
      </ol>

      <div
        :if={@failed}
        id="install-failed"
        class="rounded-box border border-error/40 bg-error/10 p-4"
      >
        <p class="font-medium text-error">
          {step_label(@failed["key"], @install)} didn't finish.
        </p>
        <p class="mt-1 text-base text-base-content">{@failed["error"]}</p>
        <div class="mt-4 flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-4">
          <button type="button" id="install-retry" phx-click="retry" class="btn btn-primary min-h-11">
            Retry
          </button>
          <p class="text-sm text-error">Retrying won't create a second server.</p>
        </div>
      </div>

      <div
        :if={@records != []}
        id="install-records"
        class="rounded-box border border-info/40 bg-info/10 p-4 text-base-content"
      >
        <p class="font-medium text-info">Point {@install.primary_host} at your server</p>
        <p class="mt-1 text-sm text-base-content/80">
          Add these two records where you manage your domain. This step finishes by itself once they
          are live, which can take up to an hour.
        </p>
        <dl class="mt-3 space-y-2">
          <div
            :for={{record, i} <- Enum.with_index(@records)}
            class="rounded-box border border-base-300 bg-base-100 p-3"
            data-record-type={record.type}
          >
            <dt class="text-xs text-base-content/70">
              {record.type} record for
              <span class="font-mono text-sm text-base-content break-all">{record.name}</span>
            </dt>
            <dd class="mt-1 flex items-center gap-2">
              <span class="min-w-0 flex-1 font-mono text-sm break-all">
                {record.value || "your server's address (shown once it is reserved)"}
              </span>
              <button
                :if={record.value}
                type="button"
                id={"copy-record-#{i}"}
                phx-hook="CopyToClipboard"
                data-clipboard-text={record.value}
                class="btn btn-ghost btn-sm min-h-11 shrink-0"
              >
                Copy
              </button>
            </dd>
          </div>
        </dl>
      </div>

      <div class="space-y-1 text-base text-base-content/70">
        <p>About 8 minutes. You can close this tab; this link keeps working.</p>
        <p id="install-plan" class="text-sm">
          {Installs.region_label(@install.region)} · {Installs.size_label(@install.size)}<span :if={
            @price
          }> · {@price}</span>
        </p>
      </div>
    </section>
    """
  end

  attr(:state, :string, required: true)

  defp step_icon(%{state: "done"} = assigns) do
    ~H"""
    <.icon name="hero-check-circle" class="size-5 shrink-0 text-neutral" />
    """
  end

  defp step_icon(%{state: "running"} = assigns) do
    ~H"""
    <.icon name="hero-arrow-path" class="size-5 shrink-0 animate-spin text-info" />
    """
  end

  defp step_icon(%{state: "failed"} = assigns) do
    ~H"""
    <.icon name="hero-x-circle" class="size-5 shrink-0 text-error" />
    """
  end

  defp step_icon(assigns) do
    ~H"""
    <span
      class="inline-block size-5 shrink-0 rounded-full border-2 border-neutral/40"
      aria-hidden="true"
    >
    </span>
    """
  end

  defp label_class("done"), do: "text-base-content/60"
  defp label_class("running"), do: "font-medium text-info"
  defp label_class("failed"), do: "font-medium text-error"
  defp label_class(_pending), do: "text-base-content"

  @doc false
  def step_label("reserve", _install), do: "Reserving your server"
  def step_label("install", _install), do: "Installing Burrow"
  def step_label("connect", install), do: "Connecting #{install.primary_host}"
  def step_label("final", _install), do: "Final checks"
  def step_label(key, _install), do: key

  @doc false
  def elapsed(%{"state" => "running"}), do: "…"

  def elapsed(%{"state" => state, "started_at" => started, "finished_at" => finished})
      when state in ["done", "failed"] and is_binary(started) and is_binary(finished) do
    with {:ok, s, _} <- DateTime.from_iso8601(started),
         {:ok, f, _} <- DateTime.from_iso8601(finished) do
      seconds = max(DateTime.diff(f, s, :second), 0)

      "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
    else
      _ -> nil
    end
  end

  def elapsed(_step), do: nil

  # The records block shows while a customer-domain install waits in connect.
  defp waiting_records(%Install{domain_mode: "customer", steps: steps} = install) do
    connect = Enum.find(steps, &(&1["key"] == "connect"))

    if connect && connect["state"] in ["running", "failed"],
      do: Installs.dns_instructions(install),
      else: []
  end

  defp waiting_records(_install), do: []

  # The shown-once card body. Its ONLY dynamic input is `@handover` (a
  # temporary assign), so it renders exactly when a reveal put a value there
  # and is skipped by every later render. Nil (the dead render, before the
  # connected mount reveals) shows a placeholder.
  attr(:handover, :map, default: nil)

  defp credentials(%{handover: nil} = assigns) do
    ~H"""
    <div id="handover-credentials" class="mt-5 text-base text-base-content/70">
      Preparing your details…
    </div>
    """
  end

  defp credentials(assigns) do
    ~H"""
    <div id="handover-credentials" class="mt-5 space-y-4">
      <dl class="space-y-3">
        <.credential_row id="handover-burrow" label="Burrow" value={@handover.burrow_url} />
        <.credential_row id="handover-admin" label="Admin" value={@handover.admin_email} />
        <div class="rounded-box border border-base-300 p-3">
          <dt class="text-sm text-base-content/70">Sign-in link</dt>
          <dd class="mt-1 flex items-center gap-2">
            <span
              id="handover-signin-masked"
              class="min-w-0 flex-1 font-mono text-sm tracking-widest"
            >
              ••••••••••••
            </span>
            <span
              id="handover-signin-value"
              class="hidden min-w-0 flex-1 font-mono text-sm break-all"
              data-handover-field="Sign-in link"
              data-value={@handover.sign_in_link}
            >
              {@handover.sign_in_link}
            </span>
            <button
              type="button"
              id="handover-signin-show"
              class="btn btn-ghost btn-sm min-h-11 shrink-0"
              phx-click={
                JS.toggle(to: "#handover-signin-masked")
                |> JS.toggle(to: "#handover-signin-value")
              }
            >
              Show
            </button>
            <button
              type="button"
              id="handover-signin-copy"
              phx-hook="CopyToClipboard"
              data-clipboard-text={@handover.sign_in_link}
              class="btn btn-ghost btn-sm min-h-11 shrink-0"
            >
              Copy
            </button>
          </dd>
          <p class="mt-1 text-xs text-base-content/70">
            Opens once. You'll add a passkey. It works for 30 minutes; reopen this page for a fresh one
            until you tick the box below.
          </p>
        </div>
      </dl>

      <details id="handover-ssh" class="group rounded-box border border-base-300">
        <summary class="flex min-h-11 cursor-pointer items-center gap-2 px-3 text-sm font-medium text-base-content">
          <.icon name="hero-chevron-right" class="size-4 transition-transform group-open:rotate-90" />
          For technical users (SSH)
        </summary>
        <dl class="space-y-3 border-t border-base-300 p-3">
          <.credential_row id="handover-ssh-host" label="Host" value={@handover.ssh.host} />
          <.credential_row id="handover-ssh-user" label="User" value={@handover.ssh.user} />
          <div>
            <dt class="flex items-center justify-between text-sm text-base-content/70">
              Private key
              <button
                type="button"
                id="handover-ssh-key-copy"
                phx-hook="CopyToClipboard"
                data-clipboard-text={@handover.ssh.private_key}
                class="btn btn-ghost btn-sm min-h-11"
              >
                Copy
              </button>
            </dt>
            <dd>
              <pre
                id="handover-ssh-key"
                class="mt-1 max-h-48 overflow-auto rounded-box bg-base-200 p-2 font-mono text-sm"
                data-handover-field="SSH private key"
                data-value={@handover.ssh.private_key}
              >{@handover.ssh.private_key}</pre>
            </dd>
          </div>
        </dl>
      </details>

      <button
        type="button"
        id="handover-download"
        phx-hook="HandoverDownload"
        data-handover-target="handover-credentials"
        data-filename="burrow-details.txt"
        class="btn btn-outline min-h-11 w-full sm:w-auto"
      >
        <.icon name="hero-arrow-down-tray" class="size-5" /> Download as file
      </button>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp credential_row(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 p-3">
      <dt class="text-sm text-base-content/70">{@label}</dt>
      <dd class="mt-1 flex items-center gap-2">
        <span
          id={@id}
          class="min-w-0 flex-1 font-mono text-sm break-all text-base-content"
          data-handover-field={field_name(@id, @label)}
          data-value={@value}
        >
          {@value}
        </span>
        <button
          type="button"
          id={"#{@id}-copy"}
          phx-hook="CopyToClipboard"
          data-clipboard-text={@value}
          class="btn btn-ghost btn-sm min-h-11 shrink-0"
        >
          Copy
        </button>
      </dd>
    </div>
    """
  end

  defp field_name("handover-ssh-" <> _, label), do: "SSH #{String.downcase(label)}"
  defp field_name(_id, label), do: label
end
