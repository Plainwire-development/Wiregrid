defmodule Wiregrid.ExternalIsolationTest.CaptureStorage do
  @behaviour Wiregrid.Storage

  def bootstrap(_opts), do: :ok

  def append(opts, stream, id, _event, _meta, _ts) do
    send(
      Keyword.fetch!(opts, :test_pid),
      {:captured_stream, Keyword.fetch!(opts, :instance), stream, id}
    )

    :ok
  end

  def get(_opts, _stream, _id), do: :not_found
  def page(_opts, _stream, _cursor, _limit), do: {:ok, [], nil}
  def delete(_opts, _stream, _id), do: :ok
  def prune(_opts, _stream, _before, _limit), do: {:ok, 0}
  def health(_opts), do: :ok
end

defmodule Wiregrid.ExternalIsolationTest.FakeRedis do
  def command(test_pid, command) do
    send(test_pid, {:redis_command, command})

    case command do
      ["EVAL" | _] -> {:ok, 1}
      ["PING"] -> {:ok, "PONG"}
      ["GET" | _] -> {:ok, nil}
      ["DEL" | _] -> {:ok, 0}
      _ -> {:ok, nil}
    end
  end
end

defmodule Wiregrid.ExternalIsolationTest do
  use ExUnit.Case, async: false

  alias Wiregrid.ExternalIsolationTest.{CaptureStorage, FakeRedis}

  test "durable stream identifiers are isolated by Wiregrid instance" do
    a = {:isolation, System.unique_integer([:positive]), :a}
    b = {:isolation, System.unique_integer([:positive]), :b}
    storage = {CaptureStorage, [test_pid: self()]}

    {:ok, _} = Wiregrid.start_instance(a, profile: :small, storage: storage)
    {:ok, _} = Wiregrid.start_instance(b, profile: :small, storage: storage)

    on_exit(fn ->
      Wiregrid.stop_instance(a)
      Wiregrid.stop_instance(b)
    end)

    stream = {:channel, "same-logical-stream"}
    :ok = Wiregrid.append_event(a, stream, "1", :event)
    :ok = Wiregrid.append_event(b, stream, "1", :event)

    assert_receive {:captured_stream, ^a, encoded_a, "1"}
    assert_receive {:captured_stream, ^b, encoded_b, "1"}
    refute encoded_a == encoded_b
  end

  test "Redis default keys derive a distinct instance namespace" do
    common = [client_module: FakeRedis, conn: self(), prefix: "wg-test:"]

    assert :ok =
             Wiregrid.Cache.Redis.put(
               Keyword.put(common, :instance, {:cache, :a}),
               "key",
               :value,
               :infinity
             )

    assert_receive {:redis_command, ["EVAL", _script, "2", key_a, counter_a, _value, "0"]}

    assert :ok =
             Wiregrid.Cache.Redis.put(
               Keyword.put(common, :instance, {:cache, :b}),
               "key",
               :value,
               :infinity
             )

    assert_receive {:redis_command, ["EVAL", _script, "2", key_b, counter_b, _value, "0"]}

    refute key_a == key_b
    refute counter_a == counter_b
    assert String.ends_with?(key_a, "v:key")
    assert String.ends_with?(key_b, "v:key")
  end
end
