defmodule Platform.Mail.MailboxPrivacyTest do
  @moduledoc """
  The mailbox-ownership gate on every Mail read and write of task 01a1ea5b
  stage 2: `Platform.Mail.Mailbox` (inbox, sent, refused, drafts, deep
  links, Add to files), `Platform.Mail.Drafts` visibility and editing,
  `Platform.Mail.Dispatch`, `Platform.Mail.list_readable_accounts/2`, the
  `Platform.Mail.Ownership` restriction provider (mail-bound spaces), the
  mail-file helpers, `list_grants/2`, and the Experiments mail source.

  Every access test proves both directions: the reader sees it, a member
  who is not a reader (and an org admin, for a personal mailbox) does not.

  async: false — flips `:mail_enabled` and installs the labeler stub through
  application env.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.TenancyFixtures
  import Platform.Test.MailPrivacyFixtures

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Experiments.Signals
  alias Platform.Experiments.Signals.MailSource
  alias Platform.Mail
  alias Platform.Mail.{Account, Delivery, Dispatch, Draft, Drafts, Mailbox, Ownership}
  alias Platform.Test.ExperimentsLabelerStub, as: LabelerStub
  alias Platform.Test.ExperimentsMailFixtures, as: ExpFixtures

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

    org_id = acme_org_id()
    admin = user!("admin") |> member!(org_id, "admin")
    owner = user!("owner") |> member!(org_id)
    other = user!("other") |> member!(org_id)

    account = account!(admin, org_id, %{"internal_only" => false})
    {:ok, _} = Mail.put_sender(admin, account, %{"key" => "ops", "address" => owner.email})
    personal = personal!(admin, account, owner)

    %{org_id: org_id, admin: admin, owner: owner, other: other, personal: personal}
  end

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))

  defp delivery!(account, attrs) do
    id = Platform.Types.UUIDv7.generate()

    %{
      id: id,
      org_id: account.org_id,
      account_id: account.id,
      sender_key: "ops",
      from_address: "ops@example.com",
      recipients: ["someone@example.com"],
      subject: "Delivery #{id}",
      body: "b",
      actor_type: "system",
      message_id_header: "<#{id}@example.com>",
      status: "sending"
    }
    |> Map.merge(attrs)
    |> Delivery.insert_changeset()
    |> Repo.insert!()
  end

  defp draft!(org_id, attrs) do
    %Draft{}
    |> Draft.changeset(
      Map.merge(
        %{
          org_id: org_id,
          to_addresses: ["someone@example.com"],
          subject: "Hello",
          body: "The body.",
          created_by_type: "agent",
          created_by_id: Ecto.UUID.generate(),
          status: "draft"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  # ── Accounts ────────────────────────────────────────────────────────────

  describe "list_readable_accounts/2" do
    test "the owner gets their personal mailbox; a member and an org admin do not", ctx do
      assert Enum.map(Mail.list_readable_accounts(ctx.owner, ctx.org_id), & &1.id) == [
               ctx.personal.id
             ]

      assert Mail.list_readable_accounts(ctx.other, ctx.org_id) == []
      assert Mail.list_readable_accounts(ctx.admin, ctx.org_id) == []
      # The settings read still lists it for the admin.
      assert ctx.personal.id in Enum.map(Mail.list_accounts(ctx.org_id), & &1.id)
    end
  end

  # ── Inbox ───────────────────────────────────────────────────────────────

  describe "inbox reads" do
    test "list_inbound/3 and count_inbound/3 return the owner's mail and nothing to anyone else",
         ctx do
      row = inbound!(ctx.personal, %{subject: "SUBJ-P-1"})

      assert [%{id: id}] = Mailbox.list_inbound(ctx.owner, ctx.org_id)
      assert id == row.id
      assert Mailbox.count_inbound(ctx.owner, ctx.org_id) == 1

      for viewer <- [ctx.other, ctx.admin] do
        assert Mailbox.list_inbound(viewer, ctx.org_id) == []
        assert Mailbox.count_inbound(viewer, ctx.org_id) == 0
        # A crafted account filter naming the unreadable account lists nothing.
        assert Mailbox.list_inbound(viewer, ctx.org_id, account_id: ctx.personal.id) == []
        assert Mailbox.count_inbound(viewer, ctx.org_id, account_id: ctx.personal.id) == 0
      end
    end

    test "get_inbound/3 and inbound_org_id/2 answer an unreadable id exactly as an unknown one",
         ctx do
      row = inbound!(ctx.personal)
      unknown = Ecto.UUID.generate()

      assert %{id: id} = Mailbox.get_inbound(ctx.owner, ctx.org_id, row.id)
      assert id == row.id
      assert Mailbox.inbound_org_id(ctx.owner, row.id) == ctx.org_id

      for viewer <- [ctx.other, ctx.admin] do
        assert Mailbox.get_inbound(viewer, ctx.org_id, row.id) ==
                 Mailbox.get_inbound(viewer, ctx.org_id, unknown)

        assert Mailbox.get_inbound(viewer, ctx.org_id, row.id) == nil
        assert Mailbox.inbound_org_id(viewer, row.id) == nil
        assert Mailbox.inbound_org_id(viewer, unknown) == nil
      end
    end

    test "unassigned mailboxes are read by nobody, the admin included", ctx do
      unassigned = account!(ctx.admin, ctx.org_id)
      inbound!(unassigned)

      for viewer <- [ctx.owner, ctx.other, ctx.admin] do
        assert Mailbox.list_inbound(viewer, ctx.org_id, account_id: unassigned.id) == []
      end
    end

    test "a shared member reads; revoking the grant hides it on the next read", ctx do
      shared = shared!(ctx.admin, account!(ctx.admin, ctx.org_id), [ctx.other])
      row = inbound!(shared)

      assert [%{id: id}] = Mailbox.list_inbound(ctx.other, ctx.org_id, account_id: shared.id)
      assert id == row.id
      assert Mailbox.list_inbound(ctx.owner, ctx.org_id, account_id: shared.id) == []

      {:ok, _} = Ownership.revoke(ctx.admin, shared, {:user, ctx.other.id})
      assert Mailbox.list_inbound(ctx.other, ctx.org_id, account_id: shared.id) == []
    end
  end

  # ── Sent / Refused ──────────────────────────────────────────────────────

  describe "deliveries" do
    test "sent and refused are the readers' only", ctx do
      sent = delivery!(ctx.personal, %{})

      refused =
        delivery!(ctx.personal, %{status: "refused", refusal_reason: %{"code" => "send_disabled"}})

      assert [%{id: s}] = Mailbox.list_deliveries(ctx.owner, ctx.org_id, :sent)
      assert s == sent.id
      assert [%{id: r}] = Mailbox.list_deliveries(ctx.owner, ctx.org_id, :refused)
      assert r == refused.id
      assert Mailbox.count_deliveries(ctx.owner, ctx.org_id, :sent) == 1

      for viewer <- [ctx.other, ctx.admin], which <- [:sent, :refused] do
        assert Mailbox.list_deliveries(viewer, ctx.org_id, which) == []
        assert Mailbox.count_deliveries(viewer, ctx.org_id, which) == 0
      end
    end
  end

  # ── Drafts ──────────────────────────────────────────────────────────────

  describe "draft visibility" do
    test "a draft on an account is seen by the account's readers and its on-behalf person only",
         ctx do
      on_behalf = user!("behalf") |> member!(ctx.org_id)

      draft =
        draft!(ctx.org_id, %{account_id: ctx.personal.id, on_behalf_of_user_id: on_behalf.id})

      for viewer <- [ctx.owner, on_behalf] do
        assert [%{id: id}] = Mailbox.list_drafts(viewer, ctx.org_id)
        assert id == draft.id
        assert Mailbox.count_drafts(viewer, ctx.org_id) == 1
        assert %Draft{} = Drafts.get_visible(viewer, ctx.org_id, draft.id)
      end

      for viewer <- [ctx.other, ctx.admin] do
        assert Mailbox.list_drafts(viewer, ctx.org_id) == []
        assert Mailbox.count_drafts(viewer, ctx.org_id) == 0
        assert Drafts.get_visible(viewer, ctx.org_id, draft.id) == nil
      end
    end

    test "a draft without an account is seen by its creator and on-behalf person only", ctx do
      on_behalf = user!("behalf") |> member!(ctx.org_id)

      draft =
        draft!(ctx.org_id, %{
          created_by_type: "user",
          created_by_id: ctx.other.id,
          on_behalf_of_user_id: on_behalf.id
        })

      for viewer <- [ctx.other, on_behalf] do
        assert %Draft{} = Drafts.get_visible(viewer, ctx.org_id, draft.id)
        assert [_] = Mailbox.list_drafts(viewer, ctx.org_id)
      end

      for viewer <- [ctx.owner, ctx.admin] do
        assert Drafts.get_visible(viewer, ctx.org_id, draft.id) == nil
        assert Mailbox.list_drafts(viewer, ctx.org_id) == []
      end
    end

    test "only someone who can see a draft may edit or discard it", ctx do
      draft = draft!(ctx.org_id, %{account_id: ctx.personal.id})

      for viewer <- [ctx.other, ctx.admin] do
        assert {:error, :unauthorized} = Drafts.update(viewer, draft.id, %{"subject" => "x"})
        assert {:error, :unauthorized} = Drafts.discard(viewer, draft.id)
      end

      assert Repo.reload!(draft).subject == "Hello"

      assert {:ok, %{subject: "Owner edit"}} =
               Drafts.update(ctx.owner, draft.id, %{"subject" => "Owner edit"})
    end

    test "a user may put a draft only on an account they can read", ctx do
      assert {:error, :account_not_found} =
               Drafts.create(ctx.other, ctx.org_id, %{"account_id" => ctx.personal.id})

      mine = Drafts.create(ctx.other, ctx.org_id, %{"subject" => "no account"})
      assert {:ok, %Draft{} = own} = mine

      assert {:error, :account_not_found} =
               Drafts.update(ctx.other, own.id, %{"account_id" => ctx.personal.id})

      assert {:ok, %Draft{account_id: id}} =
               Drafts.create(ctx.owner, ctx.org_id, %{"account_id" => ctx.personal.id})

      assert id == ctx.personal.id
    end

    test "sendable_senders/2 lists only readable accounts' senders", ctx do
      assert [{%Account{id: id}, %{key: "ops"}}] = Drafts.sendable_senders(ctx.owner, ctx.org_id)
      assert id == ctx.personal.id
      assert Drafts.sendable_senders(ctx.other, ctx.org_id) == []
      assert Drafts.sendable_senders(ctx.admin, ctx.org_id) == []
    end
  end

  # ── Dispatch ────────────────────────────────────────────────────────────

  describe "dispatch" do
    test "refuses an actor who cannot read the sending account; the owner sends", ctx do
      draft =
        draft!(ctx.org_id, %{
          account_id: ctx.personal.id,
          sender_key: "ops",
          to_addresses: [ctx.owner.email]
        })

      for viewer <- [ctx.other, ctx.admin] do
        assert {:error, :unauthorized} = Dispatch.dispatch(draft.id, viewer)
      end

      assert Repo.aggregate(where(Delivery, [d], d.draft_id == ^draft.id), :count) == 0
      assert {:ok, %Delivery{}} = Dispatch.dispatch(draft.id, ctx.owner)
    end

    test "an admin's own Send test still sends from a personal mailbox; the editor path does not",
         ctx do
      assert {:ok, %Delivery{}} = Mail.send_test(ctx.admin, ctx.personal, "ops")

      # The same kind of draft sent without the send_test option is refused.
      draft =
        draft!(ctx.org_id, %{
          account_id: ctx.personal.id,
          sender_key: "ops",
          to_addresses: [ctx.admin.email],
          responsibility: "mail_account_test",
          created_by_type: "user",
          created_by_id: ctx.admin.id
        })

      assert {:error, :unauthorized} = Dispatch.dispatch(draft.id, ctx.admin)

      assert {:error, :unauthorized} =
               Dispatch.dispatch(draft.id, ctx.other, account_test: true)
    end
  end

  # ── Add to files ────────────────────────────────────────────────────────

  describe "add_to_files/3" do
    setup ctx do
      root = Platform.TestTemp.path("mail-privacy-files")
      File.mkdir_p!(root)
      previous_root = Application.get_env(:platform, :chat_attachments_root)
      Application.put_env(:platform, :chat_attachments_root, root)

      on_exit(fn ->
        File.rm_rf!(root)

        if previous_root,
          do: Application.put_env(:platform, :chat_attachments_root, previous_root),
          else: Application.delete_env(:platform, :chat_attachments_root)
      end)

      {:ok, project} =
        Platform.Tasks.create_project(%{name: "Mp files #{unique()}", org_id: ctx.org_id})

      %{project: project}
    end

    test "a non-reader gets not-found and writes nothing; the owner adds it", ctx do
      row = inbound!(ctx.personal)

      for viewer <- [ctx.other, ctx.admin] do
        assert {:error, :not_found} = Mailbox.add_to_files(viewer, row.id, ctx.project.id)
      end

      assert is_nil(Repo.reload!(row).file_id)
      assert {:ok, :created, file} = Mailbox.add_to_files(ctx.owner, row.id, ctx.project.id)
      assert Repo.reload!(row).file_id == file.id
    end
  end

  # ── Mail-bound spaces (the Access restriction provider) ─────────────────

  describe "restricted_space_ids/2 (mail-bound spaces)" do
    setup ctx do
      space = channel!(ctx.org_id)
      bind_inbound_space!(ctx.personal, space)
      p = join_user!(space, ctx.owner)
      join_user!(space, ctx.other)
      join_user!(space, ctx.admin)
      %{space: space, poster: p}
    end

    test "an inbound space is restricted for every non-reader and open to the owner", ctx do
      assert Access.can?(scope(ctx.owner), "chat.read", ctx.space.id)
      assert Access.restricted_space_ids(scope(ctx.owner), [ctx.space.id]) == MapSet.new()

      for viewer <- [ctx.other, ctx.admin] do
        assert Access.restricted_space_ids(scope(viewer), [ctx.space.id]) ==
                 MapSet.new([ctx.space.id])

        refute Access.can?(scope(viewer), "chat.read", ctx.space.id)

        assert Access.check(scope(viewer), "chat.read", {:space, ctx.space.id}) ==
                 {:error, :denied}
      end

      # Only the ids asked about are answered.
      unrelated = channel!(ctx.org_id)
      assert Ownership.restricted_space_ids(scope(ctx.other), [unrelated.id]) == []

      # Joining the space granted nothing, and nothing was removed from it.
      assert Repo.exists?(
               from(p in Platform.Chat.Participant,
                 where: p.space_id == ^ctx.space.id and p.participant_id == ^ctx.other.id
               )
             )
    end

    test "a space holding a mail post stays bound after inbound_space_id moves away", ctx do
      mail_post!(ctx.personal, ctx.space, ctx.poster, "BODY-P-1")
      moved = channel!(ctx.org_id)
      bind_inbound_space!(ctx.personal, moved)

      assert Ownership.restricted_space_ids(scope(ctx.other), [ctx.space.id, moved.id])
             |> MapSet.new() == MapSet.new([ctx.space.id, moved.id])

      assert Ownership.restricted_space_ids(scope(ctx.owner), [ctx.space.id, moved.id]) == []
    end

    test "an archived account still binds its space", ctx do
      {:ok, _} = Mail.archive_account(ctx.admin, ctx.personal)
      assert ctx.space.id in Ownership.restricted_space_ids(scope(ctx.other), [ctx.space.id])
      assert Ownership.restricted_space_ids(scope(ctx.owner), [ctx.space.id]) == []
    end

    test "a space bound to two accounts needs a reader of EVERY account", ctx do
      shared = shared!(ctx.admin, account!(ctx.admin, ctx.org_id), [ctx.other])
      mail_post!(shared, ctx.space, ctx.poster, "shared mail")

      # The owner reads the personal mailbox but not the shared one.
      assert ctx.space.id in Ownership.restricted_space_ids(scope(ctx.owner), [ctx.space.id])
      # The shared member reads the shared mailbox but not the personal one.
      assert ctx.space.id in Ownership.restricted_space_ids(scope(ctx.other), [ctx.space.id])

      {:ok, _} = Ownership.grant(ctx.admin, shared, {:user, ctx.owner.id})
      assert Ownership.restricted_space_ids(scope(ctx.owner), [ctx.space.id]) == []
    end

    test "an agent runtime reads only with a grant; a revoke restricts on the next read", ctx do
      agent = agent!()
      join_agent!(ctx.space, agent)
      runtime = runtime!(agent, ctx.owner)
      rscope = Scope.for_runtime(runtime)

      assert ctx.space.id in Ownership.restricted_space_ids(rscope, [ctx.space.id])
      refute Access.can?(rscope, "chat.read", ctx.space.id)

      {:ok, _} = Ownership.grant(ctx.owner, ctx.personal, {:agent, agent.id})
      assert Ownership.restricted_space_ids(rscope, [ctx.space.id]) == []
      assert Access.can?(rscope, "chat.read", ctx.space.id)

      {:ok, _} = Ownership.revoke(ctx.owner, ctx.personal, {:agent, agent.id})
      assert ctx.space.id in Ownership.restricted_space_ids(rscope, [ctx.space.id])
    end

    test "an agent grant on an unassigned account opens nothing", ctx do
      unassigned = account!(ctx.admin, ctx.org_id)
      space = channel!(ctx.org_id)
      bind_inbound_space!(unassigned, space)
      agent = agent!()

      Repo.insert!(%Platform.Mail.AccountGrant{
        account_id: unassigned.id,
        principal_type: "agent",
        principal_id: agent.id
      })

      rscope = Scope.for_runtime(runtime!(agent, ctx.owner))
      assert space.id in Ownership.restricted_space_ids(rscope, [space.id])
    end

    test "a meeting invitee and an empty Scope read no mailbox", ctx do
      for s <- [Scope.for_meeting_invitee(%{id: Ecto.UUID.generate()}), %Scope{}] do
        assert ctx.space.id in Ownership.restricted_space_ids(s, [ctx.space.id])
      end
    end

    test ":all is answered with ONE query", ctx do
      mail_post!(ctx.personal, ctx.space, ctx.poster, "x")
      handler = "mp-query-count-#{unique()}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:platform, :repo, :query],
        fn _e, _m, _meta, _ -> if self() == test_pid, do: send(test_pid, :mp_query) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      s = scope(ctx.other)
      flush = fn -> receive_all(:mp_query) end
      flush.()

      ids = Ownership.restricted_space_ids(s, :all)
      assert ctx.space.id in ids
      assert receive_all(:mp_query) == 1
    end
  end

  defp receive_all(msg, n \\ 0) do
    receive do
      ^msg -> receive_all(msg, n + 1)
    after
      0 -> n
    end
  end

  # ── Mail-derived files ──────────────────────────────────────────────────

  describe "mail file helpers" do
    test "a file mail was added to is unreadable to non-readers and agents without a grant",
         ctx do
      file_id = Ecto.UUID.generate()

      {:ok, project} =
        Platform.Tasks.create_project(%{name: "Mp #{unique()}", org_id: ctx.org_id})

      file =
        Repo.insert!(%Platform.Files.File{
          id: file_id,
          project_id: project.id,
          name: "mail.md",
          original_filename: "mail.md",
          content_type: "text/markdown",
          byte_size: 4,
          storage_key: "files/#{project.id}/#{file_id}/mail.md",
          content_hash: "h-#{unique()}",
          ingest_status: "ingested",
          ingest_intent: "attempt"
        })

      plain = Ecto.UUID.generate()
      inbound!(ctx.personal, %{file_id: file.id})

      # A second mail file, not asked about, is not answered.
      other_id = Ecto.UUID.generate()

      Repo.insert!(
        Ecto.put_meta(
          %{
            file
            | id: other_id,
              storage_key: "files/#{project.id}/#{other_id}/mail.md",
              content_hash: "h-#{unique()}"
          },
          state: :built
        )
      )

      inbound!(ctx.personal, %{file_id: other_id})
      agent = agent!()

      assert Ownership.mail_file_ids_unreadable_by(ctx.owner, [file.id, plain]) == MapSet.new()

      for p <- [ctx.other, ctx.admin, {:agent, agent.id}, nil] do
        assert Ownership.mail_file_ids_unreadable_by(p, [file.id, plain]) ==
                 MapSet.new([file.id])
      end

      {:ok, _} = Ownership.grant(ctx.owner, ctx.personal, {:agent, agent.id})
      assert Ownership.mail_file_ids_unreadable_by({:agent, agent.id}, [file.id]) == MapSet.new()
    end
  end

  # ── list_grants/2 ───────────────────────────────────────────────────────

  describe "list_grants/2" do
    test "the manager gets the grants; a member and an org admin of a personal mailbox do not",
         ctx do
      agent = agent!()
      {:ok, grant} = Ownership.grant(ctx.owner, ctx.personal, {:agent, agent.id})

      assert {:ok, [%{id: id}]} = Ownership.list_grants(ctx.owner, ctx.personal)
      assert id == grant.id

      for viewer <- [ctx.other, ctx.admin, nil] do
        assert {:error, :unauthorized} = Ownership.list_grants(viewer, ctx.personal)
      end
    end
  end

  # ── Experiments mail signals ────────────────────────────────────────────

  describe "experiments mail source" do
    setup do
      ExpFixtures.scientist!()
      :ok = LabelerStub.install!(fn _c, _m, _o -> {:error, :no_reply_planted} end)
      :ok
    end

    test "a personal mailbox's mail never reaches the labeler; a shared one's does", ctx do
      experiment = ExpFixtures.mail_experiment!(%{org_id: ctx.org_id})
      task = ExpFixtures.task!("Mail privacy subject")
      ExpFixtures.assign!(experiment, task.id, "control")

      shared = ExpFixtures.account!(ctx.org_id)

      personal =
        ExpFixtures.account!(ctx.org_id)
        |> then(&personal!(ctx.admin, &1, ctx.owner))

      {1, personal_row} = ExpFixtures.ingest!(personal)
      assert MailSource.on_inbound(personal_row.id) == []
      refute_received {:labeler_stub_called, _, _, _}

      LabelerStub.reply!(
        LabelerStub.json(%{
          "label" => "rejection",
          "subject_id" => task.id,
          "confidence" => 0.8,
          "reason" => "declined"
        })
      )

      {1, shared_row} = ExpFixtures.ingest!(shared)
      assert [{:ok, _signal}] = MailSource.on_inbound(shared_row.id)
      assert_received {:labeler_stub_called, _, _, _}

      # reconcile/0 labels nothing from the personal mailbox either.
      assert MailSource.reconcile() == 0
      refute_received {:labeler_stub_called, _, _, _}
    end

    test "experiment_signals_list returns a mail signal's reason only to a granted agent", ctx do
      experiment = ExpFixtures.mail_experiment!(%{org_id: ctx.org_id})
      row = inbound!(ctx.personal)
      subject = Ecto.UUID.generate()

      {:ok, _} =
        Signals.record(%{
          experiment_id: experiment.id,
          subject_type: "task",
          subject_id: subject,
          label: "screen",
          confidence: 0.9,
          reason: "REASON-P-1",
          status: "labelled",
          source_type: "mail_inbound",
          source_id: to_string(row.id)
        })

      agent = agent!()
      args = %{"experiment_id" => experiment.id}

      call = fn ->
        Platform.Experiments.Tools.execute("experiment_signals_list", args, %{agent_id: agent.id})
      end

      assert {:ok, %{signals: [%{reason: nil, label: "screen"}]}} = call.()
      {:ok, _} = Ownership.grant(ctx.owner, ctx.personal, {:agent, agent.id})
      assert {:ok, %{signals: [%{reason: "REASON-P-1"}]}} = call.()
    end
  end
end
