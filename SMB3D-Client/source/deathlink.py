"""DeathLink wire behavior and local death thresholds (1 means every death)."""
from collections import deque
import math
import time


def threshold(value):
    if isinstance(value, bool):
        raise ValueError('DeathLink amnesty must be a whole number from 1 to 100.')
    try:
        number = int(value)
    except (TypeError, ValueError):
        raise ValueError('DeathLink amnesty must be a whole number from 1 to 100.') from None
    if str(number) != str(value).strip() or not 1 <= number <= 100:
        raise ValueError('DeathLink amnesty must be a whole number from 1 to 100.')
    return number


class DeathLink:
    def __init__(self, source, enabled=False, amnesty=1, emit=lambda *args: None):
        self.source = source
        self.enabled = enabled
        self.amnesty = threshold(amnesty)
        self.count = 0
        self.emit = emit
        self.sent = deque(maxlen=256)
        self.seen = deque(maxlen=1024)

    def configure(self, enabled=None, amnesty=None):
        if enabled is not None and self.enabled != bool(enabled):
            self.enabled = bool(enabled)
            self.count = 0
        if amnesty is not None:
            value = threshold(amnesty)
            if value != self.amnesty:
                self.amnesty = value
                self.count = 0

    def local_death(self):
        if not self.enabled:
            return []
        self.count += 1
        if self.count < self.amnesty:
            self.emit('log', f'DeathLink amnesty: {self.count}/{self.amnesty} local deaths.')
            return []
        self.count = 0
        stamp = time.time()
        self.sent.append((stamp, self.source))
        self.emit('log', f'DeathLink sent after {self.amnesty} local death(s).')
        return [{'cmd': 'Bounce', 'tags': ['DeathLink'], 'data': {
            'time': stamp, 'source': self.source, 'cause': f'{self.source} died in Super Meat Boy 3D.'}}]

    def receive(self, packet):
        if not self.enabled or 'DeathLink' not in packet.get('tags', []):
            return
        data = packet.get('data', {})
        if not isinstance(data, dict):
            return
        stamp, source = data.get('time'), data.get('source')
        if isinstance(stamp, bool) or not isinstance(stamp, (float, int)) or not math.isfinite(stamp):
            return
        if not isinstance(source, str) or not source or source == self.source or (stamp, source) in self.sent:
            return
        identity = (stamp, source)
        if identity in self.seen:
            return
        self.seen.append(identity)
        self.emit('log', f'DeathLink received from {source}.')
        self.emit('deathlink', {'time': stamp, 'source': source})
