"""Archipelago networking with an optional durable UE4SS file bridge."""
import json
import queue
import threading
import time
import uuid
import ssl
import traceback
import certifi
from pathlib import Path
from urllib.parse import urlsplit

from websockets.sync.client import connect
from deathlink import DeathLink, threshold

GAME = "Super Meat Boy 3D"


def tls_context():
    # Supply a bundled CA file instead of relying on OpenSSL installation paths.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.load_default_certs()
    context.load_verify_locations(cafile=certifi.where())
    return context


def server_uri(address):
    address = address.strip()
    if not address:
        raise ValueError("Enter a server address and port, such as archipelago.gg:42069.")
    explicit = "://" in address
    uri = address if explicit else "wss://" + address
    parsed = urlsplit(uri)
    if parsed.scheme not in {"ws", "wss"} or not parsed.hostname:
        raise ValueError("Use host:port, ws://host:port, or wss://host:port.")
    if parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in {"", "/"}:
        raise ValueError("Use only the server address and port; enter the password in its own field.")
    try:
        port = parsed.port
    except ValueError as error:
        raise ValueError("The port must be a number from 1 to 65535.") from error
    if port is None or port == 0:
        raise ValueError("Include a port, such as archipelago.gg:42069.")
    return uri, explicit


class Protocol:
    def __init__(self, slot, password, death_link, emit, client_uuid=None):
        self.slot_name = slot
        self.password = password or None
        self.death_link = death_link
        self.emit = emit
        self.uuid = client_uuid or str(uuid.uuid4())
        self.deaths = DeathLink(slot, death_link, emit=emit)
        self.connected = False
        self.items = []
        self.players = {}
        self.seed = ""
        self.team = None
        self.slot = None
        self.checked = set()
        self.total = 0
        self.sync_pending = False
        self.packages = {}
        self.game_packages = {}
        # The known local game's names are available even before the server's
        # data package arrives. Other games always use their own server package.
        try:
            contract = json.loads((Path(__file__).resolve().parent / 'client-contract-v1.json').read_text(encoding='utf-8'))
            self.game_packages[GAME] = {
                'item_name_to_id': contract['items'], 'location_name_to_id': contract['locations']}
        except (OSError, ValueError, KeyError):
            pass

    def tags(self):
        return ["AP"] + (["DeathLink"] if self.death_link else [])

    def set_death_link(self, value):
        self.death_link = bool(value)
        self.deaths.configure(enabled=value)
        return [{"cmd": "ConnectUpdate", "tags": self.tags()}] if self.connected else []

    def player_name(self, slot):
        return self.players.get(int(slot), f"Player {slot}")

    def name(self, kind, identifier, player):
        info = self.packages.get(str(player), {})
        return info.get(kind, {}).get(int(identifier), str(identifier))

    def handle(self, packet):
        cmd = packet.get("cmd")
        if cmd == "RoomInfo":
            self.seed = packet.get("seed_name", "")
            if GAME not in packet.get("games", [GAME]):
                self.emit("fatal", "This room has no Super Meat Boy 3D slot.")
                return []
            self.emit("status", "Authenticating…")
            games = packet.get('games') or list(packet.get('datapackage_checksums', {})) or [GAME]
            return [{"cmd": "GetDataPackage", "games": sorted(set(games))}, {
                "cmd": "Connect", "password": self.password, "game": GAME,
                "name": self.slot_name, "uuid": self.uuid,
                "version": {"major": 0, "minor": 6, "build": 8, "class": "Version"},
                "items_handling": 7, "tags": self.tags(), "slot_data": True,
            }]
        if cmd == "ConnectionRefused":
            errors = packet.get("errors", ["Unknown error"])
            self.emit("fatal", "Connection refused: " + ", ".join(errors))
        elif cmd == "Connected":
            slot_data = packet.get("slot_data", {})
            if slot_data.get("protocol_version") not in (1, 2):
                self.emit("fatal", "Unsupported or missing SMB3D slot protocol. Use a compatible SMB3D APWorld and client.")
                return []
            self.connected = True
            self.team, self.slot = packet["team"], packet["slot"]
            self.slot_info = packet.get("slot_info", {})
            self.checked = set(packet.get("checked_locations", []))
            self.total = len(self.checked | set(packet.get("missing_locations", [])))
            self.update_players(packet.get("players", []))
            self.emit("authenticated", {"seed": self.seed, "slot": self.slot, "team": self.team})
            self.emit("log", f"Connected as {self.slot_name}. Seed: {self.seed}")
            self.emit("checks", (len(self.checked), self.total))
            self.emit("tags", self.tags())
        elif cmd == "DataPackage":
            self.game_packages.update(packet.get("data", {}).get("games", {}))
        elif cmd == "ReceivedItems" and self.connected:
            index = packet["index"]
            if index == 0:
                self.items = list(packet["items"])
                self.sync_pending = False
            elif index == len(self.items):
                self.items.extend(packet["items"])
            else:
                if not self.sync_pending:
                    self.sync_pending = True
                    self.emit("log", "Item history mismatch; requesting a fresh copy.")
                    return [{"cmd": "Sync"}, {"cmd": "LocationChecks", "locations": []}]
                return []
            self.emit("items", list(self.items))
        elif cmd == "RoomUpdate":
            if "players" in packet:
                self.update_players(packet["players"])
            self.checked.update(packet.get("checked_locations", []))
            self.emit("checks", (len(self.checked), self.total))
        elif cmd == "PrintJSON":
            self.emit("log", self.render(packet.get("data", [])))
        elif cmd == "Print":
            self.emit("log", packet.get("text", ""))
        elif cmd == "InvalidPacket":
            self.emit("log", "Server rejected a packet: " + str(packet.get("text", packet.get("type", "unknown"))))
        elif cmd == 'Bounced' and self.connected:
            self.deaths.emit = self.emit
            self.deaths.receive(packet)
        return []

    def update_players(self, players):
        for player in players:
            if player.get("team") == self.team:
                self.players[player["slot"]] = player.get("alias", player.get("name", "Unknown"))

    def render(self, parts):
        text = []
        for part in parts:
            value = part.get("text", "")
            kind = part.get("type")
            try:
                if kind == "player_id":
                    value = self.player_name(value)
                elif kind in {"item_id", "location_id"}:
                    player = part.get("player", self.slot)
                    info = getattr(self, "slot_info", {}).get(str(player), {})
                    game = info.get("game", GAME)
                    table = getattr(self, "game_packages", {}).get(game, {}).get(
                        "item_name_to_id" if kind == "item_id" else "location_name_to_id", {})
                    value = next((name for name, code in table.items() if code == int(value)), value)
            except (ValueError, TypeError):
                pass
            text.append(str(value))
        return "".join(text)


class Connection:
    def __init__(self, events, bridge=None):
        self.events = events
        self.commands = queue.Queue()
        self.stop_event = threading.Event()
        self.thread = None
        self.bridge = bridge

    def emit(self, event, value):
        self.events.put((event, value))

    def start(self, address, slot, password, death_link, amnesty=1):
        uri, explicit = server_uri(address)
        if not slot.strip():
            raise ValueError("Enter your slot name.")
        if self.thread and self.thread.is_alive():
            raise ValueError("The previous connection is still closing. Try again in a moment.")
        self.stop_event.clear()
        self.commands = queue.Queue()
        amnesty = threshold(amnesty)
        self.thread = threading.Thread(target=self.run, args=(uri, explicit, slot.strip(), password, death_link, amnesty), daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()

    def set_death_link(self, value):
        self.commands.put(("death_link", value))

    def set_death_amnesty(self, value):
        self.commands.put(('death_amnesty', threshold(value)))

    def run(self, uri, explicit, slot, password, death_link, amnesty=1):
        identity = str(uuid.uuid4())
        attempt = 0
        while not self.stop_event.is_set():
            protocol = Protocol(slot, password, death_link, self.emit, identity)
            protocol.deaths.configure(amnesty=amnesty)
            refused = False
            try:
                self.emit("status", "Connecting…" if attempt == 0 else "Reconnecting…")
                try:
                    options = {"ssl": tls_context()} if uri.startswith("wss://") else {}
                    socket = connect(uri, open_timeout=8, close_timeout=1, proxy=None, max_size=8 * 1024 * 1024, **options)
                except Exception as tls_error:
                    if explicit or not uri.startswith("wss://") or self.stop_event.is_set() or isinstance(tls_error, (FileNotFoundError, ssl.SSLCertVerificationError)):
                        raise
                    self.emit("log", "TLS connection unavailable; trying this server's plain WebSocket endpoint.")
                    socket = connect("ws://" + uri[6:], open_timeout=8, close_timeout=1, proxy=None,
                                     max_size=8 * 1024 * 1024)
                with socket:
                    deadline = time.monotonic() + 20
                    while not self.stop_event.is_set():
                        while True:
                            try:
                                command, value = self.commands.get_nowait()
                            except queue.Empty:
                                break
                            if command == "death_link":
                                death_link = bool(value)
                                packets = protocol.set_death_link(value)
                                if packets:
                                    socket.send(json.dumps(packets))
                                    self.emit("tags", protocol.tags())
                                if self.bridge:
                                    self.bridge.configure_death_link(death_link)
                            elif command == 'death_amnesty':
                                amnesty = threshold(value)
                                protocol.deaths.configure(amnesty=amnesty)
                        if not protocol.connected and time.monotonic() > deadline:
                            raise TimeoutError("The server did not finish authentication within 20 seconds.")
                        if self.bridge:
                            try:
                                outgoing = self.bridge.poll()
                                protocol.deaths.emit = self.emit
                                for _death in self.bridge.drain_deaths():
                                    outgoing.extend(protocol.deaths.local_death())
                                if outgoing:
                                    socket.send(json.dumps(outgoing))
                            except OSError as error:
                                self.emit("log", f"Game bridge file unavailable ({type(error).__name__}); retrying.")
                        try:
                            message = socket.recv(timeout=0.2)
                        except TimeoutError:
                            continue
                        packets = json.loads(message)
                        if not isinstance(packets, list):
                            raise ValueError("Unexpected server message format.")
                        for packet in packets:
                            if packet.get("cmd") == "ConnectionRefused":
                                refused = True
                            # Treat fatal protocol validation failures like a refused login.
                            def emit(event, value):
                                nonlocal refused
                                if event == "fatal":
                                    refused = True
                                if event == 'deathlink' and self.bridge:
                                    self.bridge.receive_death(value)
                                self.emit(event, value)
                            protocol.emit = emit
                            responses = protocol.handle(packet)
                            if self.bridge and not refused:
                                if packet.get("cmd") == "Connected" and protocol.connected:
                                    self.bridge.bind(protocol.seed, protocol.team, protocol.slot, protocol.checked,
                                                     slot_data=packet.get('slot_data'))
                                    self.bridge.configure_death_link(death_link)
                                elif packet.get("cmd") == "ReceivedItems" and protocol.connected and not protocol.sync_pending:
                                    self.bridge.inventory(protocol.items)
                                elif packet.get("cmd") == "RoomUpdate" and protocol.connected:
                                    self.bridge.acknowledge(protocol.checked)
                            if responses:
                                socket.send(json.dumps(responses))
                            if refused:
                                break
                        if refused:
                            break
            except Exception as error:
                if not self.stop_event.is_set():
                    detail = str(error)
                    trace = traceback.format_exc()
                    if password:
                        detail = detail.replace(password, "[password removed]")
                        trace = trace.replace(password, "[password removed]")
                    self.emit("log", f"Connection interrupted ({type(error).__name__}): {detail}")
                    if self.bridge:
                        try:
                            diagnostic = self.bridge.directory / 'client-error.log'
                            with diagnostic.open('a', encoding='utf-8') as file:
                                file.write(time.strftime('%Y-%m-%d %H:%M:%S') + '\n' + trace + '\n')
                            self.emit('log', f'Diagnostic saved: {diagnostic}')
                        except OSError:
                            pass
            if self.bridge:
                try:
                    self.bridge.offline()
                except OSError:
                    pass
            if refused or self.stop_event.is_set():
                break
            self.emit("status", "Disconnected — retrying in 5 seconds…")
            self.emit("lost", None)
            attempt += 1
            self.stop_event.wait(5)
        self.emit("closed", None)
