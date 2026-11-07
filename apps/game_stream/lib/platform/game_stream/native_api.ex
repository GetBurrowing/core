defmodule Platform.GameStream.NativeAPI do
  @moduledoc "Session-scoped host admission and project-scoped CI publishing. No browser/session auth is inherited."
  @behaviour Plug
  import Plug.Conn
  alias Platform.GameStream.{NativeSessions, NativeBuild, JoinToken}
  def init(opts), do: opts

  def call(conn, _) do
    # Secrets in POST bodies/Authorization only. Never accept query credentials.
    if Platform.GameStream.enabled?() and conn.method == "POST" and conn.query_string == "" do
      dispatch(conn)
    else
      reply(conn, 401, %{error: "unauthorized"})
    end
  end

  defp dispatch(%{path_info: ["admit", session_id]} = conn) do
    with true <- Platform.UUID.valid?(session_id),
         ["Bearer " <> credential] <- get_req_header(conn, "authorization"),
         claims when is_map(claims) <- conn.body_params,
         {:ok, admission} <- NativeSessions.consume(session_id, credential, claims) do
      reply(conn, 200, admission)
    else
      _ -> reply(conn, 401, %{error: "unauthorized"})
    end
  end

  defp dispatch(%{path_info: ["builds", project_id]} = conn) do
    with true <- Platform.UUID.valid?(project_id),
         ["Bearer " <> credential] <- get_req_header(conn, "authorization"),
         true <- publisher?(project_id, credential),
         manifest when is_map(manifest) <- conn.body_params,
         {:ok, row} <- NativeBuild.register(project_id, manifest) do
      reply(conn, 200, %{id: row.id})
    else
      _ -> reply(conn, 401, %{error: "unauthorized"})
    end
  end
  defp dispatch(conn), do: reply(conn, 404, %{error: "not_found"})

  defp publisher?(id, credential) do
    expected = Application.get_env(:game_stream, :native_publishers, %{})[id]
    is_binary(expected) and byte_size(expected) == 64 and
      Plug.Crypto.secure_compare(expected, JoinToken.hash(credential))
  end
  defp reply(conn, status, body), do: conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body)) |> halt()
end
