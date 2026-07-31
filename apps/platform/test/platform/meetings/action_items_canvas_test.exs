defmodule Platform.Meetings.ActionItemsCanvasTest do
  @moduledoc """
  Tests for `Platform.Meetings.ActionItemsCanvas` (task 019fb90f-36e3
  stage 2 — the READ half; stage 4 adds `create/3` + `apply_operations/2`).

  The load-bearing tests here are the NEGATIVE controls. `locate/2` is
  a filter over every canvas in a space, and a filter that has stopped
  filtering still returns a canvas for the happy path — so a positive
  control on its own cannot tell "found the right one" from "returned
  the first one it saw". Both discriminating cases (right meeting /
  wrong source, right source / wrong meeting) are asserted, because
  dropping either half of the `and` leaves the other test green.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Meetings.ActionItemsCanvas
  alias Platform.Orchestration.ExecutionSpace

  defp create_space! do
    {:ok, space} = Chat.create_space(%{kind: "execution"})
    ExecutionSpace.ensure_system_participant(space.id)
    space
  end

  defp participant_id(space_id) do
    {:ok, participant} = ExecutionSpace.ensure_system_participant(space_id)
    participant.id
  end

  defp checklist_document(items, opts \\ []) do
    revision = Keyword.get(opts, :revision, 1)

    %{
      "version" => 1,
      "revision" => revision,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "children" => [
          %{
            "id" => "checklist-1",
            "type" => "checklist",
            "props" => %{"title" => "Action Items"},
            "children" =>
              Enum.map(items, fn {node_id, label, state} ->
                %{
                  "id" => node_id,
                  "type" => "checklist_item",
                  "props" => %{"label" => label, "state" => state}
                }
              end)
          }
        ]
      }
    }
  end

  defp create_canvas!(space, metadata, opts \\ []) do
    document = Keyword.get(opts, :document, checklist_document([]))

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant_id(space.id),
        "title" => Keyword.get(opts, :title, "Action Items"),
        "document" => document,
        "metadata" => metadata
      })

    canvas
  end

  defp ours(meeting_id), do: ActionItemsCanvas.metadata_for(meeting_id)

  describe "locate/2" do
    test "finds the canvas stamped with this meeting's source + meeting_id" do
      space = create_space!()
      meeting_id = Ecto.UUID.generate()
      canvas = create_canvas!(space, ours(meeting_id))

      assert {:ok, found} = ActionItemsCanvas.locate(space.id, meeting_id)
      assert found.id == canvas.id
    end

    test "a space with no action-items canvas is :missing, not an error" do
      space = create_space!()

      assert :missing = ActionItemsCanvas.locate(space.id, Ecto.UUID.generate())
    end

    test "NEGATIVE CONTROL: a canvas in the SAME space with a different source is not returned" do
      # Without this, `locate/2` could ignore `metadata[\"source\"]`
      # entirely and every positive assertion above would still pass —
      # and the handler would happily reconcile action items onto the
      # scribe's summary canvas.
      space = create_space!()
      meeting_id = Ecto.UUID.generate()

      scribe =
        create_canvas!(
          space,
          %{"source" => "meeting_scribe", "meeting_id" => meeting_id},
          title: "Meeting Summary"
        )

      assert :missing = ActionItemsCanvas.locate(space.id, meeting_id)

      # And prove the row is genuinely there — otherwise this test would
      # also pass against an empty space, which proves nothing.
      assert Enum.any?(Chat.list_canvases(space.id), &(&1.id == scribe.id))
    end

    test "NEGATIVE CONTROL: the right source for a DIFFERENT meeting is not returned" do
      # The other half of the `and`. Two meetings can share a chat space
      # (a recurring standup in a team space), and returning the last
      # meeting's canvas would silently merge two meetings' action items.
      space = create_space!()
      other_meeting_id = Ecto.UUID.generate()
      this_meeting_id = Ecto.UUID.generate()

      other = create_canvas!(space, ours(other_meeting_id))

      assert :missing = ActionItemsCanvas.locate(space.id, this_meeting_id)
      assert Enum.any?(Chat.list_canvases(space.id), &(&1.id == other.id))

      # And the same call for the meeting that DOES own it still finds it,
      # so the refusal above is a filter and not a broken read.
      assert {:ok, found} = ActionItemsCanvas.locate(space.id, other_meeting_id)
      assert found.id == other.id
    end

    test "a canvas in a DIFFERENT space is not returned" do
      meeting_id = Ecto.UUID.generate()
      space_a = create_space!()
      space_b = create_space!()

      canvas = create_canvas!(space_a, ours(meeting_id))

      assert {:ok, ^canvas} = fetch(space_a.id, meeting_id, canvas)
      assert :missing = ActionItemsCanvas.locate(space_b.id, meeting_id)
    end

    test "most-recent wins when a space holds two canvases for one meeting" do
      space = create_space!()
      meeting_id = Ecto.UUID.generate()

      _first = create_canvas!(space, ours(meeting_id), title: "First")
      second = create_canvas!(space, ours(meeting_id), title: "Second")

      assert {:ok, found} = ActionItemsCanvas.locate(space.id, meeting_id)
      assert found.id == second.id
      assert found.title == "Second"
    end

    test "a soft-deleted canvas is not returned" do
      space = create_space!()
      meeting_id = Ecto.UUID.generate()
      canvas = create_canvas!(space, ours(meeting_id))

      {:ok, _} = Chat.delete_canvas(canvas)

      assert :missing = ActionItemsCanvas.locate(space.id, meeting_id)
    end

    test "blank or nil identifiers are :missing rather than a crash" do
      space = create_space!()

      assert :missing = ActionItemsCanvas.locate(nil, Ecto.UUID.generate())
      assert :missing = ActionItemsCanvas.locate(space.id, nil)
      assert :missing = ActionItemsCanvas.locate("", "")
      assert :missing = ActionItemsCanvas.locate(nil, nil)
    end
  end

  describe "metadata_for/1" do
    test "produces exactly the keys locate/2 filters on" do
      # The writer/reader drift guard. Stage 4's `create/3` stamps this
      # map; if the two ever disagree, every canvas would be created
      # successfully and then never found again — silently, forever.
      meeting_id = Ecto.UUID.generate()
      metadata = ActionItemsCanvas.metadata_for(meeting_id)

      assert metadata == %{
               "source" => ActionItemsCanvas.metadata_source(),
               "meeting_id" => meeting_id
             }

      space = create_space!()
      canvas = create_canvas!(space, metadata)

      assert {:ok, found} = ActionItemsCanvas.locate(space.id, meeting_id)
      assert found.id == canvas.id
    end
  end

  describe "summarize/1" do
    test "walks checklist_item children out of a nested document" do
      space = create_space!()
      meeting_id = Ecto.UUID.generate()

      document =
        checklist_document([
          {"item-1", "Priya reverts the onboarding flow by Friday", "pending"},
          {"item-2", "Alex emails the deploy audit", "complete"}
        ])

      canvas = create_canvas!(space, ours(meeting_id), document: document)

      assert [first, second] = ActionItemsCanvas.summarize(canvas)

      assert first == %{
               node_id: "item-1",
               label: "Priya reverts the onboarding flow by Friday",
               state: "pending"
             }

      assert second == %{
               node_id: "item-2",
               label: "Alex emails the deploy audit",
               state: "complete"
             }
    end

    test "an item with no state prop reads as pending, matching the rendered counter" do
      # `Kinds.Checklist` counts `state == \"complete\"` and nothing else,
      # so a stateless item renders as incomplete. Reporting it as
      # anything but pending would put the prompt and the canvas at odds.
      document = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "checklist",
          "children" => [
            %{"id" => "item-1", "type" => "checklist_item", "props" => %{"label" => "No state"}}
          ]
        }
      }

      assert [%{node_id: "item-1", label: "No state", state: "pending"}] =
               ActionItemsCanvas.summarize(document)
    end

    test "ignores nodes that are not checklist_item children of a checklist" do
      # A `checklist_item` outside a checklist is not a rendered action
      # item, and a heading inside one is not an item at all. Both would
      # otherwise be handed to the model as things it can reconcile.
      document = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "children" => [
            %{"id" => "h", "type" => "heading", "props" => %{"value" => "Notes", "level" => 2}},
            %{
              "id" => "stray",
              "type" => "checklist_item",
              "props" => %{"label" => "Not in list"}
            },
            %{
              "id" => "list",
              "type" => "checklist",
              "children" => [
                %{"id" => "nope", "type" => "text", "props" => %{"value" => "filler"}},
                %{"id" => "yes", "type" => "checklist_item", "props" => %{"label" => "Real item"}}
              ]
            }
          ]
        }
      }

      assert [%{node_id: "yes", label: "Real item"}] = ActionItemsCanvas.summarize(document)
    end

    test "collects across several checklists in document order" do
      document = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "children" => [
            %{
              "id" => "c1",
              "type" => "checklist",
              "children" => [
                %{"id" => "a", "type" => "checklist_item", "props" => %{"label" => "A"}}
              ]
            },
            %{
              "id" => "card",
              "type" => "card",
              "children" => [
                %{
                  "id" => "c2",
                  "type" => "checklist",
                  "children" => [
                    %{"id" => "b", "type" => "checklist_item", "props" => %{"label" => "B"}}
                  ]
                }
              ]
            }
          ]
        }
      }

      assert ["A", "B"] = Enum.map(ActionItemsCanvas.summarize(document), & &1.label)
    end

    test "a document with no checklist has no items" do
      document = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "children" => [
            %{"id" => "t", "type" => "text", "props" => %{"value" => "nothing here"}}
          ]
        }
      }

      assert [] = ActionItemsCanvas.summarize(document)
      assert [] = ActionItemsCanvas.summarize(nil)
      assert [] = ActionItemsCanvas.summarize(%{})
    end

    test "reads an atom-keyed document as well as the string-keyed one Postgres returns" do
      document = %{
        version: 1,
        revision: 1,
        root: %{
          id: "root",
          type: "checklist",
          children: [
            %{
              id: "item-1",
              type: "checklist_item",
              props: %{label: "Atom keyed", state: "active"}
            }
          ]
        }
      }

      assert [%{node_id: "item-1", label: "Atom keyed", state: "active"}] =
               ActionItemsCanvas.summarize(document)
    end
  end

  describe "revision/1" do
    test "reads the revision out of the document, not off a column" do
      space = create_space!()
      meeting_id = Ecto.UUID.generate()

      canvas =
        create_canvas!(space, ours(meeting_id),
          document: checklist_document([{"i", "x", "pending"}], revision: 1)
        )

      assert ActionItemsCanvas.revision(canvas) == 1
      assert ActionItemsCanvas.revision(%{"revision" => 7}) == 7
      assert ActionItemsCanvas.revision(nil) == 0
      assert ActionItemsCanvas.revision(%{}) == 0
    end
  end

  # ── the WRITE half (task 019fb90f-36e3 stage 4) ────────────────────────────

  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Meetings

  defp live_document(canvas_id) do
    {:ok, %{document: document}} = CanvasServer.describe(canvas_id)
    document
  end

  defp live_revision(canvas_id) do
    {:ok, %{revision: revision}} = CanvasServer.describe(canvas_id)
    revision
  end

  defp items_on(canvas_id), do: canvas_id |> live_document() |> ActionItemsCanvas.summarize()

  defp labels_on(canvas_id), do: canvas_id |> items_on() |> Enum.map(& &1.label)

  defp checklists_in(%{"root" => root}), do: checklists_in(root)

  defp checklists_in(node) when is_map(node) do
    own = if node["type"] == "checklist", do: [node], else: []

    own ++ Enum.flat_map(node["children"] || [], &checklists_in/1)
  end

  defp checklists_in(_), do: []

  defp op(kind, fields), do: Map.merge(%{op: kind}, fields)

  defp create_meeting! do
    {:ok, project} =
      Platform.Tasks.create_project(%{name: "Meetings #{System.unique_integer([:positive])}"})

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Standup #{System.unique_integer([:positive])}"
      })

    {:ok, _} = ExecutionSpace.ensure_system_participant(meeting.chat_space_id)
    meeting
  end

  describe "create/3" do
    test "writes a checklist canvas stamped with the metadata locate/2 filters on" do
      space = create_space!()
      meeting_id = Ecto.UUID.generate()

      assert {:ok, canvas} =
               ActionItemsCanvas.create(space.id, meeting_id, [
                 %{label: "Revert the onboarding flow", state: "pending"},
                 %{label: "Email the deploy audit", state: nil}
               ])

      # The writer and the reader agree — this is the drift the shared
      # `metadata_for/1` exists to prevent, asserted rather than assumed.
      assert {:ok, found} = ActionItemsCanvas.locate(space.id, meeting_id)
      assert found.id == canvas.id

      assert labels_on(canvas.id) == ["Revert the onboarding flow", "Email the deploy audit"]
      assert Enum.all?(items_on(canvas.id), &(&1.state == "pending"))
    end

    test "the items are checklist_items under a checklist, not a markdown blob" do
      # `summarize/1` only collects `checklist_item` children of a
      # `checklist`. A markdown node carrying the same words renders the
      # same text and satisfies no assertion here.
      space = create_space!()

      assert {:ok, canvas} =
               ActionItemsCanvas.create(space.id, Ecto.UUID.generate(), [
                 %{label: "X", state: nil}
               ])

      root = live_document(canvas.id)["root"]

      assert [%{"type" => "checklist"} = checklist] = root["children"]
      assert [%{"type" => "checklist_item"}] = checklist["children"]
    end

    test "a complete item carries BOTH state and checked" do
      # The renderer falls back to `checked` when `state` is absent and
      # the triage path reads `state`. Writing one without the other is
      # how a completed item renders unticked.
      space = create_space!()

      assert {:ok, canvas} =
               ActionItemsCanvas.create(space.id, Ecto.UUID.generate(), [
                 %{label: "Done already", state: "complete"},
                 %{label: "Not yet", state: "pending"}
               ])

      [done, pending] =
        live_document(canvas.id)["root"]["children"] |> hd() |> Map.get("children")

      assert done["props"]["state"] == "complete"
      assert done["props"]["checked"] == true
      assert pending["props"]["state"] == "pending"
      assert pending["props"]["checked"] == false
    end

    test "an unknown state falls back to pending rather than writing an invalid node" do
      space = create_space!()

      assert {:ok, canvas} =
               ActionItemsCanvas.create(space.id, Ecto.UUID.generate(), [
                 %{label: "Wat", state: "finished"}
               ])

      assert [%{state: "pending"}] = items_on(canvas.id)
    end

    test "posts exactly one companion canvas message" do
      space = create_space!()

      assert {:ok, canvas} =
               ActionItemsCanvas.create(space.id, Ecto.UUID.generate(), [
                 %{label: "X", state: nil}
               ])

      companions = space.id |> Chat.list_messages() |> Enum.filter(&(&1.canvas_id == canvas.id))

      assert length(companions) == 1
    end

    test "the title names the meeting when there is one, and degrades when there is not" do
      meeting = create_meeting!()

      assert {:ok, named} =
               ActionItemsCanvas.create(meeting.chat_space_id, meeting.id, [
                 %{label: "X", state: nil}
               ])

      assert named.title == "Action Items — #{meeting.name}"

      space = create_space!()

      assert {:ok, anonymous} =
               ActionItemsCanvas.create(space.id, Ecto.UUID.generate(), [
                 %{label: "X", state: nil}
               ])

      assert anonymous.title == "Action Items"
    end

    test "a blank space or meeting id is an error, not a canvas in the void" do
      assert {:error, :invalid_create_target} = ActionItemsCanvas.create("", "m", [])
      assert {:error, :invalid_create_target} = ActionItemsCanvas.create(nil, "m", [])
      assert {:error, :invalid_create_target} = ActionItemsCanvas.create("s", nil, [])
    end
  end

  describe "items_for_create/1" do
    test "keeps adds and drops everything else" do
      assert ActionItemsCanvas.items_for_create([
               op("add", %{label: "Kept"}),
               op("update", %{match: "Kept", state: "complete"}),
               op("remove", %{match: "Kept"})
             ]) == [%{label: "Kept", state: nil}]
    end

    test "drops an update even when it carries a label" do
      # The blank-label filter is NOT what makes this work. An update
      # amending an item's text carries a full label, and against a
      # canvas that does not exist there is nothing to amend — turning it
      # into an add would put an item on the canvas the model explicitly
      # did not ask to add. (Found by mutation: a filter on `op_kind !=
      # nil` passed every other test in this block.)
      assert ActionItemsCanvas.items_for_create([
               op("update", %{match: "Old text", label: "New text", state: "complete"}),
               op("remove", %{match: "Gone", label: "Gone"})
             ]) == []
    end

    test "drops an add with a blank label" do
      assert ActionItemsCanvas.items_for_create([
               op("add", %{label: "   "}),
               op("add", %{label: nil})
             ]) == []
    end
  end

  describe "apply_operations/2 — resolving against the current items" do
    setup do
      space = create_space!()
      meeting_id = Ecto.UUID.generate()

      canvas =
        create_canvas!(
          space,
          ours(meeting_id),
          document:
            checklist_document([
              {"item-1", "Priya reverts the onboarding flow", "pending"},
              {"item-2", "Book the compliance sign-off", "pending"}
            ])
        )

      %{space: space, meeting_id: meeting_id, canvas: canvas}
    end

    test "an add appends to the existing checklist, on the SAME canvas", ctx do
      assert {:ok, updated} =
               ActionItemsCanvas.apply_operations(ctx.canvas, [
                 op("add", %{label: "Alex emails the deploy audit"})
               ])

      assert updated.id == ctx.canvas.id
      assert length(Chat.list_canvases(ctx.space.id)) == 1

      # Appended to the EXISTING checklist, not to a second one bolted
      # onto the root. `summarize/1` collects items from every checklist
      # it finds, so the labels alone cannot tell the two apart.
      assert length(checklists_in(live_document(ctx.canvas.id))) == 1

      assert labels_on(ctx.canvas.id) == [
               "Priya reverts the onboarding flow",
               "Book the compliance sign-off",
               "Alex emails the deploy audit"
             ]
    end

    test "an update matched on label text flips the state", ctx do
      assert {:ok, _} =
               ActionItemsCanvas.apply_operations(ctx.canvas, [
                 op("update", %{match: "priya reverts the onboarding flow", state: "complete"})
               ])

      assert Enum.find(items_on(ctx.canvas.id), &(&1.label =~ "Priya")).state == "complete"
      assert Enum.find(items_on(ctx.canvas.id), &(&1.label =~ "compliance")).state == "pending"
    end

    test "a partial quote of the label resolves when it is unambiguous", ctx do
      assert {:ok, _} =
               ActionItemsCanvas.apply_operations(ctx.canvas, [
                 op("update", %{match: "compliance sign-off", state: "complete"})
               ])

      assert Enum.find(items_on(ctx.canvas.id), &(&1.label =~ "compliance")).state == "complete"
    end

    test "an AMBIGUOUS partial quote resolves to nothing rather than to the first item", ctx do
      # Two items both loosely match "the". Editing whichever came first
      # is worse than editing none — and a first-wins implementation
      # passes every other test in this block.
      before = live_revision(ctx.canvas.id)

      assert {:ok, _} =
               ActionItemsCanvas.apply_operations(ctx.canvas, [
                 op("update", %{match: "the", state: "complete"})
               ])

      assert live_revision(ctx.canvas.id) == before
      assert Enum.all?(items_on(ctx.canvas.id), &(&1.state == "pending"))
    end

    test "a remove deletes exactly the matched item", ctx do
      assert {:ok, _} =
               ActionItemsCanvas.apply_operations(ctx.canvas, [
                 op("remove", %{match: "Book the compliance sign-off"})
               ])

      assert labels_on(ctx.canvas.id) == ["Priya reverts the onboarding flow"]
    end

    test "an add whose label already exists updates it instead of duplicating", ctx do
      assert {:ok, _} =
               ActionItemsCanvas.apply_operations(ctx.canvas, [
                 op("add", %{label: "Priya reverts the onboarding flow.", state: "complete"})
               ])

      items = items_on(ctx.canvas.id)

      assert length(items) == 2
      assert Enum.find(items, &(&1.label =~ "Priya")).state == "complete"
    end

    test "an add that merely CONTAINS an existing label is a new item, not a collapse", ctx do
      # The collapse is exact-match only. "Email Rowan" and "Email Rowan
      # the audit" are two commitments; a substring collapse loses one.
      assert {:ok, _} =
               ActionItemsCanvas.apply_operations(ctx.canvas, [
                 op("add", %{label: "Priya reverts the onboarding flow and tells support"})
               ])

      assert length(items_on(ctx.canvas.id)) == 3
    end

    test "operations are applied in order against a running view of the items", ctx do
      # The remove lands first, so the update that follows must NOT
      # address the node it deleted — that would conflict at head.
      assert {:ok, _} =
               ActionItemsCanvas.apply_operations(ctx.canvas, [
                 op("remove", %{match: "Priya reverts the onboarding flow"}),
                 op("update", %{match: "Priya reverts the onboarding flow", state: "complete"}),
                 op("add", %{label: "Fresh item"}),
                 op("update", %{match: "Fresh item", state: "active"})
               ])

      items = items_on(ctx.canvas.id)

      refute Enum.any?(items, &(&1.label =~ "Priya"))
      assert Enum.find(items, &(&1.label == "Fresh item")).state == "active"
    end

    test "ZERO operations leave the document and revision untouched", ctx do
      document = live_document(ctx.canvas.id)
      revision = live_revision(ctx.canvas.id)

      assert {:ok, returned} = ActionItemsCanvas.apply_operations(ctx.canvas, [])

      assert returned.id == ctx.canvas.id
      assert live_document(ctx.canvas.id) == document
      assert live_revision(ctx.canvas.id) == revision
    end

    test "an unrecognised verb is skipped and writes nothing", ctx do
      revision = live_revision(ctx.canvas.id)

      assert {:ok, _} =
               ActionItemsCanvas.apply_operations(ctx.canvas, [
                 op("frobnicate", %{label: "Nope"})
               ])

      assert live_revision(ctx.canvas.id) == revision
    end

    test "every verb in operation_kinds/0 resolves — derived, not listed", ctx do
      # The roster is walked rather than spot-checked, so a verb added to
      # `operation_kinds/0` with no resolve clause is caught here rather
      # than in production.
      for {verb, kind} <- ActionItemsCanvas.operation_kinds() do
        fields =
          case kind do
            :add -> %{label: "Verb #{verb}"}
            _ -> %{match: "Book the compliance sign-off", state: "active"}
          end

        assert {:ok, _} = ActionItemsCanvas.apply_operations(ctx.canvas, [op(verb, fields)]),
               "verb #{verb} did not resolve"
      end
    end
  end

  describe "apply_operations/2 — a document with no checklist yet" do
    test "appends a checklist rather than dropping the item" do
      space = create_space!()
      meeting_id = Ecto.UUID.generate()

      canvas =
        create_canvas!(space, ours(meeting_id),
          document: %{
            "version" => 1,
            "revision" => 1,
            "root" => %{"id" => "root", "type" => "stack", "children" => []}
          }
        )

      assert {:ok, _} =
               ActionItemsCanvas.apply_operations(canvas, [op("add", %{label: "First item"})])

      assert labels_on(canvas.id) == ["First item"]
    end
  end

  describe "apply_operations/2 — conflict and retry" do
    test "a target deleted at head conflicts, and the RETRY lands the rest" do
      # The canvas struct is captured BEFORE another writer removes the
      # node, which is the production race: `handle_output/3` resolves
      # from the row it read while `Canvas.Server` is the live writer.
      #
      # First attempt: [delete_node(item-1), append(new)] — `apply_many`
      # stops on the first error, so BOTH operations are lost, including
      # the append. Retry re-resolves against head: the remove no longer
      # matches anything and is skipped, the append lands.
      #
      # Delete the retry and "Email the deploy audit" is absent.
      space = create_space!()
      meeting_id = Ecto.UUID.generate()

      canvas =
        create_canvas!(
          space,
          ours(meeting_id),
          document:
            checklist_document([
              {"item-1", "Priya reverts the onboarding flow", "pending"},
              {"item-2", "Book the compliance sign-off", "pending"}
            ])
        )

      stale = canvas

      # Another writer, at head.
      assert {:ok, _revision} =
               CanvasServer.apply_patches(canvas.id, [{:delete_node, "item-1"}], 1)

      refute Enum.any?(labels_on(canvas.id), &(&1 =~ "Priya"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} =
                   ActionItemsCanvas.apply_operations(stale, [
                     op("remove", %{match: "Priya reverts the onboarding flow"}),
                     op("add", %{label: "Email the deploy audit"})
                   ])
        end)

      # Assert the conflict ACTUALLY happened. Without this the test is
      # equally satisfied by an implementation that resolves the first
      # attempt against head, never conflicts, and therefore never
      # exercises the retry at all — the same outcome by a path that
      # leaves the retry untested.
      assert log =~ "patch conflict"
      assert log =~ "re-resolving once"

      assert labels_on(canvas.id) == ["Book the compliance sign-off", "Email the deploy audit"]
    end

    test "a conflict that survives the retry is {:error, :canvas_conflict}, never a silent drop" do
      # A canvas stamped as ours whose root cannot hold a checklist —
      # somebody repurposed the document. Every attempt is rejected by
      # the kind registry, so the retry cannot rescue it, and the caller
      # must hear about it rather than see `:ok`.
      space = create_space!()
      meeting_id = Ecto.UUID.generate()

      canvas =
        create_canvas!(space, ours(meeting_id),
          document: %{
            "version" => 1,
            "revision" => 1,
            "root" => %{"id" => "root", "type" => "text", "props" => %{"value" => "not a list"}}
          }
        )

      revision = live_revision(canvas.id)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :canvas_conflict} =
                   ActionItemsCanvas.apply_operations(canvas, [op("add", %{label: "Nowhere"})])
        end)

      assert log =~ "patch conflict persisted after retry"
      assert live_revision(canvas.id) == revision
    end
  end

  defp fetch(space_id, meeting_id, expected) do
    case ActionItemsCanvas.locate(space_id, meeting_id) do
      {:ok, %{id: id}} when id == expected.id -> {:ok, expected}
      other -> other
    end
  end
end
