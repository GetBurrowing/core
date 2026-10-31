defmodule Platform.Federation.SpaceCreateToolTest do
  @moduledoc """
  Tests for the `space_create` tool surface clause.

  The tool exists because the alternative — agents creating channels via a raw
  `Platform.Chat.create_channel/1` RPC and then hand-adding participants —
  repeatedly wrote `chat_participants` rows with a NULL `display_name`, which
  silently dropped every `@[Name]` mention of the affected agent. So the
  load-bearing assertion here is that every participant it writes has a
  non-null, correctly-resolved display name.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{Participant, Space}
  alias Platform.Federation.{ToolDoc, ToolSurface}
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp create_agent(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      slug: "agent-#{n}",
      name: "Dalton",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  describe "space_create" do
    test "creates a channel and every participant has a resolved display_name" do
      caller = create_agent(%{name: "Dalton"})
      other = create_agent(%{name: "Higgins"})

      assert {:ok, result} =
               ToolSurface.execute(
                 "space_create",
                 %{
                   "name" => "Webhook Intake",
                   "slug" => "webhook-intake-#{System.unique_integer([:positive])}",
                   "description" => "Inbound webhook triage",
                   "agent_ids" => [other.id]
                 },
                 %{agent_id: caller.id}
               )

      assert result.kind == "channel"
      assert result.name == "Webhook Intake"
      assert result.skipped == []

      # The whole point of the tool.
      refute Enum.any?(result.participants, &is_nil(&1.display_name))

      names = result.participants |> Enum.map(& &1.display_name) |> Enum.sort()
      assert "Dalton" in names
      assert "Higgins" in names

      # And it holds in the database, not just in the response payload.
      persisted = Chat.list_participants(result.id, participant_type: "agent")
      refute persisted == []
      refute Enum.any?(persisted, &(is_nil(&1.display_name) or &1.display_name == ""))
    end

    test "the calling agent is added as a participant" do
      caller = create_agent(%{name: "Dalton"})

      assert {:ok, result} =
               ToolSurface.execute(
                 "space_create",
                 %{"name" => "Files Module #{System.unique_integer([:positive])}"},
                 %{agent_id: caller.id}
               )

      assert Enum.any?(result.participants, &(&1.agent_id == caller.id))
    end

    test "derives a slug from the name when none is given" do
      caller = create_agent()

      assert {:ok, result} =
               ToolSurface.execute(
                 "space_create",
                 %{"name" => "Email  System!!"},
                 %{agent_id: caller.id}
               )

      assert result.slug == "email-system"
    end

    test "requires a name" do
      caller = create_agent()

      assert {:error, envelope} =
               ToolSurface.execute("space_create", %{}, %{agent_id: caller.id})

      assert envelope.error =~ "name"
      assert envelope.recoverable
    end

    test "a slug collision is a recoverable error, not a silent reuse" do
      caller = create_agent()
      slug = "certification-system-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               ToolSurface.execute(
                 "space_create",
                 %{"name" => "Certification", "slug" => slug},
                 %{agent_id: caller.id}
               )

      assert {:error, envelope} =
               ToolSurface.execute(
                 "space_create",
                 %{"name" => "Certification", "slug" => slug},
                 %{agent_id: caller.id}
               )

      assert envelope.recoverable
    end

    test "unresolvable extra agents are reported in skipped, not fatal" do
      caller = create_agent()

      assert {:ok, result} =
               ToolSurface.execute(
                 "space_create",
                 %{
                   "name" => "Partial #{System.unique_integer([:positive])}",
                   "agent_ids" => ["not-a-real-agent"]
                 },
                 %{agent_id: caller.id}
               )

      assert [%{agent_id: "not-a-real-agent"}] = result.skipped
      assert Enum.any?(result.participants, &(&1.agent_id == caller.id))
    end

    test "is exposed in the space capability bundle" do
      names =
        ToolSurface.list_tools(["space"])
        |> Enum.map(& &1.name)

      assert "space_create" in names

      definition =
        ToolSurface.tool_definitions()
        |> Enum.find(&(&1.name == "space_create"))

      assert definition.bundle == "space"
    end
  end

  describe "space_create admin_user_ids (task 01a19355 stage 2)" do
    setup do
      %{
        org_id: Tenancy.get_org_by_slug!("initech").id,
        other_org_id: Tenancy.get_org_by_slug!("globex").id,
        caller: create_agent(%{name: "Dalton"})
      }
    end

    defp user!(attrs \\ %{}) do
      n = System.unique_integer([:positive])

      Repo.insert!(
        struct(
          %Platform.Accounts.User{
            name: "Paige #{n}",
            email: "paige-#{n}@example.com",
            oidc_sub: "sub-paige-#{n}"
          },
          attrs
        )
      )
    end

    defp member!(user, org_id, external \\ false) do
      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: user.id,
        org_id: org_id,
        role: "member",
        external: external
      })
      |> Repo.insert!()

      user
    end

    defp slug!, do: "paige-builds-#{System.unique_integer([:positive])}"

    defp create(args, caller),
      do: ToolSurface.execute("space_create", args, %{agent_id: caller.id})

    defp user_rows(space_id) do
      Repo.all(
        from(p in Participant, where: p.space_id == ^space_id and p.participant_type == "user")
      )
    end

    defp user_rows_for(user_id) do
      Repo.aggregate(
        from(p in Participant,
          where: p.participant_type == "user" and p.participant_id == ^user_id
        ),
        :count
      )
    end

    test "an internal member is seated as admin, can summon, and their mention adds an agent",
         ctx do
      paige = member!(user!(), ctx.org_id)
      slug = slug!()

      assert {:ok, result} =
               create(
                 %{
                   "name" => "Paige Builds",
                   "slug" => slug,
                   "org_id" => ctx.org_id,
                   "admin_user_ids" => [paige.id]
                 },
                 ctx.caller
               )

      assert [%{user_id: user_id, participant_id: pid, display_name: name}] = result.admins
      assert user_id == paige.id
      assert name == paige.name

      space = Repo.get_by!(Space, slug: slug)
      assert [%Participant{id: ^pid, role: "admin"} = row] = user_rows(space.id)
      assert row.participant_id == paige.id
      assert Chat.can_summon_agents?(space, paige.id)

      # The same mention path mention_summon_authorization_test.exs drives.
      agent =
        Repo.insert!(%Agent{
          name: "Summoned #{pid}",
          slug: "summoned-#{System.unique_integer([:positive])}",
          status: "active"
        })

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: row.id,
          content_type: "text",
          content: "hey @[" <> agent.slug <> "] please look"
        })

      assert [_] =
               Repo.all(
                 from(p in Participant,
                   where:
                     p.space_id == ^space.id and p.participant_type == "agent" and
                       p.participant_id == ^agent.id
                 )
               )
    end

    test "each bad id is refused with its reason and no channel is created", ctx do
      foreign = member!(user!(), ctx.other_org_id)
      external = member!(user!(), ctx.org_id, true)
      archived = member!(user!(%{archived_at: DateTime.utc_now()}), ctx.org_id)
      unknown = Ecto.UUID.generate()

      for {id, reason} <- [
            {unknown, "unknown"},
            {"not-a-uuid", "malformed"},
            {foreign.id, "not_in_org"},
            {external.id, "not_in_org"},
            {archived.id, "archived"}
          ] do
        slug = slug!()

        assert {:error, envelope} =
                 create(
                   %{
                     "name" => "Bad",
                     "slug" => slug,
                     "org_id" => ctx.org_id,
                     "admin_user_ids" => [id]
                   },
                   ctx.caller
                 )

        assert envelope.recoverable
        assert envelope.invalid_admin_user_ids == [%{id: id, reason: reason}], inspect(id)
        assert Repo.get_by(Space, slug: slug) == nil
      end

      for u <- [foreign, external, archived], do: assert(user_rows_for(u.id) == 0)
    end

    test "one good and one bad id refuses the whole call: no space, no rows", ctx do
      good = member!(user!(), ctx.org_id)
      bad = member!(user!(), ctx.other_org_id)
      slug = slug!()

      assert {:error, envelope} =
               create(
                 %{
                   "name" => "Mixed",
                   "slug" => slug,
                   "org_id" => ctx.org_id,
                   "admin_user_ids" => [good.id, bad.id]
                 },
                 ctx.caller
               )

      assert envelope.invalid_admin_user_ids == [%{id: bad.id, reason: "not_in_org"}]
      assert Repo.get_by(Space, slug: slug) == nil
      assert user_rows_for(good.id) == 0
      assert user_rows_for(bad.id) == 0
    end

    test "non-empty ids with no resolvable org are refused and nothing is created", ctx do
      paige = member!(user!(), ctx.org_id)
      slug = slug!()

      assert {:error, envelope} =
               create(
                 %{"name" => "No org", "slug" => slug, "admin_user_ids" => [paige.id]},
                 ctx.caller
               )

      assert envelope.recoverable
      assert envelope.error =~ "admin_user_ids needs a channel org; pass org_id"
      assert Repo.get_by(Space, slug: slug) == nil
      assert user_rows_for(paige.id) == 0
    end

    test "non-string entries are refused and nothing is created", ctx do
      slug = slug!()

      for ids <- [[123], [""], "not-a-list"] do
        assert {:error, %{recoverable: true}} =
                 create(
                   %{
                     "name" => "Typed",
                     "slug" => slug,
                     "org_id" => ctx.org_id,
                     "admin_user_ids" => ids
                   },
                   ctx.caller
                 )

        assert Repo.get_by(Space, slug: slug) == nil
      end
    end

    test "a duplicate id yields one admin row", ctx do
      paige = member!(user!(), ctx.org_id)
      slug = slug!()

      assert {:ok, result} =
               create(
                 %{
                   "name" => "Dup",
                   "slug" => slug,
                   "org_id" => ctx.org_id,
                   "admin_user_ids" => [paige.id, paige.id]
                 },
                 ctx.caller
               )

      assert [_] = result.admins
      space = Repo.get_by!(Space, slug: slug)
      assert [%Participant{role: "admin"}] = user_rows(space.id)
    end

    test "an empty list adds an empty admins key and no user rows", ctx do
      slug = slug!()

      assert {:ok, result} =
               create(
                 %{
                   "name" => "Empty",
                   "slug" => slug,
                   "org_id" => ctx.org_id,
                   "admin_user_ids" => []
                 },
                 ctx.caller
               )

      assert result.admins == []
      assert user_rows(Repo.get_by!(Space, slug: slug).id) == []
    end

    test "REGRESSION: without admin_user_ids the result keys and rows are unchanged", ctx do
      slug = slug!()

      assert {:ok, result} =
               create(%{"name" => "Plain", "slug" => slug, "org_id" => ctx.org_id}, ctx.caller)

      assert Enum.sort(Map.keys(result)) ==
               Enum.sort([
                 :id,
                 :name,
                 :slug,
                 :org_id,
                 :description,
                 :kind,
                 :participants,
                 :skipped
               ])

      space = Repo.get_by!(Space, slug: slug)
      assert user_rows(space.id) == []

      assert [%Participant{attention_mode: "mention", role: "member"}] =
               Repo.all(
                 from(p in Participant,
                   where:
                     p.space_id == ^space.id and p.participant_type == "agent" and
                       p.participant_id == ^ctx.caller.id
                 )
               )
    end

    test "the rendered tool description documents admin_user_ids" do
      definition =
        ToolSurface.tool_definitions()
        |> Enum.find(&(&1.name == "space_create"))

      rendered = ToolDoc.render_description(definition)
      assert rendered =~ "admin_user_ids"
      refute rendered =~ "Human users are not added"
      assert Map.has_key?(definition.parameters, :admin_user_ids)
    end
  end
end
