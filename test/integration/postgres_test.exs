defmodule Wiregrid.PostgresIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  test "PostgreSQL adapter bootstrap, append, get and page" do
    url = System.fetch_env!("WIREGRID_POSTGRES_URL")
    {:ok, conn} = Postgrex.start_link(postgres_options(url))
    instance = {:postgres_integration, System.unique_integer([:positive])}

    {:ok, _} =
      Wiregrid.start_instance(instance,
        profile: :small,
        storage: {Wiregrid.Storage.Postgres, conn: conn}
      )

    on_exit(fn -> Wiregrid.stop_instance(instance) end)
    assert :ok = Wiregrid.Storage.bootstrap(instance)
    stream = {:channel, "integration"}
    assert :ok = Wiregrid.Storage.append(instance, stream, "p1", %{body: "one"})

    assert {:ok, %{id: "p1", event: %{body: "one"}}} =
             Wiregrid.Storage.get(instance, stream, "p1")

    assert {:ok, [_], nil} = Wiregrid.Storage.page(instance, stream, nil, 10)
  end

  defp postgres_options(url) do
    %URI{userinfo: userinfo, host: host, port: port, path: path} = URI.parse(url)

    {username, password} =
      case String.split(userinfo || "", ":", parts: 2) do
        [user, pass] -> {URI.decode(user), URI.decode(pass)}
        [user] -> {URI.decode(user), ""}
      end

    [
      hostname: host,
      port: port || 5432,
      username: username,
      password: password,
      database: path |> to_string() |> String.trim_leading("/")
    ]
  end
end
