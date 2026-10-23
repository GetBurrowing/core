# Dev-only demo of the daily briefing in the Inbox (task 01a15ee1 stage 5).
#
#     mix run priv/repo/dev_seeds/briefing_inbox_demo.exs --email <user email> [--admin]
#
# Runs against the DEV database only: it refuses MIX_ENV test and prod (and
# anything that is not dev), and it refuses a repo whose database name is
# not a dev one (`platform_dev` or `platform_dev_<suffix>`). Never run it
# against an install's production container.
#
# What it does, idempotently per day:
#
#   * makes sure a `memory.dreaming` holder exists (the unattended actor for
#     tasks) and a `historian` role holder (who applies page edits), each
#     with a brain runtime carrying the module it needs;
#   * makes sure the page `org/page/briefing-demo.md` exists with a line to
#     edit, last edited by the user (so the page edit is addressed to them);
#   * makes sure the org has at least two live projects;
#   * turns `dissemination_enabled` on;
#   * ingests one block of each kind through `Insights.ingest_from_journal/4`,
#     authored by the dreaming holder: a question, a page_edit, a task naming
#     a project, a task naming no project, a briefing line, and a message to
#     an outside email address;
#   * runs `Disseminator.run/1`, then hands a page edit the run did not
#     select (`apply_page_edits` off) to the user with `deliver_now/3`.
#
# `--admin` promotes the user to a root-org admin first: "needs your call"
# items (the outside message among them) are routed to root admins.

alias Platform.Accounts.User
alias Platform.Agents.Agent
alias Platform.Agents.AgentRuntime
alias Platform.Access.RuntimeProfiles
alias Platform.Memory.Insights
alias Platform.Memory.Insights.Disseminator
alias Platform.Memory.Insights.Settings
alias Platform.Org.Wiki
alias Platform.Repo
alias Platform.Tenancy.OrgMembership

import Ecto.Query, only: [from: 2]

unless Mix.env() == :dev do
  Mix.raise("briefing_inbox_demo.exs is dev-only; MIX_ENV=#{Mix.env()} refused")
end

database = Repo.config()[:database]

# `platform_dev`, or a per-worktree `platform_dev_<suffix>`; never a test or
# production database name.
unless is_binary(database) and Regex.match?(~r/_dev(_|$)/, database) and
         not Regex.match?(~r/test|prod/, database) do
  Mix.raise("briefing_inbox_demo.exs touches only a dev database; got #{inspect(database)}")
end

{opts, _rest, _invalid} =
  OptionParser.parse(System.argv(), strict: [email: :string, admin: :boolean])

email = opts[:email] || Mix.raise("usage: mix run #{__ENV__.file} --email <user email> [--admin]")
user = Repo.get_by(User, email: email) || Mix.raise("no user with email #{email}")
org = Platform.Tenancy.get_root_org() || Mix.raise("no root org")
today = Disseminator.local_date(DateTime.utc_now())

if opts[:admin] do
  from(m in OrgMembership, where: m.user_id == ^user.id and m.org_id == ^org.id)
  |> Repo.update_all(set: [role: "admin"])
end

# ── Agents: the dreaming holder and the Historian ──────────────────────

agent! = fn slug, name ->
  Repo.get_by(Agent, slug: slug) ||
    Repo.insert!(%Agent{slug: slug, name: name, status: "active"})
end

runtime! = fn agent, modules ->
  case agent.runtime_id && Repo.get(AgentRuntime, agent.runtime_id) do
    %AgentRuntime{} = runtime ->
      runtime

    _ ->
      runtime =
        %AgentRuntime{}
        |> AgentRuntime.changeset(%{
          runtime_id: "briefing-demo-#{agent.slug}",
          owner_user_id: user.id,
          agent_id: agent.id
        })
        |> Repo.insert!()

      {:ok, _profile} =
        RuntimeProfiles.create_for_runtime(
          runtime,
          modules,
          RuntimeProfiles.translated_permissions(modules)
        )

      Repo.update_all(from(a in Agent, where: a.id == ^agent.id), set: [runtime_id: runtime.id])
      runtime
  end
end

dreamer =
  case Platform.Roles.assignee_for("memory.dreaming") do
    %{id: id} ->
      Repo.get!(Agent, id)

    nil ->
      agent = agent!.("briefing-demo-dreamer", "Dreaming")
      {:ok, _} = Platform.Roles.set_override("memory.dreaming", agent.id)
      agent
  end

runtime!.(Repo.get!(Agent, dreamer.id), ["task"])

if is_nil(Platform.Roles.agent_id_for_role("historian")) do
  historian = agent!.("briefing-demo-historian", "Historian")
  {:ok, _} = Platform.Roles.assign_role("historian", historian.id)
  runtime!.(Repo.get!(Agent, historian.id), ["memory"])
end

# ── The page, the projects, the settings ───────────────────────────────

page = "org/page/briefing-demo.md"

unless Wiki.get_page(page) do
  {:ok, _} =
    Wiki.upsert_page(page, %{
      content: "# Briefing demo\n\nDeploys go to host-a every Tuesday.\n",
      updated_by: user.id
    })
end

project! = fn name ->
  Repo.get_by(Platform.Tasks.Project, name: name, org_id: org.id) ||
    elem(Platform.Tasks.create_project(%{name: name, org_id: org.id}), 1)
end

named = project!.("Briefing demo")
_other = project!.("Briefing demo (other)")

{:ok, _} =
  Settings.get()
  |> Settings.changeset(%{dissemination_enabled: true})
  |> Repo.update()

# ── One block of each kind ──────────────────────────────────────────────

journal = "org/journal/#{today}.md"
ref = Date.to_iso8601(today)

blocks = """
<synthesis-insight action="question" confidence="high" evidence="#Social System 10:21; Social tab error" addressee="#{user.id}">
Should we move to the paid mail plan? The free tier allows two connected accounts and both are taken, ref #{ref}-q.
</synthesis-insight>

<synthesis-insight action="page_edit" confidence="high" target="#{page}" source="page:#{page}" evidence="journal #{ref} deploy notes">
The deploy day moved, ref #{ref}-e.
<old>Deploys go to host-a every Tuesday.</old><new>Deploys go to host-b every Thursday.</new>
</synthesis-insight>

<synthesis-insight action="task" confidence="high" target="#{named.id}" addressee="#{user.id}" evidence="journal #{ref} CI topology">
Put the test scripts back under version control. The live copies have drifted, ref #{ref}-t1.
</synthesis-insight>

<synthesis-insight action="task" confidence="high" addressee="#{user.id}" evidence="#Agents #{ref}">
Someone should own the release notes. Nobody has picked them up this week, ref #{ref}-t2.
</synthesis-insight>

<synthesis-insight action="briefing" confidence="high" addressee="#{user.id}" evidence="#Agents 09:01">
Redesign rungs 4 and 5 are live on the experiment install, ref #{ref}-b.
</synthesis-insight>

<synthesis-insight action="question" confidence="high" addressee="ana@client.example" evidence="#Client thread #{ref}">
Hi Ana, can we move Thursday's review to Friday at 10:00? Ref #{ref}-o.
</synthesis-insight>
"""

{:ok, inserted} = Insights.ingest_from_journal(nil, journal, blocks, dreamer.id)
{:ok, result} = Disseminator.run(now: DateTime.utc_now())

# With `apply_page_edits` off (the shipped default) the digest never selects
# a page edit, so the run above leaves it undelivered. Hand it to the user's
# briefing the way a person's own request does (`deliver_now/3`, which
# applies nothing): it then waits under "Needs your call" with its diff.
# With the toggle on, the run applied it and it is already under Done today.
pending_edit =
  Repo.one(
    from(i in Platform.Memory.Insight,
      where:
        i.journal_path == ^journal and i.action_type == "page_edit" and i.state == "open" and
          is_nil(i.delivered_at) and like(i.body, ^"%ref #{ref}-e%"),
      limit: 1
    )
  )

if pending_edit, do: {:ok, _} = Disseminator.deliver_now(user.id, [pending_edit])

IO.puts(
  "briefing demo: #{inserted} new insight(s), delivered #{inspect(result)}; " <>
    "open /inbox/briefing/#{Date.to_iso8601(today)} as #{email}"
)
