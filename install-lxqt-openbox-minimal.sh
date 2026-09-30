#!/usr/bin/env bash
# =============================================================================
#  Ultra-light LXQt/Openbox for Raspberry Pi OS Lite
#
#  Installs ONLY:
#    - a bare X11 server + xinit (startx)
#    - openbox           (window manager)
#    - lxqt-panel        (panel / menu / taskbar / tray / clock)
#    - pcmanfm-qt        (file manager, also draws the desktop)
#    - qterminal         (terminal)
#    - one small font    (fonts-dejavu-core, otherwise nothing renders text)
#  plus whatever those packages strictly *Depend* on. No recommends, no display
#  manager, no lxqt-session, no themes, no extra apps. Nothing starts at boot:
#  you log in on the console and type `startx`.
#
#  Usage:   sudo bash install-lxqt-openbox-minimal.sh
#  Options: NO_DESKTOP=1  -> don't let pcmanfm-qt draw the desktop/wallpaper
#           TARGET_USER=x -> configure a user other than the one running sudo
# =============================================================================
set -euo pipefail

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root:  sudo bash $0"
command -v apt-get >/dev/null || die "apt-get not found - is this Raspberry Pi OS / Debian?"

TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] \
    || die "Could not determine the desktop user. Run with sudo from your normal user, or set TARGET_USER=name."
id "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' does not exist."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
[[ -d "$TARGET_HOME" ]] || die "Home directory '$TARGET_HOME' not found."

NO_DESKTOP="${NO_DESKTOP:-0}"
export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# 1. Packages
# -----------------------------------------------------------------------------
PACKAGES=(
    # X11: bare server, libinput for keyboard/mouse, startx
    xserver-xorg-core          # includes the 'modesetting' driver used on KMS Pis
    xserver-xorg-input-libinput
    xserver-xorg-video-fbdev   # tiny fallback for non-KMS setups
    xinit
    # Window manager
    openbox
    # The three LXQt bits you asked for
    lxqt-panel 
        lxqt-session 
        liblxqt-dev
        lxqt-config
        lxqt-themes 
        lxqt-policykit 
        lxqt-qtplugin
    # Completely Optional
        # lxqt-runner 
        # lxqt-about
        # lxqt-notificationd
        # lxqt-powermanagement
        # lxqt-globalkeyshortcuts # If you are using a custom window manager (like i3, Openbox, or Labwc), you will map your hotkeys directly in that WM's configuration file anyway
        # lxqt-admin              # Easily handled entirely through standard terminal commands (timedatectl, useradd).
        # lxqt-sudo               # Grphical sudo / Rarely needed if you launch administrative software directly from a terminal window

    # Tools
    # file manager
    pcmanfm-qt

    # terminal
    qterminal

    # browser
    vimb

    # clipboqrd manager
    qlipper

    # A single small font so Qt has something to render with
    fonts-dejavu-core

    # Session D-Bus for the Qt apps (pcmanfm-qt depends on it anyway)
    dbus-x11
)

log "Updating package lists"
apt-get update

log "Installing packages (no recommends / no suggests)"
apt-get install -y --no-install-recommends --no-install-suggests "${PACKAGES[@]}"

log "Cleaning apt cache"
apt-get clean

# Keep booting to the console (Lite already does, but make it explicit)
systemctl set-default multi-user.target >/dev/null 2>&1 || true

# Make sure the user can access the GPU / input devices for rootless Xorg
for g in video render input; do
    getent group "$g" >/dev/null && usermod -aG "$g" "$TARGET_USER" || true
done

# -----------------------------------------------------------------------------
# 2. Raspberry Pi 5 (and some Pi 4 KMS setups) have more than one DRM card:
#    the v3d render-only card and the vc4 display card. Xorg's modesetting
#    driver may grab the wrong one ("Cannot run in framebuffer mode").
#    Point it explicitly at the card that has display connectors.
# -----------------------------------------------------------------------------
DISPLAY_CARD=""
card_count=0
for c in /sys/class/drm/card[0-9]; do
    [[ -e "$c" ]] || continue
    card_count=$((card_count + 1))
    if [[ -z "$DISPLAY_CARD" ]] && ls -d "$c"-* >/dev/null 2>&1; then
        DISPLAY_CARD="/dev/dri/$(basename "$c")"
    fi
done
if (( card_count > 1 )) && [[ -n "$DISPLAY_CARD" ]]; then
    log "Multiple DRM cards found - pinning Xorg to $DISPLAY_CARD"
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/99-pi-kmsdev.conf <<EOF
# Written by install-lxqt-openbox-minimal.sh
Section "Device"
    Identifier "Pi KMS display"
    Driver     "modesetting"
    Option     "kmsdev" "$DISPLAY_CARD"
EndSection
EOF
fi

# -----------------------------------------------------------------------------
# 3. User configuration
# -----------------------------------------------------------------------------
as_user() { sudo -u "$TARGET_USER" -H "$@"; }
backup()  { [[ -e "$1" ]] && cp -a "$1" "$1.bak.$(date +%Y%m%d%H%M%S)" && warn "Backed up existing $1"; return 0; }

log "Writing configuration for user '$TARGET_USER'"
as_user mkdir -p "$TARGET_HOME/.config/openbox" "$TARGET_HOME/.config/lxqt" "$TARGET_HOME/.config/pcmanfm-qt/default"

# --- ~/.xinitrc --------------------------------------------------------------
XINITRC="$TARGET_HOME/.xinitrc"
backup "$XINITRC"
cat > "$XINITRC" <<'EOF'
#!/bin/sh
# Minimal LXQt-panel + Openbox session, started with `startx`

export XDG_CURRENT_DESKTOP=LXQt
export XDG_SESSION_TYPE=x11
export QT_AUTO_SCREEN_SCALE_FACTOR=0

# Merge ~/.Xresources if present
[ -f "$HOME/.Xresources" ] && command -v xrdb >/dev/null && xrdb -merge "$HOME/.Xresources"

# openbox-session runs ~/.config/openbox/autostart (panel, desktop)
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    exec dbus-launch --exit-with-session openbox-session
else
    exec openbox-session
fi
EOF
chmod 755 "$XINITRC"

# --- Openbox autostart -------------------------------------------------------
AUTOSTART="$TARGET_HOME/.config/openbox/autostart"
backup "$AUTOSTART"
{
    echo '# Started by openbox-session'
    echo 'lxqt-panel &'
    if [[ "$NO_DESKTOP" == "1" ]]; then
        echo '# pcmanfm-qt --desktop &   # disabled (NO_DESKTOP=1)'
    else
        echo 'pcmanfm-qt --desktop &'
    fi
} > "$AUTOSTART"

# --- Openbox rc.xml: stock config + Ctrl+Alt+T / Super+E shortcuts -----------
RCXML="$TARGET_HOME/.config/openbox/rc.xml"
if [[ ! -e "$RCXML" && -f /etc/xdg/openbox/rc.xml ]]; then
    cp /etc/xdg/openbox/rc.xml "$RCXML"
    sed -i 's#</keyboard>#  <keybind key="C-A-t"><action name="Execute"><command>qterminal</command></action></keybind>\
  <keybind key="W-e"><action name="Execute"><command>pcmanfm-qt</command></action></keybind>\
</keyboard>#' "$RCXML"
fi

# --- Openbox right-click desktop menu (only our apps) ------------------------
MENUXML="$TARGET_HOME/.config/openbox/menu.xml"
backup "$MENUXML"
cat > "$MENUXML" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="Openbox">
    <item label="Terminal"><action name="Execute"><command>qterminal</command></action></item>
    <item label="File Manager"><action name="Execute"><command>pcmanfm-qt</command></action></item>
    <separator />
    <item label="Reconfigure Openbox"><action name="Reconfigure" /></item>
    <item label="Exit to console">
      <action name="Exit"><prompt>yes</prompt></action>
    </item>
  </menu>
</openbox_menu>
EOF

# --- lxqt-panel --------------------------------------------------------------
# The menu button shows text, so it works without any icon theme installed.
MENU_FILE=""
for f in /etc/xdg/menus/lxqt-applications.menu /etc/xdg/menus/lxde-applications.menu; do
    [[ -f "$f" ]] && { MENU_FILE="$f"; break; }
done

PANELCONF="$TARGET_HOME/.config/lxqt/panel.conf"
backup "$PANELCONF"
cat > "$PANELCONF" <<EOF
[General]
__userfile__=true
panels=panel1

[panel1]
alignment=-1
animation-duration=0
desktop=0
hidable=false
iconSize=22
lineCount=1
lockPanel=false
panelSize=32
plugins=mainmenu, taskbar, tray, worldclock
position=Bottom
width=100
widthPercent=true

[mainmenu]
type=mainmenu
ownIcon=false
showText=true
text=Menu
filterMenu=true
${MENU_FILE:+menu_file=$MENU_FILE}

[taskbar]
type=taskbar
buttonStyle=Text
showOnlyOneDesktopTasks=true

[tray]
type=tray

[worldclock]
type=worldclock
EOF

# Plain Qt look: no lxqt-theme package installed, so don't ask for one
LXQTCONF="$TARGET_HOME/.config/lxqt/lxqt.conf"
if [[ ! -e "$LXQTCONF" ]]; then
    cat > "$LXQTCONF" <<'EOF'
[General]
__userfile__=true
theme=
icon_theme=
EOF
fi

# --- pcmanfm-qt: plain background colour, no wallpaper file needed -----------
PCMCONF="$TARGET_HOME/.config/pcmanfm-qt/default/settings.conf"
if [[ ! -e "$PCMCONF" ]]; then
    cat > "$PCMCONF" <<'EOF'
[Desktop]
BgColor=#2e3440
FgColor=#eceff4
ShadowColor=#000000
WallpaperMode=none
ShowWmMenu=true

[Behavior]
QuickExec=false
EOF
fi

chown -R "$TARGET_USER:$TARGET_GROUP" \
    "$XINITRC" "$TARGET_HOME/.config/openbox" "$TARGET_HOME/.config/lxqt" "$TARGET_HOME/.config/pcmanfm-qt"

#------------------------------------------------------------
# Create the user autostart directory if it doesn't exist
mkdir -p ~/.config/autostart

# 2. Generate the Parcellite autostart desktop entry
cat << 'EOF' > ~/.config/autostart/parcellite.desktop
[Desktop Entry]
Type=Application
Name=Parcellite Clipboard Manager
Comment=Autostart Parcellite for LXQt and Openbox
Exec=parcellite
Terminal=false
X-LXQt-Need-Tray=true
EOF

echo "✅ Parcellite autostart script generated successfully!"

#------------------------------------------------------------

# 1. Define the Openbox config file path
printf " $ TARGET_USER variable "
echo $TARGET_USER
printf " $ HOME variable "
echo $HOME

CONFIG_FILE="$HOME/.config/openbox/rc.xml"

# 2. Make a backup of your current config just in case
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

# 3. Define the new shortcuts to insert
SHORTCUTS="    <!-- Custom LXQt/Openbox Minimal Shortcuts -->\n\
    <keybind key=\"W-w\">\n\
      <action name=\"Execute\">\n\
        <command>vimb</command>\n\
      </action>\n\
    </keybind>\n\
    <keybind key=\"W-t\">\n\
      <action name=\"Execute\">\n\
        <command>qterminal</command>\n\
      </action>\n\
    </keybind>\n\
    <keybind key=\"W-f\">\n\
      <action name=\"Execute\">\n\
        <command>pcmanfm-qt</command>\n\
      </action>\n\
    </keybind>"

# 4. Insert the shortcuts right before the closing </keyboard> tag
sed -i "/<\/keyboard>/i ${SHORTCUTS}" "$CONFIG_FILE"

# 5. Tell Openbox to instantly reload the configuration
openbox --reconfigure

echo "✅ Shortcuts added! Try pressing Win+W, Win+T, or Win+F now."

#------------------------------------------------------------

# -----------------------------------------------------------------------------
# 4. Done
# -----------------------------------------------------------------------------
log "Done."
cat <<EOF

  Installed: Xorg + xinit, openbox, lxqt-panel, pcmanfm-qt, qterminal.
  Nothing starts automatically - the Pi still boots to the console.

  To start the desktop:   log in as '$TARGET_USER' on the console and run
                              startx

  Inside the session:
    - Panel "Menu" button  -> applications
    - Right-click desktop  -> Terminal / File Manager / Exit (pcmanfm-qt shows
                              the Openbox menu when ShowWmMenu=true)
    - Ctrl+Alt+T           -> qterminal
    - Super+E              -> pcmanfm-qt
    - Exit                 -> right-click desktop > Exit, or run: openbox --exit

  Group membership changed (video/render/input) - log out and back in (or
  reboot) once before the first 'startx'.

EOF
