"""
Google Workspace Integration - Calendar, Gmail, Tasks, Sheets, Drive
Requires: pip install google-api-python-client google-auth-httplib2 google-auth-oauthlib
Auth: Place credentials.json in project root. Token is cached as token.json.
"""

import json
import os
import sys
import datetime
import io
from pathlib import Path

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload

SCOPES = [
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/tasks",
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/drive",
]

PRIORITY_DOMAINS = ["fadir.com", "njordvantage.com", "xndr.io"]

ROOT = Path(__file__).resolve().parent.parent
CREDS_PATH = ROOT / "credentials.json"
TOKEN_PATH = ROOT / "token.json"


def authenticate():
    """Authenticate with Google APIs. Opens browser on first run."""
    creds = None
    if TOKEN_PATH.exists():
        creds = Credentials.from_authorized_user_file(str(TOKEN_PATH), SCOPES)
        if creds and not creds.has_scopes(SCOPES):
            creds = None
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            if not CREDS_PATH.exists():
                raise FileNotFoundError(
                    f"Missing {CREDS_PATH}. Download from Google Cloud Console."
                )
            flow = InstalledAppFlow.from_client_secrets_file(str(CREDS_PATH), SCOPES)
            creds = flow.run_local_server(port=8085)
        TOKEN_PATH.write_text(creds.to_json())
    return creds


def authenticate_keep():
    """Authenticate with Keep scope (separate token)."""
    return _do_auth(KEEP_SCOPES, KEEP_TOKEN_PATH)


# ---------------------------------------------------------------------------
# Calendar
# ---------------------------------------------------------------------------

def calendar_events(time_min, time_max, max_results=None):
    """Fetch calendar events in a time range."""
    creds = authenticate()
    service = build("calendar", "v3", credentials=creds)

    kwargs = dict(
        calendarId="primary",
        timeMin=time_min,
        timeMax=time_max,
        singleEvents=True,
        orderBy="startTime",
    )
    if max_results:
        kwargs["maxResults"] = max_results

    result = service.events().list(**kwargs).execute()
    events = result.get("items", [])
    if not events:
        print("No events found.")
        return []
    for event in events:
        start = event["start"].get("dateTime", event["start"].get("date"))
        print(f"  {start} - {event.get('summary', '(no title)')}")
    return events


def calendar_today():
    now = datetime.datetime.now(datetime.UTC)
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + datetime.timedelta(days=1)
    return calendar_events(
        start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        end.strftime("%Y-%m-%dT%H:%M:%SZ"),
    )


def calendar_tomorrow():
    now = datetime.datetime.now(datetime.UTC)
    start = now.replace(hour=0, minute=0, second=0, microsecond=0) + datetime.timedelta(days=1)
    end = start + datetime.timedelta(days=1)
    return calendar_events(
        start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        end.strftime("%Y-%m-%dT%H:%M:%SZ"),
    )


def calendar_week():
    now = datetime.datetime.now(datetime.UTC)
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + datetime.timedelta(days=7)
    return calendar_events(
        start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        end.strftime("%Y-%m-%dT%H:%M:%SZ"),
    )


def calendar_next():
    now = datetime.datetime.now(datetime.UTC)
    return calendar_events(
        now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        (now + datetime.timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        max_results=1,
    )


# ---------------------------------------------------------------------------
# Gmail
# ---------------------------------------------------------------------------

def gmail_list_messages(query, max_results=20):
    """List Gmail messages matching a query, with metadata."""
    creds = authenticate()
    service = build("gmail", "v1", credentials=creds)

    result = service.users().messages().list(
        userId="me", q=query, maxResults=max_results
    ).execute()
    messages = result.get("messages", [])

    if not messages:
        print("No messages found.")
        return []

    output = []
    for msg in messages:
        detail = service.users().messages().get(
            userId="me", id=msg["id"], format="metadata"
        ).execute()
        headers = {h["name"]: h["value"] for h in detail["payload"]["headers"]}
        entry = {
            "id": msg["id"],
            "from": headers.get("From", ""),
            "subject": headers.get("Subject", ""),
            "date": headers.get("Date", ""),
        }
        print(f"  [{entry['date']}] {entry['from']} - {entry['subject']}")
        output.append(entry)
    return output


def gmail_priority():
    domain_query = " OR ".join(f"from:@{d}" for d in PRIORITY_DOMAINS)
    return gmail_list_messages(f"is:unread ({domain_query})")


def gmail_unread():
    return gmail_list_messages("is:unread")


def gmail_search(query):
    return gmail_list_messages(query)


def gmail_recent(count=10):
    return gmail_list_messages("", max_results=count)


# ---------------------------------------------------------------------------
# Tasks
# ---------------------------------------------------------------------------

def tasks_lists():
    """List all task lists."""
    creds = authenticate()
    service = build("tasks", "v1", credentials=creds)
    task_lists = service.tasklists().list().execute().get("items", [])
    if not task_lists:
        print("No task lists found.")
        return []
    for tl in task_lists:
        print(f"  {tl['id']} - {tl['title']}")
    return task_lists


def tasks_list(list_id="@default"):
    """List open tasks in a task list."""
    creds = authenticate()
    service = build("tasks", "v1", credentials=creds)
    tasks = service.tasks().list(
        tasklist=list_id, showCompleted=False, showHidden=False
    ).execute().get("items", [])
    if not tasks:
        print("No open tasks.")
        return []
    for t in tasks:
        due_str = f" - due {t['due'][:10]}" if t.get("due") else ""
        print(f"  [{t.get('id','')}] {t.get('title','')}{due_str}")
    return tasks


def tasks_add(title, due=None, list_id="@default"):
    """Add a new task."""
    creds = authenticate()
    service = build("tasks", "v1", credentials=creds)
    body = {"title": title}
    if due:
        body["due"] = f"{due}T00:00:00.000Z"
    result = service.tasks().insert(tasklist=list_id, body=body).execute()
    print(f"Task added: {title} (id: {result.get('id', '')})")
    return result


def tasks_complete(task_id, list_id="@default"):
    """Complete a task."""
    creds = authenticate()
    service = build("tasks", "v1", credentials=creds)
    result = service.tasks().patch(
        tasklist=list_id, task=task_id, body={"status": "completed"}
    ).execute()
    print(f"Task completed: {task_id}")
    return result


# ---------------------------------------------------------------------------
# Sheets
# ---------------------------------------------------------------------------

def sheets_read(sheet_id, range_str):
    """Read cells from a sheet."""
    creds = authenticate()
    service = build("sheets", "v4", credentials=creds)
    result = service.spreadsheets().values().get(
        spreadsheetId=sheet_id, range=range_str
    ).execute()
    rows = result.get("values", [])
    print(json.dumps(rows, indent=2, ensure_ascii=True))
    return rows


def sheets_update(sheet_id, range_str, values_json):
    """Update cells in a sheet."""
    creds = authenticate()
    service = build("sheets", "v4", credentials=creds)
    values = json.loads(values_json)
    body = {"values": values}
    result = service.spreadsheets().values().update(
        spreadsheetId=sheet_id,
        range=range_str,
        valueInputOption="USER_ENTERED",
        body=body,
    ).execute()
    print(f"Updated {result.get('updatedCells', 0)} cells")
    return result


def sheets_append(sheet_id, range_str, values_json):
    """Append rows to a sheet."""
    creds = authenticate()
    service = build("sheets", "v4", credentials=creds)
    values = json.loads(values_json)
    body = {"values": values}
    result = service.spreadsheets().values().append(
        spreadsheetId=sheet_id,
        range=range_str,
        valueInputOption="USER_ENTERED",
        body=body,
    ).execute()
    updates = result.get("updates", {})
    print(f"Appended {updates.get('updatedRows', 0)} rows")
    return result


# ---------------------------------------------------------------------------
# Drive
# ---------------------------------------------------------------------------

def drive_search(query):
    """Search Drive files by name."""
    creds = authenticate()
    service = build("drive", "v3", credentials=creds)
    result = service.files().list(
        q=f"name contains '{query}' and trashed=false",
        orderBy="modifiedTime desc",
        pageSize=20,
        fields="files(id,name,mimeType,modifiedTime,webViewLink)",
    ).execute()
    files = result.get("files", [])
    if not files:
        print("No files found.")
        return []
    for f in files:
        print(f"  {f['modifiedTime'][:10]} | {f['name']} | {f.get('webViewLink', f['id'])}")
    return files


def drive_recent(count=10):
    """List recent Drive files."""
    creds = authenticate()
    service = build("drive", "v3", credentials=creds)
    result = service.files().list(
        orderBy="modifiedTime desc",
        pageSize=count,
        fields="files(id,name,mimeType,modifiedTime,webViewLink)",
    ).execute()
    files = result.get("files", [])
    if not files:
        print("No files found.")
        return []
    for f in files:
        print(f"  {f['modifiedTime'][:10]} | {f['name']} | {f.get('webViewLink', f['id'])}")
    return files


def drive_download(file_id, output_path):
    """Download a file from Drive."""
    creds = authenticate()
    service = build("drive", "v3", credentials=creds)
    request = service.files().get_media(fileId=file_id)
    fh = io.BytesIO()
    downloader = MediaIoBaseDownload(fh, request)
    done = False
    while not done:
        status, done = downloader.next_chunk()
        if status:
            print(f"  Download {int(status.progress() * 100)}%")
    out = Path(output_path)
    out.write_bytes(fh.getvalue())
    print(f"Downloaded to {output_path}")


def drive_list_folder(folder_id):
    """List contents of a Drive folder."""
    creds = authenticate()
    service = build("drive", "v3", credentials=creds)
    result = service.files().list(
        q=f"'{folder_id}' in parents and trashed=false",
        orderBy="modifiedTime desc",
        pageSize=50,
        fields="files(id,name,mimeType,modifiedTime)",
    ).execute()
    files = result.get("files", [])
    if not files:
        print("No files found.")
        return []
    for f in files:
        print(f"  {f['modifiedTime'][:10]} | {f['name']} ({f['mimeType']})")
    return files


# ---------------------------------------------------------------------------
# Keep (API requires enterprise service account — use browser instead)
# ---------------------------------------------------------------------------

def keep_create(text, title=None):
    print("Keep API requires enterprise service account with domain-wide delegation.")
    print("Use browser: python tools/browser.py goto https://keep.google.com")
    sys.exit(1)


def keep_list():
    print("Keep API requires enterprise service account with domain-wide delegation.")
    print("Use browser: python tools/browser.py goto https://keep.google.com")
    sys.exit(1)


def keep_search(query):
    print("Keep API requires enterprise service account with domain-wide delegation.")
    print("Use browser: python tools/browser.py goto https://keep.google.com")
    sys.exit(1)
    if not matches:
        print(f"No notes matching '{query}'.")
    return matches


# ---------------------------------------------------------------------------
# CLI dispatcher
# ---------------------------------------------------------------------------

def print_usage():
    print("Google Workspace CLI")
    print()
    print("Usage: google_workspace.py <command> [args...]")
    print()
    print("Commands:")
    print("  morning                          - Daily briefing (calendar + emails + tasks)")
    print("  calendar-today                   - Today's events")
    print("  calendar-tomorrow                - Tomorrow's events")
    print("  calendar-week                    - This week's events (7 days)")
    print("  calendar-next                    - Next upcoming event")
    print("  gmail-priority                   - Unread emails from priority domains")
    print("  gmail-unread                     - All unread emails")
    print("  gmail-search <query>             - Search emails")
    print("  gmail-recent [count]             - Recent emails (default 10)")
    print("  tasks-lists                      - List all task lists")
    print("  tasks-list [list_id]             - List open tasks (default: @default)")
    print("  tasks-add <title> [--due DATE] [--list LIST_ID]")
    print("  tasks-complete <task_id> [list_id]")
    print("  sheets-read <sheet_id> <range>   - Read cells")
    print("  sheets-update <sheet_id> <range> <values_json>")
    print("  sheets-append <sheet_id> <range> <values_json>")
    print("  drive-search <query>             - Search Drive files")
    print("  drive-recent [count]             - Recent Drive files")
    print("  drive-download <file_id> <path>  - Download file")
    print("  drive-list <folder_id>           - List folder contents")
    print("  keep-create <text>               - Create note (requires Workspace)")
    print("  keep-list                        - List notes (requires Workspace)")
    print("  keep-search <query>              - Search notes (requires Workspace)")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"

    # --- Morning briefing ---
    if cmd == "morning":
        print("=== Daily Schedule ===")
        calendar_today()
        print("\n=== Priority Emails ===")
        gmail_priority()
        print("\n=== Open Tasks ===")
        tasks_list()

    # --- Calendar ---
    elif cmd == "calendar-today":
        calendar_today()
    elif cmd == "calendar-tomorrow":
        calendar_tomorrow()
    elif cmd == "calendar-week":
        calendar_week()
    elif cmd == "calendar-next":
        calendar_next()

    # Legacy alias
    elif cmd == "calendar":
        calendar_today()

    # --- Gmail ---
    elif cmd == "gmail-priority":
        gmail_priority()
    elif cmd == "gmail-unread":
        gmail_unread()
    elif cmd == "gmail-search":
        if len(sys.argv) < 3:
            print("Usage: google_workspace.py gmail-search <query>")
            sys.exit(1)
        gmail_search(sys.argv[2])
    elif cmd == "gmail-recent":
        count = int(sys.argv[2]) if len(sys.argv) > 2 else 10
        gmail_recent(count)

    # Legacy alias
    elif cmd == "emails":
        gmail_priority()

    # --- Tasks ---
    elif cmd == "tasks-lists":
        tasks_lists()
    elif cmd == "tasks-list":
        list_id = sys.argv[2] if len(sys.argv) > 2 else "@default"
        tasks_list(list_id)
    elif cmd == "tasks-add":
        if len(sys.argv) < 3:
            print("Usage: google_workspace.py tasks-add <title> [--due DATE] [--list LIST_ID]")
            sys.exit(1)
        title = sys.argv[2]
        due = None
        list_id = "@default"
        i = 3
        while i < len(sys.argv):
            if sys.argv[i] == "--due" and i + 1 < len(sys.argv):
                due = sys.argv[i + 1]
                i += 2
            elif sys.argv[i] == "--list" and i + 1 < len(sys.argv):
                list_id = sys.argv[i + 1]
                i += 2
            else:
                i += 1
        tasks_add(title, due=due, list_id=list_id)
    elif cmd == "tasks-complete":
        if len(sys.argv) < 3:
            print("Usage: google_workspace.py tasks-complete <task_id> [list_id]")
            sys.exit(1)
        task_id = sys.argv[2]
        list_id = sys.argv[3] if len(sys.argv) > 3 else "@default"
        tasks_complete(task_id, list_id)

    # Legacy alias
    elif cmd == "tasks":
        tasks_list()

    # --- Sheets ---
    elif cmd == "sheets-read":
        if len(sys.argv) < 4:
            print("Usage: google_workspace.py sheets-read <sheet_id> <range>")
            sys.exit(1)
        sheets_read(sys.argv[2], sys.argv[3])
    elif cmd == "sheets-update":
        if len(sys.argv) < 5:
            print("Usage: google_workspace.py sheets-update <sheet_id> <range> <values_json>")
            sys.exit(1)
        sheets_update(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == "sheets-append":
        if len(sys.argv) < 5:
            print("Usage: google_workspace.py sheets-append <sheet_id> <range> <values_json>")
            sys.exit(1)
        sheets_append(sys.argv[2], sys.argv[3], sys.argv[4])

    # Legacy alias
    elif cmd == "sheet":
        if len(sys.argv) < 4:
            print("Usage: google_workspace.py sheet <sheet_id> <tab>")
        else:
            sheets_read(sys.argv[2], f"{sys.argv[3]}!A1:Z100")

    # --- Drive ---
    elif cmd == "drive-search":
        if len(sys.argv) < 3:
            print("Usage: google_workspace.py drive-search <query>")
            sys.exit(1)
        drive_search(sys.argv[2])
    elif cmd == "drive-recent":
        count = int(sys.argv[2]) if len(sys.argv) > 2 else 10
        drive_recent(count)
    elif cmd == "drive-download":
        if len(sys.argv) < 4:
            print("Usage: google_workspace.py drive-download <file_id> <output_path>")
            sys.exit(1)
        drive_download(sys.argv[2], sys.argv[3])
    elif cmd == "drive-list":
        if len(sys.argv) < 3:
            print("Usage: google_workspace.py drive-list <folder_id>")
            sys.exit(1)
        drive_list_folder(sys.argv[2])

    # --- Keep ---
    elif cmd == "keep-create":
        if len(sys.argv) < 3:
            print("Usage: google_workspace.py keep-create <text>")
            sys.exit(1)
        keep_create(sys.argv[2])
    elif cmd == "keep-list":
        keep_list()
    elif cmd == "keep-search":
        if len(sys.argv) < 3:
            print("Usage: google_workspace.py keep-search <query>")
            sys.exit(1)
        keep_search(sys.argv[2])

    # --- Help ---
    else:
        print_usage()
        if cmd != "help":
            sys.exit(1)
