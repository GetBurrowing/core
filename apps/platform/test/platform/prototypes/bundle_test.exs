defmodule Platform.Prototypes.BundleTest do
  use ExUnit.Case, async: true

  import Platform.PrototypeFixtures, only: [zip: 1]

  alias Platform.Prototypes.Bundle

  @limits %{max_files: 10, max_bytes: 10_000}

  describe "validate_path/1" do
    test "accepts ordinary relative paths" do
      for p <- ["index.html", "assets/app.js", "a b.html", "deep/er/x.png"],
          do: assert(Bundle.validate_path(p) == :ok, p)
    end

    test "refuses traversal, absolute, backslash, NUL, scheme-like and empty segments" do
      for p <-
            [
              "../x",
              "a/../x",
              "/etc/x",
              "a\\b",
              "a\0b",
              "c:x",
              "a//b",
              "./a",
              "a/.",
              "",
              "a?b",
              "a#b"
            ] do
        assert {:error, {:invalid_path, _}} = Bundle.validate_path(p), inspect(p)
      end
    end
  end

  describe "from_files/2" do
    test "decodes content and content_base64" do
      assert {:ok, files} =
               Bundle.from_files(
                 %{
                   "index.html" => %{"content" => "<p>hi</p>"},
                   "img.png" => %{"content_base64" => Base.encode64(<<1, 2, 3>>)}
                 },
                 @limits
               )

      assert Enum.sort_by(files, & &1.path) == [
               %{path: "img.png", bytes: <<1, 2, 3>>},
               %{path: "index.html", bytes: "<p>hi</p>"}
             ]
    end

    test "refuses too many files, oversize totals, bad base64 and a file/dir clash" do
      many = Map.new(1..11, &{"f#{&1}.txt", %{"content" => "x"}})
      assert {:error, {:too_many_files, _}} = Bundle.from_files(many, @limits)

      big = %{"index.html" => %{"content" => String.duplicate("x", 10_001)}}
      assert {:error, {:bundle_too_large, _}} = Bundle.from_files(big, @limits)

      assert {:error, {:invalid_file_content, _}} =
               Bundle.from_files(%{"a" => %{"content_base64" => "!!"}}, @limits)

      clash = %{"a" => %{"content" => "1"}, "a/b" => %{"content" => "2"}}
      assert {:error, {:path_conflict, _}} = Bundle.from_files(clash, @limits)

      assert {:error, {:invalid_path, _}} =
               Bundle.from_files(%{"../x" => %{"content" => "1"}}, @limits)
    end
  end

  describe "from_zip/2" do
    test "reads an archive written by :zip.create/3 (stored and deflated)" do
      {:ok, {_, bin}} =
        :zip.create(~c"b.zip", [{~c"index.html", "<p>hi</p>"}, {~c"js/app.js", "1+1"}], [
          :memory
        ])

      assert {:ok, files} = Bundle.from_zip(bin, @limits)

      assert Enum.sort_by(files, & &1.path) == [
               %{path: "index.html", bytes: "<p>hi</p>"},
               %{path: "js/app.js", bytes: "1+1"}
             ]
    end

    test "reads the hand-built fixture and skips directory entries" do
      bin =
        zip([
          %{name: "assets/", data: "", method: 0},
          %{name: "assets/a.css", data: "body{}"},
          %{name: "index.html", data: "<p>x</p>", method: 0}
        ])

      assert {:ok, files} = Bundle.from_zip(bin, @limits)
      assert Enum.map(files, & &1.path) == ["assets/a.css", "index.html"]
    end

    test "refuses traversal and absolute entry names" do
      for name <- ["../x", "/etc/x", "a/../../x", "a\\..\\x"] do
        bin = zip([%{name: "index.html", data: "ok"}, %{name: name, data: "evil"}])
        assert {:error, {:invalid_path, _}} = Bundle.from_zip(bin, @limits), name
      end
    end

    test "refuses a symlink entry (S_IFLNK in the Unix mode)" do
      bin = zip([%{name: "link", data: "/etc/passwd", mode: 0o120777}])
      assert {:error, {:symlink_entry, _}} = Bundle.from_zip(bin, @limits)

      # Positive control: the same entry as a regular file passes.
      bin = zip([%{name: "link", data: "/etc/passwd", mode: 0o100644}])
      assert {:ok, [%{path: "link"}]} = Bundle.from_zip(bin, @limits)
    end

    test "refuses a declared total over the cap before inflating anything" do
      bin = zip([%{name: "index.html", data: "x", declared: 10_001}])
      assert {:error, {:bundle_too_large, msg}} = Bundle.from_zip(bin, @limits)
      assert msg =~ "10001 bytes uncompressed"
    end

    test "ZIP BOMB: a small declared size that inflates far past it is refused" do
      real = :binary.copy(<<0>>, 5_000_000)
      bin = zip([%{name: "index.html", data: real, declared: 100}])
      # The archive is tiny; only real inflation could find the lie.
      assert byte_size(bin) < 10_000
      assert {:error, {:bundle_too_large, msg}} = Bundle.from_zip(bin, @limits)
      assert msg =~ "more than its declared 100 bytes"
    end

    test "refuses more entries than max_files" do
      entries = for n <- 1..11, do: %{name: "f#{n}.txt", data: "x"}
      assert {:error, {:too_many_files, _}} = Bundle.from_zip(zip(entries), @limits)
    end

    test "refuses a CRC mismatch, a non-zip and duplicate names" do
      assert {:error, {:invalid_zip, _}} =
               Bundle.from_zip(zip([%{name: "a", data: "abc", crc: 1}]), @limits)

      assert {:error, {:invalid_zip, _}} = Bundle.from_zip("not a zip", @limits)

      dup = zip([%{name: "a", data: "1"}, %{name: "a", data: "2"}])
      assert {:error, {:duplicate_path, _}} = Bundle.from_zip(dup, @limits)
    end
  end
end
