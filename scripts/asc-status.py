"""Print TestFlight build status for the app from the App Store Connect API.

Env: ASC_KEY_ID, ASC_ISSUER_ID, KEY_PATH (normalized .p8), BUNDLE_ID.
Prints only build/group metadata, never key material or tester emails.
"""
import json, os, sys, time, urllib.error, urllib.parse, urllib.request
import jwt  # PyJWT[crypto]

API = "https://api.appstoreconnect.apple.com"
key = open(os.environ["KEY_PATH"]).read()
token = jwt.encode(
    {"iss": os.environ["ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 900, "aud": "appstoreconnect-v1"},
    key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
)


def get(path, **params):
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        print(f"::error::GET {path} -> {e.code} {e.read()[:400]!r}")
        sys.exit(1)


bundle = os.environ["BUNDLE_ID"]
apps = get("/v1/apps", **{"filter[bundleId]": bundle})["data"]
if not apps:
    print(f"::error::No app with bundle ID {bundle}")
    sys.exit(1)
app = apps[0]
print(f"App: {app['attributes']['name']} ({bundle}) id={app['id']}")

builds = get("/v1/builds", **{
    "filter[app]": app["id"], "sort": "-uploadedDate", "limit": "15",
    "include": "buildBetaDetail,preReleaseVersion,betaGroups",
})
inc = {(i["type"], i["id"]): i for i in builds.get("included", [])}
summary = ["| Build | Version | Uploaded (UTC) | Processing | Internal | External | Expired | Groups |", "|---|---|---|---|---|---|---|---|"]
print("\nBuilds (newest first):")
for b in builds["data"]:
    a = b["attributes"]
    rel = b.get("relationships", {})
    bbd = inc.get(("buildBetaDetails", (rel.get("buildBetaDetail", {}).get("data") or {}).get("id")), {}).get("attributes", {})
    prv = inc.get(("preReleaseVersions", (rel.get("preReleaseVersion", {}).get("data") or {}).get("id")), {}).get("attributes", {})
    groups = [inc.get(("betaGroups", g["id"]), {}).get("attributes", {}).get("name", g["id"]) for g in (rel.get("betaGroups", {}).get("data") or [])]
    row = [a.get("version"), prv.get("version"), a.get("uploadedDate"), a.get("processingState"),
           bbd.get("internalBuildState"), bbd.get("externalBuildState"), a.get("expired"), ", ".join(groups) or "-"]
    print("  " + "  ".join(str(x) for x in row))
    summary.append("| " + " | ".join(str(x) for x in row) + " |")

groups = get("/v1/betaGroups", **{"filter[app]": app["id"], "limit": "20"})["data"]
print("\nBeta groups:")
summary += ["", "| Group | Internal | All builds auto | Public link |", "|---|---|---|---|"]
for g in groups:
    ga = g["attributes"]
    gb = get(f"/v1/betaGroups/{g['id']}/builds", **{"limit": "5", "fields[builds]": "version"})
    print(f"  {ga.get('name')}: internal={ga.get('isInternalGroup')} hasAccessToAllBuilds={ga.get('hasAccessToAllBuilds')} "
          f"publicLink={ga.get('publicLinkEnabled')} builds={[x['attributes'].get('version') for x in gb['data']]}")
    summary.append(f"| {ga.get('name')} | {ga.get('isInternalGroup')} | {ga.get('hasAccessToAllBuilds')} | {ga.get('publicLinkEnabled')} |")

out = os.environ.get("GITHUB_STEP_SUMMARY")
if out:
    with open(out, "a") as f:
        f.write("\n".join(summary) + "\n")
