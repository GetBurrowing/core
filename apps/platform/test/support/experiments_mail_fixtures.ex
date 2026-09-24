defmodule Platform.Test.ExperimentsMailFixtures do
  @moduledoc """
  Fixtures shared by the mail-signal tests (task 01a0d415 stage 3):
  a mail account, an ingested inbound row, a running mail-signal
  experiment, a task subject and its assignment, and a scientist agent.
  Ingest goes through `Platform.Mail.Inbound.ingest/5`, the real write path.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Mail
  alias Platform.Mail.Inbound
  alias Platform.Mail.InboundMessage
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  @address "jobs@acme.test"

  def address, do: @address

  def unique, do: System.unique_integer([:positive])

  def admin!(org_id) do
    n = unique()

    user =
      %User{}
      |> User.changeset(%{
        email: "exp-mail-#{n}@example.com",
        name: "Exp Mail #{n}",
        oidc_sub: "oidc-exp-mail-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "admin"})
    |> Repo.insert!()

    user
  end

  def account!(org_id) do
    n = unique()

    {:ok, space} =
      Chat.create_space(%{name: "ExpMail #{n}", slug: "exp-mail-#{n}", kind: "channel"})

    {:ok, account} =
      Mail.create_account(
        admin!(org_id),
        org_id,
        %{
          "name" => "jobs-#{n}",
          "smtp_tls" => "starttls",
          "username" => @address,
          "imap_host" => "imap-#{n}.acme.test",
          "imap_port" => 993,
          "imap_tls" => "tls",
          "read_enabled" => true,
          "inbound_space_id" => space.id
        },
        %{imap: "imap-pass"}
      )

    account
  end

  def raw(opts) do
    headers =
      [
        {"From", Keyword.get(opts, :from, "Recruiter <recruiter@corp.test>")},
        {"To", Keyword.get(opts, :to, @address)},
        {"Subject", Keyword.get(opts, :subject, "Re: your application")},
        {"Date", "Tue, 22 Sep 2026 10:00:00 +0000"},
        {"Message-ID", Keyword.get(opts, :message_id, "<m-#{unique()}@corp.test>")}
      ]
      |> Enum.map_join("\r\n", fn {k, v} -> "#{k}: #{v}" end)

    headers <> "\r\n\r\n" <> Keyword.get(opts, :body, "Thanks, we received it.") <> "\r\n"
  end

  @doc "Ingest one message through the real path; returns `{count, row | nil}`."
  def ingest!(account, opts \\ []) do
    raw = raw(opts)
    count = Inbound.ingest(account, "INBOX", 1, unique(), raw)
    key = Inbound.message_id_key(Inbound.parse(raw).message_id, raw)

    row =
      Repo.one(
        from(m in InboundMessage, where: m.account_id == ^account.id and m.message_id_key == ^key)
      )

    {count, row}
  end

  @doc "A RUNNING experiment reading mail sent to `address/0`."
  def mail_experiment!(attrs \\ %{}) do
    {:ok, experiment} =
      Experiments.create_experiment(
        Map.merge(
          %{
            slug: "mail-exp-#{unique()}",
            name: "Mail experiment",
            signal_source: %{
              "kind" => "mail_inbound",
              "to_address" => @address,
              "labels" => ~w(auto_ack rejection screen interview other)
            }
          },
          attrs
        )
      )

    {:ok, _} = Experiments.add_variant(experiment, %{slug: "control", content: "c", weight: 1})

    experiment
    |> Ecto.Changeset.change(status: "running")
    |> Repo.update!()
  end

  def task!(title) do
    {:ok, project} = Tasks.create_project(%{name: "ExpMail #{unique()}"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: title})
    task
  end

  def assign!(%Experiment{} = experiment, subject_id, variant_slug) do
    Repo.insert!(%Assignment{
      experiment_id: experiment.id,
      subject_type: "task",
      subject_id: subject_id,
      variant_slug: variant_slug,
      assigned_at: DateTime.utc_now()
    })
  end

  @doc "An external agent pinned to the `scientist` role."
  def scientist!(opts \\ []) do
    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "scientist-#{unique()}",
        name: "Scientist",
        status: "active",
        kind: "external",
        runtime_type: "external",
        endpoint_kind: "openai_compat",
        base_url: "http://stub.example.local/v1",
        model: "stub-model"
      })
      |> Repo.insert!()

    if Keyword.get(opts, :assign, true) do
      Roles.unassign_role("scientist")
      {:ok, _} = Roles.assign_role("scientist", agent.id)
    end

    agent
  end
end
