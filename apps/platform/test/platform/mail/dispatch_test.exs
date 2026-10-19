defmodule Platform.Mail.DispatchTest do
  @moduledoc """
  The audited send path, `Platform.Mail.Dispatch` (task 01a0cf21 stage 2).

  async: false because it flips `:mail_enabled` and the mailer adapter in
  application env. Mail never leaves the process: the adapters are
  `Platform.Mail.TestAdapter` (records `{email, config}`) and
  `Platform.Mail.RaisingTestAdapter`.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Audit
  alias Platform.Mail
  alias Platform.Mail.Delivery
  alias Platform.Mail.Dispatch
  alias Platform.Mail.Draft
  alias Platform.Mail.Internal
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp user!(opts \\ []) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: Keyword.get(opts, :email, "mail-dispatch-#{n}@example.com"),
        name: "Mail #{n}",
        oidc_sub: "oidc-mail-dispatch-#{n}"
      })
      |> Repo.insert!()

    case Keyword.get(opts, :archived_at) do
      nil -> user
      at -> user |> Ecto.Changeset.change(archived_at: at) |> Repo.update!()
    end
  end

  defp member!(user, org_id, role \\ "member", external \\ false) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: role,
      external: external
    })
    |> Repo.insert!()

    user
  end

  defp account!(admin, org_id, name, overrides \\ %{}) do
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

  defp sender!(admin, account, key, address, display_name \\ nil) do
    {:ok, sender} =
      Mail.put_sender(admin, account, %{
        "key" => key,
        "address" => address,
        "display_name" => display_name
      })

    sender
  end

  defp draft!(org_id, account, key, to, attrs \\ %{}) do
    %Draft{}
    |> Draft.changeset(
      Map.merge(
        %{
          org_id: org_id,
          account_id: account && account.id,
          sender_key: key,
          to_addresses: to,
          subject: "Hello",
          body: "The body.",
          created_by_type: "agent",
          created_by_id: Ecto.UUID.generate()
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp fresh(%Delivery{id: id}), do: Repo.get!(Delivery, id)

  defp deliveries_count, do: Repo.aggregate(Delivery, :count)

  defp set_adapter(adapter) do
    previous = Application.get_env(:platform, Platform.Mail.Mailer)
    Application.put_env(:platform, Platform.Mail.Mailer, adapter: adapter)
    on_exit(fn -> Application.put_env(:platform, Platform.Mail.Mailer, previous) end)
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

    org_id = Tenancy.get_org_by_slug!("initech").id
    other_org_id = Tenancy.get_org_by_slug!("globex").id
    admin = user!() |> member!(org_id, "admin")
    member = user!() |> member!(org_id)
    actor = {:user, member.id}

    %{org_id: org_id, other_org_id: other_org_id, admin: admin, member: member, actor: actor}
  end

  # ── Exact account + sender ──────────────────────────────────────────────

  describe "the draft's account and sender key are used exactly" do
    test "a draft naming B goes out From B via B's relay and username", ctx do
      # A is created FIRST, so "the org's first account" would be A.
      a = account!(ctx.admin, ctx.org_id, "alpha", %{"internal_only" => false})
      sender!(ctx.admin, a, "ops", "ops-a@example.test", "Ops A")
      b = account!(ctx.admin, ctx.org_id, "bravo", %{"internal_only" => false})
      sender!(ctx.admin, b, "ops", "ops-b@example.test", "Ops B")

      draft = draft!(ctx.org_id, b, "ops", [ctx.member.email])

      assert {:ok, delivery} = Dispatch.dispatch(draft.id, ctx.actor)

      assert_received {:mail_test_adapter, email, config}
      assert email.from == {"Ops B", "ops-b@example.test"}
      assert email.to == [{"", ctx.member.email}]
      assert email.headers["Message-ID"] == "<#{delivery.id}@example.test>"
      assert config[:relay] == "smtp.bravo.test"
      assert config[:port] == 2525
      assert config[:username] == "bravo-relay"
      assert config[:password] == "bravo-password"
      refute_received {:mail_test_adapter, _, _}

      delivery = fresh(delivery)
      assert delivery.account_id == b.id
      assert delivery.sender_key == "ops"
      assert delivery.from_address == "ops-b@example.test"
      assert delivery.status == "accepted"
      assert delivery.smtp_response =~ "250"
      assert %DateTime{} = delivery.accepted_at
      assert delivery.actor_type == "user"
      assert delivery.actor_id == ctx.member.id
      assert delivery.drafted_by_type == "agent"
      assert delivery.drafted_by_id == draft.created_by_id
      assert delivery.draft_id == draft.id
    end

    test "a key present only on A is refused for B, and nothing is recorded", ctx do
      a = account!(ctx.admin, ctx.org_id, "alpha", %{"internal_only" => false})
      sender!(ctx.admin, a, "billing", "billing@example.test")
      b = account!(ctx.admin, ctx.org_id, "bravo", %{"internal_only" => false})
      sender!(ctx.admin, b, "ops", "ops-b@example.test")

      draft = draft!(ctx.org_id, b, "billing", [ctx.member.email])

      assert {:error, :sender_key_not_found} = Dispatch.dispatch(draft.id, ctx.actor)
      refute_received {:mail_test_adapter, _, _}
      assert deliveries_count() == 0
    end

    test "an account of another org is refused", ctx do
      other_admin = user!() |> member!(ctx.other_org_id, "admin")
      foreign = account!(other_admin, ctx.other_org_id, "foreign", %{"internal_only" => false})
      sender!(other_admin, foreign, "ops", "ops@foreign.test")

      draft = draft!(ctx.org_id, foreign, "ops", [ctx.member.email])

      assert {:error, :account_wrong_org} = Dispatch.dispatch(draft.id, ctx.actor)
      refute_received {:mail_test_adapter, _, _}
      assert deliveries_count() == 0
    end

    test "a draft with no account chosen is refused, never defaulted", ctx do
      a = account!(ctx.admin, ctx.org_id, "alpha", %{"internal_only" => false})
      sender!(ctx.admin, a, "ops", "ops-a@example.test")

      draft = draft!(ctx.org_id, nil, "ops", [ctx.member.email])

      assert {:error, :account_not_found} = Dispatch.dispatch(draft.id, ctx.actor)
      assert deliveries_count() == 0
    end
  end

  # ── Internal-only ───────────────────────────────────────────────────────

  describe "internal-only" do
    setup ctx do
      account = account!(ctx.admin, ctx.org_id, "internal")
      assert account.internal_only
      sender!(ctx.admin, account, "agents", "agents@example.test")
      %{account: account}
    end

    test "an external recipient is refused and recorded; nothing reaches SMTP", ctx do
      draft = draft!(ctx.org_id, ctx.account, "agents", [ctx.member.email, "out@elsewhere.test"])

      assert {:error, {:refused, {:external_recipients, ["out@elsewhere.test"]}, delivery}} =
               Dispatch.dispatch(draft.id, ctx.actor)

      refute_received {:mail_test_adapter, _, _}

      delivery = fresh(delivery)
      assert delivery.status == "refused"

      assert delivery.refusal_reason == %{
               "code" => "external_recipients",
               "addresses" => ["out@elsewhere.test"]
             }

      assert delivery.recipients == [ctx.member.email, "out@elsewhere.test"]
      assert Repo.get!(Draft, draft.id).status == "draft"
    end

    test "POSITIVE CONTROL: a non-external member is accepted, case-insensitively", ctx do
      draft = draft!(ctx.org_id, ctx.account, "agents", [String.upcase(ctx.member.email)])

      assert {:ok, delivery} = Dispatch.dispatch(draft.id, ctx.actor)
      assert_received {:mail_test_adapter, _email, _config}
      assert fresh(delivery).status == "accepted"
    end

    test "a user id recipient is expanded to the member's email", ctx do
      draft = draft!(ctx.org_id, ctx.account, "agents", [], %{to_user_ids: [ctx.admin.id]})

      assert {:ok, delivery} = Dispatch.dispatch(draft.id, ctx.actor)
      assert fresh(delivery).recipients == [ctx.admin.email]
    end

    test "an external: true member counts as external", ctx do
      guest = user!() |> member!(ctx.org_id, "member", true)
      draft = draft!(ctx.org_id, ctx.account, "agents", [guest.email])

      assert {:error, {:refused, {:external_recipients, [addr]}, _}} =
               Dispatch.dispatch(draft.id, ctx.actor)

      assert addr == guest.email
      refute_received {:mail_test_adapter, _, _}
    end

    test "a non-member on the members' domain counts as external", ctx do
      [_, domain] = String.split(ctx.member.email, "@")
      stranger = "nobody-#{System.unique_integer([:positive])}@#{domain}"
      draft = draft!(ctx.org_id, ctx.account, "agents", [stranger])

      assert {:error, {:refused, {:external_recipients, [^stranger]}, _}} =
               Dispatch.dispatch(draft.id, ctx.actor)

      refute_received {:mail_test_adapter, _, _}
    end

    test "a member of ANOTHER org counts as external", ctx do
      outsider = user!() |> member!(ctx.other_org_id)
      draft = draft!(ctx.org_id, ctx.account, "agents", [outsider.email])

      assert {:error, {:refused, {:external_recipients, _}, _}} =
               Dispatch.dispatch(draft.id, ctx.actor)
    end

    test "an archived member counts as external", ctx do
      gone = user!(archived_at: DateTime.utc_now()) |> member!(ctx.org_id)
      assert Internal.external(ctx.org_id, [gone.email]) == [gone.email]
    end

    test "internal_only off sends to anyone", ctx do
      {:ok, open} = Mail.update_account(ctx.admin, ctx.account, %{"internal_only" => false})
      draft = draft!(ctx.org_id, open, "agents", ["out@elsewhere.test"])

      assert {:ok, _} = Dispatch.dispatch(draft.id, ctx.actor)
      assert_received {:mail_test_adapter, _, _}
    end
  end

  # ── The audit row is committed before SMTP ──────────────────────────────

  describe "audit before send" do
    setup ctx do
      account = account!(ctx.admin, ctx.org_id, "audited", %{"internal_only" => false})
      sender!(ctx.admin, account, "ops", "ops@example.test")
      %{account: account}
    end

    test "the row exists as `sending` at the moment SMTP is contacted", ctx do
      draft = draft!(ctx.org_id, ctx.account, "ops", [ctx.member.email])
      test_pid = self()

      Process.put(:mail_test_adapter_hook, fn _email ->
        rows =
          from(d in Delivery, where: d.draft_id == ^draft.id, select: d.status)
          |> Repo.all()

        send(test_pid, {:rows_at_smtp, rows})
      end)

      assert {:ok, _} = Dispatch.dispatch(draft.id, ctx.actor)

      # Bind the FIRST message, then refute any other: a pattern-matched
      # `assert_received {:rows_at_smtp, ["sending"]}` scans the whole mailbox
      # and passed vacuously under the row-after-deliver mutant, whose extra
      # early SMTP contact saw `[]` and whose later one saw `["sending"]`.
      assert_received {:rows_at_smtp, rows}
      assert rows == ["sending"]
      refute_received {:rows_at_smtp, _}
    end

    test "a raising adapter leaves a committed `failed` row with the error", ctx do
      set_adapter(Platform.Mail.RaisingTestAdapter)
      draft = draft!(ctx.org_id, ctx.account, "ops", [ctx.member.email])

      assert {:error, {:failed, error, delivery}} = Dispatch.dispatch(draft.id, ctx.actor)
      assert_received {:mail_raising_adapter, _email}
      assert error =~ "simulated SMTP failure"

      [row] = from(d in Delivery, where: d.id == ^delivery.id) |> Repo.all()
      assert row.status == "failed"
      assert row.error =~ "simulated SMTP failure"
      assert row.body == "The body."
      assert row.recipients == [ctx.member.email]
      assert is_nil(row.accepted_at)
      assert Repo.get!(Draft, draft.id).status == "draft"
    end

    test "an audit event references the delivery and carries no body", ctx do
      draft = draft!(ctx.org_id, ctx.account, "ops", [ctx.member.email])
      assert {:ok, delivery} = Dispatch.dispatch(draft.id, ctx.actor)

      assert [event] = Audit.list(resource_type: "mail_delivery", resource_id: delivery.id)
      assert event.event_type == "platform.mail.dispatch"
      assert event.action == "sending"
      assert event.actor_type == "user"
      assert event.actor_id == ctx.member.id
      assert event.metadata["delivery_id"] == delivery.id
      assert event.metadata["recipient_count"] == 1
      refute inspect(event.metadata) =~ "The body."
    end

    test "a refusal records its own audit event", ctx do
      {:ok, off} = Mail.update_account(ctx.admin, ctx.account, %{"send_enabled" => false})
      draft = draft!(ctx.org_id, off, "ops", [ctx.member.email])

      assert {:error, {:refused, :send_disabled, delivery}} =
               Dispatch.dispatch(draft.id, ctx.actor)

      assert [event] = Audit.list(resource_type: "mail_delivery", resource_id: delivery.id)
      assert event.action == "refused"
      assert event.metadata["refusal_reason"] == %{"code" => "send_disabled"}
      refute_received {:mail_test_adapter, _, _}
    end

    test "the draft becomes dispatched only on accepted, and cannot be sent twice", ctx do
      draft = draft!(ctx.org_id, ctx.account, "ops", [ctx.member.email])
      assert {:ok, _} = Dispatch.dispatch(draft.id, ctx.actor)
      assert Repo.get!(Draft, draft.id).status == "dispatched"

      assert {:error, :draft_not_sendable} = Dispatch.dispatch(draft.id, ctx.actor)
      assert deliveries_count() == 1
    end

    test "Deliverer refuses a refused row and a row that does not exist", ctx do
      {:ok, off} = Mail.update_account(ctx.admin, ctx.account, %{"send_enabled" => false})
      draft = draft!(ctx.org_id, off, "ops", [ctx.member.email])
      {:error, {:refused, _, delivery}} = Dispatch.dispatch(draft.id, ctx.actor)

      assert {:error, {:not_sendable, "refused"}} = Platform.Mail.Deliverer.deliver(delivery.id)
      assert {:error, :not_found} = Platform.Mail.Deliverer.deliver(Ecto.UUID.generate())
      refute_received {:mail_test_adapter, _, _}
    end

    test "dispatch refuses to run inside a caller's transaction", ctx do
      draft = draft!(ctx.org_id, ctx.account, "ops", [ctx.member.email])

      assert {:ok, {:error, :in_transaction}} =
               Repo.transaction(fn -> Dispatch.dispatch(draft.id, ctx.actor) end)

      assert deliveries_count() == 0
    end
  end

  # ── Rate limit ──────────────────────────────────────────────────────────

  describe "rate limit" do
    setup ctx do
      account =
        account!(ctx.admin, ctx.org_id, "limited", %{
          "internal_only" => false,
          "rate_limit_per_hour" => 2
        })

      sender!(ctx.admin, account, "ops", "ops@example.test")
      %{account: account}
    end

    test "limit 2: the third send is refused :rate_limited", ctx do
      for _ <- 1..2 do
        draft = draft!(ctx.org_id, ctx.account, "ops", [ctx.member.email])
        assert {:ok, _} = Dispatch.dispatch(draft.id, ctx.actor)
      end

      third = draft!(ctx.org_id, ctx.account, "ops", [ctx.member.email])

      assert {:error, {:refused, :rate_limited, delivery}} =
               Dispatch.dispatch(third.id, ctx.actor)

      assert_received {:mail_test_adapter, _, _}
      assert_received {:mail_test_adapter, _, _}
      refute_received {:mail_test_adapter, _, _}

      assert fresh(delivery).refusal_reason == %{"code" => "rate_limited"}
      assert Dispatch.rate_usage(ctx.account) == {2, 2}
    end

    test "refused, failed and older-than-an-hour rows do not count", ctx do
      old = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)

      for {status, at} <- [{"accepted", old}, {"failed", nil}, {"refused", nil}] do
        Repo.insert!(%Delivery{
          id: Platform.Types.UUIDv7.generate(),
          org_id: ctx.org_id,
          account_id: ctx.account.id,
          sender_key: "ops",
          from_address: "ops@example.test",
          recipients: [ctx.member.email],
          actor_type: "system",
          message_id_header: "<x@example.test>",
          status: status,
          inserted_at: at
        })
      end

      assert Dispatch.rate_usage(ctx.account) == {0, 2}
    end
  end

  # ── Flag and actors ─────────────────────────────────────────────────────

  describe "gate and actor" do
    setup ctx do
      account = account!(ctx.admin, ctx.org_id, "gated", %{"internal_only" => false})
      sender!(ctx.admin, account, "ops", "ops@example.test")
      %{account: account, draft: draft!(ctx.org_id, account, "ops", [ctx.member.email])}
    end

    test "flag off: :mail_disabled, zero rows, zero adapter calls", ctx do
      Application.put_env(:platform, :mail_enabled, false)

      assert {:error, :mail_disabled} = Dispatch.dispatch(ctx.draft.id, ctx.actor)
      assert deliveries_count() == 0
      refute_received {:mail_test_adapter, _, _}
    end

    test "an agent cannot send; it may only draft", ctx do
      assert {:error, :unauthorized} =
               Dispatch.dispatch(ctx.draft.id, {:agent, Ecto.UUID.generate()})

      assert deliveries_count() == 0
    end

    test "an external member cannot send", ctx do
      guest = user!() |> member!(ctx.org_id, "member", true)
      assert {:error, :unauthorized} = Dispatch.dispatch(ctx.draft.id, {:user, guest.id})
      assert deliveries_count() == 0
    end

    test "the system may send (the deploy strategy path)", ctx do
      assert {:ok, delivery} = Dispatch.dispatch(ctx.draft.id, :system)
      assert fresh(delivery).actor_type == "system"
    end
  end

  # ── Snapshot immutability ───────────────────────────────────────────────

  describe "snapshot immutability" do
    setup ctx do
      account = account!(ctx.admin, ctx.org_id, "snap", %{"internal_only" => false})
      sender!(ctx.admin, account, "ops", "ops@example.test")
      draft = draft!(ctx.org_id, account, "ops", [ctx.member.email])
      {:ok, delivery} = Dispatch.dispatch(draft.id, ctx.actor)
      %{delivery: fresh(delivery), draft: draft}
    end

    test "status_changeset casts only the mutable fields", %{delivery: delivery} do
      changeset =
        Delivery.status_changeset(delivery, %{
          status: "failed",
          error: "boom",
          subject: "rewritten",
          body: "rewritten",
          recipients: ["someone@else.test"],
          from_address: "evil@example.test",
          actor_id: Ecto.UUID.generate()
        })

      assert Map.keys(changeset.changes) |> Enum.sort() == [:error, :status]

      {:ok, _} = Repo.update(changeset)
      row = fresh(delivery)
      assert row.subject == "Hello"
      assert row.body == "The body."
      assert row.from_address == "ops@example.test"
    end

    test "the database refuses an update to a snapshot column", %{delivery: delivery} do
      assert_raise Postgrex.Error, ~r/snapshot columns are immutable/, fn ->
        Repo.transaction(fn ->
          from(d in Delivery, where: d.id == ^delivery.id)
          |> Repo.update_all(set: [subject: "rewritten"])
        end)
      end

      assert fresh(delivery).subject == "Hello"
    end

    test "the database allows status/error/smtp_response updates", %{delivery: delivery} do
      assert {1, _} =
               from(d in Delivery, where: d.id == ^delivery.id)
               |> Repo.update_all(set: [error: "note", smtp_response: "250 again"])
    end

    test "editing the draft afterwards does not change the delivery", ctx do
      ctx.draft |> Ecto.Changeset.change(body: "edited later") |> Repo.update!()
      assert fresh(ctx.delivery).body == "The body."
    end
  end
end
