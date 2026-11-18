defmodule Platform.Test.MailPrivacyFixtures do
  @moduledoc """
  Fixtures for the mailbox-ownership gate (task 01a1ea5b stage 2): users,
  agents and runtimes, mail accounts with an owner, inbound rows, and the
  chat posts and files that mail lands in. Every account is created through
  `Platform.Mail.create_account/4` and owned through
  `Platform.Mail.Ownership.set_owner/3`, the real write paths.

  Bodies and subjects carry marker tokens only; nothing here is real mail.
  """

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Mail
  alias Platform.Mail.{InboundMessage, Ownership}
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  def unique, do: System.unique_integer([:positive])

  def user!(tag) do
    n = unique()

    %User{}
    |> User.changeset(%{
      email: "mp-#{tag}-#{n}@example.com",
      name: "Mp #{tag} #{n}",
      oidc_sub: "mp-#{tag}-#{n}",
      preferences: %{"first_run_goal" => "existing"}
    })
    |> Repo.insert!()
  end

  def member!(user, org_id, role \\ "member") do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  def agent!(tag \\ "agent") do
    n = unique()

    %Agent{}
    |> Agent.changeset(%{slug: "mp-#{tag}-#{n}", name: "Mp #{tag} #{n}", status: "active"})
    |> Repo.insert!()
  end

  def runtime!(%Agent{} = agent, owner) do
    runtime =
      Repo.insert!(%AgentRuntime{
        agent_id: agent.id,
        owner_user_id: owner.id,
        runtime_id: "mp-rt-#{unique()}",
        status: "active"
      })

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        runtime,
        AgentRuntime.default_tool_profile(),
        nil
      )

    runtime
  end

  def account!(admin, org_id, attrs \\ %{}) do
    n = unique()

    {:ok, account} =
      Mail.create_account(
        admin,
        org_id,
        Map.merge(
          %{
            "name" => "mp-#{n}",
            "smtp_host" => "smtp.mp-#{n}.test",
            "smtp_port" => 2525,
            "smtp_tls" => "none",
            "username" => "mp-#{n}-relay"
          },
          attrs
        ),
        %{smtp: "mp-#{n}-password"}
      )

    account
  end

  def personal!(admin, account, owner) do
    {:ok, account} =
      Ownership.set_owner(admin, account, %{kind: "personal", owner_user_id: owner.id})

    account
  end

  def shared!(admin, account, members) do
    {:ok, account} = Ownership.set_owner(admin, account, %{kind: "shared"})
    for m <- members, do: {:ok, _} = Ownership.grant(admin, account, {:user, m.id})
    account
  end

  @doc """
  Make `account` a SHARED mailbox read by every internal member its org has
  right now. For suites written before mailbox ownership (task 01a1ea5b
  stage 2) whose people read or send from an account they never owned: an
  account is unassigned, so readable by nobody, until it has an owner.
  """
  def share_with_org!(admin, account) do
    import Ecto.Query, only: [from: 2]

    members =
      from(m in OrgMembership,
        where: m.org_id == ^account.org_id and m.external == false,
        select: m.user_id,
        distinct: true
      )
      |> Repo.all()

    {:ok, shared} = Ownership.set_owner(admin, account, %{kind: "shared"})
    for id <- members, do: {:ok, _} = Ownership.grant(admin, shared, {:user, id})
    shared
  end

  def channel!(org_id) do
    n = unique()

    {:ok, space} =
      Chat.create_space(%{name: "Mp #{n}", slug: "mp-chan-#{n}", kind: "channel", org_id: org_id})

    space
  end

  def bind_inbound_space!(account, space) do
    account |> Ecto.Changeset.change(inbound_space_id: space.id) |> Repo.update!()
  end

  def join_user!(space, user) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  def join_agent!(space, agent) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  def post!(space, participant, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    msg
  end

  def inbound!(account, attrs \\ %{}) do
    n = unique()

    Repo.insert!(
      struct(
        InboundMessage,
        Map.merge(
          %{
            account_id: account.id,
            org_id: account.org_id,
            folder: "INBOX",
            uidvalidity: 1,
            uid: n,
            message_id_key: "mp-#{n}@example.test",
            message_id_header: "<mp-#{n}@example.test>",
            raw: "raw #{n}",
            from_address: "sender-#{n}@outside.test",
            to_addresses: ["box@example.test"],
            subject: "Subject #{n}",
            text_body: "Body #{n}",
            received_at: DateTime.utc_now()
          },
          attrs
        )
      )
    )
  end

  @doc "An inbound row of `account` whose chat post is `content`, in `space`."
  def mail_post!(account, space, participant, content) do
    msg = post!(space, participant, content)
    inbound!(account, %{chat_message_id: msg.id, text_body: content})
    msg
  end
end
