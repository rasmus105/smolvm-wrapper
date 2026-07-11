#!/bin/sh
# chatgpt.com (and any other Cloudflare-fronted provider) publishes AAAA
# records, but the guest's only IPv6 connectivity is an internal ULA prefix
# used for host<->guest plumbing -- there's no real route to the internet
# over v6. Node/Bun's fetch doesn't race v4/v6 (no happy-eyeballs fallback),
# so an AAAA hit just hangs until the client's own timeout instead of
# falling back to v4. Disabling v6 entirely makes those candidates fail
# the socket() call instantly, so clients skip straight to v4.
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 ||
  sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 ||
  true

exec "$@"
