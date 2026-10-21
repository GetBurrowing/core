defmodule Platform.Memory.Insights.BriefingsViewTest do
  @moduledoc """
  Task 01a15ee1 stage 3: the Inbox briefing's view model
  (`Briefings.view/2`), its verbs (`Briefings.handle/5`) and their
  persistent inverses (`Briefings.undo/3`).

  Every verb test reads the receipt back from the row AND the effect from
  its own table (page, task, journal, verdict), and every inverse reads the
  effect undone. Authority comes from the briefing row: a key not in
  `items` is `:not_found` and a clicker who is not the row's user is
  `:unauthorized`.

  Mutation probe: letting `handle/5` take the insight id from `params`
  (`params["insight_id"] || insight_id(briefing, key)`) turns "a forged key
  cannot reach an insight outside the row, whatever params say" red.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.InsightFixtures
  import Platform.TenancyFixtures

  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Inbox
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Memory.Insights.Briefings
  alias Platform.Memory.InsightVerdict
  alias Platform.Org.Wiki
  alias Platform.Org.WikiJournalEntry, as: JournalEntry
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  defp n, do: System.unique_integer([:positive])

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))

  defp key(insight), do: BriefingCard.node_key(insight.id)

  defp briefing!(user, insights, receipts \\ %{}) do
    Repo.insert!(%Briefing{
      user_id: user.id,
      digest_date: ~D[2026-10-21],
      items: Map.new(insights, &{key(&1), &1.id}),
      receipts: receipts
    })
  end

  defp reload(%Briefing{id: id}), do: Repo.get!(Briefing, id)
  defp reload(%Insight{id: id}), do: Repo.get!(Insight, id)

  defp page!(content) do
    key = "org/page/brief-view-#{n()}.md"
    {:ok, page} = Wiki.upsert_page(key, %{content: content})
    {key, page}
  end

  defp page_edit!(owner, key, old, new) do
    insight!(
      addressee: owner,
      action_type: "page_edit",
      action: %{"target" => key, "hunks" => [%{"old" => old, "new" => new}]}
    )
  end

  defp two_projects! do
    {:ok, a} = Tasks.create_project(%{name: "brief-a-#{n()}", org_id: acme_org_id()})
    {:ok, b} = Tasks.create_project(%{name: "brief-b-#{n()}", org_id: acme_org_id()})
    {a, b}
  end

  defp task_insight!(owner, action \\ %{}),
    do:
      insight!(
        addressee: owner,
        action_type: "task",
        body: "Rotate the key #{n()}",
        action: action
      )

  defp section_keys(view, section), do: Enum.map(Map.fetch!(view, section), & &1.key)

  setup do
    owner = person!()
    %{owner: owner}
  end

  # ── owner-scoped reads (task 01a15ee1 stage 5) ─────────────────────────

  describe "get_for_user/2 and list_for_user/2" do
    test "the owner reads their own briefing", %{owner: owner} do
      briefing = briefing!(owner, [insight!(addressee: owner)])

      assert %Briefing{id: id} = Briefings.get_for_user(briefing.id, owner.id)
      assert id == briefing.id
      assert %{^id => %Briefing{}} = Briefings.list_for_user([briefing.id], owner.id)
    end

    test "another user's briefing id reads as nothing", %{owner: owner} do
      briefing = briefing!(owner, [insight!(addressee: owner)])
      other = person!()

      assert Briefings.get_for_user(briefing.id, other.id) == nil
      assert Briefings.list_for_user([briefing.id], other.id) == %{}
    end

    test "list_for_user keeps only the caller's rows and skips junk ids", %{owner: owner} do
      mine = briefing!(owner, [insight!(addressee: owner)])
      other = person!()
      theirs = briefing!(other, [insight!(addressee: other)])

      assert Briefings.list_for_user([mine.id, theirs.id, "not-a-uuid", nil], owner.id)
             |> Map.keys() == [mine.id]
    end

    test "malformed or missing ids are nil, not a crash", %{owner: owner} do
      assert Briefings.get_for_user("not-a-uuid", owner.id) == nil
      assert Briefings.get_for_user(Ecto.UUID.generate(), owner.id) == nil
      assert Briefings.get_for_user(nil, owner.id) == nil
      assert Briefings.list_for_user([], owner.id) == %{}
      assert Briefings.list_for_user([Ecto.UUID.generate()], nil) == %{}
    end
  end

  # ── view/2: section rules ──────────────────────────────────────────────

  describe "view/2 sections" do
    test "an open question needs a call", %{owner: owner} do
      q = insight!(addressee: owner, action_type: "question", body: "Which host?")
      view = Briefings.view(briefing!(owner, [q]), scope(owner))

      assert [%{key: k, kind: :question, may_handle?: true, receipt: nil}] = view.needs_call
      assert k == key(q)
      assert view.fyi == [] and view.done == []
      assert view.counts == %{total: 1, open: 1, calls: 1, handled: 0}
      assert view.date == ~D[2026-10-21]
    end

    test "a needs_call-tier briefing line needs a call; a reversible one is FYI", %{owner: owner} do
      call = insight!(addressee: owner, tier: "needs_call")
      fyi = insight!(addressee: owner)
      view = Briefings.view(briefing!(owner, [call, fyi]), scope(owner))

      assert section_keys(view, :needs_call) == [key(call)]
      assert [%{key: fyi_key, kind: :briefing, actions: actions}] = view.fyi
      assert fyi_key == key(fyi)
      assert :got_it in actions
      assert view.counts == %{total: 2, open: 2, calls: 1, handled: 0}
    end

    test "an outside message needs a call, with its email and no draft", %{owner: owner} do
      outside =
        insight!(
          action_type: "question",
          tier: "needs_call",
          action: %{"addressee" => "ana-#{n()}@client.example"}
        )

      view = Briefings.view(briefing!(owner, [outside]), scope(owner))

      assert [%{kind: :outside, email: "ana-" <> _, draft: nil, actions: actions}] =
               view.needs_call

      refute :answer in actions
    end

    test "an unapplied page edit needs a call while apply_page_edits is off", %{owner: owner} do
      {key, _} = page!("Deploys go to host-a.")
      edit = page_edit!(owner, key, "host-a", "host-b")
      view = Briefings.view(briefing!(owner, [edit]), scope(owner))

      assert [%{kind: :page_edit, actions: [:apply, :edit_apply | _]}] = view.needs_call
    end

    test "a task with no inferable project needs a call with project nil", %{owner: owner} do
      _ = two_projects!()
      task = task_insight!(owner)
      view = Briefings.view(briefing!(owner, [task]), scope(owner))

      assert [%{kind: :task, project: nil, actions: [:file | _]}] = view.needs_call
    end

    test "an open task whose project is inferable shows that project", %{owner: owner} do
      {a, _b} = two_projects!()
      task = task_insight!(owner, %{"project_id" => a.id})
      view = Briefings.view(briefing!(owner, [task]), scope(owner))

      assert [%{kind: :task, project: %{id: id, name: name}}] = view.needs_call
      assert id == a.id and name == a.name
    end

    test "an item applied unattended is done with a derived receipt and its own undo verb",
         %{owner: owner} do
      {a, _b} = two_projects!()
      {:ok, task} = Tasks.create_task(%{project_id: a.id, title: "filed #{n()}"})

      auto =
        insight!(
          addressee: owner,
          action_type: "task",
          state: "done",
          artefact_ref: "task:" <> task.id,
          acted_at: DateTime.utc_now(),
          pre_image: %{"unattended" => true, "acting_agent_id" => Ecto.UUID.generate()}
        )

      view = Briefings.view(briefing!(owner, [auto]), scope(owner))

      assert [%{kind: :task, receipt: receipt, project: project, actions: actions}] = view.done
      assert receipt.auto? and receipt.verb == "filed" and receipt.undo == nil
      assert receipt.detail == %{task_id: task.id}
      assert project == %{id: a.id, name: a.name}
      assert actions == [:delete, :move]
      assert view.counts == %{total: 1, open: 0, calls: 0, handled: 1}
    end

    test "a receipt puts an item in done; a purged insight renders from its receipt alone",
         %{owner: owner} do
      kept = insight!(addressee: owner, state: "dismissed")
      gone_id = Ecto.UUID.generate()
      gone_key = BriefingCard.node_key(gone_id)
      unhandled_gone = Ecto.UUID.generate()

      receipts = %{
        key(kept) => %{"verb" => "dismiss", "at" => "2026-10-21T08:00:00Z", "undo" => %{}},
        gone_key => %{
          "verb" => "answer",
          "at" => "2026-10-21T07:30:00Z",
          "ref" => "journal:entry-1",
          "kind" => "question",
          "undo" => %{"verb" => "unanswer"}
        }
      }

      briefing =
        Repo.insert!(%Briefing{
          user_id: owner.id,
          digest_date: ~D[2026-10-21],
          items: %{
            key(kept) => kept.id,
            gone_key => gone_id,
            BriefingCard.node_key(unhandled_gone) => unhandled_gone
          },
          receipts: receipts
        })

      view = Briefings.view(briefing, scope(owner))

      assert [gone, dismissed] = view.done
      assert gone.key == gone_key
      assert gone.insight == nil and gone.kind == :question and gone.may_handle? == false
      assert gone.receipt.detail == %{journal_entry_id: "entry-1"}
      assert dismissed.key == key(kept)
      # The purged insight with no receipt is not rendered.
      assert view.counts == %{total: 2, open: 0, calls: 0, handled: 2}
    end

    test "an item handled elsewhere is not rendered but counts as handled", %{owner: owner} do
      elsewhere = insight!(addressee: owner, state: "dismissed")
      open = insight!(addressee: owner)
      view = Briefings.view(briefing!(owner, [elsewhere, open]), scope(owner))

      assert section_keys(view, :fyi) == [key(open)]
      assert view.done == []
      assert view.counts == %{total: 2, open: 1, calls: 0, handled: 1}
    end

    test "another user sees nothing they may press", %{owner: owner} do
      q = insight!(addressee: owner, action_type: "question")
      other = person!()
      view = Briefings.view(briefing!(owner, [q]), scope(other))
      assert [%{may_handle?: false}] = view.needs_call
    end

    test "view/2 writes nothing", %{owner: owner} do
      q = insight!(addressee: owner, action_type: "question")
      briefing = briefing!(owner, [q])
      before = {reload(briefing), reload(q)}
      _ = Briefings.view(briefing, scope(owner))
      assert {reload(briefing), reload(q)} == before
    end
  end

  # ── handle/5: authority ────────────────────────────────────────────────

  describe "handle/5 authority" do
    test "a key not in briefing.items is :not_found", %{owner: owner} do
      fyi = insight!(addressee: owner)
      briefing = briefing!(owner, [fyi])

      assert {:error, :not_found} =
               Briefings.handle(briefing, "inope", "dismiss", scope(owner), %{})

      assert reload(fyi).state == "open"
      assert reload(briefing).receipts == %{}
    end

    test "a forged key cannot reach an insight outside the row, whatever params say",
         %{owner: owner} do
      mine = insight!(addressee: owner)
      outside_row = insight!(addressee: owner)
      briefing = briefing!(owner, [mine])

      assert {:error, :not_found} =
               Briefings.handle(briefing, key(outside_row), "dismiss", scope(owner), %{
                 "insight_id" => outside_row.id,
                 "id" => outside_row.id
               })

      assert reload(outside_row).state == "open"
      assert reload(briefing).receipts == %{}

      # Positive control: the same clicker dismisses the same insight once it
      # IS in the row.
      other_briefing =
        Repo.insert!(%Briefing{
          user_id: owner.id,
          digest_date: ~D[2026-10-20],
          items: %{key(outside_row) => outside_row.id}
        })

      assert {:ok, _} =
               Briefings.handle(other_briefing, key(outside_row), "dismiss", scope(owner))

      assert reload(outside_row).state == "dismissed"
    end

    test "a clicker who is not briefing.user_id is :unauthorized", %{owner: owner} do
      fyi = insight!(addressee: owner)
      briefing = briefing!(owner, [fyi])
      other = person!()

      assert {:error, :unauthorized} =
               Briefings.handle(briefing, key(fyi), "dismiss", scope(other), %{})

      assert {:error, :unauthorized} = Briefings.undo(briefing, key(fyi), scope(other))
      assert reload(fyi).state == "open"
    end

    test "an unknown verb is :not_supported", %{owner: owner} do
      fyi = insight!(addressee: owner)
      briefing = briefing!(owner, [fyi])
      assert {:error, :not_supported} = Briefings.handle(briefing, key(fyi), "send", scope(owner))
      assert reload(fyi).state == "open"
    end

    test "a failed action writes no receipt and moves nothing", %{owner: owner} do
      q = insight!(addressee: owner, action_type: "question")
      briefing = briefing!(owner, [q])

      assert {:error, :blank} =
               Briefings.handle(briefing, key(q), "answer", scope(owner), %{"answer" => "  "})

      assert reload(q).state == "open"
      assert reload(briefing).receipts == %{}
    end

    test "every handled click broadcasts {:inbox_changed, user_id}", %{owner: owner} do
      fyi = insight!(addressee: owner)
      briefing = briefing!(owner, [fyi])
      Phoenix.PubSub.subscribe(Platform.PubSub, Inbox.topic(owner.id))

      assert {:ok, _} = Briefings.handle(briefing, key(fyi), "got_it", scope(owner))
      owner_id = owner.id
      assert_receive {:inbox_changed, ^owner_id}

      assert {:ok, _} = Briefings.undo(briefing, key(fyi), scope(owner))
      assert_receive {:inbox_changed, ^owner_id}
    end
  end

  # ── handle/5 verbs and undo/3 inverses ─────────────────────────────────

  describe "verbs and inverses" do
    test "answer writes a journal receipt; undo appends a retraction and reopens",
         %{owner: owner} do
      q = insight!(addressee: owner, action_type: "question", body: "Which host serves deploys?")
      briefing = briefing!(owner, [q])

      assert {:ok, updated} =
               Briefings.handle(briefing, key(q), "answer", scope(owner), %{"answer" => "host-b"})

      receipt = updated.receipts[key(q)]
      assert %{"verb" => "answer", "by" => by, "ref" => "journal:" <> entry_id} = receipt
      assert by == owner.id
      assert receipt["undo"] == %{"verb" => "unanswer"}
      assert receipt["kind"] == "question"
      assert is_binary(receipt["at"])
      assert Repo.get!(JournalEntry, entry_id).content =~ "host-b"
      assert reload(q).state == "done"
      assert [%{key: _}] = Briefings.view(updated, scope(owner)).done

      assert {:ok, undone} = Briefings.undo(updated, key(q), scope(owner))
      refute Map.has_key?(undone.receipts, key(q))
      assert %Insight{state: "open", artefact_ref: nil, acted_by: nil} = reload(q)

      # Append-only: the answer stays, and a retraction authored by the
      # clicker follows it.
      assert Repo.get!(JournalEntry, entry_id)

      assert [retraction] =
               Repo.all(
                 from(e in JournalEntry,
                   where: fragment("?->>'source'", e.metadata) == "insight_answer_retracted"
                 )
               )

      assert retraction.content =~ "Retracted answer to: Which host serves deploys?"
      assert retraction.authored_by == owner.id
    end

    test "reroute stores the previous addressee; undo routes it back", %{owner: owner} do
      fyi = insight!(addressee: owner)
      target = person!()
      briefing = briefing!(owner, [fyi])

      assert {:ok, updated} =
               Briefings.handle(briefing, key(fyi), "reroute", scope(owner), %{
                 "addressee" => target.email
               })

      receipt = updated.receipts[key(fyi)]
      assert receipt["verb"] == "reroute"
      assert receipt["ref"] == "user:" <> target.id
      assert receipt["name"] == target.name
      assert receipt["previous"] == owner.id
      assert receipt["undo"] == %{"verb" => "reroute", "addressee" => owner.id}
      assert reload(fyi).addressee_user_id == target.id

      [done] = Briefings.view(updated, scope(owner)).done
      assert done.receipt.detail == %{user_id: target.id, name: target.name, previous: owner.id}

      assert {:ok, _} = Briefings.undo(updated, key(fyi), scope(owner))
      assert reload(fyi).addressee_user_id == owner.id
    end

    test "apply writes the page with a page receipt; undo reverts it", %{owner: owner} do
      {page_key, page} = page!("Deploys go to host-a.")
      edit = page_edit!(owner, page_key, "host-a", "host-b")
      briefing = briefing!(owner, [edit])

      assert {:ok, updated} = Briefings.handle(briefing, key(edit), "apply", scope(owner))

      receipt = updated.receipts[key(edit)]
      written = Wiki.get_page(page_key)
      assert written.content == "Deploys go to host-b."
      assert receipt["verb"] == "apply"
      assert receipt["ref"] == "page:#{page_key}@v#{written.version}"
      assert receipt["undo"] == %{"verb" => "revert"}

      [done] = Briefings.view(updated, scope(owner)).done
      assert done.receipt.detail == %{path: page_key, version: written.version}

      assert {:ok, _} = Briefings.undo(updated, key(edit), scope(owner))
      assert Wiki.get_page(page_key).content == page.content
      assert reload(edit).state == "open"
    end

    test "edit_apply edits the hunks and applies them", %{owner: owner} do
      {page_key, _} = page!("Deploys go to host-a.")
      edit = page_edit!(owner, page_key, "host-a", "host-b")
      briefing = briefing!(owner, [edit])

      assert {:ok, updated} =
               Briefings.handle(briefing, key(edit), "edit_apply", scope(owner), %{
                 "hunks" => [%{"old" => "host-a", "new" => "host-c"}]
               })

      assert Wiki.get_page(page_key).content == "Deploys go to host-c."
      assert updated.receipts[key(edit)]["verb"] == "edit_apply"
      assert updated.receipts[key(edit)]["undo"] == %{"verb" => "revert"}

      assert {:ok, _} = Briefings.undo(updated, key(edit), scope(owner))
      assert Wiki.get_page(page_key).content == "Deploys go to host-a."
    end

    test "file files into the picked project under the given title; undo deletes it",
         %{owner: owner} do
      {_a, b} = two_projects!()
      task = task_insight!(owner)
      briefing = briefing!(owner, [task])

      assert {:error, :no_project} = Briefings.handle(briefing, key(task), "file", scope(owner))
      assert reload(briefing).receipts == %{}

      assert {:ok, updated} =
               Briefings.handle(briefing, key(task), "file", scope(owner), %{
                 "project_id" => b.id,
                 "title" => "Rotate the build key"
               })

      receipt = updated.receipts[key(task)]
      assert %{"verb" => "file", "ref" => "task:" <> task_id} = receipt
      assert receipt["project_id"] == b.id
      assert receipt["undo"] == %{"verb" => "delete"}
      filed = Repo.get!(Task, task_id)
      assert filed.project_id == b.id
      assert filed.title == "Rotate the build key"

      [done] = Briefings.view(updated, scope(owner)).done
      assert done.project == %{id: b.id, name: b.name}
      assert done.actions == [:undo, :move]

      assert {:ok, _} = Briefings.undo(updated, key(task), scope(owner))
      assert %Task{deleted_at: %DateTime{}} = Repo.get!(Task, task_id)
      assert reload(task).state == "open"
    end

    test "a project uuid the clicker cannot reach passes :not_found through", %{owner: owner} do
      task = task_insight!(owner)
      briefing = briefing!(owner, [task])

      assert {:error, :not_found} =
               Briefings.handle(briefing, key(task), "file", scope(owner), %{
                 "project_id" => Ecto.UUID.generate()
               })
    end

    test "move moves the filed task and keeps the filing receipt; undo moves it back",
         %{owner: owner} do
      {a, b} = two_projects!()
      task = task_insight!(owner)
      briefing = briefing!(owner, [task])

      {:ok, filed} =
        Briefings.handle(briefing, key(task), "file", scope(owner), %{"project_id" => a.id})

      file_receipt = filed.receipts[key(task)]
      "task:" <> task_id = file_receipt["ref"]

      assert {:ok, moved} =
               Briefings.handle(briefing, key(task), "move", scope(owner), %{"project_id" => b.id})

      receipt = moved.receipts[key(task)]
      assert receipt["verb"] == "move"
      assert receipt["ref"] == "project:" <> b.id
      assert receipt["task_id"] == task_id
      assert receipt["undo"] == %{"verb" => "move", "project_id" => a.id}
      assert receipt["prev"] == file_receipt
      assert Repo.get!(Task, task_id).project_id == b.id

      assert {:ok, back} = Briefings.undo(moved, key(task), scope(owner))
      assert Repo.get!(Task, task_id).project_id == a.id
      assert back.receipts[key(task)] == file_receipt
    end

    test "got_it confirms the line; undo restores it", %{owner: owner} do
      fyi = insight!(addressee: owner)
      briefing = briefing!(owner, [fyi])

      assert {:ok, updated} = Briefings.handle(briefing, key(fyi), "got_it", scope(owner))

      assert %{"verb" => "got_it", "ref" => nil, "undo" => %{"verb" => "restore"}} =
               updated.receipts[key(fyi)]

      assert reload(fyi).state == "done"

      assert {:ok, _} = Briefings.undo(updated, key(fyi), scope(owner))
      assert %Insight{state: "open", acted_by: nil} = reload(fyi)
      assert section_keys(Briefings.view(reload(briefing), scope(owner)), :fyi) == [key(fyi)]
    end

    test "dismiss dismisses; undo restores", %{owner: owner} do
      fyi = insight!(addressee: owner)
      briefing = briefing!(owner, [fyi])

      assert {:ok, updated} = Briefings.handle(briefing, key(fyi), "dismiss", scope(owner))
      assert updated.receipts[key(fyi)]["undo"] == %{"verb" => "restore"}
      assert reload(fyi).state == "dismissed"

      assert {:ok, _} = Briefings.undo(updated, key(fyi), scope(owner))
      assert reload(fyi).state == "open"
    end

    test "not_useful keeps the verdict id; undo deletes exactly that verdict and reopens",
         %{owner: owner} do
      fyi = insight!(addressee: owner)
      briefing = briefing!(owner, [fyi])

      assert {:error, :blank} = Briefings.handle(briefing, key(fyi), "not_useful", scope(owner))

      assert {:ok, updated} =
               Briefings.handle(briefing, key(fyi), "not_useful", scope(owner), %{
                 "reason" => "already known"
               })

      receipt = updated.receipts[key(fyi)]
      assert %{"ref" => "verdict:" <> verdict_id} = receipt
      assert receipt["undo"] == %{"verb" => "restore", "verdict_id" => verdict_id}

      assert %InsightVerdict{kind: "rejected", reason: "already known"} =
               Repo.get!(InsightVerdict, verdict_id)

      assert reload(fyi).state == "dismissed"

      assert {:ok, _} = Briefings.undo(updated, key(fyi), scope(owner))
      assert Repo.get(InsightVerdict, verdict_id) == nil
      assert reload(fyi).state == "open"
    end

    test "revert has no inverse", %{owner: owner} do
      {page_key, page} = page!("Deploys go to host-a.")
      edit = page_edit!(owner, page_key, "host-a", "host-b")
      {:ok, _} = Insights.act(edit, scope(owner))
      briefing = briefing!(owner, [edit])

      assert {:ok, updated} = Briefings.handle(briefing, key(edit), "revert", scope(owner))
      assert Wiki.get_page(page_key).content == page.content
      assert %{"verb" => "revert", "undo" => nil} = updated.receipts[key(edit)]
      assert updated.receipts[key(edit)]["ref"] == "page:" <> page_key

      assert {:error, :no_inverse} = Briefings.undo(updated, key(edit), scope(owner))
      assert Wiki.get_page(page_key).content == page.content
      assert [%{actions: []}] = Briefings.view(updated, scope(owner)).done
    end

    test "delete has no inverse", %{owner: owner} do
      {a, _b} = two_projects!()
      task = task_insight!(owner, %{"project_id" => a.id})
      {:ok, acted} = Insights.act(task, scope(owner))
      "task:" <> task_id = acted.artefact_ref
      briefing = briefing!(owner, [task])

      assert {:ok, updated} = Briefings.handle(briefing, key(task), "delete", scope(owner))
      assert %Task{deleted_at: %DateTime{}} = Repo.get!(Task, task_id)
      assert %{"verb" => "delete", "ref" => ref, "undo" => nil} = updated.receipts[key(task)]
      assert ref == "task:" <> task_id

      assert {:error, :no_inverse} = Briefings.undo(updated, key(task), scope(owner))
    end

    test "undo of an item with no receipt is :not_found", %{owner: owner} do
      fyi = insight!(addressee: owner)
      briefing = briefing!(owner, [fyi])
      assert {:error, :not_found} = Briefings.undo(briefing, key(fyi), scope(owner))
    end
  end

  describe "Insights.restore/3 and Actions.unanswer/3 authority" do
    test "restore of Got it is the presser's alone", %{owner: owner} do
      fyi = insight!(addressee: owner)
      {:ok, _} = Insights.looks_right(fyi, scope(owner))
      other = person!()

      assert {:error, :unauthorized} = Insights.restore(fyi, scope(other))
      assert reload(fyi).state == "done"
      assert {:ok, %Insight{state: "open"}} = Insights.restore(fyi, scope(owner))
    end

    test "restore refuses a verdict id that is not this clicker's rejection", %{owner: owner} do
      fyi = insight!(addressee: owner)
      {:ok, _} = Platform.Memory.Insights.Actions.reject(fyi, scope(owner), "nope")
      other_verdict = Platform.Memory.Insights.Actions.latest_rejection_id(fyi, owner.id)
      other = person!()

      assert {:error, :not_found} =
               Insights.restore(fyi, scope(other), verdict_id: other_verdict)

      assert Repo.get(InsightVerdict, other_verdict)
      assert reload(fyi).state == "dismissed"
    end

    test "restore does not reopen an acted page edit", %{owner: owner} do
      {page_key, _} = page!("Deploys go to host-a.")
      edit = page_edit!(owner, page_key, "host-a", "host-b")
      {:ok, _} = Insights.act(edit, scope(owner))

      assert {:error, :not_revertible} = Insights.restore(edit, scope(owner))
      assert reload(edit).state == "done"
    end

    test "unanswer is the answerer's alone", %{owner: owner} do
      q = insight!(addressee: owner, action_type: "question")
      {:ok, _} = Insights.answer(q, scope(owner), "yes")
      other = person!()

      assert {:error, :unauthorized} =
               Platform.Memory.Insights.Actions.unanswer(q, scope(other))

      assert reload(q).state == "done"
    end
  end
end
