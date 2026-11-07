defmodule Platform.InstructionPacks.Outcomes do
  @moduledoc """
  Bounded current effective pack inventory for the common usage batch.

  This is an observational inventory, never a causal experiment result. Habits
  currently exposes install-wide historic shapes without observation-time pack
  provenance. Consequently pack-attributed rates are explicitly unavailable;
  today's pack version must never be attached to historic signals. This module
  never reads habit_signals or exports content, target ids or arbitrary errors.
  """
  import Ecto.Query
  alias Platform.InstructionPacks.{Entry, State, Targets}
  alias Platform.Repo

  @keys ~w(pack_id selected_version effective_versions status habits_provenance)
  @max_packs 50
  @max_versions 50

  def snapshot do
    Repo.transaction(fn ->
      Repo.all(from(s in State, where: not is_nil(s.version), order_by: s.pack_id, limit: 51))
      |> Enum.map(fn state ->
        entries = Repo.all(from(e in Entry, where: e.pack_id == ^state.pack_id))
        mixed = Enum.any?(entries, &local?/1)
        %{
          "pack_id" => state.pack_id,
          "selected_version" => state.version,
          "effective_versions" => entries |> Enum.reject(&local?/1) |> Enum.map(& &1.effective_version) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort(),
          "status" => if(mixed, do: "mixed_or_local", else: "vendor"),
          "habits_provenance" => "unavailable"
        }
      end)
    end)
    |> case do
      {:ok, rows} -> if valid?(rows), do: rows, else: []
      _ -> []
    end
  end

  defp local?(entry) do
    case Targets.resolve(entry.type, entry.target) do
      {:ok, target} ->
        entry.conflict != nil or entry.applied_hash == nil or
          Entry.hash(Targets.content(target)) != entry.applied_hash
      _ -> true
    end
  end

  @doc "Strict receiver-side contract, repeated immediately before transport."
  def valid?(rows) when is_list(rows) and length(rows) <= @max_packs do
    Enum.all?(rows, &valid_row?/1) and
      length(Enum.uniq_by(rows, & &1["pack_id"])) == length(rows)
  end
  def valid?(_), do: false

  defp valid_row?(row) when is_map(row) do
    Enum.sort(Map.keys(row)) == Enum.sort(@keys) and
      is_binary(row["pack_id"]) and Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,99}\z/, row["pack_id"]) and
      version?(row["selected_version"]) and
      is_list(row["effective_versions"]) and length(row["effective_versions"]) <= @max_versions and
      Enum.all?(row["effective_versions"], &version?/1) and
      Enum.uniq(row["effective_versions"]) == row["effective_versions"] and
      row["status"] in ["vendor", "mixed_or_local"] and row["habits_provenance"] == "unavailable"
  end
  defp valid_row?(_), do: false
  defp version?(n), do: is_integer(n) and n > 0 and n <= 2_147_483_647
end
