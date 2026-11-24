# Weld 0.15.0 implementation status

Weld 0.15.0 provides checkout-owned `.weld/` output management, live source
views, portable full projections, and immutable prepared release identities.
The main tree owns development. Projection branches retain generated source
snapshots.

`mix ci` passed all 11 lanes on Elixir 1.18.0 / OTP 27.1.2 and Elixir 1.20.5 /
OTP 29.1.2, including legacy projection modes, real consumers, strict Credo,
Dialyzer and ExDoc. The prepared browser preview excludes the variable EPUB
while ExDoc continues to validate the configured documentation formats.
Dialyzer uses the Mix build directory for its local state.

Tag `v0.15.0` names source commit
`1f695bf29d540bdf9957109090900e6f5b126024`. The prepared package and the public
Hex tarball share SHA-256
`82eb1d9c5500acdc29645dc69b4d945acc6482c0acebe91ea3efa692f047d1be`.
MedEx verified adoption of the published tool through its maintainer project.

See the [release process](guides/release_process.md) and
[source-root artifacts](guides/source_projects.md) guides for the workflow.
