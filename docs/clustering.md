# clustering

clustering is optional and off by default.

when enabled, wiregrid uses a fixed number of shard workers and fixed `:pg` groups. it does not create a distributed process group for every topic or user.

local ets stays authoritative for local sessions and local hot fanout. cluster messages carry event ids and are deduplicated with bounded expiry.

presence and room membership are indexed by user, room, and node so cleanup after a node loss can work through the failed node's state in bounded batches instead of scanning everything.

instance identity is included in cluster namespaces so two wiregrid instances on the same distributed beam do not accidentally share traffic.

node join starts bounded state resync. periodic reconciliation repairs state if the first resync was incomplete under load. remote state and shard mailboxes have configured ceilings.

## consistency

wiregrid clustering is realtime best-effort dissemination, not a consensus log.

during a partition, presence and room views can temporarily disagree. important durable events should be persisted in the application's durable store and replayed/reconciled at the product layer.

beam distribution peers are trusted infrastructure. keep distribution private and configure cookie/tls/network security operationally.
