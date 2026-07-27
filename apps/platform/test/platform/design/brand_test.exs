defmodule Platform.Design.BrandTest do
  @moduledoc """
  Guards for `Platform.Design.Brand` — brand resolution and the
  once-per-project escalation (ADR 0046, stack member 7 stage 2).

  ## What each guard is actually holding

  Three claims here are load-bearing and each has one assertion carrying it:

    * **"project overrides org"** — implemented as document ORDER, so the
      guard asserts by *index*, not by presence. Presence passes on a
      concatenation in either direction.
    * **"asked once per PROJECT"** — the guard runs `escalate_once/2` for two
      different tasks in one project and asserts the total message count
      across *both* execution spaces is exactly 1.
    * **"brand never blocks"** — the guard feeds `resolve/1` six malformed
      decisions and six hostile task shapes and asserts every call returns a
      map whose `enforcement` is `:strict` or `:advisory`. There is no value
      in the return shape a caller could block on, and that is asserted rather
      than asserted-about-in-a-comment.

  ## Absence assertions are paired

  "A recorded decision silences the escalation" carries its own positive
  control *in the same test body*: an identical `escalate_once/2` call against
  a project with no decision, asserted to post exactly one message. A bare
  `assert [] == messages` passes on a module that never posts at all.

  ## The MCP guard is behavioural, not syntactic

  `Brand.recordable_modes/0` is the single copy of the accepted enum and
  `tool_surface.ex` builds both its parameter description and its validation
  from it. A grep for "one copy" would be satisfied by a rename, so the guard
  instead drives the tool with all three accepted modes and six deliberate
  near-misses — including `"asked"`, which is a valid *stored* mode but not a
  selectable one, so a check that merely asked "is this a known mode" would
  wrongly admit it.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Design.Brand
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Org.Wiki
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  setup do
    # `org/page/brand.md` is a single deployment-global row (the unique index
    # COALESCEs a NULL workspace — see the module docs), so a leftover or
    # seeded page would make every "no org brand" case silently resolve.
    Wiki.delete_page(Brand.org_page_key())
    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp project!(attrs \\ %{}) do
    {:ok, project} =
      Tasks.create_project(
        Map.merge(%{name: "Brand Project #{System.unique_integer([:positive])}"}, attrs)
      )

    project
  end

  # `Repo.insert!` rather than `Tasks.create_task/1`: the context-level writes
  # broadcast to the singleton TaskRouterWatcher, which then evaluates from a
  # process that does not own this case's sandbox connection.
  defp task!(project) do
    now = DateTime.utc_now()

    %TaskSchema{}
    |> Ecto.Changeset.change(%{
      project_id: project.id,
      title: "Brand Task #{System.unique_integer([:positive])}",
      status: "backlog",
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp put_page(file_key, content) do
    {:ok, page} = Wiki.upsert_page(file_key, %{content: content})
    page
  end

  defp drop_page(file_key), do: Wiki.delete_page(file_key)

  defp arrange_pages(org_key, project_key, pages) do
    case Keyword.fetch(pages, :org) do
      {:ok, body} -> put_page(org_key, body)
      :error -> drop_page(org_key)
    end

    case Keyword.fetch(pages, :project) do
      {:ok, body} -> put_page(project_key, body)
      :error -> drop_page(project_key)
    end
  end

  # NOT `ExecutionSpace.find_or_create/1`. That derives its slug from the first
  # 12 hex chars of the task UUID — the 48-bit UUIDv7 millisecond — and
  # `chat_spaces_unique_org_slug` then rejects two tasks in ONE org created
  # inside the same millisecond. Two back-to-back `Repo.insert!` calls do
  # exactly that: this test went red in a full-suite run with
  # `slug: {"has already been taken", constraint: :unique}` while passing when
  # the file was run alone. The source comment on `find_or_create/1` calls
  # sub-millisecond creation "well outside anything the sponsor UI can
  # produce", which is true of the UI and not true of programmatic creation.
  # That is a real orchestration bug, reported separately; it is not brand's,
  # and testing brand THROUGH it would make this file fail for a reason it
  # does not describe.
  defp execution_space!(task) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "brand-exec-#{n}",
        slug: "brand-exec-#{n}",
        kind: "execution",
        metadata: %{"task_id" => task.id}
      })

    # Guard the substitution: the module under test finds its space through
    # `find_by_task_id/1`, so if this hand-built row stopped being findable the
    # escalation tests would silently degrade into "no space" tests.
    assert %{id: found} = ExecutionSpace.find_by_task_id(task.id)
    assert found == space.id

    space
  end

  defp messages_in(space_id) do
    Repo.all(from(m in Message, where: m.space_id == ^space_id, order_by: [asc: m.inserted_at]))
  end

  defp index_of!(haystack, needle) do
    case :binary.match(haystack, needle) do
      {at, _len} -> at
      :nomatch -> flunk("expected to find #{inspect(needle)} in:\n#{haystack}")
    end
  end

  # ── Resolution ────────────────────────────────────────────────────────────

  describe "resolve/1 — sources and merge order" do
    test "org page + project page → :org_and_project, :strict, project section AFTER org" do
      project = project!()
      task = task!(project)

      put_page(Brand.org_page_key(), "Org voice: plain and declarative. ORG_BRAND_SENTINEL")

      put_page(
        Brand.project_page_key(project.id),
        "Project voice: warmer, shorter. PROJECT_BRAND_SENTINEL"
      )

      brand = Brand.resolve(task)

      assert brand.mode == :org_and_project
      assert brand.enforcement == :strict
      assert brand.org_page =~ "ORG_BRAND_SENTINEL"
      assert brand.project_page =~ "PROJECT_BRAND_SENTINEL"

      # Order IS the merge rule — these pages are prose, there is nothing to
      # deep-merge. Asserting presence would pass on either ordering.
      org_heading_at = index_of!(brand.guidance, "## Org brand")
      project_heading_at = index_of!(brand.guidance, "## Project brand")

      assert project_heading_at > org_heading_at,
             "the project section must come AFTER the org section — that ordering is " <>
               "the entire override mechanism. guidance was:\n#{brand.guidance}"

      assert index_of!(brand.guidance, "ORG_BRAND_SENTINEL") <
               index_of!(brand.guidance, "PROJECT_BRAND_SENTINEL"),
             "the bodies must appear in the same order as their headings:\n#{brand.guidance}"

      assert brand.guidance =~ "project section wins",
             "guidance must state the precedence in words, not only in layout:\n#{brand.guidance}"
    end

    test "project page only → :project_only, :strict (an org page is not a prerequisite)" do
      project = project!()
      task = task!(project)

      put_page(
        Brand.project_page_key(project.id),
        "Project-only identity. PROJECT_BRAND_SENTINEL"
      )

      brand = Brand.resolve(task)

      assert brand.mode == :project_only
      assert brand.enforcement == :strict
      assert brand.org_page == nil
      assert brand.project_page =~ "PROJECT_BRAND_SENTINEL"
      assert brand.guidance =~ "## Project brand"
      refute brand.guidance =~ "## Org brand"
    end

    test "org page only → :org_only, :strict" do
      project = project!()
      task = task!(project)

      put_page(Brand.org_page_key(), "Org identity. ORG_BRAND_SENTINEL")

      brand = Brand.resolve(task)

      assert brand.mode == :org_only
      assert brand.enforcement == :strict
      assert brand.org_page =~ "ORG_BRAND_SENTINEL"
      assert brand.project_page == nil
      assert brand.guidance =~ "## Org brand"
      refute brand.guidance =~ "## Project brand"
    end

    test "a page that is empty once frontmatter is stripped counts as ABSENT" do
      project = project!()
      task = task!(project)

      put_page(
        Brand.project_page_key(project.id),
        "---\ntitle: Brand\nstatus: draft\n---\n\n   \n"
      )

      brand = Brand.resolve(task)

      assert brand.project_page == nil
      assert brand.mode == :unresolved

      assert brand.enforcement == :advisory,
             "enforcing strictly against a blank page is enforcing against nothing, " <>
               "and it would also suppress the escalation that gets a real page written"
    end
  end

  # ── The "never blocks" claim ──────────────────────────────────────────────

  describe "resolve/1 — never returns an error tuple" do
    test "four source combinations, malformed decisions, and hostile task shapes" do
      project = project!()
      task = task!(project)
      org_key = Brand.org_page_key()
      project_key = Brand.project_page_key(project.id)

      combinations = [
        {"both pages", [org: "org body", project: "project body"], :org_and_project, :strict},
        {"org only", [org: "org body"], :org_only, :strict},
        {"project only", [project: "project body"], :project_only, :strict},
        {"neither", [], :unresolved, :advisory}
      ]

      for {label, pages, expected_mode, expected_enforcement} <- combinations do
        arrange_pages(org_key, project_key, pages)
        brand = Brand.resolve(task)

        assert brand |> Map.keys() |> Enum.sort() ==
                 [:decision, :enforcement, :guidance, :mode, :org_page, :project_page],
               "#{label}: resolve/1 returned #{inspect(brand)}"

        assert brand.mode == expected_mode, "#{label}: got #{inspect(brand.mode)}"

        assert brand.enforcement == expected_enforcement,
               "#{label}: got #{inspect(brand.enforcement)}"

        assert is_binary(brand.guidance) and brand.guidance != "", "#{label}: empty guidance"
      end

      # Every one of these is a shape `Project.changeset/2` would happily
      # persist into `config`, which is exactly why the MCP surface exposes a
      # named enum instead of a `config` passthrough.
      malformed = [%{"mode" => 7}, %{"mode" => "wat"}, %{"mode" => nil}, "exploring", %{}, 42]

      for value <- malformed do
        {:ok, p} = Tasks.update_project(project!(), %{config: %{"brand_decision" => value}})
        brand = Brand.resolve(task!(p))

        assert brand.enforcement in [:strict, :advisory],
               "#{inspect(value)} produced #{inspect(brand)}"

        assert brand.mode == :unresolved,
               "a recorded decision of #{inspect(value)} must read as NO decision"

        assert brand.decision == nil
      end

      hostile = [
        %{},
        %{project_id: nil},
        %{project_id: ""},
        %{project_id: "not-a-uuid"},
        %{project_id: 7},
        %{id: nil, project_id: nil}
      ]

      for shape <- hostile do
        brand = Brand.resolve(shape)

        assert brand.mode == :unresolved, "#{inspect(shape)} produced #{inspect(brand)}"
        assert brand.enforcement == :advisory
        assert is_binary(brand.guidance)
      end
    end
  end

  # ── Escalation ────────────────────────────────────────────────────────────

  describe "escalate_once/2" do
    test "two tasks in one project produce exactly one escalation and one `asked` record" do
      project = project!()
      task_a = task!(project)
      task_b = task!(project)

      space_a = execution_space!(task_a)
      space_b = execution_space!(task_b)

      assert {:ok, :asked} = Brand.escalate_once(task_a)
      second = Brand.escalate_once(task_b)

      posted = messages_in(space_a.id) ++ messages_in(space_b.id)

      assert length(posted) == 1,
             "escalate_once/2 asks ONCE PER PROJECT, not once per task. Got " <>
               "#{length(posted)} messages across the two execution spaces:\n" <>
               Enum.map_join(posted, "\n---\n", & &1.content)

      assert second == {:ok, :already_recorded}

      reloaded = Tasks.get_project(project.id)
      assert %{"mode" => "asked"} = reloaded.config["brand_decision"]
      assert is_binary(reloaded.config["brand_decision"]["recorded_at"])
    end

    test "the escalation enumerates exactly three options and says nothing is blocked" do
      project = project!()
      task = task!(project)
      space = execution_space!(task)

      assert {:ok, :asked} = Brand.escalate_once(task)
      assert [message] = messages_in(space.id)

      assert message.content =~ "(a)"
      assert message.content =~ "(b)"
      assert message.content =~ "(c)"
      refute message.content =~ "(d)"

      assert message.content =~ "org default identity"
      assert message.content =~ "Create an identity now"
      assert message.content =~ "Exploring"
      assert message.content =~ "Nothing is blocked"
    end

    test "a recorded `exploring` decision silences it — paired with the positive control" do
      # Positive control FIRST, in this same test: with no decision on record
      # the identical call posts exactly one message. Without this arm the
      # absence assertion below passes on a module that never posts at all.
      control_project = project!()
      control_task = task!(control_project)
      control_space = execution_space!(control_task)

      assert {:ok, :asked} = Brand.escalate_once(control_task)

      control_messages = messages_in(control_space.id)

      assert length(control_messages) == 1,
             "positive control: with no recorded decision the escalation must post exactly " <>
               "one message, got #{length(control_messages)}"

      assert hd(control_messages).content =~ "Brand direction"

      # Absence arm — identical call, decision already on record.
      project = project!()
      {:ok, project} = Brand.record_decision(project, "exploring")
      task = task!(project)
      space = execution_space!(task)

      brand = Brand.resolve(task)
      assert brand.mode == :recorded
      assert brand.enforcement == :advisory
      assert brand.decision["mode"] == "exploring"

      assert {:ok, :already_recorded} = Brand.escalate_once(task)
      assert [] == messages_in(space.id)
    end

    test "with no resolvable execution space it STILL records `asked` and returns {:ok, :asked}" do
      project = project!()
      task = task!(project)

      refute ExecutionSpace.find_by_task_id(task.id),
             "this test is only meaningful while the task has no execution space"

      log = capture_log(fn -> assert {:ok, :asked} = Brand.escalate_once(task) end)

      assert log =~ "could not deliver the brand escalation"

      reloaded = Tasks.get_project(project.id)

      assert reloaded.config["brand_decision"]["mode"] == "asked",
             "losing the question once is strictly better than asking it forever"

      assert {:ok, :already_recorded} = Brand.escalate_once(task)
    end

    test "a resolved brand page means there is nothing to ask" do
      project = project!()
      task = task!(project)
      space = execution_space!(task)

      put_page(Brand.project_page_key(project.id), "Project identity. PROJECT_BRAND_SENTINEL")

      assert {:ok, :not_needed} = Brand.escalate_once(task)
      assert [] == messages_in(space.id)
      assert Tasks.get_project(project.id).config["brand_decision"] == nil
    end

    test "records the escalating principal when one is supplied" do
      project = project!()
      task = task!(project)
      actor = Ecto.UUID.generate()

      assert {:ok, :asked} = Brand.escalate_once(task, recorded_by: actor)

      assert Tasks.get_project(project.id).config["brand_decision"]["recorded_by"] == actor
    end
  end

  # ── record_decision/3 ─────────────────────────────────────────────────────

  describe "record_decision/3" do
    test "rejects a mode outside the known set rather than poisoning the cache" do
      project = project!()

      assert {:error, {:invalid_brand_decision, "nope"}} = Brand.record_decision(project, "nope")
      assert {:error, {:invalid_brand_decision, 7}} = Brand.record_decision(project, 7)

      assert Tasks.get_project(project.id).config["brand_decision"] == nil,
             "a rejected mode must leave no record — a half-written decision would " <>
               "silence the escalation without answering it"
    end

    test "preserves unrelated config keys" do
      {:ok, project} = Tasks.update_project(project!(), %{config: %{"unrelated" => "keep me"}})

      {:ok, project} = Brand.record_decision(project, "identity")

      assert project.config["unrelated"] == "keep me"
      assert project.config["brand_decision"]["mode"] == "identity"
    end
  end

  # ── MCP surface ───────────────────────────────────────────────────────────

  describe "project_update brand_decision" do
    test "records the decision and does NOT become an arbitrary config writer" do
      project = project!()

      {:ok, result} =
        ToolSurface.execute(
          "project_update",
          %{
            "project_id" => project.id,
            "brand_decision" => "exploring",
            "config" => %{"anything" => 1}
          },
          %{}
        )

      assert result.brand_decision["mode"] == "exploring"

      reloaded = Tasks.get_project(project.id)
      assert reloaded.config["brand_decision"]["mode"] == "exploring"

      refute Map.has_key?(reloaded.config, "anything"),
             "`config` must not be agent-writable: Project.changeset/2 does not validate " <>
               "its shape, and a malformed brand_decision is read as no decision — which " <>
               "silently re-opens the re-ask loop. config was #{inspect(reloaded.config)}"
    end

    test "the accepted set and the declared enum are one list, not two copies" do
      [tool] = Enum.filter(ToolSurface.tool_definitions(), &(&1.name == "project_update"))
      description = tool.parameters.brand_decision.description

      for mode <- Brand.recordable_modes() do
        assert description =~ mode,
               "declared parameter description omits the accepted mode #{inspect(mode)}"

        project = project!()

        assert {:ok, result} =
                 ToolSurface.execute(
                   "project_update",
                   %{"project_id" => project.id, "brand_decision" => mode},
                   %{}
                 )

        assert result.brand_decision["mode"] == mode
      end

      # Near-misses. `"asked"` is a valid *stored* mode but not a selectable
      # one — it is written by escalate_once/2 and nobody chooses it — so a
      # check that merely asked "is this a known mode" would wrongly admit it.
      for mode <- ["asked", "org-default", "Identity", "exploring ", "", "config"] do
        project = project!()

        assert {:error, error} =
                 ToolSurface.execute(
                   "project_update",
                   %{"project_id" => project.id, "brand_decision" => mode},
                   %{}
                 )

        assert error.recoverable == true
        assert error.error =~ "brand_decision"

        assert Tasks.get_project(project.id).config["brand_decision"] == nil,
               "rejected mode #{inspect(mode)} still wrote a decision"
      end
    end

    test "attributes the decision to the calling agent when the context carries one" do
      project = project!()
      agent_id = Ecto.UUID.generate()

      {:ok, _result} =
        ToolSurface.execute(
          "project_update",
          %{"project_id" => project.id, "brand_decision" => "org_default"},
          %{agent_id: agent_id}
        )

      assert Tasks.get_project(project.id).config["brand_decision"]["recorded_by"] == agent_id
    end

    test "leaves the pre-existing field updates working untouched" do
      project = project!()

      {:ok, result} =
        ToolSurface.execute(
          "project_update",
          %{"project_id" => project.id, "default_branch" => "trunk"},
          %{}
        )

      assert result.default_branch == "trunk"
      assert result.brand_decision == nil
      assert Tasks.get_project(project.id).default_branch == "trunk"
    end
  end
end
