defmodule PlatformWeb.GettingStartedLive do
  @moduledoc """
  `/setup/getting-started`: "Burrow is getting ready", the holding screen a
  new install's owner sees for the few seconds after a hand-over sign-in
  while the starter key provisions Burrow (`Platform.Agents.Burrow.Starter`).

  Provisioning runs in a task started by `Starter.handover_landing/1` inside
  the OIDC callback, not in the request, so the owner never waits on the
  agent host for a response. This view:

    * subscribes to `Starter.topic/1` first, then checks the database
      (`Starter.ready_path/0`), so a task that finished between the redirect
      and the mount is not missed;
    * navigates to the Getting started conversation on `{:starter, {:ok, _}}`
      and to `/setup/connect-ai` on any other result;
    * gives up after `@wait_ms` and goes to the picker, after one last
      database check, so a lost broadcast never strands anyone.

  Anyone who is not an install admin is sent to the picker at once: there is
  nothing to wait for. The route sits in the `:admin` live_session and the
  mount re-checks `Tenancy.root_admin?/1`, as `ConnectAiLive` does.
  """
  use PlatformWeb, :live_view

  alias Platform.Agents.Burrow
  alias Platform.Agents.Burrow.Starter
  alias Platform.Tenancy

  @picker "/setup/connect-ai"
  @wait_ms 45_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user_record]

    cond do
      not Tenancy.root_admin?(user) ->
        {:ok, redirect(socket, to: "/access-denied?module=admin")}

      path = Starter.ready_path() ->
        {:ok, push_navigate(socket, to: path)}

      not Starter.configured?() ->
        {:ok, push_navigate(socket, to: @picker)}

      true ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Platform.PubSub, Starter.topic(user))
          Process.send_after(self(), :give_up, wait_ms())
        end

        # Subscribed first, then read: a result broadcast before the
        # subscription is caught by this read, one after it by handle_info.
        socket =
          socket
          |> assign(:page_title, "Getting started")
          |> assign(:agent_name, Burrow.name())

        case connected?(socket) && Starter.ready_path() do
          path when is_binary(path) -> {:ok, push_navigate(socket, to: path)}
          _ -> {:ok, socket}
        end
    end
  end

  @impl true
  def handle_info({:starter, {:ok, %{slug: slug}}}, socket) do
    {:noreply, push_navigate(socket, to: "/chat/" <> slug)}
  end

  def handle_info({:starter, _failed}, socket) do
    {:noreply, push_navigate(socket, to: @picker)}
  end

  def handle_info(:give_up, socket) do
    {:noreply, push_navigate(socket, to: Starter.ready_path() || @picker)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :picker, @picker)

    ~H"""
    <div class="h-full overflow-y-auto bg-base-100">
      <div
        id="getting-started-wait"
        class="mx-auto w-full max-w-[560px] px-4 pt-10 pb-[calc(2.5rem+env(safe-area-inset-bottom))] space-y-4"
      >
        <h1 class="text-2xl font-semibold text-base-content">{@agent_name} is getting ready</h1>
        <p class="flex items-center gap-3 text-base text-base-content">
          <span class="loading loading-spinner loading-sm shrink-0" aria-hidden="true" />
          <span>This takes a few seconds. You will be taken to your first conversation.</span>
        </p>
        <p class="text-sm text-subtle">
          Nothing to do here. If this screen stays for more than a minute, <.link
            id="getting-started-picker"
            navigate={@picker}
            class="link"
          >
            choose your AI yourself
          </.link>.
        </p>
      </div>
    </div>
    """
  end

  defp wait_ms, do: Application.get_env(:platform, __MODULE__, [])[:wait_ms] || @wait_ms
end
