# Surfex keeps this library's spec, tests and code aligned (macaw_compose spec/00 §4.1).
# Spec units are the spec's headings, identified by their `{#anchor}`; each carries its
# test hints. Code that predates the adoption was adopted by a baseline, its tests tagged
# one at a time against the units they verify (macaw_compose#65).
[
  sources: ["spec/*.md"],
  heading_ids: ~r/\{#(?<id>[a-z0-9-]+)\}\s*$/,
  tests: ["test/**/*_test.exs"],
  require: [code: [:implements, :excuses], test_hint: [:verifies]],
  adoption: :trust,
  # Type specs document the functions' contracts; the functions carry the relation
  # (a test can exercise a function, never a type).
  classes: [{"type", "types document the functions' contracts, which carry the relation"}],
  rules: [%{class: "type", kinds: [:type]}],
  # The overview's orienting sections (marked in spec/00) and the README describe the
  # library; they assert nothing a test checks. 00 §3 and §4 make claims, and are tested.
  spec_classes: [
    {"orientation", "describes what macaw_host holds and the pattern it serves; asserts nothing a test checks",
     files: ["spec/README.md"]},
    {"adopter-rule", "an obligation on the app that adopts the generated script, its image and its CI; each app's own spec and pipeline hold it, not this library's tests"}
  ],
  # Units not built yet are deferred to their macaw_compose proposal (`<!-- surfex: deferred #N -->`);
  # `mix surfex.status --issues` asks macaw_compose whether it is still open.
  issues: [
    command: ["glab", "issue", "view", "{n}", "--repo", "{project}", "-F", "json"],
    state: "state",
    project: "dco-tek/macaw_compose"
  ]
]
