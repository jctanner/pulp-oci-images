#!/usr/bin/env bash
# coding=utf-8
set -euo pipefail

SERVER="pulp"
WEB_PORT=8080
scheme=${1:-http}

BASE_ADDR="$scheme://$SERVER:$WEB_PORT"
echo "Base Address: $BASE_ADDR"

grep "127.0.0.1   pulp" /etc/hosts || echo "127.0.0.1   pulp" | sudo tee -a /etc/hosts

echo "Installing Pulp-CLI"
if [ -d pulp-cli ]; then
  cd pulp-cli
  git fetch origin
  git reset --hard origin/main
else
  git clone --depth=1 https://github.com/pulp/pulp-cli.git
  cd pulp-cli
fi
pip install -r test_requirements.txt || pip install --no-build-isolation -r test_requirements.txt
if [ -e tests/cli.toml ]; then
  mv tests/cli.toml "tests/cli.toml.bak.$(date -R)"
fi
pulp config create --base-url $BASE_ADDR --username "admin" --password "password" --no-verify-ssl --location tests/cli.toml

if [[ "$scheme" == "https" ]];then
  podman cp pulp:/etc/pulp/certs/pulp_webserver.crt /tmp/pulp_webserver.crt
  sudo cp /tmp/pulp_webserver.crt /usr/local/share/ca-certificates/pulp_webserver.crt
  # Hack: adding pulp CA to certifi.where()
  CERTIFI=$(python -c 'import certifi; print(certifi.where())')
  cat /usr/local/share/ca-certificates/pulp_webserver.crt | sudo tee -a "$CERTIFI" > /dev/null
fi

echo "Setup the signing services"
# Setup key on the Pulp container
curl -L https://github.com/pulp/pulp-fixtures/raw/master/common/GPG-KEY-pulp-qe | podman exec -i pulp su pulp -c "cat > /tmp/GPG-KEY-pulp-qe"
curl -L https://github.com/pulp/pulp-fixtures/raw/master/common/GPG-PRIVATE-KEY-pulp-qe | podman exec -i pulp su pulp -c "gpg --import"
echo "6EDF301256480B9B801EBA3D05A5E6DA269D9D98:6:" | podman exec -i pulp gpg --import-ownertrust
# Setup key on the test machine
curl -L https://github.com/pulp/pulp-fixtures/raw/master/common/GPG-KEY-pulp-qe | cat > /tmp/GPG-KEY-pulp-qe
curl -L https://github.com/pulp/pulp-fixtures/raw/master/common/GPG-PRIVATE-KEY-pulp-qe | gpg --import
echo "6EDF301256480B9B801EBA3D05A5E6DA269D9D98:6:" | gpg --import-ownertrust
echo "Setup ansible signing service"
podman exec -u pulp -i pulp bash -c "cat > /var/lib/pulp/scripts/sign_detached.sh" < "${PWD}/tests/assets/sign_detached.sh"
podman exec -u pulp pulp chmod a+rx /var/lib/pulp/scripts/sign_detached.sh
podman exec -u pulp pulp bash -c "pulpcore-manager add-signing-service --class core:AsciiArmoredDetachedSigningService sign_ansible /var/lib/pulp/scripts/sign_detached.sh 'Pulp QE'"
echo "Setup deb release signing service"
podman exec -u pulp -i pulp bash -c "cat > /var/lib/pulp/scripts/sign_deb_release.sh" < "${PWD}/tests/assets/sign_deb_release.sh"
podman exec -u pulp pulp chmod a+rx /var/lib/pulp/scripts/sign_deb_release.sh
podman exec -u pulp pulp bash -c "pulpcore-manager add-signing-service --class deb:AptReleaseSigningService sign_deb_release /var/lib/pulp/scripts/sign_deb_release.sh 'Pulp QE'"

echo "Run all CLI tests"
make test