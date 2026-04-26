"""
Cloudflare Operations — Casino Launch Support
Requires: pip install requests
Auth: Set CF_API_TOKEN and CF_ACCOUNT_ID environment variables.
"""

import os
import sys
import json
import socket
import ssl
import requests

CF_API_TOKEN = os.environ.get("CF_API_TOKEN", "")
CF_BASE = "https://api.cloudflare.com/client/v4"

HEADERS = {
    "Authorization": f"Bearer {CF_API_TOKEN}",
    "Content-Type": "application/json",
}


def _require_token():
    if not CF_API_TOKEN:
        print("ERROR: CF_API_TOKEN environment variable not set.")
        sys.exit(1)


def check_dns_propagation(domain: str):
    """Check if DNS resolves for the given domain."""
    print(f"Checking DNS propagation for {domain}...")
    try:
        records = socket.getaddrinfo(domain, 443)
        ips = sorted(set(r[4][0] for r in records))
        print(f"  Resolved to: {', '.join(ips)}")
        return ips
    except socket.gaierror as e:
        print(f"  DNS resolution FAILED: {e}")
        return []


def verify_ssl(domain: str):
    """Verify SSL certificate for the given domain."""
    print(f"Verifying SSL for {domain}...")
    try:
        ctx = ssl.create_default_context()
        with ctx.wrap_socket(socket.socket(), server_hostname=domain) as s:
            s.settimeout(10)
            s.connect((domain, 443))
            cert = s.getpeercert()
            print(f"  Issuer: {dict(x[0] for x in cert.get('issuer', []))}")
            print(f"  Expires: {cert.get('notAfter', 'unknown')}")
            return cert
    except Exception as e:
        print(f"  SSL verification FAILED: {e}")
        return None


def purge_zone_cache(zone_id: str):
    """Purge all cached content for a Cloudflare zone."""
    _require_token()
    print(f"Purging cache for zone {zone_id}...")
    resp = requests.post(
        f"{CF_BASE}/zones/{zone_id}/purge_cache",
        headers=HEADERS,
        json={"purge_everything": True},
    )
    data = resp.json()
    if data.get("success"):
        print("  Cache purged successfully.")
    else:
        print(f"  Purge FAILED: {json.dumps(data.get('errors', []), indent=2)}")
    return data


def list_zones():
    """List all zones in the Cloudflare account."""
    _require_token()
    resp = requests.get(f"{CF_BASE}/zones", headers=HEADERS, params={"per_page": 50})
    data = resp.json()
    if data.get("success"):
        for zone in data["result"]:
            print(f"  {zone['name']} — {zone['id']} ({zone['status']})")
    return data


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python cloudflare_ops.py check_dns <domain>")
        print("  python cloudflare_ops.py verify_ssl <domain>")
        print("  python cloudflare_ops.py purge_cache <zone_id>")
        print("  python cloudflare_ops.py list_zones")
        sys.exit(0)

    cmd = sys.argv[1]
    if cmd == "check_dns" and len(sys.argv) > 2:
        check_dns_propagation(sys.argv[2])
    elif cmd == "verify_ssl" and len(sys.argv) > 2:
        verify_ssl(sys.argv[2])
    elif cmd == "purge_cache" and len(sys.argv) > 2:
        purge_zone_cache(sys.argv[2])
    elif cmd == "list_zones":
        list_zones()
    else:
        print(f"Unknown command: {cmd}")
