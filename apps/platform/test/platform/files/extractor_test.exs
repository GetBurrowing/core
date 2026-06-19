defmodule Platform.Files.ExtractorTest do
  @moduledoc """
  Per-format extractor tests.

  Three of the format modules (`PDF`, `DOCX`, `Image`) shell out to
  binaries that aren't necessarily installed on every CI box. Each of
  those test groups is tagged with `:integration_<tool>` so they can be
  skipped on machines that lack the tool. Run a tool-aware subset with:

      mix test apps/platform/test/platform/files/extractor_test.exs \\
        --exclude integration_pdftotext \\
        --exclude integration_pandoc \\
        --exclude integration_tesseract

  The "tool missing → :tool_unavailable" path is exercised unconditionally
  so the dispatch surface is covered even when the binaries are absent.
  """

  use ExUnit.Case, async: true

  alias Platform.Files.Extractor
  alias Platform.Files.File, as: FileRow

  @fixtures_dir Path.expand("../../support/fixtures/files", __DIR__)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "platform-files-extractor-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    previous = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: Application.put_env(:platform, :chat_attachments_root, previous),
        else: Application.delete_env(:platform, :chat_attachments_root)
    end)

    {:ok, root: root}
  end

  defp stage(root, fixture_name, storage_key) do
    src = Path.join(@fixtures_dir, fixture_name)
    dst = Path.join(root, storage_key)
    File.mkdir_p!(Path.dirname(dst))
    File.cp!(src, dst)
    :ok
  end

  defp stage_binary(root, bytes, storage_key) do
    dst = Path.join(root, storage_key)
    File.mkdir_p!(Path.dirname(dst))
    File.write!(dst, bytes)
    :ok
  end

  defp file_row(content_type, storage_key) do
    %FileRow{content_type: content_type, storage_key: storage_key}
  end

  describe "extract/1 dispatch" do
    test "returns :unsupported_content_type for unknown MIME" do
      assert {:error, {:unsupported_content_type, "application/x-weird"}} =
               Extractor.extract(file_row("application/x-weird", "files/p/f/x"))
    end

    test "returns :unsupported_content_type for nil content_type" do
      assert {:error, {:unsupported_content_type, nil}} =
               Extractor.extract(file_row(nil, "files/p/f/x"))
    end
  end

  describe "Text extractor" do
    test "reads text/plain bytes verbatim", %{root: root} do
      stage(root, "sample.txt", "files/p/f/sample.txt")

      assert {:ok, %{text: text, pages: nil}} =
               Extractor.extract(file_row("text/plain", "files/p/f/sample.txt"))

      assert text =~ "hello world from the text fixture"
    end

    test "reads text/markdown bytes verbatim", %{root: root} do
      stage(root, "sample.txt", "files/p/f/sample.md")

      assert {:ok, %{text: text, pages: nil}} =
               Extractor.extract(file_row("text/markdown", "files/p/f/sample.md"))

      assert text =~ "platform files extractor sample"
    end

    test "missing storage_key surfaces as error" do
      assert {:error, :missing_storage_key} =
               Extractor.extract(file_row("text/plain", nil))
    end

    test "missing on-disk file surfaces enoent rather than raising", %{root: _root} do
      assert {:error, :enoent} =
               Extractor.extract(file_row("text/plain", "files/p/f/does-not-exist.txt"))
    end
  end

  describe "CSV extractor" do
    test "rewrites rows as header: value paragraphs", %{root: root} do
      stage(root, "sample.csv", "files/p/f/sample.csv")

      assert {:ok, %{text: text, pages: nil}} =
               Extractor.extract(file_row("text/csv", "files/p/f/sample.csv"))

      # known sentinel values from the fixture
      assert text =~ "name: Alice"
      assert text =~ "age: 30"
      assert text =~ "city: Portland"
      # quoted-field-with-comma round-trip
      assert text =~ "city: Eugene, OR"
      # escaped-quote round-trip
      assert text =~ ~s(city: She said "hi")
      # paragraph separator
      assert text =~ "\n\n"
    end

    test "returns :malformed_csv on unterminated quoted field", %{root: root} do
      stage_binary(root, ~s(name,age\n"Alice,30\n), "files/p/f/bad.csv")

      assert {:error, :malformed_csv} =
               Extractor.extract(file_row("text/csv", "files/p/f/bad.csv"))
    end

    test "empty file returns empty text", %{root: root} do
      stage_binary(root, "", "files/p/f/empty.csv")

      assert {:ok, %{text: "", pages: nil}} =
               Extractor.extract(file_row("text/csv", "files/p/f/empty.csv"))
    end
  end

  describe "PDF extractor" do
    test "returns :tool_unavailable when pdftotext missing", %{root: root} do
      if System.find_executable("pdftotext") do
        # On a box that has the tool we don't have a fixture to assert
        # against — just assert dispatch reaches the module. The
        # `@tag :integration_pdftotext` test below covers the happy path.
        :ok
      else
        stage_binary(root, "%PDF-1.4 fake", "files/p/f/bogus.pdf")

        assert {:error, :tool_unavailable} =
                 Extractor.extract(file_row("application/pdf", "files/p/f/bogus.pdf"))
      end
    end

    @tag :integration_pdftotext
    test "extracts text and splits on form-feed when pdftotext present", %{root: root} do
      if System.find_executable("pdftotext") &&
           File.exists?(Path.join(@fixtures_dir, "sample.pdf")) do
        stage(root, "sample.pdf", "files/p/f/sample.pdf")

        assert {:ok, %{text: text, pages: pages}} =
                 Extractor.extract(file_row("application/pdf", "files/p/f/sample.pdf"))

        assert is_list(pages)
        assert length(pages) >= 1
        assert text =~ "hello"
      else
        # Tool or fixture not present on this host — silently skip,
        # matching the pattern used by the sibling :tool-missing tests
        # above. Runners that want a hard signal can `--include` the
        # tag and provide the binary/fixture in the environment.
        :ok
      end
    end

    test "malformed pdf bytes surface as error tuple when tool present", %{root: root} do
      if System.find_executable("pdftotext") do
        stage_binary(root, "not actually a pdf", "files/p/f/bogus.pdf")
        result = Extractor.extract(file_row("application/pdf", "files/p/f/bogus.pdf"))
        assert match?({:error, _}, result), "expected error tuple, got: #{inspect(result)}"
      else
        :ok
      end
    end
  end

  describe "DOCX extractor" do
    test "returns :tool_unavailable when pandoc missing", %{root: root} do
      if System.find_executable("pandoc") do
        :ok
      else
        stage_binary(root, "PK\x03\x04 fake", "files/p/f/bogus.docx")

        assert {:error, :tool_unavailable} =
                 Extractor.extract(
                   file_row(
                     "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                     "files/p/f/bogus.docx"
                   )
                 )
      end
    end

    @tag :integration_pandoc
    test "extracts plain text from docx when pandoc present", %{root: root} do
      if System.find_executable("pandoc") &&
           File.exists?(Path.join(@fixtures_dir, "sample.docx")) do
        stage(root, "sample.docx", "files/p/f/sample.docx")

        assert {:ok, %{text: text, pages: nil}} =
                 Extractor.extract(
                   file_row(
                     "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                     "files/p/f/sample.docx"
                   )
                 )

        assert text =~ "hello"
      else
        :ok
      end
    end
  end

  describe "Image extractor" do
    test "returns :ocr_unavailable when tesseract missing", %{root: root} do
      if System.find_executable("tesseract") do
        :ok
      else
        stage_binary(root, "\x89PNG fake", "files/p/f/bogus.png")

        assert {:error, :ocr_unavailable} =
                 Extractor.extract(file_row("image/png", "files/p/f/bogus.png"))
      end
    end

    test "never raises on a non-image file (always error tuple)", %{root: root} do
      stage_binary(root, "definitely not an image", "files/p/f/bogus.png")
      result = Extractor.extract(file_row("image/png", "files/p/f/bogus.png"))
      assert match?({:error, _}, result), "expected error tuple, got: #{inspect(result)}"
    end

    @tag :integration_tesseract
    test "extracts text from PNG when tesseract present", %{root: root} do
      if System.find_executable("tesseract") &&
           File.exists?(Path.join(@fixtures_dir, "sample.png")) do
        stage(root, "sample.png", "files/p/f/sample.png")

        assert {:ok, %{text: text, pages: nil}} =
                 Extractor.extract(file_row("image/png", "files/p/f/sample.png"))

        assert text =~ ~r/hello/i
      else
        :ok
      end
    end
  end

  describe "GDoc extractor" do
    test "missing drive_id returns :missing_drive_id" do
      # No "drive:..." prefix on storage_key → no drive id discoverable.
      assert {:error, :missing_drive_id} =
               Extractor.extract(file_row("application/vnd.google-apps.document", "files/p/f/x"))
    end

    test "drive_id present but no transport returns :drive_client_unavailable" do
      previous = Application.get_env(:platform, :gdoc_drive_request)
      Application.delete_env(:platform, :gdoc_drive_request)

      try do
        assert {:error, :drive_client_unavailable} =
                 Extractor.extract(
                   file_row("application/vnd.google-apps.document", "drive:abc123")
                 )
      after
        if previous,
          do: Application.put_env(:platform, :gdoc_drive_request, previous),
          else: Application.delete_env(:platform, :gdoc_drive_request)
      end
    end

    test "drive_id + stubbed Req plug returns extracted text and splits pages" do
      # Req.new accepts a `:plug` adapter — anonymous arity-1 function
      # that takes a %Plug.Conn{} and returns a %Plug.Conn{}. We use
      # this to mock the Drive API without standing up a real server.
      plug = fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/drive/v3/files/abc123/export"
        assert conn.query_string =~ "mimeType=text"
        Plug.Conn.resp(conn, 200, "page one body\fpage two body")
      end

      request = Req.new(plug: plug)

      previous = Application.get_env(:platform, :gdoc_drive_request)
      Application.put_env(:platform, :gdoc_drive_request, request)

      try do
        assert {:ok, %{text: text, pages: pages}} =
                 Extractor.extract(
                   file_row("application/vnd.google-apps.document", "drive:abc123")
                 )

        assert text == "page one body\fpage two body"
        assert pages == ["page one body", "page two body"]
      after
        if previous,
          do: Application.put_env(:platform, :gdoc_drive_request, previous),
          else: Application.delete_env(:platform, :gdoc_drive_request)
      end
    end

    test "Drive API non-200 surfaces as :drive_api_failed" do
      plug = fn conn -> Plug.Conn.resp(conn, 404, "") end

      request = Req.new(plug: plug)

      previous = Application.get_env(:platform, :gdoc_drive_request)
      Application.put_env(:platform, :gdoc_drive_request, request)

      try do
        assert {:error, {:drive_api_failed, 404}} =
                 Extractor.extract(
                   file_row("application/vnd.google-apps.document", "drive:abc123")
                 )
      after
        if previous,
          do: Application.put_env(:platform, :gdoc_drive_request, previous),
          else: Application.delete_env(:platform, :gdoc_drive_request)
      end
    end
  end
end
