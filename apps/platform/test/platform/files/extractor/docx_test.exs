defmodule Platform.Files.Extractor.DOCXTest do
  use ExUnit.Case, async: false

  alias Platform.Files.Extractor.DOCX

  @docx_ct "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    previous = Application.get_env(:platform, :files_service)

    Application.put_env(:platform, :files_service,
      base_url: "http://files-service:8200",
      token: "devtoken",
      timeout: 1_000
    )

    on_exit(fn ->
      Application.delete_env(:platform, :files_service_req_client)

      if previous,
        do: Application.put_env(:platform, :files_service, previous),
        else: Application.delete_env(:platform, :files_service)
    end)

    :ok
  end

  defp install_stub(fun) do
    Req.Test.stub(:docx_extractor_test, fun)

    Application.put_env(
      :platform,
      :files_service_req_client,
      Req.new(plug: {Req.Test, :docx_extractor_test})
    )
  end

  test "delegates to ServiceClient with the docx content_type" do
    test_pid = self()

    install_stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req, body})
      Req.Test.json(conn, %{"text" => "quarterly board minutes", "pages" => nil})
    end)

    assert {:ok, %{text: "quarterly board minutes", pages: nil}} = DOCX.extract("PK\x03\x04")

    assert_receive {:req, body}
    assert body =~ @docx_ct
  end

  test "returns :service_disabled when unconfigured" do
    Application.delete_env(:platform, :files_service)
    assert {:error, :service_disabled} = DOCX.extract("PK")
  end
end
