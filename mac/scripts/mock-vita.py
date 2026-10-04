#!/usr/bin/env python3
"""Pretend to be a PS Vita running the VitaPresence plugin, to test the Mac app or CLI without a Vita.

Every connection gets exactly what plugin/src/main.c sends: one 148-byte packet, then the connection is
closed. The foreground title changes every --cycle seconds.

Examples:
    scripts/mock-vita.py
    scripts/mock-vita.py --cycle 5 --titles "LiveArea,PCSE00120:Persona 4 Golden"
    scripts/mock-vita.py --port 40000   # vitapresence-cli --address 127.0.0.1 --port 40000 --client-id ...
"""

import argparse
import math
import socket
import struct
import sys
import time

MAGIC = 0xCAFECAFE
DEFAULT_PORT = 0xCAFE  # 51966
DEFAULT_TITLES = "LiveArea,PCSE00120:Persona 4 Golden,XMB:Adrenaline XMB Menu,PCSB00245:Gravity Rush"

# vitapresence_data_t: uint32 magic, int32 index, char titleid[10], char title[128], then 2 bytes of ARM EABI
# tail padding: 148 bytes on the wire. Like the plugin's `static vitapresence_data_t presence_data`, one
# zero-initialised buffer is reused for every connection: the padding stays zero, but the string fields keep
# stale bytes from earlier packets after their terminating NUL.
TITLE_ID_OFFSET, TITLE_ID_SIZE = 8, 10
TITLE_OFFSET, TITLE_SIZE = 18, 128
PACKET = bytearray(148)


class Title:
    """One entry of --titles. `title_id` is None for the LiveArea."""

    def __init__(self, title_id, name):
        self.title_id = title_id
        self.name = name

    @property
    def is_live_area(self):
        return self.title_id is None

    def __str__(self):
        if self.is_live_area:
            return "LiveArea"
        return "%s (%s)" % (self.name, self.title_id) if self.name else self.title_id


def parse_titles(text):
    """Parses "LiveArea,ID:Name,..." into Titles."""
    titles = []
    for item in text.split(","):
        item = item.strip()
        if item.lower() == "livearea":
            titles.append(Title(None, ""))
        elif ":" in item:
            title_id, name = item.split(":", 1)
            titles.append(Title(title_id.strip(), name.strip()))
        else:
            raise argparse.ArgumentTypeError("'%s' is neither LiveArea nor ID:Name" % item)
    return titles


def positive_seconds(text):
    try:
        value = float(text)
    except ValueError:
        value = math.nan
    if not (value > 0 and math.isfinite(value)):
        raise argparse.ArgumentTypeError("'%s' is not a positive number of seconds" % text)
    return value


def port_number(text):
    if not text.isdigit() or int(text) > 65535:
        raise argparse.ArgumentTypeError("'%s' is not a port number from 0 to 65535" % text)
    return int(text)


def write_field(offset, size, text):
    """Writes `text` like snprintf(field, size, "%s", text): at most size - 1 bytes plus a NUL. Long text is
    cut bytewise, possibly inside a UTF-8 sequence, as on the Vita. The rest of the field keeps old bytes."""
    data = text.encode("utf-8")[: size - 1]
    PACKET[offset : offset + len(data)] = data
    PACKET[offset + len(data)] = 0


def fill_packet(title):
    """Fills PACKET the way the plugin's server thread and get_fg_app() do, and returns its bytes."""
    # get_fg_app() clears only the first byte of each string field, and writes them only for an app.
    PACKET[TITLE_ID_OFFSET] = 0
    PACKET[TITLE_OFFSET] = 0
    index = 0
    if not title.is_live_area:
        write_field(TITLE_ID_OFFSET, TITLE_ID_SIZE, title.title_id)
        write_field(TITLE_OFFSET, TITLE_SIZE, title.name)
        index = 1  # app slot + 1; the foreground app is in the first slot
    struct.pack_into("<Ii", PACKET, 0, MAGIC, index)
    return bytes(PACKET)


def log(message):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), message), flush=True)


def serve(host, port, cycle, titles):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind((host, port))
    except OSError as error:
        sys.exit("mock-vita.py: can't listen on %s:%d: %s" % (host, port, error.strerror or error))
    server.listen(128)
    host, port = server.getsockname()
    log("Mock Vita listening on %s:%d, next title every %g s: %s" % (host, port, cycle, ", ".join(map(str, titles))))

    started = time.monotonic()
    while True:
        client, (peer_host, peer_port) = server.accept()
        title = titles[int((time.monotonic() - started) // cycle) % len(titles)]
        # Like the plugin: send without reading anything, then close.
        try:
            client.sendall(fill_packet(title))
            log("%s:%d <- %s" % (peer_host, peer_port, title))
        except OSError as error:
            log("%s:%d: send failed: %s" % (peer_host, peer_port, error.strerror or error))
        finally:
            client.close()


def main():
    parser = argparse.ArgumentParser(
        description="Emulate a PS Vita running the VitaPresence plugin: every connection gets one 148-byte "
        "packet describing the current title, then the connection is closed."
    )
    parser.add_argument("--host", default="127.0.0.1",
                        help="IPv4 address to listen on (default 127.0.0.1; 0.0.0.0 accepts other devices)")
    parser.add_argument("--port", type=port_number, default=DEFAULT_PORT,
                        help="TCP port (default %d, 0 picks a free one)" % DEFAULT_PORT)
    parser.add_argument("--cycle", type=positive_seconds, default=15.0, metavar="SECONDS",
                        help="seconds before switching to the next title (default 15)")
    parser.add_argument("--titles", type=parse_titles, default=parse_titles(DEFAULT_TITLES),
                        help='comma-separated "LiveArea" or "ID:Name" entries (default "%s")' % DEFAULT_TITLES)
    args = parser.parse_args()
    try:
        serve(args.host, args.port, args.cycle, args.titles)
    except KeyboardInterrupt:
        log("Stopped.")


if __name__ == "__main__":
    main()
