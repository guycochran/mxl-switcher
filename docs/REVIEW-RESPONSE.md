# Review response thread

Shared async thread between the author and the independent reviewer. Each item carries a
status: `open` / `fixed` / `disputed` / `wontfix` / `needs-decision` /
`needs-hw-verify`.

## Oct 9 — Guy's decisions + actions on the Oct 9 review

Thanks for the thorough pass. Guy made the five calls; here they are, with what's done.

### Decisions from Guy

1. **Merge order** — `fixed(plan)`: proceed in the recommended order **#38 → #40 → #37 → #39 → #41**.
   #37 is held until its open notes below are addressed; the other four can go once conflicts
   are resolved.
2. **Deploying unmerged branches to the live box** — `accepted`: continue only to close the
   verification gap faster, with the merge plan above ending the drift. Box-specific details
   stay uncommitted or placeholdered, never on master.
3. **/join policy** — `decided`: **passphrase (merge #40)**. Public contributors must present
   the SRT passphrase; the /join QR embeds it so legitimate scanners stay one-tap.
4. **Apache copyright holder (#39)** — `decided`: **Guy Cochran** (individual).
5. **Naming the hostname + Jonas** — `decided`: remove the live hostname from the repo; drop
   the employer tag on the EFA changelog line; retain the public open-source proxy credit.

### Actions already taken (Oct 9)

- **Hostname leak (#41)** — `fixed`: committed documentation no longer hardcodes the live
  server hostname.
- **Control API hardening** — `fixed`: mediamtx's API binds to localhost rather than all
  interfaces.
- **Employer tag (#37 changelog)** — `fixed`: the entry states the technical cause without
  identifying an individual or employer.

### Still open — #37 notes

- `open`: NMOS routing still ignores the flow ID; the domain ID is not a proper UUID; the ADR
  over-claims both as done; the soak check reports a stale result as a failure; the PR is too
  broad. Address these before merge.

## Oct 9 (later) — two more decisions from Guy

- **Multiview visibility (#40)** — `decided`: passphrase-to-publish is enough; public viewing
  is acceptable for the demo.
- **Core-vs-Skin leak sweep** — `fixed` in PR #42: runnable Core defaults are neutral while
  the project publication may retain its authorship and field notes.

## Oct 17 — commercialization validation page

- **Pilot offer page** — `open`: `docs/pilot.html` adds a bounded, measured pilot offer and
  explicitly excludes a general-purpose production-platform promise, a 24/7 SLA, universal
  MXL-vs-NDI claims, and finished TAMS editing/replay.
- **Claim discipline** — `fixed`: the page carries only already documented proof points and
  labels the CPU comparison as a bounded same-host test.
- **Runtime impact** — `fixed`: documentation-only; no Core, live-system, tunnel, cloud, Docker,
  meeting, mapping or service changes.
- **Review request** — `open`: verify that the public wording does not overstate the evidence
  and that the pilot scope remains commercially useful without implying product maturity.

