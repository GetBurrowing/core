defmodule Platform.Mail.DraftsTest do
  @moduledoc """
  `Platform.Mail.Drafts` additions of task 01a1f426 stage 4:

    * `create/4` and `update/4` take `log: false` and `telemetry_event: nil`,
      which keep the draft body out of Ecto's query log AND out of the
      `[:platform, :repo, :query]` event (ecto_sql 3.13 still emits that
      event, params included, with `log: false` alone). The default is
      unchanged, which is also the positive control;
    * `in_reply_to_inbound_id`: an agent (or the system) may link a draft to
      an inbound email of the draft's OWN account; a person's attrs never
      set it.

  async: false — the Logger level and `:mail_enabled` are application-wide.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.TenancyFixtures
  import Platform.Test.MailPrivacyFixtures
  import Platform.Test.MailTriageFixtures

  alias Platform.Mail
  alias Platform.Mail.Drafts

  setup do
    enable_mail!()
    org_id = acme_org_id()
    n = unique()

    a = user!("a") |> member!(org_id, "admin")
    r = user!("r") |> member!(org_id)
    agent = agent!("triage")

    p = account!(a, org_id, %{"name" => "Pbox #{n}"}) |> then(&personal!(a, &1, r))

    {:ok, _} =
      Mail.put_sender(a, p, %{key: "ops", address: "box@example.test", display_name: "R"})

    grant_agent!(r, p, agent)

    other = account!(a, org_id, %{"name" => "Other #{n}"}) |> then(&personal!(a, &1, r))

    {:ok, _} =
      Mail.put_sender(a, other, %{key: "ops", address: "o@example.test", display_name: "O"})

    grant_agent!(r, other, agent)

    %{org_id: org_id, r: r, agent: agent, p: p, other: other}
  end

  defp attrs(ctx, extra \\ %{}) do
    Map.merge(
      %{
        account_id: ctx.p.id,
        sender_key: "ops",
        to_addresses: ["x@outside.test"],
        subject: "Re: hi",
        body: "b",
        on_behalf_of_user_id: ctx.r.id
      },
      extra
    )
  end

  # Runs `fun` with Logger at :debug and a `[:platform, :repo, :query]`
  # handler; returns {log, inspected telemetry params+queries}.
  defp observe(fun) do
    test_pid = self()
    handler = "drafts-quiet-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:platform, :repo, :query],
        fn _e, _m, meta, _ -> send(test_pid, {:q, Map.delete(meta, :result)}) end,
        nil
      )

    previous = Logger.level()
    Logger.configure(level: :debug)

    log =
      try do
        capture_log([level: :debug], fun)
      after
        Logger.configure(level: previous)
        :telemetry.detach(handler)
      end

    {log, inspect(drain(), limit: :infinity, printable_limit: :infinity)}
  end

  defp drain do
    receive do
      {:q, meta} -> [meta | drain()]
    after
      0 -> []
    end
  end

  describe "log: false, telemetry_event: nil" do
    test "create/4 keeps the body out of the query log and the repo telemetry", ctx do
      quiet = "QUIET-#{Ecto.UUID.generate()}"
      loud = "LOUD-#{Ecto.UUID.generate()}"

      {log, telemetry} =
        observe(fn ->
          assert {:ok, _} =
                   Drafts.create({:agent, ctx.agent.id}, ctx.org_id, attrs(ctx, %{body: quiet}),
                     log: false,
                     telemetry_event: nil
                   )
        end)

      refute log =~ quiet
      refute telemetry =~ quiet

      # Positive control: the default still logs and emits the body.
      {log, telemetry} =
        observe(fn ->
          assert {:ok, _} =
                   Drafts.create({:agent, ctx.agent.id}, ctx.org_id, attrs(ctx, %{body: loud}))
        end)

      assert log =~ loud
      assert telemetry =~ loud
    end

    test "log: false alone still emits the params (why both are needed)", ctx do
      body = "HALF-#{Ecto.UUID.generate()}"

      {log, telemetry} =
        observe(fn ->
          assert {:ok, _} =
                   Drafts.create({:agent, ctx.agent.id}, ctx.org_id, attrs(ctx, %{body: body}),
                     log: false
                   )
        end)

      refute log =~ body
      assert telemetry =~ body
    end

    test "update/4 takes the same options", ctx do
      {:ok, draft} = Drafts.create({:agent, ctx.agent.id}, ctx.org_id, attrs(ctx))
      quiet = "QUIET-#{Ecto.UUID.generate()}"

      {log, telemetry} =
        observe(fn ->
          assert {:ok, %{body: ^quiet}} =
                   Drafts.update({:agent, ctx.agent.id}, draft.id, %{body: quiet},
                     log: false,
                     telemetry_event: nil
                   )
        end)

      refute log =~ quiet
      refute telemetry =~ quiet

      loud = "LOUD-#{Ecto.UUID.generate()}"

      {log, _} =
        observe(fn -> {:ok, _} = Drafts.update({:user, ctx.r.id}, draft.id, %{body: loud}) end)

      assert log =~ loud
    end
  end

  describe "in_reply_to_inbound_id" do
    test "an agent links a draft to an email of the draft's own account", ctx do
      inbound = inbound!(ctx.p)

      assert {:ok, draft} =
               Drafts.create(
                 {:agent, ctx.agent.id},
                 ctx.org_id,
                 attrs(ctx, %{in_reply_to_inbound_id: inbound.id})
               )

      assert draft.in_reply_to_inbound_id == inbound.id
    end

    test "an email of another account, or an unknown id, is refused", ctx do
      elsewhere = inbound!(ctx.other)

      for id <- [elsewhere.id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert {:error, :in_reply_to_not_found} =
                 Drafts.create(
                   {:agent, ctx.agent.id},
                   ctx.org_id,
                   attrs(ctx, %{in_reply_to_inbound_id: id})
                 )
      end

      inbound = inbound!(ctx.p)

      {:ok, draft} =
        Drafts.create(
          {:agent, ctx.agent.id},
          ctx.org_id,
          attrs(ctx, %{in_reply_to_inbound_id: inbound.id})
        )

      # Moving the draft to another account re-checks the link.
      assert {:error, :in_reply_to_not_found} =
               Drafts.update({:agent, ctx.agent.id}, draft.id, %{account_id: ctx.other.id})
    end

    test "a person's attrs never set it", ctx do
      inbound = inbound!(ctx.p)

      assert {:ok, draft} =
               Drafts.create(
                 {:user, ctx.r.id},
                 ctx.org_id,
                 attrs(ctx, %{in_reply_to_inbound_id: inbound.id})
               )

      assert draft.in_reply_to_inbound_id == nil

      {:ok, agent_draft} =
        Drafts.create(
          {:agent, ctx.agent.id},
          ctx.org_id,
          attrs(ctx, %{in_reply_to_inbound_id: inbound.id})
        )

      assert {:ok, edited} =
               Drafts.update({:user, ctx.r.id}, agent_draft.id, %{in_reply_to_inbound_id: nil})

      assert edited.in_reply_to_inbound_id == inbound.id
    end

    test "the link is nilified when the email is deleted", ctx do
      inbound = inbound!(ctx.p)

      {:ok, draft} =
        Drafts.create(
          {:agent, ctx.agent.id},
          ctx.org_id,
          attrs(ctx, %{in_reply_to_inbound_id: inbound.id})
        )

      Repo.delete!(inbound)
      assert Repo.get!(Mail.Draft, draft.id).in_reply_to_inbound_id == nil
    end
  end
end
