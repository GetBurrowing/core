defmodule PlatformWeb.AccessViewAsLive do
  @moduledoc "Read-only view-as surface for access managers."
  use PlatformWeb, :live_view

  alias Platform.Access.ViewAs
  alias PlatformWeb.AccessViewAs

  @impl true
  def mount(%{"type" => type, "id" => id}, _session, socket) do
    target = parse_target(type, id)

    case ViewAs.compute(socket.assigns.access_scope, target) do
      {:ok, result} ->
        {:ok,
         socket
         |> assign(:page_title, "View as")
         |> assign(:result, result)
         |> assign(:rail_keys, AccessViewAs.rail_keys(result))}

      {:error, _denial} ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to that view.")
         |> push_navigate(to: "/chat")}
    end
  end

  defp parse_target("user", id), do: {:user, id}
  defp parse_target("agent", id), do: {:agent, id}

  defp parse_target("role", id) do
    case String.split(id, ":", parts: 2) do
      [org_id, key] -> {:role, org_id, key}
      _ -> :invalid
    end
  end

  defp parse_target(_, _), do: :invalid

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-3xl space-y-6 p-6">
      <h1 class="text-2xl font-semibold">View as</h1>
      <p data-role="view-as-surface">{Atom.to_string(@result.surface)}</p>
      <p :if={@result.capped == false}>Agent scope is not capped at owner (pos 5).</p>
      <section>
        <h2 class="font-medium">Rail destinations</h2>
        <ul data-role="view-as-rail" class="mt-2 grid grid-cols-2 gap-2 text-sm">
          <li
            :for={key <- @rail_keys}
            data-destination={key}
            class="rounded border border-edge px-3 py-2"
          >
            {key}
          </li>
        </ul>
      </section>
      <section data-role="view-as-resources" class="space-y-4">
        <div>
          <h2 class="font-medium">Projects</h2>
          <ul class="mt-2 space-y-1">
            <li :for={project <- @result.resources.projects} data-resource-id={project.id}>
              {project.name}
            </li>
          </ul>
        </div>
        <div>
          <h2 class="font-medium">Channels</h2>
          <ul class="mt-2 space-y-1">
            <li :for={channel <- @result.resources.channels} data-resource-id={channel.id}>
              {channel.name}
            </li>
          </ul>
        </div>
      </section>
    </main>
    """
  end
end
