defmodule Platform.Chat.Canvas.Version do
  @moduledoc """
  A row in `canvas_versions` — one full document snapshot per (canvas, revision)
  pair (task 019e0ac0).

  Written in the same path as the canvas mutation it records:

    * Successful `Platform.Chat.create_canvas_with_message/3` → revision 1,
      `ops: nil` (the create has no upstream patch list).
    * Successful `Platform.Chat.patch_canvas/2` → revision N+1, `ops: <patch list>`.
    * Successful restore → revision N+1, `ops: [["restore_from_revision", R]]`.

  Rejected patches do NOT write a row. `written_by` is denormalized
  (`%{type, id, slug?, display_name?}`) so canvas history survives future
  participant deletions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "canvas_versions" do
    field(:canvas_id, :binary_id)
    field(:revision, :integer)
    field(:document, :map)
    # `ops` is stored JSONB. The migration uses `:map` because Ecto's
    # `{:array, :map}` is array-of-objects, but each op is itself a
    # `[name, ...args]` list. We marshal through a wrapper map at the
    # changeset boundary so the schema stays homogeneous.
    field(:ops, :map)
    field(:written_by, :map)
    field(:written_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @required_fields [:canvas_id, :revision, :document, :written_by, :written_at]
  @optional_fields [:ops]

  def changeset(version, attrs) do
    attrs = wrap_ops(attrs)

    version
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:revision, greater_than: 0)
    |> unique_constraint([:canvas_id, :revision],
      name: :canvas_versions_canvas_id_revision_index
    )
  end

  @doc """
  Pull the op list out of a loaded version row. Returns nil when the row
  recorded no ops (the initial create).
  """
  @spec ops(t()) :: list() | nil
  def ops(%__MODULE__{ops: nil}), do: nil
  def ops(%__MODULE__{ops: %{"ops" => list}}) when is_list(list), do: list
  def ops(%__MODULE__{ops: ops}) when is_list(ops), do: ops
  def ops(%__MODULE__{ops: _}), do: nil

  defp wrap_ops(attrs) do
    cond do
      Map.get(attrs, :ops) |> is_list() ->
        Map.put(attrs, :ops, %{"ops" => Map.get(attrs, :ops)})

      Map.get(attrs, "ops") |> is_list() ->
        Map.put(attrs, "ops", %{"ops" => Map.get(attrs, "ops")})

      true ->
        attrs
    end
  end
end
