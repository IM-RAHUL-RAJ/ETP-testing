"""Turn a team's compose override (overrides/<id>.yml: config files mounted into services) into the
Kubernetes way of doing the same: one ConfigMap per mounted file or folder, mounted at the same path,
plus any extra environment values. Prints kubectl commands for the ConfigMaps and appends JSON patches
to the kustomization.
Usage: k8s-configmount.py <override.yml> <k8s dir> <namespace>
"""
import json, sys, yaml
from pathlib import Path

over = yaml.safe_load(open(sys.argv[1]))["services"]
kdir, ns = Path(sys.argv[2]), sys.argv[3]
kust = yaml.safe_load((kdir / "kustomization.yaml").read_text())
patches = kust.setdefault("patches", [])
for svc, spec in over.items():
    ops = [{"op": "add", "path": "/spec/template/spec/volumes", "value": []}]
    mounts = []
    for i, v in enumerate(spec.get("volumes") or []):
        host, target = v.split(":")[:2]
        name = f"{svc}-files-{i}"
        print(f"kubectl -n {ns} create configmap {name} --from-file={host}")
        ops.append({"op": "add", "path": "/spec/template/spec/volumes/-",
                    "value": {"name": name, "configMap": {"name": name}}})
        m = {"name": name, "mountPath": target, "readOnly": True}
        if Path(host).is_file():
            m["subPath"] = Path(host).name
        mounts.append(m)
    for m in mounts:
        ops.append({"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": m})
    for k, val in (spec.get("environment") or {}).items():
        ops.append({"op": "add", "path": "/spec/template/spec/containers/0/env/-",
                    "value": {"name": k, "value": str(val)}})
    if mounts:
        # The container may have no volumeMounts list yet.
        ops.insert(1, {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts", "value": []})
    patches.append({"target": {"kind": "Deployment", "name": svc}, "patch": json.dumps(ops)})
(kdir / "kustomization.yaml").write_text(yaml.safe_dump(kust, sort_keys=False))
