# lfe

wiregrid has one runtime. the real state and correctness rules live in the elixir/erlang otp code.

lfe is an optional layer on top of the plain-term `wiregrid_api` interface. it is used for the places where lfe is genuinely convenient: actor loops, mailbox matching, small tail-recursive workers, compile-time routing, and macros that can turn a fixed chat workflow into normal beam functions before the app starts.

wiregrid does not need lfe to boot.

## why the lfe side is this big

at first glance there are a lot of lfe modules for an optional language, but they are not copies of the elixir runtime.

most of them are narrow pieces of one hot-path toolset. a worker that preserves per-session ordering has different rules from a worker that coalesces ephemeral typing updates, and both are different from a macro that only generates fixed topic constructors. keeping those jobs separate is less clever, but it is much easier to inspect when something goes wrong.

this also keeps the boundary honest. lfe never owns the ets tables, resume tokens, storage transaction rules, authorization state, or delivery reservations. it calls the same `wiregrid_api` functions as any other beam language, so it cannot quietly skip the limits enforced by the main runtime.

if an app never needs these worker patterns, it can ignore the whole directory.

## what the modules are for

`wiregrid.lfe` is the normal lfe-facing api. it covers lifecycle, subscriptions, publishing, direct delivery, rooms, presence, signaling, receipts, storage/cache access, health, draining, and shutdown.

`wiregrid_macros.lfe` contains compile-time helpers for fixed topics, targets, publishers, subscription sets, workers, and command handlers. the generated functions call `wiregrid_api` directly instead of bouncing through another wrapper layer.

`wiregrid_fast.lfe` contains prepared and grouped operations used by hotter paths.

`wiregrid_mailbox.lfe` collects one bounded burst from a worker's own mailbox. it never scans another process and the optional collect wait is bounded.

`wiregrid_worker.lfe`, `wiregrid_batch_worker.lfe`, and `wiregrid_adaptive_worker.lfe` are the worker processes. they use off-heap message queues, hard batch limits, and explicit failure behavior. the adaptive worker only looks at its own mailbox after the first delivery; it does not probe recipients to guess whether they are slow.

`wiregrid_lane.lfe` keeps work ordered inside a key, such as a session or topic, while allowing unrelated keys to run concurrently under a hard lane limit.

`wiregrid_coalesce.lfe` removes superseded ephemeral work inside one bounded batch. durable deliveries are never collapsed.

`wiregrid_kernel.lfe` and `wiregrid_selector.lfe` let a worker make a routing/drop decision from envelope metadata before decoding the payload. this is useful when a lot of incoming work will be ignored or routed elsewhere.

`wiregrid_pipeline.lfe` is for decode-once handler pipelines. `wiregrid_fold.lfe` is for stateful bounded folds. `wiregrid_stream.lfe` is just chunk orchestration when the caller intentionally has more work than one public batch allows.

none of these modules make a second queueing system. delivery ids still come from wiregrid and successful work still gets acknowledged through wiregrid.

## building it

```sh
mix wiregrid.lfe.compile
```

or run the lfe check directly:

```sh
./scripts/check-lfe.sh
```

release environments that require lfe should make a missing compiler fatal rather than silently skipping it.

## using prepared fanout

when one event is going to several places, prepare it once and reuse the encoded body:

```lisp
(case (wiregrid:prepare 'chat event)
  ((tuple 'ok prepared)
    (wiregrid:publish-topics-prepared
      'chat
      (list (wiregrid:topic-channel #"general")
            (wiregrid:topic-document #"activity"))
      prepared)))
```

for topology known at compile time, the macro module can generate the boring wrappers for you. that is where lfe macros earn their keep: the route becomes ordinary beam code with fixed terms instead of a runtime mini-dsl.

## encoded consumers

for higher fanout, an encoded session can avoid copying a large decoded event term into every consumer mailbox. the worker decodes only when it knows the event will actually be handled.

that matters for selectors and kernels because they can reject, retain, or route an envelope using metadata before touching the body.

acknowledgements are grouped per session where possible, but failed or unprocessed deliveries stay reserved. a worker should never acknowledge work it has not actually committed.

## ordering and coalescing

use lanes when ordering matters inside one key but unrelated keys can proceed in parallel. keep the lane key small and stable, and put a real ceiling on lane count.

use coalescing only for ephemeral state such as typing or transient cursor/activity updates. it is deliberately local to the current bounded batch. it does not create a hidden long-lived cache, and it will not collapse durable events.

## replay

`wiregrid:replay-session/3,4` reads one bounded storage page and redelivers it through normal authorization, codec, and backpressure rules. the returned resume cursor only moves past rows that were accepted by delivery, so pressure does not silently skip the first row that failed admission.

## when not to use the lfe workers

if a normal elixir consumer is fast enough, keep it normal. if the work is mostly database latency, an lfe mailbox loop will not make the database faster. use these pieces when profiling shows that routing, decode cost, worker scheduling, or per-message overhead is the part worth tightening.
