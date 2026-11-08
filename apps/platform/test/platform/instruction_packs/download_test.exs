defmodule Platform.InstructionPacks.DownloadTest do
  use ExUnit.Case, async: false
  import Platform.InstructionPackFixtures
  alias Platform.InstructionPacks.Download

  setup do
    old = Application.get_env(:platform, Platform.Feedback.GithubPublisher)

    Application.put_env(:platform, Platform.Feedback.GithubPublisher,
      broker_url: Platform.Feedback.GithubPublisher.Broker.default_broker_url()
    )

    # Broker config uses the same configured base URL as feedback publishing.
    on_exit(fn ->
      if old,
        do: Application.put_env(:platform, Platform.Feedback.GithubPublisher, old),
        else: Application.delete_env(:platform, Platform.Feedback.GithubPublisher)
    end)

    :ok
  end

  test "downloads signed bytes over the existing broker and refuses redirects or bad signatures" do
    {e, roots} = envelope()

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/api/feedback-broker/v1/instruction-packs/setup-guide/1"
      Plug.Conn.send_resp(conn, 200, Jason.encode!(e))
    end)

    assert {:ok, _} = Download.fetch("setup-guide", 1, roots, plug: {Req.Test, __MODULE__})

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://example.invalid/leak")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, :download_failed} =
             Download.fetch("setup-guide", 1, roots, plug: {Req.Test, __MODULE__})

    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(put_in(e, ["manifest", "changelog"], "tampered"))
      )
    end)

    assert {:error, :untrusted_pack} =
             Download.fetch("setup-guide", 1, roots, plug: {Req.Test, __MODULE__})
  end

  test "bounded catalog accepts only unique pack ids, never URLs or release authority" do
    plug = fn conn ->
      assert conn.request_path == "/api/feedback-broker/v1/instruction-packs"
      Plug.Conn.send_resp(conn, 200, ~s({"packs":["guide","roles"]}))
    end

    assert {:ok, ["guide", "roles"]} = Download.catalog(plug: plug)

    for invalid <- [
          %{"packs" => ["guide", "guide"]},
          %{"packs" => ["https://other.example"]},
          %{"packs" => ["guide"], "url" => "https://other.example"},
          %{"packs" => Enum.map(1..101, &"pack-#{&1}")}
        ] do
      assert {:error, :invalid_catalog} =
               Download.catalog(
                 plug: fn conn -> Plug.Conn.send_resp(conn, 200, Jason.encode!(invalid)) end
               )
    end
  end

  test "valid signed bytes cannot substitute a different requested version" do
    {e, roots} = envelope()
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, Jason.encode!(e)) end)

    assert {:error, :unexpected_release} =
             Download.fetch("setup-guide", 2, roots, plug: {Req.Test, __MODULE__})
  end

  test "plain HTTP and URLs with credentials fail closed" do
    for url <- ["http://example.invalid/api", "https://user:secret@example.invalid/api"] do
      Application.put_env(:platform, Platform.Feedback.GithubPublisher, broker_url: url)
      assert {:error, :invalid_pack_source} = Download.fetch("setup-guide", 1, %{})
    end
  end

  test "oversized transport and path-like ids are refused" do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, String.duplicate("x", 1_100_001))
    end)

    assert {:error, _} = Download.fetch("setup-guide", 1, %{}, plug: {Req.Test, __MODULE__})
    assert {:error, :invalid_pack_source} = Download.fetch("../other", 1, %{})
  end
end
