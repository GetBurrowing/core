defmodule Platform.Federation.ToolSurfaceMailTest do
  @moduledoc """
  The Email module's agent tools, `mail_draft_create` and
  `mail_draft_update` (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 5):
  hidden and refused while the module flag is off, the create/update happy
  path, a tenant-pinned agent refused on a sibling org, and — the property
  the whole design rests on — no bundle exposes a way for an agent to send.

  As of task 01a0d4a0 stage 4 round 2, these tools live in their OWN `mail`
  bundle, not folded into `messaging` — a runtime granted `messaging` alone
  (e.g. the single-purpose Burrow voice persona) no longer gets
  mail-drafting for free. See `ToolSurface.messaging_tools/0`'s moduledoc
  comment and the `20260924180000_agent_runtime_mail_bundle.exs` migration
  that backfilled existing runtimes.

  async: false — flips `:mail_enabled` in application env.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation.ToolSurface
  alias Platform.Mail
  alias Platform.Mail.Delivery
  alias Platform.Mail.Draft
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @draft_tools ~w(mail_draft_create mail_draft_update)

  defp user!(label) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "#{label}-#{n}@example.com",
      name: "#{label} #{n}",
      oidc_sub: "oidc-mail-tool-#{label}-#{n}"
    })
    |> Repo.insert!()
  end

  defp member!(user, org_id, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role, external: false})
    |> Repo.insert!()

    user
  end

  defp agent!(label, metadata) do
    %Agent{}
    |> Agent.changeset(%{
      slug: "#{label}-#{System.unique_integer([:positive, :monotonic])}",
      name: "Agent #{label}",
      status: "active",
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp set_flag(value), do: Application.put_env(:platform, :mail_enabled, value)

  setup do
    previous = Application.fetch_env(:platform, :mail_enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)

    set_flag(true)

    org_id = Tenancy.get_org_by_slug!("soylent").id
    other_org_id = Tenancy.get_org_by_slug!("sxi").id

    admin = user!("admin") |> member!(org_id, "admin")
    member = user!("member") |> member!(org_id, "member")
    other_admin = user!("other-admin") |> member!(other_org_id, "admin")

    {:ok, account} =
      Mail.create_account(admin, org_id, %{"name" => "ops", "smtp_host" => "smtp.ops.test"}, %{
        smtp: "pw"
      })

    {:ok, _} =
      Mail.put_sender(admin, account, %{"key" => "ops", "address" => "ops@soylent.test"})

    {:ok, project} =
      Tasks.create_project(%{name: "Mail tool #{System.unique_integer()}", org_id: org_id})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Weekly digest"})

    %{
      org_id: org_id,
      other_org_id: other_org_id,
      admin: admin,
      member: member,
      other_admin: other_admin,
      account: account,
      task: task,
      agent: agent!("pinned", %{"org_id" => org_id}),
      other_agent: agent!("other", %{"org_id" => org_id}),
      sibling_agent: agent!("sibling", %{"org_id" => other_org_id})
    }
  end

  defp ctx_for(agent), do: %{agent_id: agent.id}

  defp create_args(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        "org_id" => ctx.org_id,
        "account_id" => ctx.account.id,
        "sender_key" => "ops",
        "to_addresses" => [ctx.member.email],
        "subject" => "Weekly digest",
        "body" => "Hi team,\n\nThis week: 4 tasks shipped."
      },
      overrides
    )
  end

  defp draft_count, do: Repo.aggregate(Draft, :count)

  describe "the module flag" do
    test "off: the tools are not listed in mail or anywhere, and execute refuses recoverably",
         ctx do
      set_flag(false)

      names = ToolSurface.tool_definitions() |> Enum.map(& &1.name)
      for tool <- @draft_tools, do: refute(tool in names)
      refute Enum.any?(ToolSurface.list_tools(["mail"]), &(&1.name in @draft_tools))

      before = draft_count()

      for tool <- @draft_tools do
        args =
          if tool == "mail_draft_create",
            do: create_args(ctx),
            else: %{"draft_id" => Ecto.UUID.generate()}

        assert {:error, envelope} = ToolSurface.execute(tool, args, ctx_for(ctx.agent))
        assert envelope.code == :mail_disabled
        assert envelope.recoverable == true
        assert envelope.error =~ "email module is not enabled"
      end

      assert draft_count() == before
    end

    test "positive control: on, both tools are listed in the mail bundle and only there" do
      mail = ToolSurface.list_tools(["mail"])

      for tool <- @draft_tools do
        assert %{bundle: "mail"} = Enum.find(mail, &(&1.name == tool))
      end

      others = ToolSurface.list_tools(ToolSurface.all_bundles() -- ["mail"])
      refute Enum.any?(others, &(&1.name in @draft_tools))
    end

    test "messaging alone does not grant mail drafting" do
      messaging = ToolSurface.list_tools(["messaging"])
      refute Enum.any?(messaging, &(&1.name in @draft_tools))
    end
  end

  describe "mail_draft_create" do
    test "writes a draft as the calling agent, body verbatim", ctx do
      body = "  <b>not html</b>\n**not markdown**\n@[Someone] trailing  "

      assert {:ok, result} =
               ToolSurface.execute(
                 "mail_draft_create",
                 create_args(ctx, %{"body" => body, "task_id" => ctx.task.id}),
                 ctx_for(ctx.agent)
               )

      assert result.status == "draft"
      assert result.review_path == "/email/drafts/#{result.draft_id}?org=#{ctx.org_id}"

      draft = Repo.get!(Draft, result.draft_id)
      assert draft.body == body
      assert draft.created_by_type == "agent"
      assert draft.created_by_id == ctx.agent.id
      assert draft.org_id == ctx.org_id
      assert draft.account_id == ctx.account.id
      assert draft.sender_key == "ops"
      assert draft.task_id == ctx.task.id
      assert draft.status == "draft"

      # Nothing was sent or recorded as a send.
      assert Repo.aggregate(from(d in Delivery, where: d.draft_id == ^draft.id), :count) == 0
      refute_received {:mail_test_adapter, _, _}
    end

    test "names every bad reference and writes nothing", ctx do
      before = draft_count()

      for {overrides, code} <- [
            {%{"account_id" => Ecto.UUID.generate()}, :account_not_found},
            {%{"sender_key" => "nobody"}, :sender_key_not_found},
            {%{"to_addresses" => ["not an address"]}, :invalid},
            {%{"to_user_ids" => [Ecto.UUID.generate()]}, :invalid},
            {%{"on_behalf_of_user_id" => ctx.other_admin.id}, :invalid},
            {%{"task_id" => Ecto.UUID.generate()}, :task_not_found}
          ] do
        assert {:error, envelope} =
                 ToolSurface.execute(
                   "mail_draft_create",
                   create_args(ctx, overrides),
                   ctx_for(ctx.agent)
                 ),
               "expected #{inspect(overrides)} to be refused"

        assert envelope.code == code
      end

      assert draft_count() == before
    end

    test "a tenant-pinned agent cannot draft into a sibling org", ctx do
      before = draft_count()

      assert {:error, envelope} =
               ToolSurface.execute(
                 "mail_draft_create",
                 create_args(ctx),
                 ctx_for(ctx.sibling_agent)
               )

      assert envelope.error =~ "unauthorized"
      assert envelope.recoverable == false
      assert draft_count() == before
    end

    test "an anonymous caller is refused", ctx do
      assert {:error, envelope} = ToolSurface.execute("mail_draft_create", create_args(ctx), %{})
      assert envelope.code == :unauthorized
    end
  end

  describe "mail_draft_update" do
    setup ctx do
      {:ok, result} =
        ToolSurface.execute("mail_draft_create", create_args(ctx), ctx_for(ctx.agent))

      %{draft_id: result.draft_id}
    end

    test "revises only the fields passed, verbatim", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "mail_draft_update",
                 %{"draft_id" => ctx.draft_id, "body" => "Revised\n  body"},
                 ctx_for(ctx.agent)
               )

      assert result.draft_id == ctx.draft_id
      draft = Repo.get!(Draft, ctx.draft_id)
      assert draft.body == "Revised\n  body"
      assert draft.subject == "Weekly digest"
      assert draft.to_addresses == [ctx.member.email]
    end

    test "another agent, a sibling-org agent and a person's draft are all refused", ctx do
      assert {:error, %{code: :unauthorized}} =
               ToolSurface.execute(
                 "mail_draft_update",
                 %{"draft_id" => ctx.draft_id, "body" => "hijack"},
                 ctx_for(ctx.other_agent)
               )

      assert {:error, envelope} =
               ToolSurface.execute(
                 "mail_draft_update",
                 %{"draft_id" => ctx.draft_id, "body" => "hijack"},
                 ctx_for(ctx.sibling_agent)
               )

      assert envelope.error =~ "unauthorized"

      {:ok, person_draft} =
        Mail.Drafts.create(ctx.member, ctx.org_id, %{subject: "mine", body: "mine"})

      assert {:error, %{code: :unauthorized}} =
               ToolSurface.execute(
                 "mail_draft_update",
                 %{"draft_id" => person_draft.id, "body" => "hijack"},
                 ctx_for(ctx.agent)
               )

      assert Repo.get!(Draft, ctx.draft_id).body =~ "This week"
      assert Repo.get!(Draft, person_draft.id).body == "mine"
    end

    test "a draft that is no longer a draft is not editable", ctx do
      {:ok, _} = Mail.Drafts.discard(ctx.member, ctx.draft_id)

      assert {:error, %{code: :draft_not_editable}} =
               ToolSurface.execute(
                 "mail_draft_update",
                 %{"draft_id" => ctx.draft_id, "body" => "late"},
                 ctx_for(ctx.agent)
               )
    end

    test "a malformed draft id is a not-found, not a crash", ctx do
      assert {:error, %{code: :not_found}} =
               ToolSurface.execute(
                 "mail_draft_update",
                 %{"draft_id" => "not-a-uuid", "body" => "x"},
                 ctx_for(ctx.agent)
               )
    end
  end

  describe "no agent send path" do
    test "with the module on, no tool in any bundle is a mail send tool" do
      names = ToolSurface.list_tools(ToolSurface.all_bundles()) |> Enum.map(& &1.name)

      mail_tools = Enum.filter(names, &(&1 =~ ~r/mail/i))
      assert Enum.sort(mail_tools) == Enum.sort(@draft_tools)

      refute Enum.any?(names, &(&1 =~ ~r/(mail|email).*(send|dispatch|deliver)/i)),
             "an agent-facing mail send tool exists: #{inspect(names)}"

      refute Enum.any?(names, &(&1 =~ ~r/(send|dispatch|deliver).*(mail|draft)/i)),
             "an agent-facing mail send tool exists: #{inspect(names)}"
    end

    test "the tool surface source never reaches the send path" do
      read = fn rel ->
        Path.expand("../../../lib/platform/federation/#{rel}", __DIR__) |> File.read!()
      end

      surface = read.("tool_surface.ex")
      definitions = read.("mail_draft_tools.ex")

      # Positive controls: the reads prove they opened the right files.
      assert surface =~ ~s(def execute("mail_draft_create")
      assert definitions =~ ~s(name: "mail_draft_create")

      for source <- [surface, definitions] do
        refute source =~ "Mail.Dispatch"
        refute source =~ "Mail.Deliverer"
        refute source =~ "Mail.Mailer"
      end
    end
  end
end
