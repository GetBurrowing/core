# Seed the fixture `e2e/tests/meeting_guest_link_by_name.spec.ts` reads
# (task 01a19ea6 stage 3).
#
# Run INSIDE the dev server's container, from apps/platform:
#
#     mix run ../../e2e/scripts/seed-meeting-guest-link-fixture.exs
#
# Precondition: the viewer has logged in once, so its user row exists:
#
#     curl -s -o /dev/null http://<host>:<port>/dev/login?as=glviewer
#
# What it writes, fresh per run (a random tag keeps two runs apart):
#
#   * a project made with `Tasks.create_project/1` in the root org;
#   * meeting A, scheduled two days ahead with a scheduled end two hours
#     later (the "Until the meeting ends" case);
#   * meeting B, scheduled earlier today and already over, so it has no
#     FUTURE scheduled end (the 24-hour fallback case). A meeting with no
#     schedule at all has no detail panel to invite from, so a past end is
#     the reachable form of "no scheduled end";
#   * the viewer as a chat participant of both spaces (not the host: Add
#     people is open to any viewer who can see the meeting);
#   * a member, so a member's name is a candidate rather than a guest name;
#   * one guest per spec combination whose link has ALREADY EXPIRED, with the
#     short link it had, so the spec can show that link refused after New link.
#
# MEETING_GUEST_HOST must already be set on the server. The last line printed
# is `FIXTURE <json>`; the spec reads it from GUEST_LINK_FIXTURE.

alias Platform.{Chat, Meetings, Repo}
alias Platform.Accounts.User
alias Platform.Meetings.{Invite, Meeting}

login = System.get_env("GUEST_LINK_LOGIN", "glviewer")

viewer =
  Repo.get_by(User, email: "#{login}@localhost") ||
    raise "no #{login}@localhost user: GET /dev/login?as=#{login} once first"

tag = for(_ <- 1..5, into: "", do: <<Enum.random(?a..?z)>>)
org = Platform.Tenancy.get_root_org() || raise "no root org"

{:ok, project} =
  Platform.Tasks.create_project(%{name: "Guest link e2e #{tag}", org_id: org.id})

space! = fn name ->
  {:ok, space} =
    Chat.create_space(%{
      name: "#{name} #{tag}",
      slug: "guest-link-#{String.downcase(name)}-#{tag}",
      kind: "channel"
    })

  {:ok, _} =
    Chat.add_participant(space.id, %{
      participant_type: "user",
      participant_id: viewer.id,
      display_name: viewer.name,
      joined_at: DateTime.utc_now()
    })

  space
end

meeting! = fn name, starts_at, ends_at ->
  space = space!.(name)
  id = Platform.Types.UUIDv7.generate()

  %Meeting{id: id}
  |> Meeting.changeset(%{
    project_id: project.id,
    chat_space_id: space.id,
    slug: "guest-link-#{String.downcase(name)}-#{tag}",
    name: "#{name} #{tag}",
    livekit_room_name: "meeting-#{id}",
    status: "scheduled",
    scheduled_start_at: starts_at,
    scheduled_end_at: ends_at
  })
  |> Repo.insert!()
end

# Both meetings sit inside the calendars' default 08:00-18:00 hour window
# (the spec runs in UTC), or they are never drawn and cannot be selected.
now = DateTime.utc_now()
today = DateTime.to_date(now)
a_start = DateTime.new!(Date.add(today, 2), ~T[14:00:00], "Etc/UTC")
meeting_a = meeting!.("Planning", a_start, DateTime.add(a_start, 2 * 3600, :second))

# Already over: today 09:00-10:00 once that is past, otherwise yesterday.
b_day = if now.hour >= 11, do: today, else: Date.add(today, -1)
b_start = DateTime.new!(b_day, ~T[09:00:00], "Etc/UTC")
meeting_b = meeting!.("Retro", b_start, DateTime.add(b_start, 3600, :second))

member =
  Repo.insert!(%User{
    name: "Member Quill #{tag}",
    email: "member.quill.#{tag}@example.com",
    oidc_sub: "e2e-guest-link-member-#{tag}"
  })


combos = for s <- ~w(meetings calendar), v <- ~w(desktop phone), do: "#{s}-#{v}"

expired =
  Map.new(combos, fn combo ->
    name = "Expired #{combo} #{tag}"
    {:ok, %{invite: invite}} = Meetings.invite_guest(meeting_a, %{display_name: name})
    url = Meetings.guest_invite_link(meeting_a, invite)

    invite
    |> Invite.changeset(%{expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)})
    |> Repo.update!()

    {combo, %{id: invite.id, name: name, url: url}}
  end)

IO.puts(
  "FIXTURE " <>
    Jason.encode!(%{
      tag: tag,
      login: login,
      a: %{
        id: meeting_a.id,
        slug: meeting_a.slug,
        starts_at: meeting_a.scheduled_start_at,
        ends_at: meeting_a.scheduled_end_at
      },
      b: %{
        id: meeting_b.id,
        slug: meeting_b.slug,
        starts_at: meeting_b.scheduled_start_at,
        ends_at: meeting_b.scheduled_end_at
      },
      member: %{id: member.id, name: member.name},
      expired: expired
    })
)
