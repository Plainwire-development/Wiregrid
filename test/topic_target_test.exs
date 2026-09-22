defmodule Wiregrid.TopicTargetTest do
  use ExUnit.Case, async: true

  test "topic constructors are the canonical plain terms" do
    assert Wiregrid.Topic.user("u") == {:user, "u"}
    assert Wiregrid.Topic.channel("c") == {:channel, "c"}
    assert Wiregrid.Topic.thread("t") == {:thread, "t"}
    assert Wiregrid.Topic.room("r") == {:room, "r"}
    assert Wiregrid.Topic.game("g") == {:game, "g"}
    assert Wiregrid.Topic.document("d") == {:document, "d"}
    assert Wiregrid.Topic.custom("ns", "v") == {:custom, "ns", "v"}
  end

  test "dispatch target constructors add no wrapper state" do
    topic = Wiregrid.Topic.channel("general")
    assert Wiregrid.Target.topic(topic) == {:topic, topic}
    assert Wiregrid.Target.room("call") == {:room, "call"}
    assert Wiregrid.Target.user("u") == {:user, "u"}
    assert Wiregrid.Target.session("s") == {:session, "s"}
  end
end
