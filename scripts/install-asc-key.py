import os, re, base64, sys
raw = os.environ.get("ASC_KEY_P8", "")
path = os.environ["KEY_PATH"]
s = raw.replace("\\n", "\n").replace("\r", "")
for a, b in {"\u2014": "--", "\u2013": "-", "\u2010": "-", "\u2011": "-", "\u2212": "-", "\u00a0": " ", "\u200b": ""}.items():
    s = s.replace(a, b)
pat = r"BEGIN[ _]+PRIVATE[ _]+KEY-*(.*?)-*\s*END[ _]+PRIVATE[ _]+KEY"
m = re.search(pat, s, re.S)
how = "pem"
if m:
    body = m.group(1)
else:
    body = s
    how = "body-only"
    try:
        dec = base64.b64decode(re.sub(r"[^A-Za-z0-9+/=]", "", s) + "===")
        m2 = re.search(pat.encode(), dec, re.S)
        if m2:
            body, how = m2.group(1).decode(), "base64-of-pem"
    except Exception:
        pass
body = re.sub(r"[^A-Za-z0-9+/=]", "", body)
try:
    der = base64.b64decode(body + "=" * (-len(body) % 4))
except Exception:
    der = b""
print(f"ASC_KEY_P8 diagnostics: chars={len(raw)} lines={raw.count(chr(10))+1} has_BEGIN={'BEGIN' in raw} format={how} der_bytes={len(der)} der_starts_with_SEQUENCE={der[:1]==b'0'}")
if len(der) < 100 or der[:1] != b"0":
    print("::error title=Bad ASC_KEY_P8::Secret does not contain a usable private key (expected the contents of AuthKey_XXXX.p8).")
    sys.exit(1)
b64 = base64.b64encode(der).decode()
with open(path, "w") as f:
    f.write("-----BEGIN PRIVATE KEY-----\n" + "\n".join(b64[i:i+64] for i in range(0, len(b64), 64)) + "\n-----END PRIVATE KEY-----\n")
