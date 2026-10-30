# Seed the fixture `e2e/tests/meeting_human_invites.spec.ts` reads
# (task 01a18d0a-ec37 stage 3).
#
# Run INSIDE the dev server's container, from apps/platform:
#
#     mix run ../../e2e/scripts/seed-meeting-human-invite-fixture.exs
#
# Precondition: the viewer has logged in once, so its user row exists:
#
#     curl -s -o /dev/null http://<host>:<port>/dev/login?as=hiviewer
#
# What it writes, all fresh per run (a random tag keeps two runs apart):
#
#   * a chat space and a LIVE meeting bound to it, in a project of the root
#     org. The same meeting serves `/meetings/<slug>` and the in-chat
#     quickmeet on `/chat/<space slug>`, because the quickmeet joins
#     `Meetings.get_live_meeting_for_space/1`.
#   * the viewer as a chat participant of the space (NOT the host: the
#     control is for any human with access).
#   * a host and a joined guest in the room, so the humans list has rows.
#   * three internal users the spec searches for: two sharing a first name,
#     and one with a long name and a long email (truncation order).
#
# The last line printed is `FIXTURE <json>`; the spec reads it from the
# HUMAN_INVITE_FIXTURE env var.

alias Platform.{Chat, Meetings, Repo}
alias Platform.Accounts.User
alias Platform.Meetings.Meeting
alias Platform.Tasks.Project

login = System.get_env("HUMAN_INVITE_LOGIN", "hiviewer")
viewer = Repo.get_by(User, email: "#{login}@localhost") ||
  raise "no #{login}@localhost user: GET /dev/login?as=#{login} once first"

tag =
  for(_ <- 1..5, into: "", do: <<Enum.random(?a..?z)>>)
  |> String.capitalize()

org = Platform.Tenancy.get_root_org() || raise "no root org"

project =
  Repo.get_by(Project, org_id: org.id) ||
    %Project{}
    |> Project.changeset(%{name: "Burrow", slug: "burrow-#{String.downcase(tag)}", org_id: org.id})
    |> Repo.insert!()

{:ok, space} =
  Chat.create_space(%{
    name: "Invite E2E #{tag}",
    slug: "invite-e2e-#{String.downcase(tag)}",
    kind: "channel"
  })

id = Platform.Types.UUIDv7.generate()

meeting =
  %Meeting{id: id}
  |> Meeting.changeset(%{
    project_id: project.id,
    chat_space_id: space.id,
    slug: "invite-e2e-#{String.downcase(tag)}",
    name: "Invite E2E #{tag}",
    livekit_room_name: "meeting-#{id}",
    status: "live"
  })
  |> Repo.insert!()

user! = fn name, email ->
  Repo.insert!(%User{name: name, email: email, oidc_sub: "e2e-human-invite-" <> email})
end

host = user!.("Morgan Ellery #{tag}", "morgan.#{String.downcase(tag)}@example.com")
first = user!.("Dana Whitfield #{tag}", "dana.whitfield.#{String.downcase(tag)}@example.com")
second = user!.("Dana Cole #{tag}", "dana.cole.#{String.downcase(tag)}@example.com")

long =
  user!.(
    "Dana Alexandria Montgomery-Whitfield #{tag}",
    "dana.alexandria.montgomery-whitfield.operations.#{String.downcase(tag)}@northwind-logistics-example.com"
  )

for u <- [viewer, host] do
  {:ok, _} =
    Chat.add_participant(space.id, %{
      participant_type: "user",
      participant_id: u.id,
      display_name: u.name,
      joined_at: DateTime.utc_now()
    })
end

{:ok, room} = Meetings.ensure_room(space.id)
{:ok, room} = Meetings.activate_room(room)
{:ok, _} = Meetings.participant_joined(room, %{user_id: host.id, display_name: host.name})
{:ok, _} = Meetings.participant_joined(room, %{display_name: "Riley #{tag} (guest)"})

IO.puts(
  "FIXTURE " <>
    Jason.encode!(%{
      tag: tag,
      login: login,
      meeting_slug: meeting.slug,
      meeting_id: meeting.id,
      space_slug: space.slug,
      users: %{
        first: %{id: first.id, name: first.name, email: first.email},
        second: %{id: second.id, name: second.name, email: second.email},
        long: %{id: long.id, name: long.name, email: long.email}
      }
    })
)
