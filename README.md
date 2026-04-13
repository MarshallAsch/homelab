# Infrastructure as Code

This is designed to provide a frictionless way to get all of my home services back up and running without needing to manually reconfigure everything. 

## Docker compose

This currently just contains the docker compose project that will start everything in a container. 

## Usage:

In order to make the [compose.yaml] file more generic, some portions of its configuration have been extracted into a `.env` file. A sample [env.template] file has been provided that includes the environment variables that need to be set. 

These environment variables (and the files for the volumes obviously) should be all that is needed to pick up all of the containers and drop them onto a new host. 

### Pre setup tasks:

1. Set up the `.env` file with all the needed variables. 
2. Update the `letsencrypt` subdomain variable with any different subdomains.
3. Update the `transmission` definition and get the correct openvpn file.
4. Start the containers
5. Edit the necessary configuration files once they are created
    - `letsencrypt` setup the reverse proxies

### Services

#### Databases
- **mariadb** - Shared MariaDB instance
- **inventory_db** - Postgres database for inventory app
- **fills_db** - MariaDB for fill-station
- **divetec_db** - MariaDB for dive-tec website
- **gitea_db** - Postgres for Gitea
- **immich_db** - Postgres with vector extensions for Immich
- **firefly_db** - MariaDB for Firefly III
- **postal_db** - MariaDB for Postal mail server
- **analytics_db** - Postgres for Umami analytics
- **unifi-db** - MongoDB for UniFi Network Application
- **openldap** - LDAP directory server
- **authelia_redis** - Redis for Authelia session storage
- **immich_redis** - Valkey for Immich caching

#### Media
- **plex** - Plex Media Server (with GPU transcoding)
- **sonarr** - TV show management
- **radarr** - Movie management
- **lidarr** - Music management
- **bookshelf** - Book and audiobook management (Readarr fork)
- **bazarr** - Subtitle management
- **prowlarr** - Indexer management
- **tautulli** - Plex monitoring and statistics
- **seerr** - Media request management
- **transmission** - Torrent client (via NordVPN)
- **unpackerr** - Automated archive extraction
- **tunarr** - Custom TV channel creation (with hardware transcoding)
- **wrapped** - Plex Wrapped/year-in-review
- **handbrake** - Video transcoding (web UI)

#### Core
- **authelia** - SSO and authentication portal
- **ldap-user-manager** - Web UI for LDAP user management
- **letsencrypt** - SWAG reverse proxy with automatic SSL
- **ddclient** - Dynamic DNS updates (Cloudflare)
- **smtp-relay** - Outbound mail relay via SES
- **backup-manager** - Automated database backups with email notifications
- **duplicati** - File backup to remote storage
- **diun** - Docker image update notifier (Discord)

#### Monitoring
- **speedtest** - Internet speed test tracker
- **peanut** - UPS monitoring (NUT web UI)

#### Home
- **homepage** - Dashboard/landing page
- **mealie** - Recipe manager (with Authelia OIDC and Ollama AI)
- **nextcloud** - File storage and collaboration
- **lubelogger** - Vehicle maintenance tracker
- **immich_server** / **immich_ml** - Photo management (with GPU-accelerated ML)
- **firefly** / **firefly_cron** / **firefly_import** - Personal finance manager
- **kavita** - E-book library and reader
- **calibre-gui** - E-book metadata management (Calibre desktop)
- **gitea** - Self-hosted Git server
- **gitea_runner** - Gitea Actions CI runner (host Docker socket)
- **solidinvoice** - Invoicing

#### Support
- **ollama** - Local LLM inference (GPU)
- **collabora** - Online document editing (LibreOffice)
- **analytics** - Umami web analytics

#### External
- **botomir** - Discord bot
- **fill-station** - Dive shop fill tracking
- **dive-tec** - Dive-Tec website
- **inventory** - Road2IR inventory system

#### Network
- **pihole** - DNS ad-blocker and local DNS
- **unifi** - UniFi Network Application

#### Mail
- **postal** / **postal_worker** / **postal_smtp** - Full mail server

#### Other
- **homeassistant** - Home automation

## Profiles

This docker compose file uses the concept of 'profiles' to allow different subsets of the containers to be started at a time.

- **default** (no profile) - All production services
- **temp** - Services that are still being tested or not fully configured (paperless, mongo_botomir, minecraft, printer)
- **test** - Experimental services (plexripper)

## Limitations

- The compose setup makes use of the macvlan networking mode which can have limitations imposed by the host machine supporting all the mac addresses in hardware, or from having too many mac addresses on one 802.11 interface. To avoid this make sure it is running with an Ethernet connection. 
- All of the containers that need direct LAN access are attached to the same macvlan network. Most inter-service communication uses internal Docker networks for isolation.
- Some of the containers still need to be manually configured prior to first use. 
- Several services (firefly, botomir, firefly_import) use additional `.env` files (`.firefly.env`, `.firefly.db.env`, `.importer.env`, `botomir.env`) beyond the main `.env` file.

## Next steps and things to add

Like all programming and IaC projects this is an ongoing learning adventure of what works best for me, what services I want to run and how it is configured. 
While there is a long list of other cool things that I would love to add to this project the following list includes the main ones:

- Store some of the secrets as docker secrets rather than environment variables
- Add other modules that can perform some of the configuration of the host, network, and DNS records that are needed
- Add modules to configure other machines that I have running (ie the raspberry pi DNS failovers and jump hosts)



[compose.yaml]: compose.yaml
[env.template]: env.template
