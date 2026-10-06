#!/usr/bin/env python3
"""Pretend to be a PS Vita running the VitaPresence plugin, to test the Mac app or CLI without a Vita.

Every connection gets exactly what plugin/src/main.c sends: one packet, then the connection is closed. The
foreground title changes every --cycle seconds.

A title can carry a content ID ("ID:Name:ContentID"). If any title has one, the mock acts like plugin 1.1:
every packet is 184 bytes, with the content ID at byte 146 (all zero for titles without one). Otherwise it
acts like plugin 1.0 and sends 148 bytes.

Examples:
    scripts/mock-vita.py
    scripts/mock-vita.py --cycle 5 --titles "LiveArea,PCSE00120:Persona 4 Golden"
    scripts/mock-vita.py --titles "PCSE00120:Persona 4 Golden:UP0005-PCSE00120_00-PERSONA4GOLDEN01"
    scripts/mock-vita.py --port 40000   # vitapresence-cli --address 127.0.0.1 --port 40000
"""

import argparse
import math
import re
import socket
import struct
import sys
import time

MAGIC = 0xCAFECAFE
DEFAULT_PORT = 0xCAFE  # 51966
DEFAULT_TITLES = (
    "LiveArea,PCSE00120:Persona 4 Golden:UP0005-PCSE00120_00-PERSONA4GOLDEN01,XMB:Adrenaline XMB Menu,"
    "PCSA00011:Gravity Rush"
)

# vitapresence_data_t: uint32 magic, int32 index, char titleid[10], char title[128], then in plugin 1.1
# char contentid[37] and 1 byte of tail padding (184 bytes), or in plugin 1.0 2 bytes of tail padding (148
# bytes). Plugin 1.0 reuses one zero-initialised buffer for every connection, like
# `static vitapresence_data_t presence_data`: the padding stays zero, but the string fields keep stale bytes
# from earlier packets after their terminating NUL. Plugin 1.1 rebuilds the packet from zero every time.
TITLE_ID_OFFSET, TITLE_ID_SIZE = 8, 10
TITLE_OFFSET, TITLE_SIZE = 18, 128
CONTENT_ID_OFFSET, CONTENT_ID_SIZE = 146, 37
PACKET_1_0 = bytearray(148)
PACKET_1_1_LENGTH = 184
# The only content IDs plugin 1.1 sends: XXYYYY-TTTTNNNNN_NN-LLLLLLLLLLLLLLLL, letters and digits.
CONTENT_ID = re.compile(r"[A-Za-z0-9]{6}-[A-Za-z0-9]{9}_[A-Za-z0-9]{2}-[A-Za-z0-9]{16}")


class Title:
    """One entry of --titles. `title_id` is None for the LiveArea; `content_id` is None when it has none."""

    def __init__(self, title_id, name, content_id=None):
        self.title_id = title_id
        self.name = name
        self.content_id = content_id

    @property
    def is_live_area(self):
        return self.title_id is None

    def __str__(self):
        if self.is_live_area:
            return "LiveArea"
        text = "%s (%s)" % (self.name, self.title_id) if self.name else self.title_id
        return "%s [%s]" % (text, self.content_id) if self.content_id else text


def parse_titles(text):
    """Parses "LiveArea,ID:Name,ID:Name:ContentID,..." into Titles. A name may contain ":"; only a last part
    shaped like a content ID is taken as one."""
    titles = []
    for item in text.split(","):
        item = item.strip()
        if item.lower() == "livearea":
            titles.append(Title(None, ""))
        elif ":" in item:
            title_id, name = item.split(":", 1)
            content_id = None
            if ":" in name:
                rest, last = name.rsplit(":", 1)
                if CONTENT_ID.fullmatch(last.strip()):
                    name, content_id = rest, last.strip()
            titles.append(Title(title_id.strip(), name.strip(), content_id))
        else:
            raise argparse.ArgumentTypeError("'%s' is neither LiveArea nor ID:Name[:ContentID]" % item)
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


def utf8_prefix(data, limit):
    """The first `limit` bytes of `data`, without a UTF-8 sequence cut off at the end (as plugin 1.1 cuts)."""
    data = data[:limit]
    start = len(data)
    while start > 0 and len(data) - start < 3 and data[start - 1] & 0xC0 == 0x80:
        start -= 1
    if start > 0:
        lead = data[start - 1]
        need = 2 if 0xC2 <= lead <= 0xDF else 3 if 0xE0 <= lead <= 0xEF else 4 if 0xF0 <= lead <= 0xF4 else 0
        if len(data) - (start - 1) < need:
            return data[: start - 1]
    return data


def write_field(packet, offset, size, text, whole_characters):
    """Writes `text` like snprintf(field, size, "%s", text): at most size - 1 bytes plus a NUL. Long text is
    cut bytewise as plugin 1.0 does, possibly inside a UTF-8 sequence, or on a character boundary as plugin
    1.1 does (`whole_characters`). The rest of the field keeps its old bytes."""
    data = text.encode("utf-8")
    data = utf8_prefix(data, size - 1) if whole_characters else data[: size - 1]
    packet[offset : offset + len(data)] = data
    packet[offset + len(data)] = 0


def fill_packet(title, sends_content_id):
    """Builds the packet the plugin's server thread sends for `title`: like plugin 1.1 when
    `sends_content_id`, else like plugin 1.0 and its get_fg_app()."""
    if sends_content_id:
        packet = bytearray(PACKET_1_1_LENGTH)
    else:
        # Plugin 1.0's get_fg_app() clears only the first byte of each string field.
        packet = PACKET_1_0
        packet[TITLE_ID_OFFSET] = 0
        packet[TITLE_OFFSET] = 0
    index = 0
    if not title.is_live_area:
        write_field(packet, TITLE_ID_OFFSET, TITLE_ID_SIZE, title.title_id, sends_content_id)
        write_field(packet, TITLE_OFFSET, TITLE_SIZE, title.name, sends_content_id)
        if title.content_id:
            write_field(packet, CONTENT_ID_OFFSET, CONTENT_ID_SIZE, title.content_id, True)
        index = 1  # app slot + 1; the foreground app is in the first slot
    struct.pack_into("<Ii", packet, 0, MAGIC, index)
    return bytes(packet)


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
    sends_content_id = any(title.content_id for title in titles)
    log("Mock Vita (plugin %s) listening on %s:%d, next title every %g s: %s" % (
        "1.1" if sends_content_id else "1.0", host, port, cycle, ", ".join(map(str, titles))))

    started = time.monotonic()
    while True:
        client, (peer_host, peer_port) = server.accept()
        title = titles[int((time.monotonic() - started) // cycle) % len(titles)]
        # Like the plugin: send without reading anything, then close.
        try:
            client.sendall(fill_packet(title, sends_content_id))
            log("%s:%d <- %s" % (peer_host, peer_port, title))
        except OSError as error:
            log("%s:%d: send failed: %s" % (peer_host, peer_port, error.strerror or error))
        finally:
            client.close()


def main():
    parser = argparse.ArgumentParser(
        description="Emulate a PS Vita running the VitaPresence plugin: every connection gets one packet "
        "describing the current title, then the connection is closed. With a content ID on any title, packets "
        "are 184 bytes like plugin 1.1's, otherwise 148 bytes like plugin 1.0's."
    )
    parser.add_argument("--host", default="127.0.0.1",
                        help="IPv4 address to listen on (default 127.0.0.1; 0.0.0.0 accepts other devices)")
    parser.add_argument("--port", type=port_number, default=DEFAULT_PORT,
                        help="TCP port (default %d, 0 picks a free one)" % DEFAULT_PORT)
    parser.add_argument("--cycle", type=positive_seconds, default=15.0, metavar="SECONDS",
                        help="seconds before switching to the next title (default 15)")
    parser.add_argument("--titles", type=parse_titles, default=parse_titles(DEFAULT_TITLES),
                        help='comma-separated "LiveArea", "ID:Name" or "ID:Name:ContentID" entries '
                        '(default "%s")' % DEFAULT_TITLES)
    args = parser.parse_args()
    try:
        serve(args.host, args.port, args.cycle, args.titles)
    except KeyboardInterrupt:
        log("Stopped.")


if __name__ == "__main__":
    main()
