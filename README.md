# ops-pkg-node

An [ops](https://github.com/nanovms/ops) package of **Node.js 24 LTS** for the Nanos
unikernel, for **x86_64** and **arm64** (AWS Graviton). It is built from the official
nodejs.org binaries, with every input pinned and verified, and it is reproducible
byte-for-byte. Releases are private GitHub Release assets; nothing goes to the public ops
package hub.

The package is the base for API images that run Node directly on Nanos: Fastify 5 with
WebSockets, postgres.js over TLS, the native addon `@node-rs/argon2`, and TypeScript run
through Node's type stripping.

## What is in the package

`node_<version>_linux-<arch>.tar.gz` holds the layout that `ops pkg from-run` produces and
`ops pkg add` expects, with the manifest at the archive root:

| Path | Contents |
|---|---|
| `package.manifest` | `Program: "node_<version>/node"`, `Args: ["node"]`, `Version`, `Language`, `Description` |
| `node` | `bin/node` from `node-v<version>-linux-<arch>.tar.xz`, unmodified; ops puts it in the image as `/node` |
| `sysroot/` | the loader, glibc and the GCC runtime from `debian:trixie-slim` for the target architecture, listed in [`package/sysroot-<arch>.txt`](package/) |
| `BUILDINFO.json` | inputs (tarball sha256, release-keys commit, Debian image digest, glibc version) and the sha256 of every file |
| `LICENSE` | the Node.js license |

`BUILDINFO.json` and `LICENSE` do not go into images; ops only copies `sysroot/` and the
program.

The sysroot holds `ld-linux`, `libc.so.6`, `libm.so.6`, `libstdc++.so.6` and
`libgcc_s.so.1`, which `bin/node` links. It also holds glibc's five compatibility stubs:
`libdl`, `libpthread`, `librt`, `libutil` and `libanl`. Since glibc 2.34 these are empty,
but binaries built against an older glibc still name them, and `bin/node` and prebuilt
native addons do. The x64 build of `@node-rs/argon2`, for one, fails to load without
`librt.so.1`.

The package deliberately contains no CA bundle, no npm and no shell:

- Node verifies TLS against its compiled-in Mozilla root store plus `NODE_EXTRA_CA_CERTS`.
  Production adds the RDS CA bundle that way.
- npm belongs to the build of the application, not to its runtime.

| Architecture | `.tar.gz` | `node` | `sysroot/` |
|---|---|---|---|
| x64 | 47.0 MB | 126.9 MB | 6.0 MB |
| arm64 | 46.4 MB | 123.4 MB | 5.5 MB |

(Node 24.22.1, glibc 2.41.)

## Consuming the package

Packages on the public ops hub are referred to as `<namespace>/<name>:<version>`, for
example `ops pkg load eyberg/node:20.5.0`. ops resolves that name through the hub's
`manifest.json` and downloads the archive over unauthenticated HTTP. This package is not on
the hub, and never will be. It is a release asset of this private repository, so a consumer
fetches it with their own GitHub credentials, verifies it, and adds it to ops as a *local*
package under a name they choose. The convention is `node_<version>`:

```sh
tag=v24.22.1-r1
gh release download "$tag" --repo tpjg/ops-pkg-node --pattern 'node_24.22.1_linux-arm64.tar.gz*'
sha256sum -c node_24.22.1_linux-arm64.tar.gz.sha256
gh attestation verify node_24.22.1_linux-arm64.tar.gz --repo tpjg/ops-pkg-node
ops pkg add node_24.22.1_linux-arm64.tar.gz --name node_24.22.1 --arch arm64
```

- `gh attestation verify` checks the Sigstore-signed build provenance: the file was built by
  this repository's `release` workflow, from the commit it names.
- `ops pkg add` unpacks the package into `~/.ops/local_packages/<arch>/node_24.22.1`.
  `--arch` takes ops' naming, `amd64` or `arm64`; it defaults to the host's architecture.
  Add both architectures under the same name to build images for either.

From then on, the package is referred to by that name plus `--local`:

```sh
ops pkg list --local                              # shows node 24.22.1
ops pkg contents node_24.22.1 --local             # files in the package
ops pkg load node_24.22.1 --local -a hi.js        # boot it, running hi.js
ops image create --package node_24.22.1 --local -c config.json -t aws ...
```

On Apple silicon with ops 0.1.47, add `--arch arm64` even for the native architecture. ops
always asks QEMU for an arm64 GICv2, which HVF cannot provide ("HVF does not support GICv2
emulation"). `--arch arm64` makes ops use TCG emulation instead, and then it boots. That
affects every arm64 package, not just this one.

For an app, the ops config supplies the files and the entry point:

```json
{
  "Args": ["/app/src/main.ts"],
  "DisableArgsCopy": true,
  "Dirs": ["app"],
  "Env": { "NODE_EXTRA_CA_CERTS": "/app/certs/rds-global-bundle.pem" },
  "RunConfig": { "Ports": ["8080"] }
}
```

```sh
ops pkg load node_24.22.1 --local --nanos-version 0.1.56 -c config.json
```

Install the app's `node_modules` for the target platform, so npm picks the right native
addon builds:
`npm ci --omit=dev --os=linux --cpu=arm64 --libc=glibc`.

On shutdown (an ACPI power-button press, as EC2 sends), Nanos delivers SIGTERM to Node and
powers off 30 s later at the latest. Running on EC2 is covered in [docs/aws.md](docs/aws.md).

ops can also resolve hub-style names from a private package repository, through
`OPS_PACKAGE_MANIFEST_URL` and `OPS_PACKAGE_BASE_URL`, and it checks each download against
the manifest's sha256. It fetches from `<base>/<namespace>/<name>/<version>[/arm64].tar.gz`
without credentials, though. A private GitHub repository can't serve that layout, so this
repository does not publish one.

## Building

Building needs only `docker` and `just`. Every step runs in a digest-pinned container, on
macOS and Linux alike, and either architecture can be built on any host.

```sh
just build x64        # → dist/node_<version>_linux-x64.tar.gz and .sha256
just build arm64
just check x64        # compare with package/expected.sha256
just test x64         # negative verification tests + acceptance tests (below)
just all              # all of the above, both architectures
just expected         # after an intended change: rebuild both and record new checksums
```

`scripts/build.sh ARCH` does three things:

1. `fetch-node.sh` downloads Node and `verify-node.sh` checks it, in the tools container
   (`tools/Dockerfile`).
2. `export-sysroot.sh` exports the target-arch Debian image's filesystem. The image is
   created and exported, never run, so no emulation is needed.
3. `build-package.sh` assembles and checks the package, then writes a deterministic archive.

## Pinning and verification

Every external input is pinned. Changing one is a reviewed edit to a file in this repository.

| Input | Pinned in | Verified by | Why |
|---|---|---|---|
| Node version | `NODE_VERSION` (one line) | `fetch-node.sh` rejects anything but `24.x.y` | One place to bump; the update workflow edits only this file and the checksums. |
| Node release keys | `pins.env`: `nodejs/release-keys` commit, plus the sha256 of its `gpg-only-active-keys/pubring.kbx` | `verify-node.sh` | The commit fixes *which* keys are trusted; the sha256 makes the downloaded keyring verifiable, not just addressed. Only active releasers' keys are trusted. |
| `SHASUMS256.txt` | — | `gpgv` against that keyring | Ties the checksums to a Node releaser's key, so a compromised mirror or CDN cannot substitute a tarball. |
| Node tarball | — | sha256 from the signed `SHASUMS256.txt` | The tarball's integrity follows from the signature. |
| Sysroot libraries | `pins.env`: `debian:trixie-slim` per-architecture manifest digests; file list in `package/sysroot-<arch>.txt` | `export-sysroot.sh` checks the image's OS/arch; `build-package.sh` checks each ELF's machine type and that the shared-library closure of `bin/node` and of every listed file is in the list | Libraries come from a fixed environment of the *target* architecture, never from the build host. The list makes the package's contents explicit and reviewable. |
| Build tools | `pins.env`: `debian:trixie-slim` index digest and `snapshot.debian.org` timestamp | apt's archive signatures | Tool versions (tar, gzip, readelf, gpgv) are fixed, so the archive bytes are too. |
| ops CLI | `pins.env`: version and sha256 per host platform | `install-ops.sh` | Upstream publishes only md5s; the sha256 values were recorded when pinning, after checking those md5s. |
| Nanos kernel | `pins.env`: version and sha256 per architecture | `install-ops.sh` | ops does not checksum kernel downloads, so the kernels come from these pins into a private `OPS_HOME` (`.work/ops-<os>-<machine>`); `~/.ops` is never used. |
| Test environment | `pins.env`: `ubuntu:24.04` index digest and `snapshot.ubuntu.com` timestamp | apt's archive signatures | QEMU's version decides whether tests pass (see Testing), so the tests run on a fixed QEMU locally and in CI. |
| GitHub Actions | full commit SHAs in `.github/workflows/` | — | Tags can be moved; commit SHAs cannot. |
| Output | `package/expected.sha256` | `check-expected.sh` in CI | The archive is deterministic: sorted entries, fixed mtime (the Node binary's), uid/gid 0, normalized modes, `gzip -n`. The expected values come from a build on a different host (a developer machine, or the update-node runner), so CI's match shows the build is reproducible across hosts. |

`scripts/test-verify.sh` checks that verification fails closed. An edited `SHASUMS256.txt`,
a truncated signature, a tarball with overwritten bytes and an altered keyring must each
stop the build. It runs as part of `just test`.

## Testing

`just test ARCH` runs the verification tests above, then boots the package exactly as a
consumer would:

1. Check the `.sha256`.
2. `ops pkg add`.
3. Compare `ops pkg contents` with the sysroot list.
4. Boot with `ops pkg load` on QEMU, with two vCPUs.

The guest program is TypeScript ([`test/guest/main.ts`](test/guest/main.ts)) with the
API's real dependencies. The host side is [`test/driver.mjs`](test/driver.mjs), which runs
on the verified Node build for the host's architecture.

| Check | What it shows |
|---|---|
| `argon2` (first) | `@node-rs/argon2` loads its prebuilt glibc addon, hashes and verifies, and rejects a wrong password |
| `version-and-arch` | `process.version`, `process.arch`, and the glibc runtime version |
| `typescript` | the entry point is a `.ts` file run with `process.features.typescript === 'strip'`, importing other `.ts` modules |
| `intl` | full ICU: `nl-NL` resolves, and formats as `maandag 26 oktober 2026` |
| `threadpool` | `crypto.pbkdf2` runs off the main thread (timers keep firing) and four jobs run in parallel on two vCPUs |
| `env` | variables from the ops config's `Env`, including a URL with spaces, `%`, `&`, `=` and non-ASCII, reach `process.env` intact |
| `tls-extra-ca` | `tls.connect` and `https.get` to a host server signed by the CA in `NODE_EXTRA_CA_CERTS` succeed; a server signed by another CA is rejected with `UNABLE_TO_VERIFY_LEAF_SIGNATURE` |
| `dns-getaddrinfo` | `dns.lookup` resolves through the packaged glibc (skipped when the host is offline) |
| `http`, `websocket` | Fastify and `@fastify/websocket` in the guest answer through ops' port forward |
| `sigterm-on-powerdown` | an ACPI power-button press (QMP `system_powerdown`) reaches Node as SIGTERM |

The tests always run in the Linux test container (`test/Dockerfile`), also on macOS.
`/dev/kvm` is passed through when the host has it; otherwise QEMU uses TCG emulation:

| Where | x64 | arm64 |
|---|---|---|
| CI, `ubuntu-24.04` / `ubuntu-24.04-arm` | KVM | TCG (the hosted arm64 runner has no `/dev/kvm`) |
| macOS on Apple silicon (colima) | TCG | TCG |

`scripts/ci-enable-kvm.sh` prints which case applies, and the driver records the accelerator
in `results.json`.

A typical test run boots in 9–12 s under TCG.

Why the container even on macOS: Homebrew's QEMU 11.1 on macOS hangs Nanos arm64 at boot
whenever there is more than one vCPU, under both TCG and HVF. ops always selects GICv2 for
arm64, and HVF does not emulate it. Ubuntu 24.04's QEMU 8.2.2 boots the same image with 1, 2
or 4 vCPUs.

## CI

| Workflow | Trigger | Does | Permissions |
|---|---|---|---|
| `ci.yml` | pull request, push to `main`, dispatch | build, compare with `expected.sha256`, test; per architecture on its native runner | `contents: read` |
| `release.yml` | push to `main` touching the package inputs, dispatch | the same, then attest each `.tar.gz` (`actions/attest-build-provenance`) and publish release `v<node>-r<n>` with the `.tar.gz` and `.sha256` files; skipped when the bytes equal the previous release of that version | build jobs: `contents: read`, `id-token: write`, `attestations: write`; publish job: `contents: write` |
| `update-node.yml` | daily, dispatch | if [index.json](https://nodejs.org/dist/index.json) lists a newer 24.x LTS: build both architectures, commit `NODE_VERSION` and `package/expected.sha256` to `update-node/<version>`, open a PR, dispatch `ci.yml` on it | `contents: write`, `pull-requests: write`, `actions: write` |

No workflow uses a stored secret; everything runs on the job's `GITHUB_TOKEN`.

A PR opened with `GITHUB_TOKEN` does not trigger `pull_request` workflows.
`workflow_dispatch` is the documented exception, so `update-node` dispatches CI itself, and
the checks attach to the PR's head commit. The update PR's CI then rebuilds on native
runners, compares with the checksums from the update runner, and runs the full test suite
before anyone merges. Two repository settings are required:

- "Allow GitHub Actions to create and approve pull requests" must be on.
- Branch protection should require the `package (x64)` and `package (arm64)` checks.

## Layout

```
NODE_VERSION              the Node version
pins.env                  every other pin
package/                  sysroot file lists, expected.sha256
tools/Dockerfile          build tools container
test/Dockerfile           test container (QEMU)
test/driver.mjs           host side of the acceptance tests
test/guest/               TypeScript program that runs in the unikernel
scripts/                  build, verify, test and CI scripts (justfile recipes call these)
docs/aws.md               running on EC2: AMIs, klibs, read-only root, shutdown
```
