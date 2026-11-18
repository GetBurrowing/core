defmodule Platform.SocialStudioFixtures do
  @moduledoc """
  Fixtures for the Studio flow boundary tests (Social Studio slice A).

  Slice A has no approve/plan transitions (slice B supplies them), so
  `studio_post!/4` builds an `approved` or `planned` Studio post the way the
  later slice will leave it: through `Studio.create_post/4`, then the same
  columns and one `current` approval row written directly. That is test
  scaffolding, not a path the product has.

  `drop_boundary_check!/0` drops the Studio boundary CHECK for the rest of
  the test (the sandbox transaction rolls the DDL back). It exists so the
  CODE refusals can be proven on their own: with the CHECK gone a forged
  Studio row can hold a vendor id, and only the refusal stands between it
  and the publisher.
  """

  import Ecto.Query
  import Platform.SocialFixtures

  alias Ecto.Changeset
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Clip, Post, PostApproval, Studio}
  alias Platform.Social.Publisher.Fake

  @doc "The clip-pipeline world with Studio switched on for its profile."
  def studio_world! do
    w = render_world!()
    {:ok, profile} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, true)
    %{w | profile: profile}
  end

  @doc """
  A Studio post on `account` in `status`: draft, needs_approval, approved or
  planned. Approved and planned rows carry the approver columns and one
  `current` approval row; planned rows carry a future plan.
  """
  def studio_post!(w, account, status \\ "needs_approval", attrs \\ %{}) do
    create_status = if status == "draft", do: "draft", else: "needs_approval"

    {:ok, post} =
      Studio.create_post(
        w.org_id,
        account.id,
        w.approver.id,
        Map.merge(%{body: "Studio body #{unique()}", status: create_status}, attrs)
      )

    case status do
      s when s in ~w(draft needs_approval) -> post
      "approved" -> approve!(post, w.approver)
      "planned" -> post |> approve!(w.approver) |> plan!(w.approver)
    end
  end

  defp approve!(%Post{} = post, approver) do
    now = DateTime.utc_now()

    post =
      post
      |> Changeset.change(status: "approved", approved_by_user_id: approver.id, approved_at: now)
      |> Repo.update!()

    PostApproval
    |> struct!()
    |> PostApproval.changeset(%{
      post_id: post.id,
      version: post.version,
      account_id: post.account_id,
      approved_by_user_id: approver.id,
      approved_at: now,
      state: "current",
      content_fingerprint: "fixture-#{post.id}"
    })
    |> Repo.insert!()

    post
  end

  defp plan!(%Post{} = post, approver) do
    post
    |> Changeset.change(
      status: "planned",
      scheduled_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
      planned_by_user_id: approver.id,
      planned_set_at: DateTime.utc_now(),
      state_rev: 1
    )
    |> Repo.update!()
  end

  @doc "Changes columns on a row with no validation and no CHECK bypass (the DB still checks)."
  def force!(%Post{} = post, changes), do: post |> Changeset.change(changes) |> Repo.update!()

  @doc """
  Drops the Studio boundary CHECK for this test only. Forged rows made
  after it may hold vendor ids, `publish_after` and `scheduled` status.
  """
  def drop_boundary_check! do
    Repo.query!("ALTER TABLE social_posts DROP CONSTRAINT social_posts_studio_boundary_check")
    :ok
  end

  @doc "A Studio post forged into a sent-looking state (call `drop_boundary_check!/0` first)."
  def forge_sent!(%Post{} = post, status \\ "scheduled", external_id \\ nil) do
    external_id = external_id || "ext-#{unique()}"

    post
    |> Changeset.change(
      status: status,
      external_id: external_id,
      approved_by_user_id: post.approved_by_user_id,
      approved_at: post.approved_at || DateTime.utc_now()
    )
    |> Repo.update!()
  end

  @doc "An externally submitted, review-pending clip on the world's profile."
  def pending_clip!(w, bytes \\ "rendered clip #{unique()}") do
    file = stored_file!(w.project, bytes, "clip.mp4", "video/mp4")

    {:ok, clip} =
      Social.AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => file.id,
          "title" => "Agent title",
          "caption" => "Agent caption",
          "duration_s" => 30.0,
          "width" => 1080,
          "height" => 1920
        },
        w.agent.id
      )

    clip
  end

  @doc "Marks a clip as a Studio clip (the marker slice C's intake will set at insert)."
  def make_studio_clip!(%Clip{id: id} = clip) do
    {1, _} = Repo.update_all(from(c in Clip, where: c.id == ^id), set: [flow: "studio"])
    Repo.get!(Clip, clip.id)
  end

  # ── Slice B helpers (real transitions, not forged rows) ──────────────

  @doc "The optimistic tokens a caller observed for `post`, plus `extra` keys."
  def expect(%Post{} = post, extra \\ %{}),
    do: Map.merge(%{state_rev: post.state_rev, version: post.version}, extra)

  @doc "A `needs_approval` Studio post made through `Studio.create_post/4`."
  def submitted_post!(w, account, attrs \\ %{}),
    do: studio_post!(w, account, "needs_approval", attrs)

  @doc "Approves `post` through `Studio.approve_version/4` as `user` (default the world's approver)."
  def studio_approve!(w, %Post{} = post, user \\ nil) do
    {:ok, %{post: approved}} =
      Studio.approve_version(w.org_id, post.id, (user || w.approver).id, expect(post))

    approved
  end

  @doc "Plans an approved `post` an hour from now through `Studio.plan_post/5`."
  def studio_plan!(w, %Post{} = post, user \\ nil, at \\ nil) do
    at = at || DateTime.add(DateTime.utc_now(), 3_600, :second)

    {:ok, %{post: planned}} =
      Studio.plan_post(w.org_id, post.id, (user || w.approver).id, expect(post), at)

    planned
  end

  @doc "A new live approver of the world's profile (member of the org, on the list)."
  def approver2!(w), do: make_approver!(w.org_id, w.profile, user!())

  @doc "Event actions of a post, oldest first."
  def actions(post_or_id) do
    id = if is_struct(post_or_id), do: post_or_id.id, else: post_or_id
    id |> Platform.Social.PostEvents.list_for_post() |> Enum.map(& &1.action)
  end

  @doc "Receipts of a post, oldest first."
  def receipts(post_or_id) do
    id = if is_struct(post_or_id), do: post_or_id.id, else: post_or_id

    Repo.all(
      from(a in PostApproval, where: a.post_id == ^id, order_by: [asc: a.approved_at, asc: a.id])
    )
  end

  @doc "Row counts a refused call must leave alone: posts, events, receipts."
  def write_counts do
    {Repo.aggregate(Post, :count), Repo.aggregate(Platform.Social.PostEvent, :count),
     Repo.aggregate(PostApproval, :count)}
  end

  @doc """
  Makes every later insert of an `action` event fail (CHECK), for this test
  only (the sandbox transaction rolls the DDL back).
  """
  def fail_event!(action) do
    Repo.query!(
      "ALTER TABLE social_post_events ADD CONSTRAINT boom_event CHECK (action <> '#{action}') NOT VALID"
    )

    :ok
  end

  @doc "Reads the row straight from the database."
  def fresh(%Post{id: id}), do: Repo.get!(Post, id)

  @doc "Every Fake publisher call except the inbound signature check."
  def send_calls, do: Enum.reject(Fake.calls(), &match?({:verify_webhook, _, _}, &1))
end
