# OX Drive Cleaner

Removes OX Drive completely from a Mac (TestFlight, App Store and development builds) together with
its Finder folder, its login and all of its data, so the next build starts fresh.

**Files in the OX Drive folder that were not uploaded yet are lost.**

## Use

1. Open **Terminal** (Applications > Utilities), paste this line and press Return:

   ```shell
   curl -fsSL https://raw.githubusercontent.com/sebhb/ox-drive-cleaner/v1/install.sh | bash
   ```

   This creates **OX Drive Cleaner** on your Desktop.
2. Double-click **OX Drive Cleaner**. The first time, it asks for Full Disk Access and opens System
   Settings:
   - click **+**, choose **OX Drive Cleaner** on your Desktop and turn it on;
   - open **OX Drive Cleaner** again.
3. Check the list of what will be removed and click **Remove**. Enter your password when asked.
4. Restart your Mac.
5. Remove **OX Drive Cleaner** from Full Disk Access (select it, click **−**) and move it to the
   Trash.

If **OX Drive Cleaner** is already listed in Full Disk Access from an earlier version, remove it with
**−** and add it again: a new version is not covered by the old entry.

## If something is left

The final dialog lists what could not be removed. Restart the Mac and run the cleaner again. If that
does not help, send `~/Library/Logs/OX Drive Cleaner.log` to your contact.

## Maintainers

`install.sh` is generated; do not edit it here. Replace it with a newly generated one, tag the commit
(`v2`, `v3`, ...) and update the tag in the URL above.
