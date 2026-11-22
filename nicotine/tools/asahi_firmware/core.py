# SPDX-License-Identifier: MIT
# Minimal subset of AsahiLinux/asahi-installer asahi_firmware.core — just the
# FWFile class that wifi.py needs. Vendored so the payload build has no pip deps.
from hashlib import sha256


class FWFile(object):
    def __init__(self, name, data):
        self.name = name
        self.data = data
        self.sha = sha256(data).hexdigest()

    def __repr__(self):
        return f"FWFile({self.name!r}, <{self.sha[:16]}>)"

    def __eq__(self, other):
        if other is None:
            return False
        return self.sha == other.sha

    def __hash__(self):
        return hash(self.sha)
