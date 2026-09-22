# security policy

## supported releases

security fixes are maintained on the current release line. if an issue is against an older tag, include the exact version or commit so it can be reproduced without guessing.

## reporting a vulnerability

report suspected vulnerabilities privately to the project maintainer. include the affected version or commit, the conditions needed to reproduce it, the likely impact, and any mitigation you already tried.

do not include production credentials or unrelated personal data in the report.

## what wiregrid covers

wiregrid provides bounded runtime primitives, fail-closed authorization hooks, size-limited serialization boundaries, resume-token protection, transport admission limits, signed webhook support, and explicit backpressure behavior.

it does not replace application security. the embedding service still owns identity, product permissions, database/cache credentials, tls, network segmentation, beam distribution security, backups, host hardening, and dependency patching.

`Wiregrid.Authorizer.AllowAll` is for trusted in-process callers. internet-facing transports should configure an application authorizer.

`Wiregrid.Foreign.Gateway` listens on loopback by default and rejects anonymous sessions. `allow_anonymous: true` is only accepted for a loopback bind. the protocol is bounded and versioned, and it does not provide tls. keep the socket private or terminate tls in front of it, and configure `authenticate` before untrusted clients can reach it.

before production, run `./scripts/verify.sh`, the integration tests for the adapters you actually use, deployment-specific dependency/security tooling, and target-environment load tests.

more detail is in `docs/security.md`.
