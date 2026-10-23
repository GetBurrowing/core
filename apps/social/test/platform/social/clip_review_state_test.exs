defmodule Platform.Social.ClipReviewStateTest do
  @moduledoc """
  Clip Studio 1/9 (task 01a16661-e234): a clip's review state is written
  ONLY by `Clip.review_changeset/2`. The general changeset and the external
  submit changeset ignore every review field and `rev`; the submit
  changeset forces an external, rendered, pending, rev-1 clip.
  """
  use Platform.DataCase, async: true

  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social.{Clip, ClipLook}

  @review_attrs %{
    "review_status" => "approved",
    "review_note" => "fine by me",
    "reviewed_by_user_id" => Ecto.UUID.generate(),
    "reviewed_at" => "2026-10-23T00:00:00Z",
    "rev" => 9,
    "origin" => "external"
  }

  setup do
    org_id = org_id!()
    project = project!(org_id)

    {:ok, profile} =
      Platform.Social.create_profile(org_id, %{name: "Review #{unique()}", project_id: project.id})

    %{org_id: org_id, profile: profile, user: user!(), video: file!(org_id)}
  end

  defp burrow_clip!(profile) do
    %Clip{profile_id: profile.id}
    |> Clip.changeset(%{source_url: "https://www.youtube.com/watch?v=abc"})
    |> Repo.insert!()
  end

  describe "Clip.changeset" do
    test "Clip.changeset ignores review fields" do
      attrs = Map.merge(@review_attrs, %{"source_url" => "https://www.youtube.com/watch?v=abc"})
      changeset = Clip.changeset(%Clip{}, attrs)

      for field <- ~w(review_status review_note reviewed_by_user_id reviewed_at rev origin)a do
        assert Ecto.Changeset.get_change(changeset, field) == nil, "#{field} was cast"
      end

      assert changeset.valid?
    end

    test "nor are they written on update", %{profile: profile} do
      clip = burrow_clip!(profile)
      {:ok, updated} = clip |> Clip.changeset(@review_attrs) |> Repo.update()

      assert %Clip{
               review_status: nil,
               review_note: nil,
               reviewed_by_user_id: nil,
               reviewed_at: nil,
               rev: 1,
               origin: "burrow"
             } = Repo.get!(Clip, updated.id)
    end

    test "title and episode_code are optional and bounded" do
      base = %{source_url: "https://x.test/v"}
      assert Clip.changeset(%Clip{}, base).valid?

      errors =
        errors_on(
          Clip.changeset(
            %Clip{},
            Map.merge(base, %{
              title: String.duplicate("t", 201),
              episode_code: String.duplicate("e", 33)
            })
          )
        )

      assert errors[:title]
      assert errors[:episode_code]
    end
  end

  describe "Clip.submit_changeset" do
    test "forces pending, external, rev 1, rendered; title and caption may be nil",
         %{profile: profile, video: file} do
      attrs =
        Map.merge(@review_attrs, %{
          "render_file_id" => file.id,
          "title" => nil,
          "caption" => nil,
          "status" => "candidate",
          "source_url" => "https://x.test/v"
        })

      {:ok, clip} = %Clip{profile_id: profile.id} |> Clip.submit_changeset(attrs) |> Repo.insert()
      clip = Repo.get!(Clip, clip.id)

      assert %Clip{
               origin: "external",
               status: "rendered",
               review_status: "pending",
               review_note: nil,
               reviewed_by_user_id: nil,
               reviewed_at: nil,
               rev: 1,
               title: nil,
               caption: nil,
               source_url: nil,
               source_file_id: nil
             } = clip

      assert clip.render_file_id == file.id
      assert %DateTime{} = clip.rendered_at
    end

    test "casts the metadata and look; needs a file; refuses a bad look", %{
      profile: profile,
      video: file
    } do
      look = ClipLook.effective(%{"cap" => %{"size" => 7.0}})

      {:ok, clip} =
        %Clip{profile_id: profile.id}
        |> Clip.submit_changeset(%{
          "render_file_id" => file.id,
          "title" => "Who makes Total War?",
          "episode_code" => "S2E14",
          "source_label" => "htc-clip-tool",
          "look" => look,
          "duration_s" => 31.5,
          "width" => 1080,
          "height" => 1920,
          "platforms" => ["tiktok"]
        })
        |> Repo.insert()

      assert %Clip{
               title: "Who makes Total War?",
               episode_code: "S2E14",
               source_label: "htc-clip-tool"
             } =
               clip

      assert Repo.get!(Clip, clip.id).look == look

      assert errors_on(Clip.submit_changeset(%Clip{}, %{}))[:render_file_id]

      bad =
        Clip.submit_changeset(%Clip{}, %{"render_file_id" => file.id, "look" => %{"nope" => 1}})

      assert errors_on(bad)[:look]
    end
  end

  describe "Clip.review_changeset" do
    test "approve sets approved, the reviewer and reviewed_at", %{profile: profile, user: user} do
      clip = burrow_clip!(profile)
      {:ok, clip} = clip |> Clip.review_changeset({:approve, user.id}) |> Repo.update()

      assert %Clip{
               review_status: "approved",
               reviewed_by_user_id: reviewer,
               reviewed_at: %DateTime{}
             } =
               Repo.get!(Clip, clip.id)

      assert reviewer == user.id
    end

    test "approve needs a reviewer", %{profile: profile} do
      clip = burrow_clip!(profile)
      assert errors_on(Clip.review_changeset(clip, {:approve, nil}))[:reviewed_by_user_id]
    end

    test "an agent id as reviewer is refused by the FK to users", %{profile: profile} do
      clip = burrow_clip!(profile)
      agent = agent!()

      assert {:error, changeset} =
               clip |> Clip.review_changeset({:approve, agent.id}) |> Repo.update()

      assert errors_on(changeset)[:reviewed_by_user_id]
    end

    test "reject trims and requires the note; blank is refused", %{profile: profile, user: user} do
      clip = burrow_clip!(profile)

      for note <- [nil, "", "   "] do
        changeset = Clip.review_changeset(clip, {:reject, user.id, note})
        refute changeset.valid?
        assert errors_on(changeset)[:review_note]
      end

      too_long = Clip.review_changeset(clip, {:reject, user.id, String.duplicate("n", 2001)})
      assert errors_on(too_long)[:review_note]

      {:ok, clip} =
        clip
        |> Clip.review_changeset({:reject, user.id, "  payoff is cut off \n"})
        |> Repo.update()

      assert %Clip{review_status: "rejected", review_note: "payoff is cut off"} =
               Repo.get!(Clip, clip.id)

      assert clip.reviewed_by_user_id == user.id
      assert %DateTime{} = clip.reviewed_at
    end

    test "reset_pending sets pending and clears note, reviewer and reviewed_at",
         %{profile: profile, user: user} do
      clip = burrow_clip!(profile)
      {:ok, clip} = clip |> Clip.review_changeset({:reject, user.id, "too long"}) |> Repo.update()
      {:ok, clip} = clip |> Clip.review_changeset(:reset_pending) |> Repo.update()

      assert %Clip{
               review_status: "pending",
               review_note: nil,
               reviewed_by_user_id: nil,
               reviewed_at: nil
             } =
               Repo.get!(Clip, clip.id)
    end

    test "follows a render changeset", %{profile: profile, video: file} do
      clip = burrow_clip!(profile)

      {:ok, clip} =
        clip
        |> Clip.render_changeset(%{status: "rendered", render_file_id: file.id})
        |> Clip.review_changeset(:reset_pending)
        |> Repo.update()

      assert %Clip{status: "rendered", review_status: "pending"} = Repo.get!(Clip, clip.id)
    end
  end
end
