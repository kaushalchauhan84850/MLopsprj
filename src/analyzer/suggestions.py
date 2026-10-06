"""Rule-based debugging knowledge base: maps anomaly signatures to concrete
debugging steps (with ready-to-run kubectl commands) that get attached to
every alert and RCA report."""


def _num(row, key):
    v = row.get(key)
    if isinstance(v, (int, float)) and v == v:
        return float(v)
    return 0.0


def get_suggestions(etype, row, res=None):
    """Return a list of debugging steps for a scored window."""
    ns = row.get("namespace") or "<ns>"
    name = row.get("name") or "<name>"
    s = []

    if etype == "pod":
        if _num(row, "oom_recent") > 0:
            s += [
                f"Container was OOMKilled. Compare working set vs limit: kubectl -n {ns} describe pod {name}",
                f"If usage creeps up over hours -> probable memory leak; capture trend from Grafana 'Pod memory' panel",
                f"Raise limits if legit growth: kubectl -n {ns} set resources deploy/<owner> --limits=memory=...",
                f"Check recent rollout/change: kubectl -n {ns} rollout history deploy/<owner>",
            ]
        if _num(row, "restarts_15m") > 0:
            s += [
                f"Read the crash logs: kubectl -n {ns} logs {name} --previous --tail=100",
                f"Check events: kubectl -n {ns} get events --field-selector involvedObject.name={name} --sort-by=.lastTimestamp",
                "If CrashLoopBackOff after a deploy -> rollback: kubectl -n "
                f"{ns} rollout undo deploy/<owner>, then diff the last two ReplicaSets",
            ]
        if _num(row, "not_ready") > 0:
            s += [
                f"Pod is NotReady. kubectl -n {ns} describe pod {name} (look at Conditions + probe failures)",
                "Readiness probe failing? check probe path/timeout; app may be slow on startup or dependency down",
            ]
        if _num(row, "cpu_ratio") > 0.90:
            s += [
                f"CPU at {_num(row, 'cpu_ratio'):.0%} of limit -> likely CFS throttling (high container_cpu_cfs_throttled_periods_total)",
                f"Scale out or raise CPU limits: kubectl -n {ns} scale deploy/<owner> --replicas=+2",
                "Hot loop or bad deploy? correlate with kubectl rollout history and recent images",
            ]
        if _num(row, "mem_ratio") > 0.90:
            s += [
                f"Memory at {_num(row, 'mem_ratio'):.0%} of limit -> OOMKill risk, raise limits or fix leak",
                "Compare container_memory_working_set_bytes trend vs limit over the last 24h in Grafana",
            ]
        if _num(row, "net_err_10m") > 0 or _num(row, "net_drop_10m") > 0:
            s += [
                "Network errors/drops detected -> check CNI (calico/cilium) pod health and node NIC errors",
                "DNS failures? check CoreDNS: kubectl -n kube-system get pods | grep coredns, and coredns Prometheus metrics",
            ]
    elif etype == "svc":
        if _num(row, "http_5xx_rate") > 0.5:
            s += [
                f"Elevated 5xx rate ({_num(row, 'http_5xx_rate'):.1f}/s) -> find failing route in app logs (Grafana Explore -> Loki)",
                f"Check dependencies (DB/cache) health and recent deploys: kubectl -n {ns} rollout history deploy",
                "Look for connection pool exhaustion / timeouts in the service logs before the errors started",
            ]
        if _num(row, "latency_p95") > 1.0:
            s += [
                f"p95 latency {_num(row, 'latency_p95'):.2f}s -> check downstream calls, DB slow queries, GC pauses",
                "Correlate with CPU throttling / memory pressure on the serving pods (Grafana pod panels)",
                "Saturation? check current replicas vs KEDA scaling: kubectl get scaledobject -n " + ns,
            ]
        if _num(row, "rps") > 0 and _num(row, "latency_p95") > 0.3 and _num(row, "http_5xx_rate") > 0:
            s.append("Latency AND errors rising together -> classic saturation cascade; scale out first, root-cause second")
    elif etype == "node":
        if _num(row, "pressure_signals") > 0:
            s += [
                f"Node {name} reports MemoryPressure/DiskPressure -> kubelet will evict pods",
                f"Top consumers: kubectl describe node {name} (Allocated resources) and check for leaked emptyDir/PVCs",
                "Consider cordon + drain if pressure persists: kubectl cordon " + name,
            ]
        if _num(row, "node_mem_used") > 0.92:
            s.append(f"Node memory {_num(row, 'node_mem_used'):.0%} used -> eviction threshold imminent")
        if _num(row, "node_cpu_used") > 0.95:
            s.append(f"Node CPU {_num(row, 'node_cpu_used'):.0%} -> pods on this node are being throttled")
    elif etype == "pvc":
        if _num(row, "pvc_used_ratio") > 0.85:
            s += [
                f"PVC {ns}/{name} is {_num(row, 'pvc_used_ratio'):.0%} full -> expand or clean up",
                f"kubectl -n {ns} get pvc {name}; expand: patch spec.resources.requests.storage (needs allowVolumeExpansion)",
                "Check for log hoarding: log rotation / retention on apps writing to this volume",
            ]

    if res and res.get("top_factors"):
        s.append("Top statistical deviations vs learned baseline: " + "; ".join(res["top_factors"]))
    if not s:
        s.append(f"Statistical anomaly on {row.get('_key')}: inspect recent changes "
                 f"(kubectl -n {ns} rollout history) and correlated metrics in Grafana")
    return s[:8]
