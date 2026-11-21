defmodule Platform.Social.ApprovalDeadline do
  @moduledoc """
  Approval deadlines for legacy posts. A miss is derived, never a vendor
  failure or a stored status. Callers that write must decide on the locked
  current post and sample the clock after acquiring that lock.
  """

  @doc "Whether a scheduled time is at or before the supplied clock."
  def expired?(post, now \\ DateTime.utc_now())
  def expired?(%{scheduled_at: %DateTime{} = at}, now), do: DateTime.compare(at, now) != :gt
  def expired?(_post, _now), do: false

  @doc "A waiting legacy post whose human approval deadline has passed."
  def missed?(post, now \\ DateTime.utc_now())
  def missed?(%{flow: "studio"}, _now), do: false
  def missed?(%{status: "needs_approval"} = post, now), do: expired?(post, now)
  def missed?(_post, _now), do: false

  @doc "Untimed approval remains immediate; an expired scheduled approval is refused."
  def check_approval(post, now \\ DateTime.utc_now()) do
    if expired?(post, now), do: {:error, :slot_passed}, else: :ok
  end

  @doc "An agent may edit copy, but cannot erase an expired unapproved time."
  def check_agent_edit(post, changeset, now \\ DateTime.utc_now()) do
    if post.status in ~w(draft needs_approval) and expired?(post, now) and
         Map.has_key?(changeset.changes, :scheduled_at),
       do: {:error, :human_retime_required},
       else: :ok
  end
end
