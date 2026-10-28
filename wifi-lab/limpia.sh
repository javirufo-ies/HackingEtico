#!/bin/bash

# ==============================================================================
# SCRIPT DE LIMPIEZA Y RESTAURACIÓN INTEGRAL - LAB WI-FI (6 ESCENARIOS)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "[-] Ejecuta este script como root (sudo)."
  exit 1
fi

echo "[+] 1. Deteniendo procesos y generadores de tráfico del laboratorio..."
pkill -9 hostapd 2>/dev/null || true
pkill -9 wpa_supplicant 2>/dev/null || true
pkill -9 nc 2>/dev/null || true
pkill -9 curl 2>/dev/null || true
pkill -9 ping 2>/dev/null || true
pkill -9 arping 2>/dev/null || true
pkill -9 -f "wlan_cli_ent reassociate" 2>/dev/null || true
pkill -9 airodump-ng 2>/dev/null || true
pkill -9 aireplay-ng 2>/dev/null || true
pkill -9 aircrack-ng 2>/dev/null || true

# Limpiar sockets de control de wpa_supplicant y hostapd
rm -rf /var/run/wpa_supplicant* 2>/dev/null || true
rm -rf /var/run/hostapd* 2>/dev/null || true

echo "[+] 2. Limpiando tablas ARP/Caché de vecinos de red..."
ip neigh flush all dev wlan0 2>/dev/null || true
ip neigh flush all 2>/dev/null || true

echo "[+] 3. Eliminando interfaces de monitoreo de alumnos (wlan*mon, mon*)..."
for iface in $(ip link show | grep -E 'wlan[0-9]+mon|mon[0-9]+' | awk -F': ' '{print $2}'); do
    iw dev "$iface" del 2>/dev/null || ip link set "$iface" down 2>/dev/null || true
    echo "  [✓] Interfaz de monitoreo $iface eliminada"
done

echo "[+] 4. Eliminando Network Namespaces (Open, WPA2, PMKID, Enterprise, WEP)..."
for ns in $(ip netns list | awk '{print $1}'); do
    if [[ "$ns" == ns_* ]]; then
        ip netns del "$ns" 2>/dev/null || true
        echo "  [✓] Namespace $ns eliminado"
    fi
done

echo "[+] 5. Descargando módulo simulado mac80211_hwsim..."
modprobe -r mac80211_hwsim 2>/dev/null || true

echo "[+] 6. Limpiando archivos temporales de captura y diccionarios del alumno..."
rm -f /tmp/wep_* /tmp/wpa2_* /tmp/pmkid_* /tmp/open_* /tmp/*.cap /tmp/*.pcap /tmp/*.csv /tmp/*.netxml 2>/dev/null || true

echo "[+] 7. Borrando configuraciones residuales del lab (Anti-Cheat)..."
# despliegue.sh las borra al final; si se interrumpió antes, quedarían en disco
# (incluido eap_user.conf con la contraseña Enterprise). Los certificados de
# enterprise/certs se conservan para reutilizarlos en el siguiente despliegue.
rm -f /opt/wifi-lab/*/*.conf 2>/dev/null || true

echo "[+] 8. Reiniciando gestor de red del sistema..."
systemctl restart NetworkManager 2>/dev/null || service network-manager restart 2>/dev/null || true

echo ""
echo "=========================================================================="
echo " [✓] ENTORNO RESTAURADO Y LIMPIO (PROCESOS, NAMESPACES, ARP Y TEMP BORRADOS)"
echo "=========================================================================="
