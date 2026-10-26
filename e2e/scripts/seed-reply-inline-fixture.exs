# Fixture for task 01a174f5 stage 3's e2e cases ("a reply to an agent's
# message is answered inline in the main log"). Run through
# seed-reply-inline-fixture.sh, which runs this with `mix run` against the
# review server's PLATFORM_DEV_DATABASE. Idempotent: a re-run reuses the
# channel, the agents and their runtimes, mints fresh runtime tokens, and does
# not re-post the two status messages.
#
# It creates:
#   * channel 'reply-inline-e2e' (agents_awake true, policy collaborative)
#     with the dev user (`/dev/login`, oidc sub `dev-local-user`, or
#     REPLY_INLINE_DEV_SUB) as a participant;
#   * two external-runtime agents, 'Agent A' and 'Agent B', each registered
#     and activated through Federation.register_runtime / activate_runtime,
#     linked, and on the channel's roster as members;
#   * one top-level message from each: 'A: status one', 'B: status two'.
#
# `--reset` first soft-deletes every message in the channel (top-level and
# thread), so the cases start from a clean log: run it between review passes,
# because the thread case puts a real thread (and its chip) on 'A: status one'.
#
# The runtime ids and tokens go to a 0600 JSON file (argv[0], else
# $TMPDIR/reply-inline-e2e-runtimes.json) for echo-runtime.mjs. Tokens are
# NEVER printed: this script prints the file path and the runtime ids only.

alias Platform.Accounts.User
alias Platform.Agents.Agent
alias Platform.Chat
alias Platform.Federation
alias Platform.Repo

import Ecto.Query

{flags, rest} = Enum.split_with(System.argv(), &String.starts_with?(&1, "--"))
reset? = "--reset" in flags

out_path =
  case rest do
    [path | _] -> path
    [] -> Path.join(System.tmp_dir!(), "reply-inline-e2e-runtimes.json")
  end

dev_sub = System.get_env("REPLY_INLINE_DEV_SUB", "dev-local-user")
slug = "reply-inline-e2e"

user =
  Repo.one(from(u in User, where: u.oidc_sub == ^dev_sub)) ||
    (IO.puts(:stderr, "seed: no dev user (oidc sub #{dev_sub}); visit /dev/login on the review server first")
     System.halt(2))

general = Chat.get_space_by_slug("general")

space =
  case Chat.get_space_by_slug(slug) do
    nil ->
      {:ok, space} =
        Chat.create_space(%{
          name: slug,
          slug: slug,
          kind: "channel",
          org_id: general && general.org_id
        })

      space

    space ->
      space
  end

{:ok, space} =
  Chat.update_space(space, %{agents_awake: true, agent_attention_policy: "collaborative"})

if reset? do
  live = Repo.all(from(m in Chat.Message, where: m.space_id == ^space.id and is_nil(m.deleted_at)))
  Enum.each(live, &Chat.delete_message/1)
  IO.puts("seed: --reset soft-deleted #{length(live)} message(s) in #{slug}")
end

_ =
  Chat.add_participant(space.id, %{
    participant_type: "user",
    participant_id: user.id,
    display_name: user.name || "Dev User",
    joined_at: DateTime.utc_now()
  })

agents = [
  %{name: "Agent A", agent_slug: "reply-inline-e2e-agent-a", runtime_id: "reply-inline-e2e-a", color: "teal", post: "A: status one"},
  %{name: "Agent B", agent_slug: "reply-inline-e2e-agent-b", runtime_id: "reply-inline-e2e-b", color: "amber", post: "B: status two"}
]

entries =
  for spec <- agents do
    runtime =
      case Federation.get_runtime_by_runtime_id(spec.runtime_id) do
        nil ->
          {:ok, rt} = Federation.register_runtime(user.id, %{runtime_id: spec.runtime_id, display_name: spec.name})
          rt

        rt ->
          rt
      end

    {:ok, runtime, token} = Federation.activate_runtime(runtime)

    agent =
      case Repo.get_by(Agent, slug: spec.agent_slug) do
        nil ->
          {:ok, agent} =
            Federation.link_agent(runtime, %{
              slug: spec.agent_slug,
              name: spec.name,
              status: "active",
              color: spec.color
            })

          agent

        agent ->
          {:ok, agent} = Federation.link_agent(Federation.get_runtime(runtime.id), agent)
          agent
      end

    {:ok, _} = Chat.add_space_agent(space.id, agent.id, role: "member")
    participant = Chat.get_agent_participant(space.id, agent.id)

    already? =
      Repo.exists?(
        from(m in Chat.Message,
          where:
            m.space_id == ^space.id and m.participant_id == ^participant.id and
              m.content == ^spec.post and is_nil(m.deleted_at)
        )
      )

    unless already? do
      {:ok, _} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: participant.id,
          content_type: "text",
          content: spec.post
        })
    end

    %{name: spec.name, runtime_id: spec.runtime_id, token: token, space_id: space.id}
  end

File.write!(out_path, Jason.encode!(%{space_id: space.id, space_slug: slug, runtimes: entries}, pretty: true))
File.chmod!(out_path, 0o600)

IO.puts("seed: channel #{slug} ready (/chat/#{slug})")
IO.puts("seed: runtimes #{Enum.map_join(entries, ", ", & &1.runtime_id)}")
IO.puts("seed: credentials written to #{out_path} (0600; tokens not printed)")
