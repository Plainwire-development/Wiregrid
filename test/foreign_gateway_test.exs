defmodule Wiregrid.ForeignGatewayTest do
  use Wiregrid.TestCase, async: false

  alias Wiregrid.Foreign.Gateway
  alias Wiregrid.Foreign.JSON
  alias Wiregrid.Foreign.Protocol
  alias Wiregrid.Foreign.Topic
  alias Wiregrid.Transport.Protocol.JSON, as: JsonProtocol

  test "topic text uses the same channels as chat" do
    assert {:ok, {:channel, "general"}} = Topic.parse("general")
    assert {:ok, {:channel, "general"}} = Topic.parse("channel:general")
    assert Topic.format({:channel, "general"}) == "general"
    assert {:ok, {:thread, "42"}} = Topic.parse("thread:42")
    assert Topic.format({:thread, "42"}) == "thread:42"
    assert {:ok, {:channel, 7}} = Topic.parse("channel:i:7")
    assert Topic.format({:channel, 7}) == "channel:i:7"
    assert {:error, :unsupported_topic} = Topic.parse("channel:a:general")
    assert {:ok, {:custom, "ops", "desk"}} = Topic.parse("custom:ops:desk")
    assert Topic.format({:channel, :general}) == "channel:a:general"
  end

  test "chat events round trip through json" do
    event = %{type: :message, body: "hello \"there\""}
    assert {:ok, encoded} = JSON.encode(event)
    assert {:ok, decoded} = JSON.decode_event(encoded)
    assert decoded.type == :message
    assert decoded.body == "hello \"there\""
    assert {:ok, "hi 😀"} = JSON.decode(~s("hi \\uD83D\\uDE00"))
    assert {:error, :duplicate_json_key} = JSON.decode(~s({"a":1,"a":2}))
    assert {:error, :invalid_json} = JSON.decode(~s({"a":1,}))
  end

  test "browser commands decode onto chat topics" do
    assert {:ok, {:request, 3, {:subscribe, {:channel, "general"}}}} =
             JsonProtocol.decode(~s({"id":3,"op":"subscribe","topic":"general"}))

    assert {:ok, {:request, 4, {:publish, {:channel, "general"}, event, opts}}} =
             JsonProtocol.decode(
               ~s({"id":4,"op":"publish","topic":"general","event":{"type":"message","body":"hi"}})
             )

    assert event == %{type: :message, body: "hi"}
    assert opts[:class] == :durable
    assert opts[:persist] == true

    assert {:ok, json} =
             JsonProtocol.encode(
               {:event,
                %{topic: {:channel, "general"}, delivery_id: "d1", class: :durable, event: event}}
             )

    assert {:ok,
            %{
              "type" => "event",
              "topic" => "general",
              "event" => %{"type" => "message", "body" => "hi"}
            }} =
             JSON.decode(json)
  end

  test "read history asks the authorizer" do
    instance = {:history_auth, System.unique_integer([:positive])}

    {:ok, _} =
      Wiregrid.start_instance(instance,
        profile: :small,
        cluster: false,
        authorizer: Wiregrid.Authorizer.DenyAll
      )

    on_exit(fn -> Wiregrid.stop_instance(instance) end)
    {:ok, sid} = Wiregrid.connect(instance, "ada", self())
    assert {:error, :unauthorized} = Wiregrid.read_history(instance, sid, {:channel, "general"})
  end

  test "gateway refuses anonymous clients and a public allow_anonymous bind", %{
    instance: instance
  } do
    assert {:error, %ArgumentError{message: message}} =
             Gateway.start_link(
               instance: instance,
               ip: {10, 1, 0, 8},
               port: 0,
               allow_anonymous: true
             )

    assert message =~ "allow_anonymous"

    {:ok, gateway} = Gateway.start_link(instance: instance, port: 0)
    on_exit(fn -> if Process.alive?(gateway), do: GenServer.stop(gateway) end)
    sock = tcp(Gateway.port(gateway))
    :ok = :gen_tcp.send(sock, hello("ada"))
    assert {:ok, frame} = recv(sock)
    assert {:ok, decoded} = Protocol.decode(frame)
    assert decoded.fields[Protocol.field(:error)] == "authentication_required"
    :gen_tcp.close(sock)
  end

  test "a foreign client sits on the same channel as elixir", %{instance: instance} do
    {:ok, gateway} =
      Gateway.start_link(
        instance: instance,
        port: 0,
        allow_anonymous: true,
        idle_timeout_ms: 5_000
      )

    on_exit(fn -> if Process.alive?(gateway), do: GenServer.stop(gateway) end)
    sock = tcp(Gateway.port(gateway))

    :ok = :gen_tcp.send(sock, hello("ada"))
    assert {:ok, hello_frame} = recv_ok(sock)
    session_id = hello_frame.fields[Protocol.field(:session_id)]
    assert is_binary(session_id)

    :ok =
      :gen_tcp.send(
        sock,
        request(Protocol.op(:subscribe), 2, [{Protocol.field(:topic), "general"}])
      )

    assert {:ok, _} = recv_ok(sock)

    {:ok, elixir} = Wiregrid.connect(instance, "lin", self())
    :ok = Wiregrid.subscribe(instance, elixir, {:channel, "general"})

    body = ~s({"type":"message","body":"from c"})

    :ok =
      :gen_tcp.send(
        sock,
        request(Protocol.op(:publish), 3, [
          {Protocol.field(:topic), "general"},
          {Protocol.field(:payload), body},
          {Protocol.field(:content_type), "application/json"},
          {Protocol.field(:class), "durable"}
        ])
      )

    assert {:ok, _} = recv_ok(sock)
    assert {:ok, echo} = recv(sock)
    assert {:ok, echo_frame} = Protocol.decode(echo)
    assert echo_frame.kind == 2
    assert {:ok, %{"body" => "from c"}} = JSON.decode(echo_frame.fields[Protocol.field(:payload)])

    {_delivery, envelope} = receive_delivery()
    assert envelope.topic == {:channel, "general"}
    assert envelope.event.type == :message
    assert envelope.event.body == "from c"
    assert {:ok, _} = Wiregrid.ack(instance, elixir, envelope.delivery_id)

    assert {:ok, _} =
             Wiregrid.publish(
               instance,
               {:channel, "general"},
               %{type: :message, body: "from elixir"},
               session_id: elixir,
               persist: true
             )

    assert {:ok, inbound} = recv(sock)
    assert {:ok, inbound_frame} = Protocol.decode(inbound)
    assert inbound_frame.fields[Protocol.field(:topic)] == "general"

    assert {:ok, %{"type" => "message", "body" => "from elixir"}} =
             JSON.decode(inbound_frame.fields[Protocol.field(:payload)])

    :ok =
      :gen_tcp.send(
        sock,
        request(Protocol.op(:history), 4, [
          {Protocol.field(:topic), "general"},
          {Protocol.field(:limit), "10"}
        ])
      )

    assert {:ok, history} = recv_ok(sock)
    assert {:ok, %{"events" => events}} = JSON.decode(history.fields[Protocol.field(:payload)])
    bodies = Enum.map(events, fn row -> row["event"]["body"] end)
    assert "from c" in bodies
    assert "from elixir" in bodies

    :ok =
      :gen_tcp.send(sock, request(Protocol.op(:join_room), 5, [{Protocol.field(:room), "lobby"}]))

    assert {:ok, _} = recv_ok(sock)
    assert Wiregrid.room_member?(instance, "lobby", session_id)
    :gen_tcp.close(sock)
  end

  defp tcp(port) do
    {:ok, sock} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        port,
        [:binary, packet: 4, active: false, nodelay: true],
        2_000
      )

    sock
  end

  defp hello(user), do: request(Protocol.op(:hello), 1, [{Protocol.field(:user_id), user}])

  defp request(op, id, fields) do
    {:ok, frame} = Protocol.encode(0, op, id, fields)
    frame
  end

  defp recv(sock), do: :gen_tcp.recv(sock, 0, 2_000)

  defp recv_ok(sock) do
    with {:ok, frame} <- recv(sock),
         {:ok, decoded} <- Protocol.decode(frame) do
      assert decoded.fields[Protocol.field(:status)] == "ok"
      {:ok, decoded}
    end
  end
end
