defmodule Platform.Memory.Insights.OutsideTest do
  @moduledoc """
  Task 01a15ee1 stage 3: an insight addressed to an email outside the org is
  saved as ONE email draft, never sent.

  Membership decides who is outside, not the tier. The draft is created
  once across two disseminator runs, nothing is drafted while the Email
  module is off, and `Platform.Mail.Dispatch` is never called (traced, not
  inferred), so the draft stays `draft`.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.InsightFixtures
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Mail
  alias Platform.Mail.Draft
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights.Disseminator
  alias Platform.Memory.Insights.Outside
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  defmodule PushRecorder do
    @moduledoc false
    def fan_out_to_user(_user_id, _payload), do: :ok
  end

  @now ~U[2026-10-18 12:00:00.000000Z]

  defp n, do: System.unique_integer([:positive])

  defp run!, do: Disseminator.run(now: @now, notifications_module: PushRecorder)

  defp mail_on! do
    previous = Application.fetch_env(:platform, :mail_enabled)
    Application.put_env(:platform, :mail_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)
  end

  defp account!(org_id) do
    admin = person!("admin")
    name = "outside#{n()}"

    {:ok, account} =
      Mail.create_account(admin, org_id, %{
        "name" => name,
        "smtp_host" => "smtp.#{name}.test",
        "smtp_port" => 2525,
        "smtp_tls" => "none",
        "username" => "#{name}-relay"
      })

    account
  end

  defp outside_insight!(email, attrs \\ %{}) do
    insight!(
      Map.merge(
        %{
          action_type: "question",
          body: "Hello from the team\nCould you confirm the Friday delivery window?",
          action: %{"addressee" => email},
          tier: "needs_call"
        },
        attrs
      )
    )
  end

  # Every call into `modules` that THIS process makes while `fun` runs, as
  # `{module, function, arity}`. The trace goes to a separate collector
  # process (a process is not its own tracer). Each module is loaded first
  # and must match at least one function: `trace_pattern` on an unloaded
  # module matches nothing, which would make a refute vacuous.
  defp traced_calls(modules, fun) do
    collector = spawn_link(fn -> collect([]) end)

    for module <- modules do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern({module, :_, :_}, true, [:local]) > 0
    end

    :erlang.trace(self(), true, [:call, {:tracer, collector}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(modules, &:erlang.trace_pattern({&1, :_, :_}, false, [:local]))
    end

    ref = :erlang.trace_delivered(self())

    receive do
      {:trace_delivered, _pid, ^ref} -> :ok
    after
      5_000 -> flunk("trace messages were not delivered")
    end

    send(collector, {:dump, self()})

    receive do
      {:calls, calls} -> calls
    after
      5_000 -> flunk("the trace collector did not answer")
    end
  end

  defp collect(acc) do
    receive do
      {:trace, _pid, :call, {m, f, args}} -> collect([{m, f, length(args)} | acc])
      {:dump, to} -> send(to, {:calls, Enum.reverse(acc)})
    end
  end

  defp drafts, do: Repo.all(from(d in Draft, order_by: [asc: d.inserted_at]))

  describe "outside?/1" do
    test "an unknown email is outside" do
      assert Outside.outside?(outside_insight!("nobody-#{n()}@client.example"))
    end

    test "an internal member's email is not outside" do
      member = person!()
      refute Outside.outside?(outside_insight!(member.email))

      # Case does not matter.
      refute Outside.outside?(outside_insight!(String.upcase(member.email)))
    end

    test "an external member's email is outside" do
      guest = person!("member", external: true)
      assert Outside.outside?(outside_insight!(guest.email))
    end

    test "a user of the install with no membership in the insight's org is outside" do
      stranger =
        Repo.insert!(%User{
          email: "stranger-#{n()}@example.com",
          name: "Stranger",
          oidc_sub: "stranger-#{n()}"
        })

      other_org = tenant_org_id("outside_other_#{n()}")

      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: stranger.id, org_id: other_org, role: "member"})
      |> Repo.insert!()

      assert Outside.outside?(outside_insight!(stranger.email))
    end

    test "no email addressee is never outside" do
      refute Outside.outside?(insight!(action: %{}))
      refute Outside.outside?(insight!(action: %{"addressee" => "some-agent-slug"}))
    end

    test "subject/1 is the first non-blank line, at most 120 characters" do
      assert Outside.subject("\n  Hello there  \nmore") == "Hello there"
      assert String.length(Outside.subject(String.duplicate("x", 300))) == 120
      assert Outside.subject(nil) == ""
    end
  end

  describe "drafting from the disseminator" do
    setup do
      enable_dissemination!()
      agent = dreaming_agent!()
      admin = root_admin!()
      %{agent: agent, admin: admin}
    end

    test "the draft is created once across two runs, addressed and never sent", %{agent: agent} do
      mail_on!()
      account = account!(acme_org_id())
      email = "ana-#{n()}@client.example"
      insight = outside_insight!(email)

      assert {:ok, _} = run!()

      assert [%Draft{} = draft] = drafts()
      assert draft.to_addresses == [email]
      assert draft.subject == "Hello from the team"
      assert draft.body == insight.body
      assert draft.status == "draft"
      assert draft.created_by_type == "agent"
      assert draft.created_by_id == agent.id
      assert draft.account_id == account.id
      assert draft.org_id == acme_org_id()

      assert %Insight{action: %{"mail_draft_id" => draft_id}} = Repo.get!(Insight, insight.id)
      assert draft_id == draft.id

      # Make the digest select it again (as if undelivered), so the second
      # run reaches the drafting step with the draft id already stored.
      Repo.update_all(from(i in Insight, where: i.id == ^insight.id), set: [delivered_at: nil])
      assert {:ok, _} = run!()
      assert {:ok, ^draft_id} = Outside.draft(Repo.get!(Insight, insight.id), agent)
      assert [%Draft{id: ^draft_id, status: "draft"}] = drafts()
    end

    test "nothing is drafted while the Email module is off; the insight is still delivered",
         %{agent: agent} do
      Application.put_env(:platform, :mail_enabled, false)
      _account = account!(acme_org_id())
      insight = outside_insight!("off-#{n()}@client.example")

      assert {:ok, %{items: items}} = run!()
      assert items >= 1
      assert drafts() == []
      assert Outside.draft(Repo.get!(Insight, insight.id), agent) == :skip

      reloaded = Repo.get!(Insight, insight.id)
      refute Map.has_key?(reloaded.action, "mail_draft_id")
      assert reloaded.delivered_at

      # Positive control: the same insight drafts once the module is on.
      mail_on!()
      assert {:ok, _id} = Outside.draft(reloaded, agent)
      assert [_draft] = drafts()
    end

    test "nothing is drafted when the org has no mail account", %{agent: agent} do
      mail_on!()
      insight = outside_insight!("noacct-#{n()}@client.example")

      assert {:ok, _} = run!()
      assert drafts() == []
      assert Outside.draft(Repo.get!(Insight, insight.id), agent) == :skip
    end

    test "an internal member's email gets no draft", %{agent: agent} do
      mail_on!()
      account!(acme_org_id())
      member = person!()
      insight = outside_insight!(member.email)

      assert Outside.draft(insight, agent) == :skip
      assert {:ok, _} = run!()
      assert drafts() == []
    end

    test "Platform.Mail.Dispatch is never called, and the draft stays a draft" do
      mail_on!()
      account!(acme_org_id())
      _insight = outside_insight!("trace-#{n()}@client.example")

      # Trace every call into Dispatch (and the Deliverer behind it) made by
      # this process, which is the one running the disseminator.
      calls =
        traced_calls([Platform.Mail.Dispatch, Platform.Mail.Deliverer], fn ->
          assert {:ok, _} = run!()
          assert {:ok, _} = run!()
        end)

      assert calls == []
      assert [%Draft{status: "draft"}] = drafts()

      # Positive control for the trace itself: a call into Dispatch IS seen.
      assert {Platform.Mail.Dispatch, :decode_refusal, 1} in traced_calls(
               [Platform.Mail.Dispatch],
               fn -> Platform.Mail.Dispatch.decode_refusal(%{}) end
             )
    end

    test "the insights pipeline has no reference to Platform.Mail.Dispatch" do
      sources =
        Path.wildcard(Path.expand("../../../../lib/platform/memory/**/*.ex", __DIR__)) ++
          [Path.expand("../../../../lib/platform/memory/insights.ex", __DIR__)]

      assert length(sources) > 10

      offenders =
        for path <- sources,
            String.contains?(File.read!(path), ["Mail.Dispatch.", "Dispatch.dispatch"]),
            do: path

      assert offenders == []
    end
  end
end
