#!/usr/bin/env bash
# Einmalige Einrichtung eines frischen Ubuntu/Debian-Servers.
#
#   scp setup.sh root@DEINE-SERVER-IP:
#   ssh root@DEINE-SERVER-IP
#   bash setup.sh
#
# Danach: Code wird auf GitHub gepusht -> GitHub Actions meldet sich per SSH beim
# Server -> der Server zieht den neuen Stand von GitHub und startet die App neu.
#
# Das Skript kann gefahrlos mehrfach ausgeführt werden.
set -euo pipefail

SERVER_REPO="${SERVER_REPO:-xiostar/server}"
DEPLOY_USER=deploy

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ask()  { local v; read -r -p "$1" v </dev/tty; printf '%s' "$v"; }
pause(){ read -r -p "$1 [Enter] " _ </dev/tty; }

[[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen (sudo bash setup.sh)"; exit 1; }
. /etc/os-release
[[ "$ID" == ubuntu || "$ID" == debian || "${ID_LIKE:-}" == *debian* ]] || { echo "Nur Ubuntu/Debian unterstützt"; exit 1; }

# ---------------------------------------------------------------- Eingaben
if [[ -f /srv/server/.env ]]; then
	# shellcheck disable=SC1091
	. /srv/server/.env
fi
if [[ -z "${DOMAIN:-}" ]]; then
	DOMAIN="$(ask 'Domain, die schon auf diesen Server zeigt (leer lassen = erstmal nur per IP): ')"
fi
SERVER_IP="$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')"
[[ -n "$SERVER_IP" ]] || SERVER_IP="$(ask 'Öffentliche IP-Adresse dieses Servers: ')"

# ---------------------------------------------------------------- Pakete
say "System aktualisieren und Grundpakete installieren"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -yq
apt-get install -yq ca-certificates curl git ufw fail2ban unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

if ! command -v docker >/dev/null; then
	say "Docker installieren"
	curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

# ---------------------------------------------------------------- Firewall
say "Firewall: nur SSH, HTTP und HTTPS erlauben"
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

# ---------------------------------------------------------------- Benutzer
say "Benutzer '$DEPLOY_USER' und Ordner /srv anlegen"
id "$DEPLOY_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$DEPLOY_USER"
usermod -aG docker "$DEPLOY_USER"
mkdir -p /srv/apps /srv/data
chown "$DEPLOY_USER:$DEPLOY_USER" /srv/apps /srv/data
DH="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
as_deploy() { sudo -u "$DEPLOY_USER" -H "$@"; }

as_deploy mkdir -p "$DH/.ssh"
chmod 700 "$DH/.ssh"
as_deploy touch "$DH/.ssh/known_hosts" "$DH/.ssh/config" "$DH/.ssh/authorized_keys"
chmod 600 "$DH/.ssh/config" "$DH/.ssh/authorized_keys"
if ! grep -q '^github.com ' "$DH/.ssh/known_hosts"; then
	ssh-keyscan -t ed25519,rsa github.com 2>/dev/null | as_deploy tee -a "$DH/.ssh/known_hosts" >/dev/null
fi

# ---------------------------------------------------------------- Server-Repo
if [[ ! -d /srv/server/.git ]]; then
	say "Lese-Schlüssel für $SERVER_REPO"
	KEY="$DH/.ssh/github-server"
	[[ -f "$KEY" ]] || as_deploy ssh-keygen -q -t ed25519 -N "" -C "deploy@$(hostname) $SERVER_REPO" -f "$KEY"
	if ! grep -q '^Host github-server$' "$DH/.ssh/config"; then
		printf '\nHost github-server\n\tHostName github.com\n\tUser git\n\tIdentityFile %s\n\tIdentitiesOnly yes\n' "$KEY" >>"$DH/.ssh/config"
	fi
	echo "Diesen Schlüssel in GitHub eintragen:"
	echo "  https://github.com/$SERVER_REPO/settings/keys/new  (Titel: server, KEIN Schreibzugriff)"
	echo
	cat "$KEY.pub"
	echo
	rm -rf /srv/server
	install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" /srv/server
	until as_deploy git clone -q -b main "git@github-server:$SERVER_REPO.git" /srv/server; do
		pause "Noch kein Zugriff auf $SERVER_REPO. Schlüssel eingetragen?"
	done
fi
chmod +x /srv/server/bin/*

if [[ -n "$DOMAIN" ]]; then printf 'DOMAIN=%s\n' "$DOMAIN"; else printf '# DOMAIN=meinedomain.de\n'; fi >/srv/server/.env
chown "$DEPLOY_USER:$DEPLOY_USER" /srv/server/.env
chmod 600 /srv/server/.env

# ---------------------------------------------------------------- Caddy starten
say "Reverse-Proxy (Caddy, automatisches HTTPS) starten"
docker network inspect web >/dev/null 2>&1 || docker network create web
(cd /srv/server && as_deploy docker compose up -d)

# ---------------------------------------------------------------- App-Schlüssel
say "Lese-Schlüssel für die App-Repos"
while read -r name _; do
	[[ -z "$name" || "$name" == \#* ]] && continue
	as_deploy /srv/server/bin/add-app "$name"
done </srv/server/apps.conf
echo
pause "Bitte jeden der Schlüssel oben im jeweiligen Repo als Deploy-Key eintragen."

# ---------------------------------------------------------------- GitHub-Actions-Zugang
CI_KEY=/root/github-actions-deploy-key
if [[ ! -f "$CI_KEY" ]]; then
	ssh-keygen -q -t ed25519 -N "" -C "github-actions-deploy" -f "$CI_KEY"
fi
if ! grep -qF "$(cut -d' ' -f2 "$CI_KEY.pub")" "$DH/.ssh/authorized_keys"; then
	echo "command=\"/srv/server/bin/ssh-gate\",restrict $(cat "$CI_KEY.pub")" >>"$DH/.ssh/authorized_keys"
fi

HOSTKEY="$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"

say "Fertig! Jetzt in JEDEM Repo (server + alle Apps) drei Secrets anlegen:"
cat <<EOF
GitHub -> Repo -> Settings -> Secrets and variables -> Actions -> New repository secret

  Name: DEPLOY_HOST
  Wert: $SERVER_IP

  Name: DEPLOY_KNOWN_HOSTS
  Wert: $SERVER_IP $HOSTKEY

  Name: DEPLOY_SSH_KEY
  Wert: (alles zwischen den Linien, inklusive BEGIN/END)
------------------------------------------------------------------
$(cat "$CI_KEY")
------------------------------------------------------------------

Danach $CI_KEY auf dem Server löschen:   rm $CI_KEY

Test im Browser:  $(if [[ -n "$DOMAIN" ]]; then echo "https://$DOMAIN"; else echo "http://$SERVER_IP"; fi)
Domain später aktivieren:  sudo -u $DEPLOY_USER /srv/server/bin/set-domain meinedomain.de
Manuelles Update: sudo -u $DEPLOY_USER /srv/server/bin/deploy <app-name>
EOF
