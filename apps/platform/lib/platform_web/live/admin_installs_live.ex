defmodule PlatformWeb.AdminInstallsLive do
  @moduledoc """
  `/admin/installs`: the operator's entry to one-click installs on
  DigitalOcean (task 01a10315 stage 3). A form creates an install through
  `Platform.Installs.create/2` and shows the customer's progress link ONCE;
  a list below shows every install with its status and a Destroy button that
  needs the slug typed before it calls `Platform.Installs.teardown/1`.

  ## Install requests (task 01a18f0c stage 3)

  Requests from the getburrow.ing form (`Platform.Installs.request/1`) wait
  in a Requests section above the form, oldest first. Each shows exactly
  what Provision will buy ("Will use": the first offered region, the default
  size and price, `<slug>.<zone>`), and one click calls
  `Platform.Installs.provision_request/2`; Dismiss deletes the row. The
  requester's note is untrusted text and renders escaped. A request-made
  install shows no progress link: the requester's token is minted when the
  install is ready and emailed to them (stage 4). Its row in the list says
  who requested it and the hand-over email's state, one word.

  The spend-gate toggle is `Platform.Installs.RequestSettings`; turning it
  on asks first. With it on, a new request provisions without a click.

  ## The progress link is shown once

  `create/2` returns the status token once and stores only its sha256. The
  link built from it lives in `:new_link` until the operator dismisses it or
  creates another install; nothing can show it again, including a reload.

  ## Authorization — defence in depth

  The route sits in the `:admin` live_session (`ModuleGate` maps this view to
  the `:admin` module), AND every `Platform.Installs` call here receives
  `@current_user_record`, which `create/2` and `list/1` re-check with
  `Platform.Access.authorize_install/1`, as `PlatformWeb.AdminVaultLive` does
  with `Platform.Vault.Shared`. Destroy re-checks the same way before it calls
  `teardown/1`, which takes no actor.
  """
  use PlatformWeb, :live_view

  alias Platform.Access
  alias Platform.Installs
  alias Platform.Installs.RequestSettings

  @impl true
  def mount(_params, _session, socket) do
    defaults = Installs.defaults()
    if connected?(socket), do: Installs.subscribe_requests()

    {:ok,
     socket
     |> assign(:page_title, "Installs")
     |> assign(:subscribed, MapSet.new())
     |> assign(:defaults, defaults)
     |> assign(:prices, Installs.monthly_prices())
     |> assign(:zone, Installs.cname_zone())
     |> assign(:auto_provision, RequestSettings.get().auto_provision_requests)
     |> load_requests()
     |> assign(:regions, defaults.regions)
     |> assign(:available, defaults.available)
     |> assign(:size_options, size_options(defaults.sizes))
     |> assign(:new_link, nil)
     |> assign(:form_error, nil)
     |> assign(:confirm_slug, nil)
     |> assign(:confirm_text, "")
     |> assign(:destroying, MapSet.new())
     |> assign(:form, to_form(blank_params(defaults), as: :install))
     |> load_installs()}
  end

  defp blank_params(defaults) do
    %{
      "business_name" => "",
      "owner_email" => "",
      # Stage 6: the first region offering the default size (nyc1 today).
      "region" => List.first(defaults.regions),
      "size" => defaults.default_size,
      "domain_mode" => "ours",
      "primary_host" => ""
    }
  end

  defp reset_form(socket) do
    defaults = Installs.defaults()

    socket
    |> assign(:regions, defaults.regions)
    |> assign(:available, defaults.available)
    |> assign(:form, to_form(blank_params(defaults), as: :install))
  end

  defp size_options(sizes) do
    prices = Installs.monthly_prices()

    Enum.map(sizes, fn size ->
      %{
        value: size,
        label:
          Enum.join(
            Enum.reject(
              [Installs.size_label(size), Installs.price_label(prices[size])],
              &is_nil/1
            ),
            " · "
          )
      }
    end)
  end

  defp load_installs(socket) do
    case Installs.list(socket.assigns[:current_user_record]) do
      # `handover_sealed` decrypts on load; it never enters an assign.
      {:ok, installs} ->
        installs = Enum.map(installs, &%{&1 | handover_sealed: nil})

        socket
        |> assign(:installs, installs)
        |> assign(:email_states, Installs.handover_email_states(installs))
        |> subscribe_installs(installs)

      {:error, _} ->
        socket |> assign(:installs, []) |> assign(:email_states, %{})
    end
  end

  defp load_requests(socket) do
    case Installs.list_requests(socket.assigns[:current_user_record]) do
      {:ok, requests} -> assign(socket, :requests, requests)
      {:error, _} -> assign(socket, :requests, [])
    end
  end

  # Live status for every listed install, subscribed once each.
  defp subscribe_installs(socket, installs) do
    if connected?(socket) do
      subscribed = socket.assigns[:subscribed] || MapSet.new()
      new = installs |> Enum.map(& &1.id) |> Enum.reject(&MapSet.member?(subscribed, &1))
      Enum.each(new, &Installs.subscribe/1)
      assign(socket, :subscribed, MapSet.union(subscribed, MapSet.new(new)))
    else
      socket
    end
  end

  @impl true
  def handle_event("validate", %{"install" => params}, socket) do
    # Stage 6: only regions where the chosen size can be created right now;
    # a region the new size lacks moves to the first one that has it.
    regions = Map.get(socket.assigns.available, params["size"]) || socket.assigns.regions

    params =
      if params["region"] in regions,
        do: params,
        else: Map.put(params, "region", List.first(regions))

    {:noreply,
     socket
     |> assign(:regions, regions)
     |> assign(:form, to_form(params, as: :install))}
  end

  def handle_event("create", %{"install" => params}, socket) do
    attrs = Map.take(params, ~w(business_name owner_email region size domain_mode primary_host))

    case Installs.create(socket.assigns[:current_user_record], attrs) do
      {:ok, %{install: install, status_token: token}} ->
        {:noreply,
         socket
         |> assign(:new_link, %{
           slug: install.slug,
           business_name: install.business_name,
           url: url(~p"/install-status/#{token}")
         })
         |> assign(:form_error, nil)
         |> reset_form()
         |> load_installs()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params, as: :install))
         |> assign(:form_error, create_error(reason))}
    end
  end

  def handle_event("provision_request", %{"id" => id}, socket) do
    case Installs.provision_request(socket.assigns[:current_user_record], id) do
      {:ok, install} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Provisioning. #{install.owner_email} gets an email when it's ready."
         )
         |> load_requests()
         |> load_installs()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, provision_error(reason)) |> load_requests()}
    end
  end

  def handle_event("dismiss_request", %{"id" => id}, socket) do
    case Installs.dismiss_request(socket.assigns[:current_user_record], id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Request dismissed.") |> load_requests()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to dismiss requests.")}

      {:error, _} ->
        {:noreply,
         socket |> put_flash(:error, "That request is already gone.") |> load_requests()}
    end
  end

  def handle_event("set_auto_provision", %{"enabled" => enabled}, socket) do
    case RequestSettings.update(socket.assigns[:current_user_record], %{
           auto_provision_requests: enabled == "true"
         }) do
      {:ok, settings} ->
        {:noreply, assign(socket, :auto_provision, settings.auto_provision_requests)}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:auto_provision, RequestSettings.get().auto_provision_requests)
         |> put_flash(:error, "You are not allowed to change this setting.")}
    end
  end

  def handle_event("dismiss_link", _params, socket),
    do: {:noreply, assign(socket, :new_link, nil)}

  def handle_event("ask_destroy", %{"slug" => slug}, socket) do
    {:noreply, socket |> assign(:confirm_slug, slug) |> assign(:confirm_text, "")}
  end

  def handle_event("cancel_destroy", _params, socket) do
    {:noreply, socket |> assign(:confirm_slug, nil) |> assign(:confirm_text, "")}
  end

  def handle_event("confirm_change", %{"confirm" => text}, socket) do
    {:noreply, assign(socket, :confirm_text, text)}
  end

  def handle_event("destroy", %{"confirm" => typed}, socket) do
    slug = socket.assigns.confirm_slug
    actor = socket.assigns[:current_user_record]

    cond do
      is_nil(slug) or String.trim(typed) != slug ->
        {:noreply, put_flash(socket, :error, "Type the install's name exactly to destroy it.")}

      Access.authorize_install(actor) != :ok ->
        {:noreply, put_flash(socket, :error, "You are not allowed to destroy installs.")}

      true ->
        {:noreply,
         socket
         |> assign(:confirm_slug, nil)
         |> assign(:confirm_text, "")
         |> update(:destroying, &MapSet.put(&1, slug))
         |> start_async({:teardown, slug}, fn -> Installs.teardown(slug) end)
         |> load_installs()}
    end
  end

  @impl true
  def handle_async({:teardown, slug}, result, socket) do
    socket = socket |> update(:destroying, &MapSet.delete(&1, slug)) |> load_installs()

    case result do
      {:ok, :ok} ->
        {:noreply, put_flash(socket, :info, "#{slug} was destroyed.")}

      {:ok, {:error, reason}} ->
        {:noreply,
         put_flash(socket, :error, "#{slug} is not fully destroyed yet (#{inspect(reason)}).")}

      {:exit, _reason} ->
        {:noreply, put_flash(socket, :error, "Destroying #{slug} stopped unexpectedly.")}
    end
  end

  @impl true
  def handle_info({:install_updated, _id}, socket), do: {:noreply, load_installs(socket)}

  def handle_info(:install_requests_changed, socket),
    do: {:noreply, socket |> load_requests() |> load_installs()}

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp provision_error(:unauthorized), do: "You are not allowed to provision installs."
  defp provision_error(:not_requested), do: "That request was already provisioned or dismissed."
  defp provision_error(:not_found), do: "That request is already gone."
  defp provision_error(:dns_zone_missing), do: create_error(:dns_zone_missing)
  defp provision_error({:invalid, _} = reason), do: create_error(reason)
  defp provision_error(_), do: "The install could not be provisioned."

  # "Will use: <region> · <size> · <price> · <slug>.<zone>": exactly what
  # Provision buys, from the same defaults provision_request/2 uses.
  defp will_use(request, defaults, prices, zone) do
    [
      Installs.region_label(List.first(defaults.regions)),
      Installs.size_label(defaults.default_size),
      Installs.price_label(prices[defaults.default_size]),
      if(zone, do: "#{request.slug}.#{zone}", else: "no zone configured")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp email_tone(state) when state in ["queued", "accepted"], do: "text-info"
  defp email_tone("not sent yet"), do: "text-subtle"
  defp email_tone(_), do: "text-error"

  defp relative(nil), do: ""

  defp relative(%DateTime{} = at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), at), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3600)} h ago"
      true -> "#{div(seconds, 86_400)} d ago"
    end
  end

  defp create_error(:unauthorized), do: "You are not allowed to create installs."

  defp create_error(:dns_zone_missing),
    do: "No zone is configured for subdomains of ours. Use the customer's own domain instead."

  defp create_error({:invalid, :business_name}),
    do: "Business name: 1 to 80 characters, without quotes, $ or backticks."

  defp create_error({:invalid, :owner_email}), do: "Owner email doesn't look like an address."
  defp create_error({:invalid, :region}), do: "Pick one of the listed regions."
  defp create_error({:invalid, :size}), do: "Pick one of the listed sizes."

  defp create_error({:invalid, :size_unavailable}),
    do: "That server size isn't available in this region right now. Pick another region."

  defp create_error({:invalid, :domain_mode}), do: "Pick how the install is addressed."

  defp create_error({:invalid, :primary_host}),
    do: "Enter the customer's domain as a host name, like shop.example.com."

  defp create_error(_), do: "The install could not be created."

  defp status_tone("ready"), do: "badge-success"
  defp status_tone("failed"), do: "badge-error"
  defp status_tone(status) when status in ~w(queued provisioning), do: "badge-info"
  defp status_tone(_), do: "badge-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full min-h-0 flex-col">
      <.breadcrumb segments={[
        %{label: "Admin", navigate: ~p"/admin"},
        %{label: "Installs", navigate: nil}
      ]} />
      <div class="flex items-center justify-between border-b border-edge px-4 py-3">
        <h1 class="text-sm font-semibold uppercase tracking-widest text-base-content">
          Admin · Installs
        </h1>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto p-4 clears-tab-bar">
        <div class="mx-auto max-w-[560px] space-y-6">
          <p class="text-sm text-subtle">
            Set up a new Burrow for a customer on its own server. The customer follows the
            progress link, then saves their sign-in details once.
          </p>

          <div
            :if={@new_link}
            id="install-new-link"
            class="space-y-3 rounded-box border-2 border-warning bg-base-100 p-4"
          >
            <p class="text-sm font-medium text-base-content">
              Progress link for {@new_link.business_name}. Send it to the customer now; it is shown
              only this once.
            </p>
            <div class="flex items-center gap-2">
              <span id="install-new-link-url" class="min-w-0 flex-1 font-mono text-sm break-all">
                {@new_link.url}
              </span>
              <button
                type="button"
                id="install-new-link-copy"
                phx-hook="CopyToClipboard"
                data-clipboard-text={@new_link.url}
                class="btn btn-ghost btn-sm min-h-11 shrink-0"
              >
                Copy
              </button>
            </div>
            <button type="button" phx-click="dismiss_link" class="btn btn-ghost btn-sm min-h-11">
              Done
            </button>
          </div>

          <section
            id="install-requests"
            data-role="install-requests"
            class="overflow-hidden rounded-box border border-edge"
          >
            <div class="space-y-2 bg-base-300 p-3">
              <div class="flex items-center gap-3">
                <h2 class="flex-1 text-sm font-semibold text-base-content">Requests</h2>
                <span :if={@requests != []} class="badge badge-sm badge-ghost">
                  {length(@requests)}
                </span>
              </div>
              <label class="flex min-h-11 cursor-pointer items-start gap-3">
                <input
                  type="checkbox"
                  id="auto-provision-toggle"
                  data-role="auto-provision-toggle"
                  class="toggle toggle-primary mt-1"
                  checked={@auto_provision}
                  phx-click="set_auto_provision"
                  phx-value-enabled={to_string(!@auto_provision)}
                  data-confirm={
                    if !@auto_provision,
                      do:
                        "Provision every new request automatically? Each one creates a server that costs money."
                  }
                />
                <span class="min-w-0 flex-1">
                  <span class="block text-sm text-base-content">
                    Provision new requests automatically
                  </span>
                  <span class="block text-xs text-subtle">
                    Off: each request waits for Provision. Every server costs money.
                  </span>
                </span>
              </label>
            </div>
            <p :if={@requests == []} class="bg-base-100 p-3 text-sm text-subtle">
              No install requests.
            </p>
            <ul :if={@requests != []} class="divide-y divide-edge bg-base-100">
              <li
                :for={request <- @requests}
                id={"install-request-#{request.id}"}
                data-role="install-request"
                class="space-y-2 p-3"
              >
                <div class="flex items-start gap-3">
                  <div class="min-w-0 flex-1">
                    <p class="truncate text-sm font-medium text-base-content">
                      {request.business_name}
                    </p>
                    <p class="truncate text-xs text-subtle">
                      {request.requester_name} · {request.owner_email}
                    </p>
                  </div>
                  <span class="shrink-0 text-xs text-subtle">{relative(request.requested_at)}</span>
                </div>
                <div :if={request.request_note} class="space-y-1">
                  <p
                    id={"install-request-note-#{request.id}"}
                    data-role="install-request-note"
                    class="line-clamp-3 whitespace-pre-line break-words text-sm text-subtle"
                  >
                    {request.request_note}
                  </p>
                  <button
                    :if={String.length(request.request_note) > 160}
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click={
                      JS.toggle_class("line-clamp-3", to: "#install-request-note-#{request.id}")
                    }
                  >
                    Show more
                  </button>
                </div>
                <p class="font-mono text-xs text-subtle" data-role="install-request-will-use">
                  Will use: {will_use(request, @defaults, @prices, @zone)}
                </p>
                <div class="flex flex-wrap gap-2">
                  <button
                    type="button"
                    phx-click="provision_request"
                    phx-value-id={request.id}
                    phx-disable-with="Provisioning…"
                    class="btn btn-primary btn-sm min-h-11"
                  >
                    Provision
                  </button>
                  <button
                    type="button"
                    phx-click="dismiss_request"
                    phx-value-id={request.id}
                    data-confirm={"Dismiss the request from #{request.owner_email}? Their details are deleted."}
                    class="btn btn-ghost btn-sm min-h-11"
                  >
                    Dismiss
                  </button>
                </div>
              </li>
            </ul>
          </section>

          <.form
            for={@form}
            id="install-form"
            phx-change="validate"
            phx-submit="create"
            class="space-y-4 rounded-box border border-edge bg-base-100 p-4"
          >
            <.input field={@form[:business_name]} type="text" label="Business name" required />
            <.input field={@form[:owner_email]} type="email" label="Owner email" required />
            <.input
              field={@form[:region]}
              type="select"
              label="Region"
              options={Enum.map(@regions, &{Installs.region_label(&1), &1})}
            />
            <fieldset class="space-y-2">
              <legend class="text-sm font-medium text-base-content">Size</legend>
              <label
                :for={option <- @size_options}
                class="flex min-h-11 cursor-pointer items-center gap-3 rounded-box border border-edge px-3"
              >
                <input
                  type="radio"
                  name="install[size]"
                  value={option.value}
                  checked={@form[:size].value == option.value}
                  class="radio radio-sm"
                />
                <span class="text-sm text-base-content">{option.label}</span>
              </label>
            </fieldset>
            <fieldset class="space-y-2">
              <legend class="text-sm font-medium text-base-content">Domain</legend>
              <label class="flex min-h-11 cursor-pointer items-center gap-3 rounded-box border border-edge px-3">
                <input
                  type="radio"
                  name="install[domain_mode]"
                  value="ours"
                  checked={@form[:domain_mode].value != "customer"}
                  class="radio radio-sm"
                />
                <span class="text-sm text-base-content">Use a Burrow subdomain</span>
              </label>
              <label class="flex min-h-11 cursor-pointer items-center gap-3 rounded-box border border-edge px-3">
                <input
                  type="radio"
                  name="install[domain_mode]"
                  value="customer"
                  checked={@form[:domain_mode].value == "customer"}
                  class="radio radio-sm"
                />
                <span class="text-sm text-base-content">Use my own domain</span>
              </label>
              <.input
                :if={@form[:domain_mode].value == "customer"}
                field={@form[:primary_host]}
                type="text"
                label="Domain (for example shop.example.com)"
              />
            </fieldset>
            <p :if={@form_error} id="install-form-error" class="text-sm text-error">
              {@form_error}
            </p>
            <button type="submit" class="btn btn-primary min-h-11 w-full sm:w-auto">
              Create install
            </button>
          </.form>

          <section class="space-y-2">
            <h2 class="text-sm font-semibold text-base-content">Installs</h2>
            <p :if={@installs == []} class="text-sm text-subtle">None yet.</p>
            <ul id="installs-list" class="divide-y divide-edge rounded-box border border-edge">
              <li :for={install <- @installs} id={"install-#{install.slug}"} class="space-y-2 p-3">
                <div class="flex items-center gap-3">
                  <div class="min-w-0 flex-1">
                    <p class="truncate text-sm font-medium text-base-content">
                      {install.business_name}
                    </p>
                    <p class="truncate font-mono text-xs text-subtle">{install.primary_host}</p>
                    <p
                      :if={install.requested_at}
                      class="truncate text-xs text-subtle"
                      data-role="install-requested-by"
                    >
                      Requested by {install.owner_email} · email
                      <span
                        class={email_tone(@email_states[install.id])}
                        data-role="install-email-state"
                      >
                        {@email_states[install.id]}
                      </span>
                    </p>
                  </div>
                  <span class={["badge badge-sm", status_tone(install.status)]}>
                    {if MapSet.member?(@destroying, install.slug),
                      do: "destroying",
                      else: install.status}
                  </span>
                  <button
                    :if={install.status != "destroyed" and @confirm_slug != install.slug}
                    type="button"
                    phx-click="ask_destroy"
                    phx-value-slug={install.slug}
                    class="btn btn-ghost btn-sm min-h-11 text-error"
                  >
                    Destroy
                  </button>
                </div>
                <form
                  :if={@confirm_slug == install.slug}
                  id={"destroy-#{install.slug}"}
                  phx-change="confirm_change"
                  phx-submit="destroy"
                  class="space-y-2 rounded-box border border-error/40 bg-error/10 p-3"
                >
                  <label class="block text-sm text-base-content" for={"destroy-input-#{install.slug}"}>
                    This deletes the customer's server and everything on it. Type
                    <span class="font-mono">{install.slug}</span>
                    to confirm.
                  </label>
                  <input
                    id={"destroy-input-#{install.slug}"}
                    name="confirm"
                    type="text"
                    value={@confirm_text}
                    autocomplete="off"
                    class="input input-sm w-full font-mono"
                  />
                  <div class="flex gap-2">
                    <button
                      type="submit"
                      disabled={String.trim(@confirm_text) != install.slug}
                      class="btn btn-error btn-sm min-h-11"
                    >
                      Destroy {install.slug}
                    </button>
                    <button
                      type="button"
                      phx-click="cancel_destroy"
                      class="btn btn-ghost btn-sm min-h-11"
                    >
                      Cancel
                    </button>
                  </div>
                </form>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </div>
    """
  end
end
