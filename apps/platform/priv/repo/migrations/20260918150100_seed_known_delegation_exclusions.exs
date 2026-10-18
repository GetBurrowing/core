defmodule Platform.Repo.Migrations.SeedKnownDelegationExclusions do
  @moduledoc """
  Seed the two delegation exclusions that exist today, each with the full
  sentence of the reasoning behind it (task
  `01a0b491-0718-7001-8bba-bf50f119bb13` stage 2).

  `geordi` -> `capability_judgement`, `moore` -> `role_conflict`. The two
  causes are different and are stored differently on purpose; see
  `Platform.Agents.DelegationExclusion` for why no boolean was used.

  A NO-OP ON AN INSTALL WITHOUT THOSE SLUGS. Each insert is guarded on the
  agent row existing, so a fresh DB, a CI database and any other
  deployment of this codebase migrate cleanly and simply record nothing —
  these are judgements about two specific agents on one install, not
  platform facts.

  BOTH AGENTS WERE ALREADY OFFLINE when this was written, so the rows buy
  nothing today. They are written down for when that changes, which is
  also why `Platform.Agents.Delegation`'s tests insert a CONNECTED
  fixture runtime and exclude THAT: asserting these two are absent from
  the eligible list would pass whether or not the filter worked.

  Idempotent: `on_conflict: :nothing` against the `agent_id` unique
  index. `down/0` deletes only the rows this migration could have
  inserted, matched by the same slugs.
  """

  use Ecto.Migration

  import Ecto.Query

  @exclusions [
    {"geordi", "capability_judgement",
     "Geordi runs on a local model whose output quality does not clear the bar for delegated build stages; this is a judgement about the model behind the agent, not about the agent's availability, so an idle Geordi is still not a candidate."},
    {"moore", "role_conflict",
     "Moore holds architect responsibilities, and reviewing a design while also executing against it collapses the two roles the review exists to keep apart; this exclusion is about the role, and it lapses if and when the role does."}
  ]

  # The deciding operator (a neutral label since task 01a14b9e stage 5; on a
  # fresh database no agent row matches, so nothing is written).
  @decided_by "operator"

  def up do
    now = DateTime.utc_now()

    rows =
      for {slug, kind, reason} <- @exclusions,
          agent_id = agent_id_for_slug(slug),
          not is_nil(agent_id) do
        %{
          id: Ecto.UUID.dump!(Platform.Types.UUIDv7.generate()),
          agent_id: agent_id,
          reason_kind: kind,
          reason: reason,
          decided_by: @decided_by,
          inserted_at: now,
          updated_at: now
        }
      end

    if rows != [] do
      Platform.Repo.insert_all("agent_delegation_exclusions", rows,
        on_conflict: :nothing,
        conflict_target: :agent_id
      )
    end
  end

  def down do
    agent_ids =
      @exclusions
      |> Enum.map(fn {slug, _kind, _reason} -> agent_id_for_slug(slug) end)
      |> Enum.reject(&is_nil/1)

    if agent_ids != [] do
      Platform.Repo.delete_all(
        from(e in "agent_delegation_exclusions", where: e.agent_id in ^agent_ids)
      )
    end
  end

  defp agent_id_for_slug(slug) do
    Platform.Repo.one(from(a in "agents", where: a.slug == ^slug, select: a.id))
  end
end
