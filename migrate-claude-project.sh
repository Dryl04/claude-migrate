#!/usr/bin/env bash
#
# migrate-claude-project.sh — Migration interactive d'un projet Claude Code
# (code + sessions de conversation + agents/commandes/skills globaux)
# depuis ce PC vers un serveur distant.
#
# Fonctionnalités :
#   - n'importe quel projet ayant des sessions dans ~/.claude ou ~/.claude-work
#     (second compte optionnel, via CLAUDE_CONFIG_DIR), ou n'importe quel
#     dossier local sans session ;
#   - connexion par alias ~/.ssh/config, user@host, user@host:port,
#     ou mot de passe (ssh-copy-id au premier usage, repli sshpass) ;
#   - installe les outils manquants sur le serveur, avec accord explicite :
#     rsync, tmux, mosh, git (apt/dnf/pacman), node/npm (user-space),
#     Claude Code, CLI Supabase ;
#   - serveurs mémorisés dans config/servers.conf (à côté du script).
#
# Usage :
#   ./migrate-claude-project.sh                          # interactif complet
#   ./migrate-claude-project.sh --dry-run                # simulation
#   ./migrate-claude-project.sh --list                   # projets + profils, puis quitte
#   ./migrate-claude-project.sh --project <chemin> --server <cible|profil>
#   ./migrate-claude-project.sh --yes --project <chemin> --server <cible> [--port N]
#                                                       # non-interactif : tout en défaut
#
# Options :
#   --project <chemin>    dossier de travail du projet (celui des sessions Claude)
#   --server <cible>      user@host, user@host:port, alias ssh, ou nom de profil
#   --port <N>            port ssh (si --server sans port)
#   --account <compte>    claude | claude-work | both (sessions à migrer)
#   --dest-root <chemin>  dossier racine des projets sur le serveur
#   --no-globals          ne pas copier agents/commandes/skills/settings
#   --yes                 mode non-interactif (défauts partout ; --project et
#                         --server obligatoires)
#   --dry-run             simulation : rien n'est écrit sur le serveur
#
# Sécurité :
#   - les jetons (.credentials.json, .claude.json) ne sont JAMAIS copiés ;
#   - la config partagée (agents, skills, settings.json) part en --ignore-existing :
#     rien n'est écrasé sur le serveur ;
#   - le code part sans --delete : les fichiers distants ne sont jamais supprimés.
#
set -uo pipefail

VERSION="1.0"
# Tout vit à côté du script : config/ (profils + journaux, non versionné),
# README.md (documentation).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$SCRIPT_DIR/config"
SERVERS_CONF="$CONF_DIR/servers.conf"
LOG_DIR="$CONF_DIR/logs"
mkdir -p "$CONF_DIR" "$LOG_DIR" 2>/dev/null || true
LOGFILE="$LOG_DIR/migrate-$(date +%Y%m%d-%H%M%S).log"

# ---------------------------------------------------------------------------
# 0. Options
# ---------------------------------------------------------------------------
DRY_RUN=0
ASSUME_DEFAULTS=0
OPT_PROJECT=""
OPT_SERVER=""
OPT_PORT=""
OPT_DEST_ROOT=""
OPT_ACCOUNT=""
OPT_GLOBALS=""           # "" = demander ; "non" = --no-globals
MODE_LIST=0

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY_RUN=1 ;;
        --yes|-y)     ASSUME_DEFAULTS=1 ;;
        --project)    shift; OPT_PROJECT="${1:-}" ;;
        --server)     shift; OPT_SERVER="${1:-}" ;;
        --port)       shift; OPT_PORT="${1:-}" ;;
        --account)    shift; OPT_ACCOUNT="${1:-}" ;;
        --dest-root)  shift; OPT_DEST_ROOT="${1:-}" ;;
        --no-globals) OPT_GLOBALS="non" ;;
        --list)       MODE_LIST=1 ;;
        --help|-h)    usage 0 ;;
        *) echo "Option inconnue : $1" >&2; usage 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# 1. Journal et aides
# ---------------------------------------------------------------------------
FAILED_STEPS=()

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOGFILE"; }
step() { log ""; log "==> $*"; }

die() { log "ERREUR FATALE : $*"; log "Journal complet : $LOGFILE"; exit 1; }

run() { # run "description" commande args...
    local desc="$1"; shift
    log "    -> $desc"
    if "$@" >>"$LOGFILE" 2>&1; then
        log "    OK : $desc"
    else
        log "    ERREUR : $desc (détails dans $LOGFILE)"
        FAILED_STEPS+=("$desc")
    fi
}

trap 'log "Interrompu."; exit 130' INT

# ---------------------------------------------------------------------------
# 2. Aides interactives
#    En mode --yes, chaque question renvoie sa valeur par défaut.
#    En EOF (entrée fermée), on s'arrête proprement plutôt que de deviner.
# ---------------------------------------------------------------------------

ask_value() { # ask_value "question" "défaut" → résultat dans ANSWER
    local q="$1" def="$2" rep=""
    if [ "$ASSUME_DEFAULTS" -eq 1 ]; then ANSWER="$def"; return; fi
    printf '%s [%s] : ' "$q" "$def" >&2
    read -r rep || die "entrée standard fermée — relancer sans --yes pour un usage interactif"
    ANSWER="${rep:-$def}"
}

confirm() { # confirm "question" [défaut o|n]
    local q="$1" def="${2:-o}" rep="" hint
    [ "$def" = "o" ] && hint="[O/n]" || hint="[o/N]"
    if [ "$ASSUME_DEFAULTS" -eq 1 ]; then [ "$def" = "o" ]; return; fi
    while true; do
        printf '%s %s : ' "$q" "$hint" >&2
        read -r rep || die "entrée standard fermée — relancer sans --yes pour un usage interactif"
        rep="${rep:-$def}"
        case "$rep" in [oOyY]*) return 0 ;; [nN]*) return 1 ;; esac
    done
}

menu_select() { # menu_select "invite" "option 1" ... → indice choisi dans ANSWER
    local prompt="$1"; shift
    local opts=("$@") i=1 rep
    if [ "$ASSUME_DEFAULTS" -eq 1 ]; then
        log "    (mode --yes) choix automatique : ${opts[0]}"
        ANSWER=1; return
    fi
    for o in "${opts[@]}"; do printf '  %d) %s\n' "$i" "$o" >&2; i=$((i+1)); done
    while true; do
        printf '%s [1-%d] : ' "$prompt" "$#" >&2
        read -r rep || die "entrée standard fermée — relancer sans --yes pour un usage interactif"
        if [[ "$rep" =~ ^[0-9]+$ ]] && [ "$rep" -ge 1 ] && [ "$rep" -le "$#" ]; then
            ANSWER="$rep"; return
        fi
    done
}

human_size() { # Ko → lisible
    local kb="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B --format="%.1f" "$((kb * 1024))" 2>/dev/null || echo "${kb}K"
    else
        echo "${kb}K"
    fi
}

# ---------------------------------------------------------------------------
# 3. Encodage / décodage des chemins de sessions
#    Claude Code indexe les sessions sur le chemin absolu avec '/'→'-'
#    (ex. /home/x/projet → -home-x-projet).
# ---------------------------------------------------------------------------
encode_path() { printf '%s' "$1" | sed 's|/|-|g'; }

decode_path() { # nom encodé → chemin local ("" si introuvable / python3 absent)
    local enc="$1"
    command -v python3 >/dev/null 2>&1 || return 0
    # Les segments peuvent contenir '-' (ex. MY-PROJECTS) : on reconstitue par
    # parcours en profondeur en vérifiant l'existence réelle des dossiers.
    python3 - "$enc" <<'PY' 2>/dev/null
import os, sys
enc = sys.argv[1].lstrip('-')
segs = enc.split('-')
def dfs(i, path):
    if i == len(segs):
        return path
    for k in range(len(segs) - i, 0, -1):
        cand = path + '/' + '-'.join(segs[i:i+k])
        if os.path.isdir(cand):
            r = dfs(i + k, cand)
            if r:
                return r
    return None
print(dfs(0, '') or '')
PY
}

# ---------------------------------------------------------------------------
# 4. Profils de serveurs (~/.config/claude-migrate/servers.conf)
# ---------------------------------------------------------------------------
declare -A PROF_HOST PROF_USER PROF_PORT PROF_DESTROOT PROF_CONFDIR PROF_NAMES
PROFILE_COUNT=0

load_profiles() {
    [ -f "$SERVERS_CONF" ] || return 0
    local name="" line key val
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            name="${BASH_REMATCH[1]}"
            PROFILE_COUNT=$((PROFILE_COUNT + 1))
            PROF_NAMES[$PROFILE_COUNT]="$name"
            continue
        fi
        [[ "$name" != "" && "$line" == *=* ]] || continue
        key="${line%%=*}"; val="${line#*=}"
        case "$key" in
            host)       PROF_HOST[$name]="$val" ;;
            user)       PROF_USER[$name]="$val" ;;
            port)       PROF_PORT[$name]="$val" ;;
            dest_root)  PROF_DESTROOT[$name]="$val" ;;
            config_dir) PROF_CONFDIR[$name]="$val" ;;
        esac
    done < "$SERVERS_CONF"
}

save_profile() { # save_profile "nom" — remplace la section existante
    local name="$1" tmp
    tmp="$SERVERS_CONF.tmp"
    awk -v sec="[$name]" '
        /^\[/ { skip = ($0 == sec) ? 1 : 0 }
        { if (!skip) print }
    ' "$SERVERS_CONF" 2>/dev/null > "$tmp"
    mv "$tmp" "$SERVERS_CONF"
    {
        printf '[%s]\n' "$name"
        printf 'host=%s\n'       "${PROFILE_HOST:-}"
        printf 'user=%s\n'       "${PROFILE_USER:-}"
        [ -n "${PROFILE_PORT:-}" ] && printf 'port=%s\n' "$PROFILE_PORT"
        [ -n "${PROFILE_DESTROOT:-}" ] && printf 'dest_root=%s\n' "$PROFILE_DESTROOT"
        [ -n "${PROFILE_CONFDIR:-}" ] && printf 'config_dir=%s\n' "$PROFILE_CONFDIR"
        printf '\n'
    } >> "$SERVERS_CONF"
    log "    Profil « $name » enregistré dans $SERVERS_CONF"
}

load_profiles

# ---------------------------------------------------------------------------
# 5. Connexion ssh
# ---------------------------------------------------------------------------
SSH_TARGET=""      # user@host ou alias
SSH_PORT=""
USE_SSHPASS=0
SSH_COMMON=(-o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
SSH_PORT_ARGS=()

rsh() { # commande distante, sortie capturée par l'appelant
    # -n : stdin depuis /dev/null, sinon ssh avale les réponses du menu interactif
    if [ "$USE_SSHPASS" -eq 1 ]; then
        sshpass -e ssh -n "${SSH_COMMON[@]}" "${SSH_PORT_ARGS[@]}" "$SSH_TARGET" "$@"
    else
        ssh -n "${SSH_COMMON[@]}" "${SSH_PORT_ARGS[@]}" "$SSH_TARGET" "$@"
    fi
}

rsh_tty() { # commande distante avec terminal alloué (prompts sudo/mot de passe)
    if [ "$USE_SSHPASS" -eq 1 ]; then
        sshpass -e ssh -tt "${SSH_COMMON[@]}" "${SSH_PORT_ARGS[@]}" "$SSH_TARGET" "$@"
    else
        ssh -tt "${SSH_COMMON[@]}" "${SSH_PORT_ARGS[@]}" "$SSH_TARGET" "$@"
    fi
}

rsh_script() { # script exécuté via bash -l distant, lu sur stdin
    if [ "$USE_SSHPASS" -eq 1 ]; then
        sshpass -e ssh "${SSH_COMMON[@]}" "${SSH_PORT_ARGS[@]}" "$SSH_TARGET" 'bash -l'
    else
        ssh "${SSH_COMMON[@]}" "${SSH_PORT_ARGS[@]}" "$SSH_TARGET" 'bash -l'
    fi
}

rsync_remote_shell() { # construction de -e pour rsync
    # PAS de -n ici : rsync passe son protocole par stdin/stdout du ssh enfant.
    # (rsync alimente lui-même ce stdin via un tuyau, il ne touche pas le nôtre.)
    local e="ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"
    [ -n "$SSH_PORT" ] && e="$e -p $SSH_PORT"
    [ "$USE_SSHPASS" -eq 1 ] && e="sshpass -e $e"
    printf '%s' "$e"
}

ssh_key_works() { # test d'authentification sans mot de passe
    if [ "$USE_SSHPASS" -eq 1 ]; then
        sshpass -e ssh -n -o BatchMode=yes -o ConnectTimeout=15 \
            -o StrictHostKeyChecking=accept-new "${SSH_PORT_ARGS[@]}" "$SSH_TARGET" true 2>/dev/null
    else
        ssh -n -o BatchMode=yes -o ConnectTimeout=15 \
            -o StrictHostKeyChecking=accept-new "${SSH_PORT_ARGS[@]}" "$SSH_TARGET" true 2>/dev/null
    fi
}

list_ssh_aliases() {
    [ -f "$HOME/.ssh/config" ] || return 0
    awk '/^[[:space:]]*Host[[:space:]]/ && !/[*?]/ {
             for (i = 2; i <= NF; i++) print $i
         }' "$HOME/.ssh/config" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 6. Inventaire des projets locaux (sessions des deux comptes)
# ---------------------------------------------------------------------------
CONFIG_ACCOUNTS=("$HOME/.claude" "perso" "$HOME/.claude-work" "pro")

declare -A ACC_ACCOUNTS ACC_COUNT ACC_SIZE ACC_MTIME

scan_projects() {
    local cfg label enc path dir cnt kb mtime
    local args=("$@")
    local i=0
    while [ $i -lt ${#args[@]} ]; do
        cfg="${args[$i]}"; label="${args[$((i+1))]}"
        i=$((i+2))
        [ -d "$cfg/projects" ] || continue
        for dir in "$cfg/projects"/*/; do
            [ -d "$dir" ] || continue
            enc="$(basename "$dir")"
            path="$(decode_path "$enc")"
            [ -n "$path" ] || continue
            cnt=$(ls "$dir"/*.jsonl 2>/dev/null | wc -l)
            kb=$(du -sk "$dir" 2>/dev/null | cut -f1); kb=${kb:-0}
            mtime=$(stat -c %Y "$dir" 2>/dev/null); mtime=${mtime:-0}
            case " ${ACC_ACCOUNTS[$path]:-} " in *" $label "*) ;; *) ACC_ACCOUNTS[$path]="${ACC_ACCOUNTS[$path]:-}${ACC_ACCOUNTS[$path]:+ }$label" ;; esac
            ACC_COUNT[$path]=$(( ${ACC_COUNT[$path]:-0} + cnt ))
            ACC_SIZE[$path]=$(( ${ACC_SIZE[$path]:-0} + kb ))
            [ "$mtime" -gt "${ACC_MTIME[$path]:-0}" ] && ACC_MTIME[$path]="$mtime"
        done
    done
}

# ---------------------------------------------------------------------------
# 7. Mode --list : inventaire puis sortie
# ---------------------------------------------------------------------------
if [ "$MODE_LIST" -eq 1 ]; then
    scan_projects "${CONFIG_ACCOUNTS[@]}"
    echo "Projets détectés (sessions présentes) :"
    if [ "${#ACC_MTIME[@]}" -eq 0 ]; then echo "  (aucun)"
    else
        for p in $(printf '%s\n' "${!ACC_MTIME[@]}" \
                  | while read -r k; do echo "${ACC_MTIME[$k]}|$k"; done \
                  | sort -t'|' -k1,1rn | cut -d'|' -f2-); do
            printf '  %-58s [%s] %2d session(s)  %s\n' \
                "$p" "${ACC_ACCOUNTS[$p]}" "${ACC_COUNT[$p]}" "$(human_size "${ACC_SIZE[$p]}")"
        done
    fi
    echo
    echo "Profils enregistrés :"
    if [ "$PROFILE_COUNT" -eq 0 ]; then echo "  (aucun)"
    else
        for i in $(seq 1 "$PROFILE_COUNT"); do
            n="${PROF_NAMES[$i]}"
            echo "  $n → ${PROF_USER[$n]:-?}@${PROF_HOST[$n]:-?}${PROF_PORT[$n]:+:${PROF_PORT[$n]}}"
        done
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# 8. Vérifications locales
# ---------------------------------------------------------------------------
step "Vérifications locales"

command -v rsync >/dev/null 2>&1 || die "rsync absent en local (sudo apt install rsync)"
command -v ssh   >/dev/null 2>&1 || die "ssh absent en local"
if command -v python3 >/dev/null 2>&1; then
    log "    OK : python3 (décodage des chemins de sessions)"
else
    log "    ATTENTION : python3 absent — seuls les chemins sans tiret ambigu seront détectés"
fi
[ "$DRY_RUN" -eq 1 ] && log "    MODE SIMULATION : rien ne sera écrit sur le serveur."
if [ "$ASSUME_DEFAULTS" -eq 1 ]; then
    log "    MODE NON-INTERACTIF : toutes les valeurs par défaut sont utilisées."
    [ -n "$OPT_PROJECT" ] || die "--yes exige --project <chemin>"
    [ -n "$OPT_SERVER" ] || die "--yes exige --server <cible|profil>"
fi

# ---------------------------------------------------------------------------
# 9. Choix du projet
# ---------------------------------------------------------------------------
step "Choix du projet"

if [ -n "$OPT_PROJECT" ]; then
    SRC_WORKDIR="$OPT_PROJECT"
    log "    Projet (option --project) : $SRC_WORKDIR"
    [ -d "$SRC_WORKDIR" ] || die "dossier introuvable : $SRC_WORKDIR"
else
    scan_projects "${CONFIG_ACCOUNTS[@]}"
    mapfile -t SORTED_PATHS < <(
        for k in "${!ACC_MTIME[@]}"; do echo "${ACC_MTIME[$k]}|$k"; done \
            | sort -t'|' -k1,1rn | cut -d'|' -f2-
    )
    MENU_OPTS=()
    for p in "${SORTED_PATHS[@]}"; do
        MENU_OPTS+=("$p  [${ACC_ACCOUNTS[$p]}]  ${ACC_COUNT[$p]} session(s)  $(human_size "${ACC_SIZE[$p]}")")
    done
    if [ "${#MENU_OPTS[@]}" -eq 0 ]; then
        [ "$ASSUME_DEFAULTS" -eq 1 ] && die "aucun projet détecté et --project absent"
        ask_value "Aucune session détectée — chemin du projet à migrer" "$PWD"
        SRC_WORKDIR="$ANSWER"
    else
        MENU_OPTS+=("Autre chemin (saisie manuelle)")
        log "    Projets détectés (triés par activité) :"
        menu_select "Quel projet migrer ?" "${MENU_OPTS[@]}"
        CHOICE="$ANSWER"
        if [ "$CHOICE" -lt "${#MENU_OPTS[@]}" ]; then
            SRC_WORKDIR="${SORTED_PATHS[$((CHOICE - 1))]}"
        else
            ask_value "Chemin du projet à migrer" "$PWD"
            SRC_WORKDIR="$ANSWER"
        fi
    fi
    [ -d "$SRC_WORKDIR" ] || die "dossier introuvable : $SRC_WORKDIR"
fi

SRC_WORKDIR="$(realpath "$SRC_WORKDIR" 2>/dev/null || echo "$SRC_WORKDIR")"
ENCODED_LOCAL="$(encode_path "$SRC_WORKDIR")"
log "    Projet           : $SRC_WORKDIR"
log "    Clé de sessions  : $ENCODED_LOCAL"

# Comptes ayant des sessions pour ce projet
SESSION_ACCOUNTS=()
i=0
while [ $i -lt ${#CONFIG_ACCOUNTS[@]} ]; do
    cfg="${CONFIG_ACCOUNTS[$i]}"; label="${CONFIG_ACCOUNTS[$((i+1))]}"
    # --account : claude (compte perso) | claude-work (compte pro) | both
    case "${OPT_ACCOUNT:-both}" in
        both)          FILTER="" ;;
        claude|perso)  FILTER="perso" ;;
        claude-work|pro) FILTER="pro" ;;
        *) die "--account : valeur invalide — utiliser claude, claude-work ou both" ;;
    esac
    if [ -n "$FILTER" ] && [ "$label" != "$FILTER" ]; then
        i=$((i+2)); continue
    fi
    if [ -d "$cfg/projects/$ENCODED_LOCAL" ]; then
        SESSION_ACCOUNTS+=("$cfg|$label")
    else
        log "    (aucune session [$label] pour ce projet)"
    fi
    i=$((i+2))
done

# ---------------------------------------------------------------------------
# 10. Dossier à copier et exclusions
# ---------------------------------------------------------------------------
step "Dossier à copier"

ask_value "Dossier à copier (Entrée = le projet ; indiquez le parent pour tout inclure)" "$SRC_WORKDIR"
SRC_COPYDIR="$ANSWER"
[ -d "$SRC_COPYDIR" ] || die "dossier à copier introuvable : $SRC_COPYDIR"
SRC_COPYDIR="$(realpath "$SRC_COPYDIR" 2>/dev/null || echo "$SRC_COPYDIR")"
log "    Dossier à copier : $SRC_COPYDIR"

ask_value "Exclusions rsync supplémentaires (motifs séparés par espaces, ex. 'images/ *.zip')" ""
EXTRA_EXCLUDES_STR="$ANSWER"
read -r -a EXTRA_EXCLUDES <<< "$EXTRA_EXCLUDES_STR" || true

RSYNC_EXCLUDES=(
    --exclude 'node_modules/'
    --exclude 'dist/'
    --exclude 'build/'
    --exclude '.next/'
    --exclude '.venv/'
    --exclude 'venv/'
    --exclude '__pycache__/'
    --exclude '.pytest_cache/'
    --exclude 'target/'
    --exclude '*.log'
)
for x in "${EXTRA_EXCLUDES[@]:-}"; do
    [ -n "$x" ] && RSYNC_EXCLUDES+=(--exclude "$x")
done

# ---------------------------------------------------------------------------
# 11. Serveur : profil existant ou nouvelle cible
# ---------------------------------------------------------------------------
step "Choix du serveur"

PROFILE_NAME=""
PROFILE_HOST=""; PROFILE_USER=""; PROFILE_PORT=""; PROFILE_DESTROOT=""; PROFILE_CONFDIR=""

if [ -n "$OPT_SERVER" ] && [ -n "${PROF_HOST[$OPT_SERVER]:-}" ]; then
    PROFILE_NAME="$OPT_SERVER"
    OPT_SERVER=""
fi

if [ -n "$PROFILE_NAME" ]; then
    PROFILE_HOST="${PROF_HOST[$PROFILE_NAME]}"
    PROFILE_USER="${PROF_USER[$PROFILE_NAME]}"
    PROFILE_PORT="${PROF_PORT[$PROFILE_NAME]:-}"
    PROFILE_DESTROOT="${PROF_DESTROOT[$PROFILE_NAME]:-}"
    PROFILE_CONFDIR="${PROF_CONFDIR[$PROFILE_NAME]:-}"
    SSH_TARGET="${PROFILE_USER}@${PROFILE_HOST}"
    SSH_PORT="$PROFILE_PORT"
    log "    Profil « $PROFILE_NAME » : $SSH_TARGET${SSH_PORT:+:$SSH_PORT}"
elif [ -n "$OPT_SERVER" ]; then
    SSH_TARGET="$OPT_SERVER"
    if [[ "$SSH_TARGET" == *@*:* ]]; then
        SSH_PORT="${SSH_TARGET##*:}"
        SSH_TARGET="${SSH_TARGET%:*}"
    fi
    log "    Cible (option --server) : $SSH_TARGET${SSH_PORT:+:$SSH_PORT}"
else
    ALIASES=()
    while IFS= read -r a; do ALIASES+=("$a"); done < <(list_ssh_aliases)
    if [ "${#ALIASES[@]}" -gt 0 ]; then
        OPTS_MENU=("${ALIASES[@]}" "Saisie manuelle (user@host[:port])")
        menu_select "Quel serveur ?" "${OPTS_MENU[@]}"
        CHOICE="$ANSWER"
        if [ "$CHOICE" -lt "${#OPTS_MENU[@]}" ]; then
            SSH_TARGET="${ALIASES[$((CHOICE - 1))]}"
        else
            ask_value "Cible ssh (user@host, user@host:port ou alias)" ""
            SSH_TARGET="$ANSWER"
            [ -n "$SSH_TARGET" ] || die "aucune cible saisie"
        fi
    else
        ask_value "Cible ssh (user@host, user@host:port ou alias)" ""
        SSH_TARGET="$ANSWER"
        [ -n "$SSH_TARGET" ] || die "aucune cible saisie"
    fi
    if [[ "$SSH_TARGET" == *@*:* ]]; then
        SSH_PORT="${SSH_TARGET##*:}"
        SSH_TARGET="${SSH_TARGET%:*}"
    fi
fi
[ -n "$OPT_PORT" ] && SSH_PORT="$OPT_PORT"
[ -n "$SSH_PORT" ] && SSH_PORT_ARGS=(-p "$SSH_PORT")

# ---------------------------------------------------------------------------
# 12. Test de connexion + authentification (clé → ssh-copy-id → sshpass)
# ---------------------------------------------------------------------------
step "Connexion au serveur"

if ssh_key_works; then
    log "    OK : connexion par clé établie ($SSH_TARGET${SSH_PORT:+:$SSH_PORT})"
else
    log "    Échec d'authentification par clé sur $SSH_TARGET."
    [ "$ASSUME_DEFAULTS" -eq 1 ] && die "mode non-interactif : relancez sans --yes pour configurer le mot de passe"
    if confirm "Installer votre clé publique sur le serveur (ssh-copy-id, mot de passe demandé une seule fois) ?" "o"; then
        if ! ls "$HOME"/.ssh/id_*.pub >/dev/null 2>&1; then
            confirm "Aucune clé publique locale — en générer une (ed25519, sans phrase secrète) ?" "o" \
                || die "aucune clé publique à installer"
            ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "$USER@$(hostname) migrate" \
                || die "ssh-keygen a échoué"
        fi
        log "    -> ssh-copy-id (tapez le mot de passe du serveur)"
        # sortie directe sur le terminal : le prompt du mot de passe doit être visible
        if ssh-copy-id -o StrictHostKeyChecking=accept-new ${SSH_PORT:+-p "$SSH_PORT"} "$SSH_TARGET"; then
            log "    OK : clé installée"
        else
            log "    ssh-copy-id a échoué (le serveur refuse peut-être l'authentification par clé)"
        fi
    fi
    if ssh_key_works; then
        log "    OK : connexion par clé établie"
    elif confirm "Continuer avec sshpass (le mot de passe sera utilisé pour chaque commande) ?" "o"; then
        command -v sshpass >/dev/null 2>&1 || {
            confirm "sshpass absent en local — l'installer (sudo apt install sshpass) ?" "o" \
                || die "sshpass requis pour la connexion par mot de passe"
            sudo apt-get install -y sshpass || die "installation de sshpass impossible"
        }
        printf 'Mot de passe ssh pour %s : ' "$SSH_TARGET" >&2
        read -rs SSHPASS_INPUT || die "entrée standard fermée"
        printf '\n' >&2
        export SSHPASS="$SSHPASS_INPUT"
        unset SSHPASS_INPUT
        USE_SSHPASS=1
        rsh true || die "mot de passe refusé pour $SSH_TARGET"
        log "    OK : connexion par mot de passe établie (sshpass)"
        log "    NOTE : pour un usage durable, installez plutôt votre clé (ssh-copy-id)."
    else
        die "aucune méthode de connexion disponible pour $SSH_TARGET"
    fi
fi

RHOME="$(rsh 'printf %s "$HOME"' | tr -d '\r\n')"
[ -n "$RHOME" ] || die "impossible de déterminer le home distant"
log "    Home distant      : $RHOME"

# ---------------------------------------------------------------------------
# 13. Dossiers de destination
# ---------------------------------------------------------------------------
step "Dossiers de destination"

DEFAULT_DST_ROOT="${PROFILE_DESTROOT:-}"
DEFAULT_DST_ROOT="${DEFAULT_DST_ROOT:-${OPT_DEST_ROOT:-~/projets}}"
ask_value "Racine des projets sur le serveur" "$DEFAULT_DST_ROOT"
DST_ROOT="$ANSWER"
DST_ROOT="${DST_ROOT/#\~/$RHOME}"
DST_ROOT="${DST_ROOT%/}"
DST_ROOT="${DST_ROOT//\/\//\//}"

ask_value "Nom du dossier projet" "$(basename "$SRC_COPYDIR")"
DST_NAME="$ANSWER"

DST_PROJECT="$DST_ROOT/$DST_NAME"

ask_value "Dossier de travail distant (où sera lancé claude — clé des sessions)" "$DST_PROJECT"
DST_WORKDIR="$ANSWER"
DST_WORKDIR="${DST_WORKDIR/#\~/$RHOME}"

DEFAULT_DST_CONF="${PROFILE_CONFDIR:-~/.claude}"
ask_value "Dossier de configuration Claude sur le serveur" "$DEFAULT_DST_CONF"
DST_CONF="$ANSWER"
DST_CONF="${DST_CONF/#\~/$RHOME}"

ENCODED_VPS="$(encode_path "$DST_WORKDIR")"
log "    Projet distant     : $DST_PROJECT"
log "    Dossier de travail : $DST_WORKDIR"
log "    Sessions vers      : $DST_CONF/projects/$ENCODED_VPS"

if rsh "test -d '$DST_PROJECT'" 2>/dev/null; then
    confirm "Le dossier distant $DST_PROJECT existe déjà — y fusionner/mettre à jour par rsync ?" "o" \
        || die "annulé par l'utilisateur (dossier distant existant)"
fi

# ---------------------------------------------------------------------------
# 14. Outils présents sur le serveur
# ---------------------------------------------------------------------------
step "Outils du serveur"

declare -A REMOTE_TOOL=()
while IFS=':' read -r tool state; do
    [ -n "$tool" ] && { [ "$tool" = "pkg" ] && PKG_MGR="$state" || REMOTE_TOOL["$tool"]="$state"; }
done < <(rsh_script <<'REMOTE'
for t in rsync tmux mosh git node npm claude supabase deno python3; do
    if command -v "$t" >/dev/null 2>&1; then echo "$t:ok"; else echo "$t:missing"; fi
done
if [ -x /usr/bin/apt-get ]; then echo "pkg:apt"
elif [ -x /usr/bin/dnf ]; then echo "pkg:dnf"
elif [ -x /usr/bin/pacman ]; then echo "pkg:pacman"
else echo "pkg:none"; fi
REMOTE
)
PKG_MGR="${PKG_MGR:-none}"

MISSING=()
for t in rsync tmux mosh git node npm claude supabase deno; do
    [ "${REMOTE_TOOL[$t]:-missing}" = "ok" ] || MISSING+=("$t")
done
log "    Absents : ${MISSING[*]:-aucun}"
log "    Gestionnaire de paquets : $PKG_MGR"

WANT_TOOLS=()
for t in rsync tmux mosh; do
    [ "${REMOTE_TOOL[$t]:-missing}" = "ok" ] || WANT_TOOLS+=("$t")
done
if [ -d "$SRC_COPYDIR/.git" ] && [ "${REMOTE_TOOL[git]:-missing}" != "ok" ]; then
    WANT_TOOLS+=(git)
fi

if [ "${#WANT_TOOLS[@]}" -gt 0 ]; then
    log "    Outils systèmes à installer : ${WANT_TOOLS[*]}"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "    [SIMULATION] seraient installés via $PKG_MGR : ${WANT_TOOLS[*]}"
    elif [ "$PKG_MGR" = "none" ]; then
        log "    ATTENTION : aucun gestionnaire de paquets connu sur le serveur."
        log "    À installer manuellement : ${WANT_TOOLS[*]}"
        case " ${WANT_TOOLS[*]} " in *" rsync "*) die "rsync est indispensable côté serveur pour le transfert" ;; esac
    elif confirm "Installer ${WANT_TOOLS[*]} sur le serveur (via $PKG_MGR, sudo) ?" "o"; then
        case "$PKG_MGR" in
            apt)    INSTALL_CMD="apt-get update -qq && apt-get install -y ${WANT_TOOLS[*]}" ;;
            dnf)    INSTALL_CMD="dnf install -y ${WANT_TOOLS[*]}" ;;
            pacman) INSTALL_CMD="pacman -S --noconfirm ${WANT_TOOLS[*]}" ;;
        esac
        SUDO_NONINTER="$(rsh 'sudo -n true 2>/dev/null && echo oui || echo non')"
        if [ "$SUDO_NONINTER" = "oui" ]; then
            run "Installation de ${WANT_TOOLS[*]} (sudo sans mot de passe)" \
                rsh "sudo -n bash -c '$INSTALL_CMD'"
        else
            # sortie directe sur le terminal : le prompt sudo doit être visible
            log "    -> installation (le mot de passe sudo du serveur peut être demandé)"
            if rsh_tty "sudo bash -c '$INSTALL_CMD'"; then
                log "    OK : ${WANT_TOOLS[*]} installés"
            else
                log "    ERREUR : installation impossible"
                case " ${WANT_TOOLS[*]} " in *" rsync "*)
                    die "rsync est indispensable côté serveur pour le transfert" ;; esac
                FAILED_STEPS+=("installation ${WANT_TOOLS[*]}")
            fi
        fi
        for t in "${WANT_TOOLS[@]}"; do
            if rsh "command -v $t >/dev/null 2>&1"; then REMOTE_TOOL["$t"]="ok"; fi
        done
    else
        case " ${WANT_TOOLS[*]} " in *" rsync "*) die "rsync est indispensable côté serveur pour le transfert" ;; esac
    fi
fi

# node/npm manquants et projet node → installation user-space (sans sudo)
if [ "${REMOTE_TOOL[node]:-missing}" != "ok" ] && [ -f "$SRC_COPYDIR/package.json" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        log "    [SIMULATION] node serait installé en user-space (~/.local/node)"
    elif confirm "node absent du serveur — l'installer en user-space (tarball officiel nodejs.org, sans sudo) ?" "o"; then
        NODE_VER="$(curl -fsSL https://nodejs.org/dist/index.json | python3 -c '
import json, sys
try:
    print(next(n["version"] for n in json.load(sys.stdin) if n.get("lts")))
except Exception:
    pass')"
        [ -n "$NODE_VER" ] || die "impossible de déterminer la dernière version LTS de node"
        RARCH="$(rsh 'uname -m' | tr -d '\r\n')"
        case "$RARCH" in
            x86_64)  RARCH="x64" ;;
            aarch64) RARCH="arm64" ;;
            *) die "architecture serveur non gérée pour l'installation de node : $RARCH" ;;
        esac
        run "Téléchargement de node $NODE_VER ($RARCH) sur le serveur" \
            rsh "curl -fsSL -o /tmp/node.tar.xz https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-linux-$RARCH.tar.xz"
        run "Extraction vers ~/.local/node" \
            rsh "mkdir -p \$HOME/.local/node && tar -xJf /tmp/node.tar.xz --strip-components=1 -C \$HOME/.local/node && rm -f /tmp/node.tar.xz"
        run "Liens binaires node/npm/npx/corepack dans ~/.local/bin" \
            rsh "mkdir -p \$HOME/.local/bin && for b in node npm npx corepack; do ln -sfn \$HOME/.local/node/bin/\$b \$HOME/.local/bin/\$b; done"
        REMOTE_TOOL[node]=ok; REMOTE_TOOL[npm]=ok
    fi
fi

# Claude Code manquant → proposition d'installation (le login reste manuel)
if [ "${REMOTE_TOOL[claude]:-missing}" != "ok" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        log "    [SIMULATION] Claude Code absent — son installation serait proposée"
    elif confirm "Claude Code absent du serveur — l'installer via npm (@anthropic-ai/claude-code) ?" "o"; then
        [ "${REMOTE_TOOL[npm]:-missing}" = "ok" ] \
            || die "node/npm requis pour installer Claude Code — installez d'abord node"
        run "npm install -g @anthropic-ai/claude-code" \
            rsh "bash -lc 'npm install -g --prefix \$HOME/.local/node @anthropic-ai/claude-code'"
        run "Lien du binaire claude dans ~/.local/bin" \
            rsh "ln -sfn \$HOME/.local/node/bin/claude \$HOME/.local/bin/claude"
        REMOTE_TOOL[claude]=ok
        log "    NOTE : le login Claude restera à faire sur le serveur (jamais copié)."
    fi
fi

# CLI Supabase manquant et projet supabase → proposition
if [ "${REMOTE_TOOL[supabase]:-missing}" != "ok" ] && [ -d "$SRC_COPYDIR/supabase" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        log "    [SIMULATION] CLI Supabase serait installé (npm) et lié dans ~/.local/bin"
    elif confirm "Projet Supabase détecté et CLI absent — installer supabase via npm ?" "o"; then
        if [ "${REMOTE_TOOL[npm]:-missing}" = "ok" ]; then
            run "npm install -g supabase" \
                rsh "bash -lc 'npm install -g --prefix \$HOME/.local/node supabase'"
            run "Lien du binaire supabase dans ~/.local/bin" \
                rsh "ln -sfn \$HOME/.local/node/bin/supabase \$HOME/.local/bin/supabase"
            REMOTE_TOOL[supabase]=ok
            log "    NOTE : supabase login restera à faire sur le serveur (jeton jamais copié)."
        else
            log "    ATTENTION : node absent — CLI Supabase non installé."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 15. Config globale à migrer (agents / commandes / skills / settings)
# ---------------------------------------------------------------------------
step "Configuration Claude globale (agents, commandes, skills)"

DO_GLOBALS=1
if [ "$OPT_GLOBALS" = "non" ]; then
    DO_GLOBALS=0
    log "    Désactivé (--no-globals)."
elif [ "$OPT_GLOBALS" = "" ]; then
    if confirm "Copier aussi agents/commandes/skills et settings (sans rien écraser) ?" "o"; then
        DO_GLOBALS=1
    else
        DO_GLOBALS=0
    fi
fi

# ---------------------------------------------------------------------------
# 16. Récapitulatif avant transfert
# ---------------------------------------------------------------------------
step "Récapitulatif"

SIZE_KB=$(du -sk "${RSYNC_EXCLUDES[@]}" "$SRC_COPYDIR" 2>/dev/null | cut -f1)
SIZE_KB=${SIZE_KB:-0}
log "    Source          : $SRC_COPYDIR"
log "      taille estimée : $(human_size "$SIZE_KB") (hors exclusions)"
log "    Destination     : $SSH_TARGET:$DST_PROJECT"
log "    Sessions        : $(for e in "${SESSION_ACCOUNTS[@]:-}"; do echo -n "${e#*|} "; done) → $DST_CONF/projects/$ENCODED_VPS"
log "    Config globale  : $([ "$DO_GLOBALS" -eq 1 ] && echo oui || echo non)"
log "    Exclusions      : $(printf '%s\n' "${RSYNC_EXCLUDES[@]}" | sed "s/--exclude //g" | tr '\n' ' ')"

# fichiers sensibles (env, clés) — ils SERONT transférés (nécessaires au projet)
SENSITIVE="$(find "$SRC_COPYDIR" -maxdepth 2 \( -name '.env*' -o -name '*.pem' -o -name 'credentials*' \) \
            -not -path '*/node_modules/*' 2>/dev/null | head -n 10)"
if [ -n "$SENSITIVE" ]; then
    log "    Fichiers sensibles détectés (ils seront transférés — nécessaires au projet) :"
    echo "$SENSITIVE" | tee -a "$LOGFILE" | sed 's/^/      /'
fi

confirm "Lancer la migration ?" "o" || die "annulé par l'utilisateur"

# ---------------------------------------------------------------------------
# 17. Transferts
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
    run "Création des dossiers distants" \
        rsh "mkdir -p '$DST_PROJECT' '$DST_CONF/projects/$ENCODED_VPS'"
fi

RSYNC_E="$(rsync_remote_shell)"
RSYNC_N=(); [ "$DRY_RUN" -eq 1 ] && RSYNC_N=(-n)
RSYNC_FLAGS_CODE=("${RSYNC_N[@]}" -avz --progress -e "$RSYNC_E" "${RSYNC_EXCLUDES[@]}")
RSYNC_FLAGS_GLOB=("${RSYNC_N[@]}" -avz -e "$RSYNC_E")

step "1/3 - Code du projet"
run "rsync du code" rsync "${RSYNC_FLAGS_CODE[@]}" "$SRC_COPYDIR/" "$SSH_TARGET:$DST_PROJECT/"

step "2/3 - Sessions de conversation"
if [ "${#SESSION_ACCOUNTS[@]}" -eq 0 ]; then
    log "    Aucune session à transférer."
fi
for entry in "${SESSION_ACCOUNTS[@]}"; do
    cfg="${entry%%|*}"; label="${entry#*|}"
    src="$cfg/projects/$ENCODED_LOCAL"
    [ -d "$src" ] || continue
    cnt=$(ls "$src"/*.jsonl 2>/dev/null | wc -l)
    # pas de --delete : on ajoute aux sessions déjà présentes (UUID uniques)
    run "rsync des sessions [$label] ($cnt conversation(s))" \
        rsync "${RSYNC_FLAGS_CODE[@]}" "$src/" "$SSH_TARGET:$DST_CONF/projects/$ENCODED_VPS/"
done

step "3/3 - Configuration Claude globale"
if [ "$DO_GLOBALS" -eq 1 ]; then
    # pro d'abord (prioritaire si doublon), perso ensuite (complète les skills)
    for pair in "$HOME/.claude-work|pro" "$HOME/.claude|perso"; do
        cfg="${pair%%|*}"; label="${pair#*|}"
        for sub in agents commands skills; do
            [ -d "$cfg/$sub" ] || continue
            run "rsync $sub [$label] (--ignore-existing)" \
                rsync "${RSYNC_FLAGS_GLOB[@]}" --ignore-existing \
                "$cfg/$sub/" "$SSH_TARGET:$DST_CONF/$sub/"
        done
        for f in settings.json CLAUDE.md; do
            [ -f "$cfg/$f" ] || continue
            run "rsync $f [$label] (--ignore-existing)" \
                rsync "${RSYNC_FLAGS_GLOB[@]}" --ignore-existing \
                "$cfg/$f" "$SSH_TARGET:$DST_CONF/$f"
        done
    done
    log "    NOTE : .credentials.json et .claude.json ne sont jamais copiés."
else
    log "    Sauté (choix utilisateur)."
fi

# ---------------------------------------------------------------------------
# 18. Dépendances du projet sur le serveur
# ---------------------------------------------------------------------------
step "Installation des dépendances du projet"

if [ "$DRY_RUN" -eq 1 ]; then
    log "    [SIMULATION] les dépendances (npm/pip) seraient installées dans $DST_PROJECT"
else
    if rsh "test -f '$DST_PROJECT/package.json'"; then
        run "npm ci (repli npm install) à la racine" \
            rsh "bash -lc 'cd $DST_PROJECT && (npm ci || npm install)'"
    fi
    # un niveau de sous-dossiers avec package.json (ex. layout mon-app/project)
    run "npm ci des sous-dossiers node" \
        rsh "bash -lc 'cd $DST_PROJECT && for s in */package.json; do [ -f \"\$s\" ] || continue; d=\${s%/package.json}; echo \"--> deps : \$d\"; (cd \"\$d\" && (npm ci || npm install)); done'"
    if rsh "test -f '$DST_PROJECT/requirements.txt'"; then
        run "pip install -r requirements.txt (--user)" \
            rsh "bash -lc 'cd $DST_PROJECT && python3 -m pip install --user -r requirements.txt'" \
            || log "    NOTE : pip a échoué — installez les dépendances python manuellement."
    fi
fi

# ---------------------------------------------------------------------------
# 19. Vérification post-migration
# ---------------------------------------------------------------------------
step "Vérification post-migration"
if [ "$DRY_RUN" -eq 1 ]; then
    log "    [SIMULATION] vérification ignorée."
else
    rsh_script <<REMOTE 2>&1 | tee -a "$LOGFILE" | sed 's/^/    /'
echo "code           : \$(test -d "$DST_PROJECT" && echo présent || echo MANQUANT)"
echo ".git           : \$(test -d "$DST_PROJECT/.git" && echo oui || echo non)"
echo "sessions       : \$(ls "$DST_CONF/projects/$ENCODED_VPS"/*.jsonl 2>/dev/null | wc -l) conversation(s)"
echo "skills         : \$(ls "$DST_CONF/skills" 2>/dev/null | wc -l)"
echo "agents         : \$(ls "$DST_CONF/agents" 2>/dev/null | wc -l)"
for t in rsync tmux mosh git node npm claude supabase; do
    echo "\$t : \$(command -v \$t >/dev/null 2>&1 && echo OK || echo absent)"
done
echo "git HEAD       : \$(cd "$DST_PROJECT" 2>/dev/null && git log --oneline -1 2>/dev/null || echo INDISPONIBLE)"
REMOTE
fi

# ---------------------------------------------------------------------------
# 20. Mémorisation du serveur
# ---------------------------------------------------------------------------
step "Mémorisation du serveur"
if [ "$DRY_RUN" -eq 1 ]; then
    log "    [SIMULATION] profil non enregistré."
elif confirm "Mémoriser ce serveur comme profil réutilisable ?" "o"; then
    PROFILE_HOST="${SSH_TARGET##*@}"
    PROFILE_USER="${SSH_TARGET%%@*}"
    [ "$PROFILE_USER" = "$SSH_TARGET" ] && PROFILE_USER="$USER"
    PROFILE_PORT="$SSH_PORT"
    PROFILE_DESTROOT="~$(printf '%s' "$DST_ROOT" | sed "s|^$RHOME||")"
    PROFILE_CONFDIR="~$(printf '%s' "$DST_CONF" | sed "s|^$RHOME||")"
    DEFAULT_NAME="${PROFILE_HOST%%.*}"
    [ -n "$PROFILE_NAME" ] && DEFAULT_NAME="$PROFILE_NAME"
    ask_value "Nom du profil" "$DEFAULT_NAME"
    PROFILE_NAME_SAVED="$ANSWER"
    save_profile "$PROFILE_NAME_SAVED"
fi

# ---------------------------------------------------------------------------
# 21. Prochaines étapes
# ---------------------------------------------------------------------------
step "Prochaines étapes"
if [ "${REMOTE_TOOL[mosh]:-missing}" = "ok" ]; then
    log "    Connexion quotidienne (survit aux coupures réseau) :"
    log "        mosh $SSH_TARGET"
else
    log "    Connexion :"
    log "        ssh $SSH_TARGET"
fi
if [ "${REMOTE_TOOL[tmux]:-missing}" = "ok" ]; then
    log "    Session tmux persistante :"
    log "        tmux new -s $(basename "$DST_PROJECT")    # ou : tmux attach -t $(basename "$DST_PROJECT")"
fi
log "    Reprendre le travail :"
log "        cd $DST_WORKDIR && claude --resume"

# port de dev détecté pour tailscale serve
DEV_PORT=""
if ls "$SRC_COPYDIR"/vite.config.* >/dev/null 2>&1; then DEV_PORT=5173
elif ls "$SRC_COPYDIR"/next.config.* >/dev/null 2>&1; then DEV_PORT=3000; fi
if [ -n "$DEV_PORT" ]; then
    log "    Serveur de dev visible depuis ce PC (si le serveur est sur Tailscale) :"
    log "        cd $DST_WORKDIR && npm run dev"
    log "        tailscale serve --bg $DEV_PORT    (à lancer sur le serveur)"
fi

# ---------------------------------------------------------------------------
# 22. Résumé
# ---------------------------------------------------------------------------
step "Résumé"
if [ ${#FAILED_STEPS[@]} -eq 0 ]; then
    log "    Tout s'est déroulé sans erreur."
else
    log "    ${#FAILED_STEPS[@]} étape(s) en erreur :"
    for f in "${FAILED_STEPS[@]}"; do log "      - $f"; done
fi
log "    Journal complet : $LOGFILE"
[ "$DRY_RUN" -eq 1 ] && log "    Rappel : SIMULATION — relancez sans --dry-run pour exécuter."
exit 0