defmodule PlatformWeb.InstructionPackController do
  use PlatformWeb, :controller

  def show(conn, %{"pack_id" => id, "version" => version}) do
    release =
      with {number, ""} <- Integer.parse(version),
           do: Platform.InstructionPacks.get_release(id, number)

    case release do
      %Platform.InstructionPacks.Release{} = r ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> put_resp_header("etag", ~s("#{r.digest}"))
        |> send_resp(200, r.envelope)

      _ ->
        send_resp(conn, 404, "")
    end
  end
end
