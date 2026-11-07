defmodule Platform.InstructionPacks.Entry do
  @moduledoc """
  Per-target vendor baseline and effective provenance. A nil baseline is not
  evidence of ownership: pre-existing content is local, including seeded text.
  Deletions are local edits too. Text comparison is deliberately byte-for-byte.
  """
  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  schema "instruction_pack_entries" do
    field(:pack_id, :string)
    field(:type, :string)
    field(:target, :string)
    field(:vendor_content, :string)
    field(:vendor_hash, :string)
    field(:effective_version, :integer)
    field(:applied_hash, :string)
    field(:conflict, :map)
    field(:retired, :boolean, default: false)
    timestamps(type: :utc_datetime_usec)
  end

  def hash(nil), do: nil
  def hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  @doc "Return a write decision and provenance; never treat equal local/default strings as consent."
  def reconcile(previous, local, incoming, version) do
    owned =
      not is_nil(previous) and previous.applied_hash != nil and
        hash(local) == previous.applied_hash

    cond do
      owned and is_nil(incoming) ->
        # Retiring guidance stops managing it without deleting content or
        # attachments. Local administrators can remove it deliberately later.
        {:keep, local,
         %{
           vendor_content: nil,
           vendor_hash: nil,
           applied_hash: nil,
           effective_version: previous.effective_version,
           conflict: nil,
           retired: true
         }}

      owned ->
        {:write, incoming,
         %{
           vendor_content: incoming,
           vendor_hash: hash(incoming),
           applied_hash: hash(incoming),
           effective_version: version,
           conflict: nil,
           retired: is_nil(incoming)
         }}

      is_nil(previous) and is_nil(local) and not is_nil(incoming) ->
        {:write, incoming,
         %{
           vendor_content: incoming,
           vendor_hash: hash(incoming),
           applied_hash: hash(incoming),
           effective_version: version,
           conflict: nil,
           retired: false
         }}

      true ->
        {:keep, local,
         %{
           vendor_content: incoming,
           vendor_hash: hash(incoming),
           applied_hash: previous && previous.applied_hash,
           effective_version: previous && previous.effective_version,
           conflict: %{
             "base" => previous && previous.vendor_content,
             "local" => local,
             "incoming" => incoming,
             "incoming_version" => version
           },
           retired: is_nil(incoming)
         }}
    end
  end
end
