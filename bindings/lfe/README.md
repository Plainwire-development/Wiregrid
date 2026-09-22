# wiregrid for lfe

wiregrid still has one runtime. the elixir/erlang otp code owns sessions, ets state, validation, authorization, storage rules, and delivery pressure.

this directory is the optional lfe side of the library. it targets the plain-term `wiregrid_api` boundary and mostly exists for code that benefits from lfe's actor style, pattern matching, tail recursion, and macros.

there are a lot of files here because the worker patterns are deliberately kept small and separate. ordered lanes, ephemeral coalescing, decode-late routing, folds, and fixed compile-time routes do not have the same acknowledgement or failure rules, so combining them into one giant "fast" module would make the hot path harder to audit.

none of this is required for a normal wiregrid deployment.

## the pieces

`wiregrid.lfe` is the broad lfe-facing api.

`wiregrid_macros.lfe` contains compile-time topic/target constructors, fixed publishers, subscription/room setup, workers, and command handlers. generated functions call `wiregrid_api` directly.

`wiregrid_fast.lfe` contains prepared fanout, encoded delivery helpers, and grouped acknowledgements.

`wiregrid_mailbox.lfe` owns bounded burst collection from one worker's own mailbox.

`wiregrid_worker.lfe`, `wiregrid_batch_worker.lfe`, and `wiregrid_adaptive_worker.lfe` are off-heap worker loops with hard batch bounds. the adaptive worker only inspects its own mailbox and uses a tiny bounded wait when traffic is sparse.

`wiregrid_router.lfe`, `wiregrid_selector.lfe`, and `wiregrid_kernel.lfe` choose work from envelope metadata. selectors/kernels can avoid decoding payloads that will be dropped or routed somewhere else.

`wiregrid_pipeline.lfe` handles decode-once pipelines. `wiregrid_fold.lfe` handles stateful bounded folds. `wiregrid_stream.lfe` chunks intentionally larger jobs into public bounded calls.

`wiregrid_lane.lfe` gives bounded parallelism across keys while preserving order inside one key.

`wiregrid_coalesce.lfe` keeps only the latest eligible ephemeral update inside one already-bounded batch. durable work is never coalesced.

`wiregrid_actor.lfe`, `wiregrid_policy.lfe`, `wiregrid_transport.lfe`, and `wiregrid_projection.lfe` are small helpers around authenticated actors, compiled policy, sanitized transport commands, and commit-before-ack projections.

## why macros are used here

when the instance, topic, target set, or command grammar is fixed in source, an lfe macro can turn that configuration into ordinary beam clauses at compile time. that avoids rebuilding the same routing terms and wrapper decisions for every message.

the generated code still calls the normal wiregrid api, so compile-time specialization does not bypass validation, authorization, delivery reservations, or resource limits.

## consumers and acknowledgements

for high fanout, encoded sessions can keep the already encoded body in each delivery envelope and decode only after routing says the body is needed.

workers acknowledge successful work after handling, usually grouped per session. failed and unprocessed deliveries keep their reservation. inserting something into a mailbox is not considered successful processing.

for a projection or state machine that must stop at the first failure, use an ordered kernel/fold path rather than continuing through later deliveries and breaking causality.

## building

```sh
WIREGRID_REQUIRE_LFE=1 ./scripts/check-lfe.sh
mix wiregrid.lfe.compile
```

release builds that depend on these modules should make a missing lfe compiler fatal.

for more explanation and examples, read `../../docs/lfe.md`.
