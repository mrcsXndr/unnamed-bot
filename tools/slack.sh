#!/usr/bin/env bash
# Slack CLI wrapper
# Usage: bash tools/slack.sh <command> [args]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PROJECT_DIR/.env" ]; then
  export $(grep -v '^#' "$PROJECT_DIR/.env" | grep -v '^$' | xargs)
fi

if [ -z "${SLACK_USER_TOKEN:-}" ]; then
  echo "ERROR: SLACK_USER_TOKEN not set in .env" >&2
  exit 1
fi

PYTHON="${PYTHON:-python}"

slack_api() {
  local method="$1"; shift
  PYTHONIOENCODING=utf-8 "$PYTHON" -c "
import urllib.request, urllib.parse, json, sys
token = '$SLACK_USER_TOKEN'
method = '$method'
params = dict(p.split('=',1) for p in sys.argv[1:] if '=' in p)
url = f'https://slack.com/api/{method}?{urllib.parse.urlencode(params)}'
req = urllib.request.Request(url, headers={'Authorization': f'Bearer {token}'})
resp = json.loads(urllib.request.urlopen(req).read())
if not resp.get('ok'):
    print(f'ERROR: {resp.get(\"error\",\"unknown\")}', file=sys.stderr); sys.exit(1)
json.dump(resp, sys.stdout, indent=2, ensure_ascii=False)
" "$@"
}

case "${1:-help}" in
  channels)
    echo "=== Channels ==="
    slack_api conversations.list "types=public_channel,private_channel" "limit=50" | \
      PYTHONIOENCODING=utf-8 "$PYTHON" -c "
import json,sys
d=json.load(sys.stdin)
for c in sorted(d.get('channels',[]), key=lambda x: x.get('name','')):
    prefix = '#' if not c.get('is_private') else 'L'
    print(f'  {prefix} {c[\"name\"]} ({c[\"id\"]})')
" ;;
  dms)
    echo "=== DMs ==="
    slack_api conversations.list "types=im" "limit=30" | \
      PYTHONIOENCODING=utf-8 "$PYTHON" -c "
import json,sys,urllib.request
token='$SLACK_USER_TOKEN'
d=json.load(sys.stdin)
for c in d.get('channels',[]):
    uid=c.get('user','?')
    try:
        req=urllib.request.Request(f'https://slack.com/api/users.info?user={uid}',headers={'Authorization':f'Bearer {token}'})
        u=json.loads(urllib.request.urlopen(req).read())
        name=u.get('user',{}).get('real_name',uid)
    except: name=uid
    print(f'  @{name} ({c[\"id\"]})')
" ;;
  history)
    CHANNEL="${2:?channel_id required}"; LIMIT="${3:-20}"
    slack_api conversations.history "channel=$CHANNEL" "limit=$LIMIT" | \
      PYTHONIOENCODING=utf-8 "$PYTHON" -c "
import json,sys,datetime,urllib.request
token='$SLACK_USER_TOKEN'
d=json.load(sys.stdin); users={}
def get_user(uid):
    if uid not in users:
        try:
            req=urllib.request.Request(f'https://slack.com/api/users.info?user={uid}',headers={'Authorization':f'Bearer {token}'})
            u=json.loads(urllib.request.urlopen(req).read()); users[uid]=u.get('user',{}).get('real_name',uid)
        except: users[uid]=uid
    return users[uid]
for m in reversed(d.get('messages',[])):
    ts=datetime.datetime.fromtimestamp(float(m['ts'])).strftime('%Y-%m-%d %H:%M')
    print(f'  [{ts}] {get_user(m.get(\"user\",\"system\"))}: {m.get(\"text\",\"\")[:200]}')
" ;;
  search)
    QUERY="${2:?query required}"
    slack_api search.messages "query=$QUERY" "count=10" | \
      PYTHONIOENCODING=utf-8 "$PYTHON" -c "
import json,sys,datetime
d=json.load(sys.stdin)
for m in d.get('messages',{}).get('matches',[]):
    ts=datetime.datetime.fromtimestamp(float(m['ts'])).strftime('%Y-%m-%d %H:%M')
    print(f'  [{ts}] #{m.get(\"channel\",{}).get(\"name\",\"dm\")} @{m.get(\"username\",\"?\")}: {m.get(\"text\",\"\")[:150]}')
" ;;
  unread)
    echo "=== Unread channels ==="
    slack_api conversations.list "types=public_channel,private_channel,im,mpim" "limit=50" | \
      PYTHONIOENCODING=utf-8 "$PYTHON" -c "
import json,sys
d=json.load(sys.stdin)
unread=[c for c in d.get('channels',[]) if c.get('unread_count',0)>0]
for c in sorted(unread, key=lambda x: -x.get('unread_count',0)):
    print(f'  {c.get(\"name\",c.get(\"user\",\"dm\"))}: {c[\"unread_count\"]} unread ({c[\"id\"]})')
if not unread: print('  No unread messages')
" ;;
  *)
    echo "Usage: bash tools/slack.sh <command> [args]"
    echo "Commands: channels | dms | history <id> [limit] | search <query> | unread"
    ;;
esac
