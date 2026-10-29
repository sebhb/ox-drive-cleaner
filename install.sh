#!/bin/bash
# Builds "OX Drive Cleaner" on the Desktop. Generated; do not edit.
#
#   curl -fsSL <url of this file> | bash
#
# The applet is compiled and signed here, on the Mac that runs it, so it carries no quarantine flag
# and needs no notarization. Running this again replaces it; a changed version has to be added to
# Full Disk Access again.
set -euo pipefail

CLEANER_NAME="OX Drive Cleaner"
CLEANER_BUNDLE_ID="de.ox.drive.cleaner"
TARGET="$HOME/Desktop/$CLEANER_NAME.app"
WORK_DIR=""

fail() {
  echo "$*" >&2
  exit 1
}

main() {
  [[ "$(uname -s)" == Darwin ]] || fail "This only runs on a Mac."
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT

  local applet="$WORK_DIR/$CLEANER_NAME.app"
  write_cleanup_sh >"$WORK_DIR/cleanup.sh"
  write_applescript >"$WORK_DIR/Cleaner.applescript"
  local output
  # Reports "replacing existing signature" on success; only a failure's output is of interest.
  output="$(osacompile -o "$applet" "$WORK_DIR/Cleaner.applescript" 2>&1)" || fail "$output"
  install -m 755 "$WORK_DIR/cleanup.sh" "$applet/Contents/Resources/cleanup.sh"
  # Full Disk Access lists the applet under its bundle name; without one it shows as "applet".
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $CLEANER_BUNDLE_ID" \
    -c "Set :CFBundleName $CLEANER_NAME" "$applet/Contents/Info.plist"
  codesign --force --sign - "$applet" 2>/dev/null
  codesign --verify --strict "$applet"

  rm -rf "$TARGET"
  mv "$applet" "$TARGET"
  open -R "$TARGET"
  echo "\"$CLEANER_NAME\" is on your Desktop. Double-click it and follow its instructions."
}

write_cleanup_sh() {
  cat <<'CLEANUP_SH_EOF'
#!/bin/bash
# Removes every installation of OX Drive (TestFlight, App Store, development) from this Mac
# together with its File Provider domain, synchronized folder and data. The cleaner applet runs it
# one step at a time:
#
#   cleanup.sh check     exit 3 if a container cannot be read (no Full Disk Access)
#   cleanup.sh scan      prints one line per piece that would be removed; nothing if none
#   cleanup.sh prepare   stops processes, removes the domain and every bundle the user owns;
#                        prints the root-owned bundles (store installs) for the applet to remove
#   cleanup.sh finish    removes registrations and data, prints what is left over
#
# Runs under the bash 3.2 that ships with macOS and needs nothing else. Stdout is the applet's result
# channel; everything else goes to the log file below.
set -u

APP_NAME="OX Drive"
APPLICATION_ID="de.ox.drive"

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Makes the app remove its File Provider domain and exit.
REMOVE_DOMAIN_ARG="--remove-domain"
BUNDLE_ID="$APPLICATION_ID.mac"
EXTENSION_BUNDLE_ID="$BUNDLE_ID.FileProviderExtension"
DAEMON_BUNDLE_ID="$BUNDLE_ID.SyncDaemon"
UI_BUNDLE_ID="$BUNDLE_ID.Settings"
BUNDLE_IDS=("$BUNDLE_ID" "$EXTENSION_BUNDLE_ID" "$DAEMON_BUNDLE_ID" "$UI_BUNDLE_ID")
GUI_DOMAIN="gui/$(id -u)"

LOG="$HOME/Library/Logs/$APP_NAME Cleaner.log"
mkdir -p "$HOME/Library/Logs"
exec 3>&1 >>"$LOG" 2>&1
echo
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ${1:-}"

result() {
  echo "$@" >&3
}

# Prints the command and runs it. A failure is logged, not fatal: `finish` reports what survived.
run() {
  echo "  $*"
  "$@" || echo "  (failed: exit $?)"
}

bundle_id_of() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}

is_brand_bundle() {
  local id candidate
  id="$(bundle_id_of "$1")"
  for candidate in "${BUNDLE_IDS[@]}"; do
    [[ "$id" == "$candidate" ]] && return 0
  done
  return 1
}

# Every path LaunchServices has registered: the only source that also lists copies Spotlight never
# indexed and the stale entries of bundles that are already gone.
launchservices_paths() {
  "$LSREGISTER" -dump 2>/dev/null | sed -n 's/^path: *\(\/.*\) (0x[0-9a-f]*)$/\1/p' | sort -u
}

extension_paths() {
  pluginkit -m -v -p com.apple.fileprovider-nonui -i "$EXTENSION_BUNDLE_ID" 2>/dev/null |
    awk -F'\t' 'NF >= 4 { print $4 }'
}

candidate_paths() {
  local id trashed
  for id in "${BUNDLE_IDS[@]}"; do
    mdfind "kMDItemCFBundleIdentifier == '$id'" 2>/dev/null
  done
  launchservices_paths | grep -F -e "/$APP_NAME.app" -e "FileProviderExtension.appex"
  extension_paths
  for trashed in "$HOME"/.Trash/*.app; do
    [[ -e "$trashed" ]] && echo "$trashed"
  done
}

# Fills BUNDLES with every bundle of the brand on disk, outermost only (a nested bundle goes with
# its parent) and /Applications first, the copy the domain removal tries first. STALE gets the
# registered paths that no longer exist.
find_bundles() {
  BUNDLES=()
  STALE=()
  local path kept nested
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ ! -e "$path" ]]; then
      [[ "$path" == *"/$APP_NAME.app"* ]] && STALE+=("$path")
      continue
    fi
    nested=""
    for kept in ${BUNDLES[@]+"${BUNDLES[@]}"}; do
      [[ "$path" == "$kept"/* ]] && nested=1
    done
    [[ -z "$nested" ]] || continue
    is_brand_bundle "$path" || continue
    case "$path" in
      # An archive is not an install, and Xcode's Organizer needs it to upload again.
      *.xcarchive/*) echo "  skipping $path (Xcode archive)" ;;
      /Applications/* | "$HOME"/*) BUNDLES+=("$path") ;;
      *) echo "  skipping $path (outside /Applications and the home folder)" ;;
    esac
  done < <(candidate_paths | LC_ALL=C sort -u |
    awk '{ print (index($0, "/Applications/") == 1 ? 0 : 1) "\t" $0 }' |
    sort -s -t$'\t' -k1,1 | cut -f2-)
}

is_root_owned() {
  [[ "$(stat -f %u "$1")" != "$(id -u)" ]]
}

# Every data path of the brand, existing or not. The App Group is matched with any team prefix.
data_paths() {
  local dir name id
  for dir in "$HOME/Library/Group Containers"/* "$HOME/Library/Application Scripts"/*; do
    name="$(basename "$dir")"
    case "$name" in
      "group.$APPLICATION_ID" | *".group.$APPLICATION_ID") echo "$dir" ;;
    esac
  done
  for id in "${BUNDLE_IDS[@]}"; do
    echo "$HOME/Library/Containers/$id"
    echo "$HOME/Library/Application Scripts/$id"
    echo "$HOME/Library/Application Support/$id"
    echo "$HOME/Library/Caches/$id"
    echo "$HOME/Library/HTTPStorages/$id"
    echo "$HOME/Library/HTTPStorages/$id.binarycookies"
    echo "$HOME/Library/Preferences/$id.plist"
    echo "$HOME/Library/Saved Application State/$id.savedState"
    echo "$HOME/Library/WebKit/$id"
  done
}

existing_data_paths() {
  local path
  while IFS= read -r path; do
    [[ -e "$path" || -L "$path" ]] && echo "$path"
  done < <(data_paths)
}

cloud_storage_folders() {
  local dir
  for dir in "$HOME/Library/CloudStorage/${APP_NAME// /}"-*; do
    [[ -e "$dir" ]] && echo "$dir"
  done
}

# The host app and its embedded UI and daemon run from inside the bundle, the extension too. A
# daemon whose bundle is already gone keeps running under its launchd label, its bundle id.
process_pids() {
  {
    pgrep -f "/$APP_NAME\.app/Contents/"
    pgrep -f "^${DAEMON_BUNDLE_ID//./\\.}( |\$)"
  } | sort -u
}

stop_processes() {
  echo "-> Stopping processes"
  launchctl print "$GUI_DOMAIN/$DAEMON_BUNDLE_ID" >/dev/null 2>&1 &&
    run launchctl bootout "$GUI_DOMAIN/$DAEMON_BUNDLE_ID"
  local pids
  pids="$(process_pids | tr '\n' ' ')"
  [[ -n "${pids// /}" ]] || return 0
  # shellcheck disable=SC2086 # a list of pids
  run kill $pids
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -n "$(process_pids)" ]] || return 0
    sleep 1
  done
  pids="$(process_pids | tr '\n' ' ')"
  # shellcheck disable=SC2086 # a list of pids
  [[ -z "${pids// /}" ]] || run kill -9 $pids
}

# Scoped to the provider: an unscoped dump lists every item of every provider on the Mac. Captured
# first so an early-exiting grep cannot fail the pipeline.
domain_registered() {
  local dump
  dump="$(fileproviderctl dump -l "$EXTENSION_BUNDLE_ID" 2>/dev/null)"
  grep -q "^domain: $EXTENSION_BUNDLE_ID/" <<<"$dump"
}

# Only the app that owns the provider can remove its domain, and only that removal takes the
# synchronized folder and the system's copy of the tree with it. A build that predates the argument
# never exits, hence the bound.
remove_domain() {
  echo "-> Removing the File Provider domain"
  domain_registered || { echo "  no domain registered"; return 0; }
  local app
  for app in ${BUNDLES[@]+"${BUNDLES[@]}"}; do
    [[ "$(bundle_id_of "$app")" == "$BUNDLE_ID" ]] || continue
    run open -a "$app" --args "$REMOVE_DOMAIN_ARG"
    for _ in $(seq 1 60); do
      domain_registered || break
      sleep 1
    done
    stop_processes
    domain_registered || { echo "  domain removed"; return 0; }
    echo "  still registered after 60 s"
  done
  echo "  WARNING: no installed copy removed the domain"
}

# `lsregister -u` rejects an extension; pluginkit registers those and `finish` removes them.
unregister() {
  [[ "$1" == *.appex ]] || run "$LSREGISTER" -u "$1"
}

check() {
  local path blocked=0
  while IFS= read -r path; do
    [[ -d "$path" ]] || continue
    if ! ls "$path" >/dev/null 2>&1; then
      echo "  cannot read $path"
      blocked=1
    fi
  done < <(data_paths)
  [[ "$blocked" -eq 0 ]] || exit 3
}

scan() {
  local app path
  find_bundles
  for app in ${BUNDLES[@]+"${BUNDLES[@]}"}; do
    if [[ -e "$app/Contents/_MASReceipt" ]]; then
      result "App (TestFlight or App Store): $app"
    else
      result "App: $app"
    fi
  done
  while IFS= read -r path; do
    result "Synchronized folder, including changes not uploaded yet: $path"
  done < <(cloud_storage_folders)
  domain_registered && [[ -z "$(cloud_storage_folders)" ]] && result "File Provider registration"
  [[ -n "$(existing_data_paths)" ]] && result "Settings, login and downloaded data"
  [[ -n "$(process_pids)" ]] && result "Running processes"
  return 0
}

prepare() {
  local app nested ls_paths
  find_bundles
  stop_processes
  remove_domain
  stop_processes
  echo "-> Removing app bundles"
  ls_paths="$(launchservices_paths)"
  for app in ${BUNDLES[@]+"${BUNDLES[@]}"}; do
    # Unregistering a bundle leaves the apps embedded in it registered.
    while IFS= read -r nested; do
      [[ -n "$nested" ]] && unregister "$nested"
    done < <(awk -v prefix="$app/" 'index($0, prefix) == 1' <<<"$ls_paths")
    unregister "$app"
    if is_root_owned "$app"; then
      echo "  root-owned, left to the applet: $app"
      result "$app"
    else
      run rm -rf "$app"
    fi
  done
  for app in ${STALE[@]+"${STALE[@]}"}; do
    unregister "$app"
  done
  return 0
}

# Always exits 0: `do shell script` discards stdout on a non-zero exit, and with it the leftovers.
finish() {
  local path id
  echo "-> Deregistering pluginkit entries"
  # Removing one entry can make another visible.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    path="$(extension_paths | grep '\.appex$' | head -n1)"
    [[ -n "$path" ]] || break
    run pluginkit -r "$path"
  done

  echo "-> Removing data"
  for id in "${BUNDLE_IDS[@]}"; do
    # cfprefsd caches a domain and would write a deleted plist back.
    [[ -e "$HOME/Library/Preferences/$id.plist" ]] && run defaults delete "$id"
  done
  while IFS= read -r path; do
    run rm -rf "$path"
  done < <(existing_data_paths)

  # Makes fileproviderd forget the deregistered provider. Other providers (iCloud Drive, OneDrive)
  # reconnect on their own.
  echo "-> Restarting fileproviderd"
  run killall fileproviderd

  echo "-> Checking for leftovers"
  find_bundles
  for path in ${BUNDLES[@]+"${BUNDLES[@]}"}; do
    result "App: $path"
  done
  while IFS= read -r path; do
    result "Synchronized folder: $path"
  done < <(cloud_storage_folders)
  domain_registered && result "File Provider registration"
  [[ -n "$(extension_paths | grep '\.appex$')" ]] && result "File Provider extension registration"
  while IFS= read -r path; do
    result "Data: $path"
  done < <(existing_data_paths)
  [[ -n "$(process_pids)" ]] && result "Running processes"
  return 0
}

case "${1:-}" in
  check) check ;;
  scan) scan ;;
  prepare) prepare ;;
  finish) finish ;;
  *)
    echo "usage: $0 check|scan|prepare|finish" >&2
    exit 2
    ;;
esac
CLEANUP_SH_EOF
}

write_applescript() {
  cat <<'APPLESCRIPT_EOF'
-- Removes OX Drive from this Mac by running the bundled cleanup.sh one step at a time.
--
-- Deliberately free of `property` and `global`: an applet writes those back into its own bundle
-- when it quits, which breaks its signature and with it the Full Disk Access grant.

on run
	set appName to "OX Drive"
	set cleanerName to appName & " Cleaner"
	set cleanup to "/bin/bash " & quoted form of POSIX path of (path to resource "cleanup.sh") & " "
	set logFile to "~/Library/Logs/" & cleanerName & ".log"

	-- 1. Full Disk Access, checked before anything changes.
	try
		do shell script cleanup & "check"
	on error errorText number errorNumber
		if errorNumber is 3 then
			display dialog cleanerName & " needs Full Disk Access to remove the data of " & appName & ¬
				" from this Mac." & return & return & ¬
				"1. In the settings that open now, click \"+\" and choose \"" & cleanerName & "\" on your Desktop." & return & ¬
				"2. Turn it on." & return & ¬
				"3. Open " & cleanerName & " again." & return & return & ¬
				"If \"" & cleanerName & "\" is already listed, select it, remove it with \"−\" and add it again: " & ¬
				"a new version needs to be added anew." buttons {"Cancel", "Open Settings"} ¬
				default button "Open Settings" cancel button "Cancel" with title cleanerName with icon caution
			do shell script "open 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles'"
			do shell script "open -R " & quoted form of POSIX path of (path to me)
			return
		end if
		my fail(cleanerName, errorText, logFile)
		return
	end try

	-- 2. Show what goes and ask. The search takes several seconds.
	my showProgress("Looking for " & appName & "…", "", 0)
	set found to do shell script cleanup & "scan"
	my showProgress("", "", 0)
	if found is "" then
		display dialog appName & " is not installed on this Mac and left nothing behind." buttons {"OK"} ¬
			default button "OK" with title cleanerName
		return
	end if
	display dialog "This removes " & appName & " from this Mac:" & return & return & found & return & return & ¬
		"Files in the synchronized folder that were not uploaded yet are lost. Quit the apps that use files " & ¬
		"from it first." buttons {"Cancel", "Remove"} default button "Cancel" cancel button "Cancel" ¬
		with title cleanerName with icon caution

	-- 3. Remove. Store installs belong to root, which only the step in between runs as.
	set progress total steps to 3
	set removing to "Removing " & appName & "…"
	try
		my showProgress(removing, "Stopping " & appName & " and removing its folder from Finder", 0)
		set rootOwned to paragraphs of (do shell script cleanup & "prepare")

		if rootOwned is not {} then
			my showProgress(removing, "Removing the app", 1)
			set removal to "rm -rf"
			repeat with bundlePath in rootOwned
				set removal to removal & " " & quoted form of (contents of bundlePath)
			end repeat
			do shell script removal with prompt cleanerName & " needs your password to remove " & appName & ¬
				" from the Applications folder." with administrator privileges
		end if

		my showProgress(removing, "Removing data", 2)
		set leftovers to do shell script cleanup & "finish"
		-- The window stays open next to the report until the applet quits.
		my showProgress("Finished", "", 3)
	on error errorText number errorNumber
		if errorNumber is -128 then
			display dialog "Cancelled. " & appName & " may be partly removed; open " & cleanerName & ¬
				" again to finish." buttons {"OK"} default button "OK" with title cleanerName with icon caution
			return
		end if
		my fail(cleanerName, errorText, logFile)
		return
	end try

	-- 4. Report.
	if leftovers is "" then
		display dialog appName & " has been removed." & return & return & ¬
			"Restart your Mac to remove it from Login Items as well." & return & return & ¬
			"Afterwards, remove \"" & cleanerName & "\" from Full Disk Access in System Settings and move it " & ¬
			"to the Trash." buttons {"OK"} default button "OK" with title cleanerName
	else
		display dialog "Some parts of " & appName & " could not be removed:" & return & return & leftovers & ¬
			return & return & "Restart your Mac and open " & cleanerName & " again. If this persists, send " & ¬
			logFile & " to your contact." buttons {"OK"} default button "OK" with title cleanerName with icon caution
	end if
end run

-- An applet redraws its progress window only while idle, which a blocking `do shell script` never
-- is: without the delay each update would show up one step late.
on showProgress(descriptionText, stepText, completedSteps)
	set progress description to descriptionText
	set progress additional description to stepText
	set progress completed steps to completedSteps
	delay 0.1
end showProgress

on fail(cleanerName, errorText, logFile)
	display dialog "Something went wrong:" & return & return & errorText & return & return & ¬
		"Details are in " & logFile & "." buttons {"OK"} default button "OK" with title cleanerName with icon stop
end fail
APPLESCRIPT_EOF
}

# Called last, so a download cut short by `curl | bash` runs nothing.
main </dev/null
