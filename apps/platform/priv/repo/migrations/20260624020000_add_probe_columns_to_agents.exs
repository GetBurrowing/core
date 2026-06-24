defmodule Platform.Repo.Migrations.AddProbeColumnsToAgents do
  use Ecto.Migration

  @moduledoc """
  Extends the `agents` table with observability columns used by the
  External Agents probe + liveness flow (ADR 0041 M5 stage 1).

  Adds:
    * `last_probe_at`           — wall-clock timestamp of the most recent
                                  probe attempt (success or failure).
    * `last_probe_status`       — outcome of the most recent probe, one of
                                  "ok" | "http_error" | "network_error" |
                                  "unauthorized" | "timeout". Free-text
                                  string column today; no DB CHECK
                                  constraint — classification lives in
                                  `Platform.ExternalAgents.probe/1`
                                  (stage 2).
    * `last_probe_latency_ms`   — round-trip latency in milliseconds for
                                  the most recent probe attempt
                                  (recorded even on auth/HTTP failures).
    * `last_successful_fire_at` — wall-clock timestamp of the most recent
                                  responsibility-dispatch success.
                                  Written by the M6 dispatcher; defined
                                  here so the schema is ready when the
                                  liveness state machine (stage 3) reads
                                  it.

  All four columns are NULL-able observability fields; no indexes
  (queries are per-row by agent id). Probe + dispatcher writers in
  later stages will route through a focused `Ecto.Changeset.change/2`
  rather than the full `Agent.changeset/2` to avoid tripping
  `validate_required([:slug, :name, :status])` on minimal updates.
  """

  def change do
    alter table(:agents) do
      add(:last_probe_at, :utc_datetime_usec)
      add(:last_probe_status, :string)
      add(:last_probe_latency_ms, :integer)
      add(:last_successful_fire_at, :utc_datetime_usec)
    end
  end
end
