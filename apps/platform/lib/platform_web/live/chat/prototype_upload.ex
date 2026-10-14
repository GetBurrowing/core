defmodule PlatformWeb.ChatLive.PrototypeUpload do
  @moduledoc """
  The New canvas form's "Prototype" choice (task 01a1316b-4e46 stage 2): one
  zip drop zone that publishes through `Platform.Prototypes.publish/3` and then
  creates a canvas holding a `prototype` node for the new version.

  ## Same gate as the MCP tool

  `allowed?/2` asks `Platform.Prototypes.authorize_publish/3` with the install
  settings read now, so the choice is hidden exactly when a publish from this
  user would be refused (publishing off, or a policy that does not admit the
  user in this space's org). DMs and group conversations have no org, so they
  never offer it. Hiding is convenience: `publish/3` re-runs the same check
  and every bundle limit, and refuses with a coded error the form shows.

  ## The upload ceiling is not the cap

  `allow_upload/3` needs a size at mount, before the settings are read for
  the space, so the transport ceiling is a fixed `@max_file_size`. The real
  limit is the install's `max_bundle_bytes`, enforced on the uncompressed
  bytes by `Platform.Prototypes.Bundle`.

  Folder upload (`webkitdirectory`) is not offered: LiveView uploads do not
  carry a file's relative path, so a folder would arrive flattened. Zip the
  folder instead.
  """

  import Phoenix.LiveView, only: [allow_upload: 3, consume_uploaded_entries: 3]

  alias Platform.Accounts
  alias Platform.Chat.CanvasDocument
  alias Platform.Prototypes
  alias Platform.Prototypes.Settings

  @upload :prototype_bundle
  @max_file_size 100 * 1024 * 1024

  @doc "The `allow_upload/3` name the drop zone uses."
  def upload_name, do: @upload

  @doc "Register the zip upload on a socket (mount)."
  def allow(socket) do
    allow_upload(socket, @upload, accept: ~w(.zip), max_entries: 1, max_file_size: @max_file_size)
  end

  @doc """
  May `user_id` publish a prototype into `space`'s org right now? False for a
  space without an org (DMs, groups) and whenever publishing is off.
  """
  @spec allowed?(map() | nil, binary() | nil) :: boolean()
  def allowed?(%{org_id: org_id, kind: kind}, user_id)
      when is_binary(org_id) and is_binary(user_id) and kind not in ["dm", "group"] do
    Prototypes.authorize_publish(Settings.get(), user_publisher(%{id: user_id}), org_id) == :ok
  end

  def allowed?(_space, _user_id), do: false

  @doc """
  Consume the dropped zip and publish it as a new prototype named `title` in
  `space`'s org. Returns `{:ok, %{prototype, version}}` or `{:error, message}`.
  """
  @spec publish(Phoenix.LiveView.Socket.t(), map(), binary(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def publish(socket, %{id: space_id, org_id: org_id}, user_id, title) when is_binary(org_id) do
    zips =
      consume_uploaded_entries(socket, @upload, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    with [zip] <- zips,
         %{} = user <- Accounts.get_user(user_id),
         {:ok, result} <-
           Prototypes.publish(
             user_publisher(user),
             %{org_id: org_id, space_id: space_id, name: name(title)},
             {:zip, zip}
           ) do
      {:ok, result}
    else
      [] -> {:error, "Drop a zip of the prototype first."}
      nil -> {:error, "Sign in again to publish."}
      {:error, {_code, message}} -> {:error, "Publish failed: " <> message}
      _ -> {:error, "Publish failed."}
    end
  end

  def publish(_socket, _space, _user_id, _title),
    do: {:error, "Prototypes can only be published in a channel that belongs to an org."}

  @doc "The canvas attrs for a freshly published prototype."
  @spec canvas_attrs(map(), String.t()) :: map()
  def canvas_attrs(%{prototype: prototype}, title) do
    document =
      CanvasDocument.new()
      |> Map.put("root", %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [
          %{
            "id" => "prototype",
            "type" => "prototype",
            "props" => %{"prototype_id" => prototype.id}
          }
        ]
      })

    %{"title" => name(title), "document" => document}
  end

  @doc "The success flash: the same version stamp the canvas bar shows."
  @spec success_message(map()) :: String.t()
  def success_message(%{prototype: prototype, version: version}) do
    stamp =
      PlatformWeb.Components.Canvases.PrototypeFrame.stamp(version.version, version.inserted_at)

    "Published #{prototype.name} #{stamp}"
  end

  defp user_publisher(user), do: %{kind: :user, user: user}

  defp name(title) when is_binary(title) do
    case String.trim(title) do
      "" -> "Prototype"
      t -> t
    end
  end

  defp name(_), do: "Prototype"
end
