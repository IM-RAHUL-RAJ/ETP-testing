#!/usr/bin/env python3
"""Write the two config files into the files the deployment reads.

  config/application.yaml   addresses and ports; changed for each machine
  config/project.yaml       folders, types and the settings your code reads; written once

  python3 deploy/config/apply.py            for docker-compose on a machine
  python3 deploy/config/apply.py local      services started by hand on a laptop
  python3 deploy/config/apply.py eks        for Kubernetes
  python3 deploy/config/apply.py --check    change nothing; exit 1 if a file is out of date

What it writes:
  deploy/build.env   always        folders, ports and names for the pipeline (commit it)
  deploy/.env        docker, local settings for docker-compose, plus the secrets
                                   you type in (never committed)
  deploy/k8s/        eks           the Kubernetes files (commit them)
"""
import json
import re
import secrets as tokens
import shutil
import sys
from pathlib import Path
from urllib.parse import urlsplit

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is missing. Install it with: sudo dnf install -y python3-pyyaml")

DEPLOY = Path(__file__).resolve().parent.parent
PHASES = ("local", "docker", "eks")
LOCAL_HOSTS = ("localhost", "127.0.0.1")
# role in application.yaml -> name of its container, image and Kubernetes objects
NAMES = {"frontend": "frontend", "auth": "auth-service",
         "order": "order-service", "executor": "executor-service"}
VERSIONS = {"java": "21", "node": "22", "angular": "22", "python": "3.11"}
# The tag of the images pushed by hand. The pipeline replaces it with the commit.
FIRST_TAG = "1.0"
SECRETS_HEAD = "# ---- Secrets: type the values here. This file is never committed. ----"
MANAGED_HEAD = "# ---- Written by config/apply.py from the two config files. Do not edit below. ----"
# Requests and limits per kind of service, sized for two t3.medium nodes.
RESOURCES = {
    "java": ("100m", "320Mi", "500m", "768Mi"),
    "node": ("50m", "160Mi", "250m", "384Mi"),
    "python": ("25m", "96Mi", "100m", "256Mi"),
    "angular": ("10m", "32Mi", "100m", "128Mi"),
}
WAIT_FOR_KAFKA = """\
      initContainers:
        - name: wait-for-kafka-topics
          image: apache/kafka:3.8.0
          command:
            - /bin/sh
            - -c
            - until /opt/kafka/bin/kafka-topics.sh --bootstrap-server @@KAFKA@@ --describe --topic orders >/dev/null 2>&1; do echo waiting for Kafka topics; sleep 5; done
"""


def load_config():
    """Both files as one dictionary, in the shape the rest of this program reads."""
    folder = DEPLOY / "config"
    app = yaml.safe_load((folder / "application.yaml").read_text())
    project = yaml.safe_load((folder / "project.yaml").read_text())
    k8s = project.get("kubernetes") or {}
    name = project["name"]
    addresses = {"frontend": app["frontend"], **app["services"]}
    services = {}
    for role in NAMES:
        if role not in addresses or role not in project["folders"]:
            sys.exit(f"'{role}' must be in both application.yaml and project.yaml (folders)")
        services[role] = {
            **project["folders"][role],
            "url": str(addresses[role]["url"]).rstrip("/"),
            "port": addresses[role]["port"],
            "routes": (k8s.get("routes") or {}).get(role, []),
            "test": role not in (k8s.get("skip_tests") or []),
        }
    return {
        "project": {"name": name, "root": project.get("root", "..")},
        "services": services,
        "database": {**app["database"], "password_env": project["database_password"],
                     "sql": [sql_entry(s) for s in project.get("sql") or []],
                     "sql_vars": project.get("sql_vars") or {}},
        "proxy": bool(project.get("proxy", False)),
        "strip_routes": project.get("strip_routes") or {},
        "kafka": app["kafka"],
        "mail": {"mailpit": project.get("mailpit", False), "host": "mailpit", "port": 1025,
                 **(project.get("mail") or {})},
        "aws": {"region": "ap-south-1", "namespace": name, "image_prefix": name,
                "registry": str(k8s.get("registry") or "").rstrip("/")},
        "env": project.get("settings") or {},
        "secrets": project.get("secrets") or [],
        "derived_secrets": project.get("derived_secrets") or {},
        "smoke": k8s.get("smoke") or [{"path": "/", "expect": 200}],
    }


def sql_entry(item):
    """A `sql` item: a path, or {path, schema} to run those files with that search_path."""
    if isinstance(item, dict):
        return f"{item['path']}@{item['schema']}" if item.get("schema") else item["path"]
    return str(item)


def proxy_routes(cfg):
    """PROXY_ROUTES for the frontend's nginx: each route path to its service, by container name."""
    svc = cfg["services"]
    out = [f"{route}=http://{NAMES[role]}:{svc[role]['port']}"
           for role in ("auth", "order", "executor") for route in svc[role].get("routes") or []]
    # strip_routes: a path prefix the page adds and the service does not know (/trade-api/x -> /x)
    out += [f"{route.rstrip('/')}=http://{NAMES[role]}:{svc[role]['port']}/"
            for route, role in (cfg.get("strip_routes") or {}).items()]
    return " ".join(out)


def check_docker(cfg):
    """Addresses that work on a laptop but cannot work inside a container."""
    for block in ("database", "kafka"):
        if str(cfg[block]["host"]) in LOCAL_HOSTS:
            sys.exit(f"application.yaml: {block}.host is {cfg[block]['host']}. Inside a container that means "
                     f"the container itself. Use the container's name"
                     + (" (postgres) or the RDS endpoint." if block == "database" else " (kafka)."))


def listen_port(service):
    """The port inside the container. nginx serves an Angular build on 80."""
    return 80 if service["type"] == "angular" else service["port"]


def placeholders(cfg, phase):
    """The values an `env` entry can refer to as {name}, for this phase."""
    svc, db, kafka, mail = cfg["services"], cfg["database"], cfg["kafka"], cfg["mail"]

    def address(role):
        return f"{svc[role]['url']}:{svc[role]['port']}"

    page = urlsplit(svc["frontend"]["url"])
    scheme, host = page.scheme or "http", page.hostname or ""
    if phase == "eks":
        # One load balancer serves the page and both APIs on port 80, so the
        # browser needs no API address, and services find each other by name.
        base = svc["frontend"]["url"]
        out = {"frontend_url": base, "auth_url": "", "order_url": "", "cors_origins": base,
               "cookie_secure": "false"}
        internal = {role: f"http://{NAMES[role]}:{svc[role]['port']}" for role in ("auth", "order")}
    else:
        origins = [address("frontend")]
        if host in LOCAL_HOSTS:
            origins += [f"{scheme}://{h}:{svc['frontend']['port']}" for h in LOCAL_HOSTS if h != host]
        # With the proxy the page calls its own address, as on EKS.
        same_origin = cfg.get("proxy") and phase == "docker"
        out = {"frontend_url": origins[0],
               "auth_url": "" if same_origin else address("auth"),
               "order_url": "" if same_origin else address("order"),
               "cors_origins": ",".join(origins),
               # Browsers drop Secure cookies over plain http, except on localhost.
               "cookie_secure": "true" if scheme == "https" or host in LOCAL_HOSTS else "false"}
        if phase == "docker":
            internal = {role: f"http://{NAMES[role]}:{svc[role]['port']}" for role in ("auth", "order")}
        else:
            internal = {role: f"http://localhost:{svc[role]['port']}" for role in ("auth", "order")}
    mailpit = mail.get("mailpit", False)
    if phase == "local":
        # Started by hand, the services reach Postgres, Kafka and Mailpit
        # through the ports docker-compose publishes on the machine.
        out.update({"db_host": "localhost" if db["host"] == "postgres" else db["host"],
                    "kafka": "localhost:9092" if kafka["host"] == "kafka" else f"{kafka['host']}:{kafka['port']}",
                    "mail_host": "localhost" if mailpit else mail["host"]})
    else:
        out.update({"db_host": db["host"], "kafka": f"{kafka['host']}:{kafka['port']}",
                    "mail_host": "mailpit" if mailpit else mail["host"]})
    out.update({"db_port": db["port"], "db_name": db["name"], "db_user": db["user"],
                # RDS accepts only encrypted connections; the container does not offer them.
                "db_sslmode": "disable" if db["host"] == "postgres" else "no-verify",
                # For a database URL a Node service reads: RDS accepts only encrypted connections.
                "db_ssl_query": "" if db["host"] == "postgres" else "?sslmode=no-verify",
                "mail_port": 1025 if mailpit else mail["port"],
                "auth_internal": internal["auth"], "order_internal": internal["order"]})
    return out


def app_env(cfg, phase):
    """The project's own settings, with the placeholders filled in."""
    values = placeholders(cfg, phase)
    out = {}
    for key, value in (cfg.get("env") or {}).items():
        try:
            out[key] = str(value).format(**values)
        except KeyError as err:
            sys.exit(f"project.yaml: settings.{key} uses an unknown placeholder {{{err.args[0]}}}; "
                     f"known: {', '.join(sorted(values))}")
    clash = sorted(set(out) & set(cfg.get("secrets") or []))
    if clash:
        sys.exit(f"project.yaml: listed under both settings and secrets: {', '.join(clash)}")
    return out


def service_env(cfg, phase, role):
    """Settings for one service only (folders.<role>.settings), over the shared ones."""
    values = placeholders(cfg, phase)
    out = {}
    for key, value in (cfg["services"][role].get("settings") or {}).items():
        try:
            out[key] = str(value).format(**values)
        except KeyError as err:
            sys.exit(f"project.yaml: folders.{role}.settings.{key} uses an unknown placeholder {{{err.args[0]}}}")
    return out


def build_settings(cfg):
    """Folders, ports and names: the same in every phase."""
    aws, db = cfg["aws"], cfg["database"]
    out = {
        "PROJECT_NAME": cfg["project"]["name"],
        "PROJECT_ROOT": cfg["project"].get("root", ".."),
        "PROJECT_DIR": str((DEPLOY / cfg["project"].get("root", "..")).resolve()),
        "DEPLOY_DIR": str(DEPLOY),
        "IMAGE_PREFIX": aws["image_prefix"],
        "AWS_REGION": aws["region"],
        "REGISTRY": aws["registry"],
        "NS": aws["namespace"],
        "DB_NAME": db["name"],
        "DB_USER": db["user"],
        "DB_PASSWORD_ENV": db["password_env"],
        "DB_SQL": " ".join(db.get("sql") or []),
        "DB_SQL_VARS": " ".join(f"{k}={v}" for k, v in (db.get("sql_vars") or {}).items()),
        "SECRET_NAMES": " ".join(all_secret_names(cfg)),
        "SMOKE": " ".join(f"{c['path']}={c['expect']}" for c in cfg.get("smoke") or []),
    }
    for role, name in NAMES.items():
        service, key = cfg["services"][role], role.upper()
        if service["type"] not in VERSIONS:
            sys.exit(f"project.yaml: folders.{role}.type is '{service['type']}'; choose one of: {', '.join(VERSIONS)}")
        out.update({
            f"{key}_PATH": service["path"],
            # The build starts from build_from (default: the service's own folder);
            # MODULE is the service inside it and PREBUILD what is installed first.
            f"{key}_CONTEXT": service.get("build_from") or service["path"],
            f"{key}_MODULE": module_in_context(service),
            f"{key}_PREBUILD": " ".join(service.get("prebuild") or []),
            # How the image starts the service (node and python only); folders.<role>.start overrides it.
            f"{key}_MAIN_CLASS": service.get("main_class", ""),
            f"{key}_START": service.get("start") or {"node": "node dist/main.js", "python": "python app.py"}.get(service["type"], ""),
            f"{key}_TYPE": service["type"],
            f"{key}_VERSION": str(service.get("version", VERSIONS[service["type"]])),
            f"{key}_PORT": service["port"],
            f"{key}_LISTEN": listen_port(service),
            f"{key}_HEALTH": service.get("health", "/"),
            f"{key}_TEST": "true" if service.get("test") else "false",
        })
    return out


def module_in_context(service):
    base = service.get("build_from")
    if not base:
        return "."
    rel = Path(service["path"]).relative_to(Path(base))
    return str(rel) or "."


def env_line(key, value):
    value = str(value)
    # Quoted when it holds a space, so both docker-compose and bash read it whole.
    return f'{key}="{value}"' if " " in value else f"{key}={value}"


def build_env(cfg):
    lines = ["# Folders, ports and names for the pipeline (deploy/Jenkinsfile).",
             "# Written by config/apply.py from the two config files. Do not edit.",
             "# No secrets: this file is committed, so the pipeline can read it."]
    lines += [env_line(k, v) for k, v in build_settings(cfg).items()
              # These two are different on every machine.
              if k not in ("PROJECT_DIR", "DEPLOY_DIR")]
    return "\n".join(lines) + "\n"


# Secrets the kit can make up itself: passwords, signing keys, internal tokens.
# Keys for outside services (Fauxnance, Gemini, mail logins) have to be typed in.
TYPED_ONLY = re.compile(r"API_KEY|FAUXNANCE|GEMINI|GROQ|LLM|EMAILJS|TWILIO|MAIL|SMTP|USERNAME|_USER$")


def all_secret_names(cfg):
    return list(cfg.get("secrets") or []) + [k for k in cfg.get("derived_secrets") or {} if k not in (cfg.get("secrets") or [])]


def fill_secrets(cfg, phase, found):
    """Make up the missing generatable secrets, then work out the derived ones."""
    for name, value in found.items():
        if not value and not TYPED_ONLY.search(name):
            found[name] = tokens.token_hex(24)
    values = {**placeholders(cfg, phase), **found}
    for name, template in (cfg.get("derived_secrets") or {}).items():
        try:
            found[name] = str(template).format(**values)
        except KeyError as err:
            sys.exit(f"project.yaml: derived_secrets.{name} uses an unknown name {{{err.args[0]}}}")
    return found


def secret_values(path, names):
    """What has already been typed into .env for each secret."""
    found = dict.fromkeys(names, "")
    if path.exists():
        for line in path.read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep and key.strip() in found:
                found[key.strip()] = value
    return found


def dot_env(cfg, phase):
    path = DEPLOY / ".env"
    values = placeholders(cfg, phase)
    lines = [SECRETS_HEAD,
             "# Passwords and tokens are made up on the first run and kept. Type in the API keys;",
             "# the lines under `derived` are worked out from the others on every run."]
    found = fill_secrets(cfg, phase, secret_values(path, cfg.get("secrets") or []))
    lines += [f"{k}={v}" for k, v in found.items() if k in (cfg.get("secrets") or [])]
    derived = [k for k in cfg.get("derived_secrets") or {} if k not in (cfg.get("secrets") or [])]
    if derived:
        lines += ["# derived"] + [f"{k}={found[k]}" for k in derived]
    lines += ["", MANAGED_HEAD, f"# phase: {phase}"]
    lines += [env_line(k, v) for k, v in build_settings(cfg).items()]
    # Optional containers: Postgres unless the database is elsewhere (RDS), Mailpit if asked for.
    profiles = [name for name, wanted in (("localdb", cfg["database"]["host"] == "postgres"),
                                          ("mail", cfg["mail"].get("mailpit"))) if wanted]
    lines += [env_line("COMPOSE_PROFILES", ",".join(profiles)),
              env_line("AUTH_URL", values["auth_url"]),
              env_line("BACKEND_URL", values["order_url"]),
              env_line("PROXY_ROUTES", proxy_routes(cfg) if cfg.get("proxy") else ""),
              "", "# The project's own settings (`settings` in project.yaml)."]
    lines += [env_line(k, v) for k, v in app_env(cfg, phase).items()]
    return "\n".join(lines) + "\n"


def render(text, tokens):
    for key, value in tokens.items():
        text = text.replace(f"@@{key}@@", str(value))
    if "@@" in text:
        sys.exit("a template token was not filled in: " + text[text.index("@@"):][:40])
    return text


def k8s_files(cfg):
    """File name -> content of everything in deploy/k8s for this configuration."""
    aws, svc, mail = cfg["aws"], cfg["services"], cfg["mail"]
    templates = DEPLOY / "k8s-templates"
    kafka = f"{cfg['kafka']['host']}:{cfg['kafka']['port']}"
    common = {"NS": aws["namespace"], "KAFKA": kafka}
    files = {}
    for name in ("namespace.yaml", "storageclass.yaml", "kafka.yaml"):
        files[name] = render((templates / name).read_text(), common)
    if mail.get("mailpit"):
        files["mailpit.yaml"] = render((templates / "mailpit.yaml").read_text(), common)

    data = app_env(cfg, "eks")
    if cfg.get("proxy"):
        data["PROXY_ROUTES"] = proxy_routes(cfg)
    files["configmap.yaml"] = render((templates / "configmap.yaml").read_text(), {
        **common,
        # Every ConfigMap value must be a string, so all of them are quoted.
        "DATA": "\n".join(f"  {k}: {json.dumps(str(v))}" for k, v in data.items()) or "  {}",
    })

    app = (templates / "app.yaml").read_text()
    for role, name in NAMES.items():
        own = service_env(cfg, "eks", role)
        files[f"{name}-config.yaml"] = (
            "# Settings for this service only (folders.%s.settings).\napiVersion: v1\nkind: ConfigMap\n"
            "metadata:\n  name: %s-config\n  namespace: %s\ndata:\n%s\n" % (
                role, name, aws["namespace"],
                "\n".join(f"  {k}: {json.dumps(str(v))}" for k, v in own.items()) or "  {}"))
        service = svc[role]
        cpu, memory, cpu_limit, memory_limit = RESOURCES[service["type"]]
        files[f"{name}.yaml"] = render(app, {
            **common, "NAME": name,
            "IMAGE": f"{aws['registry']}/{aws['image_prefix']}-{name}:{FIRST_TAG}",
            "PORT": service["port"], "LISTEN": listen_port(service),
            "HEALTH": service.get("health", "/"),
            "CPU": cpu, "MEMORY": memory, "CPU_LIMIT": cpu_limit, "MEMORY_LIMIT": memory_limit,
            # The two services that use Kafka wait until its topics exist.
            "INIT": render(WAIT_FOR_KAFKA, common) if role in ("order", "executor") else "",
        })

    rules = []
    for role in ("auth", "order", "executor"):
        for route in svc[role].get("routes") or []:
            rules.append((route, NAMES[role], svc[role]["port"]))
    rules.append(("/", "frontend", svc["frontend"]["port"]))
    paths = "".join(
        f"          - path: {route}\n            pathType: Prefix\n            backend:\n"
        f"              service:\n                name: {name}\n                port:\n"
        f"                  number: {port}\n" for route, name, port in rules)
    files["ingress.yaml"] = render((templates / "ingress.yaml").read_text(), {
        **common, "PATHS": paths.rstrip("\n"),
        "ROUTES": "\n".join(f"#   {route:<14} -> {name}:{port}" for route, name, port in rules),
    })
    files["kustomization.yaml"] = (
        "# Every file in this folder, for `kubectl apply -k`. Written by config/apply.py.\n"
        "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n"
        + "".join(f"  - {name}\n" for name in files))
    return files


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    check = "--check" in sys.argv[1:]
    cfg = load_config()
    phase = args[0] if args else "docker"
    if phase not in PHASES:
        sys.exit(f"unknown phase '{phase}'; choose one of: {', '.join(PHASES)}")
    if phase == "docker":
        check_docker(cfg)
    if cfg.get("proxy") and not proxy_routes(cfg):
        sys.exit("project.yaml: proxy: true needs kubernetes.routes (the API paths of auth and order)")
    if phase == "eks" and not cfg["aws"]["registry"]:
        sys.exit("project.yaml: kubernetes.registry is missing. It is the address of your image "
                 "registry, such as 123456789012.dkr.ecr.ap-south-1.amazonaws.com")

    targets = {DEPLOY / "build.env": build_env(cfg)}
    if phase == "eks":
        targets.update({DEPLOY / "k8s" / name: text for name, text in k8s_files(cfg).items()})
    else:
        targets[DEPLOY / ".env"] = dot_env(cfg, phase)
        for role, name in NAMES.items():
            targets[DEPLOY / f"{name}.env"] = "# Settings for this service only. Written by config/apply.py.\n" + \
                "".join(env_line(k, v) + "\n" for k, v in service_env(cfg, phase, role).items())
    stale = [p for p, text in targets.items() if not p.exists() or p.read_text() != text]
    k8s = DEPLOY / "k8s"
    extra = [p for p in k8s.glob("*.yaml") if p not in targets] if phase == "eks" and k8s.exists() else []

    names = ", ".join(str(p.relative_to(DEPLOY)) for p in stale + extra)
    if check:
        if stale or extra:
            sys.exit(f"out of date for phase {phase}: {names}\nrun: python3 deploy/config/apply.py {phase}")
        print(f"everything matches the config files (phase {phase})")
        return

    if phase == "eks":
        # Rebuilt from scratch, so a file that is no longer wanted does not linger.
        shutil.rmtree(k8s, ignore_errors=True)
        k8s.mkdir()
    for path, text in targets.items():
        path.write_text(text)
    print(f"phase {phase}: {'updated ' + names if stale or extra else 'already up to date'}")

    if phase == "eks":
        if cfg["database"]["host"] in ("postgres",) + LOCAL_HOSTS:
            print(f"Warning: database.host is still '{cfg['database']['host']}'. There is no Postgres container on EKS; "
                  "set it to the RDS endpoint and run this again.")
        if not any(cfg["services"][role]["routes"] for role in ("auth", "order")):
            print("Warning: project.yaml has no kubernetes.routes, so the load balancer sends every path to the frontend.")
        print(f"Page address written into the settings: {cfg['services']['frontend']['url']}")
        return
    empty = [k for k, v in secret_values(DEPLOY / ".env", cfg.get("secrets") or []).items() if not v.strip()]
    if empty:
        print(f"Type these into deploy/.env when you have them (the features that use them stay off until then): {', '.join(empty)}")
    values = placeholders(cfg, phase)
    if cfg.get("proxy") and phase == "docker":
        print(f"Page: {values['frontend_url']}   (the APIs answer on the same address: {proxy_routes(cfg)})")
    else:
        print(f"Page: {values['frontend_url']}   auth: {values['auth_url']}   trade API: {values['order_url']}")
    if phase == "docker":
        print("Now, in deploy/: docker-compose up -d --build")
    else:
        print("Now, in deploy/: docker-compose up -d postgres kafka kafka-init"
              + (" mailpit" if cfg["mail"].get("mailpit") else ""))
        print("Then, before starting a service by hand: set -a; . deploy/.env; set +a")


if __name__ == "__main__":
    main()
