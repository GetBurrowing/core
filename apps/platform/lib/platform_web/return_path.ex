defmodule PlatformWeb.ReturnPath do
  @moduledoc """
  The local path a sign-in returns to (task 01a1ccd4 stage 2).

  `PlatformWeb.Plugs.RequireAuth` stores the path a signed-out browser asked
  for (GET only) under `session_key/0` before redirecting to `/auth/login`;
  `PlatformWeb.AuthController`'s callback lands there when no hand-over
  landing is set. Both sides run `safe/1`, so a value is checked when it is
  stored and again when it is used.

  Accepted: a path (plus query) on THIS host that starts with exactly one
  `/`, at most #{2048} bytes. Refused: a scheme-relative `//host`, any
  backslash (`/\\host` reads as `//host` in a browser), an absolute URL,
  control characters and whitespace, a fragment, and `/auth/` routes (a
  return to `/auth/logout` would sign straight back out).
  """

  @max_bytes 2048
  @session_key :return_to

  @doc "The session key the return path is stored under."
  def session_key, do: @session_key

  @doc "The path when it is a safe local return path, else `:error`."
  @spec safe(term()) :: {:ok, String.t()} | :error
  def safe("/" <> rest = path) when byte_size(path) <= @max_bytes do
    with false <- String.starts_with?(rest, ["/", "auth/"]) or rest == "auth",
         false <- String.contains?(path, ["\\", "#"]),
         false <- String.match?(path, ~r/[\x00-\x20\x7f]/),
         true <- String.valid?(path),
         %URI{scheme: nil, host: nil, userinfo: nil} <- URI.parse(path) do
      {:ok, path}
    else
      _ -> :error
    end
  end

  def safe(_), do: :error

  @doc "The return path for a request: its path plus query string."
  @spec of_conn(Plug.Conn.t()) :: String.t()
  def of_conn(%Plug.Conn{request_path: path, query_string: ""}), do: path
  def of_conn(%Plug.Conn{request_path: path, query_string: qs}), do: path <> "?" <> qs
end
