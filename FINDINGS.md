# Code Review Findings

Review of 2026-10-22. Findings 14–24 are deferred ("leave the smaller things be"); 1–13 are in scope.

## In scope

1. **No SIGTERM handling** — bash as PID 1 ignores SIGTERM without a trap; `podman stop` burns the full grace period and ends in SIGKILL (verified: 10s stop, ExitCode=137).
2. **No-authkey path hangs forever** — empty state dir + no `TS_AUTHKEY` → `tailscale up` blocks on an interactive login URL nobody sees (verified: silent hang).
3. **Readiness loop conflates daemon-up with authenticated** — `tailscale status` exits 1 in NeedsLogin, so every start burns the full 10s loop even with a valid authkey (verified).
4. **Child-exit handling is dead code** — under `set -e`, `EXIT_CODE=$?` after `wait -n` is unreachable when a child exits non-zero (verified on bash 5.2/5.3).
5. **`set -u` defeats the validation message** — unset (vs empty) `TS_DEST_HOST` dies with "unbound variable" instead of the friendly error (verified).
6. **Publish workflow not gated on integration test** — the workflow split (253f965) made publishing independent of testing; broken images ship to `latest` before tests run; arm64 is never tested.
7. **Secrets-check step cannot fail the job** — `::error::` annotations without `exit 1`; secrets interpolated into shell string; OAuth secret on curl's argv.
8. **CI uses docker, repo uses podman** — toolchain mismatch (cosmetic).
9. **Hardcoded `--hostname="ts-proxy"`** — collisions when running multiple instances.
10. **Hardcoded `--accept-routes`** — least-privilege violation; dubious in userspace mode.
11. **Unauthenticated wide-open listener undocumented** — `0.0.0.0` bind tunnels anything into the tailnet; also IPv4-only.
12. **No health monitoring** — broken proxy stays "up"; no HEALTHCHECK; curl installed but unused.
13. **`VOLUME ["/var/lib/tailscale"]` hurts** — anonymous volume per run silently discards state, burning non-reusable authkeys.

## Deferred (smaller things — leave for now)

14. `.gitignore` missing `tailscale-data/`
15. authkey on command line (ps leak) → `file:`
16. README bind-mount fails on fresh checkout (missing dir)
17. `FROM alpine:latest` unpinned
18. ~~curl installed but unused~~ resolved by finding 12's HEALTHCHECK, which uses curl
19. ~~shellcheck SC2086/SC2034~~ resolved (entrypoint is shellcheck-clean); no numeric validation of ports
20. ARG/ENV/EXPOSE dance
21. CI prerequisites undocumented (MagicDNS, tag:testing, fork PRs)
22. No LICENSE / OCI labels
23. Actions pinned by mutable tags
24. TCP-only, no keepalive tuning
