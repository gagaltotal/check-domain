# Check Domain dan Sub domain
untuk simple check domain dan subdomain terjadi down dan up

Fitur:
- check enumarate domain menggunakan subfinder
- report list domain dengan format json dan txt

Prasyarat:
- Python 3.8+
- install subfinder
- aiohttp: pip install aiohttp
- aiodns: pip install aiodns  

# install subfinder

```sh
git clone https://github.com/projectdiscovery/subfinder.git
cd subfinder/cmd/subfinder
go build
mv subfinder /usr/local/bin/
subfinder -version

```

Bisa cek lebih lengkap install subfinder di docs:
```sh
https://docs.projectdiscovery.io/opensource/subfinder/install
```

# install package pakai virtual atau venv

```sh
python -m venv check-domain
source check-domain/bin/activate
pip install aiohttp aiodns
```

# Contoh Pakai :

```sh
$ python check.py
```

Lisensi: Open Source