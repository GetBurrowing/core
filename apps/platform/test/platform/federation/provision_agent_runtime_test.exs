defmodule Platform.Federation.ProvisionAgentRuntimeTest do
  @moduledoc """
  `Federation.provision_agent_runtime/3` (task 01a10322 stage 1): the ONE core
  composition of register, link and activate, now behind both the federate
  onboarding form and native agents.

  Two properties:

    * the federate form behaves as it did when it composed the three steps
      itself (same rows, same token shown once, same flash);
    * the three steps are one transaction, so a failure in step 2 or step 3
      leaves no runtime row from step 1. Before this stage a failed link left
      a `pending` runtime behind.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation
  alias Platform.Repo

  defp create_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "provision-#{n}@example.com",
      name: "Provision #{n}",
      oidc_sub: "oidc-provision-#{n}"
    })
  end

  defp runtime_rows(runtime_id),
    do: Repo.all(from(r in AgentRuntime, where: r.runtime_id == ^runtime_id))

  defp open_federate_form(conn, user) do
    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/control")
    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "federate"})
    view
  end

  describe "submit_federate through the shared function" do
    test "creates the same linked, active runtime and shows its token once", %{conn: conn} do
      user = create_user()
      n = System.unique_integer([:positive])
      runtime_id = "federate-form-#{n}"

      html =
        conn
        |> open_federate_form(user)
        |> form("#federate-form",
          federate: %{
            runtime_id: runtime_id,
            display_name: "Form Box",
            agent_name: "Form Agent #{n}"
          }
        )
        |> render_submit()

      assert [runtime] = runtime_rows(runtime_id)
      agent = Repo.get_by!(Agent, slug: "form-agent-#{n}")

      assert runtime.status == "active"
      assert runtime.owner_user_id == user.id
      assert runtime.display_name == "Form Box"
      assert runtime.agent_id == agent.id
      assert runtime.managed_by == nil
      assert agent.runtime_type == "external"
      assert agent.runtime_id == runtime.id
      assert agent.name == "Form Agent #{n}"

      assert html =~ "Federated agent Form Agent #{n} created."
      assert html =~ runtime_id

      # The token on the page is the one whose hash is stored.
      [token] =
        ~r/[A-Za-z0-9_-]{43}/
        |> Regex.scan(html)
        |> List.flatten()
        |> Enum.filter(&(AgentRuntime.hash_token(&1) == runtime.auth_token_hash))
        |> Enum.uniq()

      assert Federation.get_runtime_by_token(token).id == runtime.id
    end

    test "a failed link leaves no runtime row and shows the error", %{conn: conn} do
      user = create_user()
      n = System.unique_integer([:positive])

      # Occupy the slug so step 2 (the agent insert) fails.
      Repo.insert!(
        Agent.changeset(%Agent{}, %{slug: "taken-#{n}", name: "Taken", status: "active"})
      )

      runtime_id = "federate-taken-#{n}"

      html =
        conn
        |> open_federate_form(user)
        |> form("#federate-form",
          federate: %{runtime_id: runtime_id, display_name: "", agent_name: "Taken #{n}"}
        )
        |> render_submit()

      assert html =~ "slug already taken"
      assert runtime_rows(runtime_id) == []
    end
  end

  describe "provision_agent_runtime/3 is one transaction" do
    test "returns the linked agent, the active runtime and a token that authenticates" do
      user = create_user()
      n = System.unique_integer([:positive])

      assert {:ok, %Agent{} = agent, %AgentRuntime{} = runtime, raw} =
               Federation.provision_agent_runtime(
                 user.id,
                 %{slug: "prov-#{n}", name: "Prov", status: "active"},
                 %{"runtime_id" => "prov-rt-#{n}", "display_name" => "Prov box"}
               )

      assert runtime.agent_id == agent.id
      assert runtime.status == "active"
      assert agent.runtime_id == runtime.id
      assert Federation.get_runtime_by_token(raw).id == runtime.id
    end

    test "a failure in step 2 (link) rolls back step 1 (register)" do
      user = create_user()
      n = System.unique_integer([:positive])

      Repo.insert!(Agent.changeset(%Agent{}, %{slug: "dup-#{n}", name: "Dup", status: "active"}))

      assert {:error, %Ecto.Changeset{} = changeset} =
               Federation.provision_agent_runtime(
                 user.id,
                 %{slug: "dup-#{n}", name: "Dup again", status: "active"},
                 %{runtime_id: "dup-rt-#{n}"}
               )

      assert {"slug already taken in this workspace", _} = changeset.errors[:slug]
      assert runtime_rows("dup-rt-#{n}") == []
    end

    test "a failure in step 3 (activate) rolls back steps 1 and 2" do
      user = create_user()
      n = System.unique_integer([:positive])
      runtime_id = "noactivate-#{n}"

      # Refuse activation of THIS runtime only, inside the test's own sandbox
      # transaction (Postgres DDL is transactional, so it is gone afterwards).
      Repo.query!("""
      ALTER TABLE agent_runtimes ADD CONSTRAINT test_01a10322_no_activate
      CHECK (status <> 'active' OR runtime_id <> '#{runtime_id}') NOT VALID
      """)

      assert_raise Ecto.ConstraintError, ~r/test_01a10322_no_activate/, fn ->
        Federation.provision_agent_runtime(
          user.id,
          %{slug: "noactivate-#{n}", name: "No activate", status: "active"},
          %{runtime_id: runtime_id}
        )
      end

      assert runtime_rows(runtime_id) == []
      assert Repo.get_by(Agent, slug: "noactivate-#{n}") == nil
    end

    test "an unknown runtime attribute is refused before anything is written" do
      user = create_user()

      assert_raise ArgumentError, ~r/unknown runtime attribute/, fn ->
        Federation.provision_agent_runtime(user.id, %{slug: "x", name: "X"}, %{
          "runtime_id" => "x",
          "no_such_field" => 1
        })
      end

      assert runtime_rows("x") == []
    end
  end
end
