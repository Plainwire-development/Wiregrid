defmodule Wiregrid.TestAuthorizer.DenyPublish do
  @behaviour Wiregrid.Authorizer

  @impl true
  def authorize(:publish, _session, _resource, _context), do: false
  def authorize(_action, _session, _resource, _context), do: :ok
end

defmodule Wiregrid.TestAuthorizer.Crash do
  @behaviour Wiregrid.Authorizer

  @impl true
  def authorize(_action, _session, _resource, _context), do: raise("authorizer failure")
end

defmodule Wiregrid.TestAuthorizer.DenyOneSubscription do
  @behaviour Wiregrid.Authorizer

  @impl true
  def authorize(:subscribe, _session, {:channel, "denied"}, _context), do: {:error, :denied_topic}
  def authorize(_action, _session, _resource, _context), do: :ok
end

defmodule Wiregrid.TestAuthorizer.SlowSubscribe do
  @behaviour Wiregrid.Authorizer

  @impl true
  def authorize(:subscribe, _session, _resource, _context) do
    Process.sleep(250)
    :ok
  end

  def authorize(_action, _session, _resource, _context), do: :ok
end

defmodule Wiregrid.TestAuthorizer.SlowAll do
  @behaviour Wiregrid.Authorizer

  @impl true
  def authorize(_action, _session, _resource, _context) do
    Process.sleep(250)
    :ok
  end
end
