#!/bin/bash

VERSION=0.1

version() {
  printf '%s version %s\n' "$BASENAME" "$VERSION"
}

usage() {
  printf 'Usage: %s [OPTIONS] -i ISO\n' "$BASENAME"
}

help() {
  version
  usage
  cat << EOF

Build a docker image using a Lunar-Linux ISO. By default, will create an image
named "lunar-linux-<arch>" with the "latest" and ISO version tags. Optionally
tag and push to a remote repository.

${C_BLD}Must be run as root.${C_OFF}

  -i, --iso=FILE          Required. Lunar-Linux ISO to use.
  -n, --name=STRING       Name of the image to build. (Default: lunar-linux)

  -r, --remote=HOST/REPO  Tag image for remote repository. Please provide full
                          host, path, and image name. Tags will also be applied.
                          NOTE: Authorization is not handled for you.
  -p, --push              Initiate docker push after image is built.

  -t, --tag=STRING        Docker tag to build. (Default: latest)
  -e, --extratag=STRING   Tag the new image with an additional tag.
  -s, --suffix=STRING     Apply a suffix to the docker image name.
  -T, --targetdir=PATH    Temporary working directory to build the image.

  --stop-iso              Unknown.

  -v, --version           Display script version.
  -h, --help              This help.

EOF
}

error() {
  MSG="ERROR: $1\n"; shift
  printf "$MSG" "$@" >&2
  exit 1
}

chroot_run() {
  local RESULT

  chroot $TARGET "$@"
  RESULT=$?

  # debug the problem in case there is one
  if [[ $RESULT -eq 1 ]] ; then
    (
      cat << EOF

${C_RED}ERROR: An error occurred while executing a command. The command was:
ERROR: "${C_OFF}$@${C_RED}"
ERROR:
ERROR: You should inspect any output above and retry the command with
ERROR: different input or parameters. Please report the problem if
ERROR: you think this error is displayed by mistake.${C_OFF}

${C_BLD}Press ENTER to continue${C_OFF}
EOF
    read JUNK
    ) >&2
  fi
  return $RESULT
}

transfer_package() {
  printf "${C_CLN}Transfering %s..." "$1"
  cd $TARGET                          &&
  LINE=$(grep "^$1:" $PACKAGES_LIST)  &&
  MOD=$(echo $LINE | cut -d: -f1)     &&
  VER=$(echo $LINE | cut -d: -f4)     &&
  tar xJf "$ROOTFS"/var/cache/lunar/$MOD-$VER-*.tar.xz 2> /dev/null           &&
  echo $LINE >> $TARGET/var/state/lunar/packages                              &&
  cp $TARGET/var/state/lunar/packages $TARGET/var/state/lunar/packages.backup
}


main() {
  local ISOMNT SQFSMNT PACKAGES_LIST MOONBASE_TAR

  cleanup() {
    cd /tmp
    for m in $ROOTFS $SQFSMNT $ISOMNT; do
      umount -f $m &> /dev/null
      rm -r "$m"
    done
    rm -rf "$TARGET"
  }

  trap "cleanup; exit 1" INT TERM KILL

  ISOMNT=$(mktemp -d /tmp/lunar-docker-iso.XXXXXX)
  SQFSMNT=$(mktemp -d /tmp/lunar-docker-sqfs.XXXXXX)
  export ROOTFS=$(mktemp -d /tmp/lunar-docker-rootfs.XXXXXX)
  export TARGET=${TARGET:-$(mktemp -d /tmp/lunar-docker.XXXXXX)}
  PACKAGES_LIST="$ROOTFS"/var/cache/lunar/packages
  MOONBASE_TAR="$ROOTFS"/usr/share/lunar-install/moonbase.tar.bz2

  if ! mount -o ro,loop $LUNAR_ISO $ISOMNT; then
    error "Failed to mount ISO: %s" "$LUNAR_ISO"
  else
    echo "Mounting $LUNAR_ISO at $ISOMNT"
  fi

  if ! mount -o ro,loop "$ISOMNT"/LiveOS/squashfs.img $SQFSMNT; then
    error "Failed to mount %s/LiveOS/squashfs.img, is this really a Lunar Linux ISO?" "$ISOMNT"
  else
    echo "Mounting squashfs.img at $SQFSMNT"
  fi

  if ! mount -o ro,loop "$SQFSMNT"/LiveOS/rootfs.img $ROOTFS; then
    error "Failed to mount %s/LiveOS/rootfs.img, is this really a Lunar Linux ISO?" "$SQFSMNT"
  else
    echo "Mounting rootfs.img at $ROOTFS"
  fi

  if [[ -n "$STOP_ISO_TARGET" ]]; then
    cd $ROOTFS
    bash
    exit 1
  fi

  cd $TARGET

  mkdir -p bin boot dev etc home lib mnt media
  mkdir -p proc root sbin srv tmp usr var opt
  mkdir -p sys
  if [[ `arch` == "x86_64" ]]; then
    ln -sf lib lib64
    ln -sf lib usr/lib64
  fi
  mkdir -p usr/{bin,games,include,lib,libexec,local,sbin,share,src}
  mkdir -p usr/share/{dict,doc,info,locale,man,misc,terminfo,zoneinfo}
  mkdir -p usr/share/man/man{1..8}
  ln -sf share/doc usr/doc
  ln -sf share/man usr/man
  ln -sf share/info usr/info
  mkdir -p etc/lunar/local/depends
  mkdir -p run/lock
  ln -sf ../run var/run
  ln -sf ../run/lock var/lock
  mkdir -p var/log/lunar/{install,md5sum,compile,queue}
  mkdir -p var/{cache,empty,lib,log,spool,state,tmp}
  mkdir -p var/{cache,lib,log,spool,state}/lunar
  mkdir -p var/state/discover
  mkdir -p var/spool/mail
  mkdir -p media/{cdrom0,cdrom1,floppy0,floppy1,mem0,mem1}
  chmod 0700 root
  chmod 1777 tmp var/tmp

  if [[ -f "$ROOTFS"/var/cache/lunar/aaa_base.tar.xz ]]; then
    tar xJf "$ROOTFS"/var/cache/lunar/aaa_base.tar.xz 2> /dev/null
  fi
  if [[ -f "$ROOTFS"/var/cache/lunar/aaa_dev.tar.xz ]]; then
    tar xJf "$ROOTFS"/var/cache/lunar/aaa_dev.tar.xz 2> /dev/null
  fi

  for LINE in $(cat $PACKAGES_LIST | grep -v -e '^lilo:' -e '^grub:' -e '^grub2:' -e '^linux:' -e '^linux-firmware') ; do
    MOD=$(echo $LINE | cut -d: -f1)
    VER=$(echo $LINE | cut -d: -f4)
    SIZ=$(echo $LINE | cut -d: -f5)
    transfer_package $MOD
  done
  printf "${C_CLN}"

  DATE=$(date +%Y%m%d)

  (
    cd $TARGET/var/lib/lunar
    tar xjf $MOONBASE_TAR 2> /dev/null
    tar j --list -f $MOONBASE_TAR | sed 's:^:/var/lib/lunar/:g' > $TARGET/var/log/lunar/install/moonbase-$DATE
    mkdir -p moonbase/zlocal
  )
  echo "moonbase:$DATE:installed:$DATE:37000KB" >> $TARGET/var/state/lunar/packages
  cp "$TARGET"/var/state/lunar/packages       $TARGET/var/state/lunar/packages.backup
  cp "$ROOTFS"/var/state/lunar/depends        $TARGET/var/state/lunar/
  cp "$ROOTFS"/var/state/lunar/depends.backup $TARGET/var/state/lunar/

  chroot_run lsh create_module_index
  chroot_run lsh create_depends_cache

  # more moonbase related stuff
  chroot_run lsh update_plugins

  # just to make sure
  chroot_run ldconfig

  # pass through some of the configuration at this point:
  chroot_run systemd-machine-id-setup 2> /dev/null
  printf 'KEYMAP=%s\nFONT=%s' "$KEYMAP" "$CONSOLEFONT" > $TARGET/etc/vconsole.conf
  printf 'LANG=%s\nLC_ALL=%s' "${LANG:-en_US.utf8}" "${LANG:-en_US.utf8}" > $TARGET/etc/locale.conf
  [[ -z "$EDITOR" ]] || printf 'export EDITOR="%s"' "$EDITOR" > $TARGET/etc/profile.d/editor.rc

  # some more missing files:
  cp "$ROOTFS"/etc/lsb-release  $TARGET/etc/
  cp "$ROOTFS"/etc/os-release   $TARGET/etc/
  cp "$ROOTFS"/etc/issue{,.net} $TARGET/etc/

  # Some sane defaults
  GCCVER=$(chroot_run lvu installed gcc | awk -F\. '{ print $1"_"$2 }')

  cat << EOF > $TARGET/etc/lunar/local/config
LUNAR_COMPILER="GCC_$GCCVER"
LUNAR_ALIAS_SSL="openssl"
LUNAR_ALIAS_OSSL="openssl"
LUNAR_ALIAS_UDEV="systemd"
LUNAR_ALIAS_KMOD="kmod"
LUNAR_ALIAS_UDEV="systemd"
LUNAR_ALIAS_KERNEL_HEADERS="kernel-headers"
BOOTLOADER="none"
LUNAR_RESTART_SERVICES=off
EOF

  # Disable services (user can choose to enable them using services menu)
  rm -f $TARGET/etc/systemd/system/network.target.wants/wpa_supplicant.service
  rm -f $TARGET/etc/systemd/system/sockets.target.wants/sshd.socket

  # root user skel files
  find $TARGET/etc/skel ! -type d -print0 | xargs -0i cp '{}' $TARGET/root

  # Create docker image based on $TARGET
  cd $TARGET
  . etc/lsb-release

  [[ "$ARCH" -eq 1 ]] && ARCH="-${DISTRIB_RELEASE##*-}" || ARCH=""
  VERSION="${DISTRIB_RELEASE%-*}"
  ARCH="${ARCH/_/-}"
  IMAGE_NAME="${IMAGE_NAME}${ARCH}${IMAGE_SUFFIX}"

  echo "Importing docker image (${VERSION})..."
  tar -c . | docker import - "${IMAGE_NAME}${IMAGE_SUFFIX}:${VERSION}"

  # tag latest
  echo "Tagging image (${TAG})..."
  docker tag "${IMAGE_NAME}:${VERSION}" "${IMAGE_NAME}:${TAG}"

  # extra tag
  if [[ -n "$EXTRATAG" ]]; then
    echo "Tagging image (${EXTRATAG})..."
    docker tag "${IMAGE_NAME}:${VERSION}" "${IMAGE_NAME}:${EXTRATAG}"
  fi

  # remote repository
  if [[ -n "$REMOTE" ]]; then
    echo "Tagging remote image(s)..."
    docker tag "${IMAGE_NAME}:${VERSION}" "${REMOTE}:${TAG}"

    if [[ -n "$EXTRATAG" ]]; then
      docker tag "${IMAGE_NAME}:${VERSION}" "${REMOTE}:${EXTRATAG}"
    fi

    # push to repo
    if [[ "$PUSH" -eq 1 ]]; then
      echo "Pushing image(s)..."
      docker push "${IMAGE_NAME}:${TAG}"

      if [[ -n "$EXTRATAG" ]]; then
        docker push "${IMAGE_NAME}:${EXTRATAG}"
      fi
    fi
  fi

  docker images | grep -F "${IMAGE_NAME}"

  printf "Cleaning up..."
  cleanup
  echo "done."
}

# colors, disabled if not on a terminal
if [[ -t 1 ]]; then
  export C_BLD=$'\e[1m' C_RED=$'\e[31m' C_OFF=$'\e[0m' C_CLN=$'\e[0E\e[K'
else
  export C_BLD='' C_RED='' C_OFF='' C_CLN=''
fi

BASENAME=`basename "$0"`
GETOPT_ARGS=$(getopt -q -n $BASENAME -o "e:hi:n:pr:s:t:T:v" -l "extratag:,help,iso:,name:,push,remote:,suffix:,stop-iso,targetdir:,version" -- "$@")

if [[ -z "$?" ]]; then
  version
  usage
  exit
else
  if [[ $UID -ne 0 ]]; then
    error "User must have root privileges to run this script"
  fi

  eval set -- $GETOPT_ARGS

  ARCH=1
  IMAGE_NAME=lunar-linux
  TAG=latest
  PUSH=0

  while true; do
    case "$1" in
      -e|--extratag)  EXTRATAG=$2; shift 2 ;;
      -i|--iso)       LUNAR_ISO=$2; shift 2 ;;
      -n|--name)      IMAGE_NAME=$2; shift 2 ;;
      -N|--no-arch)   ARCH=0; shift 1 ;;
      -p|--push)      PUSH=1; shift 2 ;;
      -r|--remote)    REMOTE=$2; shift 2 ;;
      -s|--suffix)    IMAGE_SUFFIX=$2; shift 2 ;;
      -T|--targetdir) TARGET=$2; shift 2 ;;
      -t|--tag)       TAG=$2; shift 2 ;;

      --stop-iso)     STOP_ISO_TARGET=1; shift 1 ;;

      -v|--version)   version; exit 1 ;;
      -h|--help)      help; exit 1 ;;
      --)             shift; break ;;
      *)              help; exit 1 ;;
    esac
  done

  export ARCH EXTRATAG IMAGE_NAME IMAGE_SUFFIX LUNAR_ISO PUSH REMOTE \
         STOP_ISO_TARGET TAG TARGET

  if [[ -z "$LUNAR_ISO" ]]; then
    usage
    exit 1
  fi

  if [[ ! -f "$LUNAR_ISO" ]]; then
    error "File not found: %s" "$LUNAR_ISO"
  fi

  version
  main $@
fi
