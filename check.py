import asyncio
import json
import os
import re
import subprocess
import time
from contextlib import asynccontextmanager, suppress
from datetime import datetime, timezone
from pathlib import Path

import aiohttp
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles

# ================= CONFIG =================

def load_dotenv(dotenv_path=None):
    if dotenv_path is None:
        dotenv_path = Path(__file__).parent / ".env"

    if not dotenv_path.exists():
        return

    for line in dotenv_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value

load_dotenv()

DOMAIN_ENV = os.getenv("DOMAINS", "").strip()
DOMAINS_FILE = os.getenv("DOMAINS_FILE")

if DOMAINS_FILE:
    path = Path(DOMAINS_FILE)
    if path.exists():
        DOMAIN_ENV = path.read_text().strip()

if not DOMAIN_ENV:
    DOMAIN_ENV = "example.com"

DOMAINS = [d.strip() for d in re.split(r"[\s,;]+", DOMAIN_ENV) if d.strip()]

print("DOMAINS:", DOMAINS)

CHECK_INTERVAL = int(os.getenv("CHECK_INTERVAL", "60"))
REENUM_INTERVAL = int(os.getenv("REENUM_INTERVAL", "3600"))
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "2000"))
CONCURRENCY = int(os.getenv("CONCURRENCY", "500"))
TIMEOUT = int(os.getenv("TIMEOUT", "10"))
HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "8000"))
USE_UVLOOP = os.getenv("USE_UVLOOP", "1").lower() in {"1", "true", "yes"}
DATA_DIR = Path(os.getenv("DATA_DIR", "."))
REPORT_DIR = DATA_DIR / "report"

def dated_file(prefix, now=None):
    if now is None:
        now = datetime.now(timezone.utc)
    return REPORT_DIR / f"{prefix}_{now:%Y_%m_%d}.json"


def current_result_file():
    return dated_file("monitor_result")


def current_grafana_file():
    return dated_file("grafana_metrics")

# ==========================================

hosts = []
clients = set()
history = {}
latest_snapshot = {}

# ================= ENUMERATION =================

def run_enumeration_command(cmd):
    result = set()
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        for line in proc.stdout.splitlines():
            host = line.strip()
            if host:
                result.add(host)
    except (FileNotFoundError, subprocess.SubprocessError):
        pass
    return result


def enum_subfinder(domain):
    return run_enumeration_command(["subfinder", "-silent", "-d", domain])


def enum_assetfinder(domain):
    return run_enumeration_command(["assetfinder", "--subs-only", domain])


def enum_amass(domain):
    return run_enumeration_command([
        "amass",
        "enum",
        "-passive",
        "-d",
        domain,
        "-norecursive",
        "-silent",
    ])


def enumerate_all():
    global hosts

    all_hosts = set(DOMAINS)

    for domain in DOMAINS:
        all_hosts |= enum_subfinder(domain)
        all_hosts |= enum_assetfinder(domain)
        all_hosts |= enum_amass(domain)

    hosts = sorted(all_hosts)
    print(f"DISCOVERED HOSTS: {len(hosts)}")
    if hosts:
        print("SAMPLE HOSTS:", ", ".join(hosts[:10]))


# ================= HTTP CHECK =================

async def http_check(session, host):
    urls = [f"https://{host}", f"http://{host}"]
    headers = {
        "User-Agent": "MonitorBot/6.1",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    }

    for url in urls:
        start = time.time()
        try:
            async with session.get(url, headers=headers, allow_redirects=True) as response:
                latency = round(time.time() - start, 4)
                status = response.status
                if status < 500 or status in {401, 403, 429, 408}:
                    return host, True, latency
        except Exception:
            pass

    return host, False, None


# ================= HISTORY =================

def update_history(host, up):
    record = history.setdefault(host, {"up": 0, "total": 0})
    record["total"] += 1
    record["up"] += int(bool(up))
    return record


def uptime(host):
    record = history.get(host)
    if not record or record["total"] == 0:
        return 0.0
    return round((record["up"] / record["total"]) * 100.0, 2)


# ================= SAVE RESULT =================

def save_results(results):
    global latest_snapshot

    REPORT_DIR.mkdir(parents=True, exist_ok=True)

    up = []
    down = []
    grafana = []
    snapshot = {}

    for host, ok, latency in results:
        update_history(host, ok)
        uptime_pct = uptime(host)

        if ok:
            up.append(host)
        else:
            down.append(host)

        item = {
            "host": host,
            "up": 1 if ok else 0,
            "status": "up" if ok else "down",
            "latency": latency,
            "uptime_percent": uptime_pct,
            "timestamp": int(time.time()),
        }

        snapshot[host] = item
        grafana.append(item)

    latest_snapshot = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total_domains": len(results),
        "total_up": len(up),
        "total_down": len(down),
        "up_domains": up,
        "down_domains": down,
        "hosts": snapshot,
    }

    result_file = current_result_file()
    grafana_file = current_grafana_file()

    with open(result_file, "w") as f:
        json.dump(latest_snapshot, f, indent=2)

    with open(grafana_file, "w") as f:
        json.dump(grafana, f)

    return latest_snapshot


# ================= WEBSOCKET =================

async def broadcast(item):
    if not clients:
        return

    payload = json.dumps(item)
    dead = set()

    for ws in list(clients):
        try:
            await ws.send_text(payload)
        except Exception:
            dead.add(ws)

    clients.difference_update(dead)


# ================= SCANNER =================

async def scan_batch(session, batch):
    sem = asyncio.Semaphore(CONCURRENCY)
    results = []

    async def worker(host):
        async with sem:
            host, ok, latency = await http_check(session, host)
            results.append((host, ok, latency))
            await broadcast({
                "type": "scan_update",
                "host": host,
                "up": ok,
                "latency": latency,
                "uptime_percent": uptime(host),
                "timestamp": int(time.time()),
            })

    await asyncio.gather(*(worker(host) for host in batch), return_exceptions=True)
    return results


# ================= MONITOR LOOP =================

async def monitor():
    timeout = aiohttp.ClientTimeout(total=TIMEOUT)
    connector = aiohttp.TCPConnector(limit=CONCURRENCY, ttl_dns_cache=300)

    async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
        while True:
            if not hosts:
                await asyncio.sleep(5)
                continue

            all_results = []
            for start in range(0, len(hosts), BATCH_SIZE):
                batch = hosts[start : start + BATCH_SIZE]
                batch_results = await scan_batch(session, batch)
                all_results.extend(batch_results)

            snapshot = save_results(all_results)
            print(f"SCAN COMPLETE: {len(all_results)} hosts, up={len(snapshot['up_domains'])}, down={len(snapshot['down_domains'])}")
            await asyncio.sleep(CHECK_INTERVAL)


# ================= AUTO DISCOVERY =================

async def auto_discovery():
    while True:
        enumerate_all()
        await asyncio.sleep(REENUM_INTERVAL)


# ================= FASTAPI =================

@asynccontextmanager
async def lifespan(app: FastAPI):
    enumerate_all()
    monitor_task = asyncio.create_task(monitor())
    discovery_task = asyncio.create_task(auto_discovery())

    try:
        yield
    finally:
        for task in (monitor_task, discovery_task):
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task


app = FastAPI(lifespan=lifespan)
app.mount("/static", StaticFiles(directory=Path(__file__).parent / "static"), name="static")


def report_dates():
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    dates = set()
    for path in REPORT_DIR.iterdir():
        if path.is_file() and path.name.startswith("monitor_result_") and path.suffix == ".json":
            match = re.match(r"monitor_result_(\d{4}_\d{2}_\d{2})\.json$", path.name)
            if match:
                dates.add(match.group(1))
    return sorted(dates)


@app.get("/")
def dashboard():
    if latest_snapshot:
        return latest_snapshot
    result_file = current_result_file()
    if result_file.exists():
        with open(result_file) as f:
            return json.load(f)
    return {"status": "no data yet"}


@app.get("/health")
def health():
    return {
        "status": "ok",
        "domains_tracked": len(hosts),
        "last_scan": latest_snapshot.get("timestamp") if latest_snapshot else None,
    }


@app.get("/domains")
def domain_list():
    return {"domains": DOMAINS, "discovered_hosts": hosts}


@app.get("/status")
def status_all():
    if latest_snapshot:
        return latest_snapshot["hosts"]
    return {}


@app.get("/status/{host}")
def status_host(host: str):
    snapshot = latest_snapshot.get("hosts") if latest_snapshot else {}
    return snapshot.get(host) or {"host": host, "status": "unknown"}


@app.get("/grafana")
def grafana():
    grafana_file = current_grafana_file()
    if grafana_file.exists():
        with open(grafana_file) as f:
            return json.load(f)
    return []


@app.get("/reports")
def reports():
    return {
        "dates": report_dates(),
        "current": bool(latest_snapshot or current_result_file().exists()),
    }


@app.get("/reports/{date}")
def report(date: str):
    if date == "current":
        if latest_snapshot:
            return latest_snapshot
        result_file = current_result_file()
        if result_file.exists():
            with open(result_file) as f:
                return json.load(f)
        raise HTTPException(status_code=404, detail="Tidak ada data realtime saat ini")

    if not re.fullmatch(r"\d{4}_\d{2}_\d{2}", date):
        raise HTTPException(status_code=400, detail="Format tanggal tidak valid")

    report_file = REPORT_DIR / f"monitor_result_{date}.json"
    if not report_file.exists():
        raise HTTPException(status_code=404, detail="Laporan untuk tanggal ini tidak ditemukan")

    with open(report_file) as f:
        return json.load(f)


@app.get("/dashboard", response_class=HTMLResponse)
def dashboard_page():
    path = Path(__file__).parent / "static" / "index.html"
    return path.read_text()


@app.get("/metrics")
def prometheus_metrics():
    lines = [
        "# HELP domain_up Whether the domain is reachable (1 = up, 0 = down)",
        "# TYPE domain_up gauge",
        "# HELP domain_latency_seconds HTTP latency in seconds",
        "# TYPE domain_latency_seconds gauge",
        "# HELP domain_uptime_percent Percent uptime for the domain",
        "# TYPE domain_uptime_percent gauge",
    ]
    snapshot = latest_snapshot.get("hosts") if latest_snapshot else {}
    for host, data in snapshot.items():
        labels = f'host="{host}"'
        lines.append(f"domain_up{{{labels}}} {data['up']}")
        lines.append(f"domain_latency_seconds{{{labels}}} {data['latency'] or 0}")
        lines.append(f"domain_uptime_percent{{{labels}}} {data['uptime_percent']}")
    return "\n".join(lines) + "\n"


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await ws.accept()
    clients.add(ws)

    try:
        if latest_snapshot:
            await ws.send_text(json.dumps({"type": "snapshot", "data": latest_snapshot}))
        while True:
            await ws.receive_text()
    except (WebSocketDisconnect, Exception):
        pass
    finally:
        clients.discard(ws)


def main():
    banner = r"""
     ██████╗██╗  ██╗███████╗ ██████╗██╗  ██╗    ██████╗  ██████╗ ███╗   ███╗ █████╗ ██╗███╗   ██╗
    ██╔════╝██║  ██║██╔════╝██╔════╝██║ ██╔╝    ██╔══██╗██╔═══██╗████╗ ████║██╔══██╗██║████╗  ██║
    ██║     ███████║█████╗  ██║     █████╔╝     ██║  ██║██║   ██║██╔████╔██║███████║██║██╔██╗ ██║
    ██║     ██╔══██║██╔══╝  ██║     ██╔═██╗     ██║  ██║██║   ██║██║╚██╔╝██║██╔══██║██║██║╚██╗██║
    ╚██████╗██║  ██║███████╗╚██████╗██║  ██╗    ██████╔╝╚██████╔╝██║ ╚═╝ ██║██║  ██║██║██║ ╚████║
     ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝    ╚═════╝  ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝
    """
    print(banner)
    print(f"Listening on http://{HOST}:{PORT}")

    try:
        uvicorn.run(app, host=HOST, port=PORT, loop="uvloop" if USE_UVLOOP else None)
    except KeyboardInterrupt:
        print("Shutdown requested by user")
    except Exception as exc:
        print(f"Server error: {exc}")


if __name__ == "__main__":
    main()
