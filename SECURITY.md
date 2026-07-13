# Security Policy

Battery Hog's monitoring runs 100% locally: it reads built-in macOS tools and
does not upload monitoring data, analytics, or a system profile. A network
request to GitHub is made only when the user manually checks for an update or
opts in to periodic checks, which are disabled by default. Direct-download
updates require both a signed Sparkle feed and a signed archive. Release builds
are also signed and notarized with an Apple Developer ID.

If you find a vulnerability anyway, please report it privately instead of
opening a public issue:

- [Report a vulnerability](https://github.com/luke-fairbanks/BatteryHog/security/advisories/new)

I'll respond within a few days. The latest release is the only supported
version.
