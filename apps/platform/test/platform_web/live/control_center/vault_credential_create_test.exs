defmodule PlatformWeb.ControlCenter.VaultCredentialCreateTest do
  @moduledoc """
  The Control Center's create-a-credential surface.

  Before this existed, `Platform.Vault` was reachable from a browser only as a
  side effect of onboarding an external agent, so adding a standalone provider
  key meant an `iex` session on a production host. This file pins the two
  things that make the front door safe to open.

  ## Every absence assertion carries a positive control

  A `refute html =~ secret` passes trivially on an empty page, on a page that
  never rendered the form, and on a submit that silently failed — which is
  exactly the shape of defect this repo shipped in #856. So each one is paired:

    * "the secret is not rendered" is paired with `Vault.get/1` returning the
      secret (the write really happened) AND the slug appearing in the rendered
      list (the page really rendered the record). Only the secret is missing.
    * "the secret is not logged" is paired with a second `capture_log/1` that
      asserts a deliberately logged marker IS captured, so an empty capture
      cannot masquerade as a clean one.
    * "a non-admin changes nothing" is paired with an admin firing the same
      event by name and changing state, so a handler that refused everyone
      could not pass.

  ## Refusals are fired by name, capabilities are driven through the form

  A non-admin has no button to click, so a test that could only click proves
  the affordance is hidden rather than that the write is refused — the gate
  must hold against a client that never rendered a control. The admin cases do
  the opposite and submit the rendered form, because a capability test that
  passes on a page with no form is testing the wrong thing. Same split as
  `PlatformWeb.ExperimentsLiveTest`.
  """

  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias Platform.Vault
  alias Platform.Vault.AccessGrant
  alias Platform.Vault.Credential

  # LazyHTML.query/2, not filter/2 — filter matches only the fragment's root
  # nodes, so a nested element comes back [] and reads as "not there".
  defp q(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp user!(prefix) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "#{prefix}-#{n}@example.com",
      name: "Vault #{prefix}",
      oidc_sub: "oidc-#{prefix}-#{n}"
    })
  end

  defp member_conn(conn), do: init_test_session(conn, current_user_id: user!("vault-member").id)

  defp admin_conn(conn) do
    user = user!("vault-admin")
    org = Tenancy.get_org_by_slug!("acme")

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "admin"})
    |> Repo.insert!()

    init_test_session(conn, current_user_id: user.id)
  end

  defp agent! do
    n = System.unique_integer([:positive, :monotonic])

    %Agent{}
    |> Agent.changeset(%{
      slug: "vault-ui-agent-#{n}",
      name: "Vault UI Agent",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6", "fallbacks" => []}
    })
    |> Repo.insert!()
  end

  defp slug_of(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  # Reads the stored value off the ROW, not through `Vault.get/2`. Two reasons:
  # `get/2` enforces `:use`, which an agent-scoped credential denies to a nil
  # accessor, and at a slug that exists at two scopes `get/2` now refuses
  # outright (`{:error, :ambiguous_slug}`) rather than naming either row. The
  # Cloak type decrypts on load, so this is the plaintext.
  defp stored_value(%Credential{id: id}), do: Repo.get!(Credential, id).encrypted_data

  defp rows_at(slug), do: Credential |> Repo.all() |> Enum.filter(&(&1.slug == slug))

  defp open_form(conn, agent) do
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")
    render_click(view, "toggle_credential_form", %{})
    view
  end

  defp submit(view, params) do
    view |> form(~s([data-role="credential-form"]), params) |> render_submit()
  end

  describe "an admin creates a platform credential through the rendered form" do
    test "the credential lands in the vault and the secret is never rendered", %{conn: conn} do
      agent = agent!()
      slug = slug_of("elevenlabs")
      secret = "sk-not-in-the-html-#{System.unique_integer([:positive])}"

      view = open_form(admin_conn(conn), agent)

      # The form is real UI, not a hook target: locating it by data-role and
      # submitting it fails if the form stops being rendered.
      html = submit(view, %{"slug" => slug, "name" => "ElevenLabs", "secret" => secret})

      # POSITIVE CONTROL 1 — the write actually happened. Read back through the
      # vault, not through the changeset the handler returned.
      assert {:ok, ^secret} = Vault.get(slug)

      # POSITIVE CONTROL 2 — the page rendered the record. Without this the
      # refute below passes on an empty page or a failed submit.
      assert html =~ slug
      assert q(html, ~s([data-role="vault-manage"])) |> Enum.count() == 1

      # THE ASSERTION. Only the secret is absent.
      refute html =~ secret

      # And it is absent from a fresh mount too, not merely from this diff.
      {:ok, _view, remount} = live(admin_conn(conn), ~p"/control/#{agent.slug}")
      assert remount =~ slug
      refute remount =~ secret
    end

    test "the stored row carries the metadata the form collected", %{conn: conn} do
      agent = agent!()
      slug = slug_of("metadata")

      view = open_form(admin_conn(conn), agent)

      submit(view, %{
        "slug" => slug,
        "name" => "Metadata Key",
        "credential_type" => "token",
        "provider" => "elevenlabs",
        "expires_at" => "2027-01-31",
        "secret" => "s3cret"
      })

      credential = Repo.get_by!(Credential, slug: slug)
      assert credential.name == "Metadata Key"
      assert credential.credential_type == "token"
      assert credential.provider == "elevenlabs"
      assert credential.scope_type == "platform"
      assert is_nil(credential.scope_id)
      assert DateTime.to_date(credential.expires_at) == ~D[2027-01-31]
    end

    test "the secret never reaches the log", %{conn: conn} do
      agent = agent!()
      slug = slug_of("unlogged")
      secret = "sk-never-logged-#{System.unique_integer([:positive])}"

      view = open_form(admin_conn(conn), agent)

      log = capture_log(fn -> submit(view, %{"slug" => slug, "secret" => secret}) end)

      # POSITIVE CONTROL 1 — the write happened, so there WAS something to log.
      assert {:ok, ^secret} = Vault.get(slug)

      # POSITIVE CONTROL 2 — capture_log is actually capturing at this level.
      # Without it, a capture that returns "" for unrelated reasons reads as a
      # clean log and the refute below proves nothing.
      marker = "vault-log-capture-probe-#{System.unique_integer([:positive])}"

      assert capture_log(fn ->
               require Logger
               Logger.error(marker)
             end) =~ marker

      refute log =~ secret
    end

    test "a duplicate-slug failure does not echo the secret back", %{conn: conn} do
      # `Vault.put/4` returns {:error, changeset} on the unique-slug
      # constraint and that changeset holds the plaintext in
      # `changes.encrypted_data`. Rendering it — via to_form, an inspect, or a
      # flash built from the struct — would put the secret on the page. Here
      # the collision is at AGENT scope, which the form refuses outright, so
      # the error path runs with a secret in hand and nothing may leak.
      agent = agent!()
      slug = slug_of("collide")
      secret = "sk-collision-#{System.unique_integer([:positive])}"

      {:ok, existing} = Vault.put(slug, :api_key, "pre-existing", scope: {:agent, agent.id})

      view = open_form(admin_conn(conn), agent)
      html = submit(view, %{"slug" => slug, "secret" => secret})

      # POSITIVE CONTROL — the refusal rendered and named the slug, so the
      # page is not blank and the refute has something to be absent from.
      assert html =~ slug
      assert html =~ "agent scope"
      refute html =~ secret

      # And nothing was written: the pre-existing value is untouched, and no
      # second row appeared at this slug.
      assert stored_value(existing) == "pre-existing"
      assert rows_at(slug) |> Enum.count() == 1
    end
  end

  describe "replacing a value goes through Vault.rotate/3" do
    test "the row keeps its id and its access grants survive", %{conn: conn} do
      agent = agent!()
      slug = slug_of("rotating")

      {:ok, original} = Vault.put(slug, :api_key, "v1", scope: {:platform, nil})

      grant =
        Repo.insert!(%AccessGrant{
          credential_id: original.id,
          grantee_type: "agent",
          grantee_id: agent.id,
          permissions: ["use", "rotate"]
        })

      view = open_form(admin_conn(conn), agent)
      html = submit(view, %{"slug" => slug, "secret" => "v2"})

      # The value moved.
      assert {:ok, "v2"} = Vault.get(slug)

      # THE POINT — same row. A delete-then-put would mint a new id, and the
      # grant below would have been cascaded away with the old one.
      replaced = Repo.get_by!(Credential, slug: slug)
      assert replaced.id == original.id
      assert Repo.get(AccessGrant, grant.id)
      assert Repo.get(AccessGrant, grant.id).permissions == ["use", "rotate"]

      # Exactly one row at this slug — it was replaced, not duplicated.
      assert Repo.all(Credential) |> Enum.count(&(&1.slug == slug)) == 1

      # The history is continuous and records the rotation against the acting
      # admin, not an anonymous system accessor.
      actions = slug |> Vault.access_log() |> Enum.map(& &1.action)
      assert "rotate" in actions

      rotate_entry = slug |> Vault.access_log() |> Enum.find(&(&1.action == "rotate"))
      assert rotate_entry.accessor_type == "platform"

      # The flash says which of the two things happened, so a replacement is
      # never silent.
      assert html =~ "Replaced the value of #{slug}"
    end

    test "a slug living at two scopes is refused rather than guessed at", %{conn: conn} do
      # `Vault.rotate/3` resolves its target with a slug-only lookup that has
      # `limit: 1` and no `order_by`, while the uniqueness constraint is
      # per-scope — so one slug can exist twice and which row rotate picks is
      # undetermined. The form must not roll that die.
      agent = agent!()
      slug = slug_of("ambiguous")

      {:ok, platform_row} = Vault.put(slug, :api_key, "platform-value", scope: {:platform, nil})
      {:ok, agent_row} = Vault.put(slug, :api_key, "agent-value", scope: {:agent, agent.id})

      view = open_form(admin_conn(conn), agent)
      html = submit(view, %{"slug" => slug, "secret" => "would-clobber-one-of-them"})

      assert html =~ "more than one scope"

      # Neither was touched. Asserted POSITIVELY, on each row by id: a
      # `refute ... == "would-clobber"` over `Vault.get/2` passes without
      # reading anything, because `get/2` denies the agent-scoped row to a nil
      # accessor and returns {:error, :access_denied} for it.
      assert rows_at(slug) |> Enum.count() == 2
      assert stored_value(platform_row) == "platform-value"
      assert stored_value(agent_row) == "agent-value"
    end
  end

  describe "reads are member-visible, writes are admin-only" do
    test "a member sees the panel but no write affordance", %{conn: conn} do
      agent = agent!()
      {:ok, _} = Vault.put(slug_of("visible"), :api_key, "v", scope: {:platform, nil})

      {:ok, _view, member_html} = live(member_conn(conn), ~p"/control/#{agent.slug}")
      {:ok, _view, admin_html} = live(admin_conn(conn), ~p"/control/#{agent.slug}")

      # The absence assertion is not vacuous: the member reached the page and
      # the admin sees the very control the member does not.
      assert member_html =~ agent.name
      refute member_html =~ "Vault visibility"
      assert q(admin_html, ~s([data-role="vault-manage"])) |> Enum.count() == 1
      assert q(member_html, ~s([data-role="vault-manage"])) |> Enum.count() == 0
      assert q(admin_html, ~s([data-role="toggle-credential-form"])) |> Enum.count() == 1
      assert q(member_html, ~s([data-role="toggle-credential-form"])) |> Enum.count() == 0
    end

    test "a member firing the write events by name creates nothing", %{conn: conn} do
      agent = agent!()
      before = Repo.aggregate(Credential, :count)

      {:ok, view, _html} = live(member_conn(conn), ~p"/control/#{agent.slug}")

      # By NAME. The member has no form to submit, and a gate that only held
      # against clicks would not be a gate.
      render_hook(view, "toggle_credential_form", %{})

      render_hook(view, "create_credential", %{
        "slug" => "forged-by-a-member",
        "secret" => "sk-should-never-be-stored"
      })

      assert Repo.aggregate(Credential, :count) == before
      assert Repo.get_by(Credential, slug: "forged-by-a-member") == nil
      assert Vault.get("forged-by-a-member") == {:error, :not_found}
    end

    test "an admin firing the same event by name does create — the control", %{conn: conn} do
      # Without this, the previous test passes against a handler that refused
      # everyone, or against an event name that no clause matches at all.
      agent = agent!()
      slug = slug_of("admin-by-name")

      {:ok, view, _html} = live(admin_conn(conn), ~p"/control/#{agent.slug}")
      render_hook(view, "create_credential", %{"slug" => slug, "secret" => "sk-admin"})

      assert {:ok, "sk-admin"} = Vault.get(slug)
    end
  end
end
