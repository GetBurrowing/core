defmodule PlatformWeb.InboxLive.BriefingCopyTest do
  @moduledoc """
  Task 01a15ee1 stage 5: the briefing detail's copy is pure functions of
  the view model, so a later list renderer can call them as they are.
  Strings are the stage 5 fidelity inventory's, verbatim.
  """
  use ExUnit.Case, async: true

  alias PlatformWeb.InboxLive.BriefingCopy, as: Copy

  defp receipt(verb, attrs \\ %{}) do
    Map.merge(
      %{verb: verb, at: "2026-10-21T13:05:00Z", undo: nil, auto?: false, detail: %{}},
      attrs
    )
  end

  defp done(kind, receipt, attrs \\ %{}) do
    Map.merge(%{kind: kind, receipt: receipt, project: nil, actions: []}, attrs)
  end

  test "header and progress" do
    assert Copy.header(~D[2026-10-21], ~D[2026-10-21]) == %{
             title: "Today's briefing",
             meta: "Wed, Oct 21 · prepared from yesterday's journals and chat"
           }

    assert Copy.header(~D[2026-10-20], ~D[2026-10-21]).title == "Briefing · Tue, Oct 20"
    assert Copy.progress(%{total: 5, open: 4, handled: 1}).label == "1 of 5 handled"

    assert Copy.progress(%{total: 5, open: 0, handled: 5}).label ==
             "5 of 5 handled · you're clear for today"

    assert Copy.progress(%{total: 0, open: 0, handled: 0}).label == "0 of 0 handled"
  end

  test "section headings and kind tags" do
    assert Copy.section_heading(:needs_call, 3) == "Needs your call · 3"
    assert Copy.section_heading(:fyi, 2) == "For your information · 2"
    assert Copy.section_heading(:done, 4) == "Done today · 4"

    assert Copy.kind_tag(:question) == %{label: "Question", class: "bg-warning-dim"}
    assert Copy.kind_tag(:page_edit) == %{label: "Page edit", class: "bg-info-dim"}
    assert Copy.kind_tag(:task) == %{label: "Task", class: "bg-success-dim"}
    assert Copy.kind_tag(:briefing) == %{label: "FYI", class: "bg-base-300"}
    assert Copy.kind_tag(:outside) == %{label: "Email draft", class: "bg-base-300"}
  end

  test "receipt lines and their way back" do
    answered =
      done(:question, receipt("answer", %{undo: %{"verb" => "unanswer"}}), %{actions: [:undo]})

    assert %{
             verb: "✓ Answered",
             rest: " · saved to org memory",
             link: {"View", "/org_memory/org/journal/2026-10-21.md"},
             inverses: [%{label: "Undo answer", action: :undo}]
           } = Copy.receipt(answered)

    applied =
      done(
        :page_edit,
        receipt("applied", %{auto?: true, detail: %{path: "org/page/brand.md", version: 24}}),
        %{actions: [:revert]}
      )

    assert %{
             verb: "✓ Applied",
             rest: " · org/page/brand.md v24",
             link: {"Open page", "/org_memory/org/page/brand.md"},
             inverses: [%{label: "Revert", action: :revert, tone: :link}]
           } = Copy.receipt(applied)

    filed =
      done(:task, receipt("file", %{undo: %{"verb" => "delete"}, detail: %{task_id: "t1"}}), %{
        project: %{id: "p1", name: "Core"},
        actions: [:undo, :move]
      })

    assert %{
             verb: "✓ Task filed",
             rest: " in Core",
             link: {"Open task", "/tasks/t1"},
             inverses: [
               %{label: "Delete", tone: :error, action: :undo},
               %{label: "Move to another project", action: :move}
             ]
           } = Copy.receipt(filed)

    moved =
      done(:task, receipt("move", %{undo: %{"verb" => "move"}, detail: %{task_id: "t1"}}), %{
        project: %{id: "p2", name: "Ops"},
        actions: [:undo, :move]
      })

    assert [%{label: "Move back"}, %{label: "Move to another project"}] =
             Copy.receipt(moved).inverses

    rerouted = done(:question, receipt("reroute", %{detail: %{name: "Alex Doe"}}))

    assert %{icon: :reroute, verb: "Sent to Alex Doe", rest: " · it'll be in their briefing"} =
             Copy.receipt(rerouted)

    restore = %{"verb" => "restore"}
    assert Copy.receipt(done(:briefing, receipt("got_it", %{undo: restore}))).verb == "✓ Seen"

    assert [%{label: "Restore"}] =
             Copy.receipt(
               done(:briefing, receipt("dismiss", %{undo: restore}), %{actions: [:undo]})
             ).inverses

    assert Copy.receipt(done(:briefing, receipt("not_useful"))) |> Map.take([:verb, :rest]) ==
             %{verb: "Marked not useful", rest: " · dreaming will learn from it"}
  end

  test "toasts; Revert and Delete carry no Undo" do
    assert Copy.toast("answer", %{}) == %{message: "Answer sent", undo?: true}
    assert Copy.toast("reroute", %{name: "Sam"}).message == "Rerouted to Sam"

    assert Copy.toast("apply", %{kind: :page_edit, path: "org/page/a.md"}).message ==
             "Edit applied to org/page/a.md"

    assert Copy.toast("edit_apply", %{}).message == "Your version applied"
    assert Copy.toast("file", %{project_name: "Ops"}).message == "Task filed in Ops"
    assert Copy.toast("got_it", %{}).message == "Marked as seen"
    assert Copy.toast("dismiss", %{}).message == "Dismissed"
    assert Copy.toast("not_useful", %{}).message == "Thanks, dreaming will learn from that"
    assert Copy.toast("revert", %{}).undo? == false
    assert Copy.toast("delete", %{}).undo? == false
  end

  test "errors stay on the card in words" do
    assert Copy.error_text("file", :boom) == "Couldn't file the task. Try again."
    assert Copy.error_text("file", :no_project) == "Pick a project to file this."
    assert Copy.error_text(:undo, :boom) == "Couldn't undo that. Try again."
  end

  test "outside card and settings note" do
    assert Copy.outside_to("ana@client.example") == "To: ana@client.example (outside your org)"
    assert Copy.mail_off() == "Email wasn't set up yet, so nothing was drafted or sent."
    assert Copy.draft_path(%{id: "d1"}) == "/email/drafts/d1"
    assert Copy.draft_path(nil) == nil

    note =
      Copy.settings_note(%{apply_page_edits: true, file_tasks: true, deliver_questions: false})

    assert note.lead ==
             "Briefings arrive in your Inbox each morning. Items you don't handle expire after 7 days."

    assert note.flags == " · deliver at 7:00 · include page edits ✓ · tasks ✓ · questions ✗"
  end

  test "title_and_body splits the first sentence off" do
    assert Copy.title_and_body(%{body: "Move to a paid plan? Both slots are taken."}) ==
             {"Move to a paid plan?", "Both slots are taken."}

    assert Copy.title_and_body(%{body: "One line only"}) == {"One line only", nil}
  end
end
