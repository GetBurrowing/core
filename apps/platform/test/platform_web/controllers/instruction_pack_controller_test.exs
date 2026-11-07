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

  test "normal installs do not expose pack downloads", %{conn: conn} do
    Application.put_env(:platform, :feedback_broker_server, enabled: false)
    assert json_response(get(conn, @path), 404) == %{"error" => "not_found"}
  end
end
