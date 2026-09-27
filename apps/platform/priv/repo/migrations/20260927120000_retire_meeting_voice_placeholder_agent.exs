defmodule Platform.Repo.Migrations.RetireMeetingVoicePlaceholderAgent do
  use Ecto.Migration

  @moduledoc """
  Task 01a0e47c stage 1: retire the stale ad-hoc "Meeting Voice" placeholder
  agent.

  Per org journal 2026-09-26 and the task 01a0e47c stage 1 brief: Dalton
  created this row directly against prod as a manual/ad hoc test ("say
  hello only, no real behavior"), outside any committed seed or migration —
  so `git grep` never finds it, and it has to be retired the same way it
  was created, by a write that targets prod directly. Harper invited it by
  mistake the night of 2026-09-25 and got silence; it was confirmed retired
  the next day. It is a SEPARATE agent from the correctly-named
  "Meeting Assistant" (slug `meeting-assistant`, seeded by
  `mix platform.seed_meeting_voice_agent`, task 01a0d4a0) — this migration
  never matches that row. It is also separate from "AgentVoice" (slug
  `agentvoice`), an older, pre-existing voice agent explicitly out of scope
  for this cleanup.

  ## What this does, and why it is not a delete

  Finds the agent by BOTH slug (`"meeting-voice"`) AND display name
  (`"Meeting Voice"`) — belt and suspenders against ever matching
  `meeting-assistant` or `agentvoice`, whose slugs and names are both
  different strings. For every match:

    * `status` flips to `"archived"`. `Chat.list_agents_for_picker/0` (the
      source PlatformWeb.MeetingLive.invitable_roster/1 unions in as
      "every other active agent") filters `where: a.status == "active"`, so
      an archived agent drops out of every meeting's invite roster and out
      of the general conversation-add-agent picker. This is the actual
      removal: no code path offers an archived agent a button.
    * every runtime row bound to the agent
      (`Platform.Federation.runtimes_for_agent/1`, which is the agent's own
      federated "brain" row here — this placeholder has no separate voice
      "mouth" row the way `meeting-assistant` does) is revoked via
      `Platform.Federation.revoke_runtime/1`: status flips to `"revoked"`
      and the auth token hash is cleared, so even a stale reference to it
      can never authenticate.
    * `metadata["retired"]` is stamped with when, by what, and why — an
      audit trail, not a silent status flip.

  Deliberately NOT a delete: the row (and its runtime row) stay queryable
  for provenance, exactly as `Federation.suspend_runtime/1` /
  `revoke_runtime/1` already do for the rest of the runtime lifecycle.

  ## Idempotent

  A rerun finds the row already `"archived"` and skips it entirely (and
  finds its runtime(s) already `"revoked"` and skips those too), so running
  this migration twice, or running it after the placeholder has already
  been retired by hand, changes nothing.

  No matching row (a fresh install, or an environment where this ad hoc
  test agent was never created) is a no-op — this migration creates
  nothing.
  """

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Repo

  def up do
    Repo.all(
      from(a in Agent,
        where: a.slug == "meeting-voice" and a.name == "Meeting Voice"
      )
    )
    |> Enum.each(fn agent ->
      agent = archive_agent!(agent)

      agent
      |> Federation.runtimes_for_agent()
      |> Enum.each(&revoke_runtime_unless_already!/1)
    end)

    :ok
  end

  defp archive_agent!(%{status: "archived"} = agent), do: agent

  defp archive_agent!(agent) do
    retired_note = %{
      "retired_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "retired_by" => "migration RetireMeetingVoicePlaceholderAgent (task 01a0e47c stage 1)",
      "retired_reason" =>
        "stale ad-hoc test placeholder created by Dalton 2026-09-25 (\"say hello only, " <>
          "no real behavior\"); Harper invited it by mistake the same night and got " <>
          "silence; confirmed retired 2026-09-26 (org journal). Superseded by the " <>
          "dedicated \"Meeting Assistant\" agent (task 01a0d4a0)."
    }

    {:ok, updated} =
      agent
      |> Agent.changeset(%{
        status: "archived",
        metadata: Map.put(agent.metadata || %{}, "retired", retired_note)
      })
      |> Repo.update()

    updated
  end

  defp revoke_runtime_unless_already!(%{status: "revoked"}), do: :ok

  defp revoke_runtime_unless_already!(runtime) do
    {:ok, _} = Federation.revoke_runtime(runtime)
    :ok
  end

  def down do
    :ok
  end
end
