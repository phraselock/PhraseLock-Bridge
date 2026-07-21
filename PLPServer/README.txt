PLPServer — Client Certificate Setup
======================================

install.sh set up this server's own CA, server certificate, nginx,
mosquitto and plp-custom — and, as part of that, issued the one bootstrap
client certificate needed to access this server's API
(phraselock.conf, mTLS on port 443).

The client certificate bundle:

    __CLIENT_P12_PATH__

This needs to be imported on any PC/Mac that should be able to call this
server's /api/ (e.g. an admin's or technician's machine). Password: see
credentials.txt next to this file.

Fetch it via SCP — from the PC/Mac/Windows machine that needs it (Windows
10/11 ships scp.exe out of the box; in PowerShell use "curl.exe"/"scp.exe"
explicitly, since plain "curl"/"scp" may be aliased to something else):

    scp __SSH_USER__@__DNAME__:__CLIENT_P12_PATH__ .

(Adjust the username if you don't connect as __SSH_USER__.)

Importing on Windows:
  - Double-click the .p12 file, or import via certmgr.msc.
  - Store location: "Current User" — not "Local Machine". Current User
    matches how browsers and most client apps look up certificates by
    default; Local Machine needs admin rights and is usually the wrong
    choice here.

Importing on Mac:
  - Double-click the .p12 file, or use Keychain Access > File > Import.
  - Choose the "login" keychain — not "System". The login keychain is
    tied to your user account, matching how apps/browsers look up client
    certificates; the System keychain is shared machine-wide and needs
    admin rights.

MQTT broker login:
  Username: __MQTT_USER__
  Password: see credentials.txt next to this file.

Everything else this install produced (server CA, MQTT CA, nginx,
mosquitto, plp-custom) is already wired up automatically — no further
manual steps needed beyond this certificate import.
