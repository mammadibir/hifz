"""Copies the site to Yandex Object Storage, where it opens on Russian mobile internet without VPN.

Runs in GitHub Actions (.github/workflows/yandex.yml) on every push to main. Needs the repository secrets
YC_KEY_ID and YC_SECRET: a static access key of a Yandex Cloud service account with the storage.admin role.
Optional repository variables: YC_BUCKET (bucket name), YC_GATEWAY (address of the API gateway made from
tools/gateway.yaml), YC_RECITERS (everyayah folders to store on the site, comma separated).

What it does:
  1. creates the bucket if needed: public reading, website hosting (index.html), CORS for GET;
  2. uploads the files that changed (MD5 against the stored ETag), removes files that are gone;
  3. stores a copy of the Firebase login library under vendor/, so login does not depend on gstatic.com;
  4. stores the ayah audio of the chosen reciters under audio/<folder>/ (only missing files are fetched);
  5. writes net.json for the app: which reciters are stored here and the gateway address;
  6. checks the addresses and prints the result in the run summary.
"""
import concurrent.futures as cf
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

BUCKET = (os.environ.get('YC_BUCKET') or 'hifz-mammadibir').strip()
ROOT = os.path.abspath(os.environ.get('SITE_DIR') or os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
HERE = os.path.dirname(os.path.abspath(__file__))
RECITERS = [r.strip() for r in (os.environ.get('YC_RECITERS') or 'Alafasy_128kbps').split(',') if r.strip()]
FB_VER = '10.12.2'
SKIP_TOP = {'.git', '.github', 'tools'}
KEEP_PREFIXES = ('audio/',)          # stored separately, never removed as "stale"
ENDPOINT = 'https://storage.yandexcloud.net'
WEBSITE = f'https://{BUCKET}.website.yandexcloud.net/'
STORAGE = f'https://{BUCKET}.storage.yandexcloud.net/'
AYAHS = [7, 286, 200, 176, 120, 165, 206, 75, 129, 109, 123, 111, 43, 52, 99, 128, 111, 110, 98, 135, 112, 78, 118, 64, 77,
         227, 93, 88, 69, 60, 34, 30, 73, 54, 45, 83, 182, 88, 75, 85, 54, 53, 89, 59, 37, 35, 38, 29, 18, 45, 60, 49, 62, 55,
         78, 96, 29, 22, 24, 13, 14, 11, 11, 18, 12, 12, 30, 52, 52, 44, 28, 28, 20, 56, 40, 31, 50, 40, 46, 42, 29, 19, 36,
         25, 22, 17, 19, 26, 30, 20, 15, 21, 11, 8, 8, 19, 5, 8, 8, 11, 11, 8, 3, 9, 5, 4, 7, 3, 6, 3, 5, 4, 5, 6]
assert len(AYAHS) == 114 and sum(AYAHS) == 6236

TYPES = {
    '.html': 'text/html; charset=utf-8', '.json': 'application/json; charset=utf-8', '.js': 'application/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8', '.txt': 'text/plain; charset=utf-8', '.yaml': 'text/plain; charset=utf-8',
    '.webmanifest': 'application/manifest+json; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png',
    '.jpg': 'image/jpeg', '.ico': 'image/x-icon', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf',
    '.mp3': 'audio/mpeg', '.wasm': 'application/wasm',
}
NO_CACHE = {'index.html', 'version.json', 'net.json', 'manifest.webmanifest'}
LONG_CACHE = ('qpc/', 'fonts/', 'vendor/', 'audio/')

SUMMARY = []


def log(msg):
    print(msg, flush=True)


def notice(msg, level='notice'):
    """Shown as an annotation on the run, so it can be read without opening the log."""
    print(f'::{level}::{msg}', flush=True)
    SUMMARY.append(('⚠️ ' if level != 'notice' else '') + msg)


def write_summary():
    path = os.environ.get('GITHUB_STEP_SUMMARY')
    if not path:
        return
    with open(path, 'a', encoding='utf-8') as f:
        f.write('## Копия сайта на Yandex Cloud\n\n')
        for line in SUMMARY:
            f.write(f'- {line}\n')


def content_type(key):
    return TYPES.get(os.path.splitext(key)[1].lower(), 'application/octet-stream')


def cache_control(key):
    if key in NO_CACHE:
        return 'no-cache'
    if key.startswith(LONG_CACHE):
        return 'public, max-age=2592000'
    return 'public, max-age=600'


def md5(data):
    return hashlib.md5(data).hexdigest()


def fetch(url, tries=5, timeout=60):
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'hifz-mirror/1.0 (+https://github.com/mammadibir/hifz)'})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            last = e
            if e.code == 404:
                break
        except Exception as e:  # network hiccup: wait and retry
            last = e
        time.sleep(1.5 * (i + 1))
    raise RuntimeError(f'{url}: {last}')


def status(url, timeout=20):
    try:
        req = urllib.request.Request(url, method='GET', headers={'User-Agent': 'hifz-check/1.0', 'Range': 'bytes=0-1023'})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:
        return type(e).__name__


def client():
    import boto3
    from botocore.config import Config
    kw = dict(retries={'max_attempts': 8, 'mode': 'standard'}, max_pool_connections=40)
    try:  # newer botocore adds checksum headers that third-party S3 services may reject
        cfg = Config(request_checksum_calculation='when_required', response_checksum_validation='when_required', **kw)
    except TypeError:
        cfg = Config(**kw)
    return boto3.client('s3', endpoint_url=ENDPOINT, region_name='ru-central1',
                        aws_access_key_id=os.environ['YC_KEY_ID'], aws_secret_access_key=os.environ['YC_SECRET'], config=cfg)


def ensure_bucket(s3):
    from botocore.exceptions import ClientError
    try:
        s3.head_bucket(Bucket=BUCKET)
        log(f'bucket {BUCKET} exists')
    except ClientError as e:
        code = str(e.response.get('Error', {}).get('Code', ''))
        if code in ('404', 'NoSuchBucket', 'NotFound'):
            log(f'creating bucket {BUCKET}')
            try:
                s3.create_bucket(Bucket=BUCKET, ACL='public-read')
            except ClientError as e2:
                c2 = str(e2.response.get('Error', {}).get('Code', ''))
                if c2 in ('BucketAlreadyExists',):
                    notice(f'Имя бакета {BUCKET} занято другим пользователем Yandex Cloud. Задайте другое имя в переменной '
                           f'репозитория YC_BUCKET (Settings → Secrets and variables → Actions → Variables).', 'error')
                    sys.exit(1)
                raise
        elif code in ('403', 'AccessDenied', 'Forbidden'):
            notice(f'Нет доступа к бакету {BUCKET}: либо имя занято другим пользователем, либо у сервисного аккаунта нет роли '
                   f'storage.admin. Ответ сервера: {code}.', 'error')
            sys.exit(1)
        else:
            raise
    for what, call in [
        ('public read', lambda: s3.put_bucket_acl(Bucket=BUCKET, ACL='public-read')),
        ('website', lambda: s3.put_bucket_website(Bucket=BUCKET, WebsiteConfiguration={
            'IndexDocument': {'Suffix': 'index.html'}, 'ErrorDocument': {'Key': 'index.html'}})),
        ('cors', lambda: s3.put_bucket_cors(Bucket=BUCKET, CORSConfiguration={'CORSRules': [{
            'AllowedOrigins': ['*'], 'AllowedMethods': ['GET', 'HEAD'], 'AllowedHeaders': ['*'], 'MaxAgeSeconds': 3600}]})),
    ]:
        try:
            call()
            log(f'bucket {what}: ok')
        except Exception as e:
            notice(f'Не удалось настроить бакет ({what}): {e}', 'warning')


def remote_listing(s3):
    """key -> etag (without quotes) for everything in the bucket"""
    out = {}
    for page in s3.get_paginator('list_objects_v2').paginate(Bucket=BUCKET):
        for o in page.get('Contents', []) or []:
            out[o['Key']] = (o.get('ETag') or '').strip('"')
    return out


def local_files():
    files = {}
    for dirpath, dirnames, filenames in os.walk(ROOT):
        rel = os.path.relpath(dirpath, ROOT)
        top = rel.split(os.sep)[0]
        if rel != '.' and (top in SKIP_TOP or top.startswith('.')):
            dirnames[:] = []
            continue
        if rel == '.':
            dirnames[:] = [d for d in dirnames if d not in SKIP_TOP and not d.startswith('.')]
        for fn in filenames:
            if fn.startswith('.'):
                continue
            key = fn if rel == '.' else rel.replace(os.sep, '/') + '/' + fn
            files[key] = os.path.join(dirpath, fn)
    return files


def put(s3, key, data):
    s3.put_object(Bucket=BUCKET, Key=key, Body=data, ContentType=content_type(key), CacheControl=cache_control(key), ACL='public-read')


def upload_many(s3, items, remote, label):
    """items: list of (key, bytes-or-path). Uploads those whose MD5 differs from the stored ETag."""
    todo = []
    for key, src in items:
        data = src if isinstance(src, (bytes, bytearray)) else open(src, 'rb').read()
        if remote.get(key) != md5(data):
            todo.append((key, data))
    log(f'{label}: {len(todo)} of {len(items)} to upload')
    errors = []
    with cf.ThreadPoolExecutor(16) as ex:
        futs = {ex.submit(put, s3, k, d): k for k, d in todo}
        for f in cf.as_completed(futs):
            try:
                f.result()
            except Exception as e:
                errors.append(f'{futs[f]}: {e}')
    if errors:
        notice(f'{label}: не загрузилось {len(errors)} файлов, например {errors[0]}', 'warning')
    return len(todo) - len(errors)


def vendor_files():
    out = []
    for name in ('firebase-app-compat.js', 'firebase-auth-compat.js', 'firebase-firestore-compat.js'):
        try:
            out.append((f'vendor/firebase/{FB_VER}/{name}', fetch(f'https://www.gstatic.com/firebasejs/{FB_VER}/{name}')))
        except Exception as e:
            notice(f'Не удалось скачать {name}: {e}', 'warning')
    return out


def mirror_audio(s3, remote):
    complete = []
    for folder in RECITERS:
        wanted = [f'audio/{folder}/{s:03d}{v:03d}.mp3' for s in range(1, 115) for v in range(1, AYAHS[s - 1] + 1)]
        missing = [k for k in wanted if k not in remote]
        log(f'audio {folder}: {len(wanted) - len(missing)} stored, {len(missing)} to fetch')
        failed = []

        def one(key):
            data = fetch('https://everyayah.com/data/' + key[len('audio/'):])
            put(s3, key, data)

        started = time.time()
        with cf.ThreadPoolExecutor(24) as ex:
            futs = {ex.submit(one, k): k for k in missing}
            for n, f in enumerate(cf.as_completed(futs), 1):
                try:
                    f.result()
                except Exception as e:
                    failed.append(f'{futs[f]}: {e}')
                if n % 500 == 0:
                    log(f'  {n}/{len(missing)} in {int(time.time() - started)} s')
        have = len(wanted) - len(failed)
        if failed:
            notice(f'Аудио {folder}: не скачалось {len(failed)} файлов (повторится при следующем запуске), например {failed[0]}', 'warning')
        if have >= 0.98 * len(wanted):
            complete.append(folder)
        notice(f'Аудио {folder}: на сайте {have} из {len(wanted)} аятов.')
    return complete


def gateway_address():
    g = (os.environ.get('YC_GATEWAY') or '').strip()
    if not g and os.path.exists(os.path.join(HERE, 'gateway.txt')):
        g = open(os.path.join(HERE, 'gateway.txt'), encoding='utf-8').read().strip()
    if g and not g.startswith('http'):
        g = 'https://' + g
    return g.rstrip('/')


def main():
    if not os.environ.get('YC_KEY_ID') or not os.environ.get('YC_SECRET'):
        notice('Секреты YC_KEY_ID и YC_SECRET не заданы — копия на Yandex Cloud пока не обновляется.', 'warning')
        write_summary()
        return
    s3 = client()
    ensure_bucket(s3)
    remote = remote_listing(s3)
    log(f'{len(remote)} objects in the bucket')

    files = local_files()
    last = ['index.html', 'version.json']           # go up after everything they refer to
    items = [(k, p) for k, p in sorted(files.items()) if k not in last]
    items += vendor_files()
    n1 = upload_many(s3, items, remote, 'site')

    complete = mirror_audio(s3, remote) if RECITERS else []
    proxy = gateway_address()
    net = {'mirror': complete, 'proxy': proxy}
    upload_many(s3, [('net.json', json.dumps(net, ensure_ascii=False).encode())], remote, 'net.json')
    n2 = upload_many(s3, [(k, files[k]) for k in last if k in files], remote, 'entry')

    expected = set(files) | {k for k, _ in items} | {'net.json'}
    stale = [k for k in remote if k not in expected and not k.startswith(KEEP_PREFIXES)]
    for i in range(0, len(stale), 1000):
        s3.delete_objects(Bucket=BUCKET, Delete={'Objects': [{'Key': k} for k in stale[i:i + 1000]], 'Quiet': True})
    log(f'removed {len(stale)} stale objects')
    notice(f'Загружено файлов сайта: {n1 + n2}, удалено старых: {len(stale)}. Чтецы на сайте: {", ".join(complete) or "нет"}.'
           + (f' Шлюз: {proxy}' if proxy else ' Шлюз не задан (вход в аккаунт без VPN пока недоступен).'))

    time.sleep(3)
    checks = [('сайт', WEBSITE), ('сайт (резервный адрес)', STORAGE + 'index.html'), ('net.json', STORAGE + 'net.json')]
    if complete:
        checks.append(('аудио', WEBSITE + f'audio/{complete[0]}/001001.mp3'))
    if proxy:
        checks.append(('шлюз: аудио', proxy + '/ea/Alafasy_128kbps/001001.mp3'))
        checks.append(('шлюз: слова', proxy + '/wbw/001_001_001.mp3'))
    for label, url in checks:
        st = status(url)
        ok = st in (200, 206)
        notice(f'{"OK" if ok else "НЕ ОТКРЫВАЕТСЯ"} {label}: {url} → {st}', 'notice' if ok else 'warning')
    write_summary()


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        write_summary()
        raise
    except Exception as e:
        notice(f'Ошибка: {type(e).__name__}: {e}', 'error')
        write_summary()
        raise
