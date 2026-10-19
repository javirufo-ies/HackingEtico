#!/bin/bash

# ==============================================================================
# SCRIPT DE LIMPIEZA Y RESTAURACIÓN - LAB WI-FI (INCLUYE WEP)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "[-] Ejecuta este script como root (sudo)."
  exit 1
fi

echo "[+] 1. Deteniendo procesos del laboratorio..."
pkill -9 hostapd 2>/dev/null || true
pkill -9 wpa_supplicant 2>/dev/null || true
pkill -9 nc 2>/dev/null || true
pkill -9 curl 2>/dev/null || true
pkill -9 ping 2>/dev/null || true

# Limpiar sockets de control de todos los escenarios (incluido WEP)
rm -rf /var/run/wpa_supplicant* 2>/dev/null || true

echo "[+] 2. Eliminando Network Namespaces (Open, WPA2, PMKID, Enterprise, WEP)..."
for ns in $(ip netns list | awk '{print $1}'); do
    if [[ "$ns" == ns_* ]]; then
        ip netns del "$ns" 2>/dev/null || true
        echo "  [✓] Namespace $ns eliminado"
    fi
done

echo "[+] 3. Descargando módulo simulado mac80211_hwsim..."
modprobe -r mac80211_hwsim 2>/dev/null || true

echo "[+] 4. Reiniciando gestor de red del sistema..."
systemctl restart NetworkManager 2>/dev/null || service network-manager restart 2>/dev/null || true

echo ""
echo "=========================================================================="
echo " [✓] ENTORNO RESTAURADO CORRECTAMENTE (TODOS LOS ESCENARIOS CERRADOS)"
echo "=========================================================================="
