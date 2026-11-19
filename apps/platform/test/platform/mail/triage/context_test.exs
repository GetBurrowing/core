defmodule Platform.Mail.Triage.ContextTest do
  @moduledoc """
  `Platform.Mail.Triage.Context` (task 01a1f426 stage 1): what the org knows
  about a sender, per reader, ids and counts only. Tasks and meetings are
  read through `Platform.Tasks.list_open_tasks_matching_for_user/4` and
  `Platform.Meetings.list_meetings_in_range_for_user/4`; nothing here
  queries those tables from Mail.

  async: false — `:mail_enabled` is application-wide.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures
  import Platform.Test.MailPrivacyFixtures
  import Platform.Test.MailTriageFixtures

  alias Platform.Mail.Triage
  alias Platform.Mail.Triage.Context
  alias Platform.Meetings.Invite
  alias Platform.Tasks.Project

  setup do
    enable_mail!()
    org_id = acme_org_id()
    reader = user!("reader") |> member!(org_id, "admin")
    other = user!("other") |> member!(org_id)
    box = account!(reader, org_id) |> then(&personal!(reader, &1, reader))
    %{org_id: org_id, reader: reader, other: other, box: box}
  end

  defp at(days_ago), do: DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)

  defp project!(org_id) do
    %Project{}
    |> Project.changeset(%{
      name: "Triage ctx #{unique()}",
      slug: "triage-ctx-#{unique()}",
      org_id: org_id
    })
    |> Repo.insert!()
  end

  describe "waiting_on" do
    test "an accepted delivery to the sender with no reply since", ctx do
      delivery = delivery!(ctx.box, "Counsel <Counsel@OtherCo.test>", at(3))
      inbound = inbound!(ctx.box, %{from_address: "Counsel <counsel@otherco.test>"})

      built = Context.build(ctx.reader, inbound, roster: [])
      assert built.waiting_on == delivery.id
      assert built.address == "counsel@otherco.test"
      assert %{"kind" => "waiting_on", "delivery_id" => delivery.id} in Context.signals(built)
    end

    test "a reply already received since the delivery clears it", ctx do
      delivery!(ctx.box, "counsel@otherco.test", at(3))
      inbound!(ctx.box, %{from_address: "counsel@otherco.test", received_at: at(2)})
      inbound = inbound!(ctx.box, %{from_address: "counsel@otherco.test"})

      built = Context.build(ctx.reader, inbound, roster: [])
      assert built.waiting_on == nil
      assert built.thread == %{inbound: 1, outbound: 1}
    end

    test "falls back to the sender's domain, but never a freemail domain", ctx do
      delivery = delivery!(ctx.box, "legal@otherco.test", at(3))
      inbound = inbound!(ctx.box, %{from_address: "counsel@otherco.test"})
      assert Context.build(ctx.reader, inbound, roster: []).waiting_on == delivery.id

      delivery!(ctx.box, "someone@gmail.com", at(3))
      free = inbound!(ctx.box, %{from_address: "else@gmail.com"})
      assert Context.build(ctx.reader, free, roster: []).waiting_on == nil
    end

    test "a delivery from ANOTHER mailbox does not count", ctx do
      other_box = account!(ctx.reader, ctx.org_id) |> then(&personal!(ctx.reader, &1, ctx.other))
      delivery!(other_box, "counsel@otherco.test", at(3))
      inbound = inbound!(ctx.box, %{from_address: "counsel@otherco.test"})
      assert Context.build(ctx.reader, inbound, roster: []).waiting_on == nil
    end
  end

  describe "open tasks, meetings, people, feedback" do
    test "open tasks naming the sender's domain, via the Tasks read API", ctx do
      project = project!(ctx.org_id)

      {:ok, open} =
        Platform.Tasks.create_task(%{project_id: project.id, title: "Contract for otherco.test"})

      {:ok, done} =
        Platform.Tasks.create_task(%{project_id: project.id, title: "Old otherco.test work"})

      Repo.update_all(from(t in Platform.Tasks.Task, where: t.id == ^done.id),
        set: [status: "done"]
      )

      inbound = inbound!(ctx.box, %{from_address: "counsel@otherco.test"})
      built = Context.build(ctx.reader, inbound, roster: [])
      assert open.id in built.open_task_ids
      refute done.id in built.open_task_ids
      assert %{"kind" => "open_task", "task_id" => open.id} in Context.signals(built)
    end

    test "recent meetings the reader took part in with an invite to the sender", ctx do
      project = project!(ctx.org_id)

      {:ok, meeting} =
        Platform.Meetings.create_meeting(%{
          project_id: project.id,
          name: "Contract review",
          scheduled_start_at: at(2),
          scheduled_end_at: DateTime.add(at(2), 1800, :second),
          created_by_user_id: ctx.reader.id
        })

      {:ok, old} =
        Platform.Meetings.create_meeting(%{
          project_id: project.id,
          name: "Ancient",
          scheduled_start_at: at(30),
          scheduled_end_at: DateTime.add(at(30), 1800, :second),
          created_by_user_id: ctx.reader.id
        })

      for m <- [meeting, old] do
        %Invite{}
        |> Invite.changeset(%{meeting_id: m.id, email: "Counsel@OtherCo.test", display_name: "C"})
        |> Repo.insert!()
      end

      inbound = inbound!(ctx.box, %{from_address: "counsel@otherco.test"})
      assert Context.build(ctx.reader, inbound, roster: []).meeting_ids == [meeting.id]

      # Another member who did not take part sees no meeting signal.
      other_box = account!(ctx.reader, ctx.org_id) |> then(&personal!(ctx.reader, &1, ctx.other))
      other_in = inbound!(other_box, %{from_address: "counsel@otherco.test"})
      assert Context.build(ctx.other, other_in, roster: []).meeting_ids == []
    end

    test "the People card by alias, else by organisation", ctx do
      roster = [
        %{
          slug: "card-a",
          aliases: ["counsel@otherco.test"],
          relation: "client",
          organisation: nil
        },
        %{slug: "acme-person", aliases: [], relation: "prospect", organisation: "OtherCo"}
      ]

      inbound = inbound!(ctx.box, %{from_address: "counsel@otherco.test"})

      assert Context.build(ctx.reader, inbound, roster: roster).person == %{
               slug: "card-a",
               relation: "client"
             }

      other = inbound!(ctx.box, %{from_address: "ops@otherco.test"})

      assert Context.build(ctx.reader, other, roster: roster).person ==
               %{slug: "acme-person", relation: "prospect"}

      assert Context.build(ctx.reader, other, roster: []).person == nil
    end

    test "feedback priors are this reader's only", ctx do
      inbound = inbound!(ctx.box, %{from_address: "news@vendor.test"})
      {:ok, _} = Triage.record_feedback(ctx.reader, inbound, "not_important")

      assert Context.build(ctx.reader, inbound, roster: []).feedback ==
               %{not_important: 1, missed: 0, latest: "not_important"}

      other_box = account!(ctx.reader, ctx.org_id) |> then(&personal!(ctx.reader, &1, ctx.other))
      other_in = inbound!(other_box, %{from_address: "news@vendor.test"})

      assert Context.build(ctx.other, other_in, roster: []).feedback ==
               %{not_important: 0, missed: 0, latest: nil}
    end

    test "signals and model facts carry no text", ctx do
      project = project!(ctx.org_id)

      {:ok, _} =
        Platform.Tasks.create_task(%{project_id: project.id, title: "SECRET-TITLE otherco.test"})

      inbound =
        inbound!(ctx.box, %{from_address: "counsel@otherco.test", text_body: "SECRET-BODY"})

      built = Context.build(ctx.reader, inbound, roster: [])

      dump = inspect({Context.signals(built), Context.model_facts(built)})
      refute dump =~ "SECRET"
      assert Context.model_facts(built)["reader_open_tasks_naming_them"] == 1
    end
  end

  describe "address helpers" do
    test "address/domain/local_part" do
      assert Context.address("Name <A@B.test>") == "a@b.test"
      assert Context.address("  x@y.test ") == "x@y.test"
      assert Context.address("nobody") == nil
      assert Context.domain("a@b.test") == "b.test"
      assert Context.local_part("a@b.test") == "a"
    end
  end
end
