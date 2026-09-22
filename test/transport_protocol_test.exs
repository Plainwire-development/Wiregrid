defmodule Wiregrid.TransportProtocolTest do
  use ExUnit.Case, async: true

  alias Wiregrid.Transport.Protocol.Term, as: TermProtocol

  test "term protocol round-trips bounded ordinary terms" do
    command = {:request, "1", {:subscribe, {:channel, "general"}}}
    assert {:ok, encoded} = TermProtocol.encode(command)
    assert {:ok, ^command} = TermProtocol.decode(encoded)
  end

  test "term protocol rejects compressed ETF" do
    binary = :erlang.term_to_binary({:publish, String.duplicate("x", 10_000)}, compressed: 9)
    assert {:error, :compressed_term_rejected} = TermProtocol.decode(binary)
  end
end

defmodule Wiregrid.CowboyTransportBoundaryTest do
  use ExUnit.Case, async: false

  alias Wiregrid.Transport.Cowboy
  alias Wiregrid.Transport.Protocol.Term, as: TermProtocol

  setup do
    instance = {:cowboy_boundary, System.unique_integer([:positive])}
    {:ok, _pid} = Wiregrid.start_instance(instance, max_rate_limit_buckets: 100)
    {:ok, session_id} = Wiregrid.connect(instance, "transport-user", self())

    state = %{
      instance: instance,
      user_id: "transport-user",
      session_id: session_id,
      protocol: TermProtocol,
      command_handler: nil,
      max_frame_size: 1_048_576,
      frame_rate_limit: 100,
      frame_window_ms: 60_000,
      ack_strategy: :client
    }

    on_exit(fn -> Wiregrid.stop_instance(instance) end)
    %{instance: instance, session_id: session_id, state: state}
  end

  test "authenticated transport rejects malformed option lists instead of sanitizing them", %{
    state: state
  } do
    command =
      {:request, "bad-opts",
       {:publish, {:channel, "general"}, %{body: "hi"}, [{:class, :durable}, :broken]}}

    {:ok, frame} = TermProtocol.encode(command)

    assert {:reply, {:binary, response}, _state} =
             Cowboy.websocket_handle({:binary, frame}, state)

    assert {:ok, {:response, "bad-opts", {:error, :invalid_options}}} =
             TermProtocol.decode(response)
  end

  test "authenticated transport identity cannot be overridden by command options", %{
    session_id: session_id,
    state: state
  } do
    command =
      {:request, "override",
       {:publish, {:channel, "general"}, %{body: "hi"}, [session_id: session_id]}}

    {:ok, frame} = TermProtocol.encode(command)

    assert {:reply, {:binary, response}, _state} =
             Cowboy.websocket_handle({:binary, frame}, state)

    assert {:ok, {:response, "override", {:error, :transport_session_override}}} =
             TermProtocol.decode(response)
  end

  test "frame rate admission happens before command decode/dispatch", %{state: state} do
    state = %{state | frame_rate_limit: 1, frame_window_ms: 60_000}
    {:ok, frame} = TermProtocol.encode({:request, "ping-1", {:ping, 1}})

    assert {:reply, {:binary, first}, _} = Cowboy.websocket_handle({:binary, frame}, state)
    assert {:ok, {:response, "ping-1", {:pong, 1}}} = TermProtocol.decode(first)

    assert {:reply, {:binary, second}, _} = Cowboy.websocket_handle({:binary, frame}, state)
    assert {:ok, {:error, nil, :rate_limited}} = TermProtocol.decode(second)
  end
end
