defmodule PlatformWeb.Files.BrowserView do
  @moduledoc """
  Pure view helpers for the Files & Canvases browser (Burrow redesign rung
  16, task 01a1557a-b5f9): the URL builder, the layout choice, the masked
  label map, the breadcrumbs and the node labels. None of them touches a
  socket; `PlatformWeb.FilesLive` and `PlatformWeb.Files.BrowserComponents`
  call them at render time.

  Moved out of `files_live.ex` in stage 3 (orchestrator decision after the
  stage-2 audit) so the LiveView keeps only socket and event code; see the
  line ceiling in `test/platform_web/live/files_live_code_line_ratchet_test.exs`.
  """

  alias Platform.Chat.SidebarMask

  @url_keys ~w(project_id tab org space q file type sort highlight)

  @doc "The query keys (plus `project_id`) a browser URL may carry."
  @spec url_keys() :: [String.t()]
  def url_keys, do: @url_keys

  @doc """
  The URL for a browser state: `params` (string keys, as in `@browser.params`)
  merged with `overrides`; a nil value drops its key. A `project_id` becomes
  the `/files/:project_id` path.
  """
  @spec browser_path(map(), map()) :: String.t()
  def browser_path(params, overrides) do
    merged =
      params
      |> Map.merge(overrides)
      |> Map.take(@url_keys)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    {project_id, query} = Map.pop(merged, "project_id")
    base = if project_id, do: "/files/#{project_id}", else: "/files"

    if query == %{}, do: base, else: base <> "?" <> URI.encode_query(Enum.sort(query))
  end

  @doc """
  The layout to render: the viewer's stored choice, else grid for the Images
  chip and list for everything else.
  """
  def browser_layout(_browser, pref) when pref in [:list, :grid], do: pref
  def browser_layout(%{type: :image}, _pref), do: :grid
  def browser_layout(_browser, _pref), do: :list

  @doc """
  The label map every browser component reads org, project and channel names
  from, built at RENDER time from `masked?` (see "Name masking" in the
  moduledoc).
  """
  @spec browser_labels(map(), list(), boolean()) :: map()
  def browser_labels(tree, sections, masked?) do
    ctx = SidebarMask.context(sections, masked?, MapSet.new())

    # Re-key the Chat rail's section letters by org id: the same org carries
    # the same "Workspace X" as in the rail.
    org_placeholders =
      Enum.reduce(sections, %{}, fn %{section: section}, acc ->
        Map.put_new(acc, section.org_id, Map.fetch!(ctx.placeholders, section.id))
      end)

    orgs =
      Map.new(tree.orgs, fn %{org: org} ->
        {org.id, SidebarMask.label(org_placeholders, org.id, org.name, masked?, [])}
      end)

    projects = Enum.flat_map(tree.orgs, & &1.projects) ++ tree.other.projects

    project_placeholders =
      SidebarMask.placeholders(Enum.map(projects, &{&1.id, &1.name}), "Project")

    spaces = Enum.flat_map(tree.orgs, & &1.spaces) ++ tree.other.spaces

    %{
      orgs: orgs,
      projects:
        Map.new(projects, fn project ->
          {project.id,
           SidebarMask.label(project_placeholders, project.id, project.name, masked?, [])}
        end),
      spaces: Map.new(spaces, &{&1.id, space_text(&1, ctx, sections)}),
      other: "Other spaces",
      unknown_org: "Workspace",
      unknown_project: "Project",
      unknown_space: "Space"
    }
  end

  defp space_text(%{kind: "channel", name: name} = space, ctx, sections) when is_binary(name),
    do: "#" <> channel_text(space, name, ctx, sections)

  defp space_text(%{name: name} = space, ctx, sections) when is_binary(name) and name != "",
    do: channel_text(space, name, ctx, sections)

  defp space_text(_space, _ctx, _sections), do: "Conversation"

  # The Chat rail labels a channel row against ITS OWN section
  # (`SidebarMask.channel_label/3`). Use the space's org section the same
  # way when the name names that org, so the letter matches the rail even
  # when two visible orgs share a name (stage-5 review advisory). Otherwise
  # fall back to the whole-rail match (`space_label/3`), which fails closed.
  defp channel_text(space, name, ctx, sections) do
    org_id = Map.get(space, :org_id)
    own = org_id && Enum.find(sections, fn %{section: section} -> section.org_id == org_id end)

    if own && SidebarMask.names_org?(name, own.section),
      do: SidebarMask.channel_label(ctx, own.section, name),
      else: SidebarMask.space_label(ctx, sections, name)
  end

  @doc "Breadcrumbs for a Browse view: All > Org > Project|#space."
  def browser_crumbs(%{mode: :browse, node: node}, labels) do
    all = %{label: "All", href: browser_path(%{"tab" => "browse"}, %{})}

    case node do
      :all ->
        [%{all | href: nil}]

      :other ->
        [all, %{label: labels.other, href: nil}]

      {:org, org} ->
        [all, %{label: Map.get(labels.orgs, org.id, labels.unknown_org), href: nil}]

      {:project, project} ->
        [
          all,
          org_crumb(project.org_id, labels),
          %{label: Map.get(labels.projects, project.id, labels.unknown_project), href: nil}
        ]

      {:space, space} ->
        [
          all,
          org_crumb(space.org_id, labels),
          %{label: Map.get(labels.spaces, space.id, labels.unknown_space), href: nil}
        ]

      _ ->
        [%{all | href: nil}]
    end
  end

  def browser_crumbs(_browser, _labels), do: []

  defp org_crumb(org_id, labels) do
    case Map.fetch(labels.orgs, org_id || "") do
      {:ok, label} ->
        %{label: label, href: browser_path(%{"tab" => "browse", "org" => org_id}, %{})}

      :error ->
        %{label: labels.other, href: browser_path(%{"tab" => "browse", "org" => "other"}, %{})}
    end
  end

  @doc "The masked label for a child node of All or an org."
  def node_label(%{kind: :org, id: id}, labels), do: Map.get(labels.orgs, id, labels.unknown_org)
  def node_label(%{kind: :other}, labels), do: labels.other

  def node_label(%{kind: :project, id: id}, labels),
    do: Map.get(labels.projects, id, labels.unknown_project)

  def node_label(%{kind: :space, id: id}, labels),
    do: Map.get(labels.spaces, id, labels.unknown_space)
end
