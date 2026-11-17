# Dev-only fixture for assets/test/mobile_mention_geometry_test.mjs.
# Run with MIX_ENV=dev mix run after starting the private dev server.
if Mix.env() != :dev, do: raise("mobile mention browser fixture requires MIX_ENV=dev")

alias Platform.{Accounts, Chat, Repo}
alias Platform.Agents.Agent
import Ecto.Query

for i <- 1..12 do
  slug = "mention-helper-#{i}"

  unless Repo.get_by(Agent, slug: slug),
    do: Repo.insert!(%Agent{slug: slug, name: "Helper #{i}", status: "active"})
end

{:ok, user} =
  Accounts.find_or_create_from_oidc(%{
    sub: "dev-mobile-mention",
    email: "mobile-mention@localhost",
    name: "Mention tester"
  })

Accounts.update_user_preference(user.id, "first_run_goal", "existing")
Accounts.update_user_preference(user.id, "notification_banner_dismissed", false)

unless Chat.get_space_by_slug("mobile-mention-empty") do
  Chat.create_channel(%{
    name: "Mobile mentions empty",
    slug: "mobile-mention-empty",
    created_by: user.id
  })
end

space =
  Chat.get_space_by_slug("mobile-mention") ||
    elem(
      Chat.create_channel(%{
        name: "Mobile mentions",
        slug: "mobile-mention",
        created_by: user.id
      }),
      1
    )

participant = Repo.get_by!(Platform.Chat.Participant, space_id: space.id, participant_id: user.id)

unless Repo.exists?(from(m in Platform.Chat.Message, where: m.space_id == ^space.id)) do
  Chat.post_message(%{
    space_id: space.id,
    participant_id: participant.id,
    content_type: "text",
    content: "Open this thread to test agent tagging."
  })
end
