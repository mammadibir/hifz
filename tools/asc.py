"""App Store Connect helper for the build pipeline (uses the API key from the repository secrets).

prepare     registers the app's bundle ID if needed and checks that the app exists in App Store Connect
testflight  makes sure there is an internal TestFlight group that gets every build, with every team member in it
"""
import os
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = os.environ.get("BUNDLE_ID", "io.github.mammadibir.hifz")
GROUP = "Семья"


def token():
    key_id = os.environ["ASC_KEY_ID"]
    with open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


def call(method, path, **kw):
    r = requests.request(method, API + path, headers={"Authorization": "Bearer " + token()}, timeout=60, **kw)
    if r.status_code >= 400:
        detail = "; ".join(e.get("detail") or e.get("title", "") for e in r.json().get("errors", [])) if r.text else ""
        raise SystemExit(f"::error::App Store Connect {method} {path}: {r.status_code} {detail}")
    return r.json() if r.text else {}


def find_app():
    apps = call("GET", "/apps", params={"filter[bundleId]": BUNDLE_ID})["data"]
    return apps[0] if apps else None


def prepare():
    found = call("GET", "/bundleIds", params={"filter[identifier]": BUNDLE_ID})["data"]
    if not [b for b in found if b["attributes"]["identifier"] == BUNDLE_ID]:
        call("POST", "/bundleIds", json={"data": {"type": "bundleIds", "attributes": {
            "identifier": BUNDLE_ID, "name": "Hifz", "platform": "IOS"}}})
        print(f"::notice::Зарегистрирован идентификатор приложения {BUNDLE_ID}")
    app = find_app()
    if not app:
        print(f"::error::В App Store Connect ещё нет приложения с идентификатором {BUNDLE_ID}. "
              "Создайте его: App Store Connect → Приложения → + → Новое приложение → iOS, "
              f"любое свободное имя, язык русский, идентификатор пакета {BUNDLE_ID}, SKU hifz. "
              "Потом запустите сборку ещё раз.")
        sys.exit(1)
    print(f"::notice::Приложение в App Store Connect: {app['attributes']['name']} ({app['id']})")


def testflight(build_number):
    app = find_app()
    if not app:
        sys.exit(1)
    groups = call("GET", f"/apps/{app['id']}/betaGroups")["data"]
    group = next((g for g in groups if g["attributes"].get("isInternalGroup") and g["attributes"]["name"] == GROUP), None)
    if not group:
        group = call("POST", "/betaGroups", json={"data": {"type": "betaGroups",
            "attributes": {"name": GROUP, "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app["id"]}}}}})["data"]
        print(f"::notice::Создана группа TestFlight «{GROUP}»: в неё сразу попадает каждая новая сборка")
    have = {t["attributes"].get("email", "").lower()
            for t in call("GET", f"/betaGroups/{group['id']}/betaTesters", params={"limit": 200})["data"]}
    for user in call("GET", "/users", params={"limit": 100})["data"]:
        a = user["attributes"]
        email = (a.get("username") or a.get("email") or "").lower()
        if not email or email in have:
            continue
        try:
            call("POST", "/betaTesters", json={"data": {"type": "betaTesters",
                "attributes": {"email": email, "firstName": a.get("firstName") or "", "lastName": a.get("lastName") or ""},
                "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group["id"]}]}}}})
            print(f"::notice::В TestFlight добавлен {email}")
        except SystemExit as e:
            print(str(e).replace("::error::", "::warning::"))
    builds = call("GET", "/builds", params={"filter[app]": app["id"], "filter[version]": str(build_number)})["data"]
    state = builds[0]["attributes"].get("processingState") if builds else "ещё загружается"
    print(f"::notice::Сборка {build_number}: {state}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "prepare":
        prepare()
    elif cmd == "testflight":
        testflight(sys.argv[2] if len(sys.argv) > 2 else "")
    else:
        print(__doc__)
