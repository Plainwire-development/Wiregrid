defmodule Wiregrid.TransportCommandTest do
  use Wiregrid.TestCase, async: true

  alias Wiregrid.Transport.Command

  defmodule Extension do
    def handle_command({:echo, value}, context) do
      {:ok, %{value: value, user_id: context.user_id, session_id: context.session_id}}
    end

    def handle_command(_command, _context), do: {:error, :unsupported_extension_command}
  end

  test "built-in commands use the canonical authenticated session", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "command-user", self())
    topic = {:channel, "commands"}

    assert :ok = Command.dispatch(instance, sid, "command-user", {:subscribe, topic})
    assert Wiregrid.subscribed?(instance, sid, topic)
    assert {:pong, 123} = Command.dispatch(instance, sid, "command-user", {:ping, 123})
  end

  test "unknown commands can use a sanitized extension module", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "extension-user", self())

    assert {:ok, %{value: "hello", user_id: "extension-user", session_id: ^sid}} =
             Command.dispatch(instance, sid, "extension-user", {:echo, "hello"}, Extension)
  end

  test "extension functions do not override built-in operations", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "extension-user", self())
    parent = self()

    extension = fn command, context ->
      send(parent, {:extension_called, command, context})
      {:ok, :extension}
    end

    assert {:pong, :nonce} =
             Command.dispatch(instance, sid, "extension-user", {:ping, :nonce}, extension)

    refute_received {:extension_called, _, _}

    assert {:ok, :extension} =
             Command.dispatch(
               instance,
               sid,
               "extension-user",
               {:application_command, 1},
               extension
             )

    assert_receive {:extension_called, {:application_command, 1}, context}
    assert context == %{instance: instance, session_id: sid, user_id: "extension-user"}
  end

  test "extension failures fail closed", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "extension-failure", self())
    crashing = fn _command, _context -> raise "boom" end

    assert {:error, :command_handler_failed} =
             Command.dispatch(instance, sid, "extension-failure", {:custom, :boom}, crashing)

    assert {:error, :invalid_command_handler} =
             Command.dispatch(
               instance,
               sid,
               "extension-failure",
               {:custom, :boom},
               :not_a_handler
             )
  end

  test "command terms are bounded and portable before extensions run", %{instance: instance} do
    {:ok, sid} = Wiregrid.connect(instance, "bounded-command", self())
    parent = self()

    extension = fn _command, _context ->
      send(parent, :called)
      :ok
    end

    assert {:error, :invalid_command} =
             Command.dispatch(instance, sid, "bounded-command", {:bad, self()}, extension)

    refute_received :called
  end
end
