import asyncio, itertools, os, random, time, logging
from pathlib import Path
import httpx
from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from fastapi.responses import FileResponse

# --- 1. CẤU HÌNH LOGGING ---
logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)-8s | %(message)s", datefmt="%H:%M:%S")
logger = logging.getLogger("Gateway")

CLUSTER_NAMES = ("c1", "c2", "c3")
INITIAL_CLUSTERS = {}
for cluster_name in CLUSTER_NAMES:
    prefix = f"CLUSTER_{cluster_name.upper()}"
    cluster_url = os.environ.get(f"{prefix}_URL", "").strip()
    cluster_auth = os.environ.get(f"{prefix}_AUTH_B64", "").strip()
    if cluster_url and cluster_auth:
        INITIAL_CLUSTERS[cluster_name] = (cluster_url, cluster_auth)

CONFIG = {
    "policy": "rr",
    "breaker_on": True,
    "probe_action": "test-thu",
    "max_retries": 2
}

API_BASE = "/api/v1/namespaces/_/actions/"
HDR = {"Content-Type": "application/json"}

state = {}
ring = None
state_lock = asyncio.Lock()

def init_node(url, auth):
    return {
        "url": url,
        "auth": auth,
        "http": httpx.AsyncClient(base_url=url, verify=False, timeout=30.0,
                                limits=httpx.Limits(max_connections=200, max_keepalive_connections=50),
                                headers={"Authorization": "Basic " + auth}),
        "up": True,
        "available": True,
        "fails": 0, "oks": 0, "ewma": 0.1
    }

def build_ring():
    global ring
    ring = itertools.cycle(list(state.keys()) if state else [])

app = FastAPI(title="OpenWhisk Multi-Cluster Gateway")
BASE_DIR = Path(__file__).resolve().parent

@app.get("/")
async def gateway_dashboard():
    return FileResponse(BASE_DIR / "dashboard.html")

# --- 2. CẤU HÌNH CORS ---
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

ACTIVE = os.environ.get("ACTIVE", "c1,c2,c3").split(",")
for name in ACTIVE:
    if name and name not in INITIAL_CLUSTERS:
        logger.warning(f"⏭ Bỏ qua [{name}]: thiếu CLUSTER_{name.upper()}_URL hoặc CLUSTER_{name.upper()}_AUTH_B64")
for name, (url, auth) in INITIAL_CLUSTERS.items():
    if name in ACTIVE:
        state[name] = init_node(url, auth)
build_ring()

def pick():
    alive = [n for n, s in state.items() if s["available"] and (s["up"] or not CONFIG["breaker_on"])]
    if not alive:
        return None
    if CONFIG["policy"] == "latency":
        return random.choices(alive, [1 / state[n]["ewma"] for n in alive])[0]
    elif CONFIG["policy"] == "random":
        return random.choice(alive)

    for _ in range(len(state)):
        n = next(ring, None)
        if n in alive:
            return n
    return None

def report(name, ok):
    if name not in state: return
    s = state[name]
    if ok:
        s["fails"] = 0; s["oks"] += 1
        if not s["up"] and s["oks"] >= 2:
            s["up"] = True
            logger.info(f"✅ ĐÓNG CẦU DAO: Cụm [{name}] đã phục hồi và sẵn sàng nhận tải.")
    else:
        s["oks"] = 0; s["fails"] += 1
        if s["up"] and s["fails"] >= 10:  # Nâng lên 10 lần fail mới ngắt cầu dao
            s["up"] = False
            logger.warning(f"❌ NGẮT CẦU DAO: Cụm [{name}] đã sập hoặc không phản hồi!")

@app.post("/invoke/{action}")
async def invoke(action: str, request: Request):
    body = await request.body()

    for attempt in range(CONFIG["max_retries"] + 1):
        name = pick()
        if name is None:
            logger.error("🛑 Toàn bộ hệ thống OpenWhisk đã sập hoặc đang bảo trì.")
            return Response(content="All clusters down or in maintenance", status_code=503)

        if attempt > 0:
            logger.warning(f"🔄 Đang kích hoạt Failover (Thử lại lần {attempt}): Chuyển hướng sang [{name}]")

        s = state[name]
        t0 = time.perf_counter()
        try:
            url = f"{API_BASE}{action}?blocking=true&result=true"
            r = await s["http"].post(url, content=body, headers=HDR)
            r.raise_for_status()

            s["ewma"] = 0.8 * s["ewma"] + 0.2 * (time.perf_counter() - t0)
            report(name, True)
            return Response(r.content, r.status_code, media_type="application/json")

        except httpx.HTTPError as e:
            logger.error(f"⚠️ Lỗi kết nối tới [{name}]: {str(e)}")
            report(name, False)
            continue

    return Response(content="Gateway Error: All retries failed", status_code=502)

async def global_probe():
    logger.info("🕵️ Bắt đầu tiến trình giám sát sức khỏe (Ping ngầm mỗi 2s)...")
    while True:
        await asyncio.sleep(2)
        async with state_lock:
            current_nodes = list(state.keys())
        for name in current_nodes:
            s = state.get(name)
            if not s: continue
            try:
                url = f"{API_BASE}{CONFIG['probe_action']}?blocking=true&result=true"
                r = await s["http"].post(url, content="{}", headers=HDR, timeout=2.0)
                report(name, r.status_code == 200)
            except httpx.HTTPError:
                report(name, False)

@app.on_event("startup")
async def start():
    asyncio.create_task(global_probe())

# --- 3. DỌN RÁC RAM KHI TẮT SERVER ---
@app.on_event("shutdown")
async def shutdown():
    logger.info("🧹 Đang đóng các kết nối mạng an toàn trước khi tắt Gateway...")
    for s in state.values():
        await s["http"].aclose()

class NodeConfig(BaseModel):
    url: str
    auth: str

@app.post("/admin/clusters/{name}")
async def add_or_update_node(name: str, config: NodeConfig):
    async with state_lock:
        if name in state:
            await state[name]["http"].aclose()
        state[name] = init_node(config.url, config.auth)
        build_ring()
    logger.info(f"➕ Đã thêm/cập nhật cấu hình máy ảo [{name}]")
    return {"status": "ok", "message": f"Node {name} added/updated", "nodes": list(state.keys())}

@app.delete("/admin/clusters/{name}")
async def remove_node(name: str):
    async with state_lock:
        if name in state:
            await state[name]["http"].aclose()
            del state[name]
            build_ring()
            logger.info(f"➖ Đã gỡ bỏ máy ảo [{name}] khỏi mạng lưới")
            return {"status": "ok", "message": f"Node {name} removed"}
    return Response(status_code=404)

@app.post("/admin/clusters/{name}/toggle")
async def toggle_cluster(name: str, available: bool):
    if name in state:
        state[name]["available"] = available
        status_text = "MỞ KHÓA" if available else "BẢO TRÌ"
        logger.info(f"⚙️ Chuyển trạng thái [{name}] sang: {status_text}")
        return {"status": "ok", "node": name, "available": available}
    return Response(status_code=404)

@app.post("/admin/config")
async def update_config(policy: str = None, breaker: str = None, probe_action: str = None):
    if policy in ["rr", "latency", "random"]:
        CONFIG["policy"] = policy
        logger.info(f"🔀 Đổi thuật toán cân bằng tải thành: {policy.upper()}")
    if breaker in ["on", "off"]:
        CONFIG["breaker_on"] = (breaker == "on")
    if probe_action:
        CONFIG["probe_action"] = probe_action
        logger.info(f"🎯 Đổi mục tiêu ping ngầm sang: {probe_action}")
    return CONFIG

@app.get("/admin/clusters")
async def clusters():
    return {
        "config": CONFIG,
        "nodes": {n: {
                    "available": s["available"],
                    "up": s["up"],
                    "fails": s["fails"],
                    "ewma_ms": round(s["ewma"] * 1000, 1),
                    "url": s["url"]
                  }
                  for n, s in state.items()}
    }
