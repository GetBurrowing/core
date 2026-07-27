defmodule Platform.UUID do
  @moduledoc """
  The canonical UUID predicate for boundary lookups.

  Reach for this — not a hand-rolled `Ecto.UUID.cast/1` guard — whenever an id
  arrives from outside the database: an MCP tool argument, a channel message, a
  webhook body, a LiveView `params` map, a URL path segment.

  ## Why this module exists

  Schemas in this app key on `Platform.Types.UUIDv7` or `:binary_id`, and BOTH
  raise rather than return an error when handed a malformed id:

    * `Repo.get(User, "system")` raises `Ecto.Query.CastError`, because
      `Platform.Types.UUIDv7.cast/1` rejects any non-36-character binary.
    * `Repo.insert/1` with a bad `:binary_id` field raises `Ecto.ChangeError`
      at dump time.

  A raise from an API whose contract is `nil` / `{:error, _}` kills its caller.
  In production that took down a runtime channel process (PR #613). Values like
  `"system"`, `"system:auto"` and agent slugs are the MAJORITY of actor ids at
  agent boundaries, so this is the common path, not an edge case.

  ## Do not "simplify" this to a bare `Ecto.UUID.cast/1`

  The length check is load-bearing. `Ecto.UUID.cast/1` also accepts a raw
  16-byte binary — it hex-encodes it — while `Ecto.UUID.dump/1` rejects that
  same binary. Probed empirically before PR #613:

      "higgins"          cast=:error                                       dump=:error
      "higginshigginsxx" cast={:ok, "68696767-696e-7368-6967-67696e737878"} dump=:error
      canonical 36-char  cast={:ok, ...}                                    dump={:ok, ...}

  So ANY 16-character slug passes a cast-only guard and still raises inside
  `Repo`. Checking `byte_size/1` first closes that gap: a value satisfying
  `valid?/1` is guaranteed to cast AND dump.
  """

  @canonical_length 36

  @doc """
  True only for a canonical 36-character UUID string.

  Deliberately stricter than `Ecto.UUID.cast/1` — see the moduledoc for the
  16-byte-binary gap the length check closes. Non-binaries are `false`, so this
  is safe to call on any term.

      iex> Platform.UUID.valid?("0195f6c3-0000-7000-8000-000000000000")
      true
      iex> Platform.UUID.valid?("system:auto")
      false
      iex> Platform.UUID.valid?(nil)
      false
  """
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value) do
    byte_size(value) == @canonical_length and match?({:ok, _}, Ecto.UUID.cast(value))
  end

  def valid?(_value), do: false

  @doc """
  `{:ok, downcased_uuid}` for a canonical UUID string, `:error` otherwise.

  Same rule as `valid?/1`, in the error-tuple shape — for call sites whose
  local contract is already `{:ok, _} | :error` (most `with` chains in
  `Platform.Federation.ToolSurface`), so they need no `if valid?` dance.

      iex> Platform.UUID.cast("0195F6C3-0000-7000-8000-000000000000")
      {:ok, "0195f6c3-0000-7000-8000-000000000000"}
      iex> Platform.UUID.cast("higgins")
      :error
  """
  @spec cast(term()) :: {:ok, binary()} | :error
  def cast(value) do
    if valid?(value), do: Ecto.UUID.cast(value), else: :error
  end
end
