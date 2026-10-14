defmodule Platform.Prototypes.Bundle do
  @moduledoc """
  Turns publish input into a checked list of `%{path, bytes}` files, or
  refuses it. Nothing here writes a byte anywhere: every refusal happens
  before `Platform.Prototypes` touches storage.

  Two inputs:

    * a file map, `%{path => %{"content" => text} | %{"content_base64" => b64}}`;
    * a zip archive, as a binary.

  ## What is refused

    * Paths that are absolute, contain a `..`, `.` or empty segment, a
      backslash, NUL or any control character, or a `:`, `?` or `#` (a
      relative link to `a:b.js` parses as a URL scheme, and `?`/`#` cannot be
      addressed by a URL path at all). Duplicate paths.
    * More than `max_files` files.
    * A declared uncompressed total over `max_bytes`, checked from the
      central directory before anything is inflated.
    * A zip whose REAL inflated size differs from what it declared. Inflation
      is incremental (`:zlib.safeInflate/2`) and stops the moment a file's
      output passes its declared size, so a zip bomb that declares 1 KB and
      inflates to 1 GB is refused after roughly one chunk past 1 KB, never
      materialised. A CRC mismatch is refused too.
    * Symlink entries (a Unix `S_IFLNK` mode in the external attributes),
      encrypted entries, ZIP64, and any compression method other than
      stored (0) or deflate (8).

  ## Why not `:zip`

  `:zip.list_dir/1` masks the external mode to its permission bits
  (`band 8#777` in OTP 27's `zip.erl`, `cd_file_header_to_file_info/3`), so
  it cannot tell a symlink entry from a file, and `:zip.unzip/2` inflates
  each file whole before its size can be counted. This module therefore
  reads the central directory and inflates the entries itself; the format
  subset it accepts is the one every common zip tool writes by default.
  """

  import Bitwise

  @type limits :: %{max_files: pos_integer(), max_bytes: pos_integer()}
  @type file :: %{path: String.t(), bytes: binary()}
  @type error :: {:error, {atom(), String.t()}}

  @eocd_sig <<0x50, 0x4B, 0x05, 0x06>>
  @max_path_bytes 1024
  # A zip comment is at most 65_535 bytes, plus the 22-byte EOCD record.
  @eocd_search_window 65_557

  # ── Paths ──────────────────────────────────────────────────────────────

  @doc """
  `:ok` when `path` is a safe bundle-relative file path, else a coded error.
  """
  @spec validate_path(term()) :: :ok | error()
  def validate_path(path) when is_binary(path) do
    cond do
      path == "" ->
        bad_path(path, "is empty")

      byte_size(path) > @max_path_bytes ->
        bad_path(path, "is longer than #{@max_path_bytes} bytes")

      not String.valid?(path) ->
        bad_path(path, "is not valid UTF-8")

      String.starts_with?(path, "/") ->
        bad_path(path, "is absolute")

      String.match?(path, ~r/[\x00-\x1f\x7f\\:?#]/) ->
        bad_path(path, "contains a backslash, NUL, control character, ':', '?' or '#'")

      Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".."])) ->
        bad_path(path, "has an empty, '.' or '..' segment")

      true ->
        :ok
    end
  end

  def validate_path(path), do: bad_path(inspect(path), "is not a string")

  defp bad_path(path, why),
    do: {:error, {:invalid_path, "path #{inspect(path)} #{why}"}}

  # ── File map ───────────────────────────────────────────────────────────

  @doc "Checks and decodes a file map. See the moduledoc."
  @spec from_files(term(), limits()) :: {:ok, [file()]} | error()
  def from_files(files, %{max_files: max_files} = limits) when is_map(files) do
    cond do
      map_size(files) == 0 ->
        {:error, {:empty_bundle, "the bundle has no files"}}

      map_size(files) > max_files ->
        too_many(map_size(files), max_files)

      true ->
        files
        |> Enum.sort_by(fn {path, _} -> to_string(path) end)
        |> Enum.reduce_while({:ok, [], 0}, fn {path, spec}, {:ok, acc, total} ->
          with :ok <- validate_path(path),
               {:ok, bytes} <- decode_content(path, spec),
               total = total + byte_size(bytes),
               :ok <- check_total(total, limits) do
            {:cont, {:ok, [%{path: path, bytes: bytes} | acc], total}}
          else
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, acc, _total} -> check_tree(Enum.reverse(acc))
          {:error, _} = err -> err
        end
    end
  end

  def from_files(_files, _limits),
    do: {:error, {:invalid_files, "`files` must be an object mapping path => file"}}

  defp decode_content(_path, %{"content" => content}) when is_binary(content), do: {:ok, content}

  defp decode_content(path, %{"content_base64" => b64}) when is_binary(b64) do
    case Base.decode64(b64, ignore: :whitespace) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:invalid_file_content, "#{path}: content_base64 is not valid base64"}}
    end
  end

  defp decode_content(path, _spec),
    do:
      {:error,
       {:invalid_file_content, "#{path}: pass {content: text} or {content_base64: base64}"}}

  # ── Zip ────────────────────────────────────────────────────────────────

  @doc "Checks and extracts a zip archive in memory. See the moduledoc."
  @spec from_zip(binary(), limits()) :: {:ok, [file()]} | error()
  def from_zip(zip, limits) when is_binary(zip) do
    with {:ok, cd_offset, cd_size, count} <- read_eocd(zip),
         {:ok, entries} <- read_central_directory(zip, cd_offset, cd_size, count, limits),
         :ok <- check_declared(entries, limits),
         {:ok, files} <- extract(zip, entries) do
      if files == [],
        do: {:error, {:empty_bundle, "the zip has no files"}},
        else: check_tree(files)
    end
  end

  def from_zip(_zip, _limits), do: invalid_zip("not a binary")

  defp read_eocd(zip) do
    size = byte_size(zip)
    window_start = max(size - @eocd_search_window, 0)
    window = binary_part(zip, window_start, size - window_start)

    case :binary.matches(window, @eocd_sig) |> List.last() do
      nil ->
        invalid_zip("no end-of-central-directory record")

      {pos, _} ->
        case binary_part(window, pos, byte_size(window) - pos) do
          <<_sig::binary-4, _disk::little-16, _cd_disk::little-16, _here::little-16,
            count::little-16, cd_size::little-32, cd_offset::little-32, _rest::binary>> ->
            cond do
              count == 0xFFFF or cd_size == 0xFFFFFFFF or cd_offset == 0xFFFFFFFF ->
                unsupported_zip("ZIP64 archives are not supported")

              cd_offset + cd_size > size ->
                invalid_zip("central directory runs past the end of the file")

              true ->
                {:ok, cd_offset, cd_size, count}
            end

          _ ->
            invalid_zip("truncated end-of-central-directory record")
        end
    end
  end

  defp read_central_directory(zip, cd_offset, cd_size, count, limits) do
    read_cd_entries(binary_part(zip, cd_offset, cd_size), count, limits, [], 0)
  end

  defp read_cd_entries(_cd, 0, _limits, acc, _files), do: {:ok, Enum.reverse(acc)}

  defp read_cd_entries(
         <<0x50, 0x4B, 0x01, 0x02, made_by::little-16, _need::little-16, flags::little-16,
           method::little-16, _time::little-16, _date::little-16, crc::little-32,
           comp_size::little-32, uncomp_size::little-32, name_len::little-16,
           extra_len::little-16, comment_len::little-16, _disk::little-16, _int::little-16,
           ext_attr::little-32, local_offset::little-32, rest::binary>>,
         remaining,
         limits,
         acc,
         files
       )
       when byte_size(rest) >= name_len + extra_len + comment_len do
    <<name::binary-size(^name_len), _extra::binary-size(^extra_len),
      _comment::binary-size(^comment_len), next::binary>> = rest

    entry = %{
      name: name,
      method: method,
      crc: crc,
      comp_size: comp_size,
      uncomp_size: uncomp_size,
      local_offset: local_offset
    }

    cond do
      symlink?(made_by, ext_attr) ->
        {:error, {:symlink_entry, "zip entry #{inspect(name)} is a symlink"}}

      (flags &&& 0x1) == 0x1 ->
        unsupported_zip("zip entry #{inspect(name)} is encrypted")

      comp_size == 0xFFFFFFFF or uncomp_size == 0xFFFFFFFF or local_offset == 0xFFFFFFFF ->
        unsupported_zip("ZIP64 archives are not supported")

      String.ends_with?(name, "/") ->
        # A directory entry: no bytes, but its name must still be safe.
        with :ok <- validate_path(String.trim_trailing(name, "/")) do
          read_cd_entries(next, remaining - 1, limits, acc, files)
        end

      files + 1 > limits.max_files ->
        too_many(files + 1, limits.max_files)

      method not in [0, 8] ->
        unsupported_zip("zip entry #{inspect(name)} uses compression method #{method}")

      true ->
        with :ok <- validate_path(name) do
          read_cd_entries(next, remaining - 1, limits, [entry | acc], files + 1)
        end
    end
  end

  defp read_cd_entries(_cd, _remaining, _limits, _acc, _files),
    do: invalid_zip("malformed central directory entry")

  # Version-made-by high byte 3 = UNIX; then the high 16 bits of the
  # external attributes are st_mode, and S_IFLNK is 0o120000.
  defp symlink?(made_by, ext_attr),
    do: made_by >>> 8 == 3 and (ext_attr >>> 16 &&& 0o170000) == 0o120000

  defp check_declared(entries, limits) do
    declared = Enum.reduce(entries, 0, &(&1.uncomp_size + &2))

    with :ok <- check_total(declared, limits) do
      case entries |> Enum.map(& &1.name) |> duplicates() do
        [] -> :ok
        [dup | _] -> {:error, {:duplicate_path, "path #{inspect(dup)} appears twice"}}
      end
    end
  end

  defp duplicates(names) do
    names |> Enum.frequencies() |> Enum.filter(fn {_, n} -> n > 1 end) |> Enum.map(&elem(&1, 0))
  end

  defp extract(zip, entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case extract_entry(zip, entry) do
        {:ok, bytes} -> {:cont, {:ok, [%{path: entry.name, bytes: bytes} | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp extract_entry(zip, entry) do
    with {:ok, data} <- entry_data(zip, entry),
         {:ok, bytes} <- decompress(entry, data) do
      cond do
        byte_size(bytes) != entry.uncomp_size ->
          invalid_zip(
            "zip entry #{inspect(entry.name)} declared #{entry.uncomp_size} bytes " <>
              "and inflated to #{byte_size(bytes)}"
          )

        :erlang.crc32(bytes) != entry.crc ->
          {:error, {:invalid_zip, "zip entry #{inspect(entry.name)} fails its CRC check"}}

        true ->
          {:ok, bytes}
      end
    end
  end

  defp entry_data(zip, %{local_offset: offset, comp_size: comp_size} = entry) do
    case zip do
      <<_::binary-size(^offset), 0x50, 0x4B, 0x03, 0x04, _::binary-22, name_len::little-16,
        extra_len::little-16, _::binary>> ->
        start = offset + 30 + name_len + extra_len

        if start + comp_size <= byte_size(zip),
          do: {:ok, binary_part(zip, start, comp_size)},
          else: invalid_zip("zip entry #{inspect(entry.name)} runs past the end of the file")

      _ ->
        invalid_zip("zip entry #{inspect(entry.name)} has no local header")
    end
  end

  defp decompress(%{method: 0}, data), do: {:ok, data}

  defp decompress(%{method: 8} = entry, data) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      inflate_bounded(z, :zlib.safeInflate(z, data), entry, [], 0)
    rescue
      ErlangError -> invalid_zip("zip entry #{inspect(entry.name)} is not valid deflate data")
    after
      :zlib.close(z)
    end
  end

  # Stops as soon as the real output passes the declared size: that is the
  # zip-bomb refusal, and it happens one inflate chunk past the declaration.
  defp inflate_bounded(z, {status, out}, entry, acc, size)
       when status in [:continue, :finished] do
    size = size + IO.iodata_length(out)
    acc = [acc | out]

    cond do
      size > entry.uncomp_size -> size_mismatch(entry)
      status == :finished -> {:ok, IO.iodata_to_binary(acc)}
      true -> inflate_bounded(z, :zlib.safeInflate(z, []), entry, acc, size)
    end
  end

  defp inflate_bounded(_z, _other, entry, _acc, _size),
    do: invalid_zip("zip entry #{inspect(entry.name)} needs a preset dictionary")

  defp size_mismatch(entry),
    do:
      {:error,
       {:bundle_too_large,
        "zip entry #{inspect(entry.name)} inflates to more than its declared " <>
          "#{entry.uncomp_size} bytes; refused"}}

  # ── Shared ─────────────────────────────────────────────────────────────

  # A file whose path is also a directory of another file ("a" and "a/b")
  # cannot exist in any filesystem-shaped store, and a URL for "a/" would be
  # ambiguous, so it is refused rather than left to fail mid-write.
  defp check_tree(files) do
    paths = MapSet.new(files, & &1.path)

    conflict =
      Enum.find_value(files, fn %{path: path} ->
        path
        |> String.split("/")
        |> Enum.drop(-1)
        |> Enum.scan(&(&2 <> "/" <> &1))
        |> Enum.find(&MapSet.member?(paths, &1))
      end)

    case conflict do
      nil -> {:ok, files}
      dir -> {:error, {:path_conflict, "#{inspect(dir)} is both a file and a directory"}}
    end
  end

  defp check_total(total, %{max_bytes: max}) when total > max,
    do: {:error, {:bundle_too_large, "bundle is #{total} bytes uncompressed; the cap is #{max}"}}

  defp check_total(_total, _limits), do: :ok

  defp too_many(n, max),
    do: {:error, {:too_many_files, "bundle has #{n} or more files; the cap is #{max}"}}

  defp invalid_zip(why), do: {:error, {:invalid_zip, why}}
  defp unsupported_zip(why), do: {:error, {:unsupported_zip, why}}
end
