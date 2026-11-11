#!/usr/bin/env bash
# Gemeinsame Anmeldung an der App Store Connect API (wird von testflight.sh und testflight-status.sh eingebunden).
# Der private Schlüssel bleibt in ~/.appstoreconnect/private_keys und wird nie ausgegeben.
#   asc_load   setzt ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (Rückgabe 1, wenn nicht eingerichtet)
#   asc_token  gibt ein 15 Minuten gültiges JWT aus

asc_load() {
  if [ -f signing.env ]; then set -a; . ./signing.env; set +a; fi
  local dir="$HOME/.appstoreconnect/private_keys"
  if [ -z "${ASC_KEY_ID:-}" ]; then
    local keys=()
    while IFS= read -r f; do keys+=("$f"); done < <(ls "$dir"/AuthKey_*.p8 2>/dev/null)
    if [ "${#keys[@]}" -eq 1 ]; then
      ASC_KEY_ID="$(basename "${keys[0]}" .p8)"; ASC_KEY_ID="${ASC_KEY_ID#AuthKey_}"
    elif [ "${#keys[@]}" -gt 1 ]; then
      echo "Mehrere API-Schlüssel in $dir – ASC_KEY_ID in signing.env festlegen." >&2; return 1
    else
      echo "Kein API-Schlüssel in $dir (AuthKey_<ID>.p8)." >&2; return 1
    fi
  fi
  ASC_KEY_PATH="$dir/AuthKey_$ASC_KEY_ID.p8"
  [ -f "$ASC_KEY_PATH" ] || { echo "API-Schlüssel fehlt: $ASC_KEY_PATH" >&2; return 1; }
  [ -n "${ASC_ISSUER_ID:-}" ] || { echo "ASC_ISSUER_ID fehlt in signing.env." >&2; return 1; }
  export ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH
}

asc_token() {
  python3 - <<'PY'
import base64, json, os, subprocess, time

def b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

now = int(time.time())
header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
claims = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
signing_input = (b64(json.dumps(header, separators=(",", ":")).encode()) + "." +
                 b64(json.dumps(claims, separators=(",", ":")).encode())).encode()
der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_PATH"]],
                     input=signing_input, capture_output=True, check=True).stdout

# DER-Signatur (SEQUENCE aus zwei INTEGERn) in das von JWT verlangte r||s mit je 32 Byte umwandeln
def read_len(buf, pos):
    n = buf[pos]; pos += 1
    if n & 0x80:
        count = n & 0x7F
        n = int.from_bytes(buf[pos:pos + count], "big"); pos += count
    return n, pos

assert der[0] == 0x30
_, pos = read_len(der, 1)
parts = []
for _ in range(2):
    assert der[pos] == 0x02
    n, pos = read_len(der, pos + 1)
    parts.append(int.from_bytes(der[pos:pos + n], "big").to_bytes(32, "big")); pos += n
print(signing_input.decode() + "." + b64(parts[0] + parts[1]))
PY
}
