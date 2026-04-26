#!/usr/bin/env python3
"""Google OAuth2 authentication helper for the bot.
Handles the OAuth flow and stores credentials for gws CLI and Python API access.
"""
import json
import sys
from pathlib import Path
from google_auth_oauthlib.flow import InstalledAppFlow

SCOPES = [
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/documents",
    "https://www.googleapis.com/auth/presentations",
    "https://www.googleapis.com/auth/tasks",
    "openid",
    "https://www.googleapis.com/auth/userinfo.email",
]

CRED_DIR = Path(__file__).parent.parent / ".credentials" / "gws"
CLIENT_SECRET = CRED_DIR / "client_secret.json"
TOKEN_FILE = CRED_DIR / "token.json"
GWS_CREDS = Path.home() / ".config" / "gws" / "credentials.json"


def main():
    if not CLIENT_SECRET.exists():
        print(f"ERROR: {CLIENT_SECRET} not found")
        sys.exit(1)

    print("Starting OAuth flow — browser will open...")
    flow = InstalledAppFlow.from_client_secrets_file(str(CLIENT_SECRET), SCOPES)
    creds = flow.run_local_server(port=8085, open_browser=False, prompt="consent", access_type="offline")

    # Save token locally
    token_data = {
        "token": creds.token,
        "refresh_token": creds.refresh_token,
        "token_uri": creds.token_uri,
        "client_id": creds.client_id,
        "client_secret": creds.client_secret,
        "scopes": list(creds.scopes),
    }
    TOKEN_FILE.write_text(json.dumps(token_data, indent=2))
    print(f"Token saved to {TOKEN_FILE}")

    # Also save in gws format so gws CLI can use it
    GWS_CREDS.parent.mkdir(parents=True, exist_ok=True)
    gws_data = {
        "installed": True,
        "access_token": creds.token,
        "refresh_token": creds.refresh_token,
        "token_uri": creds.token_uri,
        "client_id": creds.client_id,
        "client_secret": creds.client_secret,
        "scopes": list(creds.scopes),
    }
    GWS_CREDS.write_text(json.dumps(gws_data, indent=2))
    print(f"gws credentials saved to {GWS_CREDS}")
    print("Done! You're authenticated.")


if __name__ == "__main__":
    main()
