defmodule PlatformWeb.InstructionPackControllerTest do
  use PlatformWeb.ConnCase, async: false
  import Platform.FeedbackBrokerFixtures
  import Platform.InstructionPackFixtures
  @path "/api/feedback-broker/v1/instruction-packs/setup-guide/1"
  setup do
    broker_node!(self())
    :ok
  end

  test "download returns the immutable signed envelope and no upload route exists", %{conn: conn} do
    {e, roots} = envelope()
    {:ok, r} = Platform.InstructionPacks.publish(e, roots)
    response = get(conn, @path)
    assert response(response, 200) == r.envelope
    assert get_resp_header(response, "etag") == [~s("#{r.digest}")]
    assert response(get(build_conn(), @path <> "junk"), 404) == ""

    assert response(get(build_conn(), String.replace(@path, "/1", "/99", global: false)), 404) ==
             ""
  end

  test "latest is a broker-gated non-cached signed head, not an apply endpoint", %{conn: conn} do
    {one, roots} = envelope()
    {:ok, _} = Platform.InstructionPacks.publish(one, roots)

    {two, _} =
      envelope(
        manifest(%{
          "version" => 2,
          "previous_digest" => Platform.InstructionPacks.Manifest.digest(one["manifest"])
        })
      )

    {:ok, release} = Platform.InstructionPacks.publish(two, roots)
    path = "/api/feedback-broker/v1/instruction-packs/setup-guide/latest"
    result = get(conn, path)
    assert response(result, 200) == release.envelope
    assert get_resp_header(result, "cache-control") == ["no-store"]
    Application.put_env(:platform, :feedback_broker_server, enabled: false)
    assert json_response(get(build_conn(), path), 404) == %{"error" => "not_found"}
  end

  test "normal installs do not expose pack downloads", %{conn: conn} do
    Application.put_env(:platform, :feedback_broker_server, enabled: false)
    assert json_response(get(conn, @path), 404) == %{"error" => "not_found"}
  end

  test "broker catalog discovers published ids but contains no prompt text", %{conn: conn} do
    {e, roots} = envelope()
    {:ok, _} = Platform.InstructionPacks.publish(e, roots)

    assert json_response(get(conn, "/api/feedback-broker/v1/instruction-packs"), 200) == %{
             "packs" => ["setup-guide"]
           }
  end
end
