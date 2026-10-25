Recon Verify - portable package
================================

Nothing to install: Node.js is included (node.exe) and the app is already built.

1. Unzip ReconVerify.zip to a folder, e.g. C:\ReconVerify
2. Copy .env.example to .env and fill in:
     RECON_CLIENT_SECRET, WAREHOUSE_DATABASE, LAKEHOUSE_SERVER, LAKEHOUSE_DATABASE,
     APP_USERNAME, APP_PASSWORD (the login the browser asks for)
3. Double-click diagnose.bat once - it must end with "warehouse OK, lakehouse OK".
4. Double-click start.bat - the browser opens http://localhost:3000
   Keep the black window open while using the app; close it to stop.

Notes
- The app is read-only and only reachable from this PC (127.0.0.1).
- .env holds the service principal secret in plain text: keep this folder readable only by its users.
- Outbound TCP port 1433 to *.datawarehouse.fabric.microsoft.com must be open (diagnose.bat shows it).
- Port 3000 in use? Run in a command prompt:  set PORT=3001 && start.bat
- New version: replace the folder, keep your .env.
