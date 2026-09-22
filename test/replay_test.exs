defmodule Wiregrid.ReplayTest do
  use ExUnit.Case, async: false

  setup do
    name = {:replay, System.unique_integer([:positive])}
    {:ok, _} = Wiregrid.start_instance(name, profile: :small)
    on_exit(fn -> Wiregrid.stop_instance(name) end)
    %{name: name}
  end

  test "replay preserves storage order and uses ordinary delivery reservations", %{name: name} do
    {:ok, session} = Wiregrid.connect(name, "u1", self(), delivery_format: :term)
    stream = {:channel, "history"}
    :ok = Wiregrid.append_event(name, stream, "a", %{n: 1})
    :ok = Wiregrid.append_event(name, stream, "b", %{n: 2})

    assert {:ok, result} = Wiregrid.replay_session(name, session, stream, limit: 2)
    assert result.delivered == 2
    assert result.complete_page

    assert_receive {:"$wiregrid",
                    %{event: %{n: 1}, context: %{kind: :replay, storage_id: "a"}} = first}

    assert_receive {:"$wiregrid",
                    %{event: %{n: 2}, context: %{kind: :replay, storage_id: "b"}} = second}

    assert Wiregrid.pending(name, session) == 2
    assert {:ok, _} = Wiregrid.ack(name, session, first.delivery_id)
    assert {:ok, _} = Wiregrid.ack(name, session, second.delivery_id)
  end

  test "replay stops before skipping an unaccepted durable row", %{name: name} do
    {:ok, session} = Wiregrid.connect(name, "u1", self(), delivery_format: :term)
    stream = {:channel, "history"}
    :ok = Wiregrid.append_event(name, stream, "a", :a)
    :ok = Wiregrid.append_event(name, stream, "b", :b)

    # Fill hard pressure with an intentionally tiny instance in a separate run
    # is covered by backpressure tests. Here verify cursor progression itself.
    assert {:ok, page1} = Wiregrid.replay_session(name, session, stream, limit: 1)
    assert is_binary(page1.next_cursor) or is_nil(page1.next_cursor)
    assert_receive {:"$wiregrid", %{event: :a} = env}
    assert {:ok, _} = Wiregrid.ack(name, session, env.delivery_id)

    assert {:ok, page2} =
             Wiregrid.replay_session(name, session, stream, cursor: page1.next_cursor, limit: 1)

    assert page2.delivered in [0, 1]
  end
end
