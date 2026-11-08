defmodule PlatformWeb.SecretaryLiveTest do
  @moduledoc """
  The main view that replaced the Inbox (task 01a1b721 stage 4): INV-1 rows
  1-30 against mockup canvas 01a1b744-5ed4 screen 1, the `/inbox` redirect,
  the module gate, the active rail key, and the unchanged badge semantics.

  The model is the dev fake host's deterministic answer, through
  `Platform.SecretaryFixtures.request/2`; no host runs.

  Mutants these name: remove the /inbox redirect (M18) -> "redirects" red;
  badge = decide count (M19) -> "badge equals reachable_unread_count" red;
  render the brief in fallback (M21) -> "no_ai" red; drop the ModuleGate
  entry (M22) -> "locked" red; skip Inbox.open_item on open (M23) ->
  "opening a row lowers the count" red.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SecretaryFixtures

  import Platform.ExternalUserFixtures,
    only: [external_user!: 1, create_user!: 0, channel!: 1, add_user!: 2, plain_member!: 2]

  alias Platform.Access.Grants
  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Experiments.Surfaces.SecretaryPolicy
  alias Platform.Inbox
  alias Platform.Secretary
  alias Platform.Secretary.{Context, Pass, Settings, Store, Todos}
  alias Platform.Tenancy

  @payload SecretaryPolicy.control()

  defp auth(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp pass!(user, opts \\ []) do
    {:ok, outcome} =
      Pass.run(
        Accounts.get_user(user.id),
        Keyword.merge(
          [
            eligible: eligible(),
            request: request(self()),
            payload: @payload,
            install_payload: @payload
          ],
          opts
        )
      )

    outcome
  end

  defp org_of(user) do
    %{org_id: org_id} = Enum.at(Platform.Accounts.get_user(user.id).org_memberships, 0)
    Tenancy.get_org!(org_id)
  end

  # The world the ok state renders: a goal space the person is in, a
  # decision with a deadline, a mention, an FYI, an open channel they are
  # not in, a heard to-do and their own to-do.
  defp world!(user) do
    org = org_of(user)
    other = create_user!()
    plain_member!(other, org)

    goal_space = channel!(%{org_id: org.id, slug: "launch-#{System.unique_integer([:positive])}"})
    add_user!(goal_space.id, user.id)
    {:ok, goal_space} = Chat.update_space(goal_space, %{goal: "Ship the spring launch"})

    open = channel!(%{org_id: org.id, slug: "finance-#{System.unique_integer([:positive])}"})
    say!(open, other, "Spring prices are being set without the menu owner")

    decide = inbox_item!(user, "task_plan_review", "The plan needs your yes today")
    mention = inbox_item!(user, "chat_mention", "Someone asked you a question")
    fyi = inbox_item!(user, "meeting_invited", "You were invited")

    {:ok, suggested} =
      Todos.suggest(user.id, %{
        "title" => "Confirm the tasting headcount",
        "source_space_id" => goal_space.id,
        "source_quote" => "can you confirm numbers with the bakery?"
      })

    {:ok, own} = Todos.add_own(user.id, "Draft the winter hours sign")

    {:ok, kept} =
      Todos.suggest(user.id, %{
        "title" => "Send the new menu",
        "source_space_id" => goal_space.id,
        "source_quote" => "send me the new menu when you can"
      })

    {:ok, kept} = Todos.keep(user.id, kept.id)

    %{
      org: org,
      other: other,
      goal_space: goal_space,
      open: open,
      decide: decide,
      mention: mention,
      fyi: fyi,
      suggested: suggested,
      kept: kept,
      own: own
    }
  end

  # The fake puts everything under "none"; move the decision into the goal
  # and give it a brief tag, and make the mention a moved-up row.
  defp dress!(user, w) do
    goal_key = Context.goal_key(w.goal_space.id, 0)

    {:ok, _} =
      Store.upsert_evaluation(user.id, %{
        ref_type: "inbox_item",
        ref_id: w.decide.id,
        tag: "decide",
        group_key: goal_key,
        brief_rank: 1,
        brief_line: "Start here: the plan needs your yes before 5pm.",
        brief_action_label: "Approve",
        brief_tag: "risk",
        model_version: "host:test:claude_code"
      })

    {:ok, _} =
      Store.upsert_evaluation(user.id, %{
        ref_type: "inbox_item",
        ref_id: w.mention.id,
        tag: "waiting",
        previous_tag: "fyi",
        model_version: "host:test:claude_code"
      })

    :ok
  end

  defp count(user), do: Inbox.reachable_unread_count(user.id)

  describe "ok state" do
    setup %{conn: conn} do
      user = person!("ok")
      w = world!(user)
      assert :submitted = pass!(user)
      dress!(user, w)
      {:ok, lv, html} = live(auth(conn, user), "/brief")
      %{user: user, w: w, lv: lv, html: html}
    end

    test "header, live dot, brief, tags, groups, add row, quiet band, raw-list link", ctx do
      %{lv: lv, html: html, w: w} = ctx
      name = Secretary.name()

      assert has_element?(lv, "h1", name)
      assert has_element?(lv, ~s([data-role="secretary-sub"]), "is reading for you")
      assert has_element?(lv, ~s([data-role="secretary-live"]), "live")
      refute has_element?(lv, ~s([data-role="secretary-catching-up"]))

      # Right now (rows 4-8)
      assert has_element?(lv, ~s([data-role="secretary-brief"]), "Right now")
      assert has_element?(lv, ~s([data-role="secretary-brief-line"]), "Start here")
      assert has_element?(lv, ~s([data-role="secretary-brief-tag"]), "Risk")
      assert has_element?(lv, ~s([data-role="secretary-just-now"]), "just now")
      assert has_element?(lv, ~s([data-role="secretary-brief-action"]), "Approve")

      assert has_element?(
               lv,
               ~s([data-role="secretary-brief-footer"]),
               "for tonight, after family dinner."
             )

      refute has_element?(lv, ~s([data-role="secretary-all-clear"]))

      # Add your own (row 12)
      assert has_element?(lv, ~s(input[placeholder="Add something to do"]))

      # Goal groups (row 13)
      assert has_element?(lv, ~s([data-role="secretary-group-header"]), "Ship the spring launch")

      assert has_element?(
               lv,
               ~s([data-role="secretary-group-header"] small),
               "##{w.goal_space.slug} goal"
             )

      assert has_element?(lv, ~s([data-role="secretary-group-header"]), "Not tied to a goal")

      # Row tags (row 15) and no Family row tag
      for tag <- ["Decide", "Waiting on you", "FYI", "You’re not in this space", "To-do"] do
        assert has_element?(lv, ~s([data-role="secretary-row-tag"]), tag), tag
      end

      refute html =~ ~r{data-role="secretary-row-tag"[^>]*>\s*Family}

      # Moved (16) and new (17) marks
      assert has_element?(lv, ~s([data-role="secretary-moved"]), "I moved this up · was FYI")
      assert has_element?(lv, ~s([data-role="secretary-new"]), "new")

      # Not in space (18)
      assert has_element?(lv, ~s([data-role="secretary-join"]), "Join ##{w.open.slug}")

      # To-do row (19) and suggestion (22)
      assert has_element?(lv, ~s([data-role="secretary-todo-check"][aria-label="Mark done"]))
      assert has_element?(lv, ~s([data-role="secretary-todo-source"]), "you added this")

      assert has_element?(
               lv,
               ~s([data-role="secretary-suggested"]),
               "I’m hearing a to-do in ##{w.goal_space.slug}"
             )

      assert has_element?(
               lv,
               ~s([data-role="secretary-suggested-quote"]),
               "“can you confirm numbers with the bakery?”"
             )

      assert has_element?(lv, ~s([data-role="secretary-suggested-keep"]), "Keep")
      assert has_element?(lv, ~s([data-role="secretary-suggested"] button), "Edit")
      assert has_element?(lv, ~s([data-role="secretary-suggested-not"]), "Not a to-do")

      # Quietly handled (24), collapsed by default
      assert has_element?(
               lv,
               ~s([data-role="secretary-quiet-toggle"][aria-expanded="false"]),
               "Quietly handled ·"
             )

      # Raw list (25)
      assert has_element?(
               lv,
               ~s([data-role="secretary-everything-link"]),
               "See everything I looked at"
             )

      # Fallback chrome absent
      refute has_element?(lv, ~s([data-role="secretary-fallback-note"]))

      # Deferred (row 29) absent
      refute html =~ "knows"
      refute html =~ "Ask for a summary"
      refute html =~ "Ask others to unblock my work"
      refute html =~ "Inter"
    end

    test "the brief's first action is the one primary chip, the rest are text links", %{
      html: html
    } do
      actions = Regex.scan(~r{data-role="secretary-brief-action"}, html)
      assert length(actions) >= 1
      assert html =~ ~r{bg-primary[^>]*data-role="secretary-brief-action"}
    end

    test "join puts the person in the open channel and says so", %{lv: lv, w: w, user: user} do
      lv |> element(~s([data-role="secretary-join"])) |> render_click()
      assert has_element?(lv, ~s([data-role="secretary-toast"]), "Joined ##{w.open.slug}")

      assert w.open.id
             |> Chat.list_participants()
             |> Enum.any?(&(&1.participant_type == "user" and &1.participant_id == user.id))
    end

    test "adding your own to-do shows it at once with its source", %{lv: lv} do
      lv
      |> form(~s([data-role="secretary-add-row"]), %{"title" => "Look into a loyalty card"})
      |> render_submit()

      assert has_element?(
               lv,
               ~s([data-role="secretary-toast"]),
               "Added. I’ll tie it to a goal if one fits."
             )

      assert has_element?(lv, ~s([data-role="secretary-todo"]), "Look into a loyalty card")
    end

    test "done-because (row 20) and undo", %{lv: lv, w: w, user: user} do
      {:ok, _} = Todos.mark_done(user.id, w.own.id, "you sent it in the channel just now")
      send(lv.pid, {:secretary_updated, user.id})

      assert has_element?(
               lv,
               ~s([data-role="secretary-todo-done"]),
               "Done, because you sent it in the channel just now"
             )

      lv |> element(~s([data-role="secretary-todo-done"] button), "Undo") |> render_click()
      assert has_element?(lv, ~s([data-role="secretary-toast"]), "Undone. Back as it was.")
      refute has_element?(lv, ~s([data-role="secretary-todo-done"]))
    end

    test "Not a to-do folds the suggestion into the learned line (row 23), undo restores it", %{
      lv: lv
    } do
      lv |> element(~s([data-role="secretary-suggested-not"])) |> render_click()

      assert has_element?(
               lv,
               ~s([data-role="secretary-learned"]),
               "Got it, I won’t add things like this."
             )

      assert has_element?(lv, ~s([data-role="secretary-toast"]), "Learned. Undo is on the line.")
      lv |> element(~s([data-role="secretary-learned"] button), "Undo") |> render_click()
      assert has_element?(lv, ~s([data-role="secretary-suggested-keep"]))
    end

    test "Keep turns the suggestion into a to-do and names the goal", %{lv: lv} do
      lv |> element(~s([data-role="secretary-suggested-keep"])) |> render_click()
      assert has_element?(lv, ~s([data-role="secretary-toast"]), "Kept. It’s in")
      assert has_element?(lv, ~s([data-role="secretary-todo"]), "Confirm the tasting headcount")
      assert has_element?(lv, ~s([data-role="secretary-todo-source"]), "heard it")
    end

    test "a just-dismissed item shows struck as resolved elsewhere (row 21)", %{
      lv: lv,
      w: w,
      user: user
    } do
      {:ok, _} = Inbox.mark_dismissed(w.fyi.id, user.id)
      send(lv.pid, {:secretary_updated, user.id})
      assert has_element?(lv, ~s([data-role="secretary-leaving"] s), w.fyi.title)
    end

    test "the quiet band expands in place", %{lv: lv} do
      lv |> element(~s([data-role="secretary-quiet-toggle"])) |> render_click()
      assert has_element?(lv, ~s([data-role="secretary-quiet-toggle"][aria-expanded="true"]))
    end

    test "opening a row lowers Inbox.reachable_unread_count/1 by one (M23)", %{
      lv: lv,
      w: w,
      user: user
    } do
      before = count(user)

      assert {:error, {:live_redirect, %{to: to}}} =
               lv
               |> element(
                 ~s([data-role="secretary-row"][data-ref-id="#{w.decide.id}"] [data-role="secretary-row-action"])
               )
               |> render_click()

      assert to == w.decide.url
      assert count(user) == before - 1
    end

    test "the brief action opens through Inbox.open_item/2 too", %{lv: lv, w: w, user: user} do
      before = count(user)

      assert {:error, {:live_redirect, _}} =
               lv
               |> element(~s([data-role="secretary-brief-action"]), "Approve")
               |> render_click()

      assert count(user) == before - 1
      assert %{read_at: %DateTime{}} = Platform.Repo.get(Platform.Inbox.Item, w.decide.id)
    end

    test "the rail badge equals Inbox.reachable_unread_count/1, not the decide count (M19)", %{
      html: html,
      user: user
    } do
      n = count(user)
      assert n > 1
      assert [_, text] = Regex.run(~r{data-role="inbox-badge"[^>]*>\s*([^<]+?)\s*<}, html)
      assert String.trim(text) == Integer.to_string(n)
      assert Enum.count(Store.list_evaluations(user.id), &(&1.tag == "decide")) != n
    end

    test "the active rail key is inbox on /brief", %{lv: lv} do
      assert has_element?(lv, "#native-tab-bridge[data-active-key='inbox']")
    end

    test "/brief/everything lists the raw items newest first with a way back", %{
      conn: conn,
      user: user,
      w: w
    } do
      {:ok, lv, _} = live(auth(conn, user), "/brief/everything")

      assert has_element?(
               lv,
               ~s([data-role="secretary-everything-title"]),
               "Everything I looked at, newest first"
             )

      assert has_element?(
               lv,
               ~s([data-role="secretary-everything-row"][data-item-id="#{w.decide.id}"])
             )

      assert has_element?(lv, ~s([data-role="secretary-back"]), "Back to #{Secretary.name()}")
      refute has_element?(lv, ~s([data-role="secretary-brief"]))
    end
  end

  describe "catching up (row 3)" do
    test "a batch in flight shows the cue at both widths", %{conn: conn} do
      user = person!("cu")
      inbox_item!(user, "task_plan_review")

      {:ok, _} =
        Store.create_batch(user.id, %{
          item_refs:
            for(_ <- 1..3, do: %{"ref_type" => "inbox_item", "ref_id" => Ecto.UUID.generate()}),
          status: "dispatched"
        })

      {:ok, lv, _} = live(auth(conn, user), "/brief")
      assert has_element?(lv, ~s([data-role="secretary-catching-up"]), "catching up…")

      assert has_element?(
               lv,
               ~s([data-role="secretary-catching-up-desktop"]),
               "catching up on 3 new things…"
             )
    end
  end

  describe "all clear (row 9)" do
    test "with only FYIs the brief is one line and the add row is hidden", %{conn: conn} do
      user = person!("ac")
      inbox_item!(user, "meeting_invited")
      inbox_item!(user, "meeting_cancelled")
      assert :submitted = pass!(user)

      {:ok, lv, _} = live(auth(conn, user), "/brief")

      assert has_element?(
               lv,
               ~s([data-role="secretary-all-clear"]),
               "Nothing needs you right now. 2 FYIs below."
             )

      refute has_element?(lv, ~s([data-role="secretary-add-row"]))
      refute has_element?(lv, ~s([data-role="secretary-brief-line"]))
    end
  end

  describe "no-AI fallback (row 10)" do
    test "copy, groups by kind, no brief, no live dot, no add row (M21)", %{conn: conn} do
      user = person!("na")
      inbox_item!(user, "task_plan_review")
      inbox_item!(user, "chat_mention")
      inbox_item!(user, "meeting_invited")
      inbox_item!(user, "briefing")
      {:ok, _} = Todos.add_own(user.id, "Pay the invoice")
      assert :no_ai = pass!(user, eligible: fn -> {:error, :no_subscription_ai} end)

      {:ok, lv, html} = live(auth(conn, user), "/brief")
      agent = Platform.Secretary.View.agent_name(Platform.Secretary.View.agent())

      assert has_element?(
               lv,
               ~s([data-role="secretary-fallback-note"][data-fallback="no_ai"]),
               "#{agent} needs an AI login to read for you, so this is sorted by kind, not by what matters to you."
             )

      assert html =~
               "Connect your AI login and #{agent} will write you a brief and say why each thing is here."

      assert has_element?(
               lv,
               ~s([data-role="secretary-connect-ai"][href="/setup/connect-ai"]),
               "Connect AI"
             )

      for label <- ["Reviews and approvals", "Mentions", "Meetings", "Briefings", "Your to-dos"] do
        assert has_element?(lv, ~s([data-role="secretary-group-header"]), label), label
      end

      assert has_element?(lv, ~s([data-role="secretary-group-count"]), "1")
      refute has_element?(lv, ~s([data-role="secretary-brief"]))
      refute has_element?(lv, ~s([data-role="secretary-live"]))
      refute has_element?(lv, ~s([data-role="secretary-add-row"]))
      refute has_element?(lv, ~s([data-role="secretary-quiet"]))
    end
  end

  describe "budget exhausted (row 11)" do
    test "the fallback groups with the until-tomorrow line", %{conn: conn} do
      user = person!("bu")
      inbox_item!(user, "task_plan_review")
      {:ok, _} = Settings.put(user.id, %{"daily_token_ceiling" => 1000})
      assert :budget_exhausted = pass!(user)

      {:ok, lv, _} = live(auth(conn, user), "/brief")

      assert has_element?(
               lv,
               ~s([data-role="secretary-fallback-note"][data-fallback="budget"]),
               "I’ve done my reading for today, so this is sorted by kind until tomorrow."
             )

      refute has_element?(lv, ~s([data-role="secretary-connect-ai"]))
      assert has_element?(lv, ~s([data-role="secretary-group-header"]), "Reviews and approvals")
      refute has_element?(lv, ~s([data-role="secretary-brief"]))
    end
  end

  describe "/inbox redirect (M18)" do
    test "GET /inbox and /inbox?open=<id> land on /brief with the query kept", %{conn: conn} do
      user = person!("rd")
      item = inbox_item!(user)

      assert redirected_to(auth(conn, user) |> get("/inbox")) == "/brief"

      assert redirected_to(auth(conn, user) |> get("/inbox?open=#{item.id}")) ==
               "/brief?open=#{item.id}"
    end

    test "/brief?open=<id> opens the item through Inbox.open_item/2", %{conn: conn} do
      user = person!("op")
      item = inbox_item!(user, "task_sponsor_assigned")
      before = count(user)

      assert {:error, {kind, %{to: to}}} = live(auth(conn, user), "/brief?open=#{item.id}")
      assert kind in [:redirect, :live_redirect]
      assert to == item.url
      assert count(user) == before - 1
    end

    test "the detail routes stay on InboxLive and read the inbox key", %{conn: conn} do
      user = person!("dt")
      {:ok, lv, _} = live(auth(conn, user), "/inbox/briefing/#{Date.utc_today()}")
      assert has_element?(lv, "#native-tab-bridge[data-active-key='inbox']")
      assert has_element?(lv, ~s([data-role="inbox-detail-back"]), "‹ #{Secretary.name()}")
    end
  end

  describe "access" do
    test "a person with the inbox module locked is denied /brief (M22)", %{conn: conn} do
      user = person!("lk")
      org = org_of(user)

      {:ok, _} =
        Grants.deny(%{
          principal: {:user, user.id},
          permission: "inbox",
          resource: {:module, org.id}
        })

      assert {:error, {:redirect, %{to: to}}} = live(auth(conn, user), "/brief")
      assert to =~ "/access-denied"

      # Positive control: an unlocked member of the same org opens it. Without
      # the ModuleGate entry an unlisted view is denied for everyone, so this
      # is the half that tells "listed under :inbox" from "not listed at all".
      twin = person!("tw")
      assert {:ok, _, _} = live(auth(conn, twin), "/brief")
    end

    test "an external user is denied /brief and /inbox", %{conn: conn} do
      org = Tenancy.get_org_by_slug!("globex")
      ext = external_user!(org)
      assert (auth(conn, ext) |> get("/brief")).status == 403
      assert (auth(conn, ext) |> get("/inbox")).status == 403
    end
  end
end
