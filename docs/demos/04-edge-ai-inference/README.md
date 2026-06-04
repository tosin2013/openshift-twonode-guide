# Demo 4: Edge AI Inference — Object Detection at the Edge

**Objective**: Showcase a lightweight AI inference workload running locally at the edge, without cloud dependency, and prove it remains available during a node failure.

---

## Prerequisites

- A healthy two-node TNF cluster
- `oc` CLI configured

!!! important "Set environment variables first"
    ```bash
    export KUBECONFIG=~/generated_assets/twonode/auth/kubeconfig
    export SSH_KEY=~/.ssh/openshift-twonode-ed25519
    ```

```bash
# Verify cluster health
oc get nodes
oc get clusteroperators | grep -v "True.*False.*False"
# Expected: no output
```

---

## Scenario

A pre-trained YOLOv8 object detection model is packaged as an inference REST API container and deployed using a standard `Deployment` object. A test script sends a sample image to the model's REST endpoint and receives predictions with bounding boxes and confidence scores. The inference service availability is then validated during a node fencing event.

---

## About the Inference Container

This demo uses a lightweight YOLOv8n (nano) model served via a Python FastAPI wrapper.

**Model**: YOLOv8n (COCO-pretrained, 80 object classes)
**Inference throughput**: ~2–5 fps on CPU (demo-grade)
**Endpoint**: REST API returning JSON predictions with bounding boxes and confidence scores

!!! note "Image and dependency notes"
    The `ultralytics/ultralytics:latest-cpu` image (~2GB) contains PyTorch, the ultralytics
    package, and model weights support, but **does NOT include** `fastapi`, `uvicorn`, or
    `python-multipart`. These are installed at pod startup via an `initContainer`.

    The YOLOv8n model weights (`yolov8n.pt`, ~6MB) are downloaded from GitHub at first
    startup. The container must run with `workingDir: /tmp` so the download writes to a
    writable path.

---

## Step 1: Deploy the Inference Service

The deployment uses three components:

1. A **ConfigMap** holding the Python FastAPI server script
2. An **initContainer** that `pip install`s the missing dependencies into a shared `emptyDir` volume
3. The **main container** that runs the server with `PYTHONPATH` pointing to the shared volume

```bash
oc new-project edge-ai-demo
oc label namespace edge-ai-demo \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=baseline \
  pod-security.kubernetes.io/audit=baseline \
  --overwrite

oc apply -n edge-ai-demo -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: yolo-server
  namespace: edge-ai-demo
data:
  server.py: |
    from ultralytics import YOLO
    from fastapi import FastAPI, UploadFile
    from fastapi.responses import JSONResponse
    import uvicorn, io
    from PIL import Image

    model = YOLO("yolov8n.pt")
    app = FastAPI()

    @app.get("/health")
    def health():
        return {"status": "ok", "model": "yolov8n"}

    @app.post("/predict")
    async def predict(file: UploadFile):
        img = Image.open(io.BytesIO(await file.read()))
        results = model(img)
        detections = []
        for r in results:
            for box in r.boxes:
                detections.append({
                    "class": model.names[int(box.cls)],
                    "confidence": round(float(box.conf), 3),
                    "bbox": box.xyxy[0].tolist()
                })
        return JSONResponse({"detections": detections, "count": len(detections)})

    uvicorn.run(app, host="0.0.0.0", port=8080)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: yolo-inference
  namespace: edge-ai-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: yolo-inference
  template:
    metadata:
      labels:
        app: yolo-inference
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: yolo-inference
      volumes:
        - name: scripts
          configMap:
            name: yolo-server
        - name: pip-pkgs
          emptyDir: {}
      initContainers:
        - name: install-deps
          image: ultralytics/ultralytics:latest-cpu
          command:
            - pip
            - install
            - fastapi
            - uvicorn[standard]
            - pillow
            - python-multipart
            - --target
            - /pip-pkgs
            - --quiet
          volumeMounts:
            - name: pip-pkgs
              mountPath: /pip-pkgs
          env:
            - name: HOME
              value: /tmp
      containers:
        - name: inference
          image: ultralytics/ultralytics:latest-cpu
          command:
            - python3
            - /scripts/server.py
          workingDir: /tmp
          ports:
            - containerPort: 8080
          env:
            - name: PYTHONPATH
              value: /pip-pkgs
            - name: HOME
              value: /tmp
            - name: MPLCONFIGDIR
              value: /tmp/mpl
            - name: YOLO_CONFIG_DIR
              value: /tmp/Ultralytics
          resources:
            requests:
              memory: "512Mi"
              cpu: "500m"
            limits:
              memory: "2Gi"
              cpu: "2000m"
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 10
            timeoutSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 90
            periodSeconds: 30
          volumeMounts:
            - name: scripts
              mountPath: /scripts
            - name: pip-pkgs
              mountPath: /pip-pkgs
---
apiVersion: v1
kind: Service
metadata:
  name: yolo-inference
  namespace: edge-ai-demo
spec:
  selector:
    app: yolo-inference
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: yolo-inference
  namespace: edge-ai-demo
spec:
  to:
    kind: Service
    name: yolo-inference
  port:
    targetPort: 8080
EOF
```

Wait for deployment (image pull ~20s per node, pip install ~30s, model download ~5s):

```bash
# Watch until both pods are 1/1 Running (allow up to 5 minutes)
watch oc -n edge-ai-demo get pods -o wide
```

!!! tip "Expected startup sequence"
    1. `Init:0/1` — initContainer installing pip deps
    2. `PodInitializing` → `Running 0/1` — main container starting, downloading model
    3. `Running 1/1` — readiness probe passes, pod ready (~90s after image pull)

```bash
# Verify pods are on different nodes
oc -n edge-ai-demo get pods -o wide
# Expected: one pod on openshift-node1, one on openshift-node2
```

---

## Step 2: Verify the Inference Service

```bash
INFERENCE_URL="http://$(oc -n edge-ai-demo get route yolo-inference -o jsonpath='{.spec.host}')"
echo "Inference endpoint: ${INFERENCE_URL}"

# Health check
curl -s "${INFERENCE_URL}/health" | python3 -m json.tool
# Expected: {"status": "ok", "model": "yolov8n"}
```

---

## Step 3: Download a Test Image and Run Inference

```bash
mkdir -p /tmp/test-images

# Download the ultralytics sample bus image (reliable public source)
curl -sL -o /tmp/test-images/bus.jpg https://ultralytics.com/images/bus.jpg
file /tmp/test-images/bus.jpg
# Expected: JPEG image data

# Send the image to the inference endpoint
curl -s -X POST \
  "${INFERENCE_URL}/predict" \
  -F "file=@/tmp/test-images/bus.jpg" | python3 -m json.tool
```

Expected response:
```json
{
  "detections": [
    {"class": "bus",    "confidence": 0.873, "bbox": [22.9, 231.3, 805.0, 756.8]},
    {"class": "person", "confidence": 0.866, "bbox": [48.6, 398.6, 245.3, 902.7]},
    {"class": "person", "confidence": 0.853, "bbox": [669.5, 392.2, 809.7, 877.0]},
    {"class": "person", "confidence": 0.825, "bbox": [221.5, 405.8, 345.0, 857.5]}
  ],
  "count": 6
}
```

!!! note "Test image source"
    Use `https://ultralytics.com/images/bus.jpg` as the test image — it is a known COCO
    benchmark image that reliably produces detections. Wikipedia image URLs may return
    HTML redirect pages (bot protection) and cause HTTP 500 on `/predict`.

---

## Step 4: Run a Batch Test

```bash
INFERENCE_URL="http://$(oc -n edge-ai-demo get route yolo-inference -o jsonpath='{.spec.host}')"
SUCCESS=0; FAIL=0

for i in $(seq 1 20); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -X POST "${INFERENCE_URL}/predict" \
    -F "file=@/tmp/test-images/bus.jpg")
  if [ "${STATUS}" = "200" ]; then
    SUCCESS=$((SUCCESS + 1))
    echo "Request ${i}: OK (200)"
  else
    FAIL=$((FAIL + 1))
    echo "Request ${i}: FAILED (${STATUS})"
  fi
  sleep 0.5
done

echo "Results: ${SUCCESS}/20 successful, ${FAIL}/20 failed"
# Expected: 20/20 successful
```

---

## Step 5: Validate Availability During Node Failure

=== "Terminal 1 — Monitor"

    ```bash
    INFERENCE_URL="http://$(oc -n edge-ai-demo get route yolo-inference -o jsonpath='{.spec.host}')"
    while true; do
      STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "${INFERENCE_URL}/health")
      echo "$(date +%H:%M:%S) — ${STATUS}"
      sleep 2
    done
    ```

=== "Terminal 2 — Fence"

    ```bash
    # Determine which node has the inference pod you want to fence
    oc -n edge-ai-demo get pods -o wide
    # Fence the node that has one of the two pods (service remains on the other)

    TARGET_NODE=openshift-node2
    VM_UUID=$(sudo virsh domuuid ${TARGET_NODE})
    fence_redfish -a 192.168.122.10 --ssl-insecure -l admin -p admin \
      --systems-uri "/redfish/v1/Systems/${VM_UUID}" --ipport 8000 -o off
    # Expected: "Success: Powered OFF"

    # Watch Terminal 1: expect 2-3 brief 000 responses (~6s gap), then 200 resumes
    # The surviving node's pod keeps serving — recovery is fast

    # After observing recovery, power on the fenced node
    fence_redfish -a 192.168.122.10 --ssl-insecure -l admin -p admin \
      --systems-uri "/redfish/v1/Systems/${VM_UUID}" --ipport 8000 -o on
    ```

!!! note "Why recovery is fast for this demo"
    The `topologySpreadConstraints` ensures one pod on each node. When one node is
    fenced, the other node's pod is **already running** and immediately takes all traffic.
    Recovery is limited only by the OVN ingress VIP migration (~6s), not by pod
    rescheduling. This is much faster than a single-replica deployment.

    Compare to Demo 1's POS service: that demo intentionally uses 1 pod per node to show
    the OVN VIP failover delay of ~5 minutes. With 2 replicas spread across nodes (this
    demo), the surviving pod absorbs traffic within seconds.

---

## Step 6: Post-Recovery Cleanup

After the fenced node rejoins, clean up Pacemaker stale states:

```bash
ssh -i $SSH_KEY core@192.168.49.21 sudo pcs resource cleanup

# Wait for all cluster operators to stabilize (~5-7 minutes)
oc get co --no-headers | grep -v "True.*False.*False"
# Expected: no output

# Verify post-recovery inference quality is unchanged
curl -s -X POST "${INFERENCE_URL}/predict" \
  -F "file=@/tmp/test-images/bus.jpg" | python3 -m json.tool
# Expected: same detections, same confidence scores
```

!!! note "etcd-clone Stopped after node rejoin"
    As documented in Demos 1 and 2, the Pacemaker `etcd-clone` resource may show
    `Stopped` on one node after a failover cycle. If `pcs resource cleanup` does not
    resolve it after 60 seconds:
    ```bash
    ssh -i $SSH_KEY core@192.168.49.21 sudo pcs resource restart etcd-clone
    ```

---

## Expected Validation Output

| Check | Expected Result |
|---|---|
| `/health` endpoint | `{"status": "ok", "model": "yolov8n"}` |
| `/predict` with JPEG | JSON with detections array and confidence scores |
| Batch test (20 requests) | 20/20 successful pre-failover |
| Availability during fence | ~3 brief `000` responses (~6s gap), then continuous `200` |
| Post-recovery inference | Same predictions, same confidence — model unchanged |

---

## Validated Results (2026-06-04)

Run against a KVM-based TNF cluster (OCP 4.22.0-rc.5) on IBM Cloud bare metal.

| Phase | Result |
|---|---|
| `/health` check | ✅ `{"status": "ok", "model": "yolov8n"}` |
| `/predict` — bus.jpg | ✅ bus (87.3%), 4 persons, stop sign detected |
| Batch test — 20 requests | ✅ 20/20 successful |
| Fence `openshift-node2` | ✅ 3 `000` responses out of 120 checks (97.5% availability, ~6s gap) |
| Post-recovery inference | ✅ Identical predictions and confidence scores |

**Key observation**: Recovery after fencing was **~6 seconds** (3×2s health check intervals), compared to ~5 minutes in Demo 1. The difference: 2 replicas with `topologySpreadConstraints` (one per node) means the surviving pod is already warm and serving. The only gap is the brief OVN ingress VIP migration.

---

## Cleanup

```bash
oc delete project edge-ai-demo
```

---

## Notes on CPU-Only Inference

In this demo, inference runs on CPU. For production edge AI deployments consider:

- **GPU-enabled nodes**: NVIDIA GPU Operator on OpenShift provides GPU scheduling for significantly higher throughput
- **Intel OpenVINO**: Hardware-optimized inference for Intel CPUs and integrated GPUs
- **Red Hat OpenShift AI (RHOAI)**: Model serving with KServe/ModelMesh for production inference management
- **Quantized models**: INT8/FP16 quantization reduces memory footprint and improves CPU throughput

The TNF architecture is forward-compatible with all of these approaches — the cluster itself imposes no inference limitations.

---

## Why This Matters

AI inference at the edge is a rapidly growing use case for retail (self-checkout, inventory management, loss prevention) and manufacturing (defect detection, safety monitoring). This demo proves the TNF architecture is forward-compatible with AI workloads — a two-node cluster with minimal hardware is sufficient to run inference services that remain available through hardware failures.
