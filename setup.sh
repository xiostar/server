#!/usr/bin/env bash
# Einrichtung eines Ubuntu/Debian-Servers. Kann gefahrlos mehrfach ausgeführt werden,
# auch auf einem bereits eingerichteten Server (aktualisiert dann nur, was fehlt).
#
#   curl -fsSL https://raw.githubusercontent.com/xiostar/server/main/setup.sh -o setup.sh && sudo bash setup.sh
#
# Danach: Code auf GitHub pushen. Der Server schaut jede Minute nach neuen Commits
# auf "main", holt sie und startet die betroffene App neu. Keine Schlüssel oder
# Secrets pro Repo nötig, nur einmal ein GitHub-Token mit Lesezugriff.
set -euo pipefail

SERVER_REPO="${SERVER_REPO:-xiostar/server}"
DEPLOY_USER=deploy

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ask() { local v; read -r -p "$1" v </dev/tty; printf '%s' "$v"; }
ask_secret() { local v; read -r -s -p "$1" v </dev/tty; echo >/dev/tty; printf '%s' "$v"; }

[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen: sudo bash setup.sh"; exit 1; }
. /etc/os-release
[[ "$ID" == ubuntu || "$ID" == debian || "${ID_LIKE:-}" == *debian* ]] || { echo "Nur Ubuntu/Debian unterstützt"; exit 1; }

# ---------------------------------------------------------------- Eingaben
FIRST_RUN=1
if [[ -f /srv/server/.env ]]; then
	FIRST_RUN=0
	# shellcheck disable=SC1091
	. /srv/server/.env
fi
if [[ $FIRST_RUN -eq 1 ]]; then
	DOMAIN="$(ask 'Domain, die schon auf diesen Server zeigt (leer lassen = erstmal nur per IP): ')"
fi
SERVER_IP="$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')"

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

# Alter Zugang für GitHub Actions (frühere Version dieses Setups) wird nicht mehr gebraucht
if [[ -f "$DH/.ssh/authorized_keys" ]]; then sed -i '/ssh-gate/d' "$DH/.ssh/authorized_keys"; fi
rm -f /root/github-actions-deploy-key /root/github-actions-deploy-key.pub

# ---------------------------------------------------------------- Server-Repo (öffentlich)
if [[ ! -d /srv/server/.git ]]; then
	rm -rf /srv/server
	install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" /srv/server
	as_deploy git clone -q -b main "https://github.com/$SERVER_REPO.git" /srv/server
else
	as_deploy git -C /srv/server remote set-url origin "https://github.com/$SERVER_REPO.git"
	as_deploy git -C /srv/server fetch -q origin main
	as_deploy git -C /srv/server reset -q --hard origin/main
fi
chmod +x /srv/server/bin/*

if [[ $FIRST_RUN -eq 1 ]]; then
	if [[ -n "${DOMAIN:-}" ]]; then printf 'DOMAIN=%s\n' "$DOMAIN"; else printf '# DOMAIN=meinedomain.de\n'; fi >/srv/server/.env
	chown "$DEPLOY_USER:$DEPLOY_USER" /srv/server/.env
	chmod 600 /srv/server/.env
fi

# ---------------------------------------------------------------- GitHub-Token (einmalig für alle Repos)
CRED="$DH/.git-credentials"
as_deploy git config --global credential.helper store
first_private="$(awk '!/^#/ && NF >= 2 { print $2; exit }' /srv/server/apps.conf)"
token_ok() { as_deploy env GIT_TERMINAL_PROMPT=0 git ls-remote -q "https://github.com/$first_private.git" HEAD >/dev/null 2>&1; }
if ! token_ok; then
	say "GitHub-Token (Lesezugriff auf deine Repos)"
	cat <<'EOF'
Der Server braucht EINEN Token, um deine privaten Repos lesen zu können.
So legst du ihn an (dauert 1 Minute):
  1. https://github.com/settings/personal-access-tokens/new öffnen
  2. Token name: server   |   Expiration: so lang wie möglich
  3. Repository access: "All repositories"
  4. Permissions -> Repository permissions -> Contents: "Read-only"
  5. "Generate token" und den Token (beginnt mit github_pat_) kopieren
Die Eingabe ist unsichtbar. Einfügen mit Rechtsklick, dann Enter.
EOF
	until token_ok; do
		token="$(ask_secret 'Token: ')"
		token="$(printf '%s' "$token" | tr -d '[:space:]')"
		[[ -n "$token" ]] || continue
		printf 'https://x-access-token:%s@github.com\n' "$token" >"$CRED"
		chown "$DEPLOY_USER:$DEPLOY_USER" "$CRED"
		chmod 600 "$CRED"
		token_ok || echo "Damit klappt der Zugriff auf $first_private nicht. Bitte prüfen und noch einmal einfügen."
	done
	unset token
	echo "Token funktioniert."
fi

# ---------------------------------------------------------------- Caddy starten
say "Reverse-Proxy (Caddy, automatisches HTTPS) starten"
docker network inspect web >/dev/null 2>&1 || docker network create web
as_deploy /srv/server/bin/gen-caddy
(cd /srv/server && as_deploy docker compose up -d --remove-orphans)
docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true

# ---------------------------------------------------------------- Automatische Updates
say "Automatische Updates einrichten (jede Minute nach neuen Commits schauen)"
cat >/etc/systemd/system/app-poll.service <<EOF
[Unit]
Description=Neue Commits von GitHub holen und Apps aktualisieren
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$DEPLOY_USER
ExecStart=/srv/server/bin/poll
TimeoutStartSec=30min
EOF
cat >/etc/systemd/system/app-poll.timer <<'EOF'
[Unit]
Description=Jede Minute nach neuen Commits schauen

[Timer]
OnBootSec=1min
OnUnitInactiveSec=1min

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now app-poll.timer
systemctl start app-poll.service --no-block

URL="$(if [[ -n "${DOMAIN:-}" ]]; then echo "https://$DOMAIN"; else echo "http://$SERVER_IP"; fi)"
say "Fertig!"
cat <<EOF
Im Browser:            $URL
Was passiert gerade:   journalctl -u app-poll -f
Domain aktivieren:     sudo -u $DEPLOY_USER /srv/server/bin/set-domain meinedomain.de
Sofort aktualisieren:  sudo -u $DEPLOY_USER /srv/server/bin/deploy <app-name>

Neue App: eine Zeile in apps.conf (Repo xiostar/server) – der Rest passiert automatisch.
EOF
