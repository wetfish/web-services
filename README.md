# 🌊🐠 Web-Services Production Manifests

> Docker Compose-based service orchestration for [Wetfish](https://wetfish.net) using [Traefik](https://doc.traefik.io/traefik/) + [Watchtower](https://containrrr.dev/watchtower/). Built for zero-downtime container updates and wildcard TLS with Cloudflare.

---

## ⚙️ Tech Stack

- **Reverse Proxy:** Traefik v2
- **Auto Updates:** Watchtower
- **Let's Encrypt w/ Cloudflare DNS API**
- **Containerized Services:** docker + compose
- **Persistent Volumes:** local bind mount & NFS

🔗 Useful Docs:
- [Watchtower](https://containrrr.dev/watchtower/)
- [Traefik](https://doc.traefik.io/traefik/)
- [Cloudflare Certbot Automation](https://labzilla.io/blog/cloudflare-certbot)

---

## 🌐 Included Services

- `online` — wetfish forums
- `wiki` — community meme shitposting and updates
- `danger` — do sketchy things with javascript
- `click` — click
- `wetfish` — main website

To add or remove services see .gitmodules in root of dir

---

## 🔥 Quickstart (Debian-based)

Run this to install everything automatically:
```bash
curl -fsSL https://raw.githubusercontent.com/cybaxx/web-services-cybaxx/refs/heads/main/util/wetfish-installer.sh | sudo bash
```

## I don't trust curl pipe to bash
Fine set it up yourself, install docker and the docker compose plugin as a dependency, see script provided above for any additional deps.

```bash
# install docker and docker-compose-plugin
# https://docs.docker.com/engine/install/debian/

# create traefik backend network
docker network create traefik-backend

# clone the repo (recursively)
cd /opt

export REPO_DIR="$(cd "/opt" || exit 1; pwd)/web-services"

git clone \
  --branch $BRANCH \
  --single-branch \
  --recursive \
  --recurse-submodules \
  https://github.com/wetfish/web-services.git \
  $REPO_DIR

# fix various permissions
cd $REPO_DIR && bash ./fix-subproject-permissions.sh

# recommended: start just traefik, give it a minute to acquire certs (or error out)
cd traefik && docker compose up -d

# start all the stacks at once
cd $REPO_DIR && bash ./init-servivces.sh && ./all-services up
```

## Where is persistent data stored?

```bash
# blog: posts
/opt/web-services/$ENV/services/blog/config.js

# danger: database
/opt/web-services/$ENV/services/danger/db

# wetfishonline: database, fish/equpipment
/opt/web-services/$ENV/services/online/db
services/online/storage

# wiki: database, user uploads
/opt/web-services/$ENV/services/wiki/db
/opt/web-services/$ENV/services/wiki/upload # mounted over nfs to storage server

# Prod Bind Mount
root@wetfish:/mnt/wetfish# ls
backups  wiki
```

## Post install 
To get routers and web services working with SSL certs:
in /opt/web-services/$ENV/treafik find traefik.env and replace the API token with a valid token generated with cloudflair

## Map
```bash
root@wetfish:/opt/web-services-cybaxx# tree -L 3
.
├── migrate.sh
├── prod
│   ├── all-services.sh
│   ├── fix-subproject-permissions.sh
│   ├── init-backup-migrations.sh
│   ├── init-services.sh
│   ├── services
│   │   ├── blog
│   │   ├── click
│   │   ├── danger
│   │   ├── glitch
│   │   ├── home
│   │   ├── online
│   │   └── wiki
│   └── traefik
│       ├── acme
│       ├── conf
│       ├── docker-compose.yml
│       ├── logs
│       ├── traefik.env
│       └── traefik.env.example
├── README.md
├── stage
│   ├── all-services.sh
│   ├── fix-subproject-permissions.sh
│   ├── init-services.sh
│   ├── services
│   │   ├── home-staging
│   │   ├── online-staging
│   │   └── wiki-staging
│   └── traefik
│       ├── acme
│       ├── conf
│       ├── docker-compose.staging.yml
│       ├── docker-compose.yml
│       ├── logs
│       └── traefik.env.example
└── util
    ├── pack-backups.sh
    └── unpack-backups.sh
```
If the network is broken its %100 ur traefik or cloudflair dns please see above
