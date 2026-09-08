# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue, PR,
or discussion for anything security-sensitive.

Use GitHub's private vulnerability reporting:
[**Report a vulnerability**](https://github.com/BuLEEto/Skald/security/advisories/new)
(also reachable from the repository's **Security** tab). This opens a private
advisory visible only to the maintainers.

Please include enough to reproduce — a minimal input, font, or code snippet, and
what you observed (crash, hang, out-of-bounds, unexpected allocation, etc.).

## Supported versions

Skald is pre-1.0 and ships as release candidates. Security fixes land on `main`
and the latest `v1.0.0-rcN` tag — please reproduce against the newest tag before
reporting.

## Scope

Skald renders untrusted text and loads untrusted fonts, so parsing/shaping bugs
that crash, hang, or read/write out of bounds are in scope. The vendored text
engine under `skald/third_party/runa/` is part of Skald for reporting purposes —
report those here and they'll be forwarded upstream as needed.
