defmodule Platform.Branding.IconStorageTest do
  @moduledoc """
  Task 01a0879a stage 2 — blob storage for the uploaded branding source and
  the seven derived variants.

  What these tests are for:

    1. THE KEY IS THE CONTENT-TYPE RECORD. No column stores a blob's type, so
       the extension `put_source/3` chooses is what `content_type_for_key/1`
       later hands the serving controller. A key whose extension came from the
       client filename would let an upload pick its own `Content-Type`.
    2. THE ALLOWLIST IS ENFORCED AT CONSUME TIME. Not by the browser's
       `accept` attribute, which is a picker hint. SVG in particular is
       refused because it can embed `<script>`, and it is precisely the file
       an admin would be talked into uploading as "the logo".
    3. VERSIONS DO NOT SHARE KEYS. New bytes land on a new prefix so the old
       blob is deleted explicitly rather than overwritten under a URL that did
       not change.
    4. A SEGMENT CANNOT ESCAPE THE NAMESPACE.
  """
  use ExUnit.Case, async: true

  alias Platform.Branding.IconStorage

  defp read!(key) do
    assert {:ok, stream} = IconStorage.get(key)
    Enum.join(stream)
  end

  defp version, do: "v#{System.unique_integer([:positive])}"

  # ── Keys carry the content type ────────────────────────────────────────

  describe "put_source/3" do
    test "writes under install-branding/<version>/source.<ext> and reads back byte for byte" do
      v = version()

      assert {:ok, result} =
               IconStorage.put_source(v, {:binary, "PNGBYTES"}, content_type: "image/png")

      assert result.storage_key == "install-branding/#{v}/source.png"
      assert result.content_type == "image/png"
      assert result.byte_size == byte_size("PNGBYTES")
      assert result.content_hash == Base.encode16(:crypto.hash(:sha256, "PNGBYTES"), case: :lower)
      assert read!(result.storage_key) == "PNGBYTES"

      on_exit(fn -> IconStorage.delete(result.storage_key) end)
    end

    test "the extension follows the RESOLVED type, not the client filename" do
      v = version()

      assert {:ok, %{storage_key: key}} =
               IconStorage.put_source(v, {:binary, "x"},
                 content_type: "image/png",
                 filename: "logo.jpeg.exe"
               )

      assert key == "install-branding/#{v}/source.png"
      assert IconStorage.content_type_for_key(key) == "image/png"
      on_exit(fn -> IconStorage.delete(key) end)
    end

    test "a generic reported type falls back to the filename, as iOS Safari requires" do
      v = version()

      assert {:ok, %{content_type: "image/webp", storage_key: key}} =
               IconStorage.put_source(v, {:binary, "x"},
                 content_type: "application/octet-stream",
                 filename: "IMG_0042.webp"
               )

      on_exit(fn -> IconStorage.delete(key) end)
    end

    test "EVERY allowed type round-trips: stored under a key that reads back as itself" do
      # The key IS the content-type record, so an allowed type whose
      # extension the MIME table does not know would be stored under an
      # extensionless key and served as application/octet-stream. That is a
      # silent downgrade for exactly the format it was allowed for.
      for type <- IconStorage.allowed_content_types() do
        v = version()

        assert {:ok, %{storage_key: key}} =
                 IconStorage.put_source(v, {:binary, "x"}, content_type: type)

        assert IconStorage.content_type_for_key(key) == type,
               "#{type} was stored as #{key}, which reads back as " <>
                 "#{IconStorage.content_type_for_key(key)}"

        on_exit(fn -> IconStorage.delete(key) end)
      end
    end

    test "a parameterised type is normalised rather than refused" do
      v = version()

      assert {:ok, %{content_type: "image/png", storage_key: key}} =
               IconStorage.put_source(v, {:binary, "x"},
                 content_type: "image/png; charset=binary"
               )

      on_exit(fn -> IconStorage.delete(key) end)
    end

    test "accepts a {:path, _} source as well as bytes" do
      v = version()

      path =
        Path.join(System.tmp_dir!(), "icon_storage_test_#{System.unique_integer([:positive])}")

      File.write!(path, "FROMPATH")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{storage_key: key, byte_size: 8}} =
               IconStorage.put_source(v, {:path, path}, content_type: "image/png")

      assert read!(key) == "FROMPATH"
      on_exit(fn -> IconStorage.delete(key) end)
    end
  end

  describe "the content-type allowlist" do
    test "SVG is refused — it can carry <script>, and it is the obvious 'logo' upload" do
      assert {:error, {:unsupported_content_type, "image/svg+xml"}} =
               IconStorage.put_source(version(), {:binary, "<svg/>"},
                 content_type: "image/svg+xml"
               )

      refute "image/svg+xml" in IconStorage.allowed_content_types()
    end

    test "text/html is refused, by type and by filename" do
      assert {:error, {:unsupported_content_type, "text/html"}} =
               IconStorage.put_source(version(), {:binary, "<h1>hi"}, content_type: "text/html")

      assert {:error, {:unsupported_content_type, "application/octet-stream"}} =
               IconStorage.put_source(version(), {:binary, "<h1>hi"},
                 content_type: "application/octet-stream",
                 filename: "logo.html"
               )
    end

    test "an unlabelled upload with no usable filename is refused, not stored blind" do
      assert {:error, {:unsupported_content_type, nil}} =
               IconStorage.put_source(version(), {:binary, "x"}, [])
    end

    test "no text/* type is on the list, and every entry is an image/*" do
      assert Enum.all?(IconStorage.allowed_content_types(), &String.starts_with?(&1, "image/"))
      refute Enum.any?(IconStorage.allowed_content_types(), &String.starts_with?(&1, "text/"))
    end

    test "ICO is allowed OUT but never IN — nobody uploads an ICO as a source" do
      assert IconStorage.content_type_for_key("install-branding/v/favicon_ico.ico") ==
               "image/x-icon"

      assert {:error, {:unsupported_content_type, "image/x-icon"}} =
               IconStorage.put_source(version(), {:binary, "x"}, content_type: "image/x-icon")
    end
  end

  # ── Derived variants ───────────────────────────────────────────────────

  describe "put_derived/3" do
    test "six variants are .png and favicon_ico is .ico" do
      v = version()

      for variant <- [
            :icon_192,
            :icon_512,
            :icon_512_maskable,
            :apple_touch,
            :favicon_32,
            :favicon_16
          ] do
        assert {:ok, key} = IconStorage.put_derived(v, variant, "bytes-#{variant}")
        assert key == "install-branding/#{v}/#{variant}.png"
        assert IconStorage.content_type_for_key(key) == "image/png"
        assert read!(key) == "bytes-#{variant}"
        on_exit(fn -> IconStorage.delete(key) end)
      end

      assert {:ok, ico_key} = IconStorage.put_derived(v, :favicon_ico, "ico-bytes")
      assert ico_key == "install-branding/#{v}/favicon_ico.ico"
      assert IconStorage.content_type_for_key(ico_key) == "image/x-icon"
      on_exit(fn -> IconStorage.delete(ico_key) end)
    end

    test "two versions of the same variant occupy different keys" do
      a = version()
      b = version()

      assert {:ok, key_a} = IconStorage.put_derived(a, :icon_512, "old")
      assert {:ok, key_b} = IconStorage.put_derived(b, :icon_512, "new")

      refute key_a == key_b
      assert read!(key_a) == "old"
      assert read!(key_b) == "new"

      on_exit(fn ->
        IconStorage.delete(key_a)
        IconStorage.delete(key_b)
      end)
    end
  end

  # ── Reading types back out ─────────────────────────────────────────────

  describe "content_type_for_key/1" do
    test "an unrecognised or dangerous extension degrades to octet-stream" do
      for key <- [
            "install-branding/v/thing.svg",
            "install-branding/v/thing.html",
            "install-branding/v/thing.txt",
            "install-branding/v/thing.wat",
            "install-branding/v/thing"
          ] do
        assert IconStorage.content_type_for_key(key) == "application/octet-stream",
               "#{key} talked the serving controller into a non-default Content-Type"
      end
    end
  end

  # ── Deletion and key shape ─────────────────────────────────────────────

  describe "delete/1" do
    test "removes the blob and is idempotent on an already-missing key" do
      v = version()
      assert {:ok, key} = IconStorage.put_derived(v, :icon_192, "bytes")
      assert read!(key) == "bytes"

      assert :ok = IconStorage.delete(key)
      assert {:error, :enoent} = IconStorage.get(key)
      assert :ok = IconStorage.delete(key)
    end
  end

  describe "build_key/2" do
    test "every key sits under the namespace" do
      assert String.starts_with?(
               IconStorage.build_key("abc", "icon_512.png"),
               "install-branding/"
             )

      assert IconStorage.namespace() == "install-branding"
    end

    test "a traversal segment cannot escape the namespace" do
      for segment <- ["..", ".", "../..", "../../etc", "/etc/passwd", ""] do
        key = IconStorage.build_key(segment, "source.png")

        assert String.starts_with?(key, "install-branding/")

        # String-prefix alone is satisfied by "install-branding/../source.png".
        # Resolve the path and check the RESULT is still inside.
        assert key |> Path.expand("/") |> String.starts_with?("/install-branding/"),
               "#{inspect(segment)} produced #{key}, which resolves to " <>
                 "#{Path.expand(key, "/")} — outside the namespace"
      end
    end
  end
end
