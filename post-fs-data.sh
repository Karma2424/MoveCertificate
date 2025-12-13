#!/system/bin/sh
# Do NOT assume where your module will be located.
# ALWAYS use $MODDIR if you need to know where this script
# and module is placed.
# This will make sure your module will still work
# if Magisk change its mount point in the future
MODDIR=${0%/*}
PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH
SUSFS_BIN="/data/adb/ksu/bin/ksu_susfs"

# This script will be executed in post-fs-data mode
# add logcat
LOG_PATH="$MODDIR/install.log"
LOG_TAG="iyue"

# Keep only one up-to-date log
echo "[$LOG_TAG] Keep only one up-to-date log" >$LOG_PATH

print_log() {
    echo "[$LOG_TAG] $@" >>$LOG_PATH
}

# ksu+susfs operating_mode
# handle probing for susfs 1.5.3+
susfs_found=false
if [ "$KSU" = true ] && [ -f ${SUSFS_BIN} ] &&
    ${SUSFS_BIN} show enabled_features | grep -q "CONFIG_KSU_SUSFS_TRY_UMOUNT" >/dev/null 2>&1; then
    print_log "susfs with try_umount found!"
    susfs_found=true
fi

print_log "Injecting certificates"

# Create a separate temp directory, to hold the current certificates
# Without this, when we add the mount we can't read the current certs anymore.
mkdir -p $MODDIR/certificates
chmod 700 $MODDIR/certificates
rm -rf $MODDIR/certificates/*

# Copy out the existing certificates
if [ -d "/apex/com.android.conscrypt/cacerts" ]; then
    cp /apex/com.android.conscrypt/cacerts/* $MODDIR/certificates/
else
    cp /system/etc/security/cacerts/* $MODDIR/certificates/
fi

# Create the in-memory mount on top of the system certs folder
mount -t tmpfs tmpfs /system/etc/security/cacerts

# Copy our new cert in, so we trust that too
cp -f /data/local/tmp/cert/* $MODDIR/certificates/

# Copy the existing certs back into the tmpfs mount, so we keep trusting them
mv $MODDIR/certificates/* /system/etc/security/cacerts/

# Update the perms & selinux context labels, so everything is as readable as before
chown root:root /system/etc/security/cacerts/*
chmod 644 /system/etc/security/cacerts/*

chcon u:object_r:system_file:s0 /system/etc/security/cacerts/
chcon u:object_r:system_file:s0 /system/etc/security/cacerts/*

print_log 'System cacerts setup completed'

# Deal with the APEX overrides in Android 14+, which need injecting into each namespace:
if [ -d "/apex/com.android.conscrypt/cacerts" ]; then
    print_log 'Injecting certificates into APEX cacerts'

    # When the APEX manages cacerts, we need to mount them at that path too. We can't do
    # this globally as APEX mounts are namespaced per process, so we need to inject a
    # bind mount for this directory into every mount namespace.

    # First we mount for the shell itself, for completeness and so we can see this
    # when we check for correct installation on later runs
    mount --bind /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts

    # First we get the Zygote process(es), which launch each app
    ZYGOTE_PID=$(pidof zygote || true)
    ZYGOTE64_PID=$(pidof zygote64 || true)
    Z_PIDS="$ZYGOTE_PID $ZYGOTE64_PID"
    # N.b. some devices appear to have both, some have >1 of each (!)

    # Apps inherit the Zygote's mounts at startup, so we inject here to ensure all newly
    # started apps will see these certs straight away:
    for Z_PID in $Z_PIDS; do
        if [ -n "$Z_PID" ]; then
            nsenter --mount=/proc/$Z_PID/ns/mnt -- \
                /bin/mount --bind /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts
        fi
    done

    print_log 'Zygote APEX certificates remounted'
fi
    
if [ "$susfs_found" = true ]; then
    ${SUSFS_BIN} add_try_umount "/system/etc/security/cacerts" 1
    print_log "mode ksu_susfs_bind"
else
    print_log "mode normal"
fi

# Delete the temp cert directory
rm -r $MODDIR/certificates

print_log "System cert successfully injected"
