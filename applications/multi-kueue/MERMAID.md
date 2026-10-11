# MultiKueue Preemption Flow

![MultiKueue Preemption Flow](multikueue-preemption-flow.png)

## Key Configuration

- **Cohort** `unreserved` owns the GPU pool (`nominalQuota: 8`)
- **All ClusterQueues** have `nominalQuota: 0` — they borrow from the Cohort
- **`cluster-queue`** has `borrowWithinCohort: LowerPriority` (threshold 100) and `reclaimWithinCohort: Any`
- CQ nominals are **ADDITIVE** to Cohort — any non-zero nominal inflates total capacity and breaks preemption

## Mermaid Source

```mermaid
flowchart TD
    subgraph COHORT["Cohort: unreserved | nominalQuota: 8 GPU"]
        POOL[(GPU Pool
8 GPUs)]
    end

    CQ1["cluster-queue
nominalQuota: 0
borrowWithinCohort: LowerPriority
reclaimWithinCohort: Any"]
    CQ2["unreserved CQ
nominalQuota: 0"]
    CQ3["unreserved-priority CQ
nominalQuota: 0"]

    GPU_POD(["gpu-fake-gpu pod
priority: 0 | 8 GPUs"])
    MK_JOB(["MultiKueue Job
priority: 10000 | needs 1 GPU"])

    GPU_POD -->|"borrows 8 GPU"| CQ2
    CQ2 -->|"borrows from"| POOL
    MK_JOB -->|"submitted to"| CQ1
    CQ1 -->|"tries to borrow"| POOL

    POOL -->|"Cohort FULL 8/8"| DECISION{"borrowWithinCohort:
LowerPriority
triggers preemption"}

    DECISION -->|"gpu-fake-gpu priority 0
< threshold 100"| PREEMPT["PREEMPTED
gpu-fake-gpu evicted"]
    DECISION -->|"GPU freed"| SUCCESS["MultiKueue Job
BORROWS 1 GPU
RUNNING"]

    style COHORT fill:#1a5276,stroke:#2980b9,color:#ecf0f1
    style POOL fill:#2980b9,stroke:#1a5276,color:#fff
    style CQ1 fill:#27ae60,stroke:#1e8449,color:#fff
    style CQ2 fill:#e67e22,stroke:#d35400,color:#fff
    style CQ3 fill:#95a5a6,stroke:#7f8c8d,color:#fff
    style DECISION fill:#e74c3c,stroke:#c0392b,color:#fff
    style PREEMPT fill:#c0392b,stroke:#922b21,color:#fff
    style SUCCESS fill:#27ae60,stroke:#1e8449,color:#fff
    style GPU_POD fill:#f39c12,stroke:#d35400,color:#fff
    style MK_JOB fill:#2ecc71,stroke:#27ae60,color:#fff
```
