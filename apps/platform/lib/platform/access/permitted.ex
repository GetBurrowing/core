defmodule Platform.Access.Permitted do
  @moduledoc """
  The grant-aware set form of `Platform.Access.can?/3` for one resource type
  (task 01a1386d-e528 stage 2,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`), returned by
  `Platform.Access.permitted/3`.

      %Permitted{resource_type, permission, allow: :all | [id], deny: [id]}

  For `:project`, `:task`, `:stack`, `:space` and `:canvas`, `allow` and
  `deny` are ids OF `resource_type`, already expanded down the inheritance
  edges. A resource is permitted exactly when
  `(allow == :all or id in allow) and id not in deny`: deny wins.

  For `:memory_node` they are the ids of the NODES the role rules or grants
  name, NOT expanded: a page is permitted when an `allow` node (or `:all`)
  covers its path and no `deny` node does, where a node covers a path when
  its current path equals it, or is a prefix ending in `/` that it starts
  with.

  `Platform.Access.Query.where_permitted/5` is the one place this becomes an
  Ecto condition.
  """

  @enforce_keys [:resource_type, :permission]
  defstruct resource_type: nil, permission: nil, allow: [], deny: []

  @type t :: %__MODULE__{
          resource_type: atom(),
          permission: String.t(),
          allow: :all | [binary()],
          deny: [binary()]
        }
end
