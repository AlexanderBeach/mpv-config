#!/bin/sh
# Installs the mpv config from the config folder next to this script, on Linux, BSD and macOS.
# POSIX sh with options that GNU and BSD tools share, because macOS has bash 3.2 and BSD sed, awk and grep.
# "sh install.sh --help" lists the options.

set -u
LC_ALL=C
export LC_ALL

MIN_MPV_MINOR=39    # autocreate-playlist in mpv.conf needs mpv 0.39
FLATPAK_ID=io.mpv.Mpv
MACOS_BUNDLE_ID=io.mpv

# Downloads are checked against pinned SHA-256 checksums, yt-dlp against the SHA2-256SUMS of its release.
FIRAGO_URL=https://raw.githubusercontent.com/bBoxType/FiraGO/master/Fonts/FiraGO_TTF_1001
ATKINSON_URL=https://raw.githubusercontent.com/google/fonts/1b22086d13bdbbf5ec63d01a39a49246e4ac355f/ofl/atkinsonhyperlegible
YTDLP_URL=https://github.com/yt-dlp/yt-dlp/releases/latest/download

# Types that get mpv as their default app: MIME types for xdg-mime, type identifiers for duti.
LINUX_TYPES="video/mp4 video/x-matroska video/webm video/x-msvideo video/quicktime video/mpeg video/x-flv
video/ogg video/mp2t video/3gpp video/x-ms-wmv video/x-m4v audio/mpeg audio/flac audio/x-flac audio/ogg
audio/mp4 audio/x-wav audio/aac audio/opus audio/x-opus+ogg audio/x-vorbis+ogg audio/x-matroska audio/webm audio/x-ms-wma"
MACOS_TYPES="public.movie public.audio public.mpeg-4 com.apple.quicktime-movie public.avi
org.matroska.mkv org.webmproject.webm public.mp3 org.xiph.flac com.apple.m4a-audio"

# Choices. GIVEN lists the ones an option set, which are not asked about.
ASK=1 FORCE_ASK=0 UNINSTALL=0 GIVEN='' CONFIG_DIR_ARG=''
PRESET=high SUB_LANGS=eng,en AUDIO_LANGS='' WITHOUT='' FONT=firago
DO_FONTS=1 DO_WEB=1 DO_PLAYER=0
PROBLEMS=0 STAGE_DIR='' WORK_DIR=''

# Messages
say() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage_error() { printf 'Error: %s\nRun "sh install.sh --help" to see the options.\n' "$1" >&2; exit 2; }
# An optional step that failed. The install goes on and the exit status says so at the end.
problem() { warn "$*"; PROBLEMS=$((PROBLEMS + 1)); }
have() { command -v "$1" >/dev/null 2>&1; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# True when word $2 is in the space separated list $1.
in_list() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

usage() {
    cat <<EOF
Usage: sh install.sh [options]

Installs this mpv config. In a terminal it asks a few questions and shows a summary first.
An existing mpv config folder is moved to a backup folder, which is never deleted.

  -y, --yes                 Ask nothing. Use the defaults and the options below.
  -i, --interactive         Ask even when the input is not a terminal.
      --config-dir DIR      Install into DIR instead of the standard mpv config folder.
      --preset NAME         Picture quality: ultra, high or light. Default: high.
      --sub-langs LIST      Subtitle languages in order of preference, such as eng,en or
                            pt-BR,pt. Use "" for none. Default: eng,en.
      --audio-langs LIST    Audio languages in order of preference. Default: none.
      --without LIST        Leave out features, comma separated: thumbnails, effects, substyle,
                            resume, modernz. Without modernz, mpv's own controller is used.
      --font KEY            Subtitle font: firago (default), atkinson, or an installed system font:
                            noto, dejavu, liberation, cantarell (Linux), helvetica, avenir, lucida (macOS).
      --fonts, --no-fonts   Download the chosen font when it is missing. Default: yes.
      --web-videos, --no-web-videos
                            Install yt-dlp in the config folder when it is not on PATH. Default: yes.
      --default-player, --no-default-player
                            Make mpv the default app for video and audio files. Default: no.
      --uninstall           Remove what was installed and restore the backup.
  -h, --help                Show this text.

The mpv found on PATH is configured, otherwise the Flatpak, Snap or macOS app one. Use --config-dir
for another. Exit status: 0 success, 1 error (nothing is left half installed), 2 mistake in the
options, 3 installed but an optional step failed.
EOF
}

# Options
strip_spaces() { printf '%s' "$1" | tr -d ' \t\r\n'; }

is_language_list() {
    printf '%s\n' "$1" | grep -Eq '^[A-Za-z]+(-[A-Za-z0-9]+)*(,[A-Za-z]+(-[A-Za-z0-9]+)*)*$'
}

# set_option OPTION VALUE
set_option() {
    GIVEN="$GIVEN ${1#--}"
    case $1 in
        --config-dir)
            [ -n "$2" ] || usage_error "The --config-dir option needs a folder, but got an empty value."
            CONFIG_DIR_ARG=$2
            ;;
        --preset)
            PRESET=$(lower "$2")
            in_list "ultra high light" "$PRESET" || usage_error "The preset can be 'ultra', 'high' or 'light', but got '$2'."
            ;;
        --sub-langs|--audio-langs)
            RESULT=$(strip_spaces "$2")
            if [ -n "$RESULT" ] && ! is_language_list "$RESULT"; then
                usage_error "The $1 option takes language codes such as eng, en, pt-BR or zh-Hans separated by commas, but got '$2'."
            fi
            if [ "$1" = --sub-langs ]; then SUB_LANGS=$RESULT; else AUDIO_LANGS=$RESULT; fi
            ;;
        --without)
            RESULT=$(strip_spaces "$2")
            printf '%s\n' "$RESULT" | grep -Eq '^((thumbnails|effects|substyle|resume|modernz)(,(thumbnails|effects|substyle|resume|modernz))*)?$' ||
                usage_error "The features to leave out can be 'thumbnails', 'effects', 'substyle', 'resume' or 'modernz', separated by commas, but got '$2'."
            WITHOUT=$(printf '%s' "$RESULT" | tr ',' ' ')
            ;;
        --font) FONT=$(lower "$2") ;;
    esac
}

parse_arguments() {
    while [ $# -gt 0 ]; do
        case $1 in
            --*=*) _arg=$1; shift; set -- "${_arg%%=*}" "${_arg#*=}" "$@" ;;
        esac
        case $1 in
            -h|--help) usage; exit 0 ;;
            -y|--yes) ASK=0 ;;
            -i|--interactive) FORCE_ASK=1 ;;
            --uninstall) UNINSTALL=1 ;;
            --fonts) DO_FONTS=1 ;;
            --no-fonts) DO_FONTS=0 ;;
            --web-videos) DO_WEB=1; GIVEN="$GIVEN web" ;;
            --no-web-videos) DO_WEB=0; GIVEN="$GIVEN web" ;;
            --default-player) DO_PLAYER=1; GIVEN="$GIVEN player" ;;
            --no-default-player) DO_PLAYER=0; GIVEN="$GIVEN player" ;;
            --config-dir|--preset|--sub-langs|--audio-langs|--without|--font)
                [ $# -ge 2 ] || usage_error "The $1 option needs a value, but got none."
                set_option "$1" "$2"
                shift
                ;;
            *) usage_error "The options are listed by --help, but got '$1'." ;;
        esac
        shift
    done
    if [ "$ASK" -eq 1 ] && [ "$FORCE_ASK" -eq 0 ] && [ ! -t 0 ]; then
        usage_error "The installer asks questions and needs a terminal, but the input is not one. Run it in a terminal, or add --yes to use the defaults."
    fi
}

# Files and folders
detect_system() {
    OS_KIND=$(uname -s)
    ARCH=$(uname -m)
    case $OS_KIND in
        MINGW*|MSYS*|CYGWIN*) fail "This installer is for Linux, BSD and macOS. On Windows, run Install.cmd." ;;
    esac
    [ -d "${HOME:-}" ] || fail "The HOME variable must name your home folder, but got '${HOME:-}'."
    SOURCE_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)/config
    MANIFEST_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/mpv
    MANIFEST_FILE=$MANIFEST_DIR/install-manifest
}

# Stops before anything is moved or removed when $1 is a folder the installer must never replace.
check_config_dir() {
    case /$1/ in */../*) fail "The config folder must not contain '..' parts, but got '$1'." ;; esac
    _dir=$(cd "$1" 2>/dev/null && pwd -P) || _dir=$1
    case $_dir in
        /|"$(cd "$HOME" && pwd -P)") fail "The config folder must not be the root folder or your home folder, but got '$1'." ;;
    esac
    _msg="The config folder must not contain or be inside the config folder of this download, but got '$1'."
    case $_dir/ in "$SOURCE_DIR"/*) fail "$_msg" ;; esac
    case $SOURCE_DIR/ in "$_dir"/*) fail "$_msg" ;; esac
}

# True when CONFIG_DIR is a link or holds something, so it needs a backup.
has_config() { [ -L "$CONFIG_DIR" ] || [ -n "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]; }

# Creates the private folder for downloads and scratch files. The exit trap removes it.
make_work_directory() {
    [ -n "$WORK_DIR" ] || WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mpv-config-install.XXXXXX") ||
        fail "A temporary folder could not be created in '${TMPDIR:-/tmp}'. Check that it exists and is writable."
}

# shellcheck disable=SC2329
cleanup() {
    if [ -n "$STAGE_DIR" ]; then rm -rf "$STAGE_DIR"; fi
    if [ -n "$WORK_DIR" ]; then rm -rf "$WORK_DIR"; fi
}

# Questions

# Reads one line into ANSWER. The input ending is an error, so a closed pipe never means "yes".
read_answer() {
    IFS= read -r ANSWER || { say; fail "The input ended before every question was answered. Run the installer again, or add --yes to use the defaults."; }
    ANSWER=$(printf '%s' "$ANSWER" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
}

# ask_yes_no QUESTION DEFAULT: returns 0 for yes. DEFAULT is y or n.
ask_yes_no() {
    if [ "$2" = y ]; then _hint='[Y/n]'; else _hint='[y/N]'; fi
    while :; do
        printf '%s %s ' "$1" "$_hint"
        read_answer
        case $ANSWER in
            '') [ "$2" = y ]; return ;;
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
        esac
        say "The answer must be y or n, but got '$ANSWER'."
    done
}

# ask_choice PROMPT DEFAULT KEYS: puts the chosen key in RESULT. The answer is a key or its number in KEYS.
ask_choice() {
    while :; do
        printf '%s [%s]: ' "$1" "$2"
        read_answer
        ANSWER=$(lower "$ANSWER")
        if [ -z "$ANSWER" ]; then RESULT=$2; return 0; fi
        _n=0
        for _key in $3; do
            _n=$((_n + 1))
            if [ "$ANSWER" = "$_n" ] || [ "$ANSWER" = "$_key" ]; then RESULT=$_key; return 0; fi
        done
        say "The choice must be one of the numbers or names above, but got '$ANSWER'."
    done
}

# ask_languages PROMPT CURRENT: puts the list in RESULT.
ask_languages() {
    while :; do
        printf '%s [%s] (- for none): ' "$1" "${2:-none}"
        read_answer
        case $ANSWER in
            '') RESULT=$2; return 0 ;;
            -) RESULT=''; return 0 ;;
        esac
        RESULT=$(strip_spaces "$ANSWER")
        if is_language_list "$RESULT"; then return 0; fi
        say "Language codes look like eng, en, pt-BR or zh-Hans separated by commas, but got '$ANSWER'."
    done
}

ask_choices() {
    if ! in_list "$GIVEN" preset; then
        say "Picture quality: 1) ultra (best scalers, needs a strong GPU)  2) high  3) light (fastest, for older computers)"
        ask_choice Preset "$PRESET" "ultra high light"
        PRESET=$RESULT
    fi
    if ! in_list "$GIVEN" sub-langs; then
        ask_languages "Subtitle languages in order of preference, such as eng,en or pt-BR,pt" "$SUB_LANGS"
        SUB_LANGS=$RESULT
    fi
    if ! in_list "$GIVEN" audio-langs; then
        ask_languages "Audio languages in order of preference" "$AUDIO_LANGS"
        AUDIO_LANGS=$RESULT
    fi
    if ! in_list "$GIVEN" without; then
        ask_yes_no "ModernZ controller instead of mpv's own?" y || WITHOUT="$WITHOUT modernz"
        if ! in_list "$WITHOUT" modernz; then ask_yes_no "Seekbar thumbnails?" y || WITHOUT="$WITHOUT thumbnails"; fi
        ask_yes_no "Video effects panel (Ctrl+E)?" y || WITHOUT="$WITHOUT effects"
        ask_yes_no "Subtitle style panel (Ctrl+T)?" y || WITHOUT="$WITHOUT substyle"
        ask_yes_no "Resume prompt for partly watched files?" y || WITHOUT="$WITHOUT resume"
    fi
    if ! in_list "$GIVEN" font; then
        say "Subtitle font:"
        _n=0
        for _key in $FONT_CHOICES; do
            _n=$((_n + 1))
            set_font "$_key"
            say "  $_n) $FONT_NAME"
        done
        ask_choice Font "$FONT" "$FONT_CHOICES"
        FONT=$RESULT
    fi
    if [ -n "$WEB_ASSET" ] && ! in_list "$GIVEN" web; then
        if ask_yes_no "Install yt-dlp so mpv can play web videos (about 40 MB)?" y; then DO_WEB=1; else DO_WEB=0; fi
    fi
    if [ -z "$PLAYER_NOTE" ] && ! in_list "$GIVEN" player; then
        if ask_yes_no "Make mpv the default app for video and audio files?" n; then DO_PLAYER=1; else DO_PLAYER=0; fi
    fi
}

# Finding mpv

# Runs mpv (or the Flatpak) with the given arguments.
run_mpv() { if [ "$MPV_KIND" = flatpak ]; then flatpak run "$FLATPAK_ID" "$@"; else "$MPV_BIN" "$@"; fi; }

find_mpv() {
    MPV_KIND='' MPV_BIN='' MPV_APP=''
    _found=$(command -v mpv 2>/dev/null) || _found=''
    case $_found in
        /snap/*|/var/lib/snapd/*) MPV_KIND=snap; MPV_BIN=$_found ;;
        /*) MPV_KIND=native; MPV_BIN=$_found ;;
    esac
    if [ -z "$MPV_KIND" ] && have flatpak && flatpak info "$FLATPAK_ID" >/dev/null 2>&1; then MPV_KIND=flatpak; fi
    if [ -z "$MPV_KIND" ] && [ "$OS_KIND" != Darwin ] && have snap && snap list mpv >/dev/null 2>&1; then
        MPV_KIND=snap
        MPV_BIN=/snap/bin/mpv
    fi
    if [ "$OS_KIND" = Darwin ]; then
        for _app in /Applications/mpv.app "$HOME/Applications/mpv.app"; do
            [ -x "$_app/Contents/MacOS/mpv" ] || continue
            MPV_APP=$_app
            if [ -z "$MPV_KIND" ]; then MPV_KIND=app; MPV_BIN=$_app/Contents/MacOS/mpv; fi
            break
        done
    fi
}

# Warns when mpv is too old, or lacks menu.conf support (probed through update-clipboard, which came after it).
check_mpv_version() {
    if [ "$MPV_KIND" != flatpak ] && [ ! -x "$MPV_BIN" ]; then return 0; fi
    _line=$(run_mpv --version 2>/dev/null | sed -n '1p')
    _ver=$(printf '%s\n' "$_line" | sed -n 's/^mpv[[:space:]][[:space:]]*v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    if [ -z "$_ver" ]; then
        warn "The mpv version could not be read from '$_line'. The config needs 0.$MIN_MPV_MINOR or newer."
    elif [ "${_ver%.*}" -eq 0 ] && [ "${_ver#*.}" -lt "$MIN_MPV_MINOR" ]; then
        warn "This mpv is version $_ver, but the config needs 0.$MIN_MPV_MINOR or newer. The effects panel and some settings will not work."
    elif ! run_mpv --no-config --input-cmdlist 2>/dev/null | grep -q '^update-clipboard'; then
        warn "This mpv ($_ver) has no menu.conf support, which came after 0.41.0. The right-click menu and Open > Clipboard will not work."
    fi
}

# Where things go
determine_paths() {
    if [ -n "$CONFIG_DIR_ARG" ]; then
        case $CONFIG_DIR_ARG in
            \~) CONFIG_DIR=$HOME ;;
            \~/*) CONFIG_DIR=$HOME/${CONFIG_DIR_ARG#\~/} ;;
            /*) CONFIG_DIR=$CONFIG_DIR_ARG ;;
            *) CONFIG_DIR=$PWD/$CONFIG_DIR_ARG ;;
        esac
    else
        case $MPV_KIND in
            flatpak) CONFIG_DIR=$HOME/.var/app/$FLATPAK_ID/config/mpv ;;
            snap) CONFIG_DIR=$HOME/snap/mpv/current/.config/mpv ;;
            *) CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/mpv ;;
        esac
    fi
    while [ "${CONFIG_DIR%/}" != "$CONFIG_DIR" ] && [ -n "${CONFIG_DIR%/}" ]; do CONFIG_DIR=${CONFIG_DIR%/}; done
}

# The manifest is a key=value file: config_dir, then one line for each thing --uninstall undoes.
mf_add() { grep -qxF "$1" "$MANIFEST_FILE" 2>/dev/null || printf '%s\n' "$1" 2>/dev/null >> "$MANIFEST_FILE"; }

# Adds "$1=$2" unless the key is there already, so the first value recorded is the one kept.
mf_add_once() { grep -q "^$1=" "$MANIFEST_FILE" 2>/dev/null || mf_add "$1=$2"; }

# Prints the values of the manifest lines that start with $1.
mf_get() { sed -n "s/^$1//p" "$MANIFEST_FILE"; }

# Downloads
download() {
    if have curl; then curl -fsSL --retry 2 --connect-timeout 20 -o "$2" "$1"; else wget -q -O "$2" "$1"; fi
}

# Prints the SHA-256 of file $1 in lower case, or nothing when no tool for it is installed.
sha256_of() {
    if have sha256sum; then sha256sum "$1"
    elif have shasum; then shasum -a 256 "$1"
    else openssl dgst -sha256 -r "$1"
    fi 2>/dev/null | awk '{ print tolower($1) }'
}

# get URL NAME: downloads into the work folder.
get() {
    make_work_directory
    download "$1" "$WORK_DIR/$2" && return 0
    problem "The download of $1 failed. Check the internet connection, and that curl or wget is installed."
    return 1
}

# fetch URL NAME SHA256: downloads into the work folder and deletes the file if the checksum differs.
fetch() {
    get "$1" "$2" || return 1
    _got=$(sha256_of "$WORK_DIR/$2")
    [ "$_got" != "$3" ] || return 0
    rm -f "${WORK_DIR:?}/$2"
    problem "The checksum of $2 must be $3, but got ${_got:-nothing, because sha256sum, shasum and openssl are all missing}. The file was deleted."
    return 1
}

# Subtitle fonts

# set_font KEY: sets FONT_NAME and FONT_SIZE. FONT_FOLDER is set for the fonts that are downloaded.
set_font() {
    FONT_FOLDER=''
    case $1 in
        firago) FONT_NAME="FiraGO Book"; FONT_SIZE=37; FONT_FOLDER=FiraGO ;;
        atkinson) FONT_NAME="Atkinson Hyperlegible"; FONT_SIZE=39; FONT_FOLDER=AtkinsonHyperlegible ;;
        noto) FONT_NAME="Noto Sans"; FONT_SIZE=36 ;;
        dejavu) FONT_NAME="DejaVu Sans"; FONT_SIZE=33 ;;
        liberation) FONT_NAME="Liberation Sans"; FONT_SIZE=34 ;;
        cantarell) FONT_NAME="Cantarell"; FONT_SIZE=38 ;;
        helvetica) FONT_NAME="Helvetica Neue"; FONT_SIZE=34 ;;
        avenir) FONT_NAME="Avenir Next"; FONT_SIZE=35 ;;
        lucida) FONT_NAME="Lucida Grande"; FONT_SIZE=34 ;;
    esac
}

# True when the font family $1 is installed. On macOS it matches file names, like scripts/font-fallback.lua.
font_present() {
    if [ "$OS_KIND" != Darwin ]; then
        have fc-list && fc-list : family 2>/dev/null | tr ',' '\n' | grep -qixF "$1"
        return
    fi
    _name=$(lower "$1" | tr -d ' ')
    for _d in /System/Library/Fonts /System/Library/Fonts/Supplemental /Library/Fonts "$HOME/Library/Fonts"; do
        if printf '%s\n' "$_d"/* | sed 's|.*/||' | tr -d ' _-' | tr '[:upper:]' '[:lower:]' | grep -q "^$_name"; then return 0; fi
    done
    return 1
}

# Sets FONT_CHOICES to the two downloadable fonts and the system fonts that are installed.
plan_fonts() {
    FONT_CHOICES="firago atkinson"
    if [ "$OS_KIND" = Darwin ]; then _system="helvetica avenir lucida"; else _system="noto dejavu liberation cantarell"; fi
    for _key in $_system; do
        set_font "$_key"
        if font_present "$FONT_NAME"; then FONT_CHOICES="$FONT_CHOICES $_key"; fi
    done
    in_list "$FONT_CHOICES" "$FONT" ||
        fail "The font can be one of '$FONT_CHOICES', but got '$FONT'. System fonts are offered only when installed."
}

# Decides what to do about the chosen font, once the choice is final.
plan_font_install() {
    set_font "$FONT"
    FONT_DOWNLOAD=0
    FONT_NOTE="installed already"
    if [ "$OS_KIND" = Darwin ]; then FONT_DIR=$HOME/Library/Fonts; else FONT_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/fonts/$FONT_FOLDER; fi
    if [ -n "$FONT_FOLDER" ] && ! font_present "$FONT_NAME"; then
        if [ "$DO_FONTS" -eq 1 ]; then FONT_DOWNLOAD=1; FONT_NOTE="download into $FONT_DIR"; else FONT_NOTE="not installed, because of --no-fonts"; fi
    fi
}

download_font() {
    case $FONT in
        firago)
            fetch "$FIRAGO_URL/Roman/FiraGO-Book.ttf" FiraGO-Book.ttf 4c132d5290477709da7fee51f2494d9d13157024e5011d665ebe73489416f894 &&
                fetch "$FIRAGO_URL/Italic/FiraGO-BookItalic.ttf" FiraGO-BookItalic.ttf d1acf0bfba04de8a35888f402bbe029b3c412b2a52ea4da27bf498bc5973fc05
            ;;
        atkinson)
            fetch "$ATKINSON_URL/AtkinsonHyperlegible-Regular.ttf" AtkinsonHyperlegible-Regular.ttf 7fb917c89019896d0b52ee84b7cbb3304c18cb90b19a62f5e32712bd23e97669 &&
                fetch "$ATKINSON_URL/AtkinsonHyperlegible-Italic.ttf" AtkinsonHyperlegible-Italic.ttf 021beda4d3c6edfc78872e436d74009f9a1bcb294331908fe5747c61d3dcc514
            ;;
    esac
}

install_font() {
    [ "$FONT_DOWNLOAD" -eq 1 ] || return 0
    say "Downloading the font $FONT_NAME"
    download_font || return 0
    for _path in "$WORK_DIR"/*.ttf; do mf_add "font=$FONT_DIR/${_path##*/}"; done
    if ! { mkdir -p "$FONT_DIR" && mv "$WORK_DIR"/*.ttf "$FONT_DIR/"; }; then
        problem "The font files could not be written to '$FONT_DIR'. Check that the folder is writable."
        return 0
    fi
    if [ "$OS_KIND" != Darwin ] && have fc-cache; then fc-cache -f "$FONT_DIR" >/dev/null 2>&1; fi
    say "  $FONT_NAME installed in $FONT_DIR"
}

# Web videos (yt-dlp)

# Sets WEB_ASSET to the yt-dlp program to download, or WEB_NOTE to the reason there is none.
plan_web() {
    WEB_ASSET='' WEB_NOTE='' YTDLP_OK=0
    _existing=$(command -v yt-dlp 2>/dev/null) || _existing=''
    if [ -n "$_existing" ]; then
        WEB_NOTE="yt-dlp is installed already, at $_existing."
        YTDLP_OK=1
    elif [ "$MPV_KIND" = flatpak ] || [ "$MPV_KIND" = snap ]; then
        WEB_NOTE="This mpv runs in a sandbox. See the package's page for how to add yt-dlp."
    else
        case $OS_KIND:$ARCH in
            Darwin:*) WEB_ASSET=yt-dlp_macos ;;
            Linux:x86_64|Linux:amd64) WEB_ASSET=yt-dlp_linux ;;
            Linux:aarch64|Linux:arm64) WEB_ASSET=yt-dlp_linux_aarch64 ;;
        esac
        if [ -z "$WEB_ASSET" ]; then
            WEB_NOTE="yt-dlp has no standalone program for $OS_KIND on $ARCH. Install it with your package manager."
        elif [ "$OS_KIND" = Linux ] && have ldd && ldd --version 2>&1 | grep -qi musl; then
            WEB_ASSET=yt-dlp_musl${WEB_ASSET#yt-dlp_}
        fi
    fi
}

# Downloads yt-dlp into the staging folder, checked against the SHA2-256SUMS of its release.
install_ytdlp() {
    [ "$DO_WEB" -eq 1 ] && [ -n "$WEB_ASSET" ] || return 0
    say "  Downloading yt-dlp ($WEB_ASSET, about 40 MB)"
    get "$YTDLP_URL/SHA2-256SUMS" SHA2-256SUMS || return 0
    _want=$(awk -v name="$WEB_ASSET" '{ n = $2; sub(/^\*/, "", n); if (n == name) print $1 }' "$WORK_DIR/SHA2-256SUMS" | sed -n '1p')
    if [ -z "$_want" ]; then
        problem "The checksum list of the yt-dlp release must contain $WEB_ASSET, but it does not. yt-dlp was not installed."
        return 0
    fi
    fetch "$YTDLP_URL/$WEB_ASSET" "$WEB_ASSET" "$_want" || return 0
    if mv "$WORK_DIR/$WEB_ASSET" "$STAGE_DIR/yt-dlp" && chmod +x "$STAGE_DIR/yt-dlp"; then
        YTDLP_OK=1
    else
        problem "yt-dlp could not be placed in the config folder. Check the free disk space."
    fi
}

# Building and installing the config
drop() {
    for _p in "$@"; do rm -rf "${STAGE_DIR:?}/$_p"; done
}

# The mpv.conf edits in one pass. A changed line keeps its comment in the same column.
# shellcheck disable=SC2016
MPV_CONF_AWK='
function put(line, text,    h) {
    h = index(substr(line, 2), "#") + 1
    if (h == 1) return text
    while (length(text) < h - 1) text = text " "
    if (text !~ / $/) text = text " "
    return text substr(line, h)
}
{
    if (!p && $0 ~ /^profile=high([ \t]|$)/) { p = 1; if (preset != "high") $0 = put($0, "profile=" preset) }
    else if (!s && $0 ~ /^slang=eng,en([ \t]|$)/) {
        s = 1
        if (slang == "") $0 = put($0, "#slang=")
        else if (slang != "eng,en") $0 = put($0, "slang=" slang)
    }
    else if (!a && $0 ~ /^#alang=([ \t]|$)/) { a = 1; if (alang != "") $0 = put($0, "alang=" alang) }
    else if (!f && $0 ~ /^sub-font=/) { f = 1; sub(/^sub-font=[^,]*/, "sub-font=" font) }
    else if (builtin && !o && $0 ~ /^osc=no([ \t]|$)/) { o = 1; $0 = put($0, "osc=yes") }
    else if (builtin && !b && $0 ~ /^osd-bar=no([ \t]|$)/) { b = 1; $0 = put($0, "osd-bar=yes") }
    print
}
END { if (!(p && s && a && f) || (builtin && !(o && b))) exit 1 }
'

edit_mpv_conf() {
    make_work_directory
    if in_list "$WITHOUT" modernz; then _builtin=1; else _builtin=0; fi
    if ! { awk -v preset="$PRESET" -v slang="$SUB_LANGS" -v alang="$AUDIO_LANGS" -v builtin="$_builtin" \
            -v font="$FONT_NAME ($FONT_SIZE regular)" "$MPV_CONF_AWK" "$STAGE_DIR/mpv.conf" > "$WORK_DIR/mpv.conf" &&
            mv "$WORK_DIR/mpv.conf" "$STAGE_DIR/mpv.conf"; }; then
        fail "The mpv.conf in '$SOURCE_DIR' must contain the lines profile=high, slang=eng,en, #alang=, sub-font=, osc=no and osd-bar=no, but at least one is missing. Nothing was changed."
    fi
}

build_stage() {
    _parent=$(dirname "$CONFIG_DIR")
    if ! { mkdir -p "$_parent" && mkdir "$_parent/.mpv-config-install.$$"; }; then
        fail "A temporary folder could not be created in '$_parent'. Check that the folder is writable."
    fi
    STAGE_DIR=$_parent/.mpv-config-install.$$
    cp -R "$SOURCE_DIR/." "$STAGE_DIR/" || fail "The config files could not be copied to '$STAGE_DIR'. Check the free disk space. Nothing was changed."
    drop tools scripts/updater.lua script-opts/updater.conf scripts/open-file/dialog.ps1 scripts/open-file/hidden.js
    if in_list "$WITHOUT" thumbnails; then drop scripts/thumbfast.lua script-opts/thumbfast.conf; fi
    if in_list "$WITHOUT" effects; then drop scripts/video-effects script-opts/video_effects.conf; fi
    if in_list "$WITHOUT" substyle; then drop scripts/sub-style.lua script-opts/sub_style.conf; fi
    if in_list "$WITHOUT" resume; then drop scripts/resume-prompt.lua; fi
    if in_list "$WITHOUT" modernz; then
        drop scripts/modernz.lua script-opts/modernz.conf fonts/modernz-icons.ttf
        rmdir "$STAGE_DIR/fonts" 2>/dev/null
    fi
    edit_mpv_conf
    if [ "$OS_KIND" = Darwin ]; then    # On macOS mpv keeps its saved resume positions, volume and subtitle style in the config folder.
        for _f in resume-prompt.json saved-state.json sub-style.json; do cp "$CONFIG_DIR/$_f" "$STAGE_DIR/" 2>/dev/null; done
    fi
    install_ytdlp
}

# Moves the old config aside and puts the new one in place. If that fails the old one comes back.
swap_in_stage() {
    BACKUP_DIR=''
    trap '' HUP INT TERM    # A signal must not cut the two moves in half.
    if has_config; then
        BACKUP_DIR=$CONFIG_DIR-backup-$(date +%Y%m%d-%H%M%S)
        if [ -e "$BACKUP_DIR" ] || [ -L "$BACKUP_DIR" ]; then BACKUP_DIR=$BACKUP_DIR-$$; fi
        mv "$CONFIG_DIR" "$BACKUP_DIR" || fail "The old config '$CONFIG_DIR' could not be moved to '$BACKUP_DIR'. Nothing was changed."
    elif [ -d "$CONFIG_DIR" ]; then
        rmdir "$CONFIG_DIR" || fail "The empty folder '$CONFIG_DIR' could not be removed. Nothing was changed."
    fi
    if ! mv "$STAGE_DIR" "$CONFIG_DIR"; then
        if [ -n "$BACKUP_DIR" ]; then mv "$BACKUP_DIR" "$CONFIG_DIR"; fi
        fail "The new config could not be moved to '$CONFIG_DIR'. Nothing was changed."
    fi
    STAGE_DIR=''
    trap 'exit 1' HUP INT TERM
}

# Default player

# Prints the path of mpv's desktop file.
find_desktop_file() (
    case $MPV_KIND in
        flatpak) _names=$FLATPAK_ID.desktop ;;
        snap) _names=mpv_mpv.desktop:mpv.desktop ;;
        *) _names=mpv.desktop ;;
    esac
    _dirs="${XDG_DATA_HOME:-$HOME/.local/share}:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:/var/lib/flatpak/exports/share:$HOME/.local/share/flatpak/exports/share:/var/lib/snapd/desktop"
    IFS=:
    # shellcheck disable=SC2086
    for _dir in $_dirs; do
        # shellcheck disable=SC2086
        for _name in $_names; do
            if [ -f "$_dir/applications/$_name" ]; then printf '%s\n' "$_dir/applications/$_name"; exit 0; fi
        done
    done
    exit 1
)

# Sets PLAYER_NOTE to the reason the default player cannot be set, or leaves it empty.
plan_player() {
    PLAYER_NOTE=''
    if [ "$OS_KIND" = Darwin ]; then
        if [ -z "$MPV_APP" ]; then PLAYER_NOTE="Setting the default player needs mpv.app, but only the command line mpv was found."
        elif ! have duti; then PLAYER_NOTE="Setting the default player needs duti. Install it with: brew install duti"
        fi
    elif [ -z "$MPV_KIND" ]; then
        PLAYER_NOTE="mpv was not found, so there is no app to make the default."
    elif ! have xdg-mime; then
        PLAYER_NOTE="Setting the default player needs xdg-mime, which is part of xdg-utils."
    elif ! _file=$(find_desktop_file); then
        PLAYER_NOTE="The desktop file of mpv was not found in the usual folders."
    else
        DESKTOP_ID=${_file##*/}
    fi
}

default_app() {
    if [ "$OS_KIND" = Darwin ]; then duti -d "$1"; else xdg-mime query default "$1"; fi 2>/dev/null
}

# set_default_app TYPE APP
set_default_app() {
    if [ "$OS_KIND" = Darwin ]; then duti -s "$2" "$1" all; else xdg-mime default "$2" "$1"; fi >/dev/null 2>&1
}

set_default_player() {
    [ "$DO_PLAYER" -eq 1 ] || return 0
    if [ -n "$PLAYER_NOTE" ]; then problem "$PLAYER_NOTE"; return 0; fi
    say "Making mpv the default player"
    if [ "$OS_KIND" = Darwin ]; then _app=$MACOS_BUNDLE_ID; _types=$MACOS_TYPES; else _app=$DESKTOP_ID; _types=$LINUX_TYPES; fi
    for _t in $_types; do
        _previous=$(default_app "$_t")
        if [ "$_previous" = "$_app" ]; then continue; fi
        if set_default_app "$_t" "$_app"; then mf_add_once "default.$_t" "$_previous"; else problem "The default app for $_t could not be set."; fi
    done
    say "  The earlier defaults are saved for --uninstall."
}

# Removes the entry "type $1 = desktop file $2" that xdg-mime wrote to mimeapps.list.
forget_default() {
    for _list in "${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list" "${XDG_DATA_HOME:-$HOME/.local/share}/applications/mimeapps.list"; do
        [ -f "$_list" ] || continue
        sed "\\|^$1=$2;*\$|d" "$_list" > "$WORK_DIR/mimeapps.list" && cat "$WORK_DIR/mimeapps.list" > "$_list"
    done
}

# Installing
show_summary() {
    if in_list "$WITHOUT" modernz; then _features="mpv's own controller"; else _features="ModernZ controller"; fi
    in_list "$WITHOUT" thumbnails || _features="$_features, seekbar thumbnails"
    in_list "$WITHOUT" effects || _features="$_features, effects panel"
    in_list "$WITHOUT" substyle || _features="$_features, subtitle style panel"
    in_list "$WITHOUT" resume || _features="$_features, resume prompt"
    _backup="none, there is no config yet"
    if has_config; then _backup="the current config moves to $CONFIG_DIR-backup-<date>-<time>"; fi
    _web="yt-dlp is not installed"
    if [ -n "$WEB_NOTE" ]; then _web=$WEB_NOTE; elif [ "$DO_WEB" -eq 1 ]; then _web="download yt-dlp ($WEB_ASSET) into the config folder"; fi
    _player=unchanged
    if [ "$DO_PLAYER" -eq 1 ]; then _player="mpv becomes the default for video and audio files"; fi
    if [ "$DO_PLAYER" -eq 1 ] && [ -n "$PLAYER_NOTE" ]; then _player="unchanged. $PLAYER_NOTE"; fi
    say "Summary:"
    say "  Config folder:    $CONFIG_DIR"
    say "  Backup:           $_backup"
    say "  Picture quality:  $PRESET"
    say "  Subtitle langs:   ${SUB_LANGS:-no preference}"
    say "  Audio langs:      ${AUDIO_LANGS:-no preference}"
    say "  Features:         $_features"
    say "  Subtitle font:    $FONT_NAME ($FONT_SIZE), $FONT_NOTE"
    say "  Web videos:       $_web"
    say "  Default player:   $_player"
    say
}

do_install() {
    [ -f "$SOURCE_DIR/mpv.conf" ] || fail "The config folder must be next to this script and contain mpv.conf, but '$SOURCE_DIR/mpv.conf' was not found. Run the installer from a full download of the repository."
    find_mpv
    if [ -n "$MPV_KIND" ]; then
        check_mpv_version
    else
        say "mpv was not found. Install it first, see https://mpv.io/installation/."
        if [ "$ASK" -eq 1 ]; then ask_yes_no "Install the config anyway?" n || { say "Nothing was changed."; exit 0; }; fi
    fi
    determine_paths
    check_config_dir "$CONFIG_DIR"
    plan_fonts
    plan_web
    plan_player
    if [ "$ASK" -eq 1 ]; then ask_choices; say; fi
    if in_list "$WITHOUT" modernz; then WITHOUT="$WITHOUT thumbnails"; fi
    plan_font_install
    if [ "$(id -u)" = 0 ]; then warn "The installer is running as root, so the files go to root's folders."; fi
    show_summary
    if [ "$ASK" -eq 1 ]; then
        ask_yes_no "Install now?" y || { say "Nothing was changed."; exit 0; }
        say
    fi

    # An earlier install in the same folder keeps its record, so --uninstall can undo all of it.
    _ours=0 _keep=''
    if [ -f "$MANIFEST_FILE" ] && [ "$(mf_get config_dir= | sed -n '1p')" = "$CONFIG_DIR" ]; then
        _ours=1
        _keep=$(grep -E '^(backup|font)=|^default\.' "$MANIFEST_FILE")
    fi

    say "Installing the config"
    build_stage
    swap_in_stage
    if [ -n "$BACKUP_DIR" ]; then say "  Your previous config is saved as $BACKUP_DIR"; fi
    {
        mkdir -p "$MANIFEST_DIR" && {
            printf '%s\n' "# Written by install.sh and read by install.sh --uninstall." "config_dir=$CONFIG_DIR"
            if [ -n "$_keep" ]; then printf '%s\n' "$_keep"; fi
            if [ -n "$BACKUP_DIR" ] && [ "$_ours" -eq 0 ]; then printf 'backup=%s\n' "$BACKUP_DIR"; fi
        } > "$MANIFEST_FILE"
    } || problem "The install record could not be written to '$MANIFEST_FILE', so --uninstall will not work. Check that the folder is writable."
    say "  Config installed in $CONFIG_DIR"

    install_font
    set_default_player
    say
    say "To undo the install, run: sh install.sh --uninstall"
    if [ "$YTDLP_OK" -eq 1 ]; then say "For YouTube, yt-dlp also needs a JavaScript runtime such as Deno (https://deno.com)."; fi
    if [ "$PROBLEMS" -gt 0 ]; then
        say "The config is installed, but $PROBLEMS optional step(s) did not finish. See the warnings above."
        exit 3
    fi
    exit 0
}

# Uninstalling
do_uninstall() {
    [ -f "$MANIFEST_FILE" ] || fail "The install record must be at '$MANIFEST_FILE', but it was not found. If you installed another way, remove the mpv config folder by hand."
    CONFIG_DIR=$(mf_get config_dir= | sed -n '1p')
    [ -n "$CONFIG_DIR" ] || fail "The install record '$MANIFEST_FILE' must name the config folder, but it does not."
    check_config_dir "$CONFIG_DIR"
    _backup=$(mf_get backup= | sed -n '1p')
    say "This removes the config folder $CONFIG_DIR, including files added to it since the install."
    if [ -n "$_backup" ] && [ ! -e "$_backup" ] && [ ! -L "$_backup" ]; then
        warn "The backup $_backup is missing, so nothing is restored."
        _backup=''
    elif [ -n "$_backup" ]; then
        say "Your earlier config is restored from $_backup."
    fi
    if [ "$ASK" -eq 1 ]; then ask_yes_no "Continue?" n || { say "Nothing was changed."; exit 0; }; fi
    make_work_directory
    rm -rf "$CONFIG_DIR" || fail "The config folder '$CONFIG_DIR' could not be removed. Nothing else was changed."
    say "Removed $CONFIG_DIR"
    if [ -n "$_backup" ]; then
        if mv "$_backup" "$CONFIG_DIR"; then
            say "Restored $_backup"
        else
            problem "The backup '$_backup' could not be moved back to '$CONFIG_DIR'. It is still in place, so move it by hand."
        fi
    fi

    mf_get font= | while IFS= read -r _font; do
        case $_font in
            */*.ttf)
                if [ -f "$_font" ] && rm -f "$_font"; then say "Removed the font $_font"; fi
                # Only a folder made by this installer (one level below a "fonts" folder), and only when empty.
                _dir=${_font%/*}
                case ${_dir%/*} in */fonts) rmdir "$_dir" 2>/dev/null ;; esac
                ;;
        esac
    done
    if [ "$OS_KIND" != Darwin ] && have fc-cache; then fc-cache -f >/dev/null 2>&1; fi

    if { [ "$OS_KIND" = Darwin ] && have duti; } || { [ "$OS_KIND" != Darwin ] && have xdg-mime; }; then
        mf_get 'default\.' | while IFS= read -r _entry; do
            _type=${_entry%%=*}
            _previous=${_entry#*=}
            if [ -n "$_previous" ]; then
                set_default_app "$_type" "$_previous" || warn "The default app for $_type could not be restored to $_previous."
            elif [ "$OS_KIND" != Darwin ]; then
                forget_default "$_type" "$(default_app "$_type")"
            fi
        done
    fi

    rm -f "$MANIFEST_FILE"
    rmdir "$MANIFEST_DIR" 2>/dev/null
    if [ "$PROBLEMS" -gt 0 ]; then
        say "The install was undone, but $PROBLEMS step(s) did not finish. See the warnings above."
        exit 3
    fi
    say "The install is undone."
    exit 0
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM
parse_arguments "$@"
detect_system
if [ "$UNINSTALL" -eq 1 ]; then do_uninstall; fi
do_install
