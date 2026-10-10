#!/usr/bin/env bash
# ============================================================
#  GHOST PANEL by Jorge Barrios  -  Administracion de VPS (Ubuntu)
#  Menu SSH: usuarios, trafico, backup, banner + Webmin
#  Uso:  sudo bash ghost-panel.sh
# ============================================================

set -u

ROJO='\033[1;31m'; VERDE='\033[1;32m'; AMARILLO='\033[1;33m'
AZUL='\033[1;34m'; CIAN='\033[1;36m'; BLANCO='\033[1;37m'
NC='\033[0m'

# --- LICENCIA / KEY -------------------------------------------
# Validacion ONLINE obligatoria (Worker de Cloudflare con KV).
# Sistema de UN SOLO USO: la primera vez que un VPS valida la key,
# el Worker la ata a su machine-id y NO se puede reutilizar en otro VPS.
SECRET_KEY='Copiaesta**'
KEY_FILE='/etc/vps-manager.key'
PERM_FILE='/etc/vps-license.permanent'
PREFIJO_KEY='VPSJB1'
REPO_RAW='https://raw.githubusercontent.com/pitubarrios/vps-manager/refs/heads/main/ghost-panel.sh'

# Pon aqui la URL de tu Worker de Cloudflare (ej: https://tu-worker.workers.dev/)
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

consultar_licencia(){
    # Devuelve: 0 valida / 1 invalida / 2 servidor sin respuesta
    # Setea: LICENSE_NOMBRE, LICENSE_PERMANENTE, LICENSE_DIAS, LICENSE_REASON
    local KEY="$1" RESP
    [[ -z "$LICENSE_URL" ]] && return 2

    RESP=$(curl -G -fsS --max-time 10 -A "Mozilla/5.0" "$LICENSE_URL" \
        --data-urlencode "key=$KEY" --data-urlencode "id=$(machine_hash)" 2>/dev/null)
    [[ -z "$RESP" ]] && return 2

    if echo "$RESP" | grep -q '"valid":[[:space:]]*true'; then
        LICENSE_NOMBRE=$(echo "$RESP" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
        if echo "$RESP" | grep -q '"permanent":[[:space:]]*true'; then
            LICENSE_PERMANENTE=1
        else
            LICENSE_PERMANENTE=0
        fi
        LICENSE_DIAS=$(echo "$RESP" | grep -o '"days_left"[[:space:]]*:[[:space:]]*[0-9]*' \
            | head -1 | grep -o '[0-9]*$')
        return 0
    fi

    LICENSE_REASON=$(echo "$RESP" \
        | grep -o '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    return 1
}

gate_licencia(){
    local INTENTOS=0 K RC
    local PERM_HASH=''

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

    [[ -f "$PERM_FILE" ]] && PERM_HASH=$(cat "$PERM_FILE" 2>/dev/null)
    INFO "Validacion online activa."

    # --- Intento con la key guardada ---
    if [[ -f "$KEY_FILE" ]]; then
        K=$(cat "$KEY_FILE" 2>/dev/null)
        consultar_licencia "$K"; RC=$?
        if [[ $RC -eq 0 ]]; then
            echo "$(machine_hash)" > "$PERM_FILE" 2>/dev/null
            chmod 600 "$PERM_FILE" 2>/dev/null
            LICENSE_OK="${LICENSE_NOMBRE:-cliente}"
            if [[ "${LICENSE_PERMANENTE:-0}" == "1" ]]; then
                LICENSE_EXP=0
            elif [[ -n "${LICENSE_DIAS:-}" ]]; then
                LICENSE_EXP=$(( $(date +%s) + LICENSE_DIAS * 86400 ))
            else
                LICENSE_EXP=0
            fi
            return 0
        elif [[ $RC -eq 2 ]]; then
            if [[ -n "$PERM_HASH" && "$PERM_HASH" == "$(machine_hash)" ]]; then
                LICENSE_OK="modo offline (licencia local permanente)"
                LICENSE_EXP=0
                return 0
            fi
            ERR "Servidor de licencias no responde y esta key nunca fue activada en este VPS."
        else
            ERR "Key rechazada: ${LICENSE_REASON:-invalida}."
            case "${LICENSE_REASON:-}" in
                already_used_other_machine|revoked|unknown_key)
                    rm -f "$KEY_FILE" "$PERM_FILE" 2>/dev/null ;;
            esac
        fi
    fi

    # --- Pedir key al usuario ---
    while [[ $INTENTOS -lt 3 ]]; do
        read -r -p " INGRESE SU KEY > " K
        consultar_licencia "$K"; RC=$?
        if [[ $RC -eq 0 ]]; then
            echo "$K" > "$KEY_FILE" 2>/dev/null;          chmod 600 "$KEY_FILE" 2>/dev/null
            echo "$(machine_hash)" > "$PERM_FILE" 2>/dev/null; chmod 600 "$PERM_FILE" 2>/dev/null
            LICENSE_OK="${LICENSE_NOMBRE:-cliente}"
            if [[ "${LICENSE_PERMANENTE:-0}" == "1" ]]; then
                LICENSE_EXP=0
            elif [[ -n "${LICENSE_DIAS:-}" ]]; then
                LICENSE_EXP=$(( $(date +%s) + LICENSE_DIAS * 86400 ))
            else
                LICENSE_EXP=0
            fi
            OK "Licencia activada PERMANENTEMENTE en este VPS. Bienvenido, ${LICENSE_OK}."
            sleep 1
            return 0
        elif [[ $RC -eq 2 ]]; then
            ERR "Servidor de licencias no responde. Intenta mas tarde."
        else
            case "${LICENSE_REASON:-}" in
                already_used_other_machine)
                    ERR "Esta key ya fue usada en OTRO VPS y no se puede reutilizar." ;;
                revoked)
                    ERR "Esta key fue revocada por el administrador." ;;
                unknown_key)
                    ERR "Key inexistente. Verifica que este bien copiada." ;;
                *)
                    ERR "Key invalida o expirada." ;;
            esac
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
    # Grupo del limiter siempre existente (para usermod en crear_usuario)
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
    if [[ "${LICENSE_EXP:-0}" == "0" ]]; then
        DIAS_LIC=" (PERMANENTE)"
    elif [[ -n "${LICENSE_EXP:-}" ]]; then
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
#  - Nunca texto fijo con la subcadena "EXP" (usar "VENCIMIENTO :").
#  - WARN va SOLO, sin prefijos tipo "AVISO :".
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
        if grep -qE '\$|\[[A-Za-z]+\]' "$tmp"; then
            rm -f "$tmp"
            ERR "Sintaxis invalida: no uses \$, [] ni \${}. Tokens permitidos: USER EXP DAYS WARN"
            return 1
        fi
        # EXP solo como token suelto (no pegado a letras)
        if grep -qE '[A-Za-z]EXP|EXP[A-Za-z]' "$tmp"; then
            rm -f "$tmp"
            ERR "Texto fijo contiene 'EXP'. Usa 'VENCIMIENTO :' como etiqueta."
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
# WEBMIN
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
    cat > /etc/fail2ban/jail.local <<'F2BEOF'
[sshd]
enabled  = true
port     = ssh
maxretry = 5
bantime  = 1h
F2BEOF
    systemctl enable --now fail2ban 2>/dev/null
    OK "Fail2ban activo: 5 intentos fallidos = baneo de 1 hora."
    PAUSA
}

cambiar_puerto_ssh(){
    read -r -p "Puerto SSH nuevo (ej. 2222): " P
    [[ "$P" =~ ^[0-9]+$ && "$P" -ge 1 && "$P" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    sed -i 's/^#\?Port .*/Port '$P'/' /etc/ssh/sshd_config
    grep -q "^Port $P" /etc/ssh/sshd_config || echo "Port $P" >> /etc/ssh/sshd_config
    ufw allow "$P/tcp" >/dev/null 2>&1
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
    OK "Puerto SSH: $P. ${AMARILLO}Abri otra terminal y proba conectarte ANTES de cerrar esta.${NC}"
    PAUSA
}

ver_puertos(){
    echo -e "${CIAN}--- PUERTOS ESCUCHANDO (TCP) ---${NC}"
    ss -tlnp 2>/dev/null | head -25
    echo
    echo -e "${CIAN}--- UFW (firewall) ---${NC}"
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose 2>/dev/null | head -20
    else
        echo "UFW no instalado."
    fi
    PAUSA
}

abrir_puerto(){
    read -r -p "Puerto a abrir (ej. 8080): " P
    [[ "$P" =~ ^[0-9]+$ && "$P" -ge 1 && "$P" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "Protocolo (tcp/udp) [tcp]: " PROTO; PROTO=${PROTO:-tcp}
    [[ "$PROTO" != "tcp" && "$PROTO" != "udp" ]] && { ERR "Protocolo invalido."; PAUSA; return; }
    if ! command -v ufw >/dev/null 2>&1; then
        INFO "UFW no instalado, instalando..."
        apt update -y >/dev/null 2>&1 && apt install -y ufw >/dev/null 2>&1
    fi
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        read -r -p "UFW no esta activo. Activarlo ahora? (s/n): " SN
        [[ "$SN" == "s" ]] && { ufw --force enable; INFO "UFW activado."; }
    fi
    ufw allow "$P/$PROTO" >/dev/null 2>&1 && OK "Puerto $P/$PROTO abierto."
    ufw status 2>/dev/null | grep -E "^$P/" || ERR "No se confirmo la regla."
    PAUSA
}

cambiar_limite(){
    echo -e "${CIAN}--- CAMBIAR LIMITE DE SESIONES ---${NC}"
    ls /etc/vps-limits/ 2>/dev/null | while read -r U; do
        printf "  %-16s max: %s\n" "$U" "$(cat /etc/vps-limits/$U 2>/dev/null)"
    done
    read -r -p "Usuario: " USU
    [[ -f "/etc/vps-limits/$USU" ]] || { ERR "Ese usuario no tiene limite (creado fuera del script?)."; PAUSA; return; }
    read -r -p "Nuevo maximo de sesiones: " M
    [[ "$M" =~ ^[0-9]+$ ]] || { ERR "Numero invalido."; PAUSA; return; }
    echo "$M" > "/etc/vps-limits/$USU"
    OK "Limite de '$USU' actualizado a $M sesiones."
    PAUSA
}

crear_test_ssh(){
    echo -e "${CIAN}--- CREAR USUARIO DE PRUEBA (vence en 1 dia) ---${NC}"
    read -r -p "Nombre base (le agrego prefijo test-): " NOMBRE
    local USU CLAVE
    USU="test-$(echo "$NOMBRE" | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z' | cut -c1-18)"
    id "$USU" >/dev/null 2>&1 && { ERR "Ya existe."; PAUSA; return; }
    read -r -p "Conexion maxima [1]: " MAXC; MAXC=${MAXC:-1}
    CLAVE=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 10)
    [[ -z "$CLAVE" ]] && CLAVE="test123456"
    useradd -m -s /bin/bash "$USU" 2>/dev/null || { ERR "No se pudo crear."; PAUSA; return; }
    echo "$USU:$CLAVE" | chpasswd
    chage -M 1 -E "$(date -d '+1 day' +%Y-%m-%d)" "$USU" 2>/dev/null
    mkdir -p /etc/vps-limits; echo "$MAXC" > "/etc/vps-limits/$USU"
    usermod -aG vpsusers "$USU" 2>/dev/null
    xray_usuario add "$USU" 2>/dev/null
    OK "Usuario de prueba creado:"
    echo -e "  Usuario: ${VERDE}$USU${NC}   Clave: ${VERDE}$CLAVE${NC}"
    echo -e "  ${AMARILLO}Vence manana. IP: $(hostname -I | awk '{print $1}')  Puerto: $(grep -i '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || echo 22)${NC}"
    PAUSA
}

eliminar_vencidos(){
    local HOY N BORRADOS=0 U EXP
    HOY=$(date +%Y-%m-%d)
    for U in $(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd); do
        EXP=$(chage -l "$U" 2>/dev/null | awk -F': ' '/Password expires/{print $2}')
        [[ -z "$EXP" || "$EXP" == "never" ]] && continue
        N=$(date -d "$EXP" +%Y-%m-%d 2>/dev/null) || continue
        if [[ "$N" < "$HOY" ]]; then
            pkill -u "$U" 2>/dev/null
            rm -f "/etc/vps-limits/$U"
            xray_usuario del "$U" 2>/dev/null
            userdel -r "$U" 2>/dev/null
            INFO "Eliminado vencido: $U (vencio: $N)"
            BORRADOS=$((BORRADOS+1))
        fi
    done
    [[ $BORRADOS -eq 0 ]] && OK "No hay usuarios vencidos." || OK "Eliminados $BORRADOS usuarios vencidos."
    PAUSA
}

mantenimiento(){
    INFO "Limpiando sistema..."
    apt autoremove -y >/dev/null 2>&1
    apt clean >/dev/null 2>&1
    journalctl --vacuum-time=7d >/dev/null 2>&1
    find /tmp -type f -mtime +7 -delete 2>/dev/null
    ls -t /root/backups/*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
    find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null
    systemctl enable --now fstrim.timer >/dev/null 2>&1
    INFO "TRIM semanal: $(systemctl is-enabled fstrim.timer 2>/dev/null || echo "no aplica en este entorno")"
    OK "Listo: paquetes huerfanos, logs viejos, /tmp y backups (conservo los ultimos 3)."
    PAUSA
}

auto_menu(){
    if grep -q "VPS-JB-AUTOMENU-INICIO" "$HOME/.bashrc" 2>/dev/null; then
        OK "El auto-menu ya estaba activo."; PAUSA; return
    fi
    cat >> "$HOME/.bashrc" <<'AMEOF'
# VPS-JB-AUTOMENU-INICIO
case "$-" in *i*) [ -x /usr/local/bin/vpsmgr ] && /usr/local/bin/vpsmgr ;; esac
# VPS-JB-AUTOMENU-FIN
AMEOF
    OK "Auto-menu activo: la proxima vez que root inicie sesion (SSH o consola), el menu abre solo."
    PAUSA
}

quitar_auto_menu(){
    sed -i '/VPS-JB-AUTOMENU-INICIO/,/VPS-JB-AUTOMENU-FIN/d' "$HOME/.bashrc" 2>/dev/null
    OK "Auto-menu desactivado."
    PAUSA
}

diagnostico(){
    echo -e "${CIAN}--- DIAGNOSTICO DEL SERVIDOR ---${NC}"
    local RAM_P DISCO_P LOAD ADV=0
    RAM_P=$(free | awk '/Mem/{printf "%d", $3*100/$2}')
    DISCO_P=$(df -h / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    LOAD=$(cut -d' ' -f1 /proc/loadavg)
    echo -e " RAM: ${RAM_P}%   Disco: ${DISCO_P}%   Carga: $LOAD"
    [[ "$RAM_P" -gt 85 ]]    && { echo -e " ${ROJO}!${NC} RAM al ${RAM_P}%: cerrar procesos o agregar swap."; ADV=1; }
    [[ "$DISCO_P" -gt 85 ]]  && { echo -e " ${ROJO}!${NC} Disco al ${DISCO_P}%: correr Mantenimiento (26) y revisar /root/backups."; ADV=1; }
    systemctl is-failed --quiet sshd 2>/dev/null && { echo -e " ${ROJO}!${NC} sshd con fallos: 'systemctl status sshd'."; ADV=1; }
    pgrep -f miniserv >/dev/null 2>&1 || echo -e " ${AMARILLO}-${NC} Webmin no corre (menu 11)."
    lastb -i 2>/dev/null | head -5 | grep -q . && echo -e " ${AMARILLO}-${NC} Intentos de login fallidos recientes: conviene Fail2ban (17)."
    [[ $ADV -eq 0 ]] && echo -e " ${VERDE}OK${NC} Sin alertas graves."
    PAUSA
}

cambiar_hostname(){
    echo -e "${CIAN}Hostname actual: ${BLANCO}$(hostname)${NC}"
    read -r -p "Nuevo hostname (sin espacios, ej. vps): " H
    [[ -z "$H" || "$H" =~ [^a-zA-Z0-9.-] ]] && { ERR "Hostname invalido."; PAUSA; return; }
    hostnamectl set-hostname "$H" 2>/dev/null || { ERR "No se pudo cambiar."; PAUSA; return; }
    sed -i "s/127.0.1.1.*/127.0.1.1\t$H/" /etc/hosts 2>/dev/null
    OK "Hostname cambiado a '$H'. Se ve completo en la proxima sesion."
    PAUSA
}

auto_update(){
    [[ -z "$REPO_RAW" ]] && { ERR "REPO_RAW sin configurar."; PAUSA; return; }
    INFO "Descargando ultima version desde tu repo..."
    local TMP; TMP=$(mktemp /tmp/vpsmgr.XXXXXX)

    if wget -q "$REPO_RAW" -O "$TMP" 2>/dev/null; then
        # Normalizar CRLF (evita romper heredocs)
        sed -i 's/\r$//' "$TMP"
        # Validar sintaxis ANTES de sobrescribir (nunca dejar el panel roto)
        if bash -n "$TMP" 2>/dev/null; then
            install -m 755 "$TMP" /usr/local/bin/vpsmgr 2>/dev/null
            cp -f "$TMP" "$(readlink -f "$0")" 2>/dev/null
            OK "Script actualizado y validado. Volves a entrar con vpsmgr."
        else
            ERR "La version descargada tiene errores de sintaxis. NO se reemplazo."
            ERR "Diagnostico: bash -n $TMP"
        fi
    else
        ERR "No se pudo descargar (sin red o repo caido)."
    fi
    rm -f "$TMP"
    PAUSA
}

# ------------------------------------------------------------
# CHECKUSER API
# ------------------------------------------------------------
checkuser_escribir_py(){
    cat > /usr/local/bin/vps-checkuser.py <<'PYEOF'
#!/usr/bin/env python3
import json, os, subprocess, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
CONF = "/etc/vps-checkuser.conf"
ENV_C = dict(os.environ)
ENV_C["LC_ALL"] = "C"
ENV_C["LANG"] = "C"
def conf():
    d = {"PORT": "8080", "TOKEN": ""}
    try:
        for line in open(CONF):
            k, _, v = line.strip().partition("=")
            if k in ("PORT", "TOKEN"): d[k] = v.strip()
    except FileNotFoundError: pass
    return d
def sh(*a):
    return subprocess.run(a, capture_output=True, text=True, env=ENV_C)
def user_info(name):
    if sh("id", name).returncode != 0:
        return {"username": name, "exists": False, "status": "notfound",
                "expiration": "", "days_left": None, "warning": ""}
    exp_raw = ""
    for line in sh("chage", "-l", name).stdout.splitlines():
        if line.startswith("Password expires"):
            exp_raw = line.split(":", 1)[1].strip()
    days, status, exp_iso = None, "active", ""
    if exp_raw and exp_raw.lower() != "never":
        try:
            ts = time.mktime(time.strptime(exp_raw, "%b %d, %Y"))
            days = int((ts - time.time()) // 86400)
            exp_iso = time.strftime("%Y-%m-%d", time.localtime(ts))
            if days < 0:
                status = "expired"
                days = 0
        except ValueError:
            exp_iso = exp_raw
    warn = ""
    if status == "expired":
        warn = "Cuenta vencida"
    elif days is not None and days <= 3:
        warn = "Por vencer"
    try: lim = open(f"/etc/vps-limits/{name}").read().strip()
    except FileNotFoundError: lim = None
    who = sh("who").stdout
    online = sum(1 for l in who.splitlines() if l.split() and l.split()[0] == name)
    return {"username": name, "user": name, "exists": True, "status": status,
            "password_expires": exp_raw, "expiration": exp_iso,
            "expired": (status == "expired"),
            "days_left": days, "remaining": days, "warning": warn, "warn": warn,
            "online": online, "limit": lim, "limit_connection": lim}
class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
    def do_GET(self):
        c = conf(); u = urlparse(self.path); qs = parse_qs(u.query)
        if c["TOKEN"] and qs.get("token", [""])[0] != c["TOKEN"]:
            return self._send(403, {"error": "forbidden"})
        if u.path in ("/checkuser.php", "/checkuser", "/check"):
            name = qs.get("user", [""])[0]
            if not name: return self._send(400, {"error": "falta parametro user"})
            return self._send(200, user_info(name))
        if u.path == "/status":
            who = [l for l in sh("who").stdout.splitlines() if l.strip()]
            tot = sh("awk", "-F:", "$3>=1000 && $1!=\"nobody\"", "/etc/passwd").stdout
            return self._send(200, {"service": "checkuser", "online_now": len(who),
                                    "total_users": len([l for l in tot.splitlines() if l.strip()])})
        return self._send(404, {"error": "not found"})
if __name__ == "__main__":
    c = conf()
    print(f"checkuser en 0.0.0.0:{c['PORT']}", flush=True)
    HTTPServer(("0.0.0.0", int(c["PORT"])), H).serve_forever()
PYEOF
    chmod 755 /usr/local/bin/vps-checkuser.py
}

checkuser_instalar(){
    echo -e "${CIAN}--- INSTALADOR CHECKUSER ---${NC}"
    local PORT TOKEN
    read -r -p "Puerto para el checkuser [8080]: " PORT; PORT=${PORT:-8080}
    [[ "$PORT" =~ ^[0-9]+$ ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "Token de seguridad (entero = aleatorio): " TOKEN
    [[ -z "$TOKEN" ]] && TOKEN=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 20)
    printf 'PORT=%s\nTOKEN=%s\n' "$PORT" "$TOKEN" > /etc/vps-checkuser.conf
    chmod 600 /etc/vps-checkuser.conf
    checkuser_escribir_py

    cat > /etc/systemd/system/vps-checkuser.service <<SVCEOF
[Unit]
Description=CheckUser API (VPS-JORGEBARRIOS)
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
    ufw allow "$PORT/tcp" >/dev/null 2>&1
    local IP; IP=$(hostname -I | awk '{print $1}')
    OK "CheckUser instalado y corriendo."
    echo -e " Prueba desde la VM:  curl http://localhost:$PORT/checkuser.php?user=TUUSUARIO&token=$TOKEN"
    echo -e " Desde afuera:        http://$IP:$PORT/checkuser.php?user=TUUSUARIO&token=$TOKEN"
    echo -e " ${AMARILLO}Guarda este token, se guarda en /etc/vps-checkuser.conf${NC}"
    PAUSA
}

checkuser_probar(){
    local P T IP
    P=$(awk -F= '/^PORT=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    T=$(awk -F= '/^TOKEN=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    IP=$(hostname -I | awk '{print $1}')
    read -r -p "Usuario a consultar: " U
    echo
    curl -s "http://localhost:${P:-8080}/checkuser.php?user=$U&token=$T" && echo || ERR "No responde. Estado:"
    systemctl status vps-checkuser --no-pager 2>/dev/null | head -6
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
    while true; do
        cabecera
        SUBTOP "$(T t_sub_cu)"
        FR_OPT 1 "$(T t_cu_inst)" 4 "$(T t_cu_token)"
        FR_OPT 2 "$(T t_estado_svc)" 5 "$(T t_remover)"
        FR_OPT 3 "$(T t_cu_probar)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) checkuser_instalar ;;
            2) systemctl status vps-checkuser --no-pager 2>/dev/null | head -15; PAUSA ;;
            3) checkuser_probar ;;
            4) cat /etc/vps-checkuser.conf 2>/dev/null || ERR "No instalado."; PAUSA ;;
            5) checkuser_quitar ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

reiniciar_vps(){
    read -r -p "Reiniciar el VPS ahora? Los servicios caeran. (s/n): " SN
    if [[ "$SN" == "s" ]]; then
        WARN "Reiniciando en 3 segundos..."
        sleep 3
        reboot
    else
        OK "Reinicio cancelado."
        PAUSA
    fi
}

# ------------------------------------------------------------
# PROTOCOLOS / CONEXIONES
# ------------------------------------------------------------
instalar_xray(){
    if command -v xray >/dev/null 2>&1; then
        read -r -p "Xray ya esta instalado. Reinstalar/configurar de nuevo? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- INSTALADOR XRAY (VLESS + REALITY) ---${NC}"
    read -r -p "Puerto para Xray [8443]: " XP; XP=${XP:-8443}
    [[ "$XP" =~ ^[0-9]+$ && "$XP" -ge 1 && "$XP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "SNI (dominio camuflaje) [www.microsoft.com]: " SNI; SNI=${SNI:-www.microsoft.com}

    INFO "Instalando Xray (descarga oficial)..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
        || { ERR "No se pudo instalar Xray (sin red?)."; PAUSA; return; }

    local KEYS UUID PRIV PUB
    KEYS=$(xray x25519 2>/dev/null)
    PRIV=$(echo "$KEYS" | awk '/Private/{print $3}')
    PUB=$(echo "$KEYS"  | awk '/Public/{print $3}')
    UUID=$(xray uuid)
    [[ -z "$PRIV" || -z "$PUB" || -z "$UUID" ]] && { ERR "No se pudieron generar las claves."; PAUSA; return; }

    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<XEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $XP,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$SNI:443",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$PRIV",
        "shortIds": [""]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
XEOF

    ufw allow "$XP/tcp" >/dev/null 2>&1
    systemctl enable --now xray 2>/dev/null || { /usr/local/bin/xray run -c /usr/local/etc/xray/config.json & }
    sleep 2
    local IP; IP=$(hostname -I | awk '{print $1}')
    local LINK="vless://$UUID@$IP:$XP?security=reality&encryption=none&pbk=$PUB&fp=chrome&sni=$SNI&flow=xtls-rprx-vision&sid=#VPS-JORGEBARRIOS"
    OK "Xray corriendo en el puerto $XP"
    echo
    echo -e " ${AMARILLO}Enlace para tu app (VLESS + Reality):${NC}"
    echo -e " ${VERDE}$LINK${NC}"
    echo
    INFO "Guarda ese enlace: es la config que importas en el cliente (v2rayNG / tu app)."
    PAUSA
}

instalar_openvpn(){
    if command -v openvpn >/dev/null 2>&1; then
        ERR "OpenVPN ya esta instalado."; PAUSA; return
    fi
    INFO "Descargando instalador de OpenVPN..."
    curl -fsSL -o /root/openvpn-install.sh https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh \
        || { ERR "Sin red, no se pudo descargar."; PAUSA; return; }
    chmod +x /root/openvpn-install.sh
    INFO "Arrancando instalador (configuralo con los valores que quieras)..."
    AUTO_INSTALL=y bash /root/openvpn-install.sh
    OK "Listo. El archivo .ovpn del cliente queda en /root/"
    PAUSA
}

instalar_ssl_stunnel(){
    if command -v stunnel4 >/dev/null 2>&1 || command -v stunnel >/dev/null 2>&1; then
        read -r -p "Stunnel ya esta instalado. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- INSTALADOR SSL (STUNNEL) ---${NC}"
    read -r -p "Puerto SSL [443]: " SP; SP=${SP:-443}
    [[ "$SP" =~ ^[0-9]+$ && "$SP" -ge 1 && "$SP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "Puerto SSH destino [22]: " SSHP; SSHP=${SSHP:-22}

    INFO "Instalando stunnel4..."
    apt update -y >/dev/null 2>&1
    apt install -y stunnel4 >/dev/null 2>&1 || { ERR "No se pudo instalar stunnel4."; PAUSA; return; }

    INFO "Generando certificado autofirmado (10 años)..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=vps-jorgebarrios" \
        -keyout /etc/stunnel/stunnel.key -out /etc/stunnel/stunnel.crt >/dev/null 2>&1
    cat /etc/stunnel/stunnel.crt /etc/stunnel/stunnel.key > /etc/stunnel/stunnel.pem 2>/dev/null

    cat > /etc/stunnel/stunnel.conf <<SEOF
pid = /var/run/stunnel4.pid
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1

[ssh-ssl]
accept = $SP
connect = 127.0.0.1:$SSHP
SEOF

    sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4 2>/dev/null
    ufw allow "$SP/tcp" >/dev/null 2>&1
    systemctl restart stunnel4 2>/dev/null || service stunnel4 restart 2>/dev/null
    sleep 1
    local IP; IP=$(hostname -I | awk '{print $1}')
    if pgrep -f stunnel >/dev/null 2>&1; then
        OK "Stunnel ACTIVO: SSL en el puerto $SP -> SSH local $SSHP"
        echo
        echo -e " ${AMARILLO}Datos para la config del cliente (HTTP Injector / tu app):${NC}"
        echo -e "  IP/Host: ${VERDE}$IP${NC}   Puerto SSL: ${VERDE}$SP${NC}"
        echo -e "  La app debe conectar por SSL/TLS al $SP y el trafico sale por SSH ($SSHP)."
    else
        ERR "Stunnel no levanto. Revisa con: systemctl status stunnel4"
    fi
    PAUSA
}

estado_protocolos(){
    echo -e "${CIAN}--- PROTOCOLOS ---${NC}"
    if command -v xray >/dev/null 2>&1; then
        local PUERTO; PUERTO=$(grep -o '"port": [0-9]*' /usr/local/etc/xray/config.json 2>/dev/null | head -1 | grep -o '[0-9]*')
        if pgrep -x xray >/dev/null 2>&1 || systemctl is-active --quiet xray 2>/dev/null; then
            echo -e " Xray:   ${VERDE}ACTIVO${NC} (puerto ${PUERTO:-?})"
        else
            echo -e " Xray:   ${AMARILLO}instalado, detenido${NC}"
        fi
    else
        echo -e " Xray:   ${ROJO}no instalado${NC}"
    fi
    if command -v stunnel4 >/dev/null 2>&1 || pgrep -f stunnel >/dev/null 2>&1; then
        local SPORT; SPORT=$(grep -A1 'ssh-ssl' /etc/stunnel/stunnel.conf 2>/dev/null | grep -o 'accept = [0-9]*' | grep -o '[0-9]*')
        pgrep -f stunnel >/dev/null 2>&1 \
            && echo -e " Stunnel (SSL): ${VERDE}ACTIVO${NC} (puerto ${SPORT:-?})" \
            || echo -e " Stunnel (SSL): ${AMARILLO}instalado, detenido${NC}"
    else
        echo -e " Stunnel (SSL): ${ROJO}no instalado${NC}"
    fi
    if pgrep -f badvpn-udpgw >/dev/null 2>&1; then
        echo -e " BadVPN: ${VERDE}ACTIVO${NC} (UDP GW local)"
    else
        echo -e " BadVPN: ${ROJO}no instalado${NC}"
    fi
    if grep -q '"ws"' /usr/local/etc/xray/config.json 2>/dev/null; then
        local WSP; WSP=$(grep -B4 '"ws"' /usr/local/etc/xray/config.json 2>/dev/null | grep -o '"port": [0-9]*' | head -1 | grep -o '[0-9]*')
        echo -e " Xray WS: ${VERDE}ACTIVO${NC} (puerto ${WSP:-?})"
    else
        echo -e " Xray WS: ${ROJO}no instalado${NC}"
    fi
    if systemctl is-active --quiet vpsjb-ws 2>/dev/null || pgrep -f vpsjb-ws.py >/dev/null 2>&1; then
        echo -e " WS-epro: ${VERDE}ACTIVO${NC} (WS -> SSH)"
    else
        echo -e " WS-epro: ${ROJO}no instalado${NC}"
    fi
    if systemctl is-active --quiet vpsjb-ss 2>/dev/null; then
        echo -e " Shadowsocks: ${VERDE}ACTIVO${NC}"
    else
        echo -e " Shadowsocks: ${ROJO}no instalado${NC}"
    fi
    if grep -q '"protocol": "trojan"' /usr/local/etc/xray/config.json 2>/dev/null; then
        echo -e " Trojan: ${VERDE}ACTIVO${NC} (en Xray)"
    else
        echo -e " Trojan: ${ROJO}no instalado${NC}"
    fi
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        echo -e " WireGuard: ${VERDE}ACTIVO${NC}"
    else
        echo -e " WireGuard: ${ROJO}no instalado${NC}"
    fi
    if pgrep -x cloudflared >/dev/null 2>&1; then
        echo -e " Tunel CDN: ${VERDE}ACTIVO${NC} ($(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cf-tunnel.log 2>/dev/null | head -1))"
    else
        echo -e " Tunel CDN: ${ROJO}inactivo${NC}"
    fi
    if command -v openvpn >/dev/null 2>&1; then
        systemctl is-active --quiet openvpn-server@server 2>/dev/null \
            && echo -e " OpenVPN: ${VERDE}ACTIVO${NC}" || echo -e " OpenVPN: ${AMARILLO}instalado, detenido${NC}"
    else
        echo -e " OpenVPN: ${ROJO}no instalado${NC}"
    fi
    PAUSA
}

# ------------------------------------------------------------
# TRAFICO POR USUARIO (iptables)
# ------------------------------------------------------------
trafico_activar(){
    iptables -N VPS-TRAFFIC 2>/dev/null
    iptables -F VPS-TRAFFIC 2>/dev/null
    local N=0 U
    for U in $(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd); do
        iptables -A VPS-TRAFFIC -m owner --uid-owner "$U" -j RETURN 2>/dev/null && N=$((N+1))
    done
    iptables -C OUTPUT -j VPS-TRAFFIC 2>/dev/null || iptables -A OUTPUT -j VPS-TRAFFIC 2>/dev/null
    [[ $N -gt 0 ]] && OK "Contadores activos para $N usuarios (se suman usuarios nuevos al re-activar)." \
                   || ERR "No se pudieron crear reglas (iptables fallo?)."
    PAUSA
}

trafico_ver(){
    echo -e "${CIAN}--- CONSUMO POR USUARIO (desde el ultimo reset) ---${NC}"
    printf "%-16s %-12s %s\n" "USUARIO" "USADO" "LIMITE(GB)"
    iptables -L VPS-TRAFFIC -v -x -n 2>/dev/null | awk '/owner UID match/ {print $2, $NF}' | while read -r BYTES UIDN; do
        local U MB LIM
        U=$(id -un "$UIDN" 2>/dev/null || echo "uid$UIDN")
        MB=$(( BYTES / 1048576 ))
        LIM=$(cat "/etc/vps-trafico/$U" 2>/dev/null || echo "-")
        printf "%-16s %7d MB   %s\n" "$U" "$MB" "$LIM"
    done
    echo
    INFO "Para medir desde cero, usa la opcion 'reset' del menu de trafico."
    PAUSA
}

trafico_limite(){
    read -r -p "Usuario: " USU
    id "$USU" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    read -r -p "Limite en GB (0 = sin limite): " G
    [[ "$G" =~ ^[0-9]+$ ]] || { ERR "Numero invalido."; PAUSA; return; }
    mkdir -p /etc/vps-trafico
    echo "$G" > "/etc/vps-trafico/$USU"
    OK "Limite de $USU = ${G}GB."
    PAUSA
}

trafico_cortar(){
    local CORTADOS=0
    for F in /etc/vps-trafico/*; do
        [[ -f "$F" ]] || continue
        local U G USED
        U=$(basename "$F"); G=$(cat "$F")
        [[ "$G" =~ ^[0-9]+$ && "$G" -gt 0 ]] || continue
        USED=$(iptables -L VPS-TRAFFIC -v -x -n 2>/dev/null | awk -v uid="$(id -u "$U" 2>/dev/null)" '$0 ~ "owner UID match "uid {print $2; exit}')
        [[ -n "$USED" && $(( USED / 1073741824 )) -ge "$G" ]] || continue
        if ! passwd -S "$U" 2>/dev/null | grep -q ' L '; then
            usermod -L "$U" 2>/dev/null; pkill -u "$U" 2>/dev/null
            INFO "$U supero su limite (${G}GB) y fue bloqueado."
            CORTADOS=$((CORTADOS+1))
        fi
    done
    [[ $CORTADOS -eq 0 ]] && OK "Nadie supero su limite." || OK "Bloqueados: $CORTADOS."
    PAUSA
}

trafico_reset(){
    iptables -Z VPS-TRAFFIC 2>/dev/null && OK "Contadores en cero." || ERR "La cadena no existe (activa antes)."
    PAUSA
}

menu_trafico(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_trafico)"
        FR_OPT 1 "$(T t_tr_activar)" 4 "$(T t_tr_cortar)"
        FR_OPT 2 "$(T t_tr_ver)" 5 "$(T t_tr_reset)"
        FR_OPT 3 "$(T t_tr_limite)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) trafico_activar ;;
            2) trafico_ver ;;
            3) trafico_limite ;;
            4) trafico_cortar ;;
            5) trafico_reset ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# SWAP / HYSTERIA2 / RESTORE / ZRAM
# ------------------------------------------------------------
agregar_swap(){
    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        ERR "Ya hay una swapfile activa."; PAUSA; return
    fi
    read -r -p "Tamaño del swap en GB [1]: " G; G=${G:-1}
    [[ "$G" =~ ^[0-9]+$ && "$G" -ge 1 ]] || { ERR "Tamaño invalido."; PAUSA; return; }
    INFO "Creando swap de ${G}GB..."
    fallocate -l "${G}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((G*1024)) status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile 2>/dev/null
    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        OK "Swap de ${G}GB activa y persistente."
    else
        rm -f /swapfile
        ERR "No se pudo activar la swap."
    fi
    PAUSA
}

agregar_zram(){
    if swapon --show 2>/dev/null | grep -q zram; then
        read -r -p "ZRAM ya esta activa. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
        swapoff /dev/zram0 2>/dev/null; zramctl --reset /dev/zram0 2>/dev/null; rmmod zram 2>/dev/null
    fi
    echo -e "${CIAN}--- ZRAM (memoria comprimida) ---${NC}"
    read -r -p "Tamaño zram en GB [1]: " G; G=${G:-1}
    [[ "$G" =~ ^[0-9]+$ && "$G" -ge 1 ]] || { ERR "Tamaño invalido."; PAUSA; return; }
    INFO "Cargando modulo zram..."
    modprobe zram 2>/dev/null || { ERR "Sin acceso al kernel (OpenVZ/LXC). Usa la opcion de swap."; PAUSA; return; }
    zramctl /dev/zram0 --algorithm zstd --size "${G}G" >/dev/null 2>&1 \
        || zramctl /dev/zram0 --algorithm lzo --size "${G}G" >/dev/null 2>&1 \
        || { ERR "zramctl fallo."; PAUSA; return; }
    mkswap /dev/zram0 >/dev/null 2>&1
    swapon -p 100 /dev/zram0 2>/dev/null || swapon /dev/zram0 2>/dev/null
    cat > /etc/systemd/system/vpsjb-zram.service <<ZEOF
[Unit]
Description=ZRAM VPS-JORGEBARRIOS
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "modprobe zram && (zramctl /dev/zram0 -a zstd -s ${G}G || zramctl /dev/zram0 -a lzo -s ${G}G) && mkswap /dev/zram0 && swapon -p 100 /dev/zram0"
ExecStop=/bin/bash -c "swapoff /dev/zram0 2>/dev/null; zramctl --reset /dev/zram0 2>/dev/null; rmmod zram 2>/dev/null"

[Install]
WantedBy=multi-user.target
ZEOF
    systemctl daemon-reload
    systemctl enable vpsjb-zram 2>/dev/null
    if swapon --show 2>/dev/null | grep -q zram; then
        OK "ZRAM de ${G}GB activa (prioridad alta, mas rapida que swap de disco)."
    else
        ERR "ZRAM no pudo activarse en este entorno."
    fi
    PAUSA
}

restaurar_backup(){
    local DIR=/root/backups
    echo -e "${CIAN}--- BACKUPS DISPONIBLES ---${NC}"
    ls -lh "$DIR"/*.tar.gz 2>/dev/null || { ERR "No hay backups en $DIR."; PAUSA; return; }
    read -r -p "Archivo a restaurar (nombre exacto, Enter = el mas reciente): " F
    [[ -z "$F" ]] && F=$(ls -t "$DIR"/*.tar.gz 2>/dev/null | head -1)
    [[ -f "$F" ]] || F="$DIR/$F"
    [[ -f "$F" ]] || { ERR "Archivo no encontrado."; PAUSA; return; }
    echo
    echo -e "${ROJO}ATENCION: esto pisa la configuracion actual de /etc${NC}"
    echo -e "${ROJO}(incluye usuarios, claves y la key de licencia).${NC}"
    read -r -p "Escribi RESTAURAR para confirmar: " CONF
    [[ "$CONF" != "RESTAURAR" ]] && { ERR "Cancelado."; PAUSA; return; }
    INFO "Restaurando $F ..."
    tar xzf "$F" -C / 2>/dev/null
    OK "Restaurado. Recomendado: reiniciar el VPS (opcion 32)."
    PAUSA
}

instalar_hysteria(){
    if command -v hysteria >/dev/null 2>&1; then
        read -r -p "Hysteria2 ya esta instalado. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- INSTALADOR HYSTERIA2 (UDP) ---${NC}"
    read -r -p "Puerto UDP [8443]: " HP; HP=${HP:-8443}
    [[ "$HP" =~ ^[0-9]+$ && "$HP" -ge 1 && "$HP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    INFO "Instalando Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1 \
        || { ERR "No se pudo instalar (sin red?)."; PAUSA; return; }
    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=vps-jorgebarrios" \
        -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt >/dev/null 2>&1
    local PASS; PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)
    cat > /etc/hysteria/config.yaml <<HEOF
listen: :$HP
auth:
  type: password
  password: "$PASS"
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
HEOF
    ufw allow "$HP/udp" >/dev/null 2>&1
    systemctl enable --now hysteria-server >/dev/null 2>&1
    sleep 1
    local IP; IP=$(hostname -I | awk '{print $1}')
    if systemctl is-active --quiet hysteria-server 2>/dev/null || pgrep -x hysteria >/dev/null 2>&1; then
        OK "Hysteria2 corriendo en UDP $HP"
        echo
        echo -e " ${AMARILLO}Enlace para el cliente (NekoBox / tu app):${NC}"
        echo -e " ${VERDE}hysteria2://$PASS@$IP:$HP/?insecure=1#VPS-JORGEBARRIOS${NC}"
    else
        ERR "Hysteria no levanto. Revisa: journalctl -u hysteria-server"
    fi
    PAUSA
}

# ------------------------------------------------------------
# BADVPN
# ------------------------------------------------------------
instalar_badvpn(){
    if pgrep -f badvpn-udpgw >/dev/null 2>&1; then
        read -r -p "BadVPN ya esta corriendo. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- INSTALADOR BADVPN (UDP GW) ---${NC}"
    read -r -p "Puerto UDP GW [7300]: " BP; BP=${BP:-7300}
    [[ "$BP" =~ ^[0-9]+$ && "$BP" -ge 1 && "$BP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    INFO "Instalando badvpn (repositorio oficial Ubuntu)..."
    apt update -y >/dev/null 2>&1
    apt install -y badvpn >/dev/null 2>&1 || { ERR "No se pudo instalar badvpn (sin red o paquete ausente)."; PAUSA; return; }
    cat > /etc/systemd/system/badvpn.service <<BEOF
[Unit]
Description=BadVPN UDP Gateway (VPS-JORGEBARRIOS)
After=network.target

[Service]
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:$BP --max-clients 500
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
BEOF
    systemctl daemon-reload
    systemctl enable --now badvpn 2>/dev/null
    sleep 1
    if systemctl is-active --quiet badvpn 2>/dev/null || pgrep -f badvpn-udpgw >/dev/null 2>&1; then
        OK "BadVPN ACTIVO en 127.0.0.1:$BP"
        echo
        echo -e " ${AMARILLO}En la app del cliente (HTTP Injector / eProxy / tu app):${NC}"
        echo -e "  UDP Gateway: ${VERDE}127.0.0.1:$BP${NC} a traves del tunel SSH/SSL"
        echo -e "  ${CIAN}Con eso funcionan juegos UDP y llamadas de WhatsApp/Telegram.${NC}"
    else
        ERR "BadVPN no levanto. Revisa: journalctl -u badvpn"
    fi
    PAUSA
}

quitar_badvpn(){
    systemctl disable --now badvpn 2>/dev/null
    rm -f /etc/systemd/system/badvpn.service
    systemctl daemon-reload 2>/dev/null
    pkill -f badvpn-udpgw 2>/dev/null
    OK "BadVPN detenido y removido."
    PAUSA
}

# ------------------------------------------------------------
# WEBSOCKET: Xray WS y WS-epro
# ------------------------------------------------------------
instalar_xray_ws(){
    if ! command -v xray >/dev/null 2>&1; then
        INFO "Xray no esta instalado, instalando primero..."
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
            || { ERR "No se pudo instalar Xray."; PAUSA; return; }
    fi
    echo -e "${CIAN}--- XRAY VLESS + WEBSOCKET (para CDN) ---${NC}"
    read -r -p "Puerto WS [8080]: " WP; WP=${WP:-8080}
    [[ "$WP" =~ ^[0-9]+$ && "$WP" -ge 1 && "$WP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "Path WS [/vpsjb]: " WPATH; WPATH=${WPATH:-/vpsjb}
    [[ "$WPATH" == /* ]] || WPATH="/$WPATH"
    local UUID; UUID=$(xray uuid)
    mkdir -p /usr/local/etc/xray
    python3 - "$WP" "$WPATH" "$UUID" <<'PYEOF'
import json, sys
port, path, uid = int(sys.argv[1]), sys.argv[2], sys.argv[3]
cfgp = "/usr/local/etc/xray/config.json"
try:
    cfg = json.load(open(cfgp))
except Exception:
    cfg = {"log":{"loglevel":"warning"},"inbounds":[],
           "outbounds":[{"protocol":"freedom"}]}
ib = [i for i in cfg.get("inbounds", []) if i.get("port") != port]
ib.append({
    "port": port,
    "protocol": "vless",
    "settings": {"clients":[{"id": uid}], "decryption": "none"},
    "streamSettings": {"network": "ws", "wsSettings": {"path": path}},
    "sniffing": {"enabled": True, "destOverride": ["http","tls"]}
})
cfg["inbounds"] = ib
json.dump(cfg, open(cfgp, "w"), indent=2)
print("ok")
PYEOF
    ufw allow "$WP/tcp" >/dev/null 2>&1
    systemctl restart xray 2>/dev/null
    sleep 1
    local IP; IP=$(hostname -I | awk '{print $1}')
    if systemctl is-active --quiet xray 2>/dev/null || pgrep -x xray >/dev/null 2>&1; then
        OK "Xray WS corriendo en el puerto $WP (path $WPATH)"
        echo
        echo -e " ${AMARILLO}Enlace VLESS + WebSocket (ponelo detras de Cloudflare):${NC}"
        echo -e " ${VERDE}vless://$UUID@$IP:$WP?type=ws&path=%2F${WPATH#/}&security=none#VPSJB-WS${NC}"
        INFO "En tu app: network=ws, path=$WPATH, TLS desactivado (el CDN lo pone)."
    else
        ERR "Xray no levanto. Revisa: journalctl -u xray"
    fi
    PAUSA
}

instalar_wsepro(){
    if systemctl is-active --quiet vpsjb-ws 2>/dev/null; then
        read -r -p "WS-epro ya esta corriendo. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- WEBSOCKET SSH (ws-epro propio, WS -> SSH 22) ---${NC}"
    read -r -p "Puerto WS [80]: " EP; EP=${EP:-80}
    [[ "$EP" =~ ^[0-9]+$ && "$EP" -ge 1 && "$EP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }

    cat > /usr/local/bin/vpsjb-ws.py <<'WSEOF'
#!/usr/bin/env python3
import socket, base64, hashlib, struct, threading, sys

LISTEN = ('0.0.0.0', int(sys.argv[1]) if len(sys.argv) > 1 else 80)
TARGET = ('127.0.0.1', int(sys.argv[2]) if len(sys.argv) > 2 else 22)
GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

def recv_until(sock, marker, limit=8192):
    data = b''
    while marker not in data and len(data) < limit:
        chunk = sock.recv(1024)
        if not chunk:
            break
        data += chunk
    return data

def handshake(c):
    req = recv_until(c, b'\r\n\r\n')
    if not req:
        return False
    key = ''
    for line in req.split(b'\r\n'):
        if line.lower().startswith(b'sec-websocket-key:'):
            key = line.split(b':', 1)[1].strip().decode()
    if not key:
        return False
    acc = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
    return True

def read_frame(c):
    hdr = c.recv(2)
    if len(hdr) < 2:
        return None, None
    op = hdr[0] & 0x0F
    b2 = hdr[1]
    masked = b2 & 0x80
    ln = b2 & 0x7F
    if ln == 126:
        ln = struct.unpack('>H', c.recv(2))[0]
    elif ln == 127:
        ln = struct.unpack('>Q', c.recv(8))[0]
    mask = c.recv(4) if masked else None
    payload = b''
    while len(payload) < ln:
        chunk = c.recv(ln - len(payload))
        if not chunk:
            break
        payload += chunk
    if mask:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return op, payload

def send_frame(s, data, op=2):
    h = bytes([0x80 | op])
    ln = len(data)
    if ln < 126:
        h += bytes([ln])
    elif ln < 65536:
        h += bytes([126]) + struct.pack('>H', ln)
    else:
        h += bytes([127]) + struct.pack('>Q', ln)
    s.sendall(h + data)

def ws_to_tcp(ws, tcp):
    try:
        while True:
            op, data = read_frame(ws)
            if op is None or op == 8:
                break
            if op in (0, 1, 2) and data:
                tcp.sendall(data)
    except Exception:
        pass
    finally:
        try:
            tcp.shutdown(socket.SHUT_WR)
        except Exception:
            pass

def tcp_to_ws(tcp, ws):
    try:
        while True:
            data = tcp.recv(65536)
            if not data:
                break
            send_frame(ws, data)
    except Exception:
        pass
    finally:
        try:
            ws.close()
        except Exception:
            pass

def handle(c):
    try:
        if not handshake(c):
            c.close()
            return
        tcp = socket.create_connection(TARGET, timeout=15)
    except Exception:
        c.close()
        return
    t1 = threading.Thread(target=ws_to_tcp, args=(c, tcp))
    t2 = threading.Thread(target=tcp_to_ws, args=(tcp, c))
    t1.start(); t2.start()
    t1.join(); t2.join()
    for s in (c, tcp):
        try:
            s.close()
        except Exception:
            pass

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(LISTEN)
srv.listen(256)
print("WS->SSH proxy en %s:%d (destino %s:%d)" % (LISTEN[0], LISTEN[1], TARGET[0], TARGET[1]), flush=True)
while True:
    client, _ = srv.accept()
    threading.Thread(target=handle, args=(client,), daemon=True).start()
WSEOF
    chmod +x /usr/local/bin/vpsjb-ws.py

    cat > /etc/systemd/system/vpsjb-ws.service <<SVCEOF
[Unit]
Description=WS-epro VPS-JORGEBARRIOS (WS -> SSH)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/vpsjb-ws.py $EP 22
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable --now vpsjb-ws 2>/dev/null
    sleep 1
    local IP; IP=$(hostname -I | awk '{print $1}')
    if systemctl is-active --quiet vpsjb-ws 2>/dev/null || pgrep -f vpsjb-ws.py >/dev/null 2>&1; then
        ufw allow "$EP/tcp" >/dev/null 2>&1
        OK "WS-epro ACTIVO: ws://$IP:$EP (cualquier path) -> SSH 22"
        echo
        echo -e " ${AMARILLO}Config del cliente (HTTP Injector / eProxy / tu app):${NC}"
        echo -e "  Servidor WS: ${VERDE}$IP:$EP${NC}   (tildar WebSocket, sin path o path /)"
    else
        ERR "El proxy WS no levanto. Revisa: journalctl -u vpsjb-ws"
    fi
    PAUSA
}

menu_protocolos(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_prot)"
        FR_OPT 1 "$(T t_xray)" 2 "$(T t_xray_ws)"
        FR_OPT 3 "$(T t_openvpn)" 4 "$(T t_stunnel)"
        FR_OPT 5 "$(T t_hysteria)" 6 "$(T t_badvpn)"
        FR_OPT 7 "$(T t_wsepro)" 8 "$(T t_shadowsocks)"
        FR_OPT 9 "$(T t_trojan)" 10 "$(T t_wireguard)"
        FR_OPT 11 "$(T t_estado_prot)" 12 "$(T t_quitar)"
        FR_OPT 13 "$(T t_cf_test)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) instalar_xray ;;        2) instalar_xray_ws ;;
            3) instalar_openvpn ;;     4) instalar_ssl_stunnel ;;
            5) instalar_hysteria ;;    6) instalar_badvpn ;;
            7) instalar_wsepro ;;      8) instalar_shadowsocks ;;
            9) instalar_trojan ;;      10) instalar_wireguard ;;
            11) estado_protocolos ;;   12) menu_quitar ;;
            13) tunel_trycloudflare ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# SUBMENUS DEL PANEL
# ------------------------------------------------------------
menu_usuarios(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_usuarios)"
        FR_OPT 1 "$(T t_crear)" 7 "$(T t_eliminar)"
        FR_OPT 2 "$(T t_listar)" 8 "$(T t_vencidos)"
        FR_OPT 3 "$(T t_clave)" 9 "$(T t_test)"
        FR_OPT 4 "$(T t_bloquear)" 10 "$(T t_conexiones)"
        FR_OPT 5 "$(T t_renovar)" 11 "$(T t_desconectar)"
        FR_OPT 6 "$(T t_limite)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) crear_usuario ;;   2) listar_usuarios ;; 3) cambiar_clave ;;
            4) bloquear_usuario ;; 5) renovar_usuario ;; 6) cambiar_limite ;;
            7) eliminar_usuario ;; 8) eliminar_vencidos ;; 9) crear_test_ssh ;;
            10) conexiones_online ;; 11) matar_conexion ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

menu_seguridad(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_seg)"
        FR_OPT 1 "$(T t_fail2ban)" 5 "$(T t_ver_puertos)"
        FR_OPT 2 "$(T t_limiter_on)" 6 "$(T t_abrir_puerto)"
        FR_OPT 3 "$(T t_limiter_off)" 7 "$(T t_banner)"
        FR_OPT 4 "$(T t_puerto_ssh)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) instalar_fail2ban ;; 2) limiter_aplicar ;; 3) limiter_quitar ;;
            4) cambiar_puerto_ssh ;; 5) ver_puertos ;; 6) abrir_puerto ;; 7) menu_banner ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

menu_sistema(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_sistema)"
        FR_OPT 1 "$(T t_monitoreo)" 5 "$(T t_mantenimiento)"
        FR_OPT 2 "$(T t_diagnostico)" 6 "$(T t_hostname)"
        FR_OPT 3 "$(T t_optimizar)" 7 "$(T t_update)"
        FR_OPT 4 "$(T t_swap)" 8 "$(T t_reiniciar)"
        FR_OPT 9 "$(T t_zram)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) monitoreo ;; 2) diagnostico ;; 3) optimizar ;; 4) agregar_swap ;;
            5) mantenimiento ;; 6) cambiar_hostname ;; 7) update_sistema ;; 8) reiniciar_vps ;;
            9) agregar_zram ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

menu_herramientas(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_herr)"
        FR_OPT 1 "$(T t_global)" 4 "$(T t_autoupdate)"
        FR_OPT 2 "$(T t_automenu_on)" 5 "$(T t_checkuser)"
        FR_OPT 3 "$(T t_automenu_off)" 6 "$(T t_idioma)"
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) instalar_comando_global ;; 2) auto_menu ;; 3) quitar_auto_menu ;;
            4) auto_update ;; 5) menu_checkuser ;;
            6) rm -f /etc/vps-manager.lang; seleccionar_idioma; OK "Idioma: $IDIOMA / Language: $IDIOMA"; PAUSA ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

menu_backup(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_backup)"
        FR_OPT 1 "$(T t_backup_crear)" 2 "$(T t_backup_restaurar)"
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) backup_basico ;; 2) restaurar_backup ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# SHADOWSOCKS / TROJAN / WIREGUARD
# ------------------------------------------------------------
instalar_shadowsocks(){
    if systemctl is-active --quiet vpsjb-ss 2>/dev/null; then
        read -r -p "Shadowsocks ya esta activo. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- SHADOWSOCKS ---${NC}"
    read -r -p "Puerto SS [8388]: " SP; SP=${SP:-8388}
    [[ "$SP" =~ ^[0-9]+$ && "$SP" -ge 1 && "$SP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    INFO "Instalando shadowsocks-libev (repositorio Ubuntu)..."
    apt update -y >/dev/null 2>&1
    apt install -y shadowsocks-libev >/dev/null 2>&1 || { ERR "No se pudo instalar shadowsocks-libev."; PAUSA; return; }
    local PASS; PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 16)
    mkdir -p /etc/shadowsocks-libev
    cat > /etc/shadowsocks-libev/config.json <<SSEOF
{
    "server": "0.0.0.0",
    "server_port": $SP,
    "password": "$PASS",
    "method": "aes-256-gcm",
    "mode": "tcp_and_udp",
    "fast_open": true
}
SSEOF
    cat > /etc/systemd/system/vpsjb-ss.service <<SSSVC
[Unit]
Description=Shadowsocks VPS-JORGEBARRIOS
After=network.target

[Service]
ExecStart=/usr/bin/ss-server -c /etc/shadowsocks-libev/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SSSVC
    systemctl daemon-reload
    systemctl enable --now vpsjb-ss 2>/dev/null
    ufw allow "$SP/tcp" >/dev/null 2>&1; ufw allow "$SP/udp" >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet vpsjb-ss 2>/dev/null; then
        local IP B64
        IP=$(hostname -I | awk '{print $1}')
        B64=$(printf 'aes-256-gcm:%s' "$PASS" | base64 -w0 2>/dev/null || printf 'aes-256-gcm:%s' "$PASS" | base64)
        OK "Shadowsocks ACTIVO en puerto $SP (aes-256-gcm)"
        echo
        echo -e " ${AMARILLO}Enlace para el cliente (SS/SSR compatible):${NC}"
        echo -e " ${VERDE}ss://$B64@$IP:$SP#VPSJB-SS${NC}"
    else
        ERR "Shadowsocks no levanto. Revisa: journalctl -u vpsjb-ss"
    fi
    PAUSA
}

instalar_trojan(){
    if ! command -v xray >/dev/null 2>&1; then
        INFO "Xray no esta instalado, instalando primero..."
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
            || { ERR "No se pudo instalar Xray."; PAUSA; return; }
    fi
    echo -e "${CIAN}--- TROJAN (dentro de Xray) ---${NC}"
    read -r -p "Puerto Trojan [9443]: " TP; TP=${TP:-9443}
    [[ "$TP" =~ ^[0-9]+$ && "$TP" -ge 1 && "$TP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "SNI (dominio camuflaje) [www.microsoft.com]: " SNI; SNI=${SNI:-www.microsoft.com}
    mkdir -p /etc/vpsjb-trojan
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=$SNI" \
        -keyout /etc/vpsjb-trojan/key.pem -out /etc/vpsjb-trojan/cert.pem >/dev/null 2>&1
    local PASS; PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 20)
    python3 - "$TP" "$SNI" "$PASS" <<'PYEOF'
import json, sys
port, sni, pwd = int(sys.argv[1]), sys.argv[2], sys.argv[3]
cfgp = "/usr/local/etc/xray/config.json"
try:
    cfg = json.load(open(cfgp))
except Exception:
    cfg = {"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}
ib = [i for i in cfg.get("inbounds", []) if i.get("port") != port]
ib.append({
    "port": port,
    "protocol": "trojan",
    "settings": {"clients":[{"password": pwd}]},
    "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
            "serverName": sni,
            "certificates": [{"certificateFile": "/etc/vpsjb-trojan/cert.pem",
                              "keyFile": "/etc/vpsjb-trojan/key.pem"}]
        }
    }
})
cfg["inbounds"] = ib
json.dump(cfg, open(cfgp, "w"), indent=2)
print("ok")
PYEOF
    ufw allow "$TP/tcp" >/dev/null 2>&1
    systemctl restart xray 2>/dev/null
    sleep 1
    if systemctl is-active --quiet xray 2>/dev/null || pgrep -x xray >/dev/null 2>&1; then
        local IP; IP=$(hostname -I | awk '{print $1}')
        OK "Trojan ACTIVO en puerto $TP (SNI $SNI)"
        echo
        echo -e " ${AMARILLO}Enlace para el cliente (activar 'allowInsecure'):${NC}"
        echo -e " ${VERDE}trojan://$PASS@$IP:$TP?security=tls&sni=$SNI&allowInsecure=1#VPSJB-Trojan${NC}"
    else
        ERR "Xray no levanto. Revisa: journalctl -u xray"
    fi
    PAUSA
}

instalar_wireguard(){
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        read -r -p "WireGuard ya esta activo. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- WIREGUARD ---${NC}"
    read -r -p "Puerto UDP [51820]: " WP; WP=${WP:-51820}
    [[ "$WP" =~ ^[0-9]+$ && "$WP" -ge 1 && "$WP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    INFO "Instalando wireguard..."
    apt update -y >/dev/null 2>&1
    apt install -y wireguard >/dev/null 2>&1 || { ERR "No se pudo instalar wireguard."; PAUSA; return; }
    local SPRIV SPRIV2 CPRIV CPUB SPUB IFACE
    SPRIV=$(wg genkey); SPUB=$(echo "$SPRIV" | wg pubkey)
    CPRIV=$(wg genkey); CPUB=$(echo "$CPRIV" | wg pubkey)
    IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    [[ -z "$IFACE" ]] && IFACE="eth0"
    cat > /etc/wireguard/wg0.conf <<WGEOF
[Interface]
Address = 10.66.0.1/24
ListenPort = $WP
PrivateKey = $SPRIV
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE

[Peer]
PublicKey = $CPUB
AllowedIPs = 10.66.0.2/32
WGEOF
    chmod 600 /etc/wireguard/wg0.conf
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    ufw allow "$WP/udp" >/dev/null 2>&1
    systemctl enable --now wg-quick@wg0 2>/dev/null
    sleep 1
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        local IP; IP=$(hostname -I | awk '{print $1}')
        cat > /root/wg-client.conf <<CLIENTEOF
[Interface]
PrivateKey = $CPRIV
Address = 10.66.0.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SPUB
Endpoint = $IP:$WP
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CLIENTEOF
        OK "WireGuard ACTIVO (puerto UDP $WP)"
        INFO "Config del cliente: /root/wg-client.conf"
        echo -e " ${AMARILLO}--- para la app WireGuard ---${NC}"
        cat /root/wg-client.conf
    else
        ERR "WireGuard no levanto. Revisa: journalctl -u wg-quick@wg0"
    fi
    PAUSA
}

# ------------------------------------------------------------
# DESINSTALADORES
# ------------------------------------------------------------
quitar_xray_completo(){
    systemctl disable --now xray 2>/dev/null
    rm -f /etc/systemd/system/xray.service /usr/local/bin/xray /usr/local/bin/xray-linux-*
    rm -rf /usr/local/etc/xray /etc/vpsjb-trojan
    systemctl daemon-reload 2>/dev/null
    pkill -x xray 2>/dev/null
    OK "Xray (y Trojan/WS) removido."
    PAUSA
}
quitar_wsepro(){
    systemctl disable --now vpsjb-ws 2>/dev/null
    rm -f /etc/systemd/system/vpsjb-ws.service /usr/local/bin/vpsjb-ws.py
    systemctl daemon-reload 2>/dev/null
    pkill -f vpsjb-ws.py 2>/dev/null
    OK "WS-epro removido."
    PAUSA
}
quitar_stunnel(){
    systemctl disable --now stunnel4 2>/dev/null
    rm -f /etc/stunnel/stunnel.conf /etc/stunnel/stunnel.pem /etc/stunnel/stunnel.crt /etc/stunnel/stunnel.key
    OK "Stunnel detenido (el paquete queda instalado)."
    PAUSA
}
quitar_hysteria(){
    systemctl disable --now hysteria-server 2>/dev/null
    rm -f /etc/systemd/system/hysteria-server.service /etc/hysteria/config.yaml
    systemctl daemon-reload 2>/dev/null
    pkill -x hysteria 2>/dev/null
    OK "Hysteria2 removido."
    PAUSA
}
quitar_shadowsocks(){
    systemctl disable --now vpsjb-ss 2>/dev/null
    rm -f /etc/systemd/system/vpsjb-ss.service /etc/shadowsocks-libev/config.json
    systemctl daemon-reload 2>/dev/null
    pkill -x ss-server 2>/dev/null
    OK "Shadowsocks removido (el paquete queda instalado)."
    PAUSA
}
quitar_trojan(){
    python3 <<'PYEOF'
import json
try:
    cfg = json.load(open("/usr/local/etc/xray/config.json"))
    cfg["inbounds"] = [i for i in cfg.get("inbounds", []) if i.get("protocol") != "trojan"]
    json.dump(cfg, open("/usr/local/etc/xray/config.json", "w"), indent=2)
    print("ok")
except Exception:
    pass
PYEOF
    rm -rf /etc/vpsjb-trojan
    systemctl restart xray 2>/dev/null
    OK "Trojan removido del Xray."
    PAUSA
}
quitar_wireguard(){
    systemctl disable --now wg-quick@wg0 2>/dev/null
    rm -f /etc/wireguard/wg0.conf /root/wg-client.conf
    OK "WireGuard removido."
    PAUSA
}

menu_quitar(){
    while true; do
        cabecera
        SUBTOP "$(T t_sub_quitar)"
        FR_OPT 1 "$(T t_q_xray)" 5 "Hysteria2"
        FR_OPT 2 "WS-epro" 6 "$(T t_shadowsocks)"
        FR_OPT 3 "Stunnel" 7 "$(T t_trojan)"
        FR_OPT 4 "BadVPN" 8 "$(T t_wireguard)"
        FR_OPT 9 "$(T t_q_tunnel)" "" ""
        FR_OPT 0 "$(T t_volver)" "" ""
        FR_BOT
        PROMPT
        case "$OP" in
            1) quitar_xray_completo ;; 2) quitar_wsepro ;; 3) quitar_stunnel ;; 4) quitar_badvpn ;;
            5) quitar_hysteria ;; 6) quitar_shadowsocks ;; 7) quitar_trojan ;; 8) quitar_wireguard ;;
            9) quitar_tunel_cdn ;;
            0) break ;; *) ERR "$(T t_opinv)"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# TUNEL CDN
# ------------------------------------------------------------
tunel_trycloudflare(){
    if pgrep -x cloudflared >/dev/null 2>&1; then
        read -r -p "Ya hay un tunel CDN corriendo. Reiniciarlo (nueva URL)? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
        pkill -x cloudflared 2>/dev/null; sleep 2
    fi
    if ! command -v cloudflared >/dev/null 2>&1; then
        INFO "Instalando cloudflared..."
        local ARCH="amd64"; [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]] && ARCH="arm64"
        timeout 25 wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb" -O /tmp/cloudflared.deb 2>/dev/null \
            && dpkg -i /tmp/cloudflared.deb >/dev/null 2>&1 && rm -f /tmp/cloudflared.deb \
            || { ERR "No se pudo descargar cloudflared (sin red?)."; PAUSA; return; }
    fi
    local PUERTO=80
    if [[ -f /etc/systemd/system/vpsjb-ws.service ]]; then
        PUERTO=$(grep -o 'vpsjb-ws.py [0-9]*' /etc/systemd/system/vpsjb-ws.service | awk '{print $2}' | head -1)
        PUERTO=${PUERTO:-80}
    fi
    if ! pgrep -f vpsjb-ws.py >/dev/null 2>&1; then
        WARN "WS-epro no esta corriendo. Instalalo primero (Protocolos -> 7, puerto 80)."
        PAUSA; return
    fi
    INFO "Levantando tunel CDN hacia 127.0.0.1:${PUERTO}..."
    nohup cloudflared tunnel --url "http://127.0.0.1:${PUERTO}" > /tmp/cf-tunnel.log 2>&1 &
    local URL="" i
    for i in $(seq 1 15); do
        sleep 2
        URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cf-tunnel.log | head -1)
        [[ -n "$URL" ]] && break
    done
    echo
    if [[ -n "$URL" ]]; then
        OK "Tunel CDN activo:"
        echo
        echo -e " ${VERDE}${URL}${NC}"
        echo
        echo -e " ${AMARILLO}Uso en la app: WebSocket activado, servidor ${URL#https://} puerto 443, path /${NC}"
        echo -e " ${AMARILLO}OJO: la URL cambia al reiniciar el tunel. Es para pruebas/demos.${NC}"
        echo -e " ${CIAN}Log: /tmp/cf-tunnel.log  |  Frenar: pkill cloudflared${NC}"
    else
        ERR "El tunel no dio URL a tiempo. Log:"
        tail -5 /tmp/cf-tunnel.log 2>/dev/null
    fi
    PAUSA
}

quitar_tunel_cdn(){
    pkill -x cloudflared 2>/dev/null && OK "Tunel CDN detenido." || ERR "No habia tunel corriendo."
    PAUSA
}

# ------------------------------------------------------------
# MENU PRINCIPAL
# ------------------------------------------------------------
[[ $EUID -ne 0 ]] && { echo -e "${ROJO}Ejecuta como root o con sudo.${NC}"; exit 1; }

# Validacion rapida de sintaxis (evita ejecutar un script corrupto)
if ! bash -n "$0" 2>/dev/null; then
    echo -e "${ROJO}[FATAL]${NC} El script tiene errores de sintaxis. NO continuar."
    exit 1
fi

seleccionar_idioma
ghost_bootstrap
gate_licencia

while true; do
    cabecera
    FR_TOP
    FR_TXT "  ${BLANCO}$(T t_menu_principal)${NC}"
    FR_MID
    FR_OPT 1 "$(T t_usuarios)" 2 "$(T t_protocolos)"
    FR_OPT 3 "$(T t_seguridad)" 4 "$(T t_sistema)"
    FR_OPT 5 "$(T t_herramientas)" 6 "$(T t_webmin)"
    FR_OPT 7 "$(T t_backup)" 8 "$(T t_diagnostico)"
    FR_MID
    FR_TXT "  $(T t_servidor_id): ${VERDE}$(machine_hash)${NC}   |   $(date '+%d/%m/%Y %H:%M')"
    FR_OPT 0 "$(T t_salir)" "" ""
    FR_BOT
    PROMPT
    case "$OP" in
        1) menu_usuarios ;;
        2) menu_protocolos ;;
        3) menu_seguridad ;;
        4) menu_sistema ;;
        5) menu_herramientas ;;
        6) menu_webmin ;;
        7) menu_backup ;;
        8) diagnostico ;;
        0) echo -e "${VERDE}Hasta luego!${NC}"; exit 0 ;;
        *) ERR "$(T t_opinv)"; sleep 1 ;;
    esac
done
