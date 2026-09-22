{:ok, _} = Application.ensure_all_started(:wiregrid)
{:ok, _} = Wiregrid.start_instance(:demo, profile: :small, cluster: false)
{:ok, sid} = Wiregrid.connect(:demo, "alice", self())
:ok = Wiregrid.subscribe(:demo, sid, {:channel, "general"})
{:ok, _} = Wiregrid.publish(:demo, {:channel, "general"}, %{type: :message, body: "hello"})

receive do
  {:"$wiregrid", envelope} ->
    IO.inspect({envelope.topic, envelope.event})
    {:ok, 0} = Wiregrid.ack(:demo, envelope.session_id, envelope.delivery_id)
after
  1_000 -> raise "message not delivered"
end
