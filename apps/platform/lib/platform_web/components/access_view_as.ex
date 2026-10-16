defmodule PlatformWeb.Components.AccessViewAs do
  use Phoenix.Component
  attr(:result, :map, required: true)
  attr(:rail_keys, :list, required: true)

  def preview(assigns) do
    ~H"""
    <section class="space-y-6">
      <h1 class="text-2xl font-semibold">View as</h1>
      <p data-role="view-as-surface">{Atom.to_string(@result.surface)}</p>
      <p :if={@result.capped == true}>Agent scope is capped at owner.</p>
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
    </section>
    """
  end
end
