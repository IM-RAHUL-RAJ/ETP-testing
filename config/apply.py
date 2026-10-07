#!/usr/bin/env python3
"""Write config/application.yaml into the file the chosen phase reads.

  python3 config/apply.py            apply the phase set in application.yaml
  python3 config/apply.py docker     write for another phase than the one in the file
  python3 config/apply.py --check    change nothing; exit 1 if a file is out of date

Only the keys listed here are touched. Everything else in .env and in the
ConfigMap (passwords, keys, comments) is left as it is.
"""
import re
import shutil
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is missing. Install it with: sudo dnf install -y python3-pyyaml")

ROOT = Path(__file__).resolve().parent.parent
LOCAL_HOSTS = ("localhost", "127.0.0.1")
PHASES = ("local", "docker", "eks")


def address(entry):
    return f"{str(entry['url']).rstrip('/')}:{entry['port']}"


def settings(cfg, phase):
    """The KEY -> value pairs this phase needs."""
    db, kafka = cfg["database"], cfg["kafka"]
    out = {
        "DB_HOST": db["host"],
        "DB_PORT": db["port"],
        "DB_NAME": db["name"],
        "DB_USER": db["user"],
        "KAFKA_BOOTSTRAP_SERVERS": f"{kafka['host']}:{kafka['port']}",
        "FAUXNANCE_BASE_URL": cfg["fauxnance"]["url"],
    }
    if phase == "eks":
        # The browser-facing addresses are the load balancer's, which the
        # deploy scripts fill in once it exists.
        return out
    frontend = cfg["frontend"]
    scheme, _, host = str(frontend["url"]).rstrip("/").rpartition("://")
    origins = [address(frontend)]
    if host in LOCAL_HOSTS:
        origins += [f"{scheme}://{h}:{frontend['port']}" for h in LOCAL_HOSTS if h != host]
    out.update({
        "AUTH_URL": address(cfg["services"]["auth"]),
        "BACKEND_URL": address(cfg["services"]["order"]),
        "CORS_ALLOWED_ORIGINS": ",".join(origins),
        # Browsers drop Secure cookies over plain http, except on localhost.
        "COOKIE_SECURE": "true" if scheme == "https" or host in LOCAL_HOSTS else "false",
    })
    return out


def rewrite(text, values, pattern, line):
    """Replace each key's line in place; append the keys that are not there."""
    for key, value in values.items():
        new = line(key, value)
        regex = re.compile(pattern.format(key=re.escape(key)), re.M)
        if regex.search(text):
            text = regex.sub(lambda m: m.group(1) + new, text, count=1)
        else:
            text = text.rstrip("\n") + "\n" + new + "\n"
    return text


def env_file(values):
    path = ROOT / ".env"
    if not path.exists():
        shutil.copy(ROOT / ".env.example", path)
        print("created .env from .env.example: set DB_PASSWORD, JWT_SECRET and FAUXNANCE_API_KEY in it")
    return path, rewrite(path.read_text(), values, r"^(){key}=.*$", lambda k, v: f"{k}={v}")


def configmap(values):
    path = ROOT / "k8s-tester" / "configmap.yaml"

    def line(key, value):
        value = str(value)
        return f'{key}: "{value}"' if value.isdigit() else f"{key}: {value}"

    return path, rewrite(path.read_text(), values, r"^(  ){key}:.*$", line)


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    check = "--check" in sys.argv[1:]
    cfg = yaml.safe_load((ROOT / "config" / "application.yaml").read_text())
    phase = args[0] if args else cfg["phase"]
    if phase not in PHASES:
        sys.exit(f"unknown phase '{phase}'; choose one of: {', '.join(PHASES)}")

    values = settings(cfg, phase)
    path, text = configmap(values) if phase == "eks" else env_file(values)
    name = path.relative_to(ROOT)
    changed = text != path.read_text()

    if check:
        if changed:
            sys.exit(f"{name} does not match config/application.yaml (phase {phase}); run python3 config/apply.py")
        print(f"{name} matches config/application.yaml (phase {phase})")
        return

    path.write_text(text)
    print(f"phase {phase} -> {name} ({'updated' if changed else 'already up to date'})")
    for key, value in values.items():
        print(f"  {key}={value}")
    if phase == "eks" and changed:
        print("Commit and push k8s-tester/configmap.yaml; the pipeline deploys it.")
    elif phase == "docker":
        print("Now: docker-compose up -d --build")
    elif phase == "local":
        print("Before starting a service: set -a; . ./.env; set +a")


if __name__ == "__main__":
    main()
