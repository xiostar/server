# Server

Einrichtung und automatisches Deployment für den VPS (Ubuntu/Debian).

```
Du pushst Code auf main ──► GitHub
                              ▲
        Server schaut jede Minute nach (bin/poll)
        und rollt neue Commits aus (bin/deploy: git pull + docker compose up --build)
```

- **Docker** startet jede App in einem eigenen Container.
- **Caddy** nimmt alle Anfragen an und holt automatisch HTTPS-Zertifikate (Let's Encrypt).
- Jede App ist unter einem Pfad erreichbar: `/dart-karriere/`, `/getraenkeliste/` usw.
- Der Server liest deine privaten Repos mit **einem** GitHub-Token (nur Lesezugriff). Keine Schlüssel oder Secrets pro Repo.

## Einrichtung (einmalig)

**Voraussetzung:** Ubuntu 24.04 LTS (Debian 12 geht auch), Zugang per SSH mit einem Benutzer, der `sudo` darf.

```bash
curl -fsSL https://raw.githubusercontent.com/xiostar/server/main/setup.sh -o setup.sh && sudo bash setup.sh
```

Das Skript fragt nach der Domain (leer lassen = erst einmal per IP) und nach einem **GitHub-Token**:

1. https://github.com/settings/personal-access-tokens/new
2. Name `server`, Ablauf so lang wie möglich
3. Repository access: **All repositories**
4. Repository permissions → **Contents: Read-only**
5. Token kopieren und im Skript einfügen

Das Skript kann jederzeit erneut ausgeführt werden, zum Beispiel um einen abgelaufenen Token zu ersetzen: vorher `sudo rm /home/deploy/.git-credentials`.

## Neue App hinzufügen

1. In [`apps.conf`](apps.conf) eine Zeile ergänzen: `name  xiostar/repo  Titel`
2. Pushen. Innerhalb einer Minute richtet der Server die Proxy-Regel und den Link auf der Startseite ein und startet die App.

Sonst ist nichts nötig. Wie eine App aufgebaut sein muss, zeigt der Ordner [`app-vorlage/`](app-vorlage/):

| Datei | Zweck |
|---|---|
| `compose.yaml` | Container heißt wie die App, hängt im Netzwerk `web`, Daten unter `/data` |
| `Dockerfile` | Die App lauscht im Container auf **Port 8080** und antwortet unter `/<name>/` (Umgebungsvariable `BASE_PATH`) |

Dauerhafte Daten (z.B. eine SQLite-Datenbank) gehören nach `/data` im Container. Auf dem Server liegen sie unter `/srv/data/<name>` und überleben jedes Update.

## Domain aktivieren (HTTPS)

1. Beim Domain-Anbieter einen **A-Record** anlegen: Name `@`, Wert = IP des Servers.
2. Auf dem Server: `sudo -u deploy /srv/server/bin/set-domain meinedomain.de`

## Eigene Adresse für eine App (Subdomain)

Beispiel: `oche-legacy.casiotc.eu` führt direkt zu Dart-Karriere.

1. Beim Domain-Anbieter für die Subdomain einen **A-Record** auf die Server-IP setzen.
2. In [`domains.conf`](domains.conf) eine Zeile ergänzen: `adresse  app-name` und pushen.
3. Innerhalb einer Minute richtet der Server die Adresse ein, Caddy holt das HTTPS-Zertifikat selbst.

Die bisherige Adresse `/<name>/` funktioniert weiterhin. Steht statt des App-Namens ein `-`, zeigt die Adresse nur eine leere Seite (z. B. für die Hauptdomain).

## Geheime Einstellungen einer App

Eine Datei `.env` im App-Ordner auf dem Server wird beim Start gelesen und nie zu GitHub hochgeladen, z. B. der Einladungscode für Dart-Karriere:

```bash
echo 'INVITE_CODE=MEINCODE' | sudo -u deploy tee /srv/apps/dart-karriere/.env
sudo -u deploy /srv/server/bin/deploy dart-karriere
```

## Nützliche Befehle auf dem Server

```bash
journalctl -u app-poll -f                              # Was rollt der Server gerade aus?
sudo -u deploy /srv/server/bin/deploy dart-karriere    # Sofort aktualisieren, ohne zu warten
docker ps                                              # Was läuft?
docker logs -f dart-karriere                           # Logs einer App
docker logs -f caddy                                   # Logs des Proxys (z.B. Zertifikate)
```

Schlägt der Build einer App fehl, steht das im Log, und der Server versucht diesen Commit nicht erneut. Der nächste Push löst einen neuen Versuch aus, ebenso `bin/deploy <name>` von Hand.

## Aufbau auf dem Server

```
/srv/server              dieses Repo, .env mit der Domain
/srv/apps/<name>         Klon des jeweiligen App-Repos
/srv/apps/.state/        welcher Commit läuft bzw. fehlgeschlagen ist
/srv/data/<name>         dauerhafte Daten der App
/home/deploy/.git-credentials   GitHub-Token (nur Lesezugriff)
app-poll.timer           systemd-Timer, startet jede Minute bin/poll
```
