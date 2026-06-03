# Demo 4: Edge AI Inference — Object Detection at the Edge

**Objective**: Showcase a lightweight AI inference workload running locally at the edge, without cloud dependency, and prove it remains available during a node failure.

---

## Prerequisites

- A healthy two-node TNF cluster
- `oc` CLI configured
- Internet access from the cluster (to pull the inference container image), or a local mirror

```bash
# Verify cluster health
oc get nodes
oc get clusteroperators | grep -v "True.*False.*False"
```

---

## Scenario

A pre-trained YOLOv8 object detection model is packaged as an inference REST API container and deployed using a standard `Deployment` object. A test script sends sample retail images (product barcodes, shelf images) to the model's REST endpoint and receives predictions. The inference service availability is then validated during a node fencing event (reusing the approach from Demo 1).

---

## About the Inference Container

This demo uses a lightweight YOLOv8n (nano) model served via a Python FastAPI wrapper. The inference runs entirely on CPU — no GPU is required — making it suitable for the edge hardware targeted by TNF.

**Model**: YOLOv8n (COCO-pretrained, 80 object classes)
**Inference throughput**: ~2-5 fps on CPU (demo-grade — production edge inference typically uses dedicated accelerators)
**Endpoint**: REST API returning JSON predictions with bounding boxes and confidence scores

---

## Step 1: Deploy the Inference Service

```bash
oc new-project edge-ai-demo

# Deploy the inference service
# The image packages YOLOv8n weights + FastAPI server
oc apply -f - <<'EOF'
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
      containers:
        - name: inference
          # Using ultralytics/ultralytics as a publicly available YOLOv8 image
          image: ultralytics/ultralytics:latest-cpu
          command:
            - python3
            - -c
            - |
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
          ports:
            - containerPort: 8080
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
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 30
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

# Wait for deployment to become ready (model download takes 1-2 minutes)
oc -n edge-ai-demo rollout status deployment/yolo-inference

# Verify pods are on different nodes
oc -n edge-ai-demo get pods -o wide
```

## Step 2: Verify the Inference Service

```bash
INFERENCE_URL="http://$(oc -n edge-ai-demo get route yolo-inference -o jsonpath='{.spec.host}')"
echo "Inference endpoint: ${INFERENCE_URL}"

# Health check
curl -s "${INFERENCE_URL}/health" | python3 -m json.tool
# Expected: {"status": "ok", "model": "yolov8n"}
```

## Step 3: Download Test Images and Run Inference

```bash
# Download sample retail images (publicly available)
mkdir -p /tmp/test-images

# Download a shelf image (substitute with actual retail images as needed)
curl -L -o /tmp/test-images/shelf.jpg \
  "https://upload.wikimedia.org/wikipedia/commons/thumb/2/26/YellowLabradorLooking_new.jpg/320px-YellowLabradorLooking_new.jpg"

# Also test with any JPEG from your local machine:
# cp /path/to/retail-image.jpg /tmp/test-images/

# Send an image to the inference endpoint
curl -s -X POST \
  "${INFERENCE_URL}/predict" \
  -F "file=@/tmp/test-images/shelf.jpg" | python3 -m json.tool

# Expected response format:
# {
#   "detections": [
#     {"class": "dog", "confidence": 0.921, "bbox": [12.3, 45.6, 300.1, 280.4]}
#   ],
#   "count": 1
# }
```

## Step 4: Run a Batch Test

```bash
# Send a batch of 20 requests and measure availability
INFERENCE_URL="http://$(oc -n edge-ai-demo get route yolo-inference -o jsonpath='{.spec.host}')"
SUCCESS=0
FAIL=0

for i in $(seq 1 20); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -X POST "${INFERENCE_URL}/predict" \
    -F "file=@/tmp/test-images/shelf.jpg")
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
```

## Step 5: Validate Availability During Node Failure

Reuse the fencing approach from Demo 1 while the inference service is running.

```bash
# Terminal 1: Start continuous inference requests (monitor availability)
INFERENCE_URL="http://$(oc -n edge-ai-demo get route yolo-inference -o jsonpath='{.spec.host}')"
while true; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "${INFERENCE_URL}/health")
  echo "$(date +%H:%M:%S) — ${STATUS}"
  sleep 2
done
```

```bash
# Terminal 2: Fence one node
NODE2_UUID=$(virsh domuuid openshift-node2)
fence_redfish -a localhost --ssl-insecure -l admin -p changeme \
  -b "/redfish/v1/Systems/${NODE2_UUID}" -o off

echo "Node 2 fenced. Watch Terminal 1 for availability."

# After ~30s, verify inference pods rescheduled
oc -n edge-ai-demo get pods -o wide

# Restore node
sleep 60
fence_redfish -a localhost --ssl-insecure -l admin -p changeme \
  -b "/redfish/v1/Systems/${NODE2_UUID}" -o on
```

---

## Expected Validation Output

| Check | Expected Result |
|---|---|
| `/health` endpoint | `{"status": "ok", "model": "yolov8n"}` |
| `/predict` with JPEG image | JSON with detections array and confidence scores |
| Batch test (20 requests) | 20/20 successful pre-failover |
| Availability during node fencing | Brief gap (~10-30s) then 200 responses resume |
| Post-recovery inference | All requests succeed, same prediction quality |

---

## Notes on CPU-Only Inference

In this demo, inference runs on CPU. For production edge AI deployments consider:

- **GPU-enabled nodes**: NVIDIA GPU Operator on OpenShift provides GPU scheduling for significantly higher throughput
- **Intel OpenVINO**: Hardware-optimized inference for Intel CPUs and integrated GPUs
- **Red Hat OpenShift AI (RHOAI)**: Model serving with KServe/ModelMesh for production inference management
- **Quantized models**: INT8/FP16 quantization reduces memory footprint and improves CPU throughput

The TNF architecture is forward-compatible with all of these approaches — the cluster itself imposes no inference limitations.

---

## Cleanup

```bash
oc delete project edge-ai-demo
```

---

## Why This Matters

AI inference at the edge is a rapidly growing use case for retail (self-checkout, inventory management, loss prevention) and manufacturing (defect detection, safety monitoring). This demo proves the TNF architecture is forward-compatible with AI workloads — a two-node cluster with minimal hardware is sufficient to run inference services that remain available through hardware failures.
