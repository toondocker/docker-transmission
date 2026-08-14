[![GitHub Stars](https://img.shields.io/github/stars/toondocker/docker-transmission.svg?color=94398d&labelColor=555555&logoColor=ffffff&style=for-the-badge&logo=github)](https://github.com/toondocker/docker-transmission)
[![GitHub Release](https://img.shields.io/github/release/toondocker/docker-transmission.svg?color=94398d&labelColor=555555&logoColor=ffffff&style=for-the-badge&logo=github)](https://github.com/toondocker/docker-transmission/releases)
[![GitHub Package Repository](https://img.shields.io/static/v1.svg?color=94398d&labelColor=555555&logoColor=ffffff&style=for-the-badge&label=toondocker&message=GitHub%20Package&logo=github)](https://github.com/toondocker/docker-transmission/packages)
[![GitLab Container Registry](https://img.shields.io/static/v1.svg?color=94398d&labelColor=555555&logoColor=ffffff&style=for-the-badge&label=toondocker&message=GitLab%20Registry&logo=gitlab)](https://gitlab.com/toondocker/docker-transmission/container_registry)
[![Docker Pulls](https://img.shields.io/docker/pulls/toondocker/docker-transmission.svg?color=94398d&labelColor=555555&logoColor=ffffff&style=for-the-badge&label=pulls&logo=docker)](https://hub.docker.com/r/toondocker/docker-transmission)
[![Docker Stars](https://img.shields.io/docker/stars/toondocker/docker-transmission.svg?color=94398d&labelColor=555555&logoColor=ffffff&style=for-the-badge&label=stars&logo=docker)](https://hub.docker.com/r/toondocker/docker-transmission)

[Transmission](https://www.transmissionbt.com/) is designed for easy, powerful use. Transmission has the features you want from a BitTorrent client: encryption, a web interface, peer exchange, magnet links, DHT, µTP, UPnP and NAT-PMP port forwarding, webseed support, watch directories, tracker editing, global and per-torrent speed limits, and more.

[![transmission](https://raw.githubusercontent.com/linuxserver/docker-templates/master/linuxserver.io/img/transmission.png)](https://www.transmissionbt.com/)

## Application Setup

Webui is on port 9091, the settings.json file in /config has extra settings not available in the webui. Stop the container before editing it or any changes won't be saved.

## Securing the webui with a username/password.

Use the `USER` and `PASS` variables in docker run/create/compose to set authentication. Do not manually edit the `settings.json` to input user/pass, otherwise transmission cannot be stopped cleanly by the s6 supervisor.

## Configuring Done Script

Use `DONESCRIPT` to specify a script that executes when a torrent completes downloading. The script must be executable and exist at the specified path.

Use `TARGET_DIR` to specify the container-side mount point where completed torrents will be symlinked by `DONESCRIPT`. This should match the volume mount path inside the container.

The `script-torrent-done-enabled` setting is automatically set to true only if the script file exists and is accessible. If the script path is invalid, this setting is automatically disabled.

Example with volume mount:
```
volumes:
  - /path/to/video/links:/video-links
environment:
  - DONESCRIPT=/app/symlink-videos.sh
```

## Configuring Sonarr Integration

The `symlink-videos.sh` script integrates with Sonarr to automatically organize downloaded TV episodes into a properly named directory structure using symlinks.

### Setup Requirements

1. **Sonarr running on the same Docker network** – When running Sonarr in a container on the same Docker network, use the container name as the hostname: `http://sonarr:8989`
2. **Sonarr API Key** – Generate one in Sonarr: **Settings > General > Security > API Key**
3. **Environment Variables** – Configure in `.env`:
   - `SONARR_URL` – The URL to reach Sonarr (e.g., `http://sonarr:8989` or `http://192.168.1.100:8989`)
   - `SONARR_API_KEY` – Your Sonarr API key (keep this private, never commit to GitHub)
   - `SYMLINK_ROOT` – The **container-side** directory path where the script organizes symlinked episodes (e.g., `/video-links`, `/data/video-links`)

### How It Works

When a torrent completes:
1. The done script extracts the series name and episode number from the torrent filename
2. It queries Sonarr's API for the series ID and episode metadata
3. Creates symlinks inside the container at: `SYMLINK_ROOT/Series Name/Season N/Series Name - SxxExx - Episode Title.ext`
4. These symlinks are accessible on the host via the volume mount
5. Results are cached per series to minimize API calls

### Example Configuration

`.env`:
```
SONARR_URL=http://sonarr:8989
SONARR_API_KEY=your_api_key_here
SYMLINK_ROOT=/video-links
```

`docker-compose.yml`:
```yaml
services:
  transmission:
    environment:
      - SONARR_URL=${SONARR_URL}
      - SONARR_API_KEY=${SONARR_API_KEY}
      - SYMLINK_ROOT=${SYMLINK_ROOT}
    volumes:
      - /mnt/media/video-links:/video-links  # Host path : Container path (matches SYMLINK_ROOT)
```

## Configuring Blocklist Filtering

Use `BLOCKLIST_ENABLED` to enable or disable blocklist filtering (set to `true`, `yes`, `1`, or `false`).

Use `BLOCKLIST_URL` to specify the URL to your blocklist file.

**Important:** `blocklist-enabled` is only set to true when `BLOCKLIST_URL` has a valid value. If `BLOCKLIST_URL` is empty, blocklist filtering is automatically disabled even if `BLOCKLIST_ENABLED=true`.

The automatic blocklist update will run once a day at 3am local server time.

## Using whitelist

Use `WHITELIST` to enable a list of ip as whitelist. This enable support for `rpc-whitelist`. When `WHITELIST` is empty support for whitelist is disabled.

Use `HOST_WHITELIST` to enable an list of dns names as host-whitelist. This enable support for `rpc-host-whitelist`. When `HOST_WHITELIST` is empty support for host-whitelist is disabled.

## Use alternative Transmission torrent ports

Use `PEERPORT` to specify the port(s) Transmission should listen on.  This disables random port selection.  This should be the same as the port mapped in your docker configuration.

## Custom Docker Network

Use `NETWORK_NAME` to specify a custom Docker network for container communication. This allows you to isolate the Transmission container on a unique network while still maintaining port access from the host. The network must be created before running the container: `docker network create transmission-network`

## Read-Only Operation

This image can be run with a read-only container filesystem. For details please [read the docs](https://docs.linuxserver.io/misc/read-only/).

## Non-Root Operation

This image can be run with a non-root user. For details please [read the docs](https://docs.linuxserver.io/misc/non-root/).

## Usage

To help you get started creating a container from this image you can either use docker-compose or the docker cli.

>[!NOTE]
>Unless a parameter is flagged as 'optional', it is *mandatory* and a value must be provided.

### docker-compose (recommended, [click here for more info](https://docs.linuxserver.io/general/docker-compose))

```yaml
---
services:
  transmission:
    image: yourdockerhubuser/docker-transmission:latest
    container_name: transmission
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Etc/UTC
      - TRANSMISSION_WEB_HOME= # optional
      - USER= # optional
      - PASS= # optional
      - WHITELIST= # optional
      - HOST_WHITELIST= # optional
      - PEERPORT= # optional
      - DONESCRIPT=/app/symlink-videos.sh # optional
      - TARGET_DIR=/video-links # optional
      - BLOCKLIST_ENABLED=false # optional
      - BLOCKLIST_URL= # optional
      - NETWORK_NAME=transmission-network # optional
      - SONARR_URL=http://sonarr:8989 # optional
      - SONARR_API_KEY= # optional
      - SYMLINK_ROOT=/video-links # optional
    volumes:
      - /path/to/transmission/config:/config
      - /path/to/downloads:/downloads # optional
      - /path/to/watch/folder:/watch # optional
      - /path/to/video/links:/video-links # optional
    ports:
      - 9091:9091
      - 51413:51413
      - 51413:51413/udp
    restart: unless-stopped
```

### docker cli ([click here for more info](https://docs.docker.com/engine/reference/commandline/cli/))

```bash
docker run -d \
  --name=transmission \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Etc/UTC \
  -e TRANSMISSION_WEB_HOME= \ # optional
  -e USER= \ # optional
  -e PASS= \ # optional
  -e WHITELIST= \ # optional
  -e PEERPORT= \ # optional
  -e HOST_WHITELIST= \ # optional
  -e DONESCRIPT=/app/symlink-videos.sh \ # optional
  -e TARGET_DIR=/video-links \ # optional
  -e BLOCKLIST_ENABLED=false \ # optional
  -e BLOCKLIST_URL= \ # optional
  -e NETWORK_NAME=transmission-network \ # optional
  -e SONARR_URL=http://sonarr:8989 \ # optional
  -e SONARR_API_KEY= \ # optional
  -e SYMLINK_ROOT=/video-links \ # optional
  -p 9091:9091 \
  -p 51413:51413 \
  -p 51413:51413/udp \
  -v /path/to/transmission/config:/config \
  -v /path/to/downloads:/downloads \ # optional
  -v /path/to/watch/folder:/watch \ # optional
  -v /path/to/video/links:/video-links \ # optional
  --restart unless-stopped \
  yourdockerhubuser/docker-transmission:latest
```

## Parameters

Containers are configured using parameters passed at runtime (such as those above). These parameters are separated by a colon and indicate `<external>:<internal>` respectively. For example, `-p 8080:80` would expose port `80` from inside the container to be accessible from the host's IP on port `8080` outside the container.

| Parameter | Function |
| :----: | --- |
| `-p 9091:9091` | WebUI |
| `-p 51413:51413` | Torrent Port TCP |
| `-p 51413:51413/udp` | Torrent Port UDP |
| `-e PUID=1000` | for UserID - see below for explanation |
| `-e PGID=1000` | for GroupID - see below for explanation |
| `-e TZ=Etc/UTC` | specify a timezone to use, see this [list](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones#List). |
| `-e TRANSMISSION_WEB_HOME=` | Specify the path to an alternative UI folder. |
| `-e USER=` | Specify an optional username for the interface |
| `-e PASS=` | Specify an optional password for the interface |
| `-e WHITELIST=` | Specify an optional list of comma separated ip whitelist. Fills rpc-whitelist setting. |
| `-e PEERPORT=` | Specify an optional port for torrent TCP/UDP connections. Fills peer-port setting. |
| `-e HOST_WHITELIST=` | Specify an optional list of comma separated dns name whitelist. Fills rpc-host-whitelist setting. |
| `-e DONESCRIPT=` | Script to execute when a torrent completes. Leave empty to disable. |
| `-e TARGET_DIR=` | Directory where completed torrents are symlinked by DONESCRIPT. |
| `-e BLOCKLIST_ENABLED=` | Enable blocklist filtering for peer connections (true/false). Only takes effect if BLOCKLIST_URL is set. |
| `-e BLOCKLIST_URL=` | URL to blocklist file for automatic peer filtering. Leave empty to disable blocklist. |
| `-e NETWORK_NAME=` | Custom Docker network name for container communication. |
| `-e SONARR_URL=` | URL to reach Sonarr service (e.g., http://sonarr:8989). Used by symlink-videos.sh script. |
| `-e SONARR_API_KEY=` | Sonarr API key for authentication. Required for Sonarr integration. |
| `-e SYMLINK_ROOT=` | Container-side directory path where symlinked video files will be organized by series/season. |
| `-v /config` | Where transmission should store config files and logs. |
| `-v /downloads` | Local path for downloads. |
| `-v /watch` | Watch folder for torrent files. |
| `-v /video-links` | Mount point for TARGET_DIR - where completed torrents are symlinked by DONESCRIPT. |
| `--read-only=true` | Run container with a read-only filesystem. Please [read the docs](https://docs.linuxserver.io/misc/read-only/). |
| `--user=1000:1000` | Run container with a non-root user. Please [read the docs](https://docs.linuxserver.io/misc/non-root/). |

## Environment variables from files (Docker secrets)

You can set any environment variable from a file by using a special prepend `FILE__`.

As an example:

```bash
-e FILE__MYVAR=/run/secrets/mysecretvariable
```

Will set the environment variable `MYVAR` based on the contents of the `/run/secrets/mysecretvariable` file.

## Umask for running applications

For all LSIO images they provide the ability to override the default umask settings for services started within the containers using the optional `-e UMASK=022` setting.
Keep in mind umask is not chmod it subtracts from permissions based on it's value it does not add. Please read up [here](https://en.wikipedia.org/wiki/Umask) before asking for support.

## User / Group Identifiers

When using volumes (`-v` flags), permissions issues can arise between the host OS and the container, we avoid this issue by allowing you to specify the user `PUID` and group `PGID`.

Ensure any volume directories on the host are owned by the same user you specify and any permissions issues will vanish like magic.

In this instance `PUID=1000` and `PGID=1000`, to find yours use `id your_user` as below:

```bash
id your_user
```

Example output:

```text
uid=1000(your_user) gid=1000(your_user) groups=1000(your_user)
```

## Docker Mods

[![Docker Mods](https://img.shields.io/badge/dynamic/yaml?color=94398d&labelColor=555555&logoColor=ffffff&style=for-the-badge&label=transmission&query=%24.mods%5B%27transmission%27%5D.mod_count&url=https%3A%2F%2Fraw.githubusercontent.com%2Flinuxserver%2Fdocker-mods%2Fmaster%2Fmod-list.yml)](https://mods.linuxserver.io/?mod=transmission "view available mods for this container.") [![Docker Universal Mods](https://img.shields.io/badge/dynamic/yaml?color=94398d&labelColor=555555&logoColor=ffffff&style=for-the-badge&label=universal&query=%24.mods%5B%27universal%27%5D.mod_count&url=https%3A%2F%2Fraw.githubusercontent.com%2Flinuxserver%2Fdocker-mods%2Fmaster%2Fmod-list.yml)](https://mods.linuxserver.io/?mod=universal "view available universal mods.")

LSIO publish various [Docker Mods](https://github.com/linuxserver/docker-mods) to enable additional functionality within the containers. The list of Mods available for this image (if any) as well as universal mods that can be applied to any one of the LSIO images can be accessed via the dynamic badges above.

## Support Info

* Shell access whilst the container is running:

    ```bash
    docker exec -it transmission /bin/bash
    ```

* To monitor the logs of the container in realtime:

    ```bash
    docker logs -f transmission
    ```

* Container version number:

    ```bash
    docker inspect -f '{{ index .Config.Labels "build_version" }}' transmission
    ```

* Image version number:

    ```bash
    docker inspect -f '{{ index .Config.Labels "build_version" }}' lscr.io/toondocker/docker-transmission:latest
    ```

## Updating Info

Most of the LSIO images are static, versioned, and require an image update and container recreation to update the app inside. With some exceptions (noted in the relevant readme.md), LSIO do not recommend or support updating apps inside the container. Please consult the [Application Setup](#application-setup) section above to see if it is recommended for the image.

Below are the instructions for updating containers:

### Via Docker Compose

* Update images:
    * All images:

        ```bash
        docker-compose pull
        ```

    * Single image:

        ```bash
        docker-compose pull transmission
        ```

* Update containers:
    * All containers:

        ```bash
        docker-compose up -d
        ```

    * Single container:

        ```bash
        docker-compose up -d transmission
        ```

* You can also remove the old dangling images:

    ```bash
    docker image prune
    ```

### Via Docker Run

* Update the image:

    ```bash
    docker pull lscr.io/toondocker/docker-transmission:latest
    ```

* Stop the running container:

    ```bash
    docker stop transmission
    ```

* Delete the container:

    ```bash
    docker rm transmission
    ```

* Recreate a new container with the same docker run parameters as instructed above (if mapped correctly to a host folder, your `/config` folder and settings will be preserved)
* You can also remove the old dangling images:

    ```bash
    docker image prune
    ```

### Image Update Notifications - Diun (Docker Image Update Notifier)

>[!TIP]
>We recommend [Diun](https://crazymax.dev/diun/) for update notifications. Other tools that automatically update containers unattended are not recommended or supported.

## Building locally

If you want to make local modifications to these images for development purposes or just to customize the logic:

```bash
git clone https://github.com/toondocker/docker-transmission.git
cd docker-transmission
docker build \
  --no-cache \
  --pull \
  -t lscr.io/toondocker/docker-transmission:latest .
```

## Versions

* **09.08.26:** - Add environment variables for done script, blocklist, and custom network configuration. First version that enhances the LSIO version, but uses Transmission 4.0.5
