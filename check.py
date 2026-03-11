import asyncio
import aiohttp
import subprocess
import json
import time
from datetime import datetime, timezone
from fastapi import FastAPI, WebSocket
from contextlib import asynccontextmanager
import uvicorn

# ================= CONFIG =================

DOMAINS = [
    "example.com" #domain
]

CHECK_INTERVAL = 60
REENUM_INTERVAL = 3600

BATCH_SIZE = 2000
CONCURRENCY = 800
TIMEOUT = 5

# ==========================================

hosts = []
clients = set()
history = {}

# ================= ENUMERATION =================

def enum_subfinder(domain):

    subs=set()

    try:
        r=subprocess.run(
            ["subfinder","-silent","-d",domain],
            capture_output=True,
            text=True
        )

        for s in r.stdout.splitlines():
            subs.add(s.strip())

    except:
        pass

    return subs


def enumerate_all():

    global hosts

    all_hosts=set()

    for d in DOMAINS:

        all_hosts.add(d)

        subs=enum_subfinder(d)

        all_hosts |= subs

    hosts=list(all_hosts)

    print("DISCOVERED HOSTS:",len(hosts))


# ================= HTTP CHECK =================

async def http_check(session,host):

    urls=[f"http://{host}",f"https://{host}"]

    headers={"User-Agent":"MonitorBot/6.1"}

    for url in urls:

        start=time.time()

        try:

            async with session.get(
                url,
                headers=headers,
                allow_redirects=True
            ) as r:

                latency=time.time()-start

                if r.status<500 or r.status==403:

                    return host,True,latency

        except:
            pass

    return host,False,None


# ================= HISTORY =================

def update_history(host,up):

    h=history.setdefault(host,{"up":0,"total":0})

    h["total"]+=1

    if up:
        h["up"]+=1


def uptime(host):

    h=history.get(host)

    if not h:
        return 0

    return round((h["up"]/h["total"])*100,2)


# ================= SAVE RESULT =================

def save_results(results):

    up=[]
    down=[]
    grafana=[]

    for host,ok,lat in results:

        update_history(host,ok)

        if ok:
            up.append(host)
        else:
            down.append(host)

        grafana.append({
            "host":host,
            "up":1 if ok else 0,
            "latency":lat,
            "uptime_percent":uptime(host),
            "timestamp":int(time.time())
        })

    data={
        "timestamp":datetime.now(timezone.utc).isoformat(),
        "total_domains":len(results),
        "total_up":len(up),
        "total_down":len(down),
        "up_domains":up,
        "down_domains":down
    }

    with open("monitor_result.json","w") as f:
        json.dump(data,f,indent=2)

    with open("grafana_metrics.json","w") as f:
        json.dump(grafana,f)

    return data


# ================= WEBSOCKET =================

async def broadcast(item):

    if not clients:
        return

    msg=json.dumps(item)

    dead=set()

    for ws in clients:

        try:
            await ws.send_text(msg)
        except:
            dead.add(ws)

    clients.difference_update(dead)


# ================= SCANNER =================

async def scan_batch(session,batch):

    sem=asyncio.Semaphore(CONCURRENCY)

    results=[]

    async def worker(host):

        async with sem:

            r=await http_check(session,host)

            results.append(r)

            await broadcast({
                "host":r[0],
                "up":r[1],
                "latency":r[2]
            })

    await asyncio.gather(*(worker(h) for h in batch))

    return results


# ================= MONITOR LOOP =================

async def monitor():

    timeout=aiohttp.ClientTimeout(total=TIMEOUT)

    connector=aiohttp.TCPConnector(limit=CONCURRENCY,ttl_dns_cache=300)

    async with aiohttp.ClientSession(
        connector=connector,
        timeout=timeout
    ) as session:

        while True:

            results=[]

            for i in range(0,len(hosts),BATCH_SIZE):

                batch=hosts[i:i+BATCH_SIZE]

                r=await scan_batch(session,batch)

                results.extend(r)

            save_results(results)

            print("SCAN COMPLETE:",len(results))

            await asyncio.sleep(CHECK_INTERVAL)


# ================= AUTO DISCOVERY =================

async def auto_discovery():

    while True:

        enumerate_all()

        await asyncio.sleep(REENUM_INTERVAL)


# ================= FASTAPI =================

@asynccontextmanager
async def lifespan(app:FastAPI):

    enumerate_all()

    asyncio.create_task(monitor())
    asyncio.create_task(auto_discovery())

    yield


app=FastAPI(lifespan=lifespan)


@app.get("/")
def dashboard():

    try:
        with open("monitor_result.json") as f:
            return json.load(f)
    except:
        return {"status":"no data yet"}


@app.get("/grafana")
def grafana():

    try:
        with open("grafana_metrics.json") as f:
            return json.load(f)
    except:
        return []


@app.websocket("/ws")
async def ws(ws:WebSocket):

    await ws.accept()

    clients.add(ws)

    try:
        while True:
            await ws.receive_text()
    except:
        clients.remove(ws)


# ================= START =================

async def main():

    BEGIN_TIME = datetime.now(timezone.utc).isoformat()

    BANNER = r"""
    ╔══════════════════════════════════════════════════════════════════════╗
    ║                           * MONITOR MODE *                           ║
    ║      Type commands to execute on monitor domain and subdomains       ║
    ╚══════════════════════════════════════════════════════════════════════╝
    """

    print(f"Monitoring started at {BEGIN_TIME}")

    print(BANNER)


if __name__=="__main__":

    asyncio.run(main())

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        loop="uvloop"
    )