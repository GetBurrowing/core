defmodule PlatformWeb.AgentInitiatedDmTest do
  @moduledoc """
  An agent opening a DM with a human (task 01a04ad4), and the three rules that
  must survive it.

  Sam asked for this verbatim: *"I want you and any other agent to be able
  to DM me at anytime, for anything, especially if there is something YOU
  ACTUALLY NEED."* Measured at `ead7ddb2`, an agent could not, by three
  independent mechanisms: `tool_definitions/0` carried no DM tool at all
  (`dm_create` existed only as a word in a comment in `chat.ex`), a mention
  inside a DM is exempt from the auto-add every other space kind gets, and
  `dm` is not one of `ChatLive`'s `@implicitly_joinable_kinds`.

  ## The distinction the whole design rests on

  An agent opening a 1:1 DM **with** a human is a different act from an agent
  getting **into** a DM **between** two humans. The second is what the privacy
  contract protects and what PR #835 closed; the first exposes nobody's
  conversation, because it is a NEW space whose entire roster is the agent and
  the person it is addressing.

  `dm_create` takes a PERSON, never a `space_id`, so there is no input by
  which it could be aimed at somebody else's conversation. This file is the
  executable form of that claim.

  ## Anti-vacuity — how each refusal here is kept honest

  A `refute` whose subject can never occur passes under every implementation,
  including one with no guard at all. That defect shipped in PR #856 and had
  to be fixed in #859, so every refusal below is paired:

    * "the agent is not handed a human↔human DM" is paired with
      `reuses a DM the human opened first` — the SAME find-branch, proven to
      return a pre-existing space when the roster does match. Without that
      pair, a `find_or_create_agent_dm/2` that never found anything would pass
      the refusal for free.

    * "an @-mention in a DM still does not auto-add the agent" is paired with
      the same mention text posted in a CHANNEL, which MUST add it. Without
      that pair, an `extract_bracketed_tokens/1` that stopped parsing `@[…]`
      at all would satisfy the refusal.

    * "an internal non-member is still refused at a human↔human DM" is paired
      with the same user auto-joining a workspace channel. Without that pair,
      a `handle_params/3` that refused everything would pass.

    * The external-user refusal asserts NO dm space exists afterwards, not
      merely that the call errored — an error return with the space already
      written is the failure mode that matters.

  ## Mutations run against this file (results in the PR body)

    * `existing_agent_dm/2`: drop the `pa.participant_id == ^agent_id` clause,
      so the lookup matches any DM the target is in.
    * `existing_agent_dm/2`: widen `s.kind == "dm"` to
      `s.kind in ["dm", "group", "channel"]` — the ticket's "widen the new
      permission to any space kind".
    * `find_or_create_agent_dm/2`: delete the `Tenancy.external_user?/1` arm.
    * `authorize_dm_target/2`: replace the tenant arm with `:ok`.
    * `reinvite_and_pin_mentioned/1`: delete the `space.kind == "dm"` arm.
    * `ChatLive`'s `@implicitly_joinable_kinds`: add `dm`.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp insert_user(opts \\ []) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "agentdm-#{n}@example.com",
      name: Keyword.get(opts, :name, "Agent DM #{n}"),
      oidc_sub: "oidc-agentdm-#{n}",
      avatar_url: nil
    })
  end

  defp insert_agent(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      slug: "dmagent-#{n}",
      name: "DM Agent #{n}",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    {:ok, agent} =
      %Agent{} |> Agent.changeset(Map.merge(defaults, attrs)) |> Repo.insert()

    agent
  end

  defp authed(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp add_user(space, user_or_id, name, role \\ "member") do
    id = if is_binary(user_or_id), do: user_or_id, else: user_or_id.id

    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: id,
        display_name: name,
        role: role,
        joined_at: DateTime.utc_now()
      })

    p
  end

  # A DM between two OTHER people — neither of them the agent under test. This
  # is the arrangement the privacy contract exists for.
  defp dm_between_humans(kind \\ "dm") do
    {:ok, space} = Chat.create_space(%{kind: kind, is_direct: kind == "dm"})
    a = insert_user(name: "Human One")
    b = insert_user(name: "Human Two")
    add_user(space, a, a.name)
    add_user(space, b, b.name)
    {space, a, b}
  end

  defp create_channel do
    n = System.unique_integer([:positive])

    {:ok, ch} =
      Chat.create_space(%{
        name: "Agent DM Channel #{n}",
        slug: "agentdm-channel-#{n}",
        kind: "channel",
        org_id: Tenancy.get_org_by_slug!("acme").id
      })

    ch
  end

  defp participant_pairs(space_id) do
    space_id
    |> Chat.list_participants()
    |> Enum.map(&{&1.participant_type, &1.participant_id})
    |> Enum.sort()
  end

  defp dm_call(agent, user_id, message) do
    ToolSurface.execute(
      "dm_create",
      %{"user_id" => user_id, "message" => message},
      %{agent_id: agent.id}
    )
  end

  # The rail slice, lifted from `ChatLiveCloseDmTest` — `<aside
  # id="chat-sidebar">` is the only place a DM row's `data-space-id` lives on
  # a `<div>`, so this is unambiguous.
  defp sidebar(html) do
    case Regex.run(~r/<aside[^>]*id="chat-sidebar".*?<\/aside>/s, html) do
      [match] -> match
      _ -> ""
    end
  end

  defp rail_has_space?(html, space_id) do
    sidebar(html) =~ ~s(data-space-id="#{space_id}")
  end

  defp live_rail(conn) do
    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
    end
  end

  setup do
    # The premise of the whole file. A user with no `org_memberships` row is
    # INTERNAL (`Tenancy.external_user?/1` is an EXISTS over memberships with
    # `external == true`). If that flipped, the external-user refusal below
    # would be doing the denying everywhere and every result here would be
    # true for the wrong reason.
    u = insert_user()
    refute Tenancy.external_user?(%{id: u.id}), "fixture users must be INTERNAL"
    :ok
  end

  # ── 1. It works, and the human actually receives it ─────────────────────

  describe "an agent opening a DM with a human" do
    test "the human's rail shows it and the message body renders in their client", %{conn: conn} do
      agent = insert_agent(%{name: "Higgins Prime"})
      human = insert_user(name: "Sam Moreno")
      body = "I need a call on the deploy target before I can finish this."

      assert {:ok, %{space_id: space_id, message_id: message_id}} =
               dm_call(agent, human.id, body)

      # The agent is a party to what it created.
      assert %Chat.Participant{} = Chat.get_agent_participant(space_id, agent.id)
      assert Chat.get_space(space_id).kind == "dm"

      # THE assertion the ticket asks for: not "a row was written", but what
      # the recipient's own client renders. The rail read
      # (`Chat.list_user_conversations/2`) joins on the caller's user id, so
      # this can only pass if the human holds a real participant row.
      conn = authed(conn, human)
      {:ok, _rail_view, rail_html} = live_rail(conn)

      assert rail_has_space?(rail_html, space_id),
             "the DM the agent opened is not on the recipient's rail"

      assert sidebar(rail_html) =~ "Higgins Prime",
             "the rail row is not labelled with the agent who opened it"

      {:ok, view, _html} = live(conn, ~p"/chat/#{space_id}")
      html = render(view)

      assert html =~ body, "the recipient's client does not render the message body"

      assert has_element?(view, ~s([data-message-id="#{message_id}"])),
             "the message row the tool returned is not in the recipient's DOM"

      assert has_element?(view, "#compose-form"),
             "the recipient cannot reply — the DM opened read-only"
    end

    test "it is idempotent: a second call reuses the same thread", %{conn: conn} do
      agent = insert_agent()
      human = insert_user()

      assert {:ok, %{space_id: first}} = dm_call(agent, human.id, "one")
      assert {:ok, %{space_id: second}} = dm_call(agent, human.id, "two")

      assert first == second,
             "an agent calling dm_create twice minted the recipient a second conversation"

      assert length(participant_pairs(first)) == 2

      # Both messages landed in the one thread the human sees.
      {:ok, view, _} = live(authed(conn, human), ~p"/chat/#{first}")
      html = render(view)
      assert html =~ "one"
      assert html =~ "two"
    end

    # POSITIVE CONTROL for the find-branch. Without this test, a
    # `find_or_create_agent_dm/2` whose lookup never matched ANYTHING would
    # pass "the agent is not handed a human↔human DM" for free.
    test "reuses a DM the human opened first, rather than opening a second one" do
      agent = insert_agent()
      human = insert_user()

      {:ok, human_opened} = Chat.find_or_create_dm(human.id, "agent", agent.id)

      assert {:ok, %{space_id: space_id}} = dm_call(agent, human.id, "picking this up")

      assert space_id == human_opened.id,
             "dm_create opened a duplicate thread beside the one the human already had"
    end

    test "refuses an agent as the target — this is a tool for reaching HUMANS" do
      agent = insert_agent()
      other_agent = insert_agent()

      assert {:error, %{error: error}} = dm_call(agent, other_agent.id, "hello")
      assert error =~ "no such user"
    end
  end

  # ── 2. The invariant: somebody else's DM is still somebody else's ───────

  describe "a DM between two other humans" do
    test "is never what dm_create returns, and the agent gets no row in it" do
      agent = insert_agent()
      {theirs, human_one, _human_two} = dm_between_humans()

      before_roster = participant_pairs(theirs.id)
      assert length(before_roster) == 2

      # The agent addresses one of the two people who are in that DM. This is
      # the shape where a lookup keyed on the TARGET alone would hand back the
      # wrong space.
      assert {:ok, %{space_id: space_id}} = dm_call(agent, human_one.id, "need you")

      refute space_id == theirs.id,
             "dm_create returned the conversation the target is having with somebody else"

      assert participant_pairs(theirs.id) == before_roster,
             "dm_create wrote a participant row into a DM between two other people"

      refute Chat.get_agent_participant(theirs.id, agent.id),
             "the agent got a participant row in a DM it is not a party to"

      # And the message went to the new space, not theirs.
      assert Chat.list_messages(theirs.id) == []
    end

    # The ticket's named mutation ("widen the new permission to any space
    # kind") lands here: a GROUP already containing both parties must not
    # satisfy the DM lookup.
    test "a group conversation containing both parties is not reused as the DM" do
      agent = insert_agent()
      human = insert_user()

      {:ok, group} = Chat.create_space(%{kind: "group"})
      add_user(group, human, human.name)
      {:ok, _} = Chat.add_agent_participant(group.id, agent)
      before_messages = length(Chat.list_messages(group.id))

      assert {:ok, %{space_id: space_id}} = dm_call(agent, human.id, "private word")

      refute space_id == group.id,
             "dm_create posted into an existing GROUP instead of opening a 1:1 DM"

      assert Chat.get_space(space_id).kind == "dm"

      assert length(Chat.list_messages(group.id)) == before_messages,
             "the group conversation received the message meant to be a private DM"
    end

    test "an @-mention inside it still does NOT auto-add the agent" do
      agent = insert_agent(%{name: "Mentionable One"})
      {theirs, human_one, _} = dm_between_humans()

      author =
        theirs.id
        |> Chat.list_participants()
        |> Enum.find(&(&1.participant_type == "user" and &1.participant_id == human_one.id))

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: theirs.id,
          participant_id: author.id,
          content_type: "text",
          content: "hey @[Mentionable One] can you look at this"
        })

      refute Chat.get_agent_participant(theirs.id, agent.id),
             "an @-mention pulled an agent into a DM between two humans"
    end

    # POSITIVE CONTROL for the assertion directly above. The mention-reinvite
    # path MUST still work everywhere it is supposed to; if it did not, the
    # refusal above would be free and would prove nothing about DMs.
    test "the SAME @-mention in a channel DOES add the agent" do
      agent = insert_agent(%{name: "Mentionable Two"})
      channel = create_channel()
      human = insert_user()
      # Admin: since task 01a0ac64 stage 1 only an authorized author can
      # summon an agent, so the positive control must use one — otherwise
      # the DM refusal above would be free.
      author = add_user(channel, human, human.name, "admin")

      refute Chat.get_agent_participant(channel.id, agent.id)

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: channel.id,
          participant_id: author.id,
          content_type: "text",
          content: "hey @[Mentionable Two] can you look at this"
        })

      assert Chat.get_agent_participant(channel.id, agent.id),
             "mention-reinvite is broken in channels, so the DM refusal above proves nothing"
    end

    test "an internal non-member is still refused at it, and still mints no row", %{conn: conn} do
      {theirs, _, _} = dm_between_humans()
      bystander = insert_user()
      before_roster = participant_pairs(theirs.id)

      assert {:error, {:live_redirect, %{to: "/chat"}}} =
               live(authed(conn, bystander), ~p"/chat/#{theirs.id}")

      assert participant_pairs(theirs.id) == before_roster,
             "PR #835's implicit-join closure has been undone"
    end

    # POSITIVE CONTROL for the refusal above: a fix that refused everything
    # would pass it and break chat for the whole team.
    test "while a workspace channel still implicitly joins the same user", %{conn: conn} do
      channel = create_channel()
      bystander = insert_user()

      assert {:ok, view, _html} = live(authed(conn, bystander), ~p"/chat/#{channel.id}")
      assert has_element?(view, "#compose-form")

      assert {"user", bystander.id} in participant_pairs(channel.id),
             "implicit join into a workspace channel is broken, so the DM refusal proves nothing"
    end
  end

  # ── 3. Who an agent may DM ──────────────────────────────────────────────

  describe "reachability" do
    test "an external (guest) user is refused, and no DM space is written" do
      agent = insert_agent()
      org = Tenancy.get_org_by_slug!("acme")
      guest = insert_user()
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: guest.id, org_id: org.id})
      assert Tenancy.external_user?(%{id: guest.id})

      assert {:error, %{error: error}} = dm_call(agent, guest.id, "hello")
      assert error =~ "external"

      # Not merely "it errored" — the space must not exist. An error returned
      # after the insert is the failure that matters.
      assert Chat.list_user_conversations(guest.id) == [],
             "a DM space was created for an external user despite the refusal"
    end

    test "while an internal user in the same org is reachable" do
      agent = insert_agent()
      internal = insert_user()

      assert {:ok, %{space_id: space_id}} = dm_call(agent, internal.id, "hello")
      assert Enum.any?(Chat.list_user_conversations(internal.id), &(&1.id == space_id))
    end

    test "a tenant-pinned agent cannot reach a user outside its org" do
      tenant = Tenancy.get_org_by_slug!("soylent")
      assert tenant.parent_org_id, "soylent must be a TENANT or agent_home_org/1 returns :root"

      agent = insert_agent(%{metadata: %{"org_id" => tenant.id}})
      outsider = insert_user()

      assert {:error, %{error: error}} = dm_call(agent, outsider.id, "hello")
      assert error =~ "not reachable from your org"
      assert Chat.list_user_conversations(outsider.id) == []
    end

    # POSITIVE CONTROL: the same tenant-pinned agent reaching someone who IS
    # in its org. Without this, a rule that denied every tenant agent would
    # pass the refusal above.
    test "but it can reach a user who holds a membership in its own org" do
      tenant = Tenancy.get_org_by_slug!("soylent")
      agent = insert_agent(%{metadata: %{"org_id" => tenant.id}})
      colleague = insert_user()

      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: colleague.id,
        org_id: tenant.id,
        role: "member"
      })
      |> Repo.insert!()

      assert {:ok, %{space_id: space_id}} = dm_call(agent, colleague.id, "need you")
      assert Enum.any?(Chat.list_user_conversations(colleague.id), &(&1.id == space_id))
    end

    test "a root-scoped agent reaches the same out-of-org user the tenant agent could not" do
      agent = insert_agent()
      outsider = insert_user()

      assert {:ok, %{space_id: space_id}} = dm_call(agent, outsider.id, "hello")
      assert Enum.any?(Chat.list_user_conversations(outsider.id), &(&1.id == space_id))
    end

    test "dm_create is not offered to external principals" do
      refute ToolSurface.external_chat_tool?("dm_create")
      # Positive control: the allowlist is not simply empty.
      assert ToolSurface.external_chat_tool?("send_media")
    end
  end
end
