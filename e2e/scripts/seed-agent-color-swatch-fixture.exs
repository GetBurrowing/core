# Seed the fixture `e2e/tests/agent_color_swatch_scroll.spec.ts` reads
# (task 01a1b34f stage 2).
#
# Run from apps/platform against a PRIVATE dev database (never the shared one):
#
#     PLATFORM_DEV_DATABASE=<your private dev db> \
#       mix run ../../e2e/scripts/seed-agent-color-swatch-fixture.exs
#
# Precondition: the viewer has logged in once, so its user row exists:
#
#     curl -s -o /dev/null http://localhost:<port>/dev/login?as=swatchviewer
#
# What it writes, fresh per run (a random tag keeps runs apart):
#
#   * an admin membership in the root org for the viewer, so the identity
#     forms on /control/<slug> are editable.
#   * a native agent owned by the viewer (the deepest identity form: the
#     colour swatches sit below the avatar, voice and runtime cards).
#   * an external agent.
#   Both start at colour "teal"; the spec picks "indigo", so a no-op save
#   cannot pass.
#
# The last line printed is `FIXTURE <json>`; the spec reads it from the
# SWATCH_FIXTURE env var.

alias Platform.Repo
alias Platform.Accounts.User
alias Platform.Agents.{Agent, NativeAgents}
alias Platform.Tenancy.OrgMembership

login = System.get_env("SWATCH_LOGIN", "swatchviewer")

viewer =
  Repo.get_by(User, email: "#{login}@localhost") ||
    raise "no #{login}@localhost user: GET /dev/login?as=#{login} once first"

org = Platform.Tenancy.get_root_org() || raise "no root org"

case Repo.get_by(OrgMembership, user_id: viewer.id, org_id: org.id) do
  nil ->
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: viewer.id, org_id: org.id, role: "admin"})
    |> Repo.insert!()

  %OrgMembership{role: "admin"} = m ->
    m

  m ->
    m |> Ecto.Changeset.change(role: "admin") |> Repo.update!()
end

tag = for(_ <- 1..5, into: "", do: <<Enum.random(?a..?z)>>)

{:ok, native, _runtime} =
  NativeAgents.create(viewer.id, %{name: "Swatch Native #{tag}", harness: "claude_code"})

native = native |> Ecto.Changeset.change(color: "teal") |> Repo.update!()

external =
  %Agent{}
  |> Agent.changeset(%{
    slug: "swatch-external-#{tag}",
    name: "Swatch External #{tag}",
    status: "active",
    runtime_type: "external",
    color: "teal"
  })
  |> Repo.insert!()

IO.puts(
  "FIXTURE " <>
    Jason.encode!(%{
      native: %{slug: native.slug, name: native.name},
      external: %{slug: external.slug, name: external.name},
      from: "teal",
      to: "indigo"
    })
)
