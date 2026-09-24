defmodule Platform.Mail.Internal do
  @moduledoc """
  Which recipient addresses are INTERNAL to an org (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 2).

  An address is internal iff it equals — case-insensitively, and otherwise
  exactly — the email of a user who has an `org_memberships` row for that org
  with `external == false` and whose `users.archived_at` is nil. Everything
  else is external, including:

    * a member whose membership is `external: true`;
    * an archived user;
    * an address on the same domain as the org's members that belongs to
      nobody in the org.

  There is no domain rule. Orgs have no verified-domain field, and
  `Platform.Tenancy.derive_role_from_email/1` is a role heuristic, not a
  membership fact; neither is consulted. The send path and the UI's
  recipient flagging both call `partition/2`, so they cannot disagree.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @doc """
  Split `addresses` into `{internal, external}` for `org_id`, preserving the
  input order and spelling. One query for the whole list.
  """
  @spec partition(binary(), [String.t()]) :: {[String.t()], [String.t()]}
  def partition(org_id, addresses) when is_binary(org_id) and is_list(addresses) do
    internal = internal_set(org_id, addresses)
    Enum.split_with(addresses, &MapSet.member?(internal, String.downcase(&1)))
  end

  @doc "The external addresses in `addresses` for `org_id`, in input order."
  @spec external(binary(), [String.t()]) :: [String.t()]
  def external(org_id, addresses) do
    {_internal, external} = partition(org_id, addresses)
    external
  end

  defp internal_set(_org_id, []), do: MapSet.new()

  defp internal_set(org_id, addresses) do
    wanted = addresses |> Enum.map(&String.downcase/1) |> Enum.uniq()

    from(u in User,
      join: m in OrgMembership,
      on: m.user_id == u.id,
      where:
        m.org_id == ^org_id and m.external == false and is_nil(u.archived_at) and
          fragment("lower(?)", u.email) in ^wanted,
      select: fragment("lower(?)", u.email),
      distinct: true
    )
    |> Repo.all()
    |> MapSet.new()
  end
end
