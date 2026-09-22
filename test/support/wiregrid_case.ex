defmodule Wiregrid.TestCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Wiregrid.TestCase
    end
  end

  setup context do
    instance = {:wiregrid_test, context.module, context.test, System.unique_integer([:positive])}
    opts = Map.get(context, :wiregrid_opts, [])

    {:ok, _pid} =
      Wiregrid.start_instance(instance, Keyword.merge([profile: :small, cluster: false], opts))

    on_exit(fn ->
      _ = Wiregrid.stop_instance(instance)
    end)

    {:ok, instance: instance}
  end

  def receive_delivery(timeout \\ 1_000) do
    receive do
      {:"$wiregrid", %{delivery_id: delivery_id} = envelope} -> {delivery_id, envelope}
    after
      timeout -> flunk("expected Wiregrid delivery")
    end
  end

  def ack_delivery(instance, %{session_id: session_id, delivery_id: delivery_id}) do
    Wiregrid.ack(instance, session_id, delivery_id)
  end

  def eventually(fun, timeout \\ 1_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        do_eventually(fun, deadline)
    end
  end
end
