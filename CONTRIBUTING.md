# contributing

wiregrid tries to keep the hot paths boring: explicit limits, normal otp supervision, small interfaces, and no hidden unbounded queues.

before sending a change, run:

```sh
./scripts/setup-dev.sh
./scripts/verify.sh
USERS=100 TOPICS=10 MESSAGES=1000 ./scripts/load.sh
```

keep public inputs bounded, do not create atoms from untrusted data, do not decode arbitrary erlang terms, and do not move normal fanout behind one global genserver.

concurrency and lifecycle changes should come with behavioral tests. if a change adds a new limit or failure mode, document it where a user would actually look for it.

optional adapters should stay optional to the core runtime. product concepts such as guilds, friendships, moderation policy, and message schemas belong in applications built on wiregrid.
