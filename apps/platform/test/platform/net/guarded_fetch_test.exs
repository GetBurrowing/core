defmodule Platform.Net.GuardedFetchTest do
  use ExUnit.Case, async: true

  alias Platform.Net.GuardedFetch

  @plug __MODULE__
  @public_v4 {8, 8, 8, 8}
  @other_v4 {1, 1, 1, 1}
  @public_v6 {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}

  test "rejects malformed URLs, disallowed schemes, userinfo, and missing hosts" do
    assert GuardedFetch.request("%", [], resolver: %{}) == {:error, :malformed_url}

    assert GuardedFetch.request("ftp://public.example/file", [],
             resolver: %{"public.example" => [@public_v4]}
           ) == {:error, {:refused, :scheme}}

    assert GuardedFetch.request("https://user:secret@public.example/file", [],
             resolver: %{"public.example" => [@public_v4]}
           ) == {:error, {:refused, :userinfo}}

    assert GuardedFetch.request("https:///missing-host", [], resolver: %{}) ==
             {:error, :malformed_url}
  end

  test "the caller selects whether http is allowed" do
    Req.Test.stub(@plug, fn conn -> Plug.Conn.send_resp(conn, 200, "plain") end)

    assert GuardedFetch.request("http://public.example/file", [plug: {Req.Test, @plug}],
             resolver: %{"public.example" => [@public_v4]}
           ) == {:error, {:refused, :scheme}}

    assert {:ok, %{status: 200, body: "plain"}} =
             GuardedFetch.request("http://public.example/file", [plug: {Req.Test, @plug}],
               schemes: [:http, :https],
               resolver: %{"public.example" => [@public_v4]}
             )
  end

  test "parses public and forbidden IP literals without consulting the resolver" do
    parent = self()

    Req.Test.stub(@plug, fn conn ->
      send(parent, {:requested, conn.host})
      Plug.Conn.send_resp(conn, 200, "literal")
    end)

    resolver = fn _host -> flunk("literal hosts must not be resolved") end

    assert {:ok, %{url: "https://8.8.8.8/value", body: "literal"}} =
             GuardedFetch.request("https://8.8.8.8/value", [plug: {Req.Test, @plug}],
               resolver: resolver
             )

    assert_receive {:requested, "8.8.8.8"}

    assert GuardedFetch.request("https://127.0.0.1/private", [plug: {Req.Test, @plug}],
             resolver: resolver
           ) == {:error, {:refused, :forbidden_address}}

    refute_receive {:requested, _}
  end

  test "accepts public A and AAAA answers and pins the request while returning the hostname URL" do
    parent = self()

    resolver = fn host ->
      send(parent, {:resolved, host})
      {:ok, [@public_v4, @public_v6]}
    end

    Req.Test.stub(@plug, fn conn ->
      send(parent, {:request, conn.host, Plug.Conn.get_req_header(conn, "x-caller")})
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert {:ok,
            %{
              url: "https://public.example/path?q=1",
              status: 200,
              body: "ok"
            }} =
             GuardedFetch.request(
               "https://public.example/path?q=1",
               [plug: {Req.Test, @plug}, headers: [{"x-caller", "kept"}]],
               resolver: resolver
             )

    assert_receive {:resolved, "public.example"}
    assert_receive {:request, "8.8.8.8", ["kept"]}
  end

  test "refuses the whole resolution when any answer is forbidden" do
    parent = self()

    Req.Test.stub(@plug, fn conn ->
      send(parent, :requested)
      Plug.Conn.send_resp(conn, 200, "bad")
    end)

    assert GuardedFetch.request("https://mixed.example/", [plug: {Req.Test, @plug}],
             resolver: %{"mixed.example" => [@public_v4, {10, 0, 0, 1}]}
           ) == {:error, {:refused, :forbidden_address}}

    refute_receive :requested
  end

  test "reports an empty or failed resolution as unresolvable" do
    assert GuardedFetch.request("https://empty.example/", [], resolver: %{}) ==
             {:error, :unresolvable}

    assert GuardedFetch.request("https://failed.example/", [],
             resolver: fn _ -> {:error, :nxdomain} end
           ) == {:error, :unresolvable}
  end

  test "follows safe absolute and relative redirects and returns the final logical URL" do
    parent = self()

    Req.Test.stub(@plug, fn conn ->
      send(parent, {:path, conn.host, conn.request_path})

      case conn.request_path do
        "/start" ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://next.example/relative")
          |> Plug.Conn.send_resp(302, "")

        "/relative" ->
          conn
          |> Plug.Conn.put_resp_header("location", "/final")
          |> Plug.Conn.send_resp(301, "")

        "/final" ->
          Plug.Conn.send_resp(conn, 200, "done")
      end
    end)

    assert {:ok, %{url: "https://next.example/final", status: 200, body: "done"}} =
             GuardedFetch.request("https://first.example/start", [plug: {Req.Test, @plug}],
               resolver: %{
                 "first.example" => [@public_v4],
                 "next.example" => [@other_v4]
               },
               max_redirects: 2
             )

    assert_receive {:path, "8.8.8.8", "/start"}
    assert_receive {:path, "1.1.1.1", "/relative"}
    assert_receive {:path, "1.1.1.1", "/final"}
  end

  test "revalidates a redirect and refuses loopback before the second request" do
    parent = self()

    Req.Test.stub(@plug, fn conn ->
      send(parent, {:requested, conn.host})

      conn
      |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/private")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert GuardedFetch.request("https://public.example/start", [plug: {Req.Test, @plug}],
             schemes: [:http, :https],
             resolver: %{"public.example" => [@public_v4]},
             max_redirects: 1
           ) == {:error, {:refused, :forbidden_address}}

    assert_receive {:requested, "8.8.8.8"}
    refute_receive {:requested, "127.0.0.1"}
  end

  test "stops at max_redirects without fetching one hop too many" do
    parent = self()

    Req.Test.stub(@plug, fn conn ->
      send(parent, {:path, conn.request_path})
      next = if conn.request_path == "/zero", do: "/one", else: "/two"

      conn
      |> Plug.Conn.put_resp_header("location", next)
      |> Plug.Conn.send_resp(302, "")
    end)

    assert GuardedFetch.request("https://public.example/zero", [plug: {Req.Test, @plug}],
             resolver: %{"public.example" => [@public_v4]},
             max_redirects: 1
           ) == {:error, :too_many_redirects}

    assert_receive {:path, "/zero"}
    assert_receive {:path, "/one"}
    refute_receive {:path, "/two"}
  end

  test "caps the raw body in the Req.Test path" do
    Req.Test.stub(@plug, fn conn -> Plug.Conn.send_resp(conn, 200, "raw-body") end)

    assert GuardedFetch.request("https://public.example/body", [plug: {Req.Test, @plug}],
             resolver: %{"public.example" => [@public_v4]},
             max_body: 3
           ) == {:error, :too_large}
  end

  test "enforces one whole-fetch timeout around the Req.Test path" do
    Req.Test.stub(@plug, fn conn ->
      Process.sleep(100)
      Plug.Conn.send_resp(conn, 200, "late")
    end)

    started = System.monotonic_time(:millisecond)

    assert GuardedFetch.request("https://public.example/slow", [plug: {Req.Test, @plug}],
             resolver: %{"public.example" => [@public_v4]},
             timeout: 20,
             receive_timeout: 500
           ) == {:error, :timeout}

    assert System.monotonic_time(:millisecond) - started < 100
  end
end
