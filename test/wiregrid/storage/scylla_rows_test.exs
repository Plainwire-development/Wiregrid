defmodule Wiregrid.Storage.ScyllaRowsTest do
  use ExUnit.Case, async: true

  @stream {:channel, "general"}

  defmodule Client do
    def prepare(_conn, statement) when is_binary(statement), do: {:ok, statement}

    def execute(_conn, statement, params, _opts) when is_binary(statement) do
      respond(statement, params)
    end

    defp respond(statement, params) do
      cond do
        String.contains?(statement, "IF NOT EXISTS") ->
          {:ok, %{content: []}}

        String.contains?(statement, "SELECT bucket,inserted_at_ms,event,meta") ->
          {:ok, lookup_result(params)}

        String.contains?(statement, "SELECT id,event,meta,inserted_at_ms") ->
          {:ok, %{content: []}}

        true ->
          {:ok, %{content: []}}
      end
    end

    defp lookup_result([stream, id]) do
      %{event: event, meta: meta} = Process.get({:scylla_blob, {stream, id}})

      columns = [
        {"wiregrid", "wiregrid_event_lookup", "bucket", :bigint},
        {"wiregrid", "wiregrid_event_lookup", "inserted_at_ms", :bigint},
        {"wiregrid", "wiregrid_event_lookup", "event", :blob},
        {"wiregrid", "wiregrid_event_lookup", "meta", :blob}
      ]

      case Process.get(:scylla_row_shape, :page) do
        :page ->
          %Xandra.Page{columns: columns, content: [[7, 1_700_000_000_000, event, meta]]}

        :maps ->
          %{
            content: [
              %{
                "bucket" => 7,
                "inserted_at_ms" => 1_700_000_000_000,
                "event" => event,
                "meta" => meta
              }
            ]
          }

        :columns_and_maps ->
          %{
            columns: columns,
            content: [
              %{
                bucket: 7,
                inserted_at_ms: 1_700_000_000_000,
                event: event,
                meta: meta
              }
            ]
          }
      end
    end
  end

  setup do
    {:ok, event} = Wiregrid.SafeTerm.encode(%{type: :message, body: "hello"}, 1_048_576)
    {:ok, meta} = Wiregrid.SafeTerm.encode(%{}, 1_048_576)
    id = "evt-1"
    Process.put({:scylla_blob, {@stream, id}}, %{event: event, meta: meta})
    [id: id]
  end

  test "append reads an enumerated Xandra page of string-key rows", %{id: id} do
    Process.put(:scylla_row_shape, :page)

    assert :ok =
             Wiregrid.Storage.Scylla.append(
               opts(),
               @stream,
               id,
               %{type: :message, body: "hello"},
               %{},
               1_700_000_000_000
             )
  end

  test "append accepts plain content maps and column-bearing test doubles", %{id: id} do
    for shape <- [:maps, :columns_and_maps] do
      Process.put(:scylla_row_shape, shape)

      assert :ok =
               Wiregrid.Storage.Scylla.append(
                 opts(),
                 @stream,
                 id,
                 %{type: :message, body: "hello"},
                 %{},
                 1_700_000_000_000
               )
    end
  end

  defp opts do
    [client_module: Client, conn: :conn, keyspace: "wiregrid", replication_factor: 1]
  end
end
