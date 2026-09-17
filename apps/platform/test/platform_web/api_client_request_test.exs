defmodule PlatformWeb.ApiClientRequestTest do
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]

  alias PlatformWeb.ApiClientRequest

  defp build(headers) do
    Enum.reduce(headers, conn(:get, "/", nil), fn {k, v}, acc ->
      Plug.Conn.put_req_header(acc, k, v)
    end)
  end

  @cases [
    {"no headers", [], false},
    {"accept: text/html browser navigation",
     [{"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}], false},
    {"accept: */*", [{"accept", "*/*"}], false},
    {"accept: application/json", [{"accept", "application/json"}], true},
    {"accept: application/octet-stream", [{"accept", "application/octet-stream"}], true},
    {"authorization with no accept", [{"authorization", "Bearer abc"}], true},
    {"authorization wins over accept: text/html",
     [{"authorization", "Bearer abc"}, {"accept", "text/html"}], true}
  ]

  for {name, headers, expected} <- @cases do
    test "#{name} -> #{expected}" do
      assert ApiClientRequest.api_client?(build(unquote(Macro.escape(headers)))) ==
               unquote(expected)
    end
  end
end
