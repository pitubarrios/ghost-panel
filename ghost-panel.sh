#!/usr/bin/env bash
# ============================================================
#  GHOST PANEL by Jorge Barrios  -  Administracion de VPS (Ubuntu)
#  Menu SSH: usuarios, trafico, backup, banner + Webmin
#  Uso:  sudo bash vps-manager.sh
# ============================================================

set -u

ROJO='\033[1;31m'; VERDE='\033[1;32m'; AMARILLO='\033[1;33m'
AZUL='\033[1;34m'; CIAN='\033[1;36m'; BLANCO='\033[1;37m'
NC='\033[0m'

# --- LICENCIA / KEY -------------------------------------------
SECRET_KEY='Copiaesta**'
KEY_FILE='/etc/vps-manager.key'
PREFIJO_KEY='VPSJB1'
REPO_RAW='https://raw.githubusercontent.com/pitubarrios/vps-manager/refs/heads/main/ghost-panel.sh'
LICENSE_URL=''
GRACE_SECS=259200
LICENSE_CACHE='/etc/vps-license.cache'

machine_hash(){
    if [[ -f /etc/machine-id ]]; then
        sha256sum /etc/machine-id 2>/dev/null | cut -c1-12
    else
        sha256sum /etc/hostname 2>/dev/null | cut -c1-12
    fi
}

validar_key(){
    local KEY BODY B64 SIG SIGC PAYLOAD NOMBRE EXP MACH
    KEY=$(echo "$1" | tr -d '[:space:]')
    case "$KEY" in ${PREFIJO_KEY}-*|VPSMGR1-*) ;; *) return 1 ;; esac
    BODY=${KEY#*-}
    SIG=${BODY##*-}
    B64=${BODY%-*}
    [[ -n "$B64" && -n "$SIG" && "$B64" != "$SIG" ]] || return 1
    SIGC=$(printf '%s' "$B64" | openssl dgst -sha256 -hmac "$SECRET_KEY" 2>/dev/null | awk '{print $NF}' | cut -c1-16 | tr 'a-f' 'A-F')
    [[ "$SIGC" == "$SIG" ]] || return 1
    PAYLOAD=$(printf '%s' "$B64" | base64 -d 2>/dev/null) || return 1
    NOMBRE=${PAYLOAD%%|*}; PAYLOAD=${PAYLOAD#*|}
    EXP=${PAYLOAD%%|*};  MACH=${PAYLOAD#*|}
    [[ -n "$NOMBRE" && -n "$EXP" ]] || return 1
    [[ "$EXP" != "0" && "$(date +%s)" -gt "$EXP" ]] && return 1
    if [[ -n "$MACH" && "$MACH" != "$(machine_hash)" ]]; then return 1; fi
    KEY_NOMBRE="$NOMBRE"
    KEY_EXP="$EXP"
    return 0
}

consultar_licencia(){
    local KEY="$1" RESP
    [[ -z "$LICENSE_URL" ]] && return 2
    RESP=$(curl -G -fsS --max-time 10 -A "Mozilla/5.0" "$LICENSE_URL" \
        --data-urlencode "key=$KEY" --data-urlencode "id=$(machine_hash)" 2>/dev/null)
    [[ -z "$RESP" ]] && return 2
    if echo "$RESP" | grep -q '"valid":[[:space:]]*true'; then
        LICENSE_NOMBRE=$(echo "$RESP" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
        LICENSE_DIAS=$(echo "$RESP" | grep -o '"days_left"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*$')
        return 0
    fi
    return 1
}

gate_licencia(){
    local INTENTOS=0 K RC
    FR_TOP
    FR_TXT "  ${AMARILLO}$(T t_lic_req)${NC} - $(T t_panel_jb)"
    FR_MID
    FR_TXT "  $(T t_id_srv): ${BLANCO}$(machine_hash)${NC}"

    if [[ -z "$LICENSE_URL" ]]; then
        FR_TXT "  ${ROJO}$(T t_online_req)${NC}"
        FR_TXT "  $(T t_online_req2)"
        FR_BOT
        exit 1
    fi

    INFO "Validacion online activa."
    if [[ -f "$KEY_FILE" ]]; then
        K=$(cat "$KEY_FILE" 2>/dev/null)
        consultar_licencia "$K"; RC=$?
        if [[ $RC -eq 0 ]]; then
            date +%s > "$LICENSE_CACHE" 2>/dev/null
            LICENSE_OK="${LICENSE_NOMBRE:-cliente}"
            [[ -n "${LICENSE_DIAS:-}" ]] && LICENSE_EXP=$(( $(date +%s) + LICENSE_DIAS * 86400 ))
            return 0
        elif [[ $RC -eq 2 ]]; then
            if [[ -f "$LICENSE_CACHE" ]] && (( $(date +%s) - $(cat "$LICENSE_CACHE" 2>/dev/null || echo 0) < GRACE_SECS )); then
                LICENSE_OK="modo gracia (servidor caido)"
                return 0
            fi
            ERR "Servidor de licencias no responde y no hay gracia acumulada."
        fi
    fi
    while [[ $INTENTOS -lt 3 ]]; do
        read -r -p " INGRESE SU KEY > " K
        consultar_licencia "$K"; RC=$?
        if [[ $RC -eq 0 ]]; then
            echo "$K" > "$KEY_FILE" 2>/dev/null
            date +%s > "$LICENSE_CACHE" 2>/dev/null
            LICENSE_OK="${LICENSE_NOMBRE:-cliente}"
            [[ -n "${LICENSE_DIAS:-}" ]] && LICENSE_EXP=$(( $(date +%s) + LICENSE_DIAS * 86400 ))
            OK "Licencia aceptada. Bienvenido, ${LICENSE_OK}."
            sleep 1
            return 0
        elif [[ $RC -eq 2 ]]; then
            ERR "Servidor de licencias no responde. Intenta mas tarde."
        else
            ERR "Key invalida, expirada, revocada o de otro servidor."
        fi
        INTENTOS=$((INTENTOS+1))
    done
    echo -e "${ROJO}Sin licencia valida. Contacta al administrador.${NC}"
    exit 1
}

# ---------- MULTI-IDIOMA ----------
IDIOMA="es"
[[ -f /etc/vps-manager.lang ]] && IDIOMA=$(cat /etc/vps-manager.lang 2>/dev/null)
declare -A TXT_ES TXT_EN
TXT_ES[t_menu_principal]="MENU PRINCIPAL"; TXT_EN[t_menu_principal]="MAIN MENU"
TXT_ES[t_usuarios]="Usuarios SSH"; TXT_EN[t_usuarios]="SSH Users"
TXT_ES[t_protocolos]="Protocolos"; TXT_EN[t_protocolos]="Protocols"
TXT_ES[t_seguridad]="Seguridad"; TXT_EN[t_seguridad]="Security"
TXT_ES[t_sistema]="Sistema y Recursos"; TXT_EN[t_sistema]="System & Resources"
TXT_ES[t_herramientas]="Herramientas"; TXT_EN[t_herramientas]="Tools"
TXT_ES[t_webmin]="Webmin"; TXT_EN[t_webmin]="Webmin"
TXT_ES[t_backup]="Backup / Restaurar"; TXT_EN[t_backup]="Backup / Restore"
TXT_ES[t_diagnostico]="Diagnostico"; TXT_EN[t_diagnostico]="Diagnostics"
TXT_ES[t_servidor_id]="Servidor ID"; TXT_EN[t_servidor_id]="Server ID"
TXT_ES[t_salir]="Salir"; TXT_EN[t_salir]="Exit"
TXT_ES[t_opcion]="Opcion"; TXT_EN[t_opcion]="Option"
TXT_ES[t_volver]="Volver"; TXT_EN[t_volver]="Back"
TXT_ES[t_sub_usuarios]="USUARIOS SSH"; TXT_EN[t_sub_usuarios]="SSH USERS"
TXT_ES[t_crear]="Crear usuario"; TXT_EN[t_crear]="Create user"
TXT_ES[t_listar]="Listar usuarios"; TXT_EN[t_listar]="List users"
TXT_ES[t_clave]="Cambiar clave"; TXT_EN[t_clave]="Change password"
TXT_ES[t_bloquear]="Bloquear/Desbl."; TXT_EN[t_bloquear]="Block/Unblock"
TXT_ES[t_renovar]="Renovar usuario"; TXT_EN[t_renovar]="Renew user"
TXT_ES[t_limite]="Cambiar limite"; TXT_EN[t_limite]="Change limit"
TXT_ES[t_eliminar]="Eliminar usuario"; TXT_EN[t_eliminar]="Delete user"
TXT_ES[t_vencidos]="Eliminar vencidos"; TXT_EN[t_vencidos]="Delete expired"
TXT_ES[t_test]="Crear test SSH"; TXT_EN[t_test]="Create SSH test"
TXT_ES[t_conexiones]="Conexiones online"; TXT_EN[t_conexiones]="Online connections"
TXT_ES[t_desconectar]="Desconectar usr"; TXT_EN[t_desconectar]="Disconnect user"
TXT_ES[t_sub_seg]="SEGURIDAD"; TXT_EN[t_sub_seg]="SECURITY"
TXT_ES[t_fail2ban]="Fail2ban"; TXT_EN[t_fail2ban]="Fail2ban"
TXT_ES[t_limiter_on]="Limiter (activar)"; TXT_EN[t_limiter_on]="Limiter (enable)"
TXT_ES[t_limiter_off]="Quitar limiter"; TXT_EN[t_limiter_off]="Remove limiter"
TXT_ES[t_puerto_ssh]="Cambiar puerto SSH"; TXT_EN[t_puerto_ssh]="Change SSH port"
TXT_ES[t_ver_puertos]="Ver puertos"; TXT_EN[t_ver_puertos]="Show ports"
TXT_ES[t_abrir_puerto]="Abrir puerto"; TXT_EN[t_abrir_puerto]="Open port"
TXT_ES[t_banner]="Banner SSH / HC"; TXT_EN[t_banner]="SSH / HC banner"
TXT_ES[t_sub_banner]="BANNER SSH / HTTP CUSTOM"; TXT_EN[t_sub_banner]="SSH / HTTP CUSTOM BANNER"
TXT_ES[t_banner_html]="Banner HTML dinamico"; TXT_EN[t_banner_html]="Dynamic HTML banner"
TXT_ES[t_banner_msg]="Mensajes banner SSH"; TXT_EN[t_banner_msg]="SSH banner messages"
TXT_ES[t_banner_del]="Eliminar banner"; TXT_EN[t_banner_del]="Remove banner"
TXT_ES[t_banner_cu]="CheckUser + banner"; TXT_EN[t_banner_cu]="CheckUser + banner"
TXT_ES[t_sub_sistema]="SISTEMA Y RECURSOS"; TXT_EN[t_sub_sistema]="SYSTEM & RESOURCES"
TXT_ES[t_monitoreo]="Monitoreo"; TXT_EN[t_monitoreo]="Monitoring"
TXT_ES[t_optimizar]="Optimizar (BBR)"; TXT_EN[t_optimizar]="Optimize (BBR)"
TXT_ES[t_swap]="Agregar swap"; TXT_EN[t_swap]="Add swap"
TXT_ES[t_zram]="Agregar zram"; TXT_EN[t_zram]="Add zram"
TXT_ES[t_mantenimiento]="Mantenimiento"; TXT_EN[t_mantenimiento]="Maintenance"
TXT_ES[t_hostname]="Cambiar hostname"; TXT_EN[t_hostname]="Change hostname"
TXT_ES[t_update]="Update sistema"; TXT_EN[t_update]="System update"
TXT_ES[t_reiniciar]="Reiniciar VPS"; TXT_EN[t_reiniciar]="Reboot VPS"
TXT_ES[t_sub_herr]="HERRAMIENTAS DEL PANEL"; TXT_EN[t_sub_herr]="PANEL TOOLS"
TXT_ES[t_global]="Comando global"; TXT_EN[t_global]="Global command"
TXT_ES[t_automenu_on]="Auto-menu login"; TXT_EN[t_automenu_on]="Auto-menu on login"
TXT_ES[t_automenu_off]="Quitar auto-menu"; TXT_EN[t_automenu_off]="Remove auto-menu"
TXT_ES[t_autoupdate]="Auto-update script"; TXT_EN[t_autoupdate]="Self-update script"
TXT_ES[t_checkuser]="CheckUser API"; TXT_EN[t_checkuser]="CheckUser API"
TXT_ES[t_idioma]="Cambiar idioma"; TXT_EN[t_idioma]="Change language"
TXT_ES[t_sub_backup]="BACKUP / RESTAURAR"; TXT_EN[t_sub_backup]="BACKUP / RESTORE"
TXT_ES[t_backup_crear]="Crear backup"; TXT_EN[t_backup_crear]="Create backup"
TXT_ES[t_backup_restaurar]="Restaurar backup"; TXT_EN[t_backup_restaurar]="Restore backup"
TXT_ES[t_sub_prot]="PROTOCOLOS / CONEXIONES"; TXT_EN[t_sub_prot]="PROTOCOLS / CONNECTIONS"
TXT_ES[t_xray]="Xray VLESS+Reality"; TXT_EN[t_xray]="Xray VLESS+Reality"
TXT_ES[t_xray_ws]="Xray WS (CDN)"; TXT_EN[t_xray_ws]="Xray WS (CDN)"
TXT_ES[t_openvpn]="OpenVPN"; TXT_EN[t_openvpn]="OpenVPN"
TXT_ES[t_stunnel]="SSL Stunnel 443"; TXT_EN[t_stunnel]="SSL Stunnel 443"
TXT_ES[t_hysteria]="Hysteria2 (UDP)"; TXT_EN[t_hysteria]="Hysteria2 (UDP)"
TXT_ES[t_badvpn]="BadVPN (UDP GW)"; TXT_EN[t_badvpn]="BadVPN (UDP GW)"
TXT_ES[t_wsepro]="WS-epro (WS->SSH)"; TXT_EN[t_wsepro]="WS-epro (WS->SSH)"
TXT_ES[t_shadowsocks]="Shadowsocks"; TXT_EN[t_shadowsocks]="Shadowsocks"
TXT_ES[t_trojan]="Trojan"; TXT_EN[t_trojan]="Trojan"
TXT_ES[t_wireguard]="WireGuard"; TXT_EN[t_wireguard]="WireGuard"
TXT_ES[t_estado_prot]="Estado protocolos"; TXT_EN[t_estado_prot]="Protocols status"
TXT_ES[t_quitar]="Quitar protocolo"; TXT_EN[t_quitar]="Remove protocol"
TXT_ES[t_sub_webmin]="WEBMIN"; TXT_EN[t_sub_webmin]="WEBMIN"
TXT_ES[t_webmin_inst]="Instalar Webmin"; TXT_EN[t_webmin_inst]="Install Webmin"
TXT_ES[t_estado_svc]="Estado servicio"; TXT_EN[t_estado_svc]="Service status"
TXT_ES[t_abrir_10000]="Abrir puerto 10000"; TXT_EN[t_abrir_10000]="Open port 10000"
TXT_ES[t_cambiar_puerto]="Cambiar puerto"; TXT_EN[t_cambiar_puerto]="Change port"
TXT_ES[t_remover_webmin]="Remover Webmin"; TXT_EN[t_remover_webmin]="Remove Webmin"
TXT_ES[t_sub_cu]="CHECKUSER API"; TXT_EN[t_sub_cu]="CHECKUSER API"
TXT_ES[t_cu_inst]="Instalar / reinstalar"; TXT_EN[t_cu_inst]="Install / reinstall"
TXT_ES[t_cu_probar]="Probar consulta"; TXT_EN[t_cu_probar]="Test query"
TXT_ES[t_cu_token]="Ver token y puerto"; TXT_EN[t_cu_token]="Show token & port"
TXT_ES[t_remover]="Remover"; TXT_EN[t_remover]="Remove"
TXT_ES[t_sub_trafico]="TRAFICO POR USUARIO"; TXT_EN[t_sub_trafico]="PER-USER TRAFFIC"
TXT_ES[t_tr_activar]="Activar contadores"; TXT_EN[t_tr_activar]="Enable counters"
TXT_ES[t_tr_ver]="Ver consumo"; TXT_EN[t_tr_ver]="View usage"
TXT_ES[t_tr_limite]="Poner limite (GB)"; TXT_EN[t_tr_limite]="Set limit (GB)"
TXT_ES[t_tr_cortar]="Cortar excedidos"; TXT_EN[t_tr_cortar]="Cut exceeded"
TXT_ES[t_tr_reset]="Reset contadores"; TXT_EN[t_tr_reset]="Reset counters"
TXT_ES[t_sub_quitar]="QUITAR PROTOCOLOS"; TXT_EN[t_sub_quitar]="REMOVE PROTOCOLS"
TXT_ES[t_q_xray]="Xray completo"; TXT_EN[t_q_xray]="Xray (full)"
TXT_ES[t_panel]="Panel de administracion"; TXT_EN[t_panel]="Administration panel"
TXT_ES[t_ram]="RAM"; TXT_EN[t_ram]="RAM"
TXT_ES[t_cpu]="CPU"; TXT_EN[t_cpu]="CPU"
TXT_ES[t_disco]="Disco"; TXT_EN[t_disco]="Disk"
TXT_ES[t_online]="Online"; TXT_EN[t_online]="Online"
TXT_ES[t_licencia]="Licencia"; TXT_EN[t_licencia]="License"
TXT_ES[t_lic_req]="LICENCIA REQUERIDA"; TXT_EN[t_lic_req]="LICENSE REQUIRED"
TXT_ES[t_panel_jb]="GHOST PANEL by Jorge Barrios"; TXT_EN[t_panel_jb]="GHOST PANEL by Jorge Barrios"
TXT_ES[t_id_srv]="ID de este servidor"; TXT_EN[t_id_srv]="ID of this server"
TXT_ES[t_online_req]="VALIDACION ONLINE OBLIGATORIA"; TXT_EN[t_online_req]="ONLINE VALIDATION REQUIRED"
TXT_ES[t_online_req2]="LICENSE_URL no configurado. Baja la version oficial."; TXT_EN[t_online_req2]="LICENSE_URL not set. Get the official release."
TXT_ES[t_opinv]="Opcion invalida."; TXT_EN[t_opinv]="Invalid option."
TXT_ES[t_cf_test]="Tunel CDN (prueba)"; TXT_EN[t_cf_test]="CDN tunnel (test)"
TXT_ES[t_q_tunnel]="Tunel CDN (cloudflared)"; TXT_EN[t_q_tunnel]="CDN tunnel (cloudflared)"
TXT_ES[t_dropbear]="Dropbear"; TXT_EN[t_dropbear]="Dropbear"
TXT_ES[t_udp_custom]="UDP Custom"; TXT_EN[t_udp_custom]="UDP Custom"
TXT_ES[t_slowdns]="SlowDNS (dnstt)"; TXT_EN[t_slowdns]="SlowDNS (dnstt)"
TXT_ES[t_ver_links]="Ver enlaces"; TXT_EN[t_ver_links]="Show links"

T(){
    if [[ "$IDIOMA" == "en" && -n "${TXT_EN[$1]:-}" ]]; then echo "${TXT_EN[$1]}"; else echo "${TXT_ES[$1]:-$1}"; fi
}

seleccionar_idioma(){
    [[ -f /etc/vps-manager.lang ]] && { IDIOMA=$(cat /etc/vps-manager.lang 2>/dev/null); return; }
    echo
    echo -e "  ${CIAN}Idioma / Language:${NC}"
    echo    "   1) Español"
    echo    "   2) English"
    read -r -p "   > " L
    case "$L" in 2) IDIOMA="en";; *) IDIOMA="es";; esac
    echo "$IDIOMA" > /etc/vps-manager.lang 2>/dev/null
}

PAUSA(){ echo -e "\n${AMARILLO}Presiona ENTER para continuar...${NC}"; read -r; }

# ---------- HELPERS DE PRODUCCION ----------
LOG_PANEL='/var/log/ghost-panel.log'
LINKS_FILE='/root/vps-links.txt'
IP_CACHE_FILE='/tmp/vps-ip.cache'
USUARIOS_DIR='/etc/vps-users'
PROTEGIDOS_NOMBRES='root daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc gnats nobody systemd-network systemd-resolve systemd-timesync syslog messagebus _apt uuidd tcpdump sshd landscape pollinate ubuntu debian admin ec2-user cloud-user vpsmgr dnstt'

vps_arch(){
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        armv7l|armhf) echo arm ;;
        *) uname -m ;;
    esac
}

vps_log(){
    local NIV=${1:-INFO}; shift || true
    mkdir -p "$(dirname "$LOG_PANEL")" 2>/dev/null
    echo "$(date '+%F %T') [$NIV] $*" >> "$LOG_PANEL" 2>/dev/null || true
}

ip_publica(){
    local ip ahora mtime=0
    ahora=$(date +%s)
    if [[ -f "$IP_CACHE_FILE" ]]; then
        mtime=$(stat -c %Y "$IP_CACHE_FILE" 2>/dev/null || echo 0)
        if (( ahora - mtime < 3600 )); then
            cat "$IP_CACHE_FILE"
            return 0
        fi
    fi
    ip=$(curl -4 -fsS --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    printf '%s' "$ip" > "$IP_CACHE_FILE" 2>/dev/null
    printf '%s' "$ip"
}

guardar_enlace(){
    local TITULO="$1" CUERPO="$2"
    mkdir -p "$(dirname "$LINKS_FILE")"
    {
        echo "===== $(date '+%F %T')  ${TITULO} ====="
        echo "$CUERPO"
        echo
    } >> "$LINKS_FILE"
    chmod 600 "$LINKS_FILE" 2>/dev/null || true
}

usuario_protegido(){
    local U="${1:-}" UIDN
    [[ -z "$U" ]] && return 0
    echo " $PROTEGIDOS_NOMBRES " | grep -q " $U " && return 0
    UIDN=$(id -u "$U" 2>/dev/null || echo 0)
    [[ "$UIDN" -lt 1000 ]] && return 0
    return 1
}

pedir_usuario_ok(){
    local _n
    read -r -p "Usuario: " _n
    if [[ -z "$_n" ]]; then ERR "Nombre vacio."; return 1; fi
    if ! id "$_n" >/dev/null 2>&1; then ERR "No existe."; return 1; fi
    if usuario_protegido "$_n"; then ERR "Usuario protegido del sistema: $_n"; vps_log WARN "intento sobre usuario protegido: $_n"; return 1; fi
    printf -v "$1" '%s' "$_n"
    return 0
}

nombre_usuario_valido(){
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

usuario_fecha_cuenta(){
    LC_ALL=C LANG=C chage -l "$1" 2>/dev/null | awk -F': ' '/Account expires/{print $2}'
}

cron_vencidos_instalar(){
    cat > /usr/local/bin/vps-cron-diario.sh <<'CRONEOF'
#!/usr/bin/env bash
LOG=/var/log/ghost-panel.log
HOY=$(date +%Y-%m-%d)
PROTEGIDOS='root daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc gnats nobody systemd-network systemd-resolve systemd-timesync syslog messagebus _apt uuidd tcpdump sshd landscape pollinate ubuntu debian admin ec2-user cloud-user vpsmgr dnstt'
log(){ echo "$(date '+%F %T') [CRON] $*" >> "$LOG" 2>/dev/null; }
awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd | while read -r U; do
    echo " $PROTEGIDOS " | grep -q " $U " && continue
    EXP=$(LC_ALL=C LANG=C chage -l "$U" 2>/dev/null | awk -F': ' '/Account expires/{gsub(/^ +/,"",$2); print $2}')
    [[ -z "$EXP" || "$EXP" == "never" ]] && continue
    N=$(date -d "$EXP" +%Y-%m-%d 2>/dev/null) || continue
    if [[ "$N" < "$HOY" ]]; then
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
            clients=ib.get("settings",{}).get("clients",[])
            if proto in ("vless","vmess"):
                ib["settings"]["clients"]=[x for x in clients if x.get("id")!=uid and x.get("email")!=u]
            elif proto=="trojan":
                ib["settings"]["clients"]=[x for x in clients if x.get("password")!=tp and x.get("email")!=u]
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
    local ACC="$1" USU="$2"
    python3 - "$ACC" "$USU" <<'PY'
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
        for k,v in meta.items():
            f.write(f"{k}={v}\n")
    os.chmod(meta_p, 0o600)
    if not os.path.isfile(cfgp):
        raise SystemExit(0)
    try:
        cfg = json.load(open(cfgp))
    except Exception:
        raise SystemExit(0)
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
                clients = ib.get("settings",{}).get("clients",[])
                if proto in ("vless","vmess"):
                    ib["settings"]["clients"] = [c for c in clients if c.get("id")!=uid and c.get("email")!=user]
                elif proto == "trojan":
                    ib["settings"]["clients"] = [c for c in clients if c.get("password")!=tp and c.get("email")!=user]
            json.dump(cfg, open(cfgp,"w"), indent=2)
        except Exception:
            pass
    try:
        os.remove(meta_p)
    except FileNotFoundError:
        pass
PY
    [[ -f /usr/local/etc/xray/config.json ]] && systemctl restart xray 2>/dev/null || true
}

ghost_bootstrap(){
    mkdir -p "$USUARIOS_DIR" /etc/vps-limits /etc/vps-trafico
    touch "$LOG_PANEL" 2>/dev/null
    chmod 640 "$LOG_PANEL" 2>/dev/null || true
    # Asegurar el grupo del limiter (asi crear_usuario puede añadir siempre)
    getent group vpsusers >/dev/null 2>&1 || groupadd vpsusers 2>/dev/null || true
    [[ -f /etc/cron.d/ghost-panel-vencidos ]] || cron_vencidos_instalar
}

# ---------- MARCO / DISEÑO DEL PANEL ----------
FR_TOP(){ printf '%b\n' "${AZUL}╔══════════════════════════════════════════════════════════╗${NC}"; }
FR_MID(){ printf '%b\n' "${AZUL}╠══════════════════════════════════════════════════════════╣${NC}"; }
FR_BOT(){ printf '%b\n' "${AZUL}╚══════════════════════════════════════════════════════════╝${NC}"; }
FR_TXT(){
    local raw="$1" out="" vis=0 esc
    raw="${raw//\\033/$'\x1b'}"
    while [[ -n "$raw" ]]; do
        if [[ "$raw" == $'\x1b['* ]]; then
            esc="${raw%%m*}m"; out+="$esc"; raw="${raw#"$esc"}"; continue
        fi
        [[ $vis -ge 56 ]] && break
        out+="${raw:0:1}"; vis=$((vis+1)); raw="${raw:1}"
    done
    printf '%b %s%*s %b\n' "${AZUL}║${NC}" "$out" "$((56-vis))" "" "${AZUL}║${NC}"
}
FR_OPT(){
    if [[ -n "$3" ]]; then
        FR_TXT "$(printf "  ${AZUL}[%-2s]${NC} %-24s  ${AZUL}[%-2s]${NC} %-18s" "$1" "$2" "$3" "$4")"
    else
        FR_TXT "$(printf "  ${AZUL}[%-2s]${NC} %s" "$1" "$2")"
    fi
}
OK(){ echo -e "${VERDE}[OK]${NC} $1"; }
ERR(){ echo -e "${ROJO}[ERROR]${NC} $1"; }
INFO(){ echo -e "${CIAN}[INFO]${NC} $1"; }
WARN(){ echo -e "${AMARILLO}[AVISO]${NC} $1"; }
FILA(){
    if [[ -n "$3" ]]; then
        printf " ${AZUL}[%-2s]${NC} %-26s ${AZUL}[%-2s]${NC} %s\n" "$1" "$2" "$3" "$4"
    else
        printf " ${AZUL}[%-2s]${NC} %s\n" "$1" "$2"
    fi
}

SUBTOP(){ FR_TOP; FR_TXT "  ${CIAN}${1}${NC}"; FR_MID; }
PROMPT(){ read -r -p "  $(echo -e "${CIAN}▸${NC}") $(T t_opcion) > " OP; }

cabecera(){
    clear
    local RAM_TOTAL RAM_USO CPU DISCO ONLINE DIAS_LIC=""
    RAM_TOTAL=$(free -m | awk '/Mem:/{print $2}')
    RAM_USO=$(free -m | awk '/Mem:/{printf "%d%% (%dM)", $3*100/$2, $3}')
    CPU=$(top -bn1 | awk '/%Cpu/{printf "%.1f%%", 100-$8}' 2>/dev/null || echo "n/a")
    DISCO=$(df -h / | awk 'NR==2{print $5}')
    ONLINE=$(who 2>/dev/null | wc -l)
    if [[ -n "${LICENSE_EXP:-}" && "${LICENSE_EXP:-0}" != "0" ]]; then
        DIAS_LIC=$(( (LICENSE_EXP - $(date +%s)) / 86400 ))
        [[ $DIAS_LIC -lt 0 ]] && DIAS_LIC=0
        DIAS_LIC=" (${DIAS_LIC}d)"
    fi
    FR_TOP
    FR_TXT "  ${VERDE}GHOST PANEL${NC}  ${BLANCO}|  $(T t_panel)${NC}"
    FR_MID
    FR_TXT "  IP: $(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')   Host: $(hostname)   Ubuntu $(lsb_release -rs 2>/dev/null)"
    FR_TXT "  $(T t_ram) ${RAM_USO}/${RAM_TOTAL}M   $(T t_cpu) ${CPU}   $(T t_disco) ${DISCO}   $(T t_online) ${VERDE}${ONLINE}${NC}"
    FR_TXT "  $(T t_licencia): ${VERDE}${LICENSE_OK:- -}${DIAS_LIC}${NC}   Webmin: $(estado_webmin_min)"
    FR_BOT
    echo
}

estado_webmin_min(){
    if dpkg -l webmin >/dev/null 2>&1; then
        if pgrep -f miniserv >/dev/null 2>&1; then echo -e "${VERDE}ACTIVO :10000${NC}"
        else echo -e "${AMARILLO}INSTALADO (detenido)${NC}"; fi
    else
        echo -e "${ROJO}NO INSTALADO${NC}"
    fi
}

# ------------------------------------------------------------
# GESTION DE USUARIOS SSH
# ------------------------------------------------------------
crear_usuario(){
    echo -e "${CIAN}--- CREAR USUARIO SSH ---${NC}"
    read -r -p "Nombre de usuario: " USU
    [[ -z "$USU" ]] && { ERR "Nombre vacio."; PAUSA; return; }
    id "$USU" >/dev/null 2>&1 && { ERR "El usuario ya existe."; PAUSA; return; }
    read -r -p "Dias de validez (ej. 30): " DIAS
    read -r -p "Conexion maxima (ej. 1) [1]: " MAXC; MAXC=${MAXC:-1}
    read -r -p "Contrasena: " CLAVE
    useradd -m -s /bin/bash "$USU" 2>/dev/null || { ERR "No se pudo crear."; PAUSA; return; }
    echo "$USU:$CLAVE" | chpasswd
    [[ "$DIAS" =~ ^[0-9]+$ ]] && chage -M "$DIAS" -E "$(date -d "+${DIAS} days" +%Y-%m-%d)" "$USU"
    mkdir -p /etc/vps-limits
    echo "$MAXC" > "/etc/vps-limits/$USU"
    # El grupo ya lo garantiza ghost_bootstrap()
    usermod -aG vpsusers "$USU" 2>/dev/null
    xray_usuario add "$USU" 2>/dev/null
    OK "Usuario '$USU' creado. Expira: $(chage -l "$USU" 2>/dev/null | awk -F': ' '/Password expires/{print $2}')"
    echo -e "IP: $(hostname -I | awk '{print $1}')  |  Puerto SSH: $(grep -i '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || echo 22)"
    PAUSA
}

cambiar_clave(){
    read -r -p "Usuario: " USU
    id "$USU" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    passwd "$USU" && OK "Clave actualizada."
    PAUSA
}

eliminar_usuario(){
    read -r -p "Usuario a eliminar: " USU
    id "$USU" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    read -r -p "Borrar tambien su /home? (s/n): " SN
    pkill -u "$USU" 2>/dev/null
    xray_usuario del "$USU" 2>/dev/null
    if [[ "$SN" == "s" ]]; then userdel -r "$USU" 2>/dev/null; else userdel "$USU"; fi
    rm -f "/etc/vps-limits/$USU" "/etc/vps-trafico/$USU"
    OK "Usuario '$USU' eliminado."
    PAUSA
}

bloquear_usuario(){
    read -r -p "Usuario a bloquear/desbloquear: " USU
    id "$USU" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    if passwd -S "$USU" | grep -q ' L '; then usermod -U "$USU"; OK "'$USU' DESBLOQUEADO."
    else usermod -L "$USU"; pkill -u "$USU" 2>/dev/null; OK "'$USU' BLOQUEADO."; fi
    PAUSA
}

renovar_usuario(){
    read -r -p "Usuario: " USU
    id "$USU" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    read -r -p "Dias a agregar: " DIAS
    chage -M "$DIAS" -E "$(date -d "+${DIAS} days" +%Y-%m-%d)" "$USU"
    OK "'$USU' renovado por ${DIAS} dias (expira: $(chage -l "$USU" | awk -F': ' '/Password expires/{print $2}'))."
    PAUSA
}

listar_usuarios(){
    echo -e "${CIAN}--- USUARIOS DEL SISTEMA (humanos) ---${NC}"
    printf "%-16s %-22s %-14s %s\n" "USUARIO" "EXPIRA" "ESTADO" "HOME"
    awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd | while read -r U; do
        EXP=$(chage -l "$U" 2>/dev/null | awk -F': ' '/Password expires/{print $2}')
        EST=$(passwd -S "$U" 2>/dev/null | awk '{print $2}')
        [[ "$EST" == "P" ]] && EST="${VERDE}OK${NC}" || EST="${ROJO}LOCK${NC}"
        printf "%-16s %-22b %-14b %s\n" "$U" "$EXP" "$EST" "$(eval echo ~$U)"
    done
    PAUSA
}

conexiones_online(){
    echo -e "${CIAN}--- CONEXIONES ONLINE (SSH/pts) ---${NC}"
    who 2>/dev/null || echo "Sin sesiones."
    echo
    echo -e "${CIAN}Total procesos sshd:${NC} $(pgrep -c sshd 2>/dev/null || echo 0)"
    PAUSA
}

matar_conexion(){
    conexiones_online_rapido
    read -r -p "Usuario a desconectar: " USU
    pkill -u "$USU" 2>/dev/null && OK "Sesiones de '$USU' cerradas." || ERR "Sin sesiones activas."
    PAUSA
}
conexiones_online_rapido(){ who 2>/dev/null; echo; }

# ------------------------------------------------------------
# SISTEMA / RED
# ------------------------------------------------------------
monitoreo(){
    echo -e "${CIAN}--- MONITOREO ---${NC}"
    echo -e "Uptime : $(uptime)"
    free -h | sed 's/^/         /'
    echo
    df -h / /home 2>/dev/null | sed 's/^/         /'
    echo
    ss -tunap 2>/dev/null | awk 'NR>1{print $1, $5, $7}' | head -20
    PAUSA
}

optimizar(){
    INFO "Aplicando ajustes basicos de rendimiento..."
    cat > /etc/sysctl.d/99-vps-manager.conf <<EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    modprobe tcp_bbr 2>/dev/null; echo "tcp_bbr" >> /etc/modules-load.d/bbr.conf 2>/dev/null
    sysctl --system >/dev/null 2>&1
    OK "Optimizacion aplicada (BBR + swappiness=10)."
    PAUSA
}

update_sistema(){
    INFO "Actualizando paquetes..."
    apt update && apt upgrade -y
    OK "Sistema actualizado."
    PAUSA
}

backup_basico(){
    DIR="/root/backups"; mkdir -p "$DIR"
    FILE="$DIR/backup-$(date +%F_%H%M).tar.gz"
    INFO "Creando backup de /etc, /home y lista de paquetes..."
    dpkg --get-selections > /root/paquetes.txt 2>/dev/null
    tar czf "$FILE" /etc /root/paquetes.txt --exclude=/etc/ssl/private 2>/dev/null
    OK "Backup creado: $FILE ($(du -h "$FILE" | cut -f1))"
    PAUSA
}

# Banner HTML para logs de HTTP Custom.
# Tokens en texto plano: USER EXP DAYS WARN  (HC los sustituye).
# Reglas estrictas:
#  - Una sola linea, sin saltos.
#  - Cada renglon visual dentro de su propio <p style="text-align:center;">.
#  - Solo etiquetas inline: <font color="#HEX">, <b>, <i>.
#  - Nunca escribir texto fijo que contenga la subcadena "EXP".
#    Usar "VENCIMIENTO :" como etiqueta de fecha.
#  - La linea de WARN lleva SOLO la variable, sin prefijos tipo "AVISO :".
banner_html_http_custom(){
    cat <<'HTMLEOF'
<p style="text-align:center;"><font color="#00FFFF"><b>════════════════════════════════</b></font></p><p style="text-align:center;"><font color="#FF00FF"><b>✦ GHOST PANEL ✦</b></font></p><p style="text-align:center;"><font color="#00FF7F"><i>── CONEXION VIP ESTABLE ──</i></font></p><p style="text-align:center;"><font color="#00FFFF"><b>════════════════════════════════</b></font></p><p style="text-align:center;"><font color="#00BFFF"><b>👤 USUARIO : USER</b></font></p><p style="text-align:center;"><font color="#FFD700"><b>📅 VENCIMIENTO : EXP</b></font></p><p style="text-align:center;"><font color="#FF8C00"><b>⏳ RESTANTES : DAYS</b></font></p><p style="text-align:center;"><font color="#FF4444"><b>WARN</b></font></p><p style="text-align:center;"><font color="#7CFC00"><i>🚀 Disfruta de la mejor velocidad 🚀</i></font></p><p style="text-align:center;"><font color="#00FFFF"><b>════════════════════════════════</b></font></p>
HTMLEOF
}

banner_activar_en_sshd(){
    local f=/etc/ssh/sshd_config
    [[ -f "$f" ]] || { ERR "No existe $f"; return 1; }
    sed -i -E '/^[[:space:]]*#?[[:space:]]*Banner[[:space:]]/d' "$f"
    printf '\nBanner /etc/banner-vps\n' >> "$f"
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || service ssh reload 2>/dev/null || true
}

banner_activar_en_dropbear(){
    if ! command -v dropbear >/dev/null 2>&1 && [[ ! -d /etc/dropbear ]]; then
        return 0
    fi
    mkdir -p /etc/dropbear
    cp -f /etc/banner-vps /etc/dropbear/banner
    chmod 644 /etc/dropbear/banner
    systemctl reload dropbear 2>/dev/null || service dropbear restart 2>/dev/null || true
    return 0
}

# Recibe HTML por stdin (una linea) y lo activa en OpenSSH + Dropbear.
banner_publicar(){
    local tmp
    tmp=$(mktemp /tmp/banner-vps.XXXXXX) || { ERR "No se pudo crear temporal."; return 1; }
    cat > "$tmp"
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        ERR "Banner vacio. No se publico."
        return 1
    fi
    if [[ "${BANNER_HC:-0}" == "1" ]]; then
        # Sin $, sin [], sin ${}  (reglas de sustitucion de HTTP Custom)
        if grep -qE '\$|\[[A-Za-z]+\]' "$tmp"; then
            rm -f "$tmp"
            ERR "Sintaxis invalida: no uses \$, [] ni \${}. Tokens permitidos: USER EXP DAYS WARN"
            return 1
        fi
        # EXP solo puede aparecer como token suelto (no dentro de otra palabra).
        # Falla si EXP esta pegado a letras (EXPIRA, EXPIRE, MIEXP, etc.).
        if grep -qE '[A-Za-z]EXP|EXP[A-Za-z]' "$tmp"; then
            rm -f "$tmp"
            ERR "Texto fijo contiene 'EXP' (solo se permite como token suelto). Usa 'VENCIMIENTO :'"
            return 1
        fi
    fi
    install -m 644 "$tmp" /etc/banner-vps
    rm -f "$tmp"
    banner_activar_en_sshd || return 1
    banner_activar_en_dropbear
    local MSG="Banner publicado en OpenSSH (/etc/banner-vps)"
    [[ -f /etc/dropbear/banner ]] && MSG="Banner publicado en OpenSSH y Dropbear"
    OK "$MSG"
}

banner_dinamico_html(){
    echo -e "${CIAN}--- BANNER DINAMICO HTML (HTTP CUSTOM) ---${NC}"
    echo "  Debe ejecutarse en el VPS (root). No sirve en Termux sin proot."
    echo
    echo "  [P] Plantilla GHOST PANEL (recomendado)"
    echo "  [C] Pegar HTML propio (una sola linea, tokens USER EXP DAYS WARN)"
    echo "  [0] Cancelar"
    read -r -p "  > " MODO
    case "$MODO" in
        P|p|"")
            banner_html_http_custom | BANNER_HC=1 banner_publicar
            echo
            INFO "Plantilla aplicada. HTTP Custom sustituye USER / EXP / DAYS / WARN."
            INFO "WARN queda vacio si CheckUser no envia aviso (no se muestra prefijo)."
            echo
            echo -e "${AMARILLO}HTML publicado:${NC}"
            tr -d '\n' < /etc/banner-vps; echo
            ;;
        C|c)
            echo "Pega el HTML en UNA linea y ENTER:"
            local HTML
            IFS= read -r HTML
            printf '%s' "$HTML" | BANNER_HC=1 banner_publicar
            ;;
        *) INFO "Cancelado." ;;
    esac
    PAUSA
}

banner_ssh(){
    echo -e "${CIAN}--- MENSAJES BANNER SSH (texto) ---${NC}"
    echo "Escribe las lineas del banner (linea vacia para terminar):"
    local tmp
    tmp=$(mktemp /tmp/banner-vps.XXXXXX) || return
    while IFS= read -r LINEA; do [[ -z "$LINEA" ]] && break; printf '%s\n' "$LINEA" >> "$tmp"; done
    if [[ ! -s "$tmp" ]]; then rm -f "$tmp"; ERR "Sin contenido."; PAUSA; return; fi
    cat "$tmp" | banner_publicar
    rm -f "$tmp"
    PAUSA
}

banner_eliminar(){
    echo -e "${CIAN}--- ELIMINAR BANNER (OpenSSH + Dropbear) ---${NC}"
    [[ -f /etc/ssh/sshd_config ]] && sed -i -E '/^[[:space:]]*#?[[:space:]]*Banner[[:space:]]/d' /etc/ssh/sshd_config
    rm -f /etc/banner-vps /etc/dropbear/banner
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    systemctl reload dropbear 2>/dev/null || service dropbear restart 2>/dev/null || true
    OK "Banner eliminado."
    PAUSA
}

banner_con_checkuser(){
    echo -e "${CIAN}--- CHECKUSER + BANNER HTML ---${NC}"
    INFO "Publica el HTML dinamico y deja CheckUser listo para USER/EXP/DAYS/WARN."
    banner_html_http_custom | BANNER_HC=1 banner_publicar
    if [[ ! -f /etc/vps-checkuser.conf ]]; then
        INFO "CheckUser no instalado. Lanzando instalador..."
        checkuser_instalar
        return
    fi
    checkuser_escribir_py
    systemctl restart vps-checkuser 2>/dev/null || true
    OK "CheckUser reiniciado con campos expiration / days_left / warning."
    local P T IP
    P=$(awk -F= '/^PORT=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    T=$(awk -F= '/^TOKEN=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    IP=$(hostname -I | awk '{print $1}')
    echo -e " URL CheckUser: ${BLANCO}http://$IP:${P:-8080}/checkuser.php?user=USUARIO&token=$T${NC}"
    PAUSA
}

menu_banner(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_banner)"
        FR_OPT 1 "$(T t_banner_html)" 3 "$(T t_banner_del)"
        FR_OPT 2 "$(T t_banner_msg)" 4 "$(T t_banner_cu)"
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) banner_dinamico_html ;;
            2) banner_ssh ;;
            3) banner_eliminar ;;
            4) banner_con_checkuser ;;
            0) break ;;
            *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# WEBMIN  (instalador oficial vía repositorio)
# ------------------------------------------------------------
instalar_webmin(){
    echo -e "${CIAN}--- INSTALADOR WEBMIN ---${NC}"
    if dpkg -l webmin >/dev/null 2>&1; then
        INFO "Webmin ya esta instalado."
    else
        INFO "Instalando dependencias..."
        apt update -y && apt install -y curl wget gnupg2 software-properties-common
        INFO "Agregando repositorio oficial de Webmin..."
        local TMP; TMP=$(mktemp -d)
        if curl -fsSL -o "$TMP/setup-repos.sh" https://raw.githubusercontent.com/webmin/webmin/master/setup-repos.sh; then
            sh "$TMP/setup-repos.sh" -f
            INFO "Instalando Webmin..."
            apt update -y && apt install -y webmin
        else
            ERR "No se pudo descargar setup-repos.sh. Instalando .deb manual..."
            wget -q https://download.webmin.com/download/repository/pool/contrib/w/webmin/webmin_2.301_all.deb -O "$TMP/webmin.deb" \
              || wget -q https://prdownloads.sourceforge.net/webadmin/webmin_2.301_all.deb -O "$TMP/webmin.deb"
            apt install -y "$TMP/webmin.deb" || apt -f install -y
        fi
        rm -rf "$TMP"
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q active; then
        ufw allow 10000/tcp >/dev/null 2>&1 && INFO "Puerto 10000/tcp abierto en UFW."
    fi
    systemctl enable --now webmin 2>/dev/null || /etc/webmin/start >/dev/null 2>&1
    sleep 1
    local WP; WP=$(grep -o '^port=[0-9]*' /etc/webmin/miniserv.conf 2>/dev/null | cut -d= -f2 | head -1); WP=${WP:-10000}
    if pgrep -f miniserv >/dev/null 2>&1; then
        OK "Webmin ACTIVO en puerto $WP."
    else
        ERR "Webmin quedo detenido. Proba con la opcion 2 (Estado / reiniciar) del menu."
    fi
    echo
    local IP; IP=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    OK "Webmin instalado."
    echo -e " Acceso  : ${VERDE}https://${IP}:10000${NC}"
    echo -e " Usuario : ${VERDE}root${NC} (o cualquier usuario con sudo)"
    echo -e " ${AMARILLO}Nota: si es una VM remota, acepta el aviso de certificado autofirmado.${NC}"
    PAUSA
}

remover_webmin(){
    INFO "Deteniendo y eliminando Webmin..."
    systemctl stop webmin 2>/dev/null
    apt purge -y webmin 2>/dev/null
    rm -f /etc/apt/sources.list.d/webmin.list /usr/share/keyrings/webmin.gpg
    apt update -y >/dev/null 2>&1
    OK "Webmin removido."
    PAUSA
}

menu_webmin(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_webmin)"
        FR_OPT 1 "$(T t_webmin_inst)" 4 "$(T t_cambiar_puerto)"
        FR_OPT 2 "Estado / reiniciar" 5 "$(T t_remover_webmin)"
        FR_OPT 3 "$(T t_abrir_10000)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) instalar_webmin ;;
            2) systemctl restart webmin 2>/dev/null || /etc/webmin/start >/dev/null 2>&1
               sleep 1
               if pgrep -f miniserv >/dev/null 2>&1; then
                   local WP; WP=$(grep -o '^port=[0-9]*' /etc/webmin/miniserv.conf 2>/dev/null | cut -d= -f2 | head -1); WP=${WP:-10000}
                   OK "Webmin corriendo en puerto $WP."
               else
                   ERR "Webmin no levanto (¿sin systemd ni /etc/webmin/start?)."
               fi
               PAUSA ;;
            3) ufw allow 10000/tcp 2>/dev/null && OK "Puerto abierto." || ERR "UFW no activo."; PAUSA ;;
            4) read -r -p "Nuevo puerto: " P
               sed -i "s/^port=.*/port=$P/" /etc/webmin/miniserv.conf 2>/dev/null
               systemctl restart webmin 2>/dev/null && OK "Puerto cambiado a $P." || ERR "Webmin no instalado."
               PAUSA ;;
            5) remover_webmin ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# HERRAMIENTAS EXTRA
# ------------------------------------------------------------
instalar_comando_global(){
    local DEST=/usr/local/bin/vpsmgr
    if cp "$(readlink -f "$0")" "$DEST" 2>/dev/null && chmod +x "$DEST"; then
        grep -q "alias vps=" /root/.bashrc 2>/dev/null || echo "alias vps='/usr/local/bin/vpsmgr'" >> /root/.bashrc
        OK "Instalado. Ahora entras desde cualquier lado con: ${VERDE}vpsmgr${NC} (o ${VERDE}vps${NC})"
    else
        ERR "No se pudo instalar en $DEST (permisos?)."
    fi
    PAUSA
}

limiter_aplicar(){
    mkdir -p /etc/vps-limits
    cat > /usr/local/bin/vps-limiter.sh <<'LIMEOF'
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
LIMEOF
    chmod +x /usr/local/bin/vps-limiter.sh 2>/dev/null || { ERR "Sin permiso para escribir /usr/local/bin"; PAUSA; return; }
    sed -i '/# VPS-LIMITER-INICIO/,/# VPS-LIMITER-FIN/d' /etc/ssh/sshd_config
    {
      echo "# VPS-LIMITER-INICIO"
      echo "Match Group vpsusers"
      echo "    ForceCommand /usr/local/bin/vps-limiter.sh"
      echo "# VPS-LIMITER-FIN"
    } >> /etc/ssh/sshd_config
    getent group vpsusers >/dev/null 2>&1 || groupadd vpsusers
    for f in /etc/vps-limits/*; do
        [ -f "$f" ] && usermod -aG vpsusers "$(basename "$f")" 2>/dev/null
    done
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
    OK "Limiter activo. Usuarios con limite: $(ls /etc/vps-limits/ 2>/dev/null | tr '\n' ' ')"
    INFO "Ojo: a los usuarios limitados se les deshabilita SFTP (ForceCommand)."
    PAUSA
}

limiter_quitar(){
    sed -i '/# VPS-LIMITER-INICIO/,/# VPS-LIMITER-FIN/d' /etc/ssh/sshd_config
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
    OK "Limiter desactivado."
    PAUSA
}

instalar_fail2ban(){
    INFO "Instalando fail2ban (anti fuerza bruta SSH)..."
    apt update -y >/dev/null 2>&1
    apt install -y fail2ban >/dev/null 2>&1
    cat > /etc/fail2ban/jail.local <<
