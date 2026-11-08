defmodule PlatformWeb.ControlCenter.UnattachedRuntimes do
  @moduledoc """
  The "Unattached runtimes" pane of Control Center (task 01a1b84c stage 2),
  rendered at `/control/unattached-runtimes`.

  One row per runtime `Platform.Federation.list_unattached_runtimes/1`
  returns: a runtime nobody can reach from an agent, still holding its
  `runtime_id`. Each row has a Revoke button that fires the stage-1
  `revoke_unattached_runtime` event (admin-gated by the event policy, and
  re-checked per row by `Federation.revoke_runtime/2`). The list is small and
  fully refetched after a revoke, so it is a plain assign, not a stream.

  Callers only render this for admins (`Access.Agents.may_create_ownerless?/1`);
  `admins_only/1` is what a member sees at the URL instead.
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.Components.ChatHelpers, only: [relative_time: 1]

  attr :runtimes, :list, required: true
  attr :owners, :map, default: %{}

  def panel(assigns) do
    ~H"""
    <section
      id="unattached-runtimes-panel"
      class="mx-auto flex w-full max-w-5xl flex-col gap-4 px-4 py-6 sm:px-6 sm:py-8"
    >
      <header class="flex items-start justify-between gap-3">
        <div>
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content">
            Unattached runtimes
          </p>
          <p class="mt-1 text-sm text-base-content">
            Runtimes no agent can reach. Each still holds its runtime ID; revoke one to free it.
          </p>
        </div>
        <.link navigate={~p"/control"} class="btn btn-ghost btn-sm">
          <span class="hero-arrow-left h-4 w-4" /> Agents
        </.link>
      </header>

      <p
        :if={@runtimes == []}
        id="unattached-runtimes-empty"
        class="rounded-2xl border border-edge bg-base-100 px-4 py-8 text-center text-sm text-subtle"
      >
        No unattached runtimes.
      </p>

      <ul :if={@runtimes != []} id="unattached-runtimes-list" class="flex flex-col gap-3">
        <li
          :for={runtime <- @runtimes}
          id={"unattached-runtime-#{runtime.id}"}
          data-runtime-id={runtime.runtime_id}
          class="flex flex-col gap-3 rounded-2xl border border-edge bg-base-100 px-4 py-4 sm:flex-row sm:items-center sm:gap-4"
        >
          <div class="flex min-w-0 flex-1 flex-col gap-1">
            <div class="flex flex-wrap items-center gap-2">
              <code class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-sm text-base-content">
                {runtime.runtime_id}
              </code>
              <span class={["badge badge-sm", status_badge_class(runtime.status)]}>
                {runtime.status}
              </span>
            </div>
            <span :if={runtime.display_name} class="text-sm text-base-content">
              {runtime.display_name}
            </span>
            <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-subtle">
              <span>owner {owner_name(@owners, runtime.owner_user_id)}</span>
              <span>last connected {last_connected(runtime.last_connected_at)}</span>
              <span>created {relative_time(runtime.inserted_at)}</span>
            </div>
          </div>

          <button
            type="button"
            phx-click="revoke_unattached_runtime"
            phx-value-id={runtime.id}
            data-confirm={"Revoke runtime #{runtime.runtime_id}? Its token stops working and the ID becomes free."}
            class="btn btn-error btn-outline btn-sm shrink-0"
          >
            Revoke
          </button>
        </li>
      </ul>
    </section>
    """
  end

  def admins_only(assigns) do
    ~H"""
    <section
      id="unattached-runtimes-admins-only"
      class="mx-auto flex w-full max-w-5xl flex-col gap-3 px-4 py-6 sm:px-6 sm:py-8"
    >
      <p class="text-xs font-semibold uppercase tracking-widest text-base-content">
        Unattached runtimes
      </p>
      <p class="rounded-2xl border border-edge bg-base-100 px-4 py-6 text-sm text-subtle">
        Admins only. Ask an admin to revoke an unattached runtime.
      </p>
      <.link navigate={~p"/control"} class="link link-primary text-sm">Back to agents</.link>
    </section>
    """
  end

  defp status_badge_class("active"), do: "badge-success"
  defp status_badge_class("suspended"), do: "badge-warning"
  defp status_badge_class(_), do: "badge-ghost"

  defp owner_name(owners, owner_user_id) do
    case Map.get(owners, owner_user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) -> email
      _ -> "unknown"
    end
  end

  defp last_connected(nil), do: "never"
  defp last_connected(%DateTime{} = at), do: relative_time(at)
end
