defmodule Platform.Files.Browser do
  @moduledoc """
  The one query layer the Files & Canvases browser (`/files`) reads
  (task 01a1557a-b5f9, Burrow redesign rung 16, stage 1).

  Every function takes the viewer as
  `%{user: %Platform.Accounts.User{}, access_scope: scope | nil}` and derives
  every project, space and org id from the database for that viewer. No
  function here trusts an id it was handed: `in_project/2` and `in_space/2`
  look the id up in the viewer's own lists and answer `:not_found` when it is
  not there, and every other read starts from those lists.

  Results are `%Platform.Files.Browser.Item{}` structs. Location LABELS (org,
  project and channel names) are deliberately NOT on an item: the rendering
  layer prints them through the name-masking context, so no unmasked name is
  baked into data.

  ## Design decisions (planner, measured on feat/redesign 0e9d32909)

    * **D1, the tree is org-rooted.** `platform_files` rows carry
      `project_id` + `org_id` and no space; `chat_canvases` carry `space_id`
      only; `chat_spaces` carry `org_id` and no project. The one node both
      trees share is the ORG, so Browse is
      All > Org > { Project (its files) | #space (its canvases and shared
      files) }. Spaces with no org (and projects with none) sit in one
      root-level `:other` bucket, as does anything whose org is not among
      the viewer's active orgs.
    * **D2, no folders.** No folder column or table exists for files,
      canvases or spaces, so there is no folder node and no "New folder".
      Building one is a migration plus move semantics, which belong with
      rung 17's Move.
    * **D3, search covers** project file names (`Files.search_files_by_name/3`,
      an escaped `ILIKE`) and canvas titles AND text (`Chat.search_canvases/3`).
      Space files (chat attachments) are not searched in this rung.
    * **D4, Recents = changed in the last 3 days.** Nothing records opens, so
      "recent" means `updated_at` within `:since` (default 3 days).
    * **D5, masking applies** to the location line, breadcrumbs and tree; it
      is done at render time, which is why no label lives on an item.
    * **D6, games** are canvases whose document holds a node of type
      `game_stream` (an extension kind). `games_enabled?/0` reports whether
      the kind is registered; core never names the extension's modules.
      Canvas and Game are exclusive types.

  ## Space files

  A space's shared files are its ready chat attachments, read from
  `Chat.list_space_attachments/2` (rung 7) and returned as
  `kind: :space_file` items whose `href` is `/chat/attachments/:id`, with
  `thumb_src` set only for images. No per-item
  `Chat.get_visible_attachment_for_principal/2` call is made: that check is
  space membership, `in_space/2` has already required the space to be one
  of the viewer's own, and `/chat/attachments/:id` re-applies the check on
  every download.
  """

  alias Platform.Chat
  alias Platform.Chat.Canvas.Kinds
  alias Platform.Files
  alias Platform.Tasks
  alias Platform.Tenancy

  defmodule Item do
    @moduledoc """
    One row of the Files & Canvases browser. See `Platform.Files.Browser`.

      * `kind` — where the row comes from: `:file` (a project file),
        `:canvas` or `:space_file` (a chat attachment).
      * `type` — what the row is: `:canvas`, `:game`, `:doc` or `:image`.
      * `thumb_src` — set for images only, nil otherwise, so a thumbnail is
        never invented for something that has none.
      * `location_href` — the Browse node the item lives under.
    """

    @type t :: %__MODULE__{
            id: binary(),
            kind: :file | :canvas | :space_file,
            type: :canvas | :game | :doc | :image,
            title: String.t() | nil,
            href: String.t(),
            thumb_src: String.t() | nil,
            org_id: binary() | nil,
            project_id: binary() | nil,
            space_id: binary() | nil,
            location_href: String.t(),
            author: String.t() | nil,
            at: DateTime.t() | nil,
            cloned?: boolean(),
            human_only?: boolean(),
            ingest_status: String.t() | nil
          }

    defstruct [
      :id,
      :kind,
      :type,
      :title,
      :href,
      :thumb_src,
      :org_id,
      :project_id,
      :space_id,
      :location_href,
      :author,
      :at,
      :ingest_status,
      cloned?: false,
      human_only?: false
    ]
  end

  @type viewer :: %{user: map(), access_scope: Platform.Access.Scope.t() | nil}
  @type item_type :: :canvas | :game | :doc | :image
  @type capped :: %{items: [Item.t()], capped?: boolean()}

  @recent_days 3
  @recent_limit 50
  @project_limit 200
  @space_limit 200
  @type_limit 100
  @search_limit 25

  @type_order %{canvas: 0, game: 1, doc: 2, image: 3}

  # ── Tree ──────────────────────────────────────────────────────────────────

  @doc """
  The Browse tree: the viewer's active orgs in a stable order (tenant
  priority, as the Files sidebar orders them), each with its readable
  projects and the viewer's spaces in it, plus an `:other` bucket for
  projects and spaces whose org is nil or not among those orgs.
  Archived spaces are excluded (the conversation query excludes them).
  """
  @spec tree(viewer()) :: %{
          orgs: [%{org: map(), projects: [map()], spaces: [map()]}],
          other: %{projects: [map()], spaces: [map()]}
        }
  def tree(viewer) do
    orgs = Tenancy.list_active_tenants_for_user(viewer.user)
    org_ids = MapSet.new(orgs, & &1.id)
    projects_by_org = Enum.group_by(projects(viewer), &bucket(&1.org_id, org_ids))
    spaces_by_org = Enum.group_by(spaces(viewer), &bucket(&1.org_id, org_ids))

    %{
      orgs:
        Enum.map(orgs, fn org ->
          %{
            org: org,
            projects: Map.get(projects_by_org, org.id, []),
            spaces: Map.get(spaces_by_org, org.id, [])
          }
        end),
      other: %{
        projects: Map.get(projects_by_org, :other, []),
        spaces: Map.get(spaces_by_org, :other, [])
      }
    }
  end

  defp bucket(org_id, org_ids) do
    if is_binary(org_id) and MapSet.member?(org_ids, org_id), do: org_id, else: :other
  end

  # ── Recents ───────────────────────────────────────────────────────────────

  @doc """
  Files and canvases changed in the last 3 days (`:since`), merged newest
  first and capped at `:limit` (default #{@recent_limit}); `capped?` says
  whether more existed.
  """
  @spec recents(viewer(), keyword()) :: capped()
  def recents(viewer, opts \\ []) do
    since = Keyword.get_lazy(opts, :since, fn -> days_ago(@recent_days) end)
    limit = Keyword.get(opts, :limit, @recent_limit)
    ctx = context(viewer)

    files =
      ctx.project_ids
      |> Files.list_recent_files_for_projects(since: since, limit: limit + 1)
      |> Enum.map(&file_item(&1, ctx))

    canvases =
      ctx.space_ids
      |> Chat.list_browser_canvases(
        since: since,
        limit: limit + 1,
        access_scope: viewer.access_scope
      )
      |> Enum.map(&canvas_item(&1, ctx))

    cap(sort(files ++ canvases, :recent), limit)
  end

  # ── One project / one space ───────────────────────────────────────────────

  @doc """
  The files of one of the viewer's projects (newest first, capped at
  #{@project_limit}), or `:not_found` when `project_id` is not one of the
  projects the viewer may read.
  """
  @spec in_project(viewer(), term()) :: {:ok, [Item.t()]} | :not_found
  def in_project(viewer, project_id) do
    ctx = context(viewer)

    case Enum.find(ctx.projects, &(&1.id == project_id)) do
      nil ->
        :not_found

      project ->
        items =
          project.id
          |> Files.list_files_for_project(limit: @project_limit, preload: :uploaded_by_user)
          |> Enum.map(&file_item(&1, ctx))

        {:ok, items}
    end
  end

  @doc """
  The canvases and shared files of one of the viewer's spaces, newest
  first, or `:not_found` when `space_id` is not a space the viewer
  participates in.
  """
  @spec in_space(viewer(), term()) :: {:ok, [Item.t()]} | :not_found
  def in_space(viewer, space_id) do
    ctx = context(viewer)

    case Map.get(ctx.spaces_by_id, space_id) do
      nil ->
        :not_found

      space ->
        canvases =
          [space.id]
          |> Chat.list_browser_canvases(limit: @space_limit, access_scope: viewer.access_scope)
          |> Enum.map(&canvas_item(&1, ctx))

        {:ok, sort(canvases ++ space_files(viewer, space), :recent)}
    end
  end

  defp space_files(viewer, space) do
    space.id
    |> Chat.list_space_attachments(scope: Map.get(viewer, :access_scope))
    |> Enum.map(&space_file_item(&1, space))
  end

  # ── By type ───────────────────────────────────────────────────────────────

  @doc """
  Every item of one type across the viewer's orgs, newest first, capped at
  `:limit` (default #{@type_limit}); `capped?` says whether more existed.
  This is what More > Canvases shows.
  """
  @spec of_type(viewer(), item_type(), keyword()) :: capped()
  def of_type(viewer, type, opts \\ [])

  def of_type(viewer, type, opts) when type in [:canvas, :game] do
    limit = Keyword.get(opts, :limit, @type_limit)
    ctx = context(viewer)

    ctx.space_ids
    |> Chat.list_browser_canvases(
      type: type,
      limit: limit + 1,
      access_scope: viewer.access_scope
    )
    |> Enum.map(&canvas_item(&1, ctx))
    |> cap(limit)
  end

  def of_type(viewer, type, opts) when type in [:doc, :image] do
    limit = Keyword.get(opts, :limit, @type_limit)
    ctx = context(viewer)

    ctx.project_ids
    |> Files.list_recent_files_for_projects(type: type, limit: limit + 1)
    |> Enum.map(&file_item(&1, ctx))
    |> cap(limit)
  end

  # ── Search ────────────────────────────────────────────────────────────────

  @doc """
  Files by name and canvases by title and text, each capped at
  #{@search_limit}: canvas hits first in rank order, then files newest
  first. A blank query returns `[]`.
  """
  @spec search(viewer(), term()) :: [Item.t()]
  def search(viewer, query) when is_binary(query) do
    if String.trim(query) == "" do
      []
    else
      ctx = context(viewer)
      scope_opts = [access_scope: viewer.access_scope]

      hits = Chat.search_canvases(ctx.space_ids, query, [limit: @search_limit] ++ scope_opts)

      # Classify each hit as canvas or game with one listing over the hit
      # ids, rather than loading documents. A hit the listing does not
      # return is dropped.
      rows =
        case Enum.map(hits, & &1.canvas.id) do
          [] ->
            %{}

          hit_ids ->
            ctx.space_ids
            |> Chat.list_browser_canvases([ids: hit_ids, limit: nil] ++ scope_opts)
            |> Map.new(&{&1.id, &1})
        end

      canvases =
        Enum.flat_map(hits, fn %{canvas: canvas} ->
          case Map.get(rows, canvas.id) do
            nil -> []
            row -> [canvas_item(row, ctx)]
          end
        end)

      files =
        ctx.project_ids
        |> Files.search_files_by_name(query, limit: @search_limit)
        |> Enum.map(&file_item(&1, ctx))

      canvases ++ files
    end
  end

  def search(_viewer, _query), do: []

  @doc """
  The `%Item{}` for one project file the caller already holds, with `org_id`
  the file's project's org. `FilesLive` builds its project node from the
  `@files` list that PubSub keeps current, so the rows and the ingest badges
  cannot disagree; the caller has already admitted the project through
  `in_project/2`'s viewer check.
  """
  @spec item_for_file(Files.File.t(), binary() | nil) :: Item.t()
  def item_for_file(%Files.File{} = file, org_id) do
    file_item(file, %{projects_by_id: %{file.project_id => %{org_id: org_id}}})
  end

  # ── Pure helpers ──────────────────────────────────────────────────────────

  @doc "Keeps the items of one type; `nil` or `:all` keeps everything."
  @spec filter([Item.t()], item_type() | :all | nil) :: [Item.t()]
  def filter(items, type) when type in [nil, :all], do: items
  def filter(items, type), do: Enum.filter(items, &(&1.type == type))

  @doc """
  Sorts items: `:recent` (newest first), `:name` (case-insensitive, then
  newest first) or `:type` (canvas, game, doc, image, then by name).
  """
  @spec sort([Item.t()], :recent | :name | :type) :: [Item.t()]
  def sort(items, :recent), do: Enum.sort(items, &newer_or_same?/2)

  def sort(items, :name) do
    items
    |> sort(:recent)
    |> Enum.sort_by(&name_key/1)
  end

  def sort(items, :type) do
    items
    |> sort(:name)
    |> Enum.sort_by(&Map.fetch!(@type_order, &1.type))
  end

  @doc "True when the `game_stream` canvas kind is registered (D6)."
  @spec games_enabled?() :: boolean()
  def games_enabled?, do: Kinds.get("game_stream") != nil

  # Enum.sort_by is stable, so sorting by name after sorting by recency keeps
  # newest-first inside equal names.
  defp name_key(%Item{title: title}), do: String.downcase(title || "")

  defp newer_or_same?(%Item{at: a}, %Item{at: b}) do
    case {a, b} do
      {nil, _} -> b == nil
      {_, nil} -> true
      _ -> DateTime.compare(a, b) != :lt
    end
  end

  defp cap(items, limit) do
    %{items: Enum.take(items, limit), capped?: length(items) > limit}
  end

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  # ── Viewer context: every id below comes from the database ────────────────

  defp context(viewer) do
    projects = projects(viewer)
    spaces = spaces(viewer)

    %{
      projects: projects,
      project_ids: Enum.map(projects, & &1.id),
      projects_by_id: Map.new(projects, &{&1.id, &1}),
      space_ids: Enum.map(spaces, & &1.id),
      spaces_by_id: Map.new(spaces, &{&1.id, &1})
    }
  end

  # The viewer's readable projects, narrowed to their ACTIVE orgs (plus
  # projects with no org). A root-org member's visibility reads every
  # project, but the Files tree has always shown only the orgs the viewer
  # belongs to: a project under a foreign org must not surface as a row, a
  # location line or an "Other" entry, and `in_project/2` answers
  # `:not_found` for it.
  defp projects(%{user: user} = viewer) do
    org_ids = user |> Tenancy.list_active_tenants_for_user() |> MapSet.new(& &1.id)

    user
    |> Tasks.list_projects_for_user(access_scope: Map.get(viewer, :access_scope))
    |> Enum.filter(&(is_nil(&1.org_id) or MapSet.member?(org_ids, &1.org_id)))
  end

  defp spaces(%{user: %{id: user_id}} = viewer) when is_binary(user_id) do
    Chat.list_user_conversations(user_id, scope: Map.get(viewer, :access_scope))
  end

  defp spaces(_viewer), do: []

  # ── Item builders ─────────────────────────────────────────────────────────

  defp file_item(%Files.File{} = file, ctx) do
    project = Map.get(ctx.projects_by_id, file.project_id)
    image? = image?(file.content_type)

    %Item{
      id: file.id,
      kind: :file,
      type: if(image?, do: :image, else: :doc),
      title: file.name || file.original_filename,
      href: "/files/#{file.project_id}?file=#{file.id}",
      thumb_src: if(image?, do: "/files/blob/#{file.id}"),
      org_id: (project && project.org_id) || file.org_id,
      project_id: file.project_id,
      space_id: nil,
      location_href: "/files/#{file.project_id}",
      author: uploader_name(file),
      at: file.updated_at,
      cloned?: false,
      human_only?: file.ingest_intent == "human_only",
      ingest_status: file.ingest_status
    }
  end

  defp canvas_item(row, ctx) do
    space = Map.get(ctx.spaces_by_id, row.space_id)

    %Item{
      id: row.id,
      kind: :canvas,
      type: if(row.game?, do: :game, else: :canvas),
      title: row.title,
      href: "/canvases/#{row.id}",
      thumb_src: nil,
      org_id: space && space.org_id,
      project_id: nil,
      space_id: row.space_id,
      location_href: "/files?space=#{row.space_id}",
      author: row.created_by_display_name,
      at: row.updated_at,
      cloned?: not is_nil(row.cloned_from),
      human_only?: false,
      ingest_status: nil
    }
  end

  defp space_file_item(attachment, space) do
    image? = image?(attachment.content_type)
    src = "/chat/attachments/#{attachment.id}"

    %Item{
      id: attachment.id,
      kind: :space_file,
      type: if(image?, do: :image, else: :doc),
      title: attachment.filename,
      href: src,
      thumb_src: if(image?, do: src),
      org_id: space.org_id,
      project_id: nil,
      space_id: space.id,
      location_href: "/files?space=#{space.id}",
      author: attachment.author,
      at: attachment.inserted_at,
      cloned?: false,
      human_only?: false,
      ingest_status: nil
    }
  end

  defp uploader_name(%Files.File{uploaded_by_user: %{name: name}}) when is_binary(name), do: name
  defp uploader_name(_file), do: nil

  # Case-insensitive, matching the `ILIKE 'image/%'` the `:image` listing uses.
  defp image?(content_type) when is_binary(content_type),
    do: content_type |> String.downcase() |> String.starts_with?("image/")

  defp image?(_content_type), do: false
end
