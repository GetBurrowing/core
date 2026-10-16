defmodule Platform.Social.PublisherTest do
  @moduledoc """
  The adapter is selected by `config :social, :publisher` alone, read on
  every call; unset means `{:error, :publisher_not_configured}`. Also pins
  the publisher columns: `is_aigc` forced on for agent-generated media, and
  the `platform_account_type` CHECK at the database.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{Account, Post, Publisher}

  describe "impl/0" do
    setup do
      previous = Application.get_env(:social, :publisher)
      on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
      :ok
    end

    test "test env selects the Fake" do
      assert Publisher.impl() == Platform.Social.Publisher.Fake
    end

    test "unset answers :publisher_not_configured, read on every call" do
      Application.delete_env(:social, :publisher)
      assert Publisher.impl() == {:error, :publisher_not_configured}

      Application.put_env(:social, :publisher, SomeVendorAdapter)
      assert Publisher.impl() == SomeVendorAdapter
    end

    test "prod config sets no publisher" do
      config = Config.Reader.read!(Path.expand("../../../config/config.exs", __DIR__), env: :prod)
      refute get_in(config, [:social, :publisher])
    end
  end

  describe "posts: is_aigc forcing" do
    setup do
      org_id = org_id!()
      {:ok, profile} = Social.create_profile(org_id, %{name: "AIGC #{unique()}"})
      {:ok, account} = Social.create_account(org_id, profile, %{platform: "tiktok"})
      %{org_id: org_id, account: account, agent: agent!()}
    end

    test "generated_by_agent_id forces is_aigc true", ctx do
      assert {:ok, post} =
               Social.create_post(ctx.org_id, ctx.account, %{
                 body: "agent cut",
                 generated_by_agent_id: ctx.agent.id,
                 is_aigc: false
               })

      assert post.is_aigc == true
      assert Repo.get!(Post, post.id).is_aigc == true
    end

    test "is_aigc can never be cleared while generated_by_agent_id is set", ctx do
      {:ok, post} =
        Social.create_post(ctx.org_id, ctx.account, %{
          body: "x",
          generated_by_agent_id: ctx.agent.id
        })

      assert {:ok, post} = Social.update_post(ctx.org_id, post, %{is_aigc: false})
      assert post.is_aigc == true
      assert Repo.get!(Post, post.id).is_aigc == true
    end

    test "without an agent, is_aigc defaults false and carries ai_disclosure and media_meta",
         ctx do
      {:ok, post} =
        Social.create_post(ctx.org_id, ctx.account, %{
          body: "human",
          ai_disclosure: "Edited with AI",
          media_meta: %{"f1" => %{"duration_s" => 30}}
        })

      post = Repo.get!(Post, post.id)
      assert post.is_aigc == false
      assert post.ai_disclosure == "Edited with AI"
      assert post.media_meta == %{"f1" => %{"duration_s" => 30}}

      assert {:ok, %{is_aigc: false}} = Social.update_post(ctx.org_id, post, %{is_aigc: false})
    end
  end

  describe "accounts: platform_account_type" do
    setup do
      org_id = org_id!()
      {:ok, profile} = Social.create_profile(org_id, %{name: "Types #{unique()}"})
      %{org_id: org_id, profile: profile}
    end

    test "a bad value is refused by the CHECK at the database (insert_all)", ctx do
      row = fn type ->
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          profile_id: Ecto.UUID.dump!(ctx.profile.id),
          platform: "instagram",
          platform_account_type: type,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      end

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn -> Repo.insert_all("social_accounts", [row.("enterprise")]) end)
        end

      assert error.postgres.constraint == "social_accounts_platform_account_type_check"

      for ok <- ["personal", "business", "creator", nil] do
        assert {:ok, {1, _}} =
                 Repo.transaction(fn -> Repo.insert_all("social_accounts", [row.(ok)]) end)
      end
    end

    test "the changeset accepts the three types and the profile takes a vendor ref", ctx do
      assert {:ok, %Account{platform_account_type: "creator"}} =
               Social.create_account(ctx.org_id, ctx.profile, %{
                 platform: "instagram",
                 platform_account_type: "creator"
               })

      assert {:error, cs} =
               Social.create_account(ctx.org_id, ctx.profile, %{
                 platform: "instagram",
                 platform_account_type: "enterprise"
               })

      assert errors_on(cs)[:platform_account_type]

      assert {:ok, %{provider_profile_ref: "vendor-profile-1"}} =
               Social.update_profile(ctx.org_id, ctx.profile, %{
                 provider_profile_ref: "vendor-profile-1"
               })
    end
  end
end
