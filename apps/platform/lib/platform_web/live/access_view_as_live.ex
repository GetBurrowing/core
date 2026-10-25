defmodule PlatformWeb.AccessViewAsLive do
  @moduledoc "Read-only view-as surface for access managers."
  use PlatformWeb, :live_view

  alias Platform.Access.ViewAs
  alias PlatformWeb.AccessViewAs

  @impl true
  def mount(params, _session, socket) do
    target = parse_target(params)

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

  defp parse_target(%{"type" => "user", "id" => id}), do: {:user, id}
  defp parse_target(%{"type" => "agent", "id" => id}), do: {:agent, id}

  defp parse_target(%{"id" => org_id, "key" => key}),
    do: {:role, org_id, key}

  defp parse_target(_), do: :invalid

  @impl true
  def render(assigns) do
    ~H"""
    <PlatformWeb.Components.AccessViewAs.preview result={@result} rail_keys={@rail_keys} />
    """
  end

  # Burrow redesign 24 stage 5: a stray message (a shell broadcast, a late
  # reply) must not crash an admin page.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}
end
