defmodule Platform.Files.BrowserActions do
  @moduledoc """
  Actor-first eligibility and commands for browser targets `{kind, id}`.
  Menus and writes resolve current rows and rebuild the user's scope.
  Project files have no space ownership: Move is unsupported.
  Attachments keep their message ownership and offer personal stars only.
  """
  alias Platform.{Accounts, Access, Chat, Files, Repo}
  alias Platform.Access.Scope
  alias Platform.Files.{Browser, Stars}
  alias Platform.Tenancy.Lifecycle

  def viewer(%{user: user}), do: viewer(user)
  def viewer({:user, id}), do: viewer(%{id: id})

  def viewer(%{id: id}) do
    with true <- Platform.UUID.valid?(id),
         %Accounts.User{} = user <- Accounts.get_user(id) do
      {:ok, %{user: user, access_scope: Scope.for_user(user)}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def viewer(_), do: {:error, :unauthorized}

  def eligible(actor, target) do
    with {:ok, viewer} <- viewer(actor),
         {:ok, source} <- Browser.fetch_source(viewer, target) do
      star = if Stars.starred?(viewer, target), do: :unstar, else: :star
      {:ok, [star | writable_actions(viewer, target, source)]}
    end
  end

  def execute(actor, target, action, attrs \\ %{})

  def execute(actor, target, action, _attrs) when action in [:star, :unstar],
    do: Stars.set(actor, target, action == :star)

  def execute(actor, target, action, attrs) when action in [:rename, :move, :delete, :undo] do
    with {:ok, viewer} <- viewer(actor),
         {:ok, source} <- Browser.fetch_source(viewer, target, include_deleted: action == :undo),
         :ok <- writable(viewer, target, source, action) do
      command(viewer, target, source, action, attrs)
    end
  end

  def execute(_actor, _target, _action, _attrs), do: {:error, :invalid_action}

  def move_destinations(actor, {:canvas, _} = target) do
    with {:ok, viewer} <- viewer(actor),
         {:ok, source} <- Browser.fetch_source(viewer, target),
         :ok <- writable(viewer, target, source, :move) do
      source_space = Chat.get_space(source.space_id)

      {:ok,
       Chat.list_user_conversations(viewer.user.id, scope: viewer.access_scope)
       |> Enum.filter(fn space ->
         space.org_id == source_space.org_id && Chat.space_writable?(space.id) &&
           Access.check(viewer.access_scope, "canvas.write", {:space, space.id}) == :ok
       end)}
    end
  end

  def move_destinations(_actor, _target), do: {:error, :unsupported}

  @doc false
  def authorize_move(actor, canvas_id, destination_id) do
    with {:ok, viewer} <- viewer(actor),
         {:ok, canvas} <- Browser.fetch_source(viewer, {:canvas, canvas_id}),
         :ok <- writable(viewer, {:canvas, canvas_id}, canvas, :move),
         true <- Platform.UUID.valid?(destination_id),
         {:ok, destinations} <- move_destinations(viewer, {:canvas, canvas_id}),
         true <- Enum.any?(destinations, &(&1.id == destination_id)) do
      {:ok, canvas}
    else
      {:error, _} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  defp writable_actions(_viewer, {:space_file, _}, _source), do: []

  defp writable_actions(viewer, {kind, _} = target, source) do
    if writable(viewer, target, source, :rename) == :ok,
      do: if(kind == :canvas, do: [:rename, :move, :delete], else: [:rename, :delete]),
      else: []
  end

  defp writable(_viewer, {:space_file, _}, _source, _action), do: {:error, :unsupported}
  defp writable(_viewer, {:file, _}, _source, :move), do: {:error, :unsupported}

  defp writable(viewer, {:canvas, id}, canvas, action) do
    with :ok <- Access.check(viewer.access_scope, "canvas.write", {:canvas, id}),
         true <- Chat.space_writable?(canvas.space_id),
         :ok <- canvas_writer(viewer, canvas, action) do
      :ok
    else
      false -> {:error, :space_archived}
      {:error, _} = error -> error
    end
  end

  defp writable(viewer, {:file, _}, file, _action) do
    with :ok <- Access.check(viewer.access_scope, "files.write", {:project, file.project_id}),
         :ok <- Lifecycle.ensure_project_writable(file.project_id),
         do: :ok
  end

  defp canvas_writer(viewer, %{deleted_at: deleted_at} = canvas, :undo)
       when not is_nil(deleted_at) do
    if Chat.participant?(canvas.space_id, viewer.user.id), do: :ok, else: {:error, :forbidden}
  end

  defp canvas_writer(viewer, canvas, _action) do
    case Chat.CanvasAccess.fetch_for_writer(canvas.id, viewer.user) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp command(viewer, {:canvas, _}, canvas, :rename, attrs) do
    with {:ok, title} <- title(attrs),
         do: Chat.update_canvas(viewer.user, canvas, %{title: title})
  end

  defp command(viewer, {:canvas, _}, canvas, :move, attrs),
    do: Chat.Canvas.Server.move(canvas.id, viewer.user, Map.get(attrs, :space_id))

  defp command(_viewer, {:canvas, _}, canvas, :delete, _attrs), do: Chat.delete_canvas(canvas)
  defp command(_viewer, {:canvas, _}, canvas, :undo, _attrs), do: Chat.restore_canvas(canvas)

  defp command(_viewer, {:file, _}, file, :rename, attrs) do
    with {:ok, name} <- title(attrs),
         {:ok, renamed} <- file |> Ecto.Changeset.change(name: name) |> Repo.update() do
      Files.broadcast_project(file.project_id, {:file_updated, renamed.id})
      {:ok, renamed}
    end
  end

  defp command(viewer, {:file, _}, file, :delete, _attrs),
    do: Files.delete_file(viewer.user, file)

  defp command(viewer, {:file, _}, file, :undo, _attrs), do: Files.restore_file(viewer.user, file)

  defp title(attrs) do
    case Map.get(attrs, :title) do
      title when is_binary(title) ->
        value = String.trim(title)

        if value != "" && String.length(value) <= 255,
          do: {:ok, value},
          else: {:error, :invalid_title}

      _ ->
        {:error, :invalid_title}
    end
  end
end
