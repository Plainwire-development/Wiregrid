defmodule Wiregrid.AuthTest do
  use ExUnit.Case, async: true

  alias Wiregrid.Transport.Auth

  test "signed tokens bind audience, support key rotation and reject tampering" do
    old = :crypto.strong_rand_bytes(32)
    current = :crypto.strong_rand_bytes(32)
    keys = %{"old" => old, "current" => current}

    assert {:ok, token} =
             Auth.issue("alice", keys, key_id: "current", audience: "chat", ttl_s: 60)

    assert {:ok, claims} = Auth.verify(token, keys, audience: "chat")
    assert claims.subject == "alice"
    assert claims.key_id == "current"
    assert {:error, :invalid_token} = Auth.verify(token, keys, audience: "other")
    assert {:error, :invalid_token} = Auth.verify(token <> "x", keys, audience: "chat")
  end

  test "instance audiences are deterministic and distinct" do
    assert Auth.instance_audience(:chat) == Auth.instance_audience(:chat)
    refute Auth.instance_audience(:chat) == Auth.instance_audience(:other)
  end

  test "key rings are bounded and strictly validated" do
    assert {:error, :invalid_key_ring} = Auth.issue("alice", %{})
    assert {:error, :invalid_key_ring} = Auth.issue("alice", %{bad: :secret})

    oversized =
      for i <- 1..33, into: %{} do
        {Integer.to_string(i), :crypto.strong_rand_bytes(32)}
      end

    assert {:error, :invalid_key_ring} = Auth.issue("alice", oversized)
  end

  test "short secrets and oversized subjects are rejected" do
    assert {:error, _} = Auth.issue("alice", "short", ttl_s: 60)
    assert {:error, _} = Auth.issue(String.duplicate("a", 513), :crypto.strong_rand_bytes(32))
  end
end
