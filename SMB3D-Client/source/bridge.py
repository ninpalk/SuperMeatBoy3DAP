"""Durable, seed/slot-scoped file bridge to the UE4SS mod."""
import hashlib
import json
import os
from pathlib import Path
import time
import tempfile


def default_bridge_directory():
    return Path(os.environ.get("SMB3D_BRIDGE_DIR", str(
        Path(os.environ.get("LOCALAPPDATA", Path.home())) / "SuperMeatBoy3DArchipelago" / "bridge")))


class GameBridge:
    def __init__(self, contract, directory=None, emit=lambda *args: None):
        self.directory = Path(directory) if directory is not None else default_bridge_directory()
        self.directory.mkdir(parents=True, exist_ok=True)
        (self.directory / "runs").mkdir(exist_ok=True)
        self.item_names = {identifier: name for name, identifier in contract["items"].items()}
        self.location_names = {identifier: name for name, identifier in contract["locations"].items()}
        self.catalog_location_ids = dict(contract['locations'])
        self.location_ids = dict(self.catalog_location_ids)
        self.goal = "all_bosses"
        self.warpzonesanity = False
        self.bandagesanity = True  # Legacy rooms always had bandages.
        self.darksanity = True  # Legacy rooms included dark levels unconditionally.
        self.speedsanity = False
        self.emit = emit
        self.session = None
        self.run = None
        self.last_send = 0
        self.last_payload = None
        self.last_heartbeat = None
        self.connected = False
        self.inventory_ready = False
        self.goal_sent = False
        self.death_link_enabled = False
        self.death_offset = 0
        self.local_deaths = []
        self.incoming_deaths = []

    def atomic_write(self, path, content):
        # Unique temporary names prevent collisions if an older client is still running.
        descriptor, filename = tempfile.mkstemp(prefix=path.name + '.', suffix='.tmp', dir=path.parent)
        temporary = Path(filename)
        try:
            with os.fdopen(descriptor, 'w', encoding='utf-8', newline='\n') as file:
                file.write(content)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)

    def persist(self):
        if self.session:
            self.atomic_write(self.directory / "runs" / (self.session + ".json"),
                              json.dumps(self.run, indent=2) + "\n")

    def bind(self, seed, team, slot, checked, slot_data=None):
        slot_data = slot_data or {}
        self.goal = slot_data.get('goal', 'all_bosses')
        if self.goal == 'all_five_bosses':
            self.goal = 'all_bosses'
        if self.goal not in ('all_bosses', 'beat_the_game'):
            raise ValueError('Unsupported SMB3D goal: ' + str(self.goal))
        self.warpzonesanity = bool(slot_data.get('warpzonesanity', False))
        self.bandagesanity = bool(slot_data.get('bandagesanity', True))
        self.darksanity = bool(slot_data.get('darksanity', True))
        self.speedsanity = bool(slot_data.get('speedsanity', False))
        server_locations = slot_data.get('location_ids', self.catalog_location_ids)
        self.location_ids = {name: identifier for name, identifier in self.catalog_location_ids.items()
                             if server_locations.get(name) == identifier
                             and (self.speedsanity or not name.endswith(' A+'))
                             and (self.darksanity or not name.startswith('Dark '))
                             and (self.bandagesanity or not name.endswith(' Bandage'))
                             and (self.warpzonesanity or not name.endswith(' Warp Zone'))}
        active_ids = set(self.location_ids.values())
        self.session = hashlib.sha256(json.dumps([seed, team, slot]).encode()).hexdigest()
        file = self.directory / "runs" / (self.session + ".json")
        self.run = {"seed": seed, "team": team, "slot": slot, "items": [], "checked": [], "pending": []}
        if file.exists():
            stored = json.loads(file.read_text(encoding="utf-8"))
            if [stored.get("seed"), stored.get("team"), stored.get("slot")] == [seed, team, slot]:
                self.run = stored
        if self.run.get('goal', 'all_bosses') != self.goal:
            self.run['credits_reached'] = False
        self.run['goal'] = self.goal
        locally_known = (set(self.run["checked"]) | set(self.run["pending"])) & active_ids
        self.run["checked"] = sorted(set(checked) & active_ids)
        self.run["pending"] = sorted(locally_known - set(checked))
        # AP omits ReceivedItems entirely when the inventory is empty. Start from
        # empty on authentication; any server item history replaces it next.
        self.run["items"] = []
        self.run.setdefault('tofu_cursor', 0)
        self.run.setdefault('tofu_pending', [])
        self.write_tofu_traps()
        self.connected = True
        self.inventory_ready = True
        self.goal_sent = False
        self.local_deaths = []
        self.incoming_deaths = []
        self.reset_death_cursor()
        self.write_incoming_deaths()
        self.last_send = 0
        self.persist()
        self.publish()
        self.emit("log", f"Game bridge selected seed {seed}, slot {slot}.")

    def inventory(self, items):
        if not self.run:
            return
        cursor = self.run.setdefault('tofu_cursor', 0)
        trap_id = next((identifier for identifier, name in self.item_names.items() if name == 'Tofu Trap'), None)
        for index, entry in enumerate(items[cursor:], start=cursor):
            if entry['item'] == trap_id:
                self.run.setdefault('tofu_pending', []).append(index)
                self.emit('log', f'Tofu Trap received (item #{index + 1}); waiting for a playable level.')
        self.run['tofu_cursor'] = max(cursor, len(items))
        self.run["items"] = sorted({entry["item"] for entry in items if entry["item"] in self.item_names})
        self.inventory_ready = True
        self.persist()
        self.write_tofu_traps()
        self.publish()

    def write_tofu_traps(self):
        if self.session and self.run:
            pending = self.run.get('tofu_pending', [])
            self.atomic_write(self.directory / ('tofu-in-' + self.session + '.txt'),
                              'TOFUTRAP1\n' + ''.join(f'{index}\n' for index in pending))

    def poll_tofu_traps(self):
        if not self.session or not self.run:
            return
        try:
            acknowledged = set((self.directory / ('tofu-acks-' + self.session + '.txt'))
                               .read_text(encoding='utf-8').splitlines())
        except FileNotFoundError:
            acknowledged = set()
        pending = self.run.get('tofu_pending', [])
        remaining = [index for index in pending if str(index) not in acknowledged]
        if remaining != pending:
            self.run['tofu_pending'] = remaining
            self.persist()
            self.write_tofu_traps()

    def acknowledge(self, checked):
        if not self.run:
            return
        self.run["checked"] = sorted(set(self.run["checked"]) | set(checked))
        self.run["pending"] = sorted(set(self.run["pending"]) - set(self.run["checked"]))
        self.persist()
        self.publish()

    def offline(self):
        self.connected = False
        self.inventory_ready = False
        self.local_deaths = []
        self.incoming_deaths = []
        self.write_incoming_deaths()
        self.publish()

    def publish(self):
        if not self.run:
            return
        lines = ["APBRIDGE1", "session\t" + self.session,
                 "status\t" + ("connected" if self.connected and self.inventory_ready else "offline"),
                 'death_link\t' + ('1' if self.connected and self.death_link_enabled else '0')]
        lines.append('goal\t' + self.goal)
        lines.append('warpzonesanity\t' + ('1' if self.warpzonesanity else '0'))
        lines.append('bandagesanity\t' + ('1' if self.bandagesanity else '0'))
        lines.append('darksanity\t' + ('1' if self.darksanity else '0'))
        lines.append('speedsanity\t' + ('1' if self.speedsanity else '0'))
        lines.extend("item\t" + self.item_names[identifier] for identifier in self.run["items"] if identifier in self.item_names)
        lines.extend("check\t" + self.location_names[identifier]
                     for identifier in sorted(set(self.run["checked"]) | set(self.run["pending"]))
                     if identifier in self.location_names)
        payload = "\n".join(lines) + "\n"
        if payload != self.last_payload:
            self.atomic_write(self.directory / "state.txt", payload)
            self.last_payload = payload

    def reset_death_cursor(self):
        if not self.session:
            return
        file = self.directory / ('deaths-' + self.session + '.txt')
        self.death_offset = file.stat().st_size if file.exists() else 0

    def configure_death_link(self, enabled):
        if self.death_link_enabled != bool(enabled):
            self.reset_death_cursor()
            self.local_deaths = []
            self.incoming_deaths = []
            self.write_incoming_deaths()
        self.death_link_enabled = bool(enabled)
        self.publish()

    def receive_death(self, data):
        if not self.session or not self.connected or not self.death_link_enabled:
            return
        identity = hashlib.sha256(json.dumps([data['time'], data['source']]).encode()).hexdigest()
        self.incoming_deaths.append((identity, time.time()))
        self.write_incoming_deaths()

    def write_incoming_deaths(self):
        if self.session:
            self.atomic_write(self.directory / ('death-in-' + self.session + '.txt'),
                              ''.join(f'{identity}\t{created}\n' for identity, created in self.incoming_deaths))

    def poll_deaths(self):
        file = self.directory / ('deaths-' + self.session + '.txt')
        if not self.connected or not self.death_link_enabled:
            self.reset_death_cursor()
            self.local_deaths = []
            return
        try:
            with file.open('rb') as stream:
                if stream.seek(0, 2) < self.death_offset:
                    self.death_offset = 0
                stream.seek(self.death_offset)
                raw = stream.read(65536)
                last_line = raw.rfind(b'\n')
                if last_line >= 0:
                    self.death_offset += last_line + 1
                    for line in raw[:last_line].decode('utf-8', errors='replace').splitlines():
                        fields = line.split('\t')
                        try:
                            if len(fields) == 2 and 0 <= time.time() - float(fields[1]) < 10:
                                self.local_deaths.append(fields[0])
                        except ValueError:
                            pass
        except FileNotFoundError:
            pass
        ack_file = self.directory / ('death-acks-' + self.session + '.txt')
        try:
            acknowledged = set(ack_file.read_text(encoding='utf-8').splitlines())
        except FileNotFoundError:
            acknowledged = set()
        pending = [(identity, created) for identity, created in self.incoming_deaths
                   if identity not in acknowledged and time.time() - created < 10]
        if pending != self.incoming_deaths:
            self.incoming_deaths = pending
            self.write_incoming_deaths()

    def drain_deaths(self):
        deaths, self.local_deaths = self.local_deaths, []
        return deaths

    def poll(self):
        try:
            heartbeat = json.loads((self.directory / "heartbeat.json").read_text(encoding="utf-8"))
            status = "Game mod active" if time.time() - heartbeat.get("time", 0) < 5 else "Waiting for game mod"
        except (OSError, ValueError, TypeError):
            status = "Waiting for game mod"
        if status != self.last_heartbeat:
            self.last_heartbeat = status
            self.emit("bridge", status)
        if not self.run:
            return []
        self.poll_tofu_traps()
        self.poll_deaths()
        journal = self.directory / ("checks-" + self.session + ".txt")
        try:
            raw = journal.read_text(encoding="utf-8")
        except FileNotFoundError:
            raw = ""
        # An interrupted final line is retried after the writer finishes it.
        names = raw.split("\n")[:-1]
        found = {self.location_ids[name] for name in names if name in self.location_ids}
        pending = sorted((set(self.run["pending"]) | found) - set(self.run["checked"]))
        if pending != self.run["pending"]:
            self.run["pending"] = pending
            self.persist()
            self.publish()
            self.emit("log", f"Queued {len(pending)} game checks for this run.")
        if not self.connected or not self.inventory_ready:
            return []
        packets = []
        if pending and time.monotonic() - self.last_send > 1:
            packets.append({"cmd": "LocationChecks", "locations": pending})
            self.last_send = time.monotonic()
        boss_ids = {self.location_ids[f"World {w} Boss"] for w in range(1, 6)}
        if self.goal == 'beat_the_game':
            ending = self.directory / ('ending-' + self.session + '.txt')
            try:
                if ending.read_text(encoding='utf-8') == 'CREDITS1\ncredits\n':
                    if not self.run.get('credits_reached'):
                        self.run['credits_reached'] = True
                        self.persist()
            except FileNotFoundError:
                pass
            # Credits are distinct from the World 5 boss check. The check must
            # also be server-acknowledged; no goal from the fight alone.
            completed = (bool(self.run.get('credits_reached')) and
                         self.location_ids['World 5 Boss'] in set(self.run['checked']))
        else:
            completed = boss_ids <= set(self.run['checked'])
        if not self.goal_sent and completed:
            packets.append({"cmd": "StatusUpdate", "status": 30})
            self.goal_sent = True
        return packets
