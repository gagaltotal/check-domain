import asyncio
import aiohttp
import aiodns
import subprocess
import socket
import ssl
import json
import time
from datetime import datetime, timezone

# ================= CONFIG =================

DOMAINS = [
    "example.com" #domain
]

CHECK_INTERVAL = 60
TIMEOUT = 8
CONCURRENT_REQUESTS = 100
RETRY = 2

RESPONSE_THRESHOLD = 10  # seconds time 

COMMON_SUBS = [
    "www","mail","webmail","ftp","cpanel",
    "api","dev","test","staging","admin",
    "panel","blog","shop","ns1","ns2"
]

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    "Accept": "*/*"
}

# ==========================================


# ============ ENUMERATION ============

def enum_subfinder(domain):
    subs = set()
    try:
        result = subprocess.run(
            ["subfinder","-silent","-d",domain],
            capture_output=True,
            text=True,
            timeout=120
        )

        for line in result.stdout.splitlines():
            subs.add(line.strip().lower())

    except Exception as e:
        print("Subfinder error:", e)

    return subs


def brute_common(domain):
    found=set()

    for sub in COMMON_SUBS:
        host=f"{sub}.{domain}"
        try:
            socket.gethostbyname(host)
            found.add(host)
        except:
            pass

    return found


def enumerate_all():

    all_hosts=set()

    for domain in DOMAINS:

        print(f"[+] ENUM {domain}")

        all_hosts.add(domain)

        sf=enum_subfinder(domain)
        brute=brute_common(domain)

        print("  Subfinder:",len(sf))
        print("  Bruteforce:",len(brute))

        all_hosts |= sf | brute

    print("TOTAL HOST:",len(all_hosts))

    return list(all_hosts)


# ============ NETWORK CHECKS ============

async def resolve_dns(host,resolver):

    try:
        await resolver.query_dns(host, "A")
        return True
    except:
        return False


async def tcp_check(host,port):

    try:
        reader,writer=await asyncio.wait_for(
            asyncio.open_connection(host,port),
            timeout=3
        )
        writer.close()
        await writer.wait_closed()
        return True

    except:
        return False


async def ssl_check(host):

    try:
        ctx=ssl.create_default_context()

        reader,writer=await asyncio.open_connection(
            host,
            443,
            ssl=ctx,
            server_hostname=host
        )

        writer.close()
        await writer.wait_closed()

        return True

    except:
        return False


async def http_check(session,host):

    urls=[f"http://{host}",f"https://{host}"]

    for _ in range(RETRY):

        for url in urls:

            start=time.time()

            try:

                async with session.get(
                    url,
                    timeout=TIMEOUT,
                    allow_redirects=True
                ) as resp:

                    elapsed=time.time()-start

                    if elapsed>RESPONSE_THRESHOLD:
                        return False

                    if resp.status<500 or resp.status==403:
                        return True

            except:
                pass

    return False


async def ping_check(host):

    try:

        proc=await asyncio.create_subprocess_exec(
            "ping","-c","1","-W","2",host,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL
        )

        await proc.communicate()

        return proc.returncode==0

    except:
        return False


# ============ HOST CHECK ============

async def check_host(session,host,semaphore,resolver):

    async with semaphore:

        # DNS
        dns_ok=await resolve_dns(host,resolver)
        if not dns_ok:
            return host,False

        # TCP
        tcp80=await tcp_check(host,80)
        tcp443=await tcp_check(host,443)

        if not tcp80 and not tcp443:
            return host,False

        # SSL
        if tcp443:
            ssl_ok=await ssl_check(host)
        else:
            ssl_ok=False

        # HTTP
        http_ok=await http_check(session,host)

        if http_ok:
            return host,True

        # fallback ping
        ping_ok=await ping_check(host)

        return host,ping_ok


# ============ SAVE RESULT ============

def save_results(up_list,down_list):

    timestamp = datetime.now(timezone.utc).isoformat()

    result={
        "timestamp":timestamp,
        "total_domains":len(up_list)+len(down_list),
        "total_up":len(up_list),
        "total_down":len(down_list),
        "up_domains":sorted(up_list),
        "down_domains":sorted(down_list)
    }

    with open("monitor_result.json","w") as f:
        json.dump(result,f,indent=4)

    with open("monitor_result.txt","w") as f:

        f.write(f"Timestamp: {timestamp}\n")
        f.write(f"Total Domains: {result['total_domains']}\n")
        f.write(f"Total UP: {result['total_up']}\n")
        f.write(f"Total DOWN: {result['total_down']}\n\n")

        f.write("=== UP DOMAINS ===\n")

        for d in result["up_domains"]:
            f.write(d+"\n")

        f.write("\n=== DOWN DOMAINS ===\n")

        for d in result["down_domains"]:
            f.write(d+"\n")


# ============ MONITOR ============

async def monitor(hosts):

    status_map={}

    semaphore=asyncio.Semaphore(CONCURRENT_REQUESTS)

    resolver=aiodns.DNSResolver()

    while True:

        print("\n===== CHECK ROUND =====")

        up_list=[]
        down_list=[]

        async with aiohttp.ClientSession(headers=HEADERS) as session:

            tasks=[
                check_host(session,host,semaphore,resolver)
                for host in hosts
            ]

            results=await asyncio.gather(*tasks)

        for host,is_up in results:

            if is_up:
                up_list.append(host)
            else:
                down_list.append(host)

            old=status_map.get(host)

            if old is None:
                print(f"[INIT] {host} => {'UP' if is_up else 'DOWN'}")

            elif old and not is_up:
                print(f"[ALERT] DOWN: {host}")

            elif not old and is_up:
                print(f"[RECOVER] UP: {host}")

            status_map[host]=is_up

        save_results(up_list,down_list)

        print(f"UP: {len(up_list)} | DOWN: {len(down_list)}")

        print(f"Sleep {CHECK_INTERVAL}s...\n")

        await asyncio.sleep(CHECK_INTERVAL)


# ============ MAIN ============

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

    hosts=enumerate_all()

    await monitor(hosts)


if __name__=="__main__":

    asyncio.run(main())