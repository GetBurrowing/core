defmodule Platform.InstructionPacks.Check do
  @moduledoc "Install-wide pull status, including discovery failures before any pack exists. Contains no consent settings."
  use Ecto.Schema
  alias Platform.Repo
  alias Platform.InstructionPacks.Check

  @primary_key {:singleton, :boolean, autogenerate: false}
  schema "instruction_pack_checks" do
    field(:pending, :boolean, default: false)
    field(:checked_at, :utc_datetime_usec)
    field(:last_successful_check_at, :utc_datetime_usec)
    field(:error_kind, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def get, do: Repo.get(Check, true) || %Check{singleton: true}
  def begin_check, do: write(%{pending: true, checked_at: DateTime.utc_now()})

  def finish(result) do
    attrs = %{pending: false, checked_at: DateTime.utc_now(), error_kind: nil}

    attrs =
      case result do
        :ok -> Map.put(attrs, :last_successful_check_at, DateTime.utc_now())
        {:error, reason} -> Map.put(attrs, :error_kind, error_kind(reason))
      end

    write(attrs)
  end

  defp error_kind(reason) when reason in [:sharing_disabled, :sharing_changed], do: "disabled"

  defp error_kind(reason)
       when reason in [:download_failed, :invalid_pack_source, :release_unavailable],
       do: "network"

  defp error_kind(_), do: "verification"

  defp write(attrs) do
    attrs = Map.put(attrs, :updated_at, DateTime.utc_now())

    Repo.insert!(struct(Check, Map.put(attrs, :singleton, true)),
      on_conflict: [set: Map.to_list(attrs)],
      conflict_target: :singleton
    )
  end
end
