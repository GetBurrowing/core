# Dev-only users for the admin theme editor (task 01a1557a-fe9b, Burrow
# redesign 24, stage 1).
#
#     mix run priv/repo/seeds/dev_theme_editor.exs
#
# Refuses any MIX_ENV but dev, and any database whose name is not a dev one.
# Idempotent: run it as often as you like.
#
# It ensures three users, each the user `/dev/login?as=<slug>` signs in as
# (the controller derives sub `dev-<slug>` and email `<slug>@localhost`, and
# finds the user by that sub):
#
#   * as=themeadmin — a root-org admin (promoted with the role lock, so the
#     email-domain rule cannot demote it on the next login);
#   * as=member     — an internal, non-admin member of the same (root) org;
#   * as=guest      — an external user: their membership carries the
#     `external` marker, so login admits them as external.

alias Platform.Accounts
alias Platform.Repo
alias Platform.Tenancy

unless Mix.env() == :dev do
  Mix.raise("dev_theme_editor.exs is dev-only; MIX_ENV=#{Mix.env()} refused")
end

database = Repo.config()[:database]

unless is_binary(database) and Regex.match?(~r/_dev(_|$)/, database) and
         not Regex.match?(~r/test|prod/, database) do
  Mix.raise("dev_theme_editor.exs touches only a dev database; got #{inspect(database)}")
end

root = Tenancy.get_root_org() || Mix.raise("no root org; run mix setup first")

# Exactly the identity AuthController.dev_admit/3 builds for `?as=<slug>`.
dev_user = fn slug ->
  {:ok, user} =
    Accounts.find_or_create_from_oidc(%{
      sub: "dev-#{slug}",
      email: "#{slug}@localhost",
      name: "Dev #{String.capitalize(slug)}"
    })

  user
end

admin = dev_user.("themeadmin")
{:ok, _} = Tenancy.promote_to_admin(admin, reason: "dev_theme_editor seed")
true = Tenancy.root_admin?(admin)

member = dev_user.("member")

if Tenancy.root_admin?(member) do
  {:ok, _} = Tenancy.revoke_admin(member, reason: "dev_theme_editor seed")
end

false = Tenancy.root_admin?(member)
true = Tenancy.member_of?(member, root.id)

guest = dev_user.("guest")
{:ok, _} = Tenancy.mark_membership_external(%{user_id: guest.id, org_id: root.id})
true = Tenancy.external_user?(guest)
false = Tenancy.root_admin?(guest)

IO.puts("""
dev_theme_editor: ready in org #{root.slug}
  /dev/login?as=themeadmin  root admin
  /dev/login?as=member      internal member, not an admin
  /dev/login?as=guest       external user
""")
