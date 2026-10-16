defmodule Platform.Social.TaskBridge.SegmentGuardTest do
  use Platform.DataCase, async: true

  import Platform.SocialBridgeFixtures

  alias Platform.Meetings.Candidates
  alias Platform.Social.TaskBridge.SegmentGuard

  setup do
    {:ok, meeting} =
      Platform.Meetings.create_meeting(%{
        project_id: Platform.SocialFixtures.project!(Platform.SocialFixtures.org_id!()).id,
        name: "Guard meet"
      })

    %{meeting: meeting}
  end

  test "a routable open segment passes, returning its candidate", %{meeting: m} do
    seg = segment_id()
    c = candidate!(m, seg)
    assert {:ok, [%{id: id}]} = SegmentGuard.check(m.id, [seg])
    assert id == c.id
  end

  describe "off-topic" do
    test "the model's own off_topic refuses", %{meeting: m} do
      seg = segment_id()
      candidate!(m, seg, %{classified_intent: "off_topic"})
      assert {:error, :segment_off_topic, [^seg]} = SegmentGuard.check(m.id, [seg])
    end

    test "a demoted row (off_topic with demoted_from) refuses", %{meeting: m} do
      seg = segment_id()
      candidate!(m, seg, %{classified_intent: "off_topic", demoted_from: routable_intent()})
      assert {:error, :segment_off_topic, [^seg]} = SegmentGuard.check(m.id, [seg])
    end

    # Defensive: the guard reads demoted_from on its own, so a demoted row
    # whose classified_intent was later rewritten still refuses.
    test "demoted_from alone refuses, whatever classified_intent says", %{meeting: m} do
      seg = segment_id()
      candidate!(m, seg, %{classified_intent: routable_intent(), demoted_from: "task_create"})
      assert {:error, :segment_off_topic, [^seg]} = SegmentGuard.check(m.id, [seg])
    end

    test "any off-topic row on a segment wins over a routable one", %{meeting: m} do
      seg = segment_id()
      candidate!(m, seg)
      candidate!(m, seg, %{classified_intent: "off_topic"})
      assert {:error, :segment_off_topic, [^seg]} = SegmentGuard.check(m.id, [seg])
    end
  end

  describe "retracted" do
    test "closed :retracted refuses", %{meeting: m} do
      seg = segment_id()
      closed_candidate!(m, seg, :retracted)
      assert {:error, :segment_retracted, [^seg]} = SegmentGuard.check(m.id, [seg])
    end

    test "closed :vetoed refuses", %{meeting: m} do
      seg = segment_id()
      closed_candidate!(m, seg, :vetoed)
      assert {:error, :segment_retracted, [^seg]} = SegmentGuard.check(m.id, [seg])
    end

    test "a segment threaded onto a retracted card refuses", %{meeting: m} do
      own = segment_id()
      threaded = segment_id()
      closed_candidate!(m, own, :retracted, %{transcript_chunk_ids: [own, threaded]})
      assert {:error, :segment_retracted, [^threaded]} = SegmentGuard.check(m.id, [threaded])
    end

    test "a threaded segment on a routable card passes", %{meeting: m} do
      own = segment_id()
      threaded = segment_id()
      c = candidate!(m, own, %{transcript_chunk_ids: [own, threaded]})
      assert {:ok, [%{id: id}]} = SegmentGuard.check(m.id, [threaded])
      assert id == c.id
    end

    test "closed :duplicate or :done does not refuse", %{meeting: m} do
      dup = segment_id()
      closed_candidate!(m, dup, :duplicate)
      assert {:ok, [_]} = SegmentGuard.check(m.id, [dup])
    end
  end

  describe "unclassified" do
    test "a segment with no candidate refuses", %{meeting: m} do
      seg = segment_id()
      assert {:error, :segment_unclassified, [^seg]} = SegmentGuard.check(m.id, [seg])
    end

    test "a non-UUID segment id matches nothing", %{meeting: m} do
      candidate!(m, segment_id())
      assert {:error, :segment_unclassified, ["seg-1"]} = SegmentGuard.check(m.id, ["seg-1"])
    end

    test "an open row not yet classified refuses", %{meeting: m} do
      seg = segment_id()
      candidate!(m, seg, %{classified_intent: nil})
      assert {:error, :segment_unclassified, [^seg]} = SegmentGuard.check(m.id, [seg])
    end

    test "a segment of ANOTHER meeting matches nothing here", %{meeting: m} do
      {:ok, other} =
        Platform.Meetings.create_meeting(%{project_id: m.project_id, name: "Other meet"})

      seg = segment_id()
      candidate!(other, seg)
      assert {:error, :segment_unclassified, [^seg]} = SegmentGuard.check(m.id, [seg])
    end
  end

  describe "the whole request" do
    test "one bad segment refuses all of them, naming it", %{meeting: m} do
      ok = segment_id()
      off = segment_id()
      candidate!(m, ok)
      candidate!(m, off, %{classified_intent: "off_topic"})
      before = Candidates.list_for_meeting(m.id)

      assert {:error, :segment_off_topic, [^off]} = SegmentGuard.check(m.id, [ok, off])
      assert Candidates.list_for_meeting(m.id) == before
    end

    test "off_topic outranks retracted outranks unclassified", %{meeting: m} do
      off = segment_id()
      ret = segment_id()
      none = segment_id()
      candidate!(m, off, %{classified_intent: "off_topic"})
      closed_candidate!(m, ret, :retracted)

      assert {:error, :segment_off_topic, [^off]} = SegmentGuard.check(m.id, [none, ret, off])
      assert {:error, :segment_retracted, [^ret]} = SegmentGuard.check(m.id, [none, ret])
    end
  end
end
