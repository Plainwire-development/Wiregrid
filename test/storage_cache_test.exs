defmodule Wiregrid.StorageCacheTest do
  use Wiregrid.TestCase, async: false

  test "memory storage is idempotent and pages with stable composite cursors", %{
    instance: instance
  } do
    stream = {:channel, "history"}
    assert :ok = Wiregrid.Storage.append(instance, stream, "a", %{body: "A"})
    assert :ok = Wiregrid.Storage.append(instance, stream, "b", %{body: "B"})
    assert :ok = Wiregrid.Storage.append(instance, stream, "a", %{body: "ignored retry"})

    assert {:ok, %{id: "a", event: %{body: "A"}}} = Wiregrid.Storage.get(instance, stream, "a")
    assert {:ok, [first], cursor} = Wiregrid.Storage.page(instance, stream, nil, 1)
    assert is_binary(cursor)
    assert {:ok, [second], nil} = Wiregrid.Storage.page(instance, stream, cursor, 10)
    assert MapSet.new([first.id, second.id]) == MapSet.new(["a", "b"])
  end

  test "memory cache separates values and counters and honors TTL", %{instance: instance} do
    assert :ok = Wiregrid.Cache.put(instance, "value", %{ok: true}, 500)
    assert {:ok, %{ok: true}} = Wiregrid.Cache.get(instance, "value")
    assert {:error, :not_a_counter} = Wiregrid.Cache.incr(instance, "value", 1, 500)

    assert {:ok, 1} = Wiregrid.Cache.incr(instance, "counter", 1, 50)
    assert {:ok, 3} = Wiregrid.Cache.incr(instance, "counter", 2, 50)
    assert {:ok, 3} = Wiregrid.Cache.get(instance, "counter")
    assert eventually(fn -> Wiregrid.Cache.get(instance, "counter") == :miss end, 1_500)
  end

  test "concurrent memory counter increments are atomic", %{instance: instance} do
    results =
      1..100
      |> Task.async_stream(fn _ -> Wiregrid.Cache.incr(instance, "hot", 1, 5_000) end,
        max_concurrency: 32,
        timeout: 5_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok, {:ok, value}} -> is_integer(value)
             _ -> false
           end)

    assert {:ok, 100} = Wiregrid.Cache.get(instance, "hot")
  end

  test "concurrent cache replacement and deletion cannot strand a fresh generation", %{
    instance: instance
  } do
    assert :ok = Wiregrid.Cache.put(instance, "aba", :initial, 5_000)

    tasks =
      for n <- 1..64 do
        Task.async(fn ->
          if rem(n, 3) == 0 do
            Wiregrid.Cache.delete(instance, "aba")
          else
            Wiregrid.Cache.put(instance, "aba", {:value, n}, 100)
          end
        end)
      end

    Enum.each(tasks, &Task.await(&1, 5_000))

    # A clean final generation must remain readable, then expire on its own.
    assert :ok = Wiregrid.Cache.put(instance, "aba", :final, 50)
    assert {:ok, :final} = Wiregrid.Cache.get(instance, "aba")
    assert eventually(fn -> Wiregrid.Cache.get(instance, "aba") == :miss end, 1_500)
  end
end
