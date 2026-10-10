#!/usr/bin/env bash
# ============================================================
#  GHOST PANEL v3.1.1 by Jorge Barrios
#  Administracion profesional de VPS (Ubuntu / Debian)
#  Uso:  sudo bash ghost-panel.sh  |  ghostpanel
# ============================================================

set -uo pipefail
IFS=$'\n\t'

# ---------- LOCALE UTF-8 (critico para ${#s} y padding visual) ----------
# Sin esto, en Termux con LANG=C las lineas de la UI no se alinean.
for _loc in C.UTF-8 en_US.UTF-8 es_AR.UTF-8 es_ES.UTF-8 es_MX.UTF-8; do
    if locale -a 2>/dev/null | grep -qx "$_loc"; then
        export LANG="$_loc" LC_ALL="$_loc"
        break
    fi
done
unset _loc

# ---------- PALETA ----------
RS='\033[0m'
BD='\033[1m'
DM='\033[2m'
CR='\033[1;31m'
CG='\033[1;32m'
CY='\033[1;33m'
CB='\033[1;34m'
CM='\033[1;35m'
CC='\033[1;36m'
CW='\033[1;37m'
C_DIM='\033[38;5;240m'
C_LBL='\033[38;5;245m'
C_VAL='\033[38;5;255m'
C_ACC='\033[38;5;81m'
C_OK='\033[38;5;77m'
C_WARN='\033[38;5;214m'
C_ERR='\033[38;5;203m'
C_FRM='\033[38;5;61m'
C_FRM2='\033[38;5;99m'

# ---------- CONFIG ----------
CONF_FILE='/etc/ghost-panel.conf'
if [[ ! -f "$CONF_FILE" ]]; then
    cat > "$CONF_FILE" <<'CONFEOF'
LICENSE_URL=https://vps-licencias.jorgebarriosmpya.workers.dev
REPO_RAW=https://raw.githubusercontent.com/pitubarrios/vps-manager/refs/heads/main/ghost-panel.sh
PREFIJO_KEY=VPSJB1
PANEL_COMPACT=0
PANEL_THEME=ghost
CONFEOF
    chmod 600 "$CONF_FILE"
fi

# shellcheck disable=SC1090
source "$CONF_FILE"
LICENSE_URL="${LICENSE_URL:-}"
REPO_RAW="${REPO_RAW:-}"
PREFIJO_KEY="${PREFIJO_KEY:-VPSJB1}"
PANEL_COMPACT="${PANEL_COMPACT:-0}"

KEY_FILE='/etc/vps-manager.key'
PERM_FILE='/etc/vps-license.permanent'
LOG_PANEL='/var/log/ghost-panel.log'
USUARIOS_DIR='/etc/vps-users'
LIMITS_DIR='/etc/vps-limits'
TRAF_DIR='/etc/vps-trafico'
PROTECTED_FILE='/etc/ghost-panel.protected'

if [[ ! -f "$PROTECTED_FILE" ]]; then
    cat > "$PROTECTED_FILE" <<'PROTEOF'
root daemon bin sys sync games man lp mail news uucp proxy www-data backup
list irc gnats nobody systemd-network systemd-resolve systemd-timesync
syslog messagebus _apt uuidd tcpdump sshd landscape pollinate ubuntu
debian admin ec2-user cloud-user vpsmgr ghostpanel dnstt
PROTEOF
    chmod 644 "$PROTECTED_FILE"
fi

# ---------- TRAP ----------
TMP_FILES=()
cleanup(){
    local f
    for f in "${TMP_FILES[@]:-}"; do [[ -n "$f" ]] && rm -f "$f" 2>/dev/null; done
}
trap cleanup EXIT INT TERM

mktmp(){
    local f; f=$(mktemp "$@") || return 1
    TMP_FILES+=("$f")
    printf '%s' "$f"
}

# ---------- CORE ----------
vps_log(){
    local NIV=${1:-INFO}; shift || true
    mkdir -p "$(dirname "$LOG_PANEL")" 2>/dev/null
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$NIV" "$*" >> "$LOG_PANEL" 2>/dev/null || true
}

OK(){   printf '%b▸ OK%b   %s\n' "$C_OK" "$RS" "$1"; }
ERR(){  printf '%b▸ ERR%b  %s\n' "$C_ERR" "$RS" "$1" >&2; }
INFO(){ printf '%b▸ INFO%b %s\n' "$C_ACC" "$RS" "$1"; }
WARN(){ printf '%b▸ WARN%b %s\n' "$C_WARN" "$RS" "$1"; }

PAUSA(){ printf '\n%b  Presiona ENTER para continuar...%b\n' "$C_LBL" "$RS"; read -r _; }

pkill_user(){
    local u="${1:-}"
    [[ -z "$u" || "$u" == "root" ]] && return 0
    pkill -u "$u" 2>/dev/null || true
}

user_home(){ getent passwd "$1" 2>/dev/null | cut -d: -f6; }

# machine_hash: ID estable del servidor.
# Orden: /etc/machine-id -> /etc/hostname -> /var/lib/dbus/machine-id -> ID persistido.
machine_hash(){
    local src="" cache="" dir=""
    if [[ -r /etc/machine-id && -s /etc/machine-id ]]; then
        src=$(cat /etc/machine-id 2>/dev/null)
    elif [[ -r /etc/hostname && -s /etc/hostname ]]; then
        src=$(cat /etc/hostname 2>/dev/null)
    elif [[ -r /var/lib/dbus/machine-id && -s /var/lib/dbus/machine-id ]]; then
        src=$(cat /var/lib/dbus/machine-id 2>/dev/null)
    else
        # Fallback persistente: si nada existe (Termux, contenedores raros)
        for dir in /etc /var/lib "$HOME" /tmp; do
            [[ -n "$dir" && -w "$dir" ]] && { cache="$dir/.vps-machine-id"; break; }
        done
        if [[ -z "$cache" ]]; then
            src="unknown-$(uname -n)-$(date +%s)"
        else
            if [[ ! -s "$cache" ]]; then
                { hostname 2>/dev/null; \
                  cat /proc/sys/kernel/random/uuid 2>/dev/null; \
                  date +%s; } | sha256sum | cut -c1-32 > "$cache" 2>/dev/null
                chmod 600 "$cache" 2>/dev/null || true
            fi
            src=$(cat "$cache" 2>/dev/null)
        fi
    fi
    [[ -z "$src" ]] && src="fallback-$(uname -n)"
    printf '%s' "$src" | sha256sum | cut -c1-12
}

require_root(){
    [[ $EUID -ne 0 ]] && { printf '%bNecesita root.%b\n' "$C_ERR" "$RS"; exit 1; }
}

get_ipv4(){
    local ip
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
    [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s' "$ip"
}

check_deps(){
    local missing=() cmd
    for cmd in bash python3 curl wget openssl systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ! command -v iptables >/dev/null 2>&1 && ! command -v nft >/dev/null 2>&1; then
        missing+=("iptables/nft")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        printf '%bFaltan dependencias:%b %s\n' "$C_ERR" "$RS" "${missing[*]}"
        return 1
    fi
    return 0
}

fw_backend(){
    if command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
        echo nft
    else
        echo iptables
    fi
}

# ============================================================
#  UI FRAMEWORK v3.1.1
# ============================================================
BC=()

push_crumb(){ BC+=("$1"); }
pop_crumb(){  [[ ${#BC[@]} -gt 0 ]] && unset 'BC[-1]'; }
crumbs(){
    local s="" i
    for i in "${BC[@]:-}"; do s+=" $i ›"; done
    printf '%s' "${s# }"
}

clear_if_tty(){ [[ -t 1 ]] && clear; }

# vis_width: ancho visual (en celdas de terminal) de una cadena con ANSI.
# Requiere locale UTF-8 (forzado arriba). Maneja wide-chars tipo emoji/CJK.
vis_width(){
    local s="$1" w=0 i c cp len
    s=$(printf '%s' "$s" | sed 's/\x1b\[[0-9;]*m//g')
    len=${#s}
    for ((i=0; i<len; i++)); do
        c="${s:i:1}"
        cp=$(printf '%d' "'$c" 2>/dev/null) || { w=$((w+1)); continue; }
        if (( cp >= 0x1F000 && cp <= 0x1FFFF )); then
            w=$((w+2))
        elif (( cp >= 0x1100 && cp <= 0x115F )) || \
             (( cp >= 0x2E80 && cp <= 0xA4CF )) || \
             (( cp >= 0xAC00 && cp <= 0xD7A3 )) || \
             (( cp >= 0xF900 && cp <= 0xFAFF )) || \
             (( cp >= 0xFE30 && cp <= 0xFE4F )) || \
             (( cp >= 0xFF00 && cp <= 0xFF60 )) || \
             (( cp >= 0xFFE0 && cp <= 0xFFE6 )); then
            w=$((w+2))
        else
            w=$((w+1))
        fi
    done
    printf '%d' "$w"
}

# pad_vis: rellena con espacios ASCII hasta 'target' celdas visuales.
# Usa printf ' ' iterativo (inmune a %*s y a locales C/POSIX).
pad_vis(){
    local s="$1" target="$2"
    local vw p i
    vw=$(vis_width "$s")
    p=$(( target - vw ))
    (( p < 0 )) && p=0
    printf '%s' "$s"
    for ((i=0; i<p; i++)); do printf ' '; done
}

ui_line(){ local n=${1:-60} c=${2:-$C_FRM}; local s=""; local i; for ((i=0;i<n;i++)); do s+="─"; done; printf '%b%s%b' "$c" "$s" "$RS"; }
ui_top(){ printf '%b╭%s╮%b\n' "$C_FRM" "$(ui_line 60 $C_FRM)" "$RS"; }
ui_mid(){ printf '%b├%s┤%b\n' "$C_FRM" "$(ui_line 60 $C_FRM)" "$RS"; }
ui_bot(){ printf '%b╰%s╯%b\n' "$C_FRM" "$(ui_line 60 $C_FRM)" "$RS"; }

ui_row(){
    local raw="$1"
    printf '%b│%b %s %b│%b\n' "$C_FRM" "$RS" "$(pad_vis "$raw" 58)" "$C_FRM" "$RS"
}

opt(){
    if [[ $# -ge 4 ]]; then
        local c1 c2
        c1=$(printf '%b[%b%s%b]%b %s' "$C_LBL" "$C_ACC" "$1" "$C_LBL" "$RS" "$2")
        c2=$(printf '%b[%b%s%b]%b %s' "$C_LBL" "$C_ACC" "$3" "$C_LBL" "$RS" "$4")
        ui_row "$(pad_vis "$c1" 27)$c2"
    else
        ui_row "$(printf '%b[%b%s%b]%b %s' "$C_LBL" "$C_ACC" "$1" "$C_LBL" "$RS" "$2")"
    fi
}

ui_center(){
    local txt="$1"
    local vw; vw=$(vis_width "$txt")
    local p=$(( (58 - vw) / 2 ))
    ((p<0)) && p=0
    printf '%b│%b %*s%s%*s %b│%b\n' "$C_FRM" "$RS" "$p" "" "$txt" "$((58 - p - vw))" "" "$C_FRM" "$RS"
}

subtop(){
    local title="$1"
    local fill=$(( 56 - ${#title} - 2 ))
    ((fill<1)) && fill=1
    printf '\n%b╭─%b %b%s%b %b%s╮%b\n' \
        "$C_FRM" "$RS" "$C_FRM2$BD" "$title" "$RS" \
        "$C_FRM" "$(ui_line $fill $C_FRM)" "$RS"
}

botline(){ printf '%b╰%s╯%b\n\n' "$C_FRM" "$(ui_line 60 $C_FRM)" "$RS"; }

prompt(){ printf '  %b▸%b %b%s%b %b>%b ' "$C_FRM2" "$RS" "$C_LBL" "${1:-Opcion}" "$RS" "$C_FRM2" "$RS"; }

# Barra visual tipo [████░░░░░░]  20 celdas
barra(){
    local pct="${1:-0}" ancho="${2:-20}" color="${3:-$C_OK}"
    pct="${pct%\%}"
    pct=$(printf '%.0f' "$pct" 2>/dev/null) || pct=0
    case "$pct" in ''|*[!0-9-]*) pct=0 ;; esac
    ((pct<0)) && pct=0
    ((pct>100)) && pct=100
    local llenos=$(( pct * ancho / 100 ))
    local vacios=$(( ancho - llenos ))
    local s=""
    local i
    for ((i=0;i<llenos;i++)); do s+="█"; done
    for ((i=0;i<vacios;i++)); do s+="░"; done
    printf '%b%s%b' "$color" "$s" "$RS"
}

# ---------- HEADER ----------
header(){
    clear_if_tty
    local ram_total ram_used_mb ram_pct cpu_pct disk_pct online lic="-" ipv4 osver kern uptime
    ram_total=$(free -m | awk '/Mem:/{print $2}')
    ram_used_mb=$(free -m | awk '/Mem:/{print $3}')
    ram_pct=$(free | awk '/Mem:/{printf "%d", $3*100/$2}')
    [[ -z "$ram_pct" ]] && ram_pct=0
    cpu_pct=$(top -bn1 2>/dev/null | awk '/%Cpu/{printf "%d", 100-$8}')
    [[ -z "$cpu_pct" ]] && cpu_pct=0
    disk_pct=$(df -h / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    [[ -z "$disk_pct" ]] && disk_pct=0
    online=$(who 2>/dev/null | wc -l)
    ipv4=$(get_ipv4)
    osver=$(lsb_release -rs 2>/dev/null || echo '?')
    kern=$(uname -r | cut -d- -f1)
    uptime=$(uptime -p 2>/dev/null | sed 's/^up //' || echo "-")

    if [[ "${LICENSE_EXP:-0}" == "0" ]]; then
        lic="permanente"
    elif [[ -n "${LICENSE_EXP:-}" ]]; then
        local d=$(( (LICENSE_EXP - $(date +%s)) / 86400 )); ((d<0)) && d=0
        lic="${d} dias"
    fi

    local ram_c="$C_OK"
    [[ "$ram_pct" -gt 70 ]] && ram_c="$C_WARN"
    [[ "$ram_pct" -gt 90 ]] && ram_c="$C_ERR"
    local disk_c="$C_OK"
    [[ "$disk_pct" -gt 70 ]] && disk_c="$C_WARN"
    [[ "$disk_pct" -gt 90 ]] && disk_c="$C_ERR"
    local cpu_c="$C_OK"
    [[ "$cpu_pct" -gt 80 ]] && cpu_c="$C_WARN"

    local ram_bar cpu_bar disk_bar
    ram_bar=$(barra "$ram_pct" 20 "$ram_c")
    cpu_bar=$(barra "$cpu_pct" 20 "$cpu_c")
    disk_bar=$(barra "$disk_pct" 20 "$disk_c")

    printf '\n'
    ui_top
    local title
    title=$(printf '%b◆%b %bGHOST PANEL%b  %b·%b  %bv3.1.1%b' "$C_FRM2" "$RS" "$BD$CW" "$RS" "$C_LBL" "$RS" "$C_DIM" "$RS")
    ui_row "$title"
    ui_mid
    ui_row "$(printf '%bSISTEMA%b' "$C_LBL" "$RS")"
    ui_row "$(printf '  %bOS%b   %s %s %b·%b kernel %s' "$C_LBL" "$RS" "$(lsb_release -is 2>/dev/null || echo Linux)" "$osver" "$C_LBL" "$RS" "$kern")"
    ui_row "$(printf '  %bUptime%b   %s' "$C_LBL" "$RS" "$uptime")"
    ui_mid
    ui_row "$(printf '%bRECURSOS%b' "$C_LBL" "$RS")"
    ui_row "$(printf '  %bRAM%b    %s  %b%s%%%b  %sM / %sM' "$C_LBL" "$RS" "$ram_bar" "$ram_c" "$ram_pct" "$RS" "$ram_used_mb" "$ram_total")"
    ui_row "$(printf '  %bCPU%b    %s  %b%s%%%b' "$C_LBL" "$RS" "$cpu_bar" "$cpu_c" "$cpu_pct" "$RS")"
    ui_row "$(printf '  %bDisco%b  %s  %b%s%%%b' "$C_LBL" "$RS" "$disk_bar" "$disk_c" "$disk_pct" "$RS")"
    ui_mid
    ui_row "$(printf '%bSESION%b' "$C_LBL" "$RS")"
    ui_row "$(printf '  %bIP%b       %s' "$C_LBL" "$RS" "$(printf '%b%s%b' "$C_ACC" "$ipv4" "$RS")")"
    ui_row "$(printf '  %bHost%b     %s   %bOnline%b  %b%s%b' "$C_LBL" "$RS" "$(hostname)" "$C_LBL" "$RS" "$C_OK" "$online" "$RS")"
    ui_row "$(printf '  %bUsuario%b  %s   %bLic%b  %b%s%b' "$C_LBL" "$RS" "$(whoami)" "$C_LBL" "$RS" "$C_OK" "$lic" "$RS")"
    ui_bot

    if [[ ${#BC[@]} -gt 0 ]]; then
        printf '  %b%s%b\n' "$C_DIM" "$(crumbs)" "$RS"
    fi
    printf '\n'
}

# ============================================================
#  LICENCIA
# ============================================================
consultar_licencia(){
    local KEY="$1" RESP
    [[ -z "$LICENSE_URL" ]] && return 2
    RESP=$(curl -G -fsS --max-time 10 -A "Mozilla/5.0" "$LICENSE_URL" \
        --data-urlencode "key=$KEY" --data-urlencode "id=$(machine_hash)" 2>/dev/null) || return 2
    [[ -z "$RESP" ]] && return 2
    if printf '%s' "$RESP" | grep -q '"valid":[[:space:]]*true'; then
        LICENSE_NOMBRE=$(printf '%s' "$RESP" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
        LICENSE_PERMANENTE=0
        printf '%s' "$RESP" | grep -q '"permanent":[[:space:]]*true' && LICENSE_PERMANENTE=1
        LICENSE_DIAS=$(printf '%s' "$RESP" | grep -o '"days_left"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*$' || true)
        return 0
    fi
    LICENSE_REASON=$(printf '%s' "$RESP" | grep -o '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    return 1
}

apply_license_times(){
    if [[ "${LICENSE_PERMANENTE:-0}" == "1" ]]; then
        LICENSE_EXP=0
    elif [[ -n "${LICENSE_DIAS:-}" ]]; then
        LICENSE_EXP=$(( $(date +%s) + LICENSE_DIAS * 86400 ))
    else
        LICENSE_EXP=0
    fi
}

gate_licencia(){
    local intentos=0 k rc perm_hash="" mhash
    clear_if_tty
    printf '\n'
    ui_top
    ui_center "$(printf '%b◆%b %bLICENCIA%b' "$C_FRM2" "$RS" "$BD$CW" "$RS")"
    ui_mid
    mhash=$(machine_hash)
    ui_row "$(printf '  %bServidor ID%b  %s' "$C_LBL" "$RS" "$(printf '%b%s%b' "$C_ACC" "$mhash" "$RS")")"
    if [[ -z "$LICENSE_URL" ]]; then
        ui_row "$(printf '  %bConfigurar LICENSE_URL en:%b' "$C_ERR" "$RS")"
        ui_row "  $CONF_FILE"
        ui_bot
        exit 1
    fi
    ui_bot
    INFO "Validando licencia online..."

    [[ -f "$PERM_FILE" ]] && perm_hash=$(cat "$PERM_FILE" 2>/dev/null)

    if [[ -f "$KEY_FILE" ]]; then
        k=$(cat "$KEY_FILE" 2>/dev/null)
        consultar_licencia "$k"; rc=$?
        if [[ $rc -eq 0 ]]; then
            printf '%s' "$mhash" > "$PERM_FILE" 2>/dev/null
            chmod 600 "$PERM_FILE" 2>/dev/null
            LICENSE_OK="${LICENSE_NOMBRE:-cliente}"
            apply_license_times
            OK "Licencia valida."
            sleep 1
            return 0
        elif [[ $rc -eq 2 ]]; then
            if [[ -n "$perm_hash" && "$perm_hash" == "$mhash" ]]; then
                LICENSE_OK="offline (permanente local)"
                LICENSE_EXP=0
                WARN "Worker no responde, usando licencia local."
                return 0
            fi
            ERR "Worker no responde y esta key nunca valido aqui."
        else
            ERR "Key rechazada: ${LICENSE_REASON:-invalida}."
            case "${LICENSE_REASON:-}" in
                already_used_other_machine|revoked|unknown_key)
                    rm -f "$KEY_FILE" "$PERM_FILE" 2>/dev/null ;;
            esac
        fi
    fi

    while [[ $intentos -lt 3 ]]; do
        printf '  %bINGRESE SU KEY%b %b>%b ' "$C_WARN" "$RS" "$C_FRM2" "$RS"
        read -r k
        consultar_licencia "$k"; rc=$?
        if [[ $rc -eq 0 ]]; then
            printf '%s' "$k" > "$KEY_FILE"; chmod 600 "$KEY_FILE"
            printf '%s' "$mhash" > "$PERM_FILE"; chmod 600 "$PERM_FILE"
            LICENSE_OK="${LICENSE_NOMBRE:-cliente}"
            apply_license_times
            OK "Licencia activada PERMANENTEMENTE. Bienvenido, ${LICENSE_OK}."
            sleep 1
            return 0
        elif [[ $rc -eq 2 ]]; then
            ERR "Worker no responde."
        else
            case "${LICENSE_REASON:-}" in
                already_used_other_machine) ERR "Key ya usada en otro VPS." ;;
                revoked)                    ERR "Key revocada." ;;
                unknown_key)                ERR "Key inexistente." ;;
                *)                          ERR "Key invalida." ;;
            esac
        fi
        intentos=$((intentos+1))
    done
    ERR "Sin licencia valida."
    exit 1
}

# ============================================================
#  USUARIOS
# ============================================================
usuario_protegido(){
    local u="${1:-}" uidn
    [[ -z "$u" ]] && return 0
    grep -qw "$u" "$PROTECTED_FILE" 2>/dev/null && return 0
    uidn=$(id -u "$u" 2>/dev/null || echo 0)
    [[ "$uidn" -lt 1000 ]] && return 0
    return 1
}

bootstrap_dirs(){
    mkdir -p "$USUARIOS_DIR" "$LIMITS_DIR" "$TRAF_DIR"
    touch "$LOG_PANEL" 2>/dev/null
    chmod 640 "$LOG_PANEL" 2>/dev/null || true
    getent group vpsusers >/dev/null 2>&1 || groupadd vpsusers 2>/dev/null || true
    [[ -f /etc/cron.d/ghost-panel-vencidos ]] || cron_vencidos_instalar
}

cron_vencidos_instalar(){
    cat > /usr/local/bin/vps-cron-diario.sh <<'CRONEOF'
#!/usr/bin/env bash
LOG=/var/log/ghost-panel.log
PROTECTED=/etc/ghost-panel.protected
log(){ printf '%s [CRON] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }
today=$(date +%Y-%m-%d)
awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd | while read -r U; do
    grep -qw "$U" "$PROTECTED" 2>/dev/null && continue
    EXP=$(LC_ALL=C LANG=C chage -l "$U" 2>/dev/null | awk -F': ' '/Account expires/{gsub(/^ +/,"",$2); print $2}')
    [[ -z "$EXP" || "$EXP" == "never" ]] && continue
    N=$(date -d "$EXP" +%Y-%m-%d 2>/dev/null) || continue
    if [[ "$N" < "$today" ]]; then
        pkill -u "$U" 2>/dev/null
        python3 - "$U" >/dev/null 2>&1 <<'PY'
import json,sys,os
u=sys.argv[1]
p="/usr/local/etc/xray/config.json"
meta={}
try:
    for line in open(f"/etc/vps-users/{u}"):
        k,_,v=line.strip().partition("=")
        if k: meta[k]=v
except FileNotFoundError:
    pass
if os.path.isfile(p):
    try:
        c=json.load(open(p))
        uid=meta.get("uuid",""); tp=meta.get("trojan","")
        for ib in c.get("inbounds",[]):
            proto=ib.get("protocol")
            cl=ib.get("settings",{}).get("clients",[])
            if proto in ("vless","vmess"):
                ib["settings"]["clients"]=[x for x in cl if x.get("id")!=uid and x.get("email")!=u]
            elif proto=="trojan":
                ib["settings"]["clients"]=[x for x in cl if x.get("password")!=tp and x.get("email")!=u]
        json.dump(c, open(p,"w"), indent=2)
    except Exception:
        pass
PY
        rm -f "/etc/vps-limits/$U" "/etc/vps-trafico/$U" "/etc/vps-users/$U"
        userdel -r "$U" 2>/dev/null || userdel "$U" 2>/dev/null
        log "eliminado vencido: $U (vencio $N)"
    fi
done
CRONEOF
    chmod 755 /usr/local/bin/vps-cron-diario.sh
    cat > /etc/cron.d/ghost-panel-vencidos <<'TAB'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * * root /usr/local/bin/vps-cron-diario.sh
TAB
    chmod 644 /etc/cron.d/ghost-panel-vencidos
}

xray_usuario(){
    local acc="$1" usu="$2"
    python3 - "$acc" "$usu" <<'PY'
import json, os, sys, uuid, secrets
acc, user = sys.argv[1], sys.argv[2]
meta_p = f"/etc/vps-users/{user}"
cfgp = "/usr/local/etc/xray/config.json"
os.makedirs("/etc/vps-users", exist_ok=True)
meta = {}
if os.path.isfile(meta_p):
    for line in open(meta_p):
        k,_,v = line.strip().partition("=")
        if k: meta[k]=v
if acc == "add":
    meta.setdefault("uuid", str(uuid.uuid4()))
    meta.setdefault("trojan", secrets.token_hex(10))
    with open(meta_p,"w") as f:
        for k,v in meta.items(): f.write(f"{k}={v}\n")
    os.chmod(meta_p, 0o600)
    if not os.path.isfile(cfgp): raise SystemExit(0)
    try: cfg = json.load(open(cfgp))
    except Exception: raise SystemExit(0)
    for ib in cfg.get("inbounds", []):
        proto = ib.get("protocol")
        st = ib.setdefault("settings", {})
        clients = st.setdefault("clients", [])
        if proto in ("vless", "vmess"):
            clients[:] = [c for c in clients if c.get("email") != user and c.get("id") != meta["uuid"]]
            entry = {"id": meta["uuid"], "email": user}
            if proto == "vless" and ib.get("streamSettings",{}).get("security") == "reality":
                entry["flow"] = "xtls-rprx-vision"
            clients.append(entry)
        elif proto == "trojan":
            clients[:] = [c for c in clients if c.get("email") != user and c.get("password") != meta["trojan"]]
            clients.append({"password": meta["trojan"], "email": user})
    json.dump(cfg, open(cfgp,"w"), indent=2)
elif acc == "del":
    uid, tp = meta.get("uuid",""), meta.get("trojan","")
    if os.path.isfile(cfgp):
        try:
            cfg = json.load(open(cfgp))
            for ib in cfg.get("inbounds", []):
                proto = ib.get("protocol")
                cl = ib.get("settings",{}).get("clients",[])
                if proto in ("vless","vmess"):
                    ib["settings"]["clients"] = [c for c in cl if c.get("id")!=uid and c.get("email")!=user]
                elif proto == "trojan":
                    ib["settings"]["clients"] = [c for c in cl if c.get("password")!=tp and c.get("email")!=user]
            json.dump(cfg, open(cfgp,"w"), indent=2)
        except Exception: pass
    try: os.remove(meta_p)
    except FileNotFoundError: pass
PY
    if [[ -f /usr/local/etc/xray/config.json ]]; then
        systemctl restart xray 2>/dev/null || true
    fi
}

xray_sync_all(){
    [[ -d "$USUARIOS_DIR" ]] || return 0
    [[ -f /usr/local/etc/xray/config.json ]] || return 0
    local u f
    for f in "$USUARIOS_DIR"/*; do
        [[ -f "$f" ]] || continue
        u=$(basename "$f")
        id "$u" >/dev/null 2>&1 && xray_usuario add "$u" 2>/dev/null
    done
}

crear_usuario(){
    echo; INFO "Crear usuario SSH"
    local usu dias maxc clave
    read -r -p "  Nombre: " usu
    [[ -z "$usu" ]] && { ERR "Vacio."; PAUSA; return; }
    [[ "$usu" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { ERR "Nombre invalido."; PAUSA; return; }
    id "$usu" >/dev/null 2>&1 && { ERR "Ya existe."; PAUSA; return; }
    usuario_protegido "$usu" && { ERR "Nombre reservado."; PAUSA; return; }
    read -r -p "  Dias de validez (30): " dias; dias=${dias:-30}
    read -r -p "  Max conexiones (1): " maxc; maxc=${maxc:-1}
    read -r -p "  Contrasena: " clave
    [[ -z "$clave" ]] && { ERR "Contrasena vacia."; PAUSA; return; }
    useradd -m -s /bin/bash "$usu" 2>/dev/null || { ERR "No se pudo crear."; PAUSA; return; }
    printf '%s:%s\n' "$usu" "$clave" | chpasswd
    if [[ "$dias" =~ ^[0-9]+$ ]]; then
        chage -M "$dias" -E "$(date -d "+${dias} days" +%Y-%m-%d)" "$usu"
    fi
    printf '%s\n' "$maxc" > "$LIMITS_DIR/$usu"
    usermod -aG vpsusers "$usu" 2>/dev/null || true
    xray_usuario add "$usu" 2>/dev/null || true
    OK "Usuario '$usu' creado."
    printf '  IP: %s   Puerto SSH: %s\n' \
        "$(get_ipv4)" \
        "$(grep -i '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || echo 22)"
    vps_log INFO "creado usuario: $usu (dias=$dias max=$maxc)"
    PAUSA
}

listar_usuarios(){
    echo
    printf '  %b%-16s %-22s %-8s %s%b\n' "$BD" "USUARIO" "EXPIRA" "ESTADO" "HOME" "$RS"
    printf '  %b%s%b\n' "$C_DIM" "$(ui_line 58 $C_DIM)" "$RS"
    local u exp est home
    while IFS= read -r u; do
        exp=$(chage -l "$u" 2>/dev/null | awk -F': ' '/Password expires/{print $2}')
        est=$(passwd -S "$u" 2>/dev/null | awk '{print $2}')
        home=$(user_home "$u")
        if [[ "$est" == "P" ]]; then
            printf '  %-16s %-22s %b%-8s%b %s\n' "$u" "$exp" "$C_OK" "● OK" "$RS" "$home"
        else
            printf '  %-16s %-22s %b%-8s%b %s\n' "$u" "$exp" "$C_ERR" "○ LOCK" "$RS" "$home"
        fi
    done < <(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd)
    PAUSA
}

cambiar_clave(){
    local u; read -r -p "  Usuario: " u
    id "$u" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    passwd "$u" && OK "Clave actualizada." || ERR "Fallo."
    PAUSA
}

eliminar_usuario(){
    local u sn; read -r -p "  Usuario a eliminar: " u
    id "$u" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    usuario_protegido "$u" && { ERR "Usuario protegido."; PAUSA; return; }
    read -r -p "  Borrar /home tambien? (s/N): " sn
    pkill_user "$u"
    xray_usuario del "$u" 2>/dev/null || true
    if [[ "${sn,,}" == "s" ]]; then userdel -r "$u" 2>/dev/null; else userdel "$u" 2>/dev/null; fi
    rm -f "$LIMITS_DIR/$u" "$TRAF_DIR/$u"
    OK "Usuario '$u' eliminado."
    vps_log INFO "eliminado usuario: $u"
    PAUSA
}

bloquear_usuario(){
    local u; read -r -p "  Usuario: " u
    id "$u" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    if passwd -S "$u" 2>/dev/null | grep -q ' L '; then
        usermod -U "$u"; OK "'$u' DESBLOQUEADO."
    else
        usermod -L "$u"; pkill_user "$u"; OK "'$u' BLOQUEADO."
    fi
    PAUSA
}

renovar_usuario(){
    local u d; read -r -p "  Usuario: " u
    id "$u" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    read -r -p "  Dias a agregar: " d
    [[ "$d" =~ ^[0-9]+$ ]] || { ERR "Invalido."; PAUSA; return; }
    chage -M "$d" -E "$(date -d "+${d} days" +%Y-%m-%d)" "$u"
    OK "'$u' renovado ${d} dias."
    PAUSA
}

cambiar_limite(){
    local u m
    echo; INFO "Usuarios con limite:"
    if compgen -G "$LIMITS_DIR/*" >/dev/null; then
        for f in "$LIMITS_DIR"/*; do
            printf '  %-16s max: %s\n' "$(basename "$f")" "$(cat "$f")"
        done
    else
        echo "  (ninguno)"
    fi
    read -r -p "  Usuario: " u
    [[ -f "$LIMITS_DIR/$u" ]] || { ERR "Sin limite asignado."; PAUSA; return; }
    read -r -p "  Nuevo max: " m
    [[ "$m" =~ ^[0-9]+$ ]] || { ERR "Invalido."; PAUSA; return; }
    printf '%s\n' "$m" > "$LIMITS_DIR/$u"
    OK "Limite de '$u' = $m."
    PAUSA
}

conexiones_online(){
    echo
    INFO "Conexiones activas"
    who 2>/dev/null || echo "  (sin sesiones)"
    printf '\n  Procesos sshd: %s\n' "$(pgrep -c sshd 2>/dev/null || echo 0)"
    PAUSA
}

matar_conexion(){
    local u
    who 2>/dev/null
    read -r -p "  Usuario a desconectar: " u
    if pkill_user "$u"; then OK "Sesiones cerradas."; else ERR "Sin sesiones."; fi
    PAUSA
}

crear_test_ssh(){
    local base usu maxc clave
    read -r -p "  Nombre base (prefijo test-): " base
    usu="test-$(printf '%s' "$base" | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z' | cut -c1-18)"
    id "$usu" >/dev/null 2>&1 && { ERR "Ya existe."; PAUSA; return; }
    read -r -p "  Max conexiones (1): " maxc; maxc=${maxc:-1}
    clave=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 10)
    [[ -z "$clave" ]] && clave="test123456"
    useradd -m -s /bin/bash "$usu" 2>/dev/null || { ERR "No se pudo crear."; PAUSA; return; }
    printf '%s:%s\n' "$usu" "$clave" | chpasswd
    chage -M 1 -E "$(date -d '+1 day' +%Y-%m-%d)" "$usu" 2>/dev/null
    printf '%s\n' "$maxc" > "$LIMITS_DIR/$usu"
    usermod -aG vpsusers "$usu" 2>/dev/null || true
    xray_usuario add "$usu" 2>/dev/null || true
    OK "Usuario test creado: $usu / $clave"
    PAUSA
}

eliminar_vencidos(){
    local today n borr=0 u exp
    today=$(date +%Y-%m-%d)
    while IFS= read -r u; do
        grep -qw "$u" "$PROTECTED_FILE" 2>/dev/null && continue
        exp=$(chage -l "$u" 2>/dev/null | awk -F': ' '/Password expires/{print $2}')
        [[ -z "$exp" || "$exp" == "never" ]] && continue
        n=$(date -d "$exp" +%Y-%m-%d 2>/dev/null) || continue
        if [[ "$n" < "$today" ]]; then
            pkill_user "$u"
            rm -f "$LIMITS_DIR/$u" "$TRAF_DIR/$u"
            xray_usuario del "$u" 2>/dev/null || true
            userdel -r "$u" 2>/dev/null
            INFO "Eliminado vencido: $u"
            borr=$((borr+1))
        fi
    done < <(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd)
    [[ $borr -eq 0 ]] && OK "No hay vencidos." || OK "Eliminados: $borr."
    PAUSA
}

menu_usuarios(){
    push_crumb "Usuarios"
    while true; do
        header
        subtop "USUARIOS SSH"
        opt 1 "Crear usuario"            7  "Eliminar usuario"
        opt 2 "Listar usuarios"          8  "Eliminar vencidos"
        opt 3 "Cambiar contrasena"       9  "Crear test SSH"
        opt 4 "Bloquear / Desbloquear"   10 "Conexiones online"
        opt 5 "Renovar usuario"          11 "Desconectar usuario"
        opt 6 "Cambiar limite sesiones"
        ui_row ""
        opt 0 "Volver"
        botline
        prompt; read -r op
        case "$op" in
            1) crear_usuario ;;  2) listar_usuarios ;; 3) cambiar_clave ;;
            4) bloquear_usuario ;; 5) renovar_usuario ;; 6) cambiar_limite ;;
            7) eliminar_usuario ;; 8) eliminar_vencidos ;; 9) crear_test_ssh ;;
            10) conexiones_online ;; 11) matar_conexion ;;
            0) pop_crumb; break ;;
            *) ERR "Invalida."; sleep 1 ;;
        esac
    done
}

# ============================================================
#  SEGURIDAD
# ============================================================
instalar_fail2ban(){
    INFO "Instalando fail2ban..."
    apt update -y >/dev/null 2>&1
    apt install -y fail2ban >/dev/null 2>&1 || { ERR "Fallo."; PAUSA; return; }
    cat > /etc/fail2ban/jail.local <<'F2B'
[sshd]
enabled  = true
port     = ssh
maxretry = 5
bantime  = 1h
F2B
    systemctl enable --now fail2ban 2>/dev/null
    OK "Fail2ban activo (5 intentos = 1h baneo)."
    PAUSA
}

limiter_aplicar(){
    mkdir -p "$LIMITS_DIR"
    cat > /usr/local/bin/vps-limiter.sh <<'LIME'
#!/bin/bash
U="$USER"
MAX=$(cat "/etc/vps-limits/$U" 2>/dev/null || echo 1)
N=$(who 2>/dev/null | awk -v u="$U" '$1==u' | wc -l)
if [ "$N" -ge "$MAX" ] && [ -n "$SSH_CONNECTION" ]; then
    T=$(tty 2>/dev/null | sed 's|/dev/||')
    echo "Limite de $MAX sesiones alcanzado."
    [ -n "$T" ] && pkill -KILL -t "$T" 2>/dev/null
    exit 0
fi
exec /bin/bash -l
LIME
    chmod +x /usr/local/bin/vps-limiter.sh 2>/dev/null || { ERR "Sin permiso."; PAUSA; return; }
    sed -i '/# VPS-LIMITER-INICIO/,/# VPS-LIMITER-FIN/d' /etc/ssh/sshd_config
    {
        echo "# VPS-LIMITER-INICIO"
        echo "Match Group vpsusers"
        echo "    ForceCommand /usr/local/bin/vps-limiter.sh"
        echo "# VPS-LIMITER-FIN"
    } >> /etc/ssh/sshd_config
    getent group vpsusers >/dev/null 2>&1 || groupadd vpsusers
    local f
    for f in "$LIMITS_DIR"/*; do
        [[ -f "$f" ]] && usermod -aG vpsusers "$(basename "$f")" 2>/dev/null
    done
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
    OK "Limiter activo."
    PAUSA
}

limiter_quitar(){
    sed -i '/# VPS-LIMITER-INICIO/,/# VPS-LIMITER-FIN/d' /etc/ssh/sshd_config
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
    OK "Limiter desactivado."
    PAUSA
}

cambiar_puerto_ssh(){
    local p; read -r -p "  Puerto SSH nuevo: " p
    [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]] || { ERR "Invalido."; PAUSA; return; }
    sed -i "s/^#\?Port .*/Port $p/" /etc/ssh/sshd_config
    grep -q "^Port $p" /etc/ssh/sshd_config || echo "Port $p" >> /etc/ssh/sshd_config
    ufw allow "$p/tcp" >/dev/null 2>&1 || true
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
    WARN "Puerto SSH: $p. Abri otra terminal y proba ANTES de cerrar esta."
    PAUSA
}

ver_puertos(){
    echo; INFO "Puertos TCP escuchando"
    ss -tlnp 2>/dev/null | head -25
    echo; INFO "Firewall"
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose 2>/dev/null | head -20
    else
        echo "  UFW no instalado."
    fi
    PAUSA
}

abrir_puerto(){
    local p proto sn
    read -r -p "  Puerto: " p
    [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]] || { ERR "Invalido."; PAUSA; return; }
    read -r -p "  Protocolo (tcp/udp) [tcp]: " proto; proto=${proto:-tcp}
    [[ "$proto" != "tcp" && "$proto" != "udp" ]] && { ERR "Invalido."; PAUSA; return; }
    command -v ufw >/dev/null 2>&1 || { apt update -y >/dev/null 2>&1; apt install -y ufw >/dev/null 2>&1; }
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        read -r -p "  UFW inactivo. Activar? (s/N): " sn
        [[ "${sn,,}" == "s" ]] && { ufw --force enable; INFO "UFW activado."; }
    fi
    ufw allow "$p/$proto" >/dev/null 2>&1 && OK "Puerto $p/$proto abierto."
    PAUSA
}

menu_seguridad(){
    push_crumb "Seguridad"
    while true; do
        header
        subtop "SEGURIDAD"
        opt 1 "Instalar fail2ban"        5  "Ver puertos"
        opt 2 "Activar limiter"          6  "Abrir puerto"
        opt 3 "Quitar limiter"           7  "Banner SSH / HTTP Custom"
        opt 4 "Cambiar puerto SSH"
        ui_row ""
        opt 0 "Volver"
        botline
        prompt; read -r op
        case "$op" in
            1) instalar_fail2ban ;; 2) limiter_aplicar ;; 3) limiter_quitar ;;
            4) cambiar_puerto_ssh ;; 5) ver_puertos ;; 6) abrir_puerto ;;
            7) menu_banner ;;
            0) pop_crumb; break ;; *) ERR "Invalida."; sleep 1 ;;
        esac
    done
}

# ============================================================
#  BANNER
# ============================================================
banner_html_default(){
    cat <<'HTML'
<p style="text-align:center;"><font color="#00FFFF"><b>════════════════════════════════</b></font></p><p style="text-align:center;"><font color="#FF00FF"><b>✦ GHOST PANEL ✦</b></font></p><p style="text-align:center;"><font color="#00FF7F"><i>── CONEXION VIP ESTABLE ──</i></font></p><p style="text-align:center;"><font color="#00FFFF"><b>════════════════════════════════</b></font></p><p style="text-align:center;"><font color="#00BFFF"><b>👤 USUARIO : USER</b></font></p><p style="text-align:center;"><font color="#FFD700"><b>📅 VENCIMIENTO : EXP</b></font></p><p style="text-align:center;"><font color="#FF8C00"><b>⏳ RESTANTES : DAYS</b></font></p><p style="text-align:center;"><font color="#FF4444"><b>WARN</b></font></p><p style="text-align:center;"><font color="#7CFC00"><i>🚀 Disfruta de la mejor velocidad 🚀</i></font></p><p style="text-align:center;"><font color="#00FFFF"><b>════════════════════════════════</b></font></p>
HTML
}

banner_activar_sshd(){
    local f=/etc/ssh/sshd_config
    [[ -f "$f" ]] || { ERR "Sin sshd_config."; return 1; }
    sed -i -E '/^[[:space:]]*#?[[:space:]]*Banner[[:space:]]/d' "$f"
    printf '\nBanner /etc/banner-vps\n' >> "$f"
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
}

banner_activar_dropbear(){
    command -v dropbear >/dev/null 2>&1 || [[ -d /etc/dropbear ]] || return 0
    mkdir -p /etc/dropbear
    cp -f /etc/banner-vps /etc/dropbear/banner
    chmod 644 /etc/dropbear/banner
    systemctl reload dropbear 2>/dev/null || service dropbear restart 2>/dev/null || true
}

banner_publicar(){
    local tmp; tmp=$(mktmp /tmp/banner-vps.XXXXXX) || { ERR "Sin tmp."; return 1; }
    cat > "$tmp"
    [[ -s "$tmp" ]] || { ERR "Vacio."; return 1; }
    if [[ "${BANNER_HC:-0}" == "1" ]]; then
        if grep -qE '\$|\[[A-Za-z]+\]' "$tmp"; then
            ERR "No uses \$ ni [VAR]. Tokens: USER EXP DAYS WARN"; return 1
        fi
        if grep -qE '[A-Za-z]EXP|EXP[A-Za-z]' "$tmp"; then
            ERR "Texto con 'EXP'. Usa 'VENCIMIENTO :'."; return 1
        fi
    fi
    install -m 644 "$tmp" /etc/banner-vps
    rm -f "$tmp"
    banner_activar_sshd || return 1
    banner_activar_dropbear
    OK "Banner publicado."
}

banner_plantilla(){
    banner_html_default | BANNER_HC=1 banner_publicar
    echo
    INFO "Tokens: USER / EXP / DAYS / WARN"
    echo; tr -d '\n' < /etc/banner-vps; echo
    PAUSA
}

banner_propio(){
    echo "  Pega el HTML en UNA linea y ENTER:"
    local html; IFS= read -r html
    printf '%s' "$html" | BANNER_HC=1 banner_publicar
    PAUSA
}

banner_texto(){
    echo "  Lineas del banner (linea vacia = fin):"
    local tmp; tmp=$(mktmp /tmp/banner-vps.XXXXXX) || return
    local l
    while IFS= read -r l; do [[ -z "$l" ]] && break; printf '%s\n' "$l" >> "$tmp"; done
    [[ -s "$tmp" ]] || { ERR "Vacio."; PAUSA; return; }
    cat "$tmp" | banner_publicar
    rm -f "$tmp"
    PAUSA
}

banner_eliminar(){
    [[ -f /etc/ssh/sshd_config ]] && sed -i -E '/^[[:space:]]*#?[[:space:]]*Banner[[:space:]]/d' /etc/ssh/sshd_config
    rm -f /etc/banner-vps /etc/dropbear/banner
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    OK "Banner eliminado."
    PAUSA
}

menu_banner(){
    push_crumb "Banner"
    while true; do
        header
        subtop "BANNER SSH / HTTP CUSTOM"
        opt 1 "Plantilla GHOST PANEL"    3 "Eliminar banner"
        opt 2 "Pegar HTML propio"        4 "CheckUser + banner"
        ui_row ""
        opt 0 "Volver"
        botline
        prompt; read -r op
        case "$op" in
            1) banner_plantilla ;;
            2) banner_propio ;;
            3) banner_eliminar ;;
            4) banner_con_checkuser ;;
            0) pop_crumb; break ;; *) ERR "Invalida."; sleep 1 ;;
        esac
    done
}

banner_con_checkuser(){
    banner_html_default | BANNER_HC=1 banner_publicar
    if [[ ! -f /etc/vps-checkuser.conf ]]; then
        INFO "Instalando CheckUser..."
        checkuser_instalar
        return
    fi
    checkuser_escribir_py
    systemctl restart vps-checkuser 2>/dev/null || true
    OK "CheckUser reiniciado."
    PAUSA
}

# ============================================================
#  CHECKUSER API
# ============================================================
checkuser_escribir_py(){
    cat > /usr/local/bin/vps-checkuser.py <<'PYEOF'
#!/usr/bin/env python3
import json, os, subprocess, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
CONF = "/etc/vps-checkuser.conf"
ENV_C = dict(os.environ); ENV_C["LC_ALL"]="C"; ENV_C["LANG"]="C"
def conf():
    d = {"PORT":"8080","TOKEN":""}
    try:
        for line in open(CONF):
            k,_,v = line.strip().partition("=")
            if k in ("PORT","TOKEN"): d[k]=v.strip()
    except FileNotFoundError: pass
    return d
def sh(*a): return subprocess.run(a, capture_output=True, text=True, env=ENV_C)
def user_info(name):
    if sh("id", name).returncode != 0:
        return {"username":name,"exists":False,"status":"notfound","expiration":"","days_left":None,"warning":""}
    exp_raw=""
    for line in sh("chage","-l",name).stdout.splitlines():
        if line.startswith("Password expires"): exp_raw=line.split(":",1)[1].strip()
    days,status,exp_iso=None,"active",""
    if exp_raw and exp_raw.lower()!="never":
        try:
            ts=time.mktime(time.strptime(exp_raw,"%b %d, %Y"))
            days=int((ts-time.time())//86400)
            exp_iso=time.strftime("%Y-%m-%d",time.localtime(ts))
            if days<0: status="expired"; days=0
        except ValueError: exp_iso=exp_raw
    warn=""
    if status=="expired": warn="Cuenta vencida"
    elif days is not None and days<=3: warn="Por vencer"
    try: lim=open(f"/etc/vps-limits/{name}").read().strip()
    except FileNotFoundError: lim=None
    who=sh("who").stdout
    online=sum(1 for l in who.splitlines() if l.split() and l.split()[0]==name)
    return {"username":name,"user":name,"exists":True,"status":status,
            "password_expires":exp_raw,"expiration":exp_iso,
            "expired":(status=="expired"),
            "days_left":days,"remaining":days,"warning":warn,"warn":warn,
            "online":online,"limit":lim,"limit_connection":lim}
class H(BaseHTTPRequestHandler):
    def _send(self,code,obj):
        b=json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
    def do_GET(self):
        c=conf(); u=urlparse(self.path); qs=parse_qs(u.query)
        if c["TOKEN"] and qs.get("token",[""])[0]!=c["TOKEN"]:
            return self._send(403,{"error":"forbidden"})
        if u.path in ("/checkuser.php","/checkuser","/check"):
            n=qs.get("user",[""])[0]
            if not n: return self._send(400,{"error":"falta user"})
            return self._send(200,user_info(n))
        if u.path=="/status":
            who=[l for l in sh("who").stdout.splitlines() if l.strip()]
            tot=sh("awk","-F:","$3>=1000 && $1!=\"nobody\"","/etc/passwd").stdout
            return self._send(200,{"service":"checkuser","online_now":len(who),
                                   "total_users":len([l for l in tot.splitlines() if l.strip()])})
        return self._send(404,{"error":"not found"})
if __name__=="__main__":
    c=conf()
    print(f"checkuser on 0.0.0.0:{c['PORT']}", flush=True)
    HTTPServer(("0.0.0.0",int(c["PORT"])),H).serve_forever()
PYEOF
    chmod 755 /usr/local/bin/vps-checkuser.py
}

checkuser_instalar(){
    echo; INFO "Instalar CheckUser API"
    local port token
    read -r -p "  Puerto [8080]: " port; port=${port:-8080}
    [[ "$port" =~ ^[0-9]+$ ]] || { ERR "Invalido."; PAUSA; return; }
    read -r -p "  Token (vacio = aleatorio): " token
    [[ -z "$token" ]] && token=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 20)
    printf 'PORT=%s\nTOKEN=%s\n' "$port" "$token" > /etc/vps-checkuser.conf
    chmod 600 /etc/vps-checkuser.conf
    checkuser_escribir_py
    cat > /etc/systemd/system/vps-checkuser.service <<SVCEOF
[Unit]
Description=CheckUser API (Ghost Panel)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/vps-checkuser.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable --now vps-checkuser 2>/dev/null
    ufw allow "$port/tcp" >/dev/null 2>&1 || true
    local ip; ip=$(get_ipv4)
    OK "CheckUser instalado."
    printf '  Local:  http://localhost:%s/checkuser.php?user=X&token=%s\n' "$port" "$token"
    printf '  Remoto: http://%s:%s/checkuser.php?user=X&token=%s\n' "$ip" "$port" "$token"
    PAUSA
}

checkuser_probar(){
    local p t u
    p=$(awk -F= '/^PORT=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    t=$(awk -F= '/^TOKEN=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    read -r -p "  Usuario a consultar: " u
    echo
    curl -s "http://localhost:${p:-8080}/checkuser.php?user=$u&token=$t" && echo || ERR "Sin respuesta."
    PAUSA
}

checkuser_quitar(){
    systemctl disable --now vps-checkuser 2>/dev/null
    rm -f /usr/local/bin/vps-checkuser.py /etc/systemd/system/vps-checkuser.service /etc/vps-checkuser.conf
    systemctl daemon-reload 2>/dev/null
    OK "CheckUser removido."
    PAUSA
}

menu_checkuser(){
    push_crumb "CheckUser"
    while true; do
        header
        subtop "CHECKUSER API"
        opt 1 "Instalar / reinstalar"  4 "Ver token y puerto"
        opt 2 "Estado del servicio"    5 "Remover"
        opt 3 "Probar consulta"
        ui_row ""
        opt 0 "Volver"
        botline
        prompt; read -r op
        case "$op" in
            1) checkuser_instalar ;;
            2) systemctl status vps-checkuser --no-pager 2>/dev/null | head -15; PAUSA ;;
            3) checkuser_probar ;;
            4) cat /etc/vps-checkuser.conf 2>/dev/null || ERR "No instalado."; PAUSA ;;
            5) checkuser_quitar ;;
            0) pop_crumb; break ;; *) ERR "Invalida."; sleep 1 ;;
        esac
    done
}

# ============================================================
#  SISTEMA
# ============================================================
monitoreo(){
    echo; INFO "Monitoreo"
    echo "  Uptime: $(uptime)"
    free -h | sed 's/^/  /'
    echo; df -h / /home 2>/dev/null | sed 's/^/  /'
    echo; ss -tunap 2>/dev/null | awk 'NR>1{print "  "$1, $5, $7}' | head -20
    PAUSA
}

optimizar(){
    INFO "Aplicando BBR + sysctl..."
    cat > /etc/sysctl.d/99-ghost-panel.conf <<'SYS'
vm.swappiness=10
vm.vfs_cache_pressure=50
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYS
    modprobe tcp_bbr 2>/dev/null
    printf 'tcp_bbr\n' >> /etc/modules-load.d/bbr.conf 2>/dev/null
    sysctl --system >/dev/null 2>&1
    OK "Optimizacion aplicada."
    PAUSA
}

agregar_swap(){
    swapon --show 2>/dev/null | grep -q '/swapfile' && { ERR "Ya existe swapfile."; PAUSA; return; }
    local g; read -r -p "  Tamaño GB (1): " g; g=${g:-1}
    [[ "$g" =~ ^[0-9]+$ && "$g" -ge 1 ]] || { ERR "Invalido."; PAUSA; return; }
    INFO "Creando swap ${g}GB..."
    fallocate -l "${g}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((g*1024)) status=none
    chmod 600 /swapfile; mkswap /swapfile >/dev/null 2>&1; swapon /swapfile 2>/dev/null
    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        OK "Swap de ${g}GB activa."
    else
        rm -f /swapfile; ERR "No se pudo activar."
    fi
    PAUSA
}

agregar_zram(){
    local g
    read -r -p "  Tamaño zram GB (1): " g; g=${g:-1}
    [[ "$g" =~ ^[0-9]+$ ]] || { ERR "Invalido."; PAUSA; return; }
    modprobe zram 2>/dev/null || { ERR "Sin acceso al kernel (OpenVZ/LXC)."; PAUSA; return; }
    zramctl /dev/zram0 --algorithm zstd --size "${g}G" >/dev/null 2>&1 \
        || zramctl /dev/zram0 --algorithm lzo --size "${g}G" >/dev/null 2>&1 \
        || { ERR "zramctl fallo."; PAUSA; return; }
    mkswap /dev/zram0 >/dev/null 2>&1
    swapon -p 100 /dev/zram0 2>/dev/null || true
    cat > /etc/systemd/system/vps-zram.service <<ZEOF
[Unit]
Description=ZRAM Ghost Panel
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "modprobe zram && (zramctl /dev/zram0 -a zstd -s ${g}G || zramctl /dev/zram0 -a lzo -s ${g}G) && mkswap /dev/zram0 && swapon -p 100 /dev/zram0"
ExecStop=/bin/bash -c "swapoff /dev/zram0 2>/dev/null; zramctl --reset /dev/zram0 2>/dev/null"
[Install]
WantedBy=multi-user.target
ZEOF
    systemctl daemon-reload; systemctl enable vps-zram 2>/dev/null
    swapon --show 2>/dev/null | grep -q zram && OK "ZRAM activa." || ERR "ZRAM no arranco."
    PAUSA
}

mantenimiento(){
    INFO "Limpiando..."
    apt autoremove -y >/dev/null 2>&1
    apt clean >/dev/null 2>&1
    journalctl --vacuum-time=7d >/dev/null 2>&1
    find /tmp -type f -mtime +7 -delete 2>/dev/null
    ls -t /root/backups/*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
    find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null
    systemctl enable --now fstrim.timer >/dev/null 2>&1
    OK "Mantenimiento completado."
    PAUSA
}

cambiar_hostname(){
    local h; read -r -p "  Nuevo hostname: " h
    [[ "$h" =~ ^[a-zA-Z0-9.-]+$ ]] || { ERR "Invalido."; PAUSA; return; }
    hostnamectl set-hostname "$h" 2>/dev/null || { ERR "Fallo."; PAUSA; return; }
    sed -i "s/127.0.1.1.*/127.0.1.1\t$h/" /etc/hosts 2>/dev/null
    OK "Hostname: $h."
    PAUSA
}

update_sistema(){
    INFO "Actualizando sistema..."
    apt update && apt upgrade -y
    OK "Listo."
    PAUSA
}

reiniciar_vps(){
    local sn; read -r -p "  Reiniciar ahora? (s/N): " sn
    if [[ "${sn,,}" == "s" ]]; then WARN "Reiniciando en 3s..."; sleep 3; reboot; fi
    PAUSA
}

diagnostico(){
    echo; INFO "Diagnostico del servidor"
    local ramp diskp load adv=0
    ramp=$(free | awk '/Mem/{printf "%d", $3*100/$2}')
    diskp=$(df -h / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    load=$(cut -d' ' -f1 /proc/loadavg)
    printf '  RAM: %s%%   Disco: %s%%   Carga: %s\n' "$ramp" "$diskp" "$load"
    [[ "$ramp" -gt 85 ]]   && { WARN "RAM al ${ramp}%"; adv=1; }
    [[ "$diskp" -gt 85 ]]  && { WARN "Disco al ${diskp}%"; adv=1; }
    systemctl is-failed --quiet sshd 2>/dev/null && { WARN "sshd con fallos"; adv=1; }
    pgrep -f miniserv >/dev/null 2>&1 || printf '  %b○%b Webmin no corre\n' "$C_WARN" "$RS"
    [[ $adv -eq 0 ]] && OK "Sin alertas graves."
    PAUSA
}

menu_sistema(){
    push_crumb "Sistema"
    while true; do
        header
        subtop "SISTEMA Y RECURSOS"
        opt 1 "Monitoreo"              5 "Mantenimiento"
        opt 2 "Diagnostico"            6 "Cambiar hostname"
        opt 3 "Optimizar (BBR)"        7 "Update sistema"
        opt 4 "Agregar swap"           8 "Reiniciar VPS"
        opt 9 "Agregar zram"
        ui_row ""
        opt 0 "Volver"
        botline
        prompt; read -r op
        case "$op" in
            1) monitoreo ;; 2) diagnostico ;; 3) optimizar ;; 4) agregar_swap ;;
            5) mantenimiento ;; 6) cambiar_hostname ;; 7) update_sistema ;;
            8) reiniciar_vps ;; 9) agregar_zram ;;
            0) pop_crumb; break ;; *) ERR "Invalida."; sleep 1 ;;
        esac
    done
}

# ============================================================
#  PROTOCOLOS
# ============================================================
instalar_xray(){
    if command -v xray >/dev/null 2>&1; then
        local sn; read -r -p "  Xray ya instalado. Reconfigurar? (s/N): " sn
        [[ "${sn,,}" != "s" ]] && { PAUSA; return; }
    fi
    local xp sni
    read -r -p "  Puerto Xray (8443): " xp; xp=${xp:-8443}
    read -r -p "  SNI (www.microsoft.com): " sni; sni=${sni:-www.microsoft.com}
    INFO "Instalando Xray..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
        || { ERR "Fallo."; PAUSA; return; }
    local keys priv pub uuidv
    keys=$(xray x25519 2>/dev/null)
    priv=$(printf '%s' "$keys" | grep -iE 'private' | awk '{print $NF}')
    pub=$(printf '%s' "$keys"  | grep -iE 'public'  | awk '{print $NF}')
    uuidv=$(xray uuid)
    [[ -z "$priv" || -z "$pub" || -z "$uuidv" ]] && { ERR "No se generaron claves."; PAUSA; return; }
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<XEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $xp,
    "protocol": "vless",
    "settings": { "clients": [{ "id": "$uuidv", "flow": "xtls-rprx-vision" }], "decryption": "none" },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "dest": "$sni:443", "xver": 0,
        "serverNames": ["$sni"], "privateKey": "$priv", "shortIds": [""]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
XEOF
    ufw allow "$xp/tcp" >/dev/null 2>&1 || true
    systemctl enable --now xray 2>/dev/null
    sleep 2
    xray_sync_all
    systemctl restart xray 2>/dev/null
    local ip; ip=$(get_ipv4)
    OK "Xray activo en :$xp"
    printf '  %bvless://%s@%s:%s?security=reality&encryption=none&pbk=%s&fp=chrome&sni=%s&flow=xtls-rprx-vision&sid=#Ghost%b\n' \
        "$C_ACC" "$uuidv" "$ip" "$xp" "$pub" "$sni" "$RS"
    PAUSA
}

instalar_xray_ws(){
    command -v xray >/dev/null 2>&1 || {
        INFO "Xray no esta, instalando..."
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    }
    local wp wpath uuidv
    read -r -p "  Puerto WS (8080): " wp; wp=${wp:-8080}
    read -r -p "  Path (/ghost): " wpath; wpath=${wpath:-/ghost}
    [[ "$wpath" == /* ]] || wpath="/$wpath"
    uuidv=$(xray uuid)
    mkdir -p /usr/local/etc/xray
    python3 - "$wp" "$wpath" "$uuidv" <<'PY'
import json, sys
port, path, uid = int(sys.argv[1]), sys.argv[2], sys.argv[3]
cfgp = "/usr/local/etc/xray/config.json"
try: cfg = json.load(open(cfgp))
except Exception: cfg = {"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}
ib = [i for i in cfg.get("inbounds", []) if i.get("port") != port]
ib.append({"port": port, "protocol": "vless",
           "settings": {"clients":[{"id": uid}], "decryption": "none"},
           "streamSettings": {"network": "ws", "wsSettings": {"path": path}},
           "sniffing": {"enabled": True, "destOverride": ["http","tls"]}})
cfg["inbounds"] = ib
json.dump(cfg, open(cfgp, "w"), indent=2)
PY
    ufw allow "$wp/tcp" >/dev/null 2>&1 || true
    systemctl restart xray 2>/dev/null
    sleep 1
    local ip; ip=$(get_ipv4)
    OK "Xray WS activo en :$wp (path $wpath)"
    printf '  %bvless://%s@%s:%s?type=ws&path=%s&security=none#Ghost-WS%b\n' \
        "$C_ACC" "$uuidv" "$ip" "$wp" "${wpath//\//%2F}" "$RS"
    PAUSA
}

instalar_trojan(){
    command -v xray >/dev/null 2>&1 || {
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    }
    local tp sni pwd
    read -r -p "  Puerto Trojan (9443): " tp; tp=${tp:-9443}
    read -r -p "  SNI (www.microsoft.com): " sni; sni=${sni:-www.microsoft.com}
    pwd=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 20)
    mkdir -p /etc/vpsjb-trojan
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=$sni" \
        -keyout /etc/vpsjb-trojan/key.pem -out /etc/vpsjb-trojan/cert.pem >/dev/null 2>&1
    python3 - "$tp" "$sni" "$pwd" <<'PY'
import json, sys
port, sni, pw = int(sys.argv[1]), sys.argv[2], sys.argv[3]
cfgp = "/usr/local/etc/xray/config.json"
try: cfg = json.load(open(cfgp))
except Exception: cfg = {"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}
ib = [i for i in cfg.get("inbounds", []) if i.get("port") != port]
ib.append({"port": port, "protocol": "trojan",
           "settings": {"clients":[{"password": pw}]},
           "streamSettings": {"network": "tcp", "security": "tls",
               "tlsSettings": {"serverName": sni,
                   "certificates": [{"certificateFile": "/etc/vpsjb-trojan/cert.pem",
                                     "keyFile": "/etc/vpsjb-trojan/key.pem"}]}}})
cfg["inbounds"] = ib
json.dump(cfg, open(cfgp, "w"), indent=2)
PY
    ufw allow "$tp/tcp" >/dev/null 2>&1 || true
    systemctl restart xray 2>/dev/null
    local ip; ip=$(get_ipv4)
    OK "Trojan activo en :$tp"
    printf '  %btrojan://%s@%s:%s?security=tls&sni=%s&allowInsecure=1#Ghost-Trojan%b\n' \
        "$C_ACC" "$pwd" "$ip" "$tp" "$sni" "$RS"
    PAUSA
}

instalar_openvpn(){
    command -v openvpn >/dev/null 2>&1 && { ERR "Ya instalado."; PAUSA; return; }
    curl -fsSL -o /root/openvpn-install.sh https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh \
        || { ERR "Sin red."; PAUSA; return; }
    chmod +x /root/openvpn-install.sh
    AUTO_INSTALL=y bash /root/openvpn-install.sh
    PAUSA
}

instalar_ssl_stunnel(){
    local sp sshp
    read -r -p "  Puerto SSL (443): " sp; sp=${sp:-443}
    read -r -p "  Puerto SSH destino (22): " sshp; sshp=${sshp:-22}
    apt update -y >/dev/null 2>&1
    apt install -y stunnel4 >/dev/null 2>&1 || { ERR "Fallo."; PAUSA; return; }
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=ghost" \
        -keyout /etc/stunnel/stunnel.key -out /etc/stunnel/stunnel.crt >/dev/null 2>&1
    cat /etc/stunnel/stunnel.crt /etc/stunnel/stunnel.key > /etc/stunnel/stunnel.pem
    cat > /etc/stunnel/stunnel.conf <<SEOF
pid = /var/run/stunnel4.pid
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1

[ssh-ssl]
accept = $sp
connect = 127.0.0.1:$sshp
SEOF
    sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4 2>/dev/null
    ufw allow "$sp/tcp" >/dev/null 2>&1 || true
    systemctl restart stunnel4 2>/dev/null
    sleep 1
    pgrep -f stunnel >/dev/null && OK "Stunnel activo :$sp -> SSH :$sshp" || ERR "No arranco."
    PAUSA
}

instalar_hysteria(){
    local hp pwd
    read -r -p "  Puerto UDP (8443): " hp; hp=${hp:-8443}
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1 || { ERR "Fallo."; PAUSA; return; }
    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=ghost" \
        -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt >/dev/null 2>&1
    pwd=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)
    cat > /etc/hysteria/config.yaml <<HEOF
listen: :$hp
auth:
  type: password
  password: "$pwd"
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
HEOF
    ufw allow "$hp/udp" >/dev/null 2>&1 || true
    systemctl enable --now hysteria-server >/dev/null 2>&1
    sleep 1
    local ip; ip=$(get_ipv4)
    systemctl is-active --quiet hysteria-server 2>/dev/null \
        && { OK "Hysteria2 en :$hp"; printf '  %bhysteria2://%s@%s:%s/?insecure=1#Ghost%b\n' "$C_ACC" "$pwd" "$ip" "$hp" "$RS"; } \
        || ERR "No arranco."
    PAUSA
}

instalar_badvpn(){
    local bp
    read -r -p "  Puerto UDP GW (7300): " bp; bp=${bp:-7300}
    apt update -y >/dev/null 2>&1
    apt install -y badvpn >/dev/null 2>&1 || { ERR "Fallo."; PAUSA; return; }
    cat > /etc/systemd/system/badvpn.service <<BEOF
[Unit]
Description=BadVPN UDP GW
After=network.target
[Service]
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:$bp --max-clients 500
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
BEOF
    systemctl daemon-reload; systemctl enable --now badvpn 2>/dev/null
    sleep 1
    pgrep -f badvpn-udpgw >/dev/null && OK "BadVPN activo en 127.0.0.1:$bp" || ERR "Fallo."
    PAUSA
}

instalar_wsepro(){
    local ep
    read -r -p "  Puerto WS (80): " ep; ep=${ep:-80}
    cat > /usr/local/bin/ghost-ws.py <<'WSEOF'
#!/usr/bin/env python3
import socket, base64, hashlib, struct, threading, sys

LISTEN = ('0.0.0.0', int(sys.argv[1]) if len(sys.argv) > 1 else 80)
TARGET = ('127.0.0.1', int(sys.argv[2]) if len(sys.argv) > 2 else 22)
GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

def recv_until(s, marker, limit=8192):
    d=b''
    while marker not in d and len(d)<limit:
        c=s.recv(1024)
        if not c: break
        d+=c
    return d

def handshake(c):
    req = recv_until(c, b'\r\n\r\n')
    if not req: return False
    key=''
    for line in req.split(b'\r\n'):
        if line.lower().startswith(b'sec-websocket-key:'):
            key = line.split(b':',1)[1].strip().decode()
    if not key: return False
    acc = base64.b64encode(hashlib.sha1((key+GUID).encode()).digest()).decode()
    c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
    return True

def read_frame(c):
    h = c.recv(2)
    if len(h)<2: return None,None
    op = h[0]&0x0F; b2 = h[1]; masked = b2&0x80; ln = b2&0x7F
    if ln == 126: ln = struct.unpack('>H', c.recv(2))[0]
    elif ln == 127: ln = struct.unpack('>Q', c.recv(8))[0]
    mask = c.recv(4) if masked else None
    p = b''
    while len(p)<ln:
        chunk = c.recv(ln-len(p))
        if not chunk: break
        p += chunk
    if mask: p = bytes(b^mask[i%4] for i,b in enumerate(p))
    return op, p

def send_frame(s, d, op=2):
    h = bytes([0x80|op]); ln = len(d)
    if ln < 126: h += bytes([ln])
    elif ln < 65536: h += bytes([126])+struct.pack('>H', ln)
    else: h += bytes([127])+struct.pack('>Q', ln)
    s.sendall(h+d)

def ws2tcp(ws, tcp):
    try:
        while True:
            op, d = read_frame(ws)
            if op is None or op == 8: break
            if op in (0,1,2) and d: tcp.sendall(d)
    except Exception: pass
    finally:
        try: tcp.shutdown(socket.SHUT_WR)
        except Exception: pass

def tcp2ws(tcp, ws):
    try:
        while True:
            d = tcp.recv(65536)
            if not d: break
            send_frame(ws, d)
    except Exception: pass
    finally:
        try: ws.close()
        except Exception: pass

def handle(c):
    try:
        if not handshake(c): c.close(); return
        tcp = socket.create_connection(TARGET, timeout=15)
    except Exception: c.close(); return
    t1 = threading.Thread(target=ws2tcp, args=(c,tcp))
    t2 = threading.Thread(target=tcp2ws, args=(tcp,c))
    t1.start(); t2.start(); t1.join(); t2.join()
    for s in (c,tcp):
        try: s.close()
        except Exception: pass

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(LISTEN); srv.listen(256)
print("WS->SSH en %s:%d -> %s:%d" % (LISTEN[0], LISTEN[1], TARGET[0], TARGET[1]), flush=True)
while True:
    cli,_ = srv.accept()
    threading.Thread(target=handle, args=(cli,), daemon=True).start()
WSEOF
    chmod +x /usr/local/bin/ghost-ws.py
    cat > /etc/systemd/system/ghost-ws.service <<SVCEOF
[Unit]
Description=WS-epro (WS->SSH)
After=network.target
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ghost-ws.py $ep 22
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload; systemctl enable --now ghost-ws 2>/dev/null
    sleep 1
    systemctl is-active --quiet ghost-ws 2>/dev/null && OK "WS-epro activo en :$ep -> SSH 22" || ERR "No arranco."
    PAUSA
}

instalar_shadowsocks(){
    local sp pw
    read -r -p "  Puerto SS (8388): " sp; sp=${sp:-8388}
    apt update -y >/dev/null 2>&1
    apt install -y shadowsocks-libev >/dev/null 2>&1 || { ERR "Fallo."; PAUSA; return; }
    pw=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
    mkdir -p /etc/shadowsocks-libev
    cat > /etc/shadowsocks-libev/config.json <<SSEOF
{
  "server": "0.0.0.0",
  "server_port": $sp,
  "password": "$pw",
  "method": "aes-256-gcm",
  "mode": "tcp_and_udp",
  "fast_open": true
}
SSEOF
    cat > /etc/systemd/system/ghost-ss.service <<SSSVC
[Unit]
Description=Shadowsocks Ghost
After=network.target
[Service]
ExecStart=/usr/bin/ss-server -c /etc/shadowsocks-libev/config.json
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SSSVC
    systemctl daemon-reload; systemctl enable --now ghost-ss 2>/dev/null
    ufw allow "$sp/tcp" >/dev/null 2>&1 || true
    ufw allow "$sp/udp" >/dev/null 2>&1 || true
    sleep 1
    if systemctl is-active --quiet ghost-ss 2>/dev/null; then
        local ip b64; ip=$(get_ipv4)
        b64=$(printf 'aes-256-gcm:%s' "$pw" | base64 -w0)
        OK "Shadowsocks activo :$sp"
        printf '  %bss://%s@%s:%s#Ghost-SS%b\n' "$C_ACC" "$b64" "$ip" "$sp" "$RS"
    else
        ERR "No arranco."
    fi
    PAUSA
}

instalar_wireguard(){
    local wp spriv spub cpriv cpub iface ip
    read -r -p "  Puerto UDP (51820): " wp; wp=${wp:-51820}
    apt update -y >/dev/null 2>&1
    apt install -y wireguard >/dev/null 2>&1 || { ERR "Fallo."; PAUSA; return; }
    spriv=$(wg genkey); spub=$(printf '%s' "$spriv" | wg pubkey)
    cpriv=$(wg genkey); cpub=$(printf '%s' "$cpriv" | wg pubkey)
    iface=$(ip route show default | awk '{print $5}' | head -1); iface=${iface:-eth0}
    cat > /etc/wireguard/wg0.conf <<WGEOF
[Interface]
Address = 10.66.0.1/24
ListenPort = $wp
PrivateKey = $spriv
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $iface -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $iface -j MASQUERADE

[Peer]
PublicKey = $cpub
AllowedIPs = 10.66.0.2/32
WGEOF
    chmod 600 /etc/wireguard/wg0.conf
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    ufw allow "$wp/udp" >/dev/null 2>&1 || true
    systemctl enable --now wg-quick@wg0 2>/dev/null
    sleep 1
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        ip=$(get_ipv4)
        cat > /root/wg-client.conf <<CLIENTEOF
[Interface]
PrivateKey = $cpriv
Address = 10.66.0.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = $spub
Endpoint = $ip:$wp
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CLIENTEOF
        OK "WireGuard activo :$wp"
        printf '  Config cliente: /root/wg-client.conf\n'
    else
        ERR "Fallo."
    fi
    PAUSA
}

estado_protocolos(){
    echo; INFO "Estado de protocolos"
    if command -v xray >/dev/null 2>&1; then
        local puerto; puerto=$(grep -o '"port": [0-9]*' /usr/local/etc/xray/config.json 2>/dev/null | head -1 | grep -o '[0-9]*')
        (pgrep -x xray >/dev/null 2>&1 || systemctl is-active --quiet xray 2>/dev/null) \
            && printf '  Xray: %b● ACTIVO%b (:%s)\n' "$C_OK" "$RS" "${puerto:-?}" \
            || printf '  Xray: %b○ detenido%b\n' "$C_WARN" "$RS"
    else
        printf '  Xray: %b○ no instalado%b\n' "$C_ERR" "$RS"
    fi
    pgrep -f badvpn-udpgw >/dev/null 2>&1 && printf '  BadVPN: %b● ACTIVO%b\n' "$C_OK" "$RS" || printf '  BadVPN: %b○ no%b\n' "$C_ERR" "$RS"
    systemctl is-active --quiet ghost-ws 2>/dev/null && printf '  WS-epro: %b● ACTIVO%b\n' "$C_OK" "$RS" || printf '  WS-epro: %b○ no%b\n' "$C_ERR" "$RS"
    systemctl is-active --quiet ghost-ss 2>/dev/null && printf '  Shadowsocks: %b● ACTIVO%b\n' "$C_OK" "$RS" || printf '  Shadowsocks: %b○ no%b\n' "$C_ERR" "$RS"
    systemctl is-active --quiet wg-quick@wg0 2>/dev/null && printf '  WireGuard: %b● ACTIVO%b\n' "$C_OK" "$RS" || printf '  WireGuard: %b○ no%b\n' "$C_ERR" "$RS"
    systemctl is-active --quiet hysteria-server 2>/dev/null && printf '  Hysteria2: %b● ACTIVO%b\n' "$C_OK" "$RS" || printf '  Hysteria2: %b○ no%b\n' "$C_ERR" "$RS"
    systemctl is-active --quiet stunnel4 2>/dev/null && printf '  Stunnel: %b● ACTIVO%b\n' "$C_OK" "$RS" || printf '  Stunnel: %b○ no%b\n' "$C_ERR" "$RS"
    pgrep -x cloudflared >/dev/null 2>&1 && printf '  Tunel CDN: %b● ACTIVO%b\n' "$C_OK" "$RS" || printf '  Tunel CDN: %b○ inactivo%b\n' "$C_ERR" "$RS"
    PAUSA
}

menu_quitar(){
    push_crumb "Quitar"
    while true; do
        header
        subtop "QUITAR PROTOCOLOS"
        opt 1 "Xray completo"   5 "Hysteria2"
        opt 2 "WS-epro"         6 "Shadowsocks"
        opt 3 "Stunnel"         7 "Trojan"
        opt 4 "BadVPN"          8 "WireGuard"
        opt 9 "Tunel CDN"
        ui_row ""
        opt 0 "Volver"
        botline
        prompt; read -r op
        case "$op" in
            1) systemctl disable --now xray 2>/dev/null; rm -f /usr/local/bin/xray; rm -rf /usr/local/etc/xray /etc/vpsjb-trojan; pkill -x xray 2>/dev/null; OK "Xray removido."; PAUSA ;;
            2) systemctl disable --now ghost-ws 2>/dev/null; rm -f /etc/systemd/system/ghost-ws.service /usr/local/bin/ghost-ws.py; pkill -f ghost-ws.py 2>/dev/null; OK "WS-epro removido."; PAUSA ;;
            3) systemctl disable --now stunnel4 2>/dev/null; OK "Stunnel detenido."; PAUSA ;;
            4) systemctl disable --now badvpn 2>/dev/null; rm -f /etc/systemd/system/badvpn.service; OK "BadVPN removido."; PAUSA ;;
            5) systemctl disable --now hysteria-server 2>/dev/null; pkill -x hysteria 2>/dev/null; OK "Hysteria2 removido."; PAUSA ;;
            6) systemctl disable --now ghost-ss 2>/dev/null; pkill -x ss-server 2>/dev/null; OK "Shadowsocks removido."; PAUSA ;;
            7) python3 -c "import json; c=json.load(open('/usr/local/etc/xray/config.json')); c['inbounds']=[i for i in c.get('inbounds',[]) if i.get('protocol')!='trojan']; json.dump(c, open('/usr/local/etc/xray/config.json','w'), indent=2)" 2>/dev/null; systemctl restart xray 2>/dev/null; OK "Trojan removido."; PAUSA ;;
            8) systemctl disable --now wg-quick@wg0 2>/dev/null; rm -f /etc/wireguard/wg0.conf; OK "WireGuard removido."; PAUSA ;;
            9) pkill -x cloudflared 2>/dev/null && OK "Tunel CDN detenido." || ERR "No habia tunel."; PAUSA ;;
            0) pop_crumb; break ;; *) ERR "Invalida."; sleep 1 ;;
        esac
    done
}

tunel_trycloudflare(){
    pgrep -x cloudflared >/dev/null 2>&1 && { pkill -x cloudflared; sleep 2; }
    if ! command -v cloudflared >/dev/null 2>&1; then
        local arch=amd64
        [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]] && arch=arm64
        wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb" -O /tmp/cf.deb \
            && dpkg -i /tmp/cf.deb >/dev/null 2>&1 && rm -f /tmp/cf.deb \
            || { ERR "No se pudo descargar."; PAUSA; return; }
    fi
    local puerto=80
    [[ -f /etc/systemd/system/ghost-ws.service ]] && \
        puerto=$(grep -o 'ghost-ws.py [0-9]*' /etc/systemd/system/ghost-ws.service | awk '{print $2}' | head -1)
    puerto=${puerto:-80}
    pgrep -f ghost-ws.py >/dev/null 2>&1 || { WARN "Instala WS-epro primero."; PAUSA; return; }
    nohup cloudflared tunnel --url "http://127.0.0.1:${puerto}" > /tmp/cf-tunnel.log 2>&1 &
    local url="" i
    for i in $(seq 1 15); do
        sleep 2
        url=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cf-tunnel.log | head -1)
        [[ -n "$url" ]] && break
    done
    [[ -n "$url" ]] && { OK "Tunel activo:"; printf '  %b%s%b\n' "$C_ACC" "$url" "$RS"; } || ERR "No se obtuvo URL."
    PAUSA
}

menu_protocolos(){
    push_crumb "Protocolos"
    while true; do
        header
        subtop "PROTOCOLOS / CONEXIONES"
        opt 1 "Xray VLESS+Reality"   2 "Xray WS (CDN)"
        opt 3 "OpenVPN"              4 "SSL Stunnel"
        opt 5 "Hysteria2 (UDP)"      6 "BadVPN (UDP GW)"
        opt 7 "WS-epro (WS->SSH)"    8 "Shadowsocks"
        opt 9 "Trojan"               10 "WireGuard"
        opt 11 "Estado protocolos"   12 "Quitar protocolos"
        opt 13 "Tunel CDN (prueba)"
        ui_row ""
        opt 0 "Volver"
        botline
        prompt; read -r op
        case "$op" in
            1) instalar_xray ;; 2) instalar_xray_ws ;; 3) instalar_openvpn ;;
            4) instalar_ssl_stunnel ;; 5) instalar_hysteria ;; 6) instalar_badvpn ;;
            7) instalar_wsepro ;; 8) instalar_shadowsocks ;; 9) instalar_trojan ;;
            10) instalar_wireguard ;; 11) estado_protocolos ;; 12) menu_quitar ;;
            13) tunel_trycloudflare ;;
            0) pop_crumb; break ;; *) ERR "Invalida."; sleep 1 ;;
        esac
    done
}

# ============================================================
#  TRAFICO
# ============================================================
trafico_activar(){
    local backend; backend=$(fw_backend)
    if [[ "$backend" == "nft" ]]; then
        WARN "nftables detectado. Esta funcion usa iptables (compat)."
    fi
    command -v iptables >/dev/null 2>&1 || { ERR "Instala iptables."; PAUSA; return; }
    iptables -N VPS-TRAFFIC 2>/dev/null || true
    iptables -F VPS-TRAFFIC 2>/dev/null
    local n=0 u
    while IFS= read -r u; do
        iptables -A VPS-TRAFFIC -m owner --uid-owner "$u" -j RETURN 2>/dev/null && n=$((n+1))
    done < <(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd)
    iptables -C OUTPUT -j VPS-TRAFFIC 2>/dev/null || iptables -A OUTPUT -j VPS-TRAFFIC 2>/dev/null
    [[ $n -gt 0 ]] && OK "Contadores activos para $n usuarios." || ERR "Fallo."
    PAUSA
}

trafico_ver(){
    echo; INFO "Consumo por usuario"
    printf '  %-16s %12s %s\n' "USUARIO" "USADO" "LIMITE(GB)"
    printf '  %b%s%b\n' "$C_DIM" "$(ui_line 58 $C_DIM)" "$RS"
    iptables -L VPS-TRAFFIC -v -x -n 2>/dev/null | awk '/owner UID match/ {print $2, $NF}' | while read -r bytes uidn; do
        local u mb lim
        u=$(id -un "$uidn" 2>/dev/null || echo "uid$uidn")
        mb=$(( bytes / 1048576 ))
        lim=$(cat "$TRAF_DIR/$u" 2>/dev/null || echo "-")
        printf '  %-16s %10d MB  %s\n' "$u" "$mb" "$lim"
    done
    PAUSA
}

trafico_limite(){
    local u g; read -r -p "  Usuario: " u
    id "$u" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    read -r -p "  Limite GB (0=sin limite): " g
    [[ "$g" =~ ^[0-9]+$ ]] || { ERR "Invalido."; PAUSA; return; }
    printf '%s\n' "$g" > "$TRAF_DIR/$u"
    OK "Limite = ${g}GB."
    PAUSA
}

trafico_cortar(){
    local cortados=0 f u g used
    for f in "$TRAF_DIR"/*; do
        [[ -f "$f" ]] || continue
        u=$(basename "$f"); g=$(cat "$f")
        [[ "$g" =~ ^[0-9]+$ && "$g" -gt 0 ]] || continue
        used=$(iptables -L VPS-TRAFFIC -v -x -n 2>/dev/null | awk -v uid="$(id -u "$u")" '$0 ~ "owner UID match "uid {print $2; exit}')
        [[ -n "$used" && $(( used / 1073741824 )) -ge "$g" ]] || continue
        if ! passwd -S "$u" 2>/dev/null | grep -q ' L '; then
            usermod -L "$u"; pkill_user "$u"
            INFO "$u bloqueado (${g}GB superados)."
            cortados=$((cortados+1))
        fi
    done
    [[ $cortados -eq 0 ]] && OK "Nadie supero su limite." || OK "Bloqueados: $cortados."
    PAUSA
}

trafico_reset(){
    iptables -Z VPS-TRAFFIC 2>/dev/null && OK "Contadores reseteados." || ERR "Cadena inexistente."
    PAUSA
}

menu_trafico(){
    push_crumb "Trafico"
    while true; do
        header
        subtop "TRAFICO POR USUARIO"
        opt 1 "Activar contadores"  4 "Cortar excedidos"
        opt 2 "Ver consumo"         5 "Reset contadores"
        opt 3 "Poner limite GB"
        ui_row ""
        opt 0 "Volver"
        botline
        prompt; read -r op
        case "$op" in
            1) trafico_activar ;; 2) trafico_ver ;; 3) trafico_limite ;;
            4) trafico_cortar ;; 5) trafico_reset ;;
            0) pop_crumb; break ;; *) ERR "Invalida."; sleep 1 ;;
        esac
    done
}

# ============================================================
#  WEBMIN
# ============================================================
instalar_webmin(){
    dpkg -l webmin >/dev/null 2>&1 || {
        apt update -y
        apt install -y curl wget gnupg2 software-properties-common
        local tmp; tmp=$(mktmp -d)
        if curl -fsSL -o "$tmp/setup.sh" https://raw.githubusercontent.com/webmin/webmin/master/setup-repos.sh; then
            sh "$tmp/setup.sh" -f
            apt update -y && apt install -y webmin
        else
            ERR "No se pudo descargar setup-repos.sh."
            return 1
        fi
        rm -rf "$tmp"
    }
    command -v ufw >/dev/null 2>&1 && ufw status | grep -q active && ufw allow 10000/tcp >/dev/null 2>&1 || true
    systemctl enable --now webmin 2>/dev/null
    sleep 1
    local wp; wp=$(grep -o '^port=[0-9]*' /etc/webmin/miniserv.conf 2>/dev/null | cut -d= -f2 | head -1); wp=${wp:-10000}
    local ip; ip=$(get_ipv4)
    pgrep -f miniserv >/dev/null 2>&1 \
        && { OK "Webmin activo :$wp"; printf '  https://%s:%s\n' "$ip" "$wp"; } \
        || ERR "Webmin no arranco."
    PAUSA
}

menu_webmin(){
    push_crumb "Webmin"
    while true; do
        header
        subtop "WEBMIN"
        opt 1 "Instalar Webmin"   4 "Cambiar puerto"
        opt 2 "Estado / reiniciar" 5 "Remover Webmin"
        opt 3 "Abrir puerto 10000"
        ui_row ""
        opt 0 "Volver"
        botline
        prompt; read -r op
        case "$op" in
            1) instalar_webmin ;;
            2) systemctl restart webmin 2>/dev/null; sleep 1; pgrep -f miniserv >/dev/null && OK "Corriendo." || ERR "No arranco."; PAUSA ;;
            3) ufw allow 10000/tcp 2>/dev/null && OK "Puerto abierto." || ERR "UFW no activo."; PAUSA ;;
            4) local p; read -r -p "  Nuevo puerto: " p; sed -i "s/^port=.*/port=$p/" /etc/webmin/miniserv.conf; systemctl restart webmin 2>/dev/null; OK "Puerto: $p."; PAUSA ;;
            5) systemctl stop webmin 2>/dev/null; apt purge -y webmin 2>/dev/null; rm -f /etc/apt/sources.list.d/webmin.list; OK "Removido."; PAUSA ;;
            0) pop_crumb; break ;; *) ERR "Invalida."; sleep 1 ;;
        esac
    done
}

# ============================================================
#  BACKUP
# ============================================================
backup_basico(){
    local dir=/root/backups file
    mkdir -p "$dir"
    file="$dir/backup-$(date +%F_%H%M).tar.gz"
    INFO "Creando backup..."
    dpkg --get-selections > /root/paquetes.txt 2>/dev/null
    tar czf "$file" /etc /root/paquetes.txt --exclude=/etc/ssl/private 2>/dev/null
    OK "Backup: $file ($(du -h "$file" | cut -f1))"
    PAUSA
}

restaurar_backup(){
    local dir=/root/backups f conf
    ls -lh "$dir"/*.tar.gz 2>/dev/null || { ERR "Sin backups."; PAUSA; return; }
    read -r -p "  Archivo (Enter = ultimo): " f
    [[ -z "$f" ]] && f=$(ls -t "$dir"/*.tar.gz 2>/dev/null | head -1)
    [[ -f "$f" ]] || f="$dir/$f"
    [[ -f "$f" ]] || { ERR "No encontrado."; PAUSA; return; }
    WARN "Esto pisa la configuracion actual de /etc."
    read -r -p "  Escribi RESTAURAR para confirmar: " conf
    [[ "$conf" != "RESTAURAR" ]] && { ERR "Cancelado."; PAUSA; return; }
    tar xzf "$f" -C / 2>/dev/null
    OK "Restaurado. Reinicia el VPS recomendado."
    PAUSA
}

menu_backup(){
    push_crumb "Backup"
    while true; do
        header
        subtop "BACKUP / RESTAURAR"
        opt 1 "Crear backup"  2 "Restaurar backup"
        ui_row ""
        opt 0 "Volver"
        botline
        prompt; read -r op
        case "$op" in
            1) backup_basico ;; 2) restaurar_backup ;;
            0) pop_crumb; break ;; *) ERR "Invalida."; sleep 1 ;;
        esac
    done
}

# ============================================================
#  HERRAMIENTAS
# ============================================================
instalar_comando_global(){
    local dest=/usr/local/bin/ghostpanel
    cp "$(readlink -f "$0")" "$dest" 2>/dev/null && chmod +x "$dest" || { ERR "Fallo."; PAUSA; return; }
    grep -q "alias ghostpanel=" /root/.bashrc 2>/dev/null || printf "alias ghostpanel='%s'\n" "$dest" >> /root/.bashrc
    OK "Instalado: ejecuta con 'ghostpanel'."
    PAUSA
}

auto_menu(){
    grep -q "GHOST-AUTOMENU" "$HOME/.bashrc" 2>/dev/null && { OK "Ya estaba activo."; PAUSA; return; }
    cat >> "$HOME/.bashrc" <<'AMEOF'
# GHOST-AUTOMENU-INICIO
case "$-" in *i*) [ -x /usr/local/bin/ghostpanel ] && /usr/local/bin/ghostpanel ;; esac
# GHOST-AUTOMENU-FIN
AMEOF
    OK "Auto-menu activado."
    PAUSA
}

quitar_auto_menu(){
    sed -i '/GHOST-AUTOMENU-INICIO/,/GHOST-AUTOMENU-FIN/d' "$HOME/.bashrc" 2>/dev/null
    OK "Auto-menu desactivado."
    PAUSA
}

auto_update(){
    [[ -z "$REPO_RAW" ]] && { ERR "REPO_RAW sin configurar."; PAUSA; return; }

    local cur_ver new_ver
    cur_ver=$(grep -m1 -oE 'GHOST PANEL v[0-9.]+' /usr/local/bin/ghostpanel 2>/dev/null | awk '{print $3}')
    INFO "Version actual: ${cur_ver:-desconocida}"
    INFO "Descargando desde GitHub..."

    local tmp; tmp=$(mktemp /tmp/ghost.XXXXXX)
    if ! wget -q "$REPO_RAW" -O "$tmp" 2>/tmp/wget.err; then
        ERR "Fallo la descarga:"
        head -5 /tmp/wget.err 2>/dev/null
        rm -f "$tmp" /tmp/wget.err
        PAUSA; return
    fi
    rm -f /tmp/wget.err

    sed -i 's/\r$//' "$tmp"

    new_ver=$(grep -m1 -oE 'GHOST PANEL v[0-9.]+' "$tmp" 2>/dev/null | awk '{print $3}')
    INFO "Version descargada: ${new_ver:-desconocida}"

    if [[ "$cur_ver" == "$new_ver" && -n "$cur_ver" ]]; then
        WARN "Ya tenes la misma version (${cur_ver}). Nada que actualizar."
        rm -f "$tmp"
        PAUSA; return
    fi

    if ! bash -n "$tmp" 2>/tmp/syn.err; then
        ERR "Sintaxis rota en la version descargada. NO se reemplazo."
        head -3 /tmp/syn.err 2>/dev/null
        rm -f "$tmp" /tmp/syn.err
        PAUSA; return
    fi
    rm -f /tmp/syn.err

    local bk="/usr/local/bin/ghostpanel.bak.$(date +%s)"
    cp -f /usr/local/bin/ghostpanel "$bk" 2>/dev/null && INFO "Backup: $bk"

    install -m 755 "$tmp" /usr/local/bin/ghostpanel
    cp -f "$tmp" "$(readlink -f "$0")" 2>/dev/null || true
    rm -f "$tmp"

    OK "Actualizado: ${cur_ver:-?} -> ${new_ver:-?}"
    WARN "Salir y reabrir el panel para ver los cambios."
    PAUSA
}

ver_logs(){
    echo; INFO "Ultimas 40 lineas del log"
    tail -40 "$LOG_PANEL" 2>/dev/null || echo "  (vacio)"
    PAUSA
}

cambiar_tema(){
    local t
    echo "  Temas: ghost | matrix | dracula | minimal"
    read -r -p "  Nuevo tema: " t
    case "$t" in
        ghost|matrix|dracula|minimal)
            sed -i "s/^PANEL_THEME=.*/PANEL_THEME=$t/" "$CONF_FILE"
            OK "Tema cambiado a '$t'. Reabre el panel."
            ;;
        *) ERR "Tema invalido." ;;
    esac
    PAUSA
}

doctor(){
    echo; INFO "Ghost Panel doctor"
    printf '  %b%s%b\n' "$C_DIM" "$(ui_line 58 $C_DIM)" "$RS"
    local ok=0 fail=0
    local check_cmd=(bash python3 curl wget openssl systemctl iptables)
    local c
    for c in "${check_cmd[@]}"; do
        if command -v "$c" >/dev/null 2>&1; then
            printf '  %b●%b %-12s %s\n' "$C_OK" "$RS" "$c" "$(command -v "$c")"
            ok=$((ok+1))
        else
            printf '  %b○%b %-12s faltante\n' "$C_ERR" "$RS" "$c"
            fail=$((fail+1))
        fi
    done
    for svc in ssh sshd vps-checkuser xray ghost-ws ghost-ss badvpn; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                printf '  %b●%b svc %-18s activo\n' "$C_OK" "$RS" "$svc"
                ok=$((ok+1))
            else
                printf '  %b○%b svc %-18s detenido\n' "$C_WARN" "$RS" "$svc"
            fi
        fi
    done
    [[ -n "${LICENSE_URL:-}" ]] && printf '  %b●%b LICENSE_URL configurado\n' "$C_OK" "$RS" || { printf '  %b○%b LICENSE_URL vacio\n' "$C_ERR" "$RS"; fail=$((fail+1)); }
    [[ -f /etc/cron.d/ghost-panel-vencidos ]] && printf '  %b●%b Cron de vencidos\n' "$C_OK" "$RS" || printf '  %b○%b Cron no instalado\n' "$C_WARN" "$RS"
    printf '  %b%s%b\n' "$C_DIM" "$(ui_line 58 $C_DIM)" "$RS"
    printf '  Total: %b%d OK%b, %b%d problemas%b\n' "$C_OK" "$ok" "$RS" "$C_ERR" "$fail" "$RS"
    PAUSA
}

cli_cmd(){
    local c1="${1:-}" c2="${2:-}" c3="${3:-}"
    case "$c1" in
        users)
            case "$c2" in
                list) listar_usuarios_nonint ;;
                create) shift 3; crear_usuario_cli "$@" ;;
                delete) [[ -n "$c3" ]] && userdel -r "$c3" 2>/dev/null && OK "Eliminado: $c3" ;;
                *) echo "Uso: ghostpanel users {list|create|delete} [args]"; return 1 ;;
            esac ;;
        status)
            printf 'IP: %s\nHost: %s\nLicencia: %s\n' \
                "$(get_ipv4)" "$(hostname)" "${LICENSE_OK:- -}"
            ;;
        doctor) doctor ;;
        *) echo "Ghost Panel - comandos: users | status | doctor"; return 1 ;;
    esac
}

listar_usuarios_nonint(){
    printf '%-16s %-22s %s\n' "USUARIO" "EXPIRA" "ESTADO"
    while IFS= read -r u; do
        local exp est
        exp=$(chage -l "$u" 2>/dev/null | awk -F': ' '/Password expires/{print $2}')
        est=$(passwd -S "$u" 2>/dev/null | awk '{print $2}')
        printf '%-16s %-22s %s\n' "$u" "$exp" "$est"
    done < <(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd)
}

crear_usuario_cli(){
    local usu="" dias=30 maxc=1 clave=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dias) dias="$2"; shift 2 ;;
            --max)  maxc="$2"; shift 2 ;;
            --pass) clave="$2"; shift 2 ;;
            *) usu="$1"; shift ;;
        esac
    done
    [[ -z "$usu" ]] && { ERR "Uso: ghostpanel users create USER --dias 30 --pass 1234"; return 1; }
    id "$usu" >/dev/null 2>&1 && { ERR "Ya existe."; return 1; }
    useradd -m -s /bin/bash "$usu"
    [[ -n "$clave" ]] && printf '%s:%s\n' "$usu" "$clave" | chpasswd
    chage -M "$dias" -E "$(date -d "+${dias} days" +%Y-%m-%d)" "$usu"
    printf '%s\n' "$maxc" > "$LIMITS_DIR/$usu"
    usermod -aG vpsusers "$usu" 2>/dev/null || true
    xray_usuario add "$usu" 2>/dev/null || true
    OK "Usuario '$usu' creado (${dias}d, max=${maxc})."
}

menu_herramientas(){
    push_crumb "Herramientas"
    while true; do
        header
        subtop "HERRAMIENTAS"
        opt 1 "Instalar comando global"  4 "Auto-update script"
        opt 2 "Activar auto-menu"        5 "CheckUser API"
        opt 3 "Quitar auto-menu"         6 "Ver logs"
        opt 7 "Cambiar tema"             8 "Doctor (diagnostico)"
        ui_row ""
        opt 0 "Volver"
        botline
        prompt; read -r op
        case "$op" in
            1) instalar_comando_global ;; 2) auto_menu ;; 3) quitar_auto_menu ;;
            4) auto_update ;; 5) menu_checkuser ;; 6) ver_logs ;;
            7) cambiar_tema ;; 8) doctor ;;
            0) pop_crumb; break ;; *) ERR "Invalida."; sleep 1 ;;
        esac
    done
}

# ============================================================
#  MAIN
# ============================================================
main_menu(){
    push_crumb "Inicio"
    while true; do
        header
        subtop "PRINCIPAL"
        opt 1 "Usuarios SSH"       2 "Protocolos"
        opt 3 "Seguridad"          4 "Sistema"
        opt 5 "Herramientas"       6 "Webmin"
        opt 7 "Backup"             8 "Diagnostico"
        ui_row ""
        opt 0 "Salir"
        botline
        prompt; read -r op
        case "$op" in
            1) menu_usuarios ;;    2) menu_protocolos ;;
            3) menu_seguridad ;;   4) menu_sistema ;;
            5) menu_herramientas ;; 6) menu_webmin ;;
            7) menu_backup ;;      8) diagnostico ;;
            0) printf '%bHasta luego.%b\n' "$C_OK" "$RS"; exit 0 ;;
            *) ERR "Invalida."; sleep 1 ;;
        esac
    done
}

# ARRANQUE
require_root
check_deps || exit 1

if [[ $# -gt 0 ]]; then
    case "$1" in
        users|status|doctor) cli_cmd "$@"; exit $? ;;
        --version|-v) echo "Ghost Panel v3.1.1"; exit 0 ;;
        --help|-h)
            cat <<HELP
Ghost Panel v3.1.1
  ghostpanel                    Menu interactivo
  ghostpanel users list
  ghostpanel users create U --dias 30 --max 1 --pass 1234
  ghostpanel users delete U
  ghostpanel status
  ghostpanel doctor
HELP
            exit 0 ;;
    esac
fi

if ! bash -n "$0" 2>/dev/null; then
    printf '%b[FATAL]%b Script con errores de sintaxis.\n' "$C_ERR" "$RS"
    exit 1
fi

bootstrap_dirs
gate_licencia
main_menu
