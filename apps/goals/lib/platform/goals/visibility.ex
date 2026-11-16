defmodule Platform.Goals.Visibility do
  @moduledoc """
  Who can see a goal (task 01a1dfc0, Goals 1/8 stage 3). This is the whole
  rule, decided in the query that reads the rows; nothing else grants
  visibility, and every read of a goal, stop, grant or entry in apps/goals
  starts from `visible_goals/1`.

  User U sees goal G when:

    1. U owns G;
    2. G has a `user` grant naming U;
    3. G has a `team` grant on an org where U has an `org_memberships` row
       with `external = false`;
    4. G has a `space` grant on a space where U has a `chat_participants`
       row (`participant_type = 'user'`).

  Agent A sees G when A is G's coach, or G has a `space` grant on a space
  where A has a `chat_participants` row (`participant_type = 'agent'`).

  A participant row is current by existing: leaving a space deletes it
  (migration 20260418220000 dropped `left_at`). Anything that is not a
  `%Platform.Accounts.User{}` or a `%Platform.Agents.Agent{}` sees nothing.

  ## The `goals.use` permission (task 01a1e229, Goals 9)

  Visibility also owns the one rule for "may this person use Goals at all":
  `may_use?/1`. A user without `goals.use` sees no goal, so `visible_goals/1`
  answers the empty query for them, read fresh on every call. That closes
  every read and every write that loads its goal first, and a revoke takes
  effect on the person's next call, not on their next page load. The
  functions in `Platform.Goals` that act without loading a goal call
  `may_use?/1` themselves. Nothing else in apps/goals compares the
  permission against a person; do not add a check in the web layer, call
  `may_use?/1`. Do not cache the answer: a cached permission is exactly the
  bug this rule closes.

  An agent's access is its granted `goals` tool bundle, which core already
  gates by `goals.use` before a tool runs, and the clock calls the coach with
  no tool call at all, so agents are not checked here.

  `Platform.Tenancy.visibility/1` and `scope/3` are NOT used: they answer
  `:root_all` for any root-org member, and a root admin must not see another
  person's goal. `Platform.Chat.participant?/2` is not used either: it checks
  users only, and privacy is decided inside this query, not by a caller.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat.Participant
  alias Platform.Goals.{Goal, Grant}
  alias Platform.Tenancy.OrgMembership

  @doc """
  Whether `actor` may use Goals at all: a user holds `goals.use` now, an
  agent always (its gate is the tool bundle), anything else never. Reads the
  permission on every call; never cache it.
  """
  @spec may_use?(term()) :: boolean()
  def may_use?(%User{id: user_id} = user) when is_binary(user_id),
    do: Platform.Access.can?(Platform.Access.Scope.for_user(user), "goals.use")

  def may_use?(%Agent{id: agent_id}) when is_binary(agent_id), do: true
  def may_use?(_actor), do: false

  @doc """
  An Ecto query of exactly the goals `actor` sees. A user without
  `goals.use` (`may_use?/1`) sees none.
  """
  @spec visible_goals(term()) :: Ecto.Query.t()
  def visible_goals(%User{id: user_id} = user) when is_binary(user_id) do
    if may_use?(user), do: user_goals(user_id), else: from(g in Goal, where: false)
  end

  def visible_goals(%Agent{id: agent_id}) when is_binary(agent_id) do
    from(g in Goal,
      as: :goal,
      where: g.coach_agent_id == ^agent_id or exists(space_grant("agent", agent_id))
    )
  end

  def visible_goals(_actor), do: from(g in Goal, where: false)

  defp user_goals(user_id) do
    from(g in Goal,
      as: :goal,
      where:
        g.owner_user_id == ^user_id or
          exists(
            from(gr in Grant,
              where:
                gr.goal_id == parent_as(:goal).id and gr.audience_type == "user" and
                  gr.user_id == ^user_id
            )
          ) or
          exists(
            from(gr in Grant,
              join: m in OrgMembership,
              on: m.org_id == gr.org_id,
              where:
                gr.goal_id == parent_as(:goal).id and gr.audience_type == "team" and
                  m.user_id == ^user_id and m.external == false
            )
          ) or
          exists(space_grant("user", user_id))
    )
  end

  defp space_grant(participant_type, participant_id) do
    from(gr in Grant,
      join: p in Participant,
      on: p.space_id == gr.space_id,
      where:
        gr.goal_id == parent_as(:goal).id and gr.audience_type == "space" and
          p.participant_type == ^participant_type and p.participant_id == ^participant_id
    )
  end
end
