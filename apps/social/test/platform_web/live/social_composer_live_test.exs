defmodule PlatformWeb.SocialComposerLiveTest do
  @moduledoc """
  The composer screen (Social authoring 6/11, task 01a16c50), one describe
  per Done-means item, driven through the real Social LiveView: the header's
  "New idea" button, the idea form, the per-account columns (each drafted on
  its own async task), and the three actions.

  No real LLM or vendor traffic: `Platform.SocialComposerFixtures` points
  the Anthropic client at a `Req.Test` stub, allowed for the LiveView's
  process (its `start_async` tasks inherit it); publishing goes to the Fake
  publisher. `async: false`: both seams are global.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.SocialApprovalFixtures
  import Platform.SocialComposerFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{ApprovalCard, Approvals, Idea, Ideas, Post, PostEvent}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    restore = use_llm_stub!()
    on_exit(restore)

    ctx = approval_fixture()
    {:ok, x} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "x", handle: "@show_x"})

    {:ok, ig} =
      Social.create_account(ctx.org_id, ctx.profile, %{platform: "instagram", handle: "@show_ig"})

    connected =
      for account <- [ctx.a, x, ig] do
        {:ok, account} = Social.update_account(ctx.org_id, account, %{status: "connected"})
        account
      end

    [a, x, ig] = connected
    Map.merge(ctx, %{a: a, x: x, ig: ig})
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp open(conn, user) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social")
    child = find_live_child(view, "ext-page-social")
    Req.Test.allow(llm_stub(), self(), child.pid)
    child
  end

  defp new_idea(child) do
    child |> element("[data-role='social-new-idea']") |> render_click()

    assert has_element?(
             child,
             "[data-role='social-composer'][data-open='true'][data-step='idea']"
           )

    child
  end

  defp draft(child, accounts, title \\ "The launch") do
    child
    |> form("#composer-idea-form",
      idea: %{title: title, brief: "What shipped.", account_ids: Enum.map(accounts, & &1.id)}
    )
    |> render_submit()

    render_async(child)
    child
  end

  defp col(account), do: "[data-role='composer-column'][data-account-id='#{account.id}']"

  defp in_col(account, sel), do: "#{col(account)} #{sel}"

  defp composer_posts(ctx) do
    ids = [ctx.a.id, ctx.d.id, ctx.x.id, ctx.ig.id]
    Repo.all(from(p in Post, where: p.account_id in ^ids))
  end

  # ── The flow ─────────────────────────────────────────────────────────

  describe "New idea" do
    test "opens the composer with every connected account ticked; draft-only and owned are labelled",
         %{conn: conn} = ctx do
      {:ok, _} = Social.set_account_owner(ctx.org_id, ctx.x, ctx.h2.id)

      child = conn |> open(ctx.h1) |> new_idea()

      for account <- [ctx.a, ctx.d, ctx.x, ctx.ig] do
        assert has_element?(
                 child,
                 "[data-role='composer-account'][data-account-id='#{account.id}'] input[checked]"
               )
      end

      assert has_element?(
               child,
               "[data-account-id='#{ctx.d.id}'] [data-role='composer-by-hand']",
               "You post this yourself"
             )

      assert has_element?(
               child,
               "[data-account-id='#{ctx.x.id}'] [data-role='composer-owner']",
               "Hugo Two's account"
             )

      child |> element("[data-role='composer-close']") |> render_click()
      assert has_element?(child, "[data-role='social-composer'][data-open='false']")
    end

    test "a title is required before drafting", %{conn: conn} = ctx do
      drafting_agent!()
      stub_llm!()
      child = conn |> open(ctx.h1) |> new_idea()

      child
      |> form("#composer-idea-form", idea: %{title: " ", account_ids: [ctx.a.id]})
      |> render_submit()

      assert has_element?(child, "[data-role='composer-idea-error']", "Give the idea a title.")
      refute_received {:llm, _, _, _}
    end
  end

  describe "LinkedIn, X and Instagram give 3 columns" do
    test "three columns side by side, each with its live preview; a 600-char X version is 3 numbered posts",
         %{conn: conn} = ctx do
      drafting_agent!()
      stub_llm!(replies: %{"x" => long_x_reply()})

      child = conn |> open(ctx.h1) |> new_idea() |> draft([ctx.a, ctx.x, ctx.ig])

      assert has_element?(child, "[data-role='social-composer'][data-step='versions']")

      for account <- [ctx.a, ctx.x, ctx.ig] do
        assert has_element?(child, col(account) <> "[data-state='ok']")

        assert has_element?(
                 child,
                 in_col(
                   account,
                   "[data-role='social-preview'][data-platform='#{account.platform}']"
                 )
               )

        assert has_element?(child, in_col(account, "[data-role='composer-rationale']"))
      end

      refute has_element?(child, col(ctx.d))

      posts =
        child
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(in_col(ctx.x, "[data-role='x-post']"))

      assert Enum.count(posts) == 3

      for n <- 1..3 do
        assert has_element?(
                 child,
                 in_col(ctx.x, "[data-role='x-post'][data-index='#{n}']"),
                 "#{n}/3"
               )
      end

      assert has_element?(
               child,
               in_col(ctx.a, "[data-role='composer-why-format']"),
               "Room for a story."
             )

      assert has_element?(
               child,
               in_col(ctx.a, "[data-role='composer-why-time']"),
               "No posting slots"
             )
    end

    test "editing a version updates its preview", %{conn: conn} = ctx do
      drafting_agent!()
      stub_llm!()
      child = conn |> open(ctx.h1) |> new_idea() |> draft([ctx.a])

      child
      |> form("#composer-edit-#{ctx.a.id}", version: %{text: "Rewritten by hand."})
      |> render_change()

      assert has_element?(
               child,
               in_col(ctx.a, "[data-role='social-preview']"),
               "Rewritten by hand."
             )
    end

    test "Regenerate this one redrafts only that column", %{conn: conn} = ctx do
      drafting_agent!()
      stub_llm!()
      child = conn |> open(ctx.h1) |> new_idea() |> draft([ctx.a, ctx.x])

      for _ <- 1..2, do: assert_receive({:llm, _, _, _})

      # Hold the regeneration's model call open so the skeleton is visible.
      test = self()

      Req.Test.stub(llm_stub(), fn conn ->
        send(test, {:llm_waiting, self()})

        receive do
          :go -> :ok
        end

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        [%{"content" => prompt}] = Jason.decode!(raw)["messages"]
        send(test, {:llm, kind(prompt), nil, prompt})

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => Jason.encode!(reply(kind(prompt)))}]
        })
      end)

      child |> element(in_col(ctx.x, "[data-role='composer-regenerate']")) |> render_click()
      assert_receive {:llm_waiting, caller}
      assert has_element?(child, col(ctx.x) <> "[data-state='loading']")
      assert has_element?(child, in_col(ctx.x, "[data-role='composer-skeleton']"))
      assert has_element?(child, col(ctx.a) <> "[data-state='ok']")
      send(caller, :go)

      render_async(child)
      assert_receive {:llm, "x", _, _}
      refute_received {:llm, _, _, _}
      assert has_element?(child, col(ctx.x) <> "[data-state='ok']")
    end
  end

  describe "Send for approval" do
    test "leaves 3 needs_approval posts under one idea, with chat cards posted, and lands in Needs you",
         %{conn: conn} = ctx do
      drafting_agent!()
      stub_llm!()
      child = conn |> open(ctx.h1) |> new_idea() |> draft([ctx.a, ctx.x, ctx.ig])

      child |> element("[data-role='composer-send']") |> render_click()

      assert has_element?(child, "[data-role='composer-sent'][data-kind='sent']")

      assert [%Idea{source_kind: "human", title: "The launch"} = idea] = Repo.all(Idea)
      posts = composer_posts(ctx)
      assert length(posts) == 3
      assert Enum.all?(posts, &(&1.status == "needs_approval" and &1.idea_id == idea.id))

      for post <- posts do
        assert %ApprovalCard{state: "pending", canvas_id: canvas_id} =
                 Approvals.live_card(post.id)

        assert %{space_id: space_id} = Platform.Chat.get_canvas(canvas_id)
        assert space_id == ctx.space.id
      end

      assert Fake.calls() == []

      # The Queue re-read on the composer's message: one card for the idea.
      assert has_element?(child, "#queue-card-idea-#{idea.id}")
    end

    test "Save as idea saves the idea at Inbox with no posts", %{conn: conn} = ctx do
      child = conn |> open(ctx.n) |> new_idea()

      child
      |> form("#composer-idea-form", idea: %{title: "Later, maybe", account_ids: [ctx.a.id]})
      |> render_change()

      child |> element("[data-role='composer-save-idea']") |> render_click()

      assert has_element?(child, "[data-role='composer-sent'][data-kind='saved']")
      assert [%Idea{title: "Later, maybe"} = idea] = Repo.all(Idea)
      assert Ideas.stage(idea) == "inbox"
      assert composer_posts(ctx) == []
    end
  end

  describe "banned phrases" do
    test "a banned phrase triggers a regeneration, and if still there it is flagged",
         %{conn: conn} = ctx do
      drafting_agent!()

      {:ok, _} =
        Social.update_profile(ctx.org_id, ctx.profile, %{voice: %{banned: ["game changer"]}})

      reply = %{"text" => "This launch is a game changer.", "why_shape" => "w"}
      stub_llm!(replies: %{"linkedin" => reply}, retry_replies: %{"linkedin" => reply})

      child = conn |> open(ctx.h1) |> new_idea() |> draft([ctx.a])

      assert_receive {:llm, "linkedin", _, _}
      assert_receive {:llm, "linkedin", _, retry}
      assert retry =~ "Your previous version used the phrase"

      assert has_element?(child, in_col(ctx.a, "[data-role='composer-banned']"), "game changer")
      assert has_element?(child, in_col(ctx.a, "[data-flag='banned_phrase']"))

      assert has_element?(
               child,
               in_col(ctx.a, "[data-role='composer-voice-check']"),
               "never says"
             )

      # A human is warned, not blocked: editing it out clears the flag.
      child
      |> form("#composer-edit-#{ctx.a.id}", version: %{text: "This launch is a big step."})
      |> render_change()

      refute has_element?(child, in_col(ctx.a, "[data-flag='banned_phrase']"))
    end
  end

  describe "one column's provider error" do
    test "leaves the other two usable", %{conn: conn} = ctx do
      drafting_agent!()
      stub_llm!(fail: ["x"])

      child = conn |> open(ctx.h1) |> new_idea() |> draft([ctx.a, ctx.x, ctx.ig])

      assert has_element?(child, col(ctx.x) <> "[data-state='error']")

      assert has_element?(
               child,
               in_col(ctx.x, "[data-role='composer-error']"),
               "The model didn't answer."
             )

      assert has_element?(child, col(ctx.a) <> "[data-state='ok']")
      assert has_element?(child, col(ctx.ig) <> "[data-state='ok']")
      assert has_element?(child, "[data-role='composer-left-out']")

      child |> element("[data-role='composer-send']", "Send 2 for approval") |> render_click()

      posts = composer_posts(ctx)
      assert Enum.sort(Enum.map(posts, & &1.account_id)) == Enum.sort([ctx.a.id, ctx.ig.id])
      [%Idea{id: idea_id}] = Repo.all(Idea)
      assert has_element?(child, "#queue-card-idea-#{idea_id}")
    end

    test "no drafting agent says so in each column", %{conn: conn} = ctx do
      stub_llm!()
      child = conn |> open(ctx.h1) |> new_idea() |> draft([ctx.a])

      assert has_element?(
               child,
               in_col(ctx.a, "[data-role='composer-error']"),
               "No drafting agent"
             )
    end
  end

  describe "Send and approve" do
    test "an approver sends and approves; the event log records a human approval and it publishes",
         %{conn: conn} = ctx do
      drafting_agent!()
      stub_llm!()
      child = conn |> open(ctx.h1) |> new_idea() |> draft([ctx.a])

      child |> element("[data-role='composer-send-approve']") |> render_click()

      assert has_element?(child, "[data-role='composer-sent'][data-kind='approved']")
      assert [post] = composer_posts(ctx)
      assert post.status in Post.approved_statuses()
      assert post.approved_by_user_id == ctx.h1.id

      assert Repo.exists?(
               from(e in PostEvent,
                 where:
                   e.post_id == ^post.id and e.action == "approved" and e.actor_kind == "human" and
                     e.actor_id == ^ctx.h1.id
               )
             )

      assert [_ | _] = Fake.calls(:publish)
    end

    test "on an owned account the owner still decides: it says Sent to <owner>",
         %{conn: conn} = ctx do
      drafting_agent!()
      stub_llm!()
      {:ok, _} = Social.set_account_owner(ctx.org_id, ctx.x, ctx.h2.id)
      child = conn |> open(ctx.h1) |> new_idea() |> draft([ctx.a, ctx.x])

      child |> element("[data-role='composer-send-approve']") |> render_click()

      assert has_element?(child, "[data-role='composer-sent-lines']", "Sent to Hugo Two")
      x_post = Enum.find(composer_posts(ctx), &(&1.account_id == ctx.x.id))
      assert x_post.status == "needs_approval"
      assert is_nil(x_post.approved_by_user_id)
    end

    test "a non-approver can't see it, and a forged event is refused with nothing written",
         %{conn: conn} = ctx do
      drafting_agent!()
      stub_llm!()
      child = conn |> open(ctx.n) |> new_idea() |> draft([ctx.a, ctx.x])

      assert has_element?(child, "[data-role='composer-send']")
      refute has_element?(child, "[data-role='composer-send-approve']")

      child |> with_target("#social-composer") |> render_click("send", %{"mode" => "approve"})

      assert has_element?(child, "[data-role='composer-send-error']", "You can't approve")
      assert composer_posts(ctx) == []
      assert Repo.all(Idea) == []
      assert Fake.calls() == []
    end
  end
end
