# ocp-virt-ux-bench

Measures **guest user experience** on OpenShift Virtualization / KubeVirt clusters: deploy a Fedora VM, run real-world benchmarks inside it, tear it down, and score the result. Lower score is better.

Objective: “how does it feel to work inside the VM?”

## Requirements

- Bash 4+
- **Bastion mode:** SSH jump host close to the cluster (same datacenter / local network), with `oc`/`virtctl` and a kubeconfig for that cluster
- **Local mode:** `oc` on your PATH (hard requirement); `virtctl` soft (bench may download a cluster-matched copy). Network reachability to each cluster API
- Cluster DataSource for the guest image (default: `fedora` in `openshift-virtualization-os-images`)
- StorageClass suitable for VM disks (default: `ocs-storagecluster-ceph-rbd-virtualization`)

## Quick start

### Bastion (SSH)

```bash
cp hosts.example hosts
# edit hosts — one bastion per line

./dispatch.sh --parallel
./view-results.sh
```

```bash
./dispatch.sh --bastions bastion1.example.com,bastion2.example.com --parallel
```

### Localhost (kubeconfigs)

Runs `bench.sh` on this machine once per kubeconfig (no SCP/SSH).

```bash
cp clusters.example clusters
# edit clusters — one kubeconfig path per line

./dispatch.sh --local --parallel
./view-results.sh
```

```bash
./dispatch.sh --local --kubeconfigs ~/.kube/ocp1,~/.kube/ocp2 --parallel
```

Result folders use the kubeconfig basename (`ocp1`, `ocp2`, …).

## What it tests and how it scores

### Tests

| Category | Test | What it measures |
|----------|------|------------------|
| **Responsiveness** | SSH round-trip (10x) | Interactive typing latency |
| | `ls -laR /etc` | Filesystem responsiveness |
| | `find / -name *.conf` | Disk metadata + CPU |
| | `ps auxww` | Kernel/process responsiveness |
| **Real tasks** | `dnf install httpd` | Package install (network + disk + CPU) |
| | `git clone` (small repo) | Network + disk stand-in (not installing the repo) |
| | `gcc` compile + run | Developer workflow (CPU + disk) |
| | Create 1000 files, tar, extract | Filesystem metadata performance |
| **Disk I/O** | fio sequential read/write (1M) | Storage throughput (`iodepth=4`) |
| | fio random read/write (4k) | Storage IOPS + latency |
| **CPU / Memory** | stress-ng matrix / memcpy | Compute and memory bandwidth |
| **Network** | ping, DNS, download | External latency and throughput (soft; see below) |
| **Lifecycle** | ns create → boot → SSH → cloud-init → destroy | Provisioning timing |

### Score (lower = better)

Only some metrics enter the score. Others are collected for context (fio, stress-ng, gcc, …).

| Category | Range | Weight |
|----------|-------|--------|
| SSH round-trip | &lt;200ms=0 … 350ms+=5 | Highest |
| dnf install | &lt;3.5s=0 … 6.5s+=3 | High |
| Filesystem (1000 files) | &lt;250ms=0 … 320ms+=2 | Medium |
| Download | failed=2, &lt;3MB/s=1 | Medium |
| Boot time | &gt;50s=1 | Low |
| External git/ping/DNS | failed when configured = +1 each | Low |

| Score | Verdict |
|-------|---------|
| 0–1 | Excellent |
| 2–3 | Good |
| 4–5 | Fair |
| 6–7 | Below average |
| 8+ | Poor |

### External network tests (soft)

Ping / DNS / download / git clone need egress from the guest. They are **soft**:

- Empty URL/target in `env.sh` → **skip** (no score impact)
- Set and fails → run continues, but **counts toward the score**
- Never abort the whole bench

Defaults and overrides: `GUEST_UX_GIT_URL`, `GUEST_UX_PING_TARGET`, `GUEST_UX_DNS_NAME`, `GUEST_UX_DOWNLOAD_URL` (see `env.example`).

### All-workers scoring (`GUEST_UX_WORKER=all`)

Each eligible worker gets `nodes/<worker>/results.json`.

The **cluster score** (used by `view-results` / `compare` / `report`) comes from top-level `results.json`: a **worst-case rollup**, not an average.

- SSH RTT, dnf, filesystem, boot → **slowest** worker
- Download → **slowest** MB/s; any configured fail counts as fail
- git / ping / DNS / download status → **any fail** wins
- Workers skipped (too full / no metrics) are **out of the score** (`workers_skipped` only)

One weak worker can pull the cluster verdict down on purpose: the score answers “how bad can guest UX get on a node we still probe?”

## Scripts

| Script | Role |
|--------|------|
| `dispatch.sh` | Fan-out: bastions (SCP/SSH) or localhost (`--local` + kubeconfigs) |
| `bench.sh` | Test payload |
| `view-results.sh` | Tables + verdict for one run |
| `compare-results.sh` | Deltas between two runs |
| `report.sh` | CSV + trend graph; optional Google Sheets via [`gws`](https://github.com/googleworkspace/cli) |
| `env.example` | Copy to `env.sh` for defaults |

```bash
./dispatch.sh --parallel
./dispatch.sh --bastions host1,host2
./dispatch.sh --local --kubeconfigs ~/.kube/a,~/.kube/b --cores 2
./bench.sh                          # single cluster (current kubeconfig)
KUBECONFIG=~/.kube/ocp1 ./bench.sh

./view-results.sh
./compare-results.sh results/OLD results/NEW
./report.sh
```

Results: `results/<YYYYMMDD-HHMMSSZ>/<id>/` (`results.json` + `run.log`).

## Configuration

```bash
cp env.example env.sh   # edit as needed
```

Load order: built-in defaults → `env.sh` (only fills **unset** vars) → CLI / already-exported env (wins).

| Variable | Default | Meaning |
|----------|---------|---------|
| `GUEST_UX_IMAGE` | `fedora` | Guest DataSource name |
| `GUEST_UX_VM_PROFILE` | `default` | `default` (2/4Gi/30Gi) or `small` (1/2Gi/15Gi) |
| `GUEST_UX_VM_CORES` / `VM_MEMORY` / `VM_DISK` | from profile | Guest VM size (overrides profile) |
| `GUEST_UX_SC` | ceph-rbd virt SC | StorageClass (comma list: first used today) |
| `GUEST_UX_VM_STAGGER_SEC` | `10` | Delay between guest creates when `WORKER=all` |
| `GUEST_UX_WORKER` | `busiest` | `busiest` \| `any` \| node name \| `all` |
| `GUEST_UX_WORKER_MAX_CPU` / `WORKER_MAX_MEM` | `80` / `85` | Skip **workers** at/above this % |

### Worker selection

- **`busiest`** (default): pin the guest to the busiest worker that still has headroom
- **`any`**: let the scheduler decide
- **`<node-name>`**: pin to that worker
- **`all`**: one namespace, one guest per eligible Ready worker; creates staggered by `GUEST_UX_VM_STAGGER_SEC`; cluster score = worst-case rollup (above)

```bash
GUEST_UX_WORKER=all ./dispatch.sh --local
GUEST_UX_WORKER=worker-15 ./bench.sh
GUEST_UX_WORKER_MAX_CPU=70 GUEST_UX_WORKER_MAX_MEM=75 ./dispatch.sh --local
```

## How heavy is a run?

Meant for shared clusters, but it is still a real guest workload:

- Guest CPU/memory benches stay inside the VM’s cgroup
- Disk I/O uses `iodepth=4` (not a storage burn-in)
- External download is a small file (when configured)
- Namespace is deleted on exit (`trap`); interrupted runs can leave `guest-ux-*`

## License

Apache License 2.0 — see [LICENSE](LICENSE).
