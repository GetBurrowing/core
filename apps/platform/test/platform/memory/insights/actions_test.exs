defmodule Platform.Memory.Insights.ActionsTest do
  @moduledoc """
  Task 01a13867 stage 2: clicker-scoped `page_edit` and `task` actions.

  Every refusal reads the page (content AND version) or the task table back
  afterwards, so a refusal that wrote first and errored second is caught.
  Every refusal has its positive control on the same fixture: the same
  click by someone allowed, or the same insight inside its TTL, DOES
  execute. Mutation probe (c) (no `expires_at` check) turns
  "an expired needs_call insight is never executed late" red.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.Purger
  alias Platform.Org.Wiki
  alias Platform.Repo
  alias Platform.Tasks.Task
  alias Platform.Tenancy.OrgMembership

  @journal "org/journal/2026-10-18.md"

  defp n, do: System.unique_integer([:positive])

  defp member!(org) do
    i = n()

    u =
      Repo.insert!(%User{email: "act-#{i}@example.com", name: "Act #{i}", oidc_sub: "act-#{i}"})

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: u.id, org_id: org, role: "member"})
    |> Repo.insert!()

    u
  end

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))

  defp page!(content, editor) do
    key = "org/page/act-#{n()}.md"
    {:ok, page} = Wiki.upsert_page(key, %{content: content, updated_by: editor && editor.id})
    {key, page}
  end

  defp edit_block(key, old, new) do
    ~s(<synthesis-insight action="page_edit" confidence="high" target="#{key}" source="page:#{key}">
    The page is out of date, ref #{n()}.
    <old>#{old}</old><new>#{new}</new>
    </synthesis-insight>)
  end

  defp ingest!(content, journal \\ @journal) do
    before = Repo.all(from(i in Insight, select: i.id))
    {:ok, 1} = Insights.ingest_from_journal(nil, journal, content)
    Repo.one!(from(i in Insight, where: i.id not in ^before))
  end

  defp page_state(key) do
    page = Wiki.get_page(key)
    {page.content, page.version}
  end

  setup do
    org = acme_org_id()
    %{org: org, member: member!(org)}
  end

  describe "page_edit" do
    test "Apply edit rewrites the cited page", %{member: member} do
      {key, page} = page!("Deploys go to hive every night.", member)
      insight = ingest!(edit_block(key, "go to hive", "go to moon"))
      assert insight.tier == "reversible"

      assert {:ok, %Insight{state: "done"} = acted} = Insights.act(insight, scope(member))

      written = Wiki.get_page(key)
      refute written.content =~ "go to hive"
      assert written.content == "Deploys go to moon every night."
      assert written.version == page.version + 1
      assert written.updated_by == member.id

      assert acted.acted_by == member.id
      assert acted.artefact_ref == "page:#{key}@v#{written.version}"

      assert %{"content" => "Deploys go to hive every night.", "version" => v} =
               Repo.get!(Insight, insight.id).pre_image

      assert v == page.version

      # Acting twice does nothing more.
      assert {:error, :not_open} = Insights.act(insight, scope(member))
      assert Wiki.get_page(key).version == written.version
    end

    test "a stale hunk refuses and leaves the page untouched", %{member: member} do
      {key, _page} = page!("Deploys go to hive every night.", member)
      insight = ingest!(edit_block(key, "go to hive", "go to moon"))

      # Someone edits the page after the insight was written.
      {:ok, _} = Wiki.upsert_page(key, %{content: "Deploys go to rock every night."})
      before = page_state(key)

      assert {:error, :stale} = Insights.act(insight, scope(member))
      assert page_state(key) == before
      assert %Insight{state: "open", pre_image: nil} = Repo.get!(Insight, insight.id)

      # An ambiguous hunk (the old text occurs twice) is stale too.
      {key2, _} = page!("hive, then hive again", member)
      twice = ingest!(edit_block(key2, "hive", "moon"))
      before2 = page_state(key2)
      assert {:error, :stale} = Insights.act(twice, scope(member))
      assert page_state(key2) == before2
    end

    test "a user without memory.write on the key is refused", %{org: org, member: member} do
      {key, _page} = page!("Deploys go to hive every night.", member)
      insight = ingest!(edit_block(key, "go to hive", "go to moon"))

      denied = member!(org)

      {:ok, _} =
        Grants.deny(%{principal: denied, permission: "memory.write", resource: {:memory, key}})

      before = page_state(key)
      assert {:error, :unauthorized} = Insights.act(insight, scope(denied))
      assert page_state(key) == before
      assert %Insight{state: "open"} = Repo.get!(Insight, insight.id)

      # Control: a member without the deny applies the same insight.
      assert {:ok, %Insight{state: "done"}} = Insights.act(insight, scope(member))
      assert Wiki.get_page(key).content == "Deploys go to moon every night."
    end

    test "revert restores the pre-image while the insight lives", %{member: member} do
      {key, page} = page!("Deploys go to hive every night.", member)
      insight = ingest!(edit_block(key, "go to hive", "go to moon"))
      {:ok, acted} = Insights.act(insight, scope(member))
      assert Wiki.get_page(key).content == "Deploys go to moon every night."

      assert {:ok, %Insight{state: "open", pre_image: nil, artefact_ref: nil}} =
               Insights.revert(acted, scope(member))

      restored = Wiki.get_page(key)
      assert restored.content == "Deploys go to hive every night."
      # A revert is a new version, not a rewind: there is no revision table.
      assert restored.version == page.version + 2

      # Once the row is purged there is nothing to revert to.
      {:ok, acted_again} = Insights.act(insight, scope(member))
      {:ok, 1} = Purger.sweep(now: DateTime.add(acted_again.expires_at, 1, :second))
      before = page_state(key)
      assert {:error, :expired} = Insights.revert(acted_again, scope(member))
      assert page_state(key) == before
    end

    test "revert refuses when the page moved on after the act", %{member: member} do
      {key, _page} = page!("Deploys go to hive every night.", member)

      {:ok, acted} =
        Insights.act(ingest!(edit_block(key, "go to hive", "go to moon")), scope(member))

      {:ok, _} = Wiki.upsert_page(key, %{content: "rewritten by hand"})
      before = page_state(key)

      assert {:error, :stale} = Insights.revert(acted, scope(member))
      assert page_state(key) == before
    end
  end

  describe "needs_call" do
    test "a non-admin cannot execute a needs_call insight", %{member: member} do
      {key, _page} = page!("Keep this. Drop this.", member)
      insight = ingest!(edit_block(key, " Drop this.", ""))
      assert insight.tier == "needs_call"

      before = page_state(key)
      assert {:error, :unauthorized} = Insights.act(insight, scope(member))
      assert page_state(key) == before

      # Control: an install admin executes it.
      admin = root_admin!()
      assert {:ok, %Insight{state: "done"}} = Insights.act(insight, scope(admin))
      assert Wiki.get_page(key).content == "Keep this."
    end

    test "an expired needs_call insight is never executed late", %{org: org, member: member} do
      admin = root_admin!()
      {key, _page} = page!("Keep this. Drop this.", member)
      edit = ingest!(edit_block(key, " Drop this.", ""))
      assert edit.tier == "needs_call"

      {:ok, project} = Platform.Tasks.create_project(%{name: "late-#{n()}", org_id: org})

      task =
        ingest!(
          ~s(<synthesis-insight action="task" confidence="high" target="#{project.id}" addressee="#{member.email}">
        Rotate the deploy key.
        </synthesis-insight>)
        )

      assert task.tier == "needs_call"

      page_before = page_state(key)
      tasks_before = Repo.aggregate(Task, :count)
      late = DateTime.add(edit.expires_at, 1, :second)

      # The admin approves after the TTL: nothing runs.
      assert {:error, :expired} = Insights.act(edit, scope(admin), now: late)
      assert {:error, :expired} = Insights.act(task, scope(admin), now: late)
      # At the boundary itself, too.
      assert {:error, :expired} = Insights.act(edit, scope(admin), now: edit.expires_at)
      assert page_state(key) == page_before
      assert Repo.aggregate(Task, :count) == tasks_before

      # The same, with the clock really past the TTL and the row not yet purged.
      Repo.update_all(from(i in Insight, where: i.id in ^[edit.id, task.id]),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert {:error, :expired} = Insights.act(edit.id, scope(admin))
      assert {:error, :expired} = Insights.act(task.id, scope(admin))
      assert page_state(key) == page_before
      assert Repo.aggregate(Task, :count) == tasks_before

      # Gone (purged) is expired as well.
      assert {:error, :expired} = Insights.act(Ecto.UUID.generate(), scope(admin))

      # Control: inside the TTL the same admin click executes both.
      Repo.update_all(from(i in Insight, where: i.id in ^[edit.id, task.id]),
        set: [expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)]
      )

      assert {:ok, _} = Insights.act(edit.id, scope(admin))
      assert {:ok, _} = Insights.act(task.id, scope(admin))
      assert Wiki.get_page(key).content == "Keep this."
      assert Repo.aggregate(Task, :count) == tasks_before + 1
    end
  end

  describe "task" do
    test "task filing outside the actor's fence is :not_found" do
      s = tenant_org_id("act_s_#{n()}")
      fenced = member!(s)
      {:ok, own} = Platform.Tasks.create_project(%{name: "own-#{n()}", org_id: s})

      {:ok, foreign} =
        Platform.Tasks.create_project(%{name: "foreign-#{n()}", org_id: acme_org_id()})

      # A project-namespace journal: the insights belong to the fenced org.
      journal = "project/#{own.id}/journal/2026-10-18.md"

      outside =
        ingest!(
          ~s(<synthesis-insight action="task" confidence="high" target="#{foreign.id}">
          File the deploy-key rotation.
          </synthesis-insight>),
          journal
        )

      assert outside.org_id == s
      tasks_before = Repo.aggregate(Task, :count)
      assert {:error, :not_found} = Insights.act(outside, scope(fenced))
      assert Repo.aggregate(Task, :count) == tasks_before
      assert %Insight{state: "open"} = Repo.get!(Insight, outside.id)

      # A project id that does not exist reads the same.
      missing =
        ingest!(
          ~s(<synthesis-insight action="task" confidence="high" target="#{Ecto.UUID.generate()}">
          File something else.
          </synthesis-insight>),
          journal
        )

      assert {:error, :not_found} = Insights.act(missing, scope(fenced))

      # Control: inside the fence the task is filed, sponsored by the addressee.
      inside =
        ingest!(
          ~s(<synthesis-insight action="task" confidence="high" target="#{own.id}">
          Rotate the deploy key on the build box.
          </synthesis-insight>),
          journal
        )

      {:ok, inside} = Insights.reroute(inside, scope(fenced), fenced.email)
      assert inside.addressee_user_id == fenced.id
      assert inside.addressee_reason == "rerouted by #{fenced.name}"
      assert inside.tier == "reversible"

      assert {:ok, %Insight{state: "done", artefact_ref: "task:" <> task_id}} =
               Insights.act(inside, scope(fenced))

      filed = Repo.get!(Task, task_id)
      assert filed.project_id == own.id
      assert filed.sponsor_user_id == fenced.id
      assert filed.title == "Rotate the deploy key on the build box."
    end
  end

  describe "reroute and dismiss" do
    test "reroute to someone unknown is :not_found; dismiss closes without a verdict", %{
      member: member
    } do
      insight =
        ingest!(~s(<synthesis-insight action="question" confidence="high">
        Who owns the staging bucket?
        </synthesis-insight>))

      assert {:error, :not_found} = Insights.reroute(insight, scope(member), "nobody-#{n()}")

      assert {:ok, %Insight{state: "dismissed"}} = Insights.dismiss(insight, scope(member))
      assert Repo.aggregate(Platform.Memory.InsightVerdict, :count) == 0
      assert {:error, :not_open} = Insights.dismiss(insight, scope(member))
    end

    # Stage 4 executes question and briefing acts (delivery into the
    # addressee's briefing, see answer_test.exs); an unrouted one has no one
    # to deliver to, and nothing is delivered.
    test "an unrouted question act has no addressee to deliver to", %{member: member} do
      insight =
        ingest!(~s(<synthesis-insight action="question" confidence="high">
        Who owns the CI runners?
        </synthesis-insight>))

      assert {:error, :no_addressee} = Insights.act(insight, scope(member))
      assert Repo.aggregate(Platform.Memory.Briefing, :count) == 0
    end
  end

  describe "edit" do
    test "edit replaces the hunks and re-runs the tier", %{member: member} do
      {key, _page} = page!("Deploys go to hive every night.", member)
      insight = ingest!(edit_block(key, "go to hive", "go to moon"))

      {:ok, edited} =
        Insights.edit(insight, scope(member), %{
          "hunks" => [%{"old" => "Deploys go to hive every night.", "new" => ""}]
        })

      assert edited.tier == "needs_call"
      assert {:error, :unauthorized} = Insights.act(edited, scope(member))

      {:ok, edited} =
        Insights.edit(edited, scope(root_admin!()), %{
          "hunks" => [%{"old" => "go to hive", "new" => "go to rock"}]
        })

      assert edited.tier == "reversible"
      assert {:ok, _} = Insights.act(edited, scope(member))
      assert Wiki.get_page(key).content == "Deploys go to rock every night."
    end
  end

  # Task 01a13867 stage 6: a subscriber re-reads the row from another
  # process, so the :acted broadcast must leave after the commit. Under the
  # test sandbox another process's read waits for the transaction to end,
  # so only `in_transaction?` at broadcast time can tell the two apart.
  describe "acted broadcasts (stage 6)" do
    defp capture_broadcasts!(insight_id) do
      test_pid = self()
      handler_id = "stage6-act-broadcasts-#{n()}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :memory_insights, :broadcast],
          fn _event, _measurements, meta, _config ->
            if meta.insight_id == insight_id,
              do: send(test_pid, {:insight_broadcast, meta.event, meta.in_transaction?})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "a page_edit act broadcasts :acted after its transaction commits", %{member: member} do
      {key, _page} = page!("Deploys go to hive every night.", member)
      insight = ingest!(edit_block(key, "go to hive", "go to moon"))
      capture_broadcasts!(insight.id)

      assert {:ok, %Insight{state: "done"}} = Insights.act(insight, scope(member))
      assert_received {:insight_broadcast, :acted, false}
      refute_received {:insight_broadcast, _event, true}
    end

    test "a task act broadcasts :acted after its transaction commits" do
      s = tenant_org_id("act_s6_#{n()}")
      fenced = member!(s)
      {:ok, own} = Platform.Tasks.create_project(%{name: "own-s6-#{n()}", org_id: s})

      inside =
        ingest!(
          ~s(<synthesis-insight action="task" confidence="high" target="#{own.id}">
          Rotate the deploy key on the stage-6 box.
          </synthesis-insight>),
          "project/#{own.id}/journal/2026-10-18.md"
        )

      {:ok, inside} = Insights.reroute(inside, scope(fenced), fenced.email)
      capture_broadcasts!(inside.id)

      assert {:ok, %Insight{state: "done", artefact_ref: "task:" <> _}} =
               Insights.act(inside, scope(fenced))

      assert_received {:insight_broadcast, :acted, false}
      refute_received {:insight_broadcast, _event, true}
    end
  end
end
