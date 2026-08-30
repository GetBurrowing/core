defmodule Platform.Tasks.BranchProvisioner.NoopRunner do
  @moduledoc """
  A `Platform.Tasks.BranchProvisioner.Runner` that touches nothing.

  Pinned as the runner in `config/test.exs`. Without it, every router
  dispatch in the test suite reaches `GhRunner`, which shells out to `gh`
  and makes a REAL network call — measured on
  `task_router_phase_assignee_test.exs`, whose fixture project points at
  `https://github.com/test/phase-assignee` and got back a live GitHub 404
  per dispatch. That is unrelated tests paying network latency to ask
  GitHub about a repository nobody owns, and it would fail differently on
  a machine with no `gh` credentials.

  Every callback answers `{:error, :branch_provisioning_disabled}`, which
  the router's fail-soft path logs and moves past — deliberately NOT a
  success, so a test that means to assert provisioning has to pin its own
  stub rather than silently observing nothing while believing it observed
  a create.
  """

  @behaviour Platform.Tasks.BranchProvisioner.Runner

  @disabled {:error, :branch_provisioning_disabled}

  @impl true
  def default_branch_sha(_args), do: @disabled

  @impl true
  def list_matching_refs(_args), do: @disabled

  @impl true
  def create_ref(_args), do: @disabled

  @impl true
  def compare_refs(_args), do: @disabled
end
