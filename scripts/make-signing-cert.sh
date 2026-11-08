#!/bin/sh
# Creates the self-signed code-signing certificate "Maclean Release" in your login
# Keychain, once. Maclean's Full Disk Access grant is tied to the app's code
# signature, so release builds are signed with this stable identity instead of ad hoc.
# The key is stored only in your Keychain, never in the repo.
# macOS may ask for your login Keychain password.
set -eu

name="Maclean Release"

if security find-identity -v -p codesigning | grep -q "\"$name\""; then
    echo "\"$name\" is already in your Keychain; nothing to do."
    exit 0
fi

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT INT TERM
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
/usr/bin/openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" \
    -out "$dir/maclean.p12" -name "$name" -passout "pass:$pass"

security import "$dir/maclean.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -T /usr/bin/codesign -P "$pass"

echo "Created \"$name\" (valid 10 years). Check it with:"
echo "  security find-identity -v -p codesigning"
