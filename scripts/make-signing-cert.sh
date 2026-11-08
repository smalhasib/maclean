#!/bin/sh
# Creates the self-signed code-signing certificate "Maclean Release" in your login
# Keychain, once, and trusts it for code signing. Maclean's Full Disk Access grant
# is tied to the app's code signature, so release builds are signed with this
# stable identity instead of ad hoc.
# The key is stored only in your Keychain, never in the repo.
# macOS may ask for your login Keychain password, and asks you to authenticate
# when the certificate is trusted for code signing.
set -eu

name="Maclean Release"
keychain="$HOME/Library/Keychains/login.keychain-db"

# How many identities are named exactly "$name", trusted or not. `-v` lists only
# valid (trusted) identities and would miss an untrusted copy, so count the
# "Matching identities" section, stopping at "Valid identities only" (which
# repeats the valid ones).
count="$(security find-identity -p codesigning |
    awk -v n="\"$name\"" '/Valid identities only/ { exit } index($0, n) { c++ } END { print c + 0 }')"

if [ "$count" -gt 1 ]; then
    echo "\"$name\" is in your Keychain $count times; codesign can't tell them apart." >&2
    echo "Delete the extra copies in Keychain Access, then run this again." >&2
    exit 1
fi

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT INT TERM

trust() {
    echo "Trusting \"$name\" for code signing. macOS will ask you to authenticate."
    security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$1"
}

if [ "$count" -eq 1 ]; then
    if security find-identity -v -p codesigning | grep -qF "\"$name\""; then
        echo "\"$name\" is already in your Keychain and trusted; nothing to do."
        exit 0
    fi
    # Imported earlier but never trusted: trust the existing certificate.
    security find-certificate -c "$name" -p "$keychain" > "$dir/cert.pem"
    trust "$dir/cert.pem"
    echo "Done. Check it with:"
    echo "  security find-identity -v -p codesigning"
    exit 0
fi

pass="$(/usr/bin/openssl rand -hex 16)"

cat > "$dir/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" -config "$dir/openssl.cnf"
# Legacy PKCS#12 algorithms: `security import` can't read newer encryption.
/usr/bin/openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out "$dir/maclean.p12" -name "$name" -passout "pass:$pass"

security import "$dir/maclean.p12" -k "$keychain" -T /usr/bin/codesign -P "$pass"
trust "$dir/cert.pem"

echo "Created \"$name\" (valid 10 years). Check it with:"
echo "  security find-identity -v -p codesigning"
