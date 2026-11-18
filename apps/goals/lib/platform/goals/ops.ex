defmodule Platform.Goals.Ops do
  @moduledoc """
  Operator commands for the Goals module, run by a deployer through a release
  `rpc` ONLY. Nothing here is ever called from a tool, a LiveView or a
  controller, and nothing here takes an actor.

  Why a separate module and not an actor argument with a root-admin check
  (task 01a1eb3f):

    1. `Platform.Goals` promises that every function except `enabled?/0` takes
       the actor first. An operator command with no actor broke that promise;
       moving it here makes the promise true again.
    2. The only caller is a deployer in a release `rpc`. An actor variant would
       make the operator load a root-admin `%Platform.Accounts.User{}` inside
       the rpc string and would add a core root-admin dependency to an
       operator command: more surface, the same trust (whoever can run `rpc`
       already holds the node).
    3. The revoked and disabled sweeps (`revoked_test.exs`, `disabled_test.exs`)
       iterate `Platform.Goals.__info__(:functions)`. A function that is not on
       `Platform.Goals` cannot be reached by a person through any Goals path,
       which is the boundary this module draws.

  ## resend_start_signal/1

  `20261117220000_move_goal_proposals_out_of_dms` moves proposals written
  before task 01a1eab6 stage 2 out of the person's DM into their own space and
  dispatches nothing. After that migration the deployer runs this once per
  migrated open proposal, so the agent learns the new space id:

      /app/bin/platform rpc 'IO.inspect(Platform.Goals.Ops.resend_start_signal("<proposal id>"))'

  `rpc`, not `eval`: the signal goes out through the RUNNING node's runtime
  connections, which a fresh `eval` node does not hold.
  `{:ok, %Platform.Goals.Proposal{delivery: "sent"}}` is the success shape;
  the other answers are documented on
  `Platform.Goals.Proposals.resend_start_signal/1`.
  """

  alias Platform.Goals.Proposal

  @doc """
  Re-sends `goals.new_goal` for an open proposal (see the moduledoc for the
  command). Answers `{:error, :goals_disabled}` while Goals is off, before
  touching the database.
  """
  @spec resend_start_signal(term()) ::
          {:ok, Proposal.t()}
          | {:error, :goals_disabled | :not_found | :proposal_closed | :lead_missing_goals_tools}
  def resend_start_signal(proposal_id) do
    if Platform.Goals.enabled?(),
      do: Platform.Goals.Proposals.resend_start_signal(proposal_id),
      else: {:error, :goals_disabled}
  end
end
