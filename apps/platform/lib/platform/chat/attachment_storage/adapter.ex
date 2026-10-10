defmodule Platform.Chat.AttachmentStorage.Adapter do
  @moduledoc "Behaviour implemented by attachment storage backends (ADR 0039)."

  @type key :: String.t()
  @type source :: {:path, Path.t()} | {:binary, binary()}
  @type persist_ok :: %{byte_size: non_neg_integer(), content_hash: String.t()}
  @type presign_ok :: %{url: String.t(), expires_at: DateTime.t()}

  @callback persist(key, source) :: {:ok, persist_ok} | {:error, term()}
  @callback read_stream(key) :: {:ok, Enumerable.t()} | {:error, term()}
  @callback delete(key) :: :ok
  @callback presign_upload(key, pos_integer(), pos_integer()) ::
              {:ok, presign_ok} | {:error, term()}

  # Resumable chunked uploads (task 01a120be). Optional: an adapter that does
  # not implement them cannot serve the HEAD/PATCH verbs on the presigned
  # upload URL. A future S3/R2 adapter can map them onto native multipart.
  #
  # Chunks may arrive out of order, so bytes and bookkeeping are separate:
  #
  #   * `write_at/3` writes `bytes` at absolute `offset` in the in-progress
  #     object. It records nothing and needs no lock.
  #   * `record_range/3` durably adds `[from, to)` to the received set and
  #     returns the new contiguous offset. Callers serialize it per key.
  #   * `upload_ranges/1` is the received set: sorted, disjoint `{from, to}`.
  #   * `upload_offset/1` is the CONTIGUOUS prefix from 0 received so far
  #     (0 when none).
  #   * `append_chunk/3` is the sequential shorthand: write at `offset`, which
  #     must equal `upload_offset/1`, else `{:error, {:offset_mismatch,
  #     actual}}`, then record it.
  #   * `complete_upload/1` makes the received bytes the object for `key` and
  #     returns its size and sha256. Callers serialize it with
  #     `record_range/3`.
  #   * `discard_part/1` drops any in-progress state, never the object.
  @callback append_chunk(key, non_neg_integer(), {:binary, binary()}) ::
              {:ok, non_neg_integer()}
              | {:error, {:offset_mismatch, non_neg_integer()}}
              | {:error, term()}
  @callback write_at(key, non_neg_integer(), {:binary, binary()}) :: :ok | {:error, term()}
  @callback record_range(key, non_neg_integer(), non_neg_integer()) ::
              {:ok, non_neg_integer()} | {:error, term()}
  @callback upload_ranges(key) ::
              {:ok, [{non_neg_integer(), non_neg_integer()}]} | {:error, term()}
  @callback upload_offset(key) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback complete_upload(key) :: {:ok, persist_ok} | {:error, term()}
  @callback discard_part(key) :: :ok

  @optional_callbacks append_chunk: 3,
                      write_at: 3,
                      record_range: 3,
                      upload_ranges: 1,
                      upload_offset: 1,
                      complete_upload: 1,
                      discard_part: 1
end
