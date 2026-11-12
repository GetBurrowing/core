# rig.sh rpc b seed_unread.exs <email> <count>
#
# Seeding for the switcher rig (task 01a1ccd4 stage 4), evaluated on the
# install's running node: a second person ("Rig Poster") posts <count>
# messages in a channel the rig user (<email>, who must already have signed
# in through OIDC) is a participant of. Prints `RIG unread=<n>`, the rig
# user's unread total afterwards.
alias Platform.{Chat, Repo}
alias Platform.Accounts.User

[email, count] = args
count = String.to_integer(count)

user = Repo.get_by!(User, email: email)

poster =
  Repo.get_by(User, email: "rig.poster@example.com") ||
    %User{}
    |> User.changeset(%{
      email: "rig.poster@example.com",
      name: "Rig Poster",
      oidc_sub: "rig-poster-local",
      preferences: %{"first_run_goal" => "existing"}
    })
    |> Repo.insert!()

space =
  case Chat.get_space_by_slug("rig-switcher") do
    nil ->
      {:ok, space} = Chat.create_space(%{name: "Rig switcher", slug: "rig-switcher", kind: "channel"})
      space

    space ->
      space
  end

participant = fn user_id ->
  case Repo.get_by(Platform.Chat.Participant,
         space_id: space.id,
         participant_type: "user",
         participant_id: user_id
       ) do
    nil ->
      {:ok, p} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user_id,
          joined_at: DateTime.utc_now()
        })

      p

    p ->
      p
  end
end

_ = participant.(user.id)
author = participant.(poster.id)

for i <- 1..count do
  {:ok, _} =
    Chat.post_message(%{
      space_id: space.id,
      participant_id: author.id,
      content_type: "text",
      content: "Switcher rig message #{i}"
    })
end

IO.puts("RIG unread=#{Chat.total_unread_for_viewer(user)} space=#{space.slug}")
