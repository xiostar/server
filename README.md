# Server

Einrichtung und automatisches Deployment für den VPS (Ubuntu/Debian).

```
Du pushst Code ──► GitHub ──► GitHub Actions ──SSH──► Server
                                                        │
                                   Server zieht neuen Stand von GitHub (git fetch)
                                   und startet die App neu (docker compose up --build)
```

- **Docker** startet jede App in einem eigenen Container.
- **Caddy** nimmt alle Anfragen an und holt automatisch HTTPS-Zertifikate (Let's Encrypt).
- Jede App ist unter einem Pfad erreichbar: `https://DOMAIN/getraenkeliste/`, `https://DOMAIN/spesenabrechnung/` usw.
- Der Server holt sich den Code mit **Lese-Schlüsseln** (Deploy-Keys) von GitHub. Er kann also nichts in die Repos schreiben.
- GitHub Actions darf auf dem Server **nur** den Befehl `deploy <app>` ausführen, keine Shell (`bin/ssh-gate`).

## Einmalige Einrichtung

**Voraussetzung:** Ein frischer Server mit **Ubuntu 24.04 LTS** (Debian 12 geht auch), auf den du per `ssh root@IP` kommst.
Die Domain ist **nicht** nötig: Ohne Domain läuft alles erst einmal per `http://SERVER-IP/`. HTTPS kommt später dazu (siehe unten).

1. Dieses Repo auf deinen Rechner holen (oder `setup.sh` auf GitHub öffnen, „Download raw file“).
2. Skript auf den Server kopieren und starten:
   ```bash
   scp setup.sh root@DEINE-SERVER-IP:
   ssh root@DEINE-SERVER-IP
   bash setup.sh
   ```
3. Das Skript fragt nach der Domain (leer lassen, solange sie noch nicht freigeschaltet ist) und zeigt dann nacheinander **Schlüssel** an:
   - einen für dieses Repo (`xiostar/server`)
   - je einen für jedes App-Repo

   Jeden Schlüssel im jeweiligen Repo unter **Settings → Deploy keys → Add deploy key** eintragen. **Kein** Schreibzugriff anhaken. (Das Skript zeigt dir den direkten Link.)
4. Am Ende gibt das Skript drei **Secrets** aus: `DEPLOY_HOST`, `DEPLOY_KNOWN_HOSTS`, `DEPLOY_SSH_KEY`. Diese in **jedem** Repo (server und alle Apps) unter **Settings → Secrets and variables → Actions** anlegen.
5. Den Schlüssel `/root/github-actions-deploy-key` auf dem Server löschen, sobald die Secrets eingetragen sind.
6. Im Browser `http://SERVER-IP` öffnen (bzw. `https://DEINE-DOMAIN`): Dort steht „Server läuft“.

Ab jetzt wird jede App automatisch ausgerollt, sobald etwas auf ihren `main`-Branch gepusht wird. Den Verlauf siehst du im Repo unter **Actions**.

## Domain später aktivieren (HTTPS)

1. Beim Domain-Anbieter einen **A-Record** anlegen: Name `@`, Wert = IP des Servers. Warten, bis er aktiv ist (prüfen z.B. auf dnschecker.org).
2. Auf dem Server:
   ```bash
   sudo -u deploy /srv/server/bin/set-domain meinedomain.de
   ```
   Caddy holt das Zertifikat automatisch. Ab dann sind die Apps unter `https://meinedomain.de/<app>/` erreichbar.
   Die GitHub-Secrets bleiben unverändert, denn GitHub verbindet sich immer über die IP.

## Wie eine App aussehen muss

Jedes App-Repo braucht drei Dinge (Vorlage im Ordner [`app-vorlage/`](app-vorlage/)):

| Datei | Zweck |
|---|---|
| `compose.yaml` | Container heißt wie die App, hängt im Netzwerk `web`, Daten unter `/data` |
| `Dockerfile` | Baut die App. Sie muss im Container auf **Port 8080** lauschen und unter `/<app-name>/` antworten (Umgebungsvariable `BASE_PATH`) |
| `.github/workflows/deploy.yml` | Löst nach jedem Push das Deployment aus |

Dauerhafte Daten (z.B. eine SQLite-Datenbank) gehören nach `/data` im Container. Auf dem Server liegen sie unter `/srv/data/<app-name>` und überleben jedes Update.

## Neue App hinzufügen

1. Zeile in [`apps.conf`](apps.conf) ergänzen und einen Block in [`caddy/Caddyfile`](caddy/Caddyfile) kopieren. Pushen, dann lädt der Server Caddy automatisch neu.
2. Auf dem Server: `sudo -u deploy /srv/server/bin/add-app <name>` und den angezeigten Schlüssel im neuen Repo als Deploy-Key eintragen.
3. Im neuen Repo die Dateien aus `app-vorlage/` anlegen (`__APP__` durch den Namen ersetzen) und die drei Secrets eintragen.

## Nützliche Befehle auf dem Server

```bash
sudo -u deploy /srv/server/bin/deploy getraenkeliste   # App von Hand aktualisieren
docker ps                                              # Was läuft?
docker logs -f getraenkeliste                          # Logs einer App
docker logs -f caddy                                   # Logs des Proxys (z.B. Zertifikatsprobleme)
```

## Aufbau auf dem Server

```
/srv/server        dieses Repo (Caddy-Konfiguration, Skripte), .env mit der Domain (falls gesetzt)
/srv/apps/<name>   Klon des jeweiligen App-Repos
/srv/data/<name>   dauerhafte Daten der App
/home/deploy/.ssh  Lese-Schlüssel für GitHub, Zugang für GitHub Actions
```
