defmodule Platform.Types.TSVector do
  @moduledoc """
  Read-only Ecto type for a Postgres `tsvector` column (task `019fb954-c848`).

  Every `tsvector` in this codebase is a **STORED GENERATED** column —
  Postgres computes it from other columns on write and rejects any attempt
  to supply a value. This type encodes that: `cast/1` and `dump/1` accept
  only `nil`, so a `tsvector` field can never be smuggled into an INSERT
  through `cast/3` or a hand-built changeset. The failure surfaces as an
  Ecto cast error at the boundary rather than as a Postgres
  `cannot insert a non-DEFAULT value into column` error at the write.

  `load/1` returns Postgrex's decoded form — a list of
  `Postgrex.Lexeme` structs, each carrying a normalised `word` and its
  `{position, weight}` pairs. Callers should treat the loaded value as
  opaque: it exists so a caller can assert the column is populated. Real
  matching and ranking happen in SQL (`@@`, `ts_rank_cd/2`), where the GIN
  indexes can be used, not by walking this list in Elixir.

  A plain `:string` field would not work here: Postgrex decodes
  `tsvectorsend` into lexeme structs, and `Ecto.Type.load(:string, list)`
  fails. `{:array, :map}` fails too — Ecto's `:map` explicitly rejects
  structs.
  """

  use Ecto.Type

  @impl true
  def type, do: :tsvector

  @impl true
  def cast(nil), do: {:ok, nil}
  def cast(_), do: :error

  @impl true
  def load(nil), do: {:ok, nil}
  def load(lexemes) when is_list(lexemes), do: {:ok, lexemes}
  def load(_), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(_), do: :error
end
