#!/bin/bash
# Makes the app's self-signed code-signing certificate, so every release is signed the
# same way and macOS keeps its Camera and Accessibility permissions across updates.
#   scripts/make-signing-cert.sh <out-dir> [days]
# Writes <out-dir>/signing.p12, <out-dir>/signing.pass and <out-dir>/signing.pem.
# An explicit config with nothing implicit: some OpenSSL builds otherwise add a second,
# conflicting "Basic Constraints" from their default config, which macOS rejects.
set -euo pipefail
OUT="$1"; DAYS="${2:-7300}"
mkdir -p "$OUT" && chmod 700 "$OUT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Lip Dictation Self-Signed
O = Lip Dictation
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
PASS="$(openssl rand -hex 24)"
openssl req -x509 -newkey rsa:3072 -sha256 -days "$DAYS" -nodes -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$OUT/signing.pem" 2>/dev/null
# macOS's importer wants the older p12 encryption
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$OUT/signing.pem" -name "Lip Dictation Self-Signed" \
  -out "$OUT/signing.p12" -passout "pass:$PASS" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null \
  || openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$OUT/signing.pem" -name "Lip Dictation Self-Signed" \
       -out "$OUT/signing.p12" -passout "pass:$PASS"
printf '%s' "$PASS" > "$OUT/signing.pass"
chmod 600 "$OUT"/signing.*
openssl x509 -in "$OUT/signing.pem" -noout -fingerprint -sha1
