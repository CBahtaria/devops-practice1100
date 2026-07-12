# BRT Platform — CLAUDE.md

## Role: Orchestrator

The current Claude Code session is the **Orchestrator** — planner, dispatcher, and final reviewer. The Orchestrator plans, dispatches child agents, reviews their output against actual changed files, and issues correction commands until each task is approved. The Orchestrator never writes production code directly.

---

## Blocking Gates (must be satisfied before any commit to main)

**Phase 1 — Secret scan. Never proceed past this step until it passes.**
```bash
gitleaks detect --source . --no-git
```
`gitleaks detect` must return 0 findings. Any API key, Redis password, or Qdrant credential in source is an immediate STOP — do not proceed, do not commit.

**Phase 2 — Scope discipline.**
```bash
make verify-scope
```
`scripts/check-scope-discipline.sh` must exit 0. Project B modules (`billing/`, `analytics/`, `data_platform/`, `k8s/`) must not appear in any diff unless the first paid invoice has been received and recorded.

**Phase 3 — Syntax + import check.**
```bash
find brt_platform -name "*.py" -exec python3.12 -m py_compile {} \;
python3.12 -c "
from brt_platform.api.middleware.auth import TenantContextMiddleware
from brt_platform.core.collection_manager import CollectionManager
from brt_platform.core.reranker import SharedModelPool, LightweightReranker
from brt_platform.core.alerting import PlatformAlerter
print('All imports OK')
"
```
Any syntax error or import failure is a blocker.

**Phase 4 — SAST (static analysis).**
```bash
bandit -r brt_platform/ -ll
```
No high-severity findings. Medium findings require a documented exception before commit.

---

## Agent Dispatch Rules

### Use `model: "opus"` for:
- Architecture decisions — new modules, cross-cutting concerns, security design
- Multi-file coordination — changes spanning `rag_engine.py` + `collection_manager.py` + `api/` together
- Review passes — reading implementer output and identifying spec gaps
- Debugging complex failures — async race conditions, import errors, Redis state issues
- Any task where wrong judgment = data loss, security regression, or billing failure

### Use `model: "sonnet"` for:
- Mechanical implementation against a complete spec (Orchestrator has already designed it)
- Single-module additions with clear inputs/outputs
- Writing tests against an already-implemented module
- Fixing issues called out by the reviewer — the fix is already described, just execute it
- Docker/Makefile/pyproject.toml edits with exact content decided

### Use `model: "haiku"` for:
- File reads, grep, existence checks — "is X in this file?"
- Verification — "did the edit land at the right line?"
- Syntax validation — `python -m py_compile`
- Import checks — `python -c "from brt_platform.X import Y"`
- Scope discipline checks — running `make verify-scope`

**Exception**: pure grep/bash in the orchestrating session is faster and cheaper than spawning a Haiku agent. Only spawn Haiku when reading + light reasoning are both needed. For bare `grep`/`find`/`python -m py_compile`, use Bash directly.

---

## Review → Fix → Re-Review Loop

```
1. Orchestrator dispatches implementer (sonnet/opus based on task complexity)
2. Implementer completes, reports DONE
3. Orchestrator reads actual changed files (never trusts the summary alone)
4. If gaps found:
   → SendMessage({ to: <agentId>, message: "fix X — you missed Y at line Z" })
   → Implementer fixes, reports DONE again
5. Repeat — MAX 3 CORRECTION ROUNDS per task.
   Round 3 failure → do NOT re-dispatch sonnet.
   Escalate: dispatch opus to redesign the approach from scratch.
6. Orchestrator runs all four blocking gates before marking complete
7. Task marked complete only after all gates pass
```

Never move to the next task while the current task has open issues.

---

## Review Rubric

An agent's work is **APPROVED** only if ALL of the following hold:

| # | Criterion | How to verify |
|---|-----------|---------------|
| a | Every file the agent claims to have touched has a visible diff | `git diff --name-only` matches the agent's report |
| b | Every finding has a fix AND a verification step | Finding IDs map 1-to-1 in the agent record below |
| c | No new secrets committed | `gitleaks detect` → 0 findings |
| d | Every test the agent named actually ran and passed | Test output included in agent record, no skips |
| e | No doc claim contradicts source | Cross-check any prose claim against the actual file before marking done |

A "looks good" without satisfying all five is not an approval.

---

## Agent Record Schema

Each completed task must have a record in YAML format:

```yaml
agent:         # agent ID or session label
model:         # opus | sonnet | haiku
phase:         # phase number or name within the task
status:        # DONE | NEEDS_REVIEW | BLOCKED
files_touched:
  - path/to/file.py
findings:
  - id:          F-001
    severity:    high | medium | low | info
    title:       Short description
    fix:         What was changed
    verified_by: Command or manual step that confirmed the fix
tests_run:
  - name: test suite or script name
    command: pytest tests/ / make verify-scope / etc.
tests_result: PASS | FAIL | SKIP
residual_risk: >
  Any known limitation, deferred item, or assumption that must be
  revisited before production release.
```

---

## Project: BRT Platform

**Repo root**: `/home/cbartaria1/brt-platform/`
**Runtime**: Python 3.12, Podman 5.8.2 (not Docker)
**Container**: `podman-compose` (Makefile auto-detects podman/docker)
**Registry**: `ghcr.io/cbahtaria/brt-platform`
**Deploy**: `make dev-up` for local, `make build` + push to GHCR for clients

### Phase Discipline (CRITICAL)

**Project A — build now (generates invoices):**
- `brt_platform/core/` — RAG engine, hookable, resilience, alerting, collection manager
- `brt_platform/api/` — FastAPI server, /query, /ingest, /health routes
- `scripts/instant-poc.sh` + `scripts/deploy-client.sh`
- `Dockerfile` (dev stage) + `docker-compose.yml`

**Project B — build ONLY after first paid invoice:**
- `brt_platform/billing/` — Paystack (requires SA entity registration)
- `brt_platform/analytics/` — ClickHouse + Kafka pipeline
- `brt_platform/data_platform/` — Airflow DAGs, Faust streams
- `k8s/`, ArgoCD, Helm charts
- Multi-region data residency

**Enforcement**: `make verify-scope` runs `scripts/check-scope-discipline.sh` before any build.

### Architecture

```
BRT Platform (Python 3.12 / FastAPI)
├── core/
│   ├── rag_engine.py        ← hybrid dense+sparse, RRF, rerank, Hookable
│   ├── hookable.py          ← tenant overrides without forking core
│   ├── collection_manager.py← asyncio + Redis distributed lock, VECTOR_SIZE enforced
│   ├── embedder.py          ← BGE-large-en-v1.5 (dense) + Splade_PP (sparse), ThreadPoolExecutor
│   ├── reranker.py          ← MiniLM-L-6-v2, SharedModelPool (threading.Lock singleton)
│   ├── resilience.py        ← CircuitBreaker (CLOSED→OPEN→HALF_OPEN) + OfflineEventBuffer
│   ├── alerting.py          ← PlatformAlerter: MD5 cooldown keys, Redis-resilient, direct httpx
│   ├── connection_pool.py   ← Qdrant gRPC keepalive (30s), connection pooling
│   └── streaming.py         ← SSE generator
├── api/
│   ├── server.py            ← FastAPI app, OTel, on_startup model preload
│   ├── routes/              ← /query, /ingest, /health, /metrics
│   └── middleware/auth.py   ← X-Tenant-ID header → request.state.tenant_id (Phase 0)
├── plugins/                 ← Phase 2: PostHog-style hooks, AST sandbox
├── analytics/               ← Phase 3: ClickHouse, Kafka (Project B)
├── billing/                 ← Phase 4: Paystack (blocked: needs SA entity)
└── compliance/              ← Phase 4: POPIA/GDPR export
```

### Key Invariants

**Never break these:**
- `CLICKHOUSE_AVAILABLE` guard in `rag_engine.py` — never hard-import ClickHouse at top level
- `VECTOR_SIZE` enforced at module load — raises `ValueError` on unknown `EMBEDDING_MODEL`
- `AlertingPy` uses `hashlib.md5()` for cooldown keys — never `hash()` (randomizes on restart)
- `CollectionManager` uses Redis `SET NX EX 10` distributed lock — asyncio lock alone is not enough
- `CircuitBreaker` has HALF_OPEN state — `_schedule_half_open()` must be an async task
- `Dockerfile` HEALTHCHECK uses Python `urllib.request` — not `curl` (read-only FS)
- `kafka-python`, `clickhouse-connect`, `apache-airflow`, `faust` are optional extras — NOT in core deps

### Redis Key Namespace (from `config.py`)
```python
class RedisKeyPrefix:
    ALERT_COOLDOWN          = "brt:alert:cooldown"
    PAYSTACK_PROCESSED      = "brt:paystack:processed"
    PAYSTACK_LOCK           = "brt:paystack:lock"
    QDRANT_COLLECTION_LOCK  = "brt:qdrant:create"
    CIRCUIT_BREAKER_STATE   = "brt:cb:state"
    CIRCUIT_BREAKER_FAILURES= "brt:cb:failures"
    RATE_LIMIT              = "brt:ratelimit"
    TENANT_SESSION          = "brt:session"
```
No ad-hoc Redis key strings outside `config.py`.

### Environment
```bash
EMBEDDING_MODEL=BAAI/bge-large-en-v1.5   # 1024 dims — only valid values in VECTOR_DIMENSIONS dict
QDRANT_URL=http://qdrant:6334             # gRPC port (not 6333 HTTP)
KAFKA_KRAFT_CLUSTER_ID=<stable-uuid>     # generate ONCE: podman run --rm bitnami/kafka:3.6 kafka-storage.sh random-uuid
```

### Coding Standards

- Python 3.12 only — no 3.11 (missing typing), no 3.14 (pre-release)
- Async-first — all I/O in `async def`, model loading in `ThreadPoolExecutor`
- All exceptions inherit `BRTError` from `brt_platform.exceptions`
- No `print()` — use `logging.getLogger(__name__)`
- `set -euo pipefail` on all shell scripts
- `make verify-scope` must pass before any commit to main

### ClickHouse Notes
- Timezone: `Africa/Johannesburg` (NOT `Africa/Mbabane` — doesn't exist in IANA)
- ARM64: use `CLICKHOUSE_IMAGE=altinity/clickhouse-server:23.8` (official has no ARM64 build)

### Verification Commands
```bash
# Syntax check
find brt_platform -name "*.py" -exec python3.12 -m py_compile {} \;

# Import check
python3.12 -c "
from brt_platform.api.middleware.auth import TenantContextMiddleware
from brt_platform.core.collection_manager import CollectionManager
from brt_platform.core.reranker import SharedModelPool, LightweightReranker
from brt_platform.core.alerting import PlatformAlerter
print('All imports OK')
"

# Scope discipline
make verify-scope

# Local stack
make dev-up
curl http://localhost:8000/health
```
