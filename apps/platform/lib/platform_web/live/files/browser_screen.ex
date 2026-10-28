defmodule PlatformWeb.Files.BrowserScreen do
  @moduledoc "Browser rendering kept outside FilesLive's code-line ratchet."
  use Phoenix.Component
  alias Platform.Files.Browser
  alias PlatformWeb.Files.{BrowserComponents, BrowserView}
  attr :browser, :map, required: true
  attr :files, :list, required: true
  attr :labels, :map, required: true
  attr :layout, :atom, required: true
  attr :claims, :map, required: true
  attr :viewer, :map, required: true
  attr :editing, :any, default: nil
  attr :revision, :integer, default: 0

  # The toolbar and the rows. A project node builds its rows from `@files`
  # (which PubSub keeps current), so a badge flip re-renders here; every
  # other view reads the items `handle_params/3` loaded.
  def browser_view(assigns) do
    {items, file_rows} =
      case assigns.browser.node do
        {:project, project} ->
          files = assigns.files

          {files
           |> Enum.map(&Browser.item_for_file(&1, project.org_id))
           |> Browser.filter(assigns.browser.type), Map.new(files, &{&1.id, &1})}

        _ ->
          {assigns.browser.items, %{}}
      end

    items =
      if assigns.browser.mode == :starred,
        do: items,
        else: Browser.sort(items, assigns.browser.sort)

    browser = %{assigns.browser | items: items}

    nodes =
      Enum.map(browser.nodes, fn node ->
        Map.put(node, :label, BrowserView.node_label(node, assigns.labels))
      end)

    assigns =
      assign(assigns,
        browser: browser,
        nodes: nodes,
        file_rows: file_rows,
        show_location: not match?({kind, _} when kind in [:project, :space], browser.node)
      )

    ~H"""
    <BrowserComponents.toolbar browser={@browser} layout={@layout} />
    <%= cond do %>
      <% @browser.items == [] and @nodes != [] -> %>
        <BrowserComponents.node_list nodes={@nodes} />
      <% @browser.items == [] -> %>
        <BrowserComponents.empty_state browser={@browser} labels={@labels} />
      <% @layout == :grid -> %>
        <BrowserComponents.item_grid
          browser={@browser}
          viewer={@viewer}
          editing={@editing}
          revision={@revision}
          labels={@labels}
          show_location={@show_location}
        />
      <% true -> %>
        <BrowserComponents.item_list
          browser={@browser}
          viewer={@viewer}
          editing={@editing}
          revision={@revision}
          labels={@labels}
          show_location={@show_location}
          file_rows={@file_rows}
          claims={@claims}
        />
    <% end %>
    <BrowserComponents.capped_note browser={@browser} />
    """
  end
end
