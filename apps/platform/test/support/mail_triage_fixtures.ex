defmodule Platform.Test.MailTriageFixtures do
  @moduledoc """
  Fixtures for `Platform.Mail.Triage` (task 01a1f426 stage 1): the triage
  agent (pinned to `mail.triage` by a responsibility override), agent
  grants, accepted deliveries and closed-shape replies. Mailboxes, users
  and inbound rows come from `Platform.Test.MailPrivacyFixtures`, through
  the real ownership write paths. Bodies carry marker tokens only.
  """

  alias Platform.Mail.{Delivery, Ownership}
  alias Platform.Repo
  alias Platform.Roles

  @doc "Turn the Email module on for the test, restoring the env on exit."
  def enable_mail! do
    previous = Application.fetch_env(:platform, :mail_enabled)
    Application.put_env(:platform, :mail_enabled, true)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)

    :ok
  end

  @doc "An agent pinned to `mail.triage`."
  def triage_agent! do
    agent = Platform.Test.MailPrivacyFixtures.agent!("triage")
    {:ok, _} = Roles.set_override("mail.triage", agent.id)
    agent
  end

  @doc "Grant `agent` the mailbox; `actor` must manage it (owner or admin)."
  def grant_agent!(actor, account, agent) do
    {:ok, _} = Ownership.grant(actor, account, {:agent, agent.id})
    account
  end

  @doc "An accepted delivery from `account` to `to`, accepted at `at`."
  def delivery!(account, to, at \\ DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)) do
    Repo.insert!(%Delivery{
      id: Platform.Types.UUIDv7.generate(),
      org_id: account.org_id,
      account_id: account.id,
      sender_key: "ops",
      from_address: "ops@example.test",
      recipients: [to],
      actor_type: "system",
      message_id_header: "<d-#{System.unique_integer([:positive])}@example.test>",
      status: "accepted",
      accepted_at: at,
      inserted_at: at
    })
  end

  @doc "A closed-shape classifier reply."
  def verdict(overrides \\ %{}) do
    Map.merge(
      %{
        "tier" => "action",
        "needs" => "reply",
        "why" => "They asked a question only you can answer.",
        "next_step" => "Reply with the answer."
      },
      overrides
    )
  end

  @doc "A raw message whose header block carries `headers` (a list of lines)."
  def raw(headers, body \\ "Body") do
    Enum.join(headers ++ ["From: someone@outside.test", "Subject: Hi", "", body], "\r\n")
  end
end
