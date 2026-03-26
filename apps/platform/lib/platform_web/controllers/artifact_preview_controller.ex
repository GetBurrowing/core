defmodule PlatformWeb.ArtifactPreviewController do
  use PlatformWeb, :controller

  @image_exts ~w(.png .jpg .jpeg .gif .webp .svg)

  def show(conn, %{"path" => path}) do
    expanded = Path.expand(path)

    if allowed_path?(expanded) and File.regular?(expanded) do
      ext = expanded |> Path.extname() |> String.downcase()
      mime = MIME.from_path(expanded) || content_type_for(ext)

      conn
      |> put_resp_content_type(mime)
      |> put_resp_header("content-disposition", ~s(inline; filename="#{Path.basename(expanded)}"))
      |> send_file(200, expanded)
    else
      send_resp(conn, 404, "Not found")
    end
  end

  defp allowed_path?(path) do
    roots()
    |> Enum.any?(fn root -> String.starts_with?(path, root <> "/") or path == root end)
  end

  defp roots do
    workspace_root =
      System.get_env("AGENT_WORKSPACE_PATH") ||
        Path.expand("~/.openclaw")

    [
      Path.expand(Path.join(workspace_root, "workspace/tmp")),
      Path.expand(Path.join(workspace_root, "tmp"))
    ]
  end

  defp content_type_for(ext) when ext in @image_exts,
    do: "image/#{String.trim_leading(ext, ".") |> String.replace("jpg", "jpeg")}"

  defp content_type_for(".md"), do: "text/markdown"
  defp content_type_for(".txt"), do: "text/plain"
  defp content_type_for(_), do: "application/octet-stream"
end
