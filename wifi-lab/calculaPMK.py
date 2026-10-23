#!/usr/bin/env python3
"""Calcula la PMK de WPA/WPA2 a partir de un SSID y un passphrase.

PMK = PBKDF2-HMAC-SHA1(passphrase, SSID, 4096 iteraciones, 32 bytes)

Uso:
    ./calc_pmk.py <SSID> <passphrase>

Ejemplos:
    ./calc_pmk.py he_wpa2 dragonfly
    ./calc_pmk.py he_pmkid chocolate
"""

import sys
import hashlib
import binascii


def calcular_pmk(ssid: str, passphrase: str) -> str:
    """Devuelve la PMK (64 caracteres hex) para un SSID y passphrase dados."""
    pmk = hashlib.pbkdf2_hmac("sha1", passphrase.encode(), ssid.encode(), 4096, 32)
    return binascii.hexlify(pmk).decode()


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Uso: {sys.argv[0]} <SSID> <passphrase>", file=sys.stderr)
        print(f"Ejemplo: {sys.argv[0]} he_wpa2 dragonfly", file=sys.stderr)
        return 1

    ssid = sys.argv[1]
    passphrase = sys.argv[2]

    # WPA exige entre 8 y 63 caracteres de passphrase; aviso, no error.
    if not (8 <= len(passphrase) <= 63):
        print(f"[!] Aviso: el passphrase tiene {len(passphrase)} caracteres "
              "(WPA exige entre 8 y 63).", file=sys.stderr)

    pmk = calcular_pmk(ssid, passphrase)

    print(f"SSID       : {ssid}")
    print(f"Passphrase : {passphrase}")
    print(f"PMK        : {pmk}")
    print()
    print("Para hostapd.conf -> wpa_psk=" + pmk)
    print('Para wpa.conf     -> psk=' + pmk + "   (sin comillas = PMK en hex)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
