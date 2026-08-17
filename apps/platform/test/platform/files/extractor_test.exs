defmodule Platform.Files.ExtractorTest do
  @moduledoc """
  Dispatch surface for `Platform.Files.Extractor`.

  Per-format coverage lives in `extractor/<format>_test.exs`. These
  tests only verify the routing layer — content_type → module — and the
  FileRow→bytes plumbing.
  """

  use ExUnit.Case, async: false

  alias Platform.Files.Extractor
  alias Platform.Files.File, as: FileRow

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    previous_files = Application.get_env(:platform, :files_service)
    previous_root = Application.get_env(:platform, :chat_attachments_root)

    root =
      Platform.TestTemp.path("platform-files-extractor-test")

    File.mkdir_p!(root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf!(root)
      Application.delete_env(:platform, :files_service_req_client)

      if previous_files,
        do: Application.put_env(:platform, :files_service, previous_files),
        else: Application.delete_env(:platform, :files_service)

      if previous_root,
        do: Application.put_env(:platform, :chat_attachments_root, previous_root),
        else: Application.delete_env(:platform, :chat_attachments_root)
    end)

    {:ok, root: root}
  end

  defp file_row(content_type, storage_key) do
    %FileRow{content_type: content_type, storage_key: storage_key}
  end

  defp stage_binary(root, bytes, storage_key) do
    dst = Path.join(root, storage_key)
    File.mkdir_p!(Path.dirname(dst))
    File.write!(dst, bytes)
    :ok
  end

  describe "extract/1 (FileRow) dispatch" do
    test "returns :unsupported_content_type for unknown MIME" do
      assert {:error, {:unsupported_content_type, "application/x-weird"}} =
               Extractor.extract(file_row("application/x-weird", "files/p/f/x"))
    end

    test "returns :unsupported_content_type for nil content_type" do
      assert {:error, {:unsupported_content_type, nil}} =
               Extractor.extract(file_row(nil, "files/p/f/x"))
    end

    test "routes text/plain to the in-process Text extractor", %{root: root} do
      stage_binary(root, "hello world", "files/p/f/sample.txt")

      assert {:ok, %{text: "hello world", pages: nil}} =
               Extractor.extract(file_row("text/plain", "files/p/f/sample.txt"))
    end

    test "routes text/markdown to the in-process Text extractor", %{root: root} do
      stage_binary(root, "# heading", "files/p/f/sample.md")

      assert {:ok, %{text: "# heading", pages: nil}} =
               Extractor.extract(file_row("text/markdown", "files/p/f/sample.md"))
    end

    test "routes text/csv to the CSV extractor", %{root: root} do
      stage_binary(root, "name,age\nAlice,30\n", "files/p/f/sample.csv")

      assert {:ok, %{text: text, pages: nil}} =
               Extractor.extract(file_row("text/csv", "files/p/f/sample.csv"))

      assert text =~ "name: Alice"
      assert text =~ "age: 30"
    end

    test "routes application/vnd.google-apps.document to the GDoc stub" do
      assert {:error, :handled_externally} =
               Extractor.extract(file_row("application/vnd.google-apps.document", "drive:abc"))
    end

    test "missing storage_key on binary format surfaces as error" do
      Application.put_env(:platform, :files_service, base_url: "http://x", timeout: 1_000)

      assert {:error, :missing_storage_key} =
               Extractor.extract(file_row("application/pdf", nil))
    end

    test "missing on-disk file surfaces enoent rather than raising", %{root: _root} do
      assert {:error, :enoent} =
               Extractor.extract(file_row("text/plain", "files/p/f/does-not-exist.txt"))
    end
  end

  describe "extract/2 (bytes, content_type) dispatch" do
    test "routes text/plain to the in-process Text extractor" do
      assert {:ok, %{text: "hello", pages: nil}} = Extractor.extract("hello", "text/plain")
    end

    test "routes text/csv to the CSV extractor" do
      assert {:ok, %{text: text, pages: nil}} =
               Extractor.extract("name,age\nAlice,30\n", "text/csv")

      assert text =~ "name: Alice"
    end

    test "returns :unsupported_content_type for unknown MIME" do
      assert {:error, {:unsupported_content_type, "application/x-weird"}} =
               Extractor.extract("bytes", "application/x-weird")
    end

    test "PDF route reaches the ServiceClient (and returns :service_disabled when unconfigured)" do
      Application.delete_env(:platform, :files_service)

      assert {:error, :service_disabled} = Extractor.extract("%PDF-1.4", "application/pdf")
    end

    # Regression for task 019ee080 stage 3 e2e failure: a prior `extract/2`
    # used `function_exported?(module, :extract, 1)` as a guard. In a cold
    # BEAM the per-format module isn't loaded until first call, so the guard
    # returns false and EVERY content type fell through to
    # `:unsupported_content_type` in production. Test suites masked it because
    # `mix test` pre-compiles + loads all modules. This test purges the per-
    # format module right before dispatch to mimic the cold-load state.
    test "extract/2 succeeds even when the per-format module isn't yet loaded (cold-BEAM regression)" do
      # `:code.purge` + `:code.delete` drop the module from the code server.
      # The next call into it must re-load via `Code.ensure_loaded/1` or
      # rely on dispatcher logic that doesn't introspect for membership.
      :code.purge(Platform.Files.Extractor.Text)
      :code.delete(Platform.Files.Extractor.Text)

      assert {:ok, %{text: "hi", pages: nil}} = Extractor.extract("hi", "text/plain")
    end
  end

  describe "extract/1 dispatch into binary formats with running ServiceClient" do
    test "PDF FileRow → bytes → ServiceClient happy path", %{root: root} do
      stage_binary(root, "%PDF-1.4 hello", "files/p/f/sample.pdf")

      Application.put_env(:platform, :files_service,
        base_url: "http://files-service:8200",
        token: "devtoken",
        timeout: 1_000
      )

      Req.Test.stub(:extractor_dispatch_test, fn conn ->
        Req.Test.json(conn, %{"text" => "extracted pdf body", "pages" => ["extracted pdf body"]})
      end)

      Application.put_env(
        :platform,
        :files_service_req_client,
        Req.new(plug: {Req.Test, :extractor_dispatch_test})
      )

      assert {:ok, %{text: "extracted pdf body", pages: ["extracted pdf body"]}} =
               Extractor.extract(file_row("application/pdf", "files/p/f/sample.pdf"))
    end
  end

  describe "supported_content_type?/1" do
    # This list IS the contract: every MIME with a `dispatch/1` clause.
    # Assert all of them, not a sample — a dropped clause must fail here.
    @supported [
      "application/pdf",
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      "text/csv",
      "text/plain",
      "text/markdown",
      "image/png",
      "image/jpeg",
      "image/jpg",
      "image/webp",
      "application/vnd.google-apps.document"
    ]

    test "true for every content type with a dispatch clause" do
      for ct <- @supported do
        assert Extractor.supported_content_type?(ct), "expected #{ct} to be supported"
      end
    end

    test "false for nil, empty, and unextractable MIME" do
      refute Extractor.supported_content_type?(nil)
      refute Extractor.supported_content_type?("")
      refute Extractor.supported_content_type?("video/mp4")
      refute Extractor.supported_content_type?("audio/mpeg")
      refute Extractor.supported_content_type?("application/octet-stream")
      refute Extractor.supported_content_type?("application/zip")
      # Pinned deliberately: the feature ticket claimed application/json was
      # extractable. It has no dispatch clause, so it is not.
      refute Extractor.supported_content_type?("application/json")
    end

    # Coupling test: proves the predicate agrees with the real dispatcher
    # rather than with a copy of it. If someone reintroduces a hand-typed
    # list that drifts, a type answers `true` here while the dispatcher
    # still rejects it, and this fails.
    #
    # GDoc is excluded because it is not in `@bytes_overload_modules` —
    # it accepts a FileRow only, so `extract/2` legitimately answers
    # `:unsupported_content_type` for it regardless of the predicate.
    test "no supported content type is rejected by the real dispatcher" do
      Application.delete_env(:platform, :files_service)

      for ct <- @supported -- ["application/vnd.google-apps.document"] do
        refute match?({:error, {:unsupported_content_type, ^ct}}, Extractor.extract(<<0>>, ct)),
               "predicate says #{ct} is supported but extract/2 rejected it as unsupported"
      end
    end
  end
end
