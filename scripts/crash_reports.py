"""Prints the technical part of recent TestFlight crash reports, to find why the app crashed.

Reads the crash submissions testers sent from the TestFlight prompt, through the App Store Connect API.
Only what explains the crash is printed (when, device, build, exception, the crashed thread's frames);
tester comments and contact details are left out, since the run's log may be visible to others.
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

import jwt

BUNDLE_ID = "io.github.reiji55.threedays"
API = "https://api.appstoreconnect.apple.com"


def token():
    key = os.environ["APP_STORE_CONNECT_PRIVATE_KEY"].replace("\\n", "\n")
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["APP_STORE_CONNECT_ISSUER_ID"], "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": os.environ["APP_STORE_CONNECT_KEY_IDENTIFIER"], "typ": "JWT"})


def get(path, params=None):
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token()})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        print(f"{path}: HTTP {error.code} {error.read()[:400]!r}")
        return None


def summarize_ips(text):
    """A crash log in Apple's .ips form: a header line of JSON, then the report as JSON."""
    head, _, body = text.partition("\n")
    report = json.loads(body)
    header = json.loads(head)
    print("  app:", header.get("app_version"), header.get("build_version"), "os:", header.get("os_version"))
    print("  exception:", json.dumps(report.get("exception"), ensure_ascii=False))
    if report.get("termination"):
        print("  termination:", json.dumps(report["termination"], ensure_ascii=False)[:600])
    for key in ("asi", "ktriageinfo", "lastExceptionBacktrace"):
        if report.get(key):
            print(f"  {key}:", json.dumps(report[key], ensure_ascii=False)[:1500])
    images = report.get("usedImages", [])
    threads = report.get("threads", [])
    faulting = report.get("faultingThread", 0)
    if faulting < len(threads):
        thread = threads[faulting]
        print(f"  crashed thread {faulting}:", thread.get("queue", ""), thread.get("name", ""))
        for frame in thread.get("frames", [])[:40]:
            image = images[frame["imageIndex"]] if frame.get("imageIndex", -1) < len(images) else {}
            name = image.get("name", "?")
            symbol = frame.get("symbol", "")
            location = f'{frame.get("sourceFile", "")}:{frame.get("sourceLine", "")}' if frame.get("sourceFile") else ""
            print(f'    {name:28} +{frame.get("imageOffset")} {symbol} {location}')
    app = next((i for i in images if i.get("name") == "ThreeDays"), None)
    if app:
        print("  app image uuid:", app.get("uuid"), "base:", app.get("base"))


def summarize_text(text):
    lines = text.splitlines()
    keep = [l for l in lines if l.startswith(("Exception Type", "Exception Codes", "Exception Reason", "Termination Reason",
                                               "Triggered by Thread", "Crashed Thread", "Version", "OS Version", "Hardware Model"))]
    print("\n".join("  " + l for l in keep))
    for i, line in enumerate(lines):
        if line.startswith("Last Exception Backtrace"):
            print("\n".join("    " + l for l in lines[i:i + 45]))
            break
    for i, line in enumerate(lines):
        if "Crashed:" in line:
            print("\n".join("    " + l for l in lines[i:i + 40]))
            break


def main():
    apps = get("/v1/apps", {"filter[bundleId]": BUNDLE_ID})
    if not apps or not apps["data"]:
        sys.exit("App not found")
    app_id = apps["data"][0]["id"]
    submissions = get(f"/v1/apps/{app_id}/betaFeedbackCrashSubmissions", {"limit": "10", "sort": "-createdDate"})
    if not submissions:
        sys.exit(1)
    print(f"{len(submissions['data'])} crash submissions")
    for item in submissions["data"]:
        a = item["attributes"]
        print("\n==", a.get("createdDate"), a.get("deviceModel"), a.get("osVersion"), a.get("appPlatform"),
              "build", a.get("buildBundleId"), a.get("deviceFamily"))
        log = get(f"/v1/betaFeedbackCrashSubmissions/{item['id']}/crashLog")
        text = (log or {}).get("data", {}).get("attributes", {}).get("logText") or ""
        if not text:
            print("  (no crash log)")
            continue
        try:
            summarize_ips(text)
        except (ValueError, KeyError, TypeError):
            summarize_text(text)


if __name__ == "__main__":
    main()
