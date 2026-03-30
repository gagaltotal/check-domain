# Check Domain dan Subdomain

Tool ini melakukan:
- enumerasi subdomain otomatis menggunakan `subfinder`, `assetfinder`, dan `amass`
- pengecekan status HTTP/HTTPS secara real-time
- penyimpanan hasil ke JSON untuk Grafana dan dashboard
- websocket realtime untuk update live
- endpoint status per host dan prom metrics

## Fitur
- auto enumerasi subdomain dari daftar domain di environment `DOMAINS`
- HTTP/HTTPS check dengan fallback
- histori uptime per host
- output Grafana JSON di `grafana_metrics.json`
- API FastAPI untuk dashboard dan health check
- websocket realtime di `/ws`
- Prometheus-style metrics di `/metrics`

## Prasyarat
- Python 3.8+ (direkomendasikan Python 3.12)
- `subfinder` terpasang
- `assetfinder` dan `amass` bila tersedia untuk enumerasi lebih lengkap
- dependency Python:
  - `aiohttp`
  - `fastapi`
  - `uvicorn`
  - `websockets`

## Instalasi

```sh
python -m venv .venv
source .venv/bin/activate
pip install aiohttp fastapi uvicorn websockets
```

## Menjalankan

```sh
python check.py
```

Atau dengan environment variable:

```sh
DOMAINS="example.com;example.org" CHECK_INTERVAL=60 PORT=8000 python check.py
```

## Menggunakan .env

File `.env` di folder project akan dibaca otomatis saat `check.py` dijalankan. Contoh isi `.env`:

```ini
DOMAINS=domain.com
CHECK_INTERVAL=60
REENUM_INTERVAL=3600
CONCURRENCY=500
BATCH_SIZE=2000
TIMEOUT=10
HOST=0.0.0.0
PORT=8000
```

Jika `DOMAINS_FILE` diatur, nilai `DOMAINS` akan dibaca dari file tersebut.

Jika tidak ada `DOMAINS` di `.env` atau environment, default `example.com` akan digunakan.

## Endpoint
- `/` : ringkasan terbaru hasil pemantauan
- `/health` : status service dan jumlah domain yang dilacak
- `/domains` : daftar domain input dan host yang ditemukan
- `/status` : status semua host saat ini
- `/status/{host}` : status host tertentu
- `/grafana` : output JSON untuk Grafana
- `/metrics` : metrik Prometheus
- `/ws` : websocket realtime

## Output File
- `monitor_result.json` : ringkasan hasil monitoring
- `grafana_metrics.json` : array objek metric untuk Grafana

## Konfigurasi
Gunakan environment variable untuk menyesuaikan behavior:
- `DOMAINS`: daftar domain utama, dipisah dengan spasi, koma, atau titik koma
- `CHECK_INTERVAL`: interval scan dalam detik
- `REENUM_INTERVAL`: interval enumerasi ulang subdomain
- `BATCH_SIZE`: jumlah host per batch scan
- `CONCURRENCY`: batas koneksi async
- `TIMEOUT`: timeout request HTTP
- `HOST`: alamat bind server
- `PORT`: port server
- `DATA_DIR`: folder untuk menyimpan `monitor_result.json` dan `grafana_metrics.json`

## Contoh Grafana
Gunakan `http://localhost:8000/grafana` sebagai data source JSON atau parsing data dari `grafana_metrics.json`.

## Lisensi
Open Source