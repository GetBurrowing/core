defmodule PlatformWeb.Files.CanvasCard do
  @moduledoc "Passive canvas thumbnail and roster-filtered live overlay (rung 17)."
  use PlatformWeb, :html
  alias PlatformWeb.AvatarComponents
  alias PlatformWeb.Tasks.StatusLabels
  attr :preview, :any, default: nil
  attr :presence, :any, default: nil

  def thumbnail(assigns) do
    ~H"""
    <span
      data-role="canvas-thumbnail"
      class="relative block aspect-[4/3] w-full overflow-hidden bg-base-200"
    >
      <span
        data-role="canvas-preview-content"
        aria-hidden="true"
        class="pointer-events-none block h-full overflow-hidden p-4 text-left text-base-content"
      >
        <%= if @preview do %>
          <span :for={node <- @preview.nodes} class="mb-2 block">
            <img
              :if={node.kind == :image}
              src={node.value}
              alt=""
              loading="lazy"
              class="max-h-28 w-full object-contain"
            />
            <span :if={node.kind == :heading} class="block text-sm font-semibold">{node.value}</span>
            <span :if={node.kind == :text} class="block text-xs leading-relaxed whitespace-pre-wrap">
              {node.value}
            </span>
          </span>
          <span :if={@preview.nodes == []} class="text-xs text-subtle">No preview available</span>
        <% else %>
          <span class="text-xs text-subtle">Loading preview…</span>
        <% end %>
      </span>
      <span
        :if={@presence && @presence.people != []}
        data-role="canvas-card-presence"
        data-leaving={to_string(@presence.leaving?)}
        class="canvas-card-presence absolute bottom-2 left-2 flex flex-col gap-1 rounded-box bg-base-100 px-2 py-1 text-[13px] text-base-content shadow-sm"
      >
        <span class="flex items-center gap-1.5">
          <span class={["size-1.5 rounded-full", StatusLabels.dot_class("in_progress")]}></span>Editing now
        </span>
        <span class="flex items-center -space-x-1">
          <span
            :for={person <- Enum.take(@presence.people, 3)}
            data-role="canvas-card-person"
            data-person-id={person.principal_id}
            data-agent-slot={if person.participant_type == "agent", do: person.slot}
            class={[
              "rounded-full ring-2 ring-base-100",
              person.participant_type == "agent" && "canvas-card-agent"
            ]}
          >
            <AvatarComponents.agent_avatar
              :if={person.participant_type == "agent"}
              name={person.name}
              avatar_url={person.avatar_url}
              size="xs"
            />
            <AvatarComponents.human_avatar
              :if={person.participant_type == "user"}
              name={person.name}
              avatar_url={person.avatar_url}
              size="xs"
              seed={person.principal_id}
            />
          </span>
          <span
            :if={length(@presence.people) > 3}
            data-role="canvas-card-overflow"
            class="pl-2 tabular-nums"
          >
            +{length(@presence.people) - 3}
          </span>
        </span>
      </span>
    </span>
    """
  end
end
