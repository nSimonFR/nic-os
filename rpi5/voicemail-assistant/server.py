#
# Voicemail webhook server — receives inbound call notifications from Daily,
# creates a room, and spawns a Pipecat bot to handle the call.
#
# Daily's SIP interconnect forwards inbound calls here as POST /call.
# This server creates a Daily room with SIP dial-in, then spawns the bot
# process to join that room.
#

import os
import sys
import time
import json
import subprocess
import urllib.request

from http.server import HTTPServer, BaseHTTPRequestHandler
from loguru import logger

DAILY_API_KEY = os.environ.get("DAILY_API_KEY", "")
DAILY_API_URL = "https://api.daily.co/v1"
BOT_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bot.py")
LISTEN_PORT = int(os.environ.get("VOICEMAIL_PORT", "8340"))


def daily_api(endpoint: str, method: str = "GET", data: dict | None = None) -> dict:
    """Make a Daily REST API call."""
    url = f"{DAILY_API_URL}/{endpoint}"
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {DAILY_API_KEY}",
            "Content-Type": "application/json",
        },
        method=method,
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def create_room_for_call(caller_id: str) -> dict:
    """Create a Daily room with SIP enabled for the inbound call."""
    room = daily_api("rooms", "POST", {
        "properties": {
            "exp": int(time.time()) + 300,  # 5 min expiry
            "enable_dialout": False,
            "sip": {
                "display_name": caller_id or "Unknown",
                "sip_mode": "dial-in",
                "num_endpoints": 1,
                "codecs": {"audio": ["OPUS"]},
            },
        },
    })
    logger.info(f"Created room: {room['name']} for caller: {caller_id}")
    return room


def create_meeting_token(room_name: str) -> str:
    """Create a meeting token for the bot to join the room."""
    resp = daily_api("meeting-tokens", "POST", {
        "properties": {
            "room_name": room_name,
            "exp": int(time.time()) + 300,
            "is_owner": True,
        },
    })
    return resp["token"]


def spawn_bot(room_url: str, token: str, caller_id: str):
    """Spawn the voicemail bot as a subprocess."""
    env = {**os.environ}
    cmd = [sys.executable, BOT_SCRIPT, room_url, token, caller_id]
    logger.info(f"Spawning bot for room {room_url}")
    subprocess.Popen(
        cmd,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )


class CallHandler(BaseHTTPRequestHandler):
    """HTTP handler for inbound call webhooks."""

    def do_POST(self):
        if self.path == "/call":
            self._handle_inbound_call()
        else:
            self.send_error(404)

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_error(404)

    def _handle_inbound_call(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(content_length)) if content_length else {}

        caller_id = body.get("From", body.get("from", "Unknown"))
        call_id = body.get("callId", body.get("call_id", ""))
        call_domain = body.get("callDomain", body.get("call_domain", ""))

        logger.info(f"Inbound call from {caller_id} (call_id={call_id})")

        try:
            room = create_room_for_call(caller_id)
            token = create_meeting_token(room["name"])
            spawn_bot(room["url"], token, caller_id)

            # Return dial-in settings so Daily can bridge the SIP call into the room
            response = {
                "room_url": room["url"],
                "token": token,
                "dialin_settings": {
                    "call_id": call_id,
                    "call_domain": call_domain,
                },
            }
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())

        except Exception as e:
            logger.error(f"Failed to handle call: {e}")
            self.send_error(500, str(e))

    def log_message(self, format, *args):
        logger.info(f"{self.client_address[0]} - {format % args}")


def main():
    server = HTTPServer(("127.0.0.1", LISTEN_PORT), CallHandler)
    logger.info(f"Voicemail webhook server listening on 127.0.0.1:{LISTEN_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Server stopped")
        server.server_close()


if __name__ == "__main__":
    main()
