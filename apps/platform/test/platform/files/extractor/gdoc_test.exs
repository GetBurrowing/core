defmodule Platform.Files.Extractor.GDocTest do
  use ExUnit.Case, async: true

  alias Platform.Files.Extractor.GDoc
  alias Platform.Files.File, as: FileRow

  test "extract/1 with FileRow returns :handled_externally" do
    assert {:error, :handled_externally} =
             GDoc.extract(%FileRow{
               content_type: "application/vnd.google-apps.document",
               storage_key: "drive:abc123"
             })
  end

  test "extract/1 with bytes returns :handled_externally" do
    assert {:error, :handled_externally} = GDoc.extract("any bytes")
  end
end
