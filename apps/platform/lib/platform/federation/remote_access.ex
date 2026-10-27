defmodule Platform.Federation.RemoteAccess do
  @moduledoc """
  Who may be offered the remote terminal on a federated agent (task 01a17b17).

  The permission is the product of two things, never a bare boolean:

    * the federation KIND of the relationship between the viewer and the
      agent's runtime, and
    * an explicit OPT-IN made on the agent's own machine.

  Only the kinds in `allowed_kinds/0` can ever be switched on. Today that is
  exactly one: `:own_agent_in_member_install`, an agent that belongs to the
  viewer, in an install the viewer belongs to. For any other kind
  `permitted?/2` is false whatever the opt-in says, and there is no flag,
  config or environment override. A later marketplace or guest kind starts
  locked and inherits that lock until someone edits `@allowed_kinds` on
  purpose, in a diff a reviewer will see.

  The agent-config surface and the terminal view share this module so the two
  can never disagree about who is allowed.
  """

  @kinds [:own_agent_in_member_install, :other_federation]
  @allowed_kinds [:own_agent_in_member_install]

  @type kind :: :own_agent_in_member_install | :other_federation

  @doc "Every kind core knows how to name."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The kinds the terminal can be offered for. Today: one."
  @spec allowed_kinds() :: [kind()]
  def allowed_kinds, do: @allowed_kinds

  @doc """
  The kind of the relationship between `user_id` and `runtime`.

  Only a runtime whose `owner_user_id` is the viewer is the viewer's own
  agent. Everything else, including an unknown runtime, is `:other_federation`.
  """
  @spec kind_for(map() | nil, binary() | nil) :: kind()
  def kind_for(%{owner_user_id: owner}, user_id)
      when is_binary(owner) and is_binary(user_id) and owner == user_id,
      do: :own_agent_in_member_install

  def kind_for(_runtime, _user_id), do: :other_federation

  @doc "True when `kind` is one the terminal may ever be offered for."
  @spec allowed_kind?(term()) :: boolean()
  def allowed_kind?(kind), do: kind in @allowed_kinds

  @doc """
  The one decision: the terminal is permitted only for an allowed kind AND an
  explicit opt-in. A disallowed kind is refused even with `opt_in` true.
  """
  @spec permitted?(term(), term()) :: boolean()
  def permitted?(kind, opt_in), do: allowed_kind?(kind) and opt_in == true
end
