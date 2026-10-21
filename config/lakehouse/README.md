# Alpha lakehouse

Alpha includes Spark master and worker, JupyterLab, and RustFS. All use published
images; there is no Docker build. Spark and Jupyter use the same pinned
`quay.io/jupyter/pyspark-notebook:spark-3.5.3` image to keep Spark and Python
versions aligned. Delta Lake 3.2.1 and Hadoop S3A 3.3.4 are loaded through
`spark.jars.packages` when a notebook starts its Spark session. Maven access is
required on first use; the Ivy cache persists on the host. Delta is a library
and table format, so it does not need its own container.

Allow about 6 GB additional host RAM. The worker provides two cores and 2 GB
executor capacity. The master and worker have no published host ports.

## Image registry, startup helper, and container paths

[Upstream Jupyter Docker Stacks](https://jupyter-docker-stacks.readthedocs.io/en/latest/)
publishes updated images to Quay.io only, since October 20, 2023. Apache Spark itself does not require
Quay: Apache's standalone Spark images are an alternative. This fleet uses the
Jupyter PySpark image for both notebook and workers to match their Spark and
Python versions without maintaining custom images. Workers carry extra notebook
software as a tradeoff for that consistency.

RustFS uses the published `rustfs/rustfs:1.0.2` image, pinned for reproducibility.
It runs as UID/GID `10001:10001`, with separate data and log mounts. Shared AWS
credentials are mapped to RustFS's administrator credentials at startup, while
Spark uses those same values through its environment credential provider.

`lakehouse-init` is a one-shot bucket bootstrap using the published AWS CLI
image. After RustFS becomes healthy, it checks for the private `lakehouse` bucket
and creates it if missing. It neither deletes nor empties an existing bucket.
Jupyter waits for successful completion.
`/home/jovyan` is the published Jupyter image's standard home directory, owned by
its non-root `jovyan` user. Host notebooks
live in `/opt/flotilla/data/jupyterlab`, mounted into `/home/jovyan/work`; host
Maven cache lives in `/opt/flotilla/data/spark-ivy`, mounted into
`/home/jovyan/.ivy2`. Keeping the image's defaults avoids user and ownership
customization during container startup.

`smoke.py` is an optional integration test, not a daemon or startup requirement.
It creates a small Delta table in RustFS, checks distributed SQL and schema
evolution, reads an older table version, and deletes selected rows transactionally.
It intentionally leaves its test table in `lakehouse/smoke/` for inspection. It
runs only when you invoke the verification command below.

## Prepare an existing installation

```sh
sudo install -d -m 700 /opt/flotilla/secrets
sudo install -m 600 config/lakehouse/lakehouse.env.example /opt/flotilla/secrets/lakehouse.env
sudoedit /opt/flotilla/secrets/lakehouse.env
sudo install -d -o 1000 -g 100 -m 750 /opt/flotilla/data/jupyterlab /opt/flotilla/data/spark-ivy
sudo install -d -o 10001 -g 10001 -m 750 /opt/flotilla/data/rustfs /opt/flotilla/data/rustfs-logs
sudo mkdir -p /opt/flotilla/config/lakehouse
sudo cp config/lakehouse/spark-defaults.conf config/lakehouse/smoke.py /opt/flotilla/config/lakehouse/
sudo cp alpha/docker-compose.yml /opt/flotilla/docker-compose.yml
sudo cp config/letsencrypt/nginx/proxy-confs/{jupyter,rustfs,s3,spark}.subdomain.conf /opt/flotilla/config/letsencrypt/nginx/proxy-confs/
```

Replace all credential placeholders before startup. RustFS takes its administrator login
from the same AWS credentials Spark uses. For shared use, create a scoped RustFS
account and use that for Spark instead. Notebooks and Maven cache run as the
published image's `jovyan` user (UID 1000, GID 100). Bind mounts include SELinux
labels consistent with the alpha fleet. Back up notebook data, RustFS data, and the credentials. If the installer already linked config
paths to this checkout, avoid copying files onto themselves.

## DNS and HTTPS

Create these DNS records pointing to the same public address as the existing
SWAG host (A/AAAA records, or CNAMEs to an existing hostname):

| Hostname | Destination | Authentication |
| --- | --- | --- |
| `jupyter.maxocull.com` | JupyterLab, port 8888 | `JUPYTER_TOKEN` |
| `rustfs.maxocull.com` | RustFS console, port 9001 | AWS key and secret |
| `s3.maxocull.com` | RustFS S3 API, port 9000 | S3 signed requests |
| `spark.maxocull.com` | Spark master UI, port 8080 | SWAG basic auth |

All four names are included in alpha's SWAG `SUBDOMAINS`. Jupyter kernels and
RustFS console use SWAG's standard WebSocket proxy configuration. The S3 proxy
preserves the request path and Host header for request signing and allows
streamed uploads. Spark connects to RustFS internally at `http://rustfs:9000`.

Create SWAG's password file before publishing the Spark UI. If it already exists,
add a user without `-c` (which overwrites the file):

```sh
docker exec -it letsencrypt htpasswd -c /config/nginx/.htpasswd sparkadmin
```

Start the new services, then recreate SWAG after the DNS records resolve so it
requests a certificate covering the added names:

```sh
docker compose -f /opt/flotilla/docker-compose.yml config --quiet
docker compose -f /opt/flotilla/docker-compose.yml up -d spark-master spark-worker rustfs lakehouse-init jupyterlab
docker compose -f /opt/flotilla/docker-compose.yml up -d --force-recreate letsencrypt
docker logs letsencrypt
docker exec letsencrypt nginx -t
```

## Notebook and verification

Open `https://jupyter.maxocull.com`, enter the token, and save notebooks in `work`
so they persist. In a Python notebook:

```python
from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("experiments").getOrCreate()
spark.range(100).repartition(2).write.format("delta").mode("overwrite").save(
    "s3a://lakehouse/demo"
)
spark.read.format("delta").load("s3a://lakehouse/demo").createOrReplaceTempView("demo")
spark.sql("SELECT count(*) FROM demo").show()
spark.sql("SELECT * FROM demo WHERE id < 10").explain(True)
```

Stop notebook Spark sessions before running the integration check:

```sh
docker compose -f /opt/flotilla/docker-compose.yml exec jupyterlab python /opt/lakehouse/smoke.py
```

It verifies distributed DataFrames, SQL, Delta schema evolution, time travel,
and transactional deletes in RustFS. It retains a unique small table under
`lakehouse/smoke/` for inspection. Drivers run in JupyterLab and advertise its
hostname to executors. Use one active Spark context at a time. The Spark master
UI shows worker registration; executor and driver UI links use internal Docker
addresses and are not separately proxied.

## Add a worker on Leviathan

Leviathan has 128 GB RAM and 128 cores. Start with a worker offering **32 cores
and 96 GB RAM**, with a Docker limit of 32 CPUs and 104 GB, leaving host capacity
for other services. A notebook can then request one 32-core, 80-GB executor,
leaving room for JVM/native overhead within that worker allocation. Increase
these limits only after observing memory and CPU use. This example leaves the
small alpha worker in place, but its resources are too small for this notebook's
executor request, so this notebook runs on Leviathan.

A worker joining the master is only part of the connection: remote executors
also need to call back to the notebook driver, read RustFS, and accept driver
connections. The default Docker-only hostnames work on one host and will not
work across these machines. Use a trusted LAN or private VPN; do not forward
Spark RPC ports from the public Internet. Spark RPC in this setup has no
authentication or encryption. The SWAG basic-auth page does not protect RPC.

### 1. Publish private fleet endpoints

On the alpha host, create `/opt/flotilla/leviathan.override.yml`:

```yaml
services:
  spark-master:
    ports:
      - "${FLEET_LAN_IP:?Set FLEET_LAN_IP}:7077:7077"
  jupyterlab:
    ports:
      - "${FLEET_LAN_IP:?Set FLEET_LAN_IP}:39001:39001"
      - "${FLEET_LAN_IP:?Set FLEET_LAN_IP}:39002:39002"
  rustfs:
    ports:
      - "${FLEET_LAN_IP:?Set FLEET_LAN_IP}:9000:9000"
```

Replace the address below with alpha's actual LAN/VPN address, not its public
address. Use alpha's existing Compose project name if you have set one explicitly:

```sh
export FLEET_LAN_IP=192.168.1.REPLACE
# Replace the placeholder above before running Compose.
docker compose -f /opt/flotilla/docker-compose.yml \
    -f /opt/flotilla/leviathan.override.yml up -d spark-master jupyterlab rustfs
```

Keep that override and `FLEET_LAN_IP` in subsequent Compose invocations managing
these services. The legacy `flotilla` commands do not automatically include this
override; include it in the installed Compose file or service invocation before
relying on those commands to recreate containers.

Use the hosts' firewall to allow TCP 7077, 39001, 39002, and 9000 on alpha only
from Leviathan's private address. Bind-address restrictions alone do not restrict
which LAN peers connect; verify Docker's forwarding/firewall rules too.

### 2. Start the remote worker

On Leviathan (Linux), create a separate `compose.yml`:

```yaml
services:
  spark-worker:
    image: quay.io/jupyter/pyspark-notebook:spark-3.5.3
    network_mode: host
    extra_hosts:
      - "spark-master:${FLEET_LAN_IP:?Set FLEET_LAN_IP}"
    env_file:
      - /opt/flotilla/secrets/lakehouse.env
    init: true
    command:
      - /usr/local/spark/bin/spark-class
      - org.apache.spark.deploy.worker.Worker
      - --host
      - "${LEVIATHAN_LAN_IP:?Set LEVIATHAN_LAN_IP}"
      - --port
      - "7078"
      - --webui-port
      - "8081"
      - --cores
      - "32"
      - --memory
      - 96g
      - "spark://${FLEET_LAN_IP:?Set FLEET_LAN_IP}:7077"
    cpus: 32
    mem_limit: 104g
    restart: unless-stopped
```

Create a `.env` next to that file with alpha's real address and Leviathan's
address (the fleet currently uses `192.168.1.11` for Leviathan's Ollama endpoint;
verify it is the correct reachable interface):

```dotenv
FLEET_LAN_IP=192.168.1.REPLACE
LEVIATHAN_LAN_IP=192.168.1.11
```

Securely copy alpha's `/opt/flotilla/secrets/lakehouse.env` to that same path on
Leviathan and restrict it with `chmod 600` before starting the worker. Prefer a
scoped RustFS account for worker credentials. The environment credentials provider
requires these values on the remote worker as well as the notebook driver.

Run `docker compose config --quiet` and `docker compose up -d`. The `extra_hosts`
entry lets the remote worker and executors resolve the master's advertised
Docker hostname back to alpha's LAN address. The worker uses
host networking to advertise a LAN address rather than an unreachable container
address. It needs outbound access to alpha and TCP 7078, 39010, and 39002 inbound
from alpha only. Port 8081 is its worker UI; restrict it to administrators or
use an SSH tunnel. Ensure those ports are free on Leviathan first. Do not start
a second worker or a second executor using the same fixed ports on that host.

### 3. Use the remote worker from Jupyter

Stop any existing Spark session, then create a session in a fresh kernel with
these overrides. Substitute alpha's real LAN/VPN address:

```python
from pyspark.sql import SparkSession

fleet_ip = "192.168.1.REPLACE"
spark = (
    SparkSession.builder.appName("leviathan")
    .config("spark.driver.host", fleet_ip)
    .config("spark.driver.bindAddress", "0.0.0.0")
    .config("spark.driver.port", "39001")
    .config("spark.driver.blockManager.port", "39002")
    .config("spark.blockManager.port", "39002")
    .config("spark.executor.port", "39010")
    .config("spark.port.maxRetries", "0")
    .config("spark.executor.cores", "32")
    .config("spark.executor.memory", "80g")
    .config("spark.cores.max", "32")
    .config("spark.hadoop.fs.s3a.endpoint", f"http://{fleet_ip}:9000")
    .getOrCreate()
)
spark.range(1_000_000).repartition(32).groupBy().sum("id").show()
```

These settings deliberately allow one executor on Leviathan and one driver in
Jupyter. The fixed ports make firewall rules predictable; concurrent applications
need separate ports and corresponding firewall rules. Spark distributes the
Delta/S3A JARs from the driver to executors, and passes the S3A configuration with
jobs. The remote worker's `env_file` supplies the S3 credentials to its executors;
RustFS data travels directly between Leviathan and alpha's private S3 endpoint.

Check `https://spark.maxocull.com` for the Leviathan worker and a running executor,
then write and read a small Delta table with the notebook example above. If the
worker registers but tasks hang, check driver callbacks and both machines'
firewalls first. A successful SQL aggregate alone does not verify RustFS access.
This multi-host recipe has been configuration-checked, not tested on Leviathan.
