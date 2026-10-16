defmodule PlatformWeb.Plugs.ExtensionRoutesTest do
  @moduledoc """
  The `routes/0` reader end to end through the real router and endpoint,
  with `Platform.FixtureExtension` as the positive control:

    * `/api/ext/fixture/x` reaches the fixture's plug, prefix shifted off;
    * an unknown prefix is a 404 JSON;
    * with the fixture unregistered, the same path is a 404 (read per request);
    * the `:extension_api` pipeline gets no session, no CSRF (architect note:
      a later extension must not be able to assume a logged-in user).

  NOT async: registering writes `:platform, :extensions`.
  """
  use PlatformWeb.ConnCase, async: false

  alias Platform.FixtureExtension

  test "a registered prefix reaches the extension's plug with the prefix shifted off", %{
    conn: conn
  } do
    FixtureExtension.register()
    conn = post(conn, "/api/ext/fixture/x/y", %{"a" => 1})

    assert %{
             "method" => "POST",
             "path_info" => ["x", "y"],
             "script_name" => ["api", "ext", "fixture"],
             "tag" => "fixture"
           } = json_response(conn, 200)
  end

  test "GET reaches it too; the plug, not core, decides methods", %{conn: conn} do
    FixtureExtension.register()

    assert %{"method" => "GET", "path_info" => []} =
             json_response(get(conn, "/api/ext/fixture"), 200)
  end

  test "an unknown prefix, or no prefix, is a 404", %{conn: conn} do
    FixtureExtension.register()
    assert json_response(post(conn, "/api/ext/nope/x", %{}), 404) == %{"error" => "not_found"}
    assert json_response(post(build_conn(), "/api/ext", %{}), 404) == %{"error" => "not_found"}
  end

  test "with the fixture unregistered the route is a 404", %{conn: conn} do
    FixtureExtension.register([])
    assert json_response(post(conn, "/api/ext/fixture/x", %{}), 404) == %{"error" => "not_found"}
  end

  test "the extension pipeline sets no session cookie", %{conn: conn} do
    FixtureExtension.register()
    conn = post(conn, "/api/ext/fixture/x", %{})
    assert conn.status == 200
    assert get_resp_header(conn, "set-cookie") == []
  end

  test ":extension_api never gains fetch_session, CSRF or an auth plug" do
    source = File.read!(Path.expand("../../../lib/platform_web/router.ex", __DIR__))
    [_, body] = Regex.run(~r/pipeline :extension_api do\n(.*?)\n  end/s, source)

    plugs =
      ~r/^\s*plug\(?\s*([^,\s\)]+)/m
      |> Regex.scan(body, capture: :all_but_first)
      |> List.flatten()

    assert plugs == [":accepts"]
  end
end
