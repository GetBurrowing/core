defmodule Platform.Deploy.EmailTest do
  @moduledoc """
  The `email` deploy strategy (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6
  stage 6): `Platform.Deploy.Email`, `Platform.Mail.Dispatch.enqueue/3` and
  `Platform.Mail.Outbox`.

  async: false because it flips `:mail_enabled` and the mailer adapter in
  application env. The recording adapter reports `{:mail_test_adapter,
  email, config}` to the process that delivered (and its `$callers`), so a
  test drives the Outbox with `Outbox.run_once/0` in its own process.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Audit.Event
  alias Platform.Chat
  alias Platform.Deploy
  alias Platform.Deploy.Email
  alias Platform.Mail
  alias Platform.Mail.Delivery
  alias Platform.Mail.Dispatch
  alias Platform.Mail.Draft
  alias Platform.Mail.Drafts
  alias Platform.Mail.Outbox
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, Stage, Validation}
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp user!(org_id, role \\ "member") do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "deploy-email-#{n}@example.com",
        name: "Deploy Email #{n}",
        oidc_sub: "oidc-deploy-email-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role, external: false})
    |> Repo.insert!()

    user
  end

  defp account!(admin, org_id, overrides \\ %{}) do
    name = unique("acct")

    attrs =
      Map.merge(
        %{
          "name" => name,
          "smtp_host" => "smtp.#{name}.test",
          "smtp_port" => 2525,
          "smtp_tls" => "none",
          "username" => "#{name}-relay"
        },
        overrides
      )

    {:ok, account} = Mail.create_account(admin, org_id, attrs, %{smtp: "#{name}-password"})
    account
  end

  defp sender!(admin, account, key, address, display_name) do
    {:ok, sender} =
      Mail.put_sender(admin, account, %{
        "key" => key,
        "address" => address,
        "display_name" => display_name
      })

    sender
  end

  defp set_adapter(adapter) do
    previous = Application.get_env(:platform, Platform.Mail.Mailer)
    Application.put_env(:platform, Platform.Mail.Mailer, adapter: adapter)
    on_exit(fn -> Application.put_env(:platform, Platform.Mail.Mailer, previous) end)
  end

  defp canvas!(task, text) do
    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "TestAgent",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => "Deliverable",
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{
            "id" => "root",
            "type" => "stack",
            "children" => [
              %{
                "id" => "h",
                "type" => "heading",
                "props" => %{"level" => 1, "value" => "Report"}
              },
              %{"id" => "m", "type" => "markdown", "props" => %{"content" => text}}
            ]
          }
        }
      })

    canvas
  end

  defp email_config(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        "strategy" => "email",
        "account_id" => ctx.account.id,
        "sender_key" => "reports",
        "recipients" => [ctx.member.email],
        "subject" => "Weekly report"
      },
      overrides
    )
  end

  defp email_task!(ctx, config, status \\ "in_progress") do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: ctx.project.id,
        title: "Mail the weekly report",
        status: status,
        deploy_target: "email",
        deploy_strategy: %{"type" => "email"},
        deploy_target_config: config
      })

    Tasks.ensure_project_loaded(task)
  end

  # A running deploy stage with a pending test_pass, as the plan engine
  # injects it.
  defp deploy_stage!(task) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Deploy: Email"})

    {:ok, running} = PlanEngine.start_stage(stage.id)
    {:ok, _} = Tasks.create_validation(%{stage_id: running.id, kind: "test_pass"})
    running
  end

  defp test_pass(stage_id) do
    from(v in Validation, where: v.stage_id == ^stage_id and v.kind == "test_pass")
    |> Repo.one!()
  end

  defp deliveries, do: Repo.all(from(d in Delivery, order_by: [asc: d.inserted_at]))
  defp deliveries_count, do: Repo.aggregate(Delivery, :count)

  defp dispatch_events_count do
    from(e in Event, where: e.event_type == "platform.mail.dispatch") |> Repo.aggregate(:count)
  end

  defp adapter_messages(acc \\ []) do
    receive do
      {:mail_test_adapter, email, _config} -> adapter_messages([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  setup do
    previous = Application.fetch_env(:platform, :mail_enabled)
    Application.put_env(:platform, :mail_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)

    Process.delete(:mail_test_adapter_hook)

    org_id = Tenancy.get_org_by_slug!("soylent").id
    other_org_id = Tenancy.get_org_by_slug!("sxi").id
    admin = user!(org_id, "admin")
    member = user!(org_id)
    account = account!(admin, org_id)
    sender!(admin, account, "reports", "reports@soylent.test", "Soylent Reports")
    {:ok, project} = Tasks.create_project(%{name: unique("mail-deploy"), org_id: org_id})

    %{
      org_id: org_id,
      other_org_id: other_org_id,
      admin: admin,
      member: member,
      account: account,
      project: project
    }
  end

  # ── Happy path, through the plan engine ─────────────────────────────────

  describe "plan engine → deploy → outbox" do
    test "reaches deploying, queues one delivery, and the outbox tick sends it and passes test_pass",
         ctx do
      # `in_review` + a passed implementation stage is how a task arrives at
      # deploy injection (mirrors the project_files wiring test).
      task = email_task!(ctx, email_config(ctx), "in_review")
      canvas = canvas!(task, "Revenue is up **12%**.")

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, plan_after} = PlanEngine.advance(plan.id)

      deploy_stage = Enum.find(plan_after.stages, &(&1.name == "Deploy: Email"))
      assert deploy_stage, "expected the email deploy stage to be injected"
      assert Tasks.get_task_record(task.id).status == "deploying"

      # Inside the plan engine's transaction nothing reached SMTP: the send
      # is recorded as queued and test_pass is still pending.
      assert adapter_messages() == []
      assert [%Delivery{status: "queued"} = queued] = deliveries()
      assert queued.task_id == task.id
      assert queued.stage_id == deploy_stage.id
      assert queued.responsibility == "task_deploy"
      assert queued.actor_type == "system"
      assert queued.drafted_by_type == "system"
      assert queued.from_address == "reports@soylent.test"
      assert queued.recipients == [ctx.member.email]
      assert queued.subject == "Weekly report"
      assert queued.body =~ "Revenue is up **12%**."
      assert test_pass(deploy_stage.id).status == "pending"
      assert dispatch_events_count() == 1

      assert [%{delivery_id: id, status: "accepted"}] = Outbox.run_once()
      assert id == queued.id

      assert [email] = adapter_messages()
      assert email.from == {"Soylent Reports", "reports@soylent.test"}
      assert email.to == [{"", ctx.member.email}]
      assert email.subject == "Weekly report"
      assert email.text_body =~ "Revenue is up **12%**."
      assert email.text_body =~ "# Report"

      delivery = Repo.get!(Delivery, queued.id)
      assert delivery.status == "accepted"
      assert Repo.get!(Draft, delivery.draft_id).status == "dispatched"

      v = test_pass(deploy_stage.id)
      assert v.status == "passed"
      assert v.evaluated_by == "platform.deploy.email"
      assert v.evidence["delivery_id"] == delivery.id
      assert Repo.get!(Stage, deploy_stage.id).status == "passed"

      # The canvas the body came from is the one in the execution space.
      assert canvas.id
      # A second tick has nothing left to claim.
      assert Outbox.run_once() == []
      assert adapter_messages() == []
    end
  end

  # ── Fail closed ─────────────────────────────────────────────────────────

  describe "every failure fails test_pass with a named reason and sends nothing" do
    test "an account of another org → account_wrong_org", ctx do
      other_admin = user!(ctx.other_org_id, "admin")
      foreign = account!(other_admin, ctx.other_org_id, %{"internal_only" => false})
      sender!(other_admin, foreign, "reports", "reports@sxi.test", "SXI")

      task = email_task!(ctx, email_config(ctx, %{"account_id" => foreign.id}))
      stage = deploy_stage!(task)

      assert {:error, :account_wrong_org} = Email.execute(task, stage)

      v = test_pass(stage.id)
      assert v.status == "failed"
      assert v.evidence["reason"] == "account_wrong_org"
      assert deliveries_count() == 0
      assert Outbox.run_once() == []
      assert adapter_messages() == []
    end

    test "a sender key the account does not have → sender_key_not_found", ctx do
      task = email_task!(ctx, email_config(ctx, %{"sender_key" => "billing"}))
      stage = deploy_stage!(task)

      assert {:error, :sender_key_not_found} = Email.execute(task, stage)
      assert test_pass(stage.id).evidence["reason"] == "sender_key_not_found"
      assert test_pass(stage.id).status == "failed"
      assert deliveries_count() == 0
      assert Outbox.run_once() == []
      assert adapter_messages() == []
    end

    test "an archived account → account_archived", ctx do
      {:ok, _} = Mail.archive_account(ctx.admin, ctx.account)
      task = email_task!(ctx, email_config(ctx))
      stage = deploy_stage!(task)

      assert {:error, :account_archived} = Email.execute(task, stage)
      assert test_pass(stage.id).evidence["reason"] == "account_archived"
      assert deliveries_count() == 0
    end

    test "internal-only with an external recipient → refused row kept, test_pass failed", ctx do
      task =
        email_task!(
          ctx,
          email_config(ctx, %{"recipients" => [ctx.member.email, "outsider@elsewhere.test"]})
        )

      stage = deploy_stage!(task)

      assert {:error, {:refused, {:external_recipients, ["outsider@elsewhere.test"]}}} =
               Email.execute(task, stage)

      assert [%Delivery{status: "refused"} = refused] = deliveries()
      assert refused.refusal_reason["code"] == "external_recipients"
      assert refused.stage_id == stage.id

      v = test_pass(stage.id)
      assert v.status == "failed"
      assert v.evidence["reason"] == "external_recipients"
      assert v.evidence["delivery_id"] == refused.id

      assert Outbox.run_once() == []
      assert adapter_messages() == []
    end

    test "send disabled on the account → send_disabled", ctx do
      {:ok, _} = Mail.update_account(ctx.admin, ctx.account, %{"send_enabled" => false})
      task = email_task!(ctx, email_config(ctx))
      stage = deploy_stage!(task)

      assert {:error, {:refused, :send_disabled}} = Email.execute(task, stage)
      assert test_pass(stage.id).evidence["reason"] == "send_disabled"
      assert Outbox.run_once() == []
      assert adapter_messages() == []
    end

    test "the Email module flag off → mail_disabled", ctx do
      task = email_task!(ctx, email_config(ctx))
      stage = deploy_stage!(task)
      Application.put_env(:platform, :mail_enabled, false)

      assert {:error, :mail_disabled} = Email.execute(task, stage)

      v = test_pass(stage.id)
      assert v.status == "failed"
      assert v.evidence["reason"] == "mail_disabled"
      assert deliveries_count() == 0
      assert Repo.aggregate(Draft, :count) == 0
    end

    test "a config that is not an email config → invalid_deploy_target_config", ctx do
      task = email_task!(ctx, email_config(ctx))
      stage = deploy_stage!(task)
      task = %{task | deploy_target_config: %{"strategy" => "project_files"}}

      assert {:error, :invalid_deploy_target_config} = Email.execute(task, stage)
      assert test_pass(stage.id).evidence["reason"] == "invalid_deploy_target_config"
      assert deliveries_count() == 0
    end

    test "a raising adapter → delivery failed and kept, test_pass failed", ctx do
      set_adapter(Platform.Mail.RaisingTestAdapter)
      task = email_task!(ctx, email_config(ctx))
      stage = deploy_stage!(task)

      assert {:ok, %Delivery{status: "queued"} = queued} = Email.execute(task, stage)
      assert test_pass(stage.id).status == "pending"

      assert [%{status: "failed"}] = Outbox.run_once()
      assert_received {:mail_raising_adapter, _email}

      delivery = Repo.get!(Delivery, queued.id)
      assert delivery.status == "failed"
      assert delivery.error =~ "simulated SMTP failure"
      assert Repo.get!(Draft, delivery.draft_id).status == "draft"

      v = test_pass(stage.id)
      assert v.status == "failed"
      assert v.evidence["reason"] == "smtp_failed"
      assert v.evidence["error"] =~ "simulated SMTP failure"
    end

    test "Deploy.dispatch/3 never raises, even for a task with no loadable project", ctx do
      task = email_task!(ctx, email_config(ctx))
      stage = deploy_stage!(task)
      broken = %{task | project: nil, project_id: Ecto.UUID.generate()}

      assert :ok = Deploy.dispatch(broken, %{"type" => "email"}, stage)
      assert deliveries_count() == 0
    end
  end

  # ── Transaction boundary ────────────────────────────────────────────────

  describe "the send is queued in the caller's transaction" do
    test "a rollback around the handler leaves no delivery, draft or audit event", ctx do
      task = email_task!(ctx, email_config(ctx))
      stage = deploy_stage!(task)
      events_before = dispatch_events_count()

      assert {:error, :rolled_back} =
               Repo.transaction(fn ->
                 assert {:ok, %Delivery{status: "queued"}} = Email.execute(task, stage)
                 assert deliveries_count() == 1
                 Repo.rollback(:rolled_back)
               end)

      assert deliveries_count() == 0
      assert Repo.aggregate(Draft, :count) == 0
      assert dispatch_events_count() == events_before
      assert Outbox.run_once() == []
      assert adapter_messages() == []
    end

    test "inside a transaction the handler reaches no adapter; after commit the outbox does",
         ctx do
      task = email_task!(ctx, email_config(ctx))
      stage = deploy_stage!(task)

      {:ok, {:ok, delivery}} = Repo.transaction(fn -> Email.execute(task, stage) end)

      assert adapter_messages() == []
      assert delivery.status == "queued"
      assert [%{status: "accepted"}] = Outbox.run_once()
      assert [_] = adapter_messages()
    end
  end

  # ── enqueue/3 ───────────────────────────────────────────────────────────

  describe "Dispatch.enqueue/3" do
    defp system_draft!(ctx, attrs \\ %{}) do
      {:ok, draft} =
        Drafts.create_system(
          ctx.org_id,
          Map.merge(
            %{
              account_id: ctx.account.id,
              sender_key: "reports",
              to_addresses: [ctx.member.email],
              subject: "S",
              body: "B",
              responsibility: "task_deploy"
            },
            attrs
          )
        )

      draft
    end

    test "the confirm-time version check does not refuse a fresh system draft", ctx do
      draft = system_draft!(ctx)
      assert {:ok, %Delivery{status: "queued"}} = Dispatch.enqueue(draft.id, {:system, nil})
    end

    test "a system draft edited after it was read is refused as draft_changed", ctx do
      draft = system_draft!(ctx)
      stale = DateTime.add(draft.updated_at, -1, :second)

      assert {:error, :draft_changed} =
               Dispatch.enqueue(draft.id, {:system, nil}, expected_updated_at: stale)

      assert deliveries_count() == 0
    end

    test "only the system may enqueue, and only a system draft", ctx do
      draft = system_draft!(ctx)
      assert {:error, :unauthorized} = Dispatch.enqueue(draft.id, {:user, ctx.member.id})
      assert {:error, :unauthorized} = Dispatch.enqueue(draft.id, {:agent, Ecto.UUID.generate()})

      {:ok, person_draft} =
        Drafts.create({:user, ctx.member.id}, ctx.org_id, %{
          account_id: ctx.account.id,
          sender_key: "reports",
          to_addresses: [ctx.member.email],
          subject: "S",
          body: "B"
        })

      assert {:error, :unauthorized} = Dispatch.enqueue(person_draft.id, {:system, nil})
      assert deliveries_count() == 0
    end

    test "a draft already queued is not queued twice", ctx do
      draft = system_draft!(ctx)
      assert {:ok, _} = Dispatch.enqueue(draft.id, {:system, nil})
      assert {:error, :draft_in_flight} = Dispatch.enqueue(draft.id, {:system, nil})
      assert deliveries_count() == 1
    end

    test "queued rows count toward the account's rate limit", ctx do
      {:ok, account} = Mail.update_account(ctx.admin, ctx.account, %{"rate_limit_per_hour" => 1})
      ctx = %{ctx | account: account}

      assert {:ok, _} = Dispatch.enqueue(system_draft!(ctx).id, {:system, nil})

      assert {:error, {:refused, :rate_limited, %Delivery{status: "refused"}}} =
               Dispatch.enqueue(system_draft!(ctx).id, {:system, nil})
    end
  end

  # ── Outbox claim ────────────────────────────────────────────────────────

  describe "Outbox claim" do
    setup ctx do
      task = email_task!(ctx, email_config(ctx))
      stage = deploy_stage!(task)
      {:ok, delivery} = Email.execute(task, stage)
      %{task: task, stage: stage, delivery: delivery}
    end

    test "two concurrent ticks deliver one queued row exactly once", ctx do
      parent = self()
      barrier = make_ref()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            send(parent, {:ready, barrier, self()})

            receive do
              {:go, ^barrier} -> Outbox.run_once()
            end
          end)
        end

      pids =
        for _ <- 1..2 do
          assert_receive {:ready, ^barrier, pid}
          pid
        end

      Enum.each(pids, &send(&1, {:go, barrier}))
      results = tasks |> Task.await_many(10_000) |> List.flatten()

      assert [%{status: "accepted"}] = results
      assert [_one] = adapter_messages()
      assert Repo.get!(Delivery, ctx.delivery.id).status == "accepted"
    end

    test "a tick that starts while another tick's send is in flight does not resend", _ctx do
      parent = self()

      Process.put(:mail_test_adapter_hook, fn _email ->
        # Runs at the moment SMTP is contacted for the first claim: the row
        # is `sending`, so a second tick has nothing to claim.
        send(parent, {:nested_tick, Outbox.run_once()})
      end)

      assert [%{status: "accepted"}] = Outbox.run_once()
      assert_received {:nested_tick, []}
      assert [_one] = adapter_messages()
    end

    test "a claimed row is flipped to sending in the claim itself", ctx do
      assert [id] = Outbox.claim()
      assert id == ctx.delivery.id
      assert Repo.get!(Delivery, id).status == "sending"
      assert Outbox.claim() == []
    end

    test "an already-resolved test_pass is not overwritten by the outbox", ctx do
      {:ok, _} =
        PlanEngine.evaluate_validation(test_pass(ctx.stage.id).id, %{
          status: "failed",
          evidence: %{"reason" => "operator"},
          evaluated_by: "someone"
        })

      assert [%{status: "accepted"}] = Outbox.run_once()
      v = test_pass(ctx.stage.id)
      assert v.status == "failed"
      assert v.evaluated_by == "someone"
    end
  end

  describe "startup" do
    test "the outbox is not a child when the Email module is off" do
      Application.put_env(:platform, :mail_enabled, false)
      assert Platform.Application.maybe_add_mail_outbox([:x]) == [:x]
    end

    test "the outbox is a child when the Email module is on" do
      assert Platform.Application.maybe_add_mail_outbox([:x]) == [:x, Platform.Mail.Outbox]
    end
  end
end
