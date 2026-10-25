defmodule Platform.OrgThemeFixtures do
  @moduledoc """
  Published org themes for the stage 3 tests (task 01a1557a-fe9b): a theme
  in the root org that its members can see, and one in a separate tenant org
  that they cannot. Built through `Platform.Theming` (create_draft + publish
  by a root admin), so every fixture is a theme the real path could publish.
  """

  import Platform.TenancyFixtures

  alias Platform.ExternalUserFixtures, as: X
  alias Platform.Theming

  @doc """
  `%{admin, root, tenant, member, outsider, visible, hidden}`: `member` is in
  the root org and sees `visible` (published there); `outsider` is only in a
  tenant org, where `hidden` is published. `opts[:visible_name]` names the
  visible theme (default "Ocean").
  """
  def org_theme_world!(opts \\ []) do
    n = System.unique_integer([:positive])
    root = Platform.Tenancy.get_org!(acme_org_id())
    tenant = Platform.Tenancy.get_org!(tenant_org_id("themes-s3-#{n}"))
    admin = root_admin!()

    member = X.create_user!()
    X.plain_member!(member, root)

    outsider = X.create_user!()
    X.plain_member!(outsider, tenant)

    visible = published!(admin, root.id, Keyword.get(opts, :visible_name, "Ocean #{n}"))
    hidden = published!(admin, tenant.id, "Tenant only #{n}")

    %{
      admin: admin,
      root: root,
      tenant: tenant,
      member: member,
      outsider: outsider,
      visible: visible,
      hidden: hidden
    }
  end

  @doc "A theme created as a draft in `org_id` and published by `admin`."
  def published!(admin, org_id, name) do
    {:ok, draft} = Theming.create_draft(admin, org_id, %{name: name})
    {:ok, theme} = Theming.publish(admin, draft)
    theme
  end
end
