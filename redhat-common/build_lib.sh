#!/bin/bash
# This is sourced by the RHEL release specific build extras to provide common
# RHEL build functionality.


# OS information for the OS we are building crowbar on to.
OS_TOKEN="$OS-$OS_VERSION"
PKG_TYPE="rpms"
PKG_ALLOWED_ARCHES=("x86_64" "noarch")
CHROOT_PKGDIR="var/cache/yum"
CHROOT_GEMDIR="usr/lib/ruby/gems/1.8/cache"
OS_METADATA_PKGS="createrepo"
declare -A SEEN_RPMS

# we need extglobs, so enable them.
shopt -s extglob

# Have the chroot update its package metadata
chroot_update() { in_chroot /usr/bin/yum -y makecache; }

# Install some packages in the chroot environment.
chroot_install() {
    if [[ $1 ]]; then
        in_chroot /usr/bin/yum -y install "$@"
    fi
    in_chroot /usr/bin/yum -y update
}

install_rubygems() {
    in_chroot which gem &>/dev/null && return 0
    chroot_install rubygems ruby-devel make gcc kernel-devel
}

# Fetch (but do not install) packages into the chroot environment
chroot_fetch() {
    local p
    for p in "$@"; do
        in_chroot /usr/bin/yum -y --downloadonly install "$p" || :
    done
    in_chroot /usr/bin/yum -y update
}

# Make a repository file in the chroot environment.  We use this when we get a URL
# from one of the packages files (as opposed to an RPM that contains repo info.
make_repo_file() {
    # $1 = name of repo
    # $2 = Priority
    # $3 = URL
    [[ -f "$CHROOT/etc/yum.repos.d/repo-$1.repo" ]] && return
    local repo=$(mktemp "/tmp/repo-$1-XXXX.repo")
    cat >"$repo" <<EOF
[$1]
name=Repo for $1
baseurl=$3
enabled=1
gpgcheck=0
EOF
    if [[ $RPM_PRIORITIES ]]; then
        echo "priority=$2" >>"$repo"
    fi
    sudo cp "$repo" "$CHROOT/etc/yum.repos.d/repo-$1.repo"
    rm "$repo"
}

# Add repositories to the chroot environment.
# This also add proxy information if needed.
add_repos() {
    for repo in "$@"; do
        rtype="${repo%% *}"
        rdest="${repo#* }"
        case $rtype in
            rpm) rdest="${rdest#* }"
                f="$(mktemp /tmp/tmp-XXXXXX.rpm)"
                curl -L -o "$f" "$rdest"
                sudo cp "$f" "$CHROOT/tmp"
                rm "$f"
                in_chroot /bin/rpm -Uvh "$f";;
            bare) make_repo_file $rdest;;
        esac
    done
    [[ $USE_PROXY = "1" ]] || return 0
    (   cd "$CHROOT"
        for f in etc/yum.repos.d/*; do
            [[ -f "$f" ]] || continue
            in_chroot /bin/grep -q "'^proxy='" "/$f" && continue
            in_chroot /bin/grep -q "'^baseurl=http://.*127\.0\.0\.1.*'" "/$f" && \
                continue
            in_chroot sed -i "'/^name/ a\proxy=http://$PROXY_HOST:$PROXY_PORT'" "$f"
            [[ $PROXY_USER ]] && \
                in_chroot sed -i "'/^proxy/ a\proxy_username=$PROXY_USER'" "$f"
            [[ $PROXY_PASSWORD ]] && \
                in_chroot sed -i "'^/proxy_username/ a\proxy_password=$PROXY_PASSWORD'" "$f"
            : ;
        done
    )
}

# Check to see if something is a valid RPM package name.
is_pkg() { [[ $1 = *.rpm ]]; }

__barclamp_pkg_metadata_needs_update() (
    cd "$CACHE_DIR/barclamps/$1/$OS_TOKEN/pkgs"
    [[ -d repodata ]] || return 0
    while read fname; do
        [[ $fname -nt . ]] && return 0
    done < <(find . -name '*.rpm' -type f)
    return 1
)

__make_barclamp_pkg_metadata () {
    in_chroot "cd /mnt; createrepo -d -q ."
    sudo chown -R "$(whoami)" "$CACHE_DIR/barclamps/$bc/$OS_TOKEN/pkgs"
    touch "$CACHE_DIR/barclamps/$bc/$OS_TOKEN/pkgs/repodata"
    if [[ $CURRENT_CACHE_BRANCH ]]; then
        CACHE_NEEDS_COMMIT=true
        in_cache git add "barclamps/$bc/$OS_TOKEN/pkgs/repodata"
    fi
}

add_offline_repos() (
    in_chroot mkdir -p /etc/yum.repos.d
    for bc in "${BARCLAMPS[@]}"; do
        [[ -d $CACHE_DIR/barclamps/$bc/$OS_TOKEN/pkgs/repodata ]] || continue
        sudo mkdir -p "$CHROOT/packages/barclamps/$bc"
        sudo mount --bind "$CACHE_DIR/barclamps/$bc/$OS_TOKEN/pkgs" \
            "$CHROOT/packages/barclamps/$bc"
        make_repo_file "barclamp-$bc" 99 "file:///packages/barclamps/$bc"
    done
)

# For Fedora 17 and later packages are stored in subdirectories bucketed by
# the first letter of the package name and lower cased
__pkg_location() {
    if [ "$OS" = "fedora" -a $OS_VERSION = 18 ]; then
	lowercase_pkg=${pkg,,}
        echo "$(find_cd_pool)/${lowercase_pkg:0:1}/$pkg"
    else
	echo "$(find_cd_pool)/$pkg"
    fi
}

# This function makes a functional centos chroot environment.
# We do this so that we can build an install DVD that has Crowbar staged
# on it without having to have a handy Redhat/CentOS environment to build from.
# It also makes sure that even if we do, we don't inadvertently wind up installing
# packages on the build system by mistake.
__make_chroot() {
    postcmds=()
    # Install basic packages.
      for pkg in "${OS_BASIC_PACKAGES[@]}"; do
         for f in "$(__pkg_location)"-[0-9]*+(noarch|x86_64).rpm; do
            rpm2cpio "$f" | \
                (cd "$CHROOT"; sudo cpio --extract \
                --make-directories --no-absolute-filenames \
                --preserve-modification-time)
        done
        if [[ $pkg =~ (centos|redhat|fedora)-release ]]; then
            sudo mkdir -p "$CHROOT/tmp"
            sudo cp "$f" "$CHROOT/tmp/${f##*/}"
            postcmds+=("/bin/rpm -ivh --force --nodeps /tmp/${f##*/}")
        fi
    done
    # install priorities support
    mkdir -p "$CACHE_DIR/$OS_TOKEN/pkgs"
    if [[ $PRIORITIES_RPM ]]; then
        [[ -f $CACHE_DIR/$OS_TOKEN/pkgs/$PRIORITIES_RPM ]] || \
            curl -o "$CACHE_DIR/$OS_TOKEN/pkgs/$PRIORITIES_RPM" \
            "$PRIORITIES_HTTP"
        rpm2cpio "$CACHE_DIR/$OS_TOKEN/pkgs/$PRIORITIES_RPM" | \
            ( cd "$CHROOT"; sudo cpio --extract \
            --make-directories --no-absolute-filenames \
            --preserve-modification-time)
    fi
    # fix up the chroot to make sure we can use it
    sudo cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"
    sudo rm -f "$CHROOT/etc/yum.repos.d/"*
    for d in /proc /sys /dev /dev/pts /dev/shm; do
        [[ -L $d ]] && d="$(readlink -f "$d")"
        sudo mkdir -p "${CHROOT}$d"
        sudo mount --bind "$d" "${CHROOT}$d"
    done
    # third, run any post cmds we got earlier
    for cmd in "${postcmds[@]}"; do
        in_chroot $cmd
    done
    # Work around packages we don't have, but that the yum bootstrap
    # will grab for us.
    in_chroot mkdir -p "/usr/lib/python2.4/site-packages/urlgrabber.broke"
    for f in "$CHROOT/usr/lib/python2.4/site-packages/urlgrabber/keepalive"*; do
        in_chroot mv "${f#$CHROOT}" \
            "/usr/lib/python2.4/site-packages/urlgrabber.broke/"
    done
    # Make sure yum does not throw away our caches for any reason.
    in_chroot /bin/sed -i -e "'/keepcache/ s/0/1/'" /etc/yum.conf
    in_chroot "echo 'exclude = *.i?86' >>/etc/yum.conf"

    [[ $USE_PROXY = "1" ]] && (
        cd "$CHROOT"
        for f in etc/yum.repos.d/*; do
            [[ -f "$f" ]] || continue
            in_chroot /bin/grep -q "'^proxy='" "/$f" && continue
            in_chroot /bin/grep -q "'^baseurl=http://.*127\.0\.0\.1.*'" "/$f" && \
                continue
            in_chroot sed -i "'/^name/ a\proxy=http://$PROXY_HOST:$PROXY_PORT'" "$f"
            [[ $PROXY_USER ]] && \
                in_chroot sed -i "'/^proxy/ a\proxy_username=$PROXY_USER'" "$f"
            [[ $PROXY_PASSWORD ]] && \
                in_chroot sed -i "'^/proxy_username/ a\proxy_password=$PROXY_PASSWORD'" "$f"
            : ;
        done
    )
    # Make sure that the bootstrap only uses local data off the install DVD.
    in_chroot mv /etc/yum.repos.d /etc/yum.repos.d.old
    in_chroot mkdir -p /etc/yum.repos.d/
    in_chroot mkdir -p /packages/base
    sudo mount --bind "$IMAGE_DIR" "$CHROOT/packages/base"
    make_repo_file redhat-base 99 "file:///packages/base/$OS_REPO_POOL"
    # have yum bootstrap everything else into usefulness
    in_chroot yum -y install yum yum-downloadonly createrepo
    # Once we have the chroot bootstrapped, restore the CentOS repos.
    # If we are using a proxy, fastestmirror usually does the Wrong Thing.
    [[ $USE_PROXY = 1 && \
        -f $CHROOT/etc/yum/pluginconf.d/fastestmirror.conf ]] && \
        in_chroot sed -ie "'/^enabled/ s/1/0/'" \
        /etc/yum/pluginconf.d/fastestmirror.conf
    if [[ $ALLOW_CACHE_UPDATE = true ]]; then
        in_chroot 'cp /etc/yum.repos.d.old/* /etc/yum.repos.d'
    fi
    if [[ -f $CHROOT/etc/yum.conf ]]; then
        in_chroot 'echo "exclude=centos-release redhat-release" >>/etc/yum.conf'
    else
        in_chroot 'printf "[main]\nexclude=centos-release redhat-release" >/etc/yum.conf'
    fi
}

# Extract version information from an RPM file
rpmver() {
    [[ -f $1 && $1 = *.rpm ]] || die "$1 is not an rpm!"
    if [[ ! ${SEEN_RPMS["${1##*/}"]} ]]; then
        local ver=$(rpm --queryformat \
            '%{NAME}.%{ARCH} %{EPOCH}:%{VERSION}-%{RELEASE}' \
            --nodigest --nosignature -qp "$1")
        SEEN_RPMS["${1##*/}"]="${ver// (none):/ }"
    fi
    echo "${SEEN_RPMS["${1##*/}"]}"
}

# Get a package name in the form of $name-$arch
pkg_name() {
    local res="$(rpmver "$1")"
    echo "${res% *}"
}

# Copy our isolinux bits into place and append our kickstarts into the initrds.
final_build_fixups() {
    # Copy our isolinux files.
    debug "Updating the isolinux boot information"
    mv "$BUILD_DIR/extra/isolinux" "$BUILD_DIR"
    # Add our kickstart files into the initrd images.
    debug "Adding our kickstarts to the initrd images."
    (cd "$IMAGE_DIR"; find -name initrd.img |cpio -o) | \
        (cd "$BUILD_DIR"; cpio -i --make-directories)
    chmod -R u+rw "$BUILD_DIR"
    (cd "$BUILD_DIR/extra"; find . -name '*.ks' | \
        cpio --create --format=newc 2>/dev/null | \
                gzip -9 > "initrd.img.append"
        cat "initrd.img.append" >> "../isolinux/initrd.img"
        cat "initrd.img.append" >> "../images/pxeboot/initrd.img")
}

__check_all_deps() {
    local pkgname pkg token rest bc ok
    for pkgname in "$@"; do
        local -A deps
        [[ ${touched_pkgs["$pkgname"]} ]] && continue
        #debug "Checking dependencies for $pkgname"
        while read token rest; do
            pkg=${rest% *}
            ok=false
            # We only care about certian arches.
            for rest in "${PKG_ALLOWED_ARCHES[@]}"; do
                [[ $pkg = *.$rest ]] || continue
                ok=true
                break
            done
            [[ $ok = true ]] || continue
            case $token in
                package:)
                    [[ ${CD_POOL["${pkg}"]} && \
                        ! ${INSTALLED_PKGS["${pkg}"]} ]] || continue
                    #debug "Staging depended upon package $pkg"
                    INSTALLED_PKGS["${pkg}"]="true"
                    touched_pkgs["${pkg}"]="true";;
                provider:) [[ ${seen_deps["$pkg"]} ]] && continue
                    #debug "Will check dependent package ${pkg} for $pkgname"
                    INSTALLED_PKGS["${pkg}"]="true"
                    seen_deps["$pkg"]="true"
                    deps["${pkg}"]="true";;
                *) continue;;
            esac
        done < <(in_chroot yum -C deplist "$pkgname")
        [[ ${!deps[*]} ]] && __check_all_deps "${!deps[@]}"
        unset deps
        # Add ourselves to the installed_pkgs array if we woud not
        # have been processed by yum above.
        for rest in "${PKG_ALLOWED_ARCHES[@]}"; do
            [[ $pkgname = *.$rest ]] || continue
            INSTALLED_PKGS["$pkgname"]="true"
            break
        done
        printf '.' >&2
    done
}

check_all_deps() {
    local -A touched_pkgs
    local -A seen_deps
    debug "Analyzing dependencies for shrinking the install ISO."
    __check_all_deps "$@"
}

# Throw away packages we will not need on the install media
shrink_iso() {
    # Do nothing if we do not have a minimal-install set for this OS.
    [[ -f $CROWBAR_DIR/$OS_TOKEN-extra/minimal-install ]] || \
        return 0
    local pkgname pkgver compfile
    local -a minimal to_copy
    while read pkgname pkgver; do
        minimal+=("$pkgname")
    done < "$CROWBAR_DIR/$OS_TOKEN-extra/minimal-install"
    mkdir -p "$BUILD_DIR/Packages"
    cp -a "$IMAGE_DIR/repodata" "$BUILD_DIR"
    make_chroot
    # Make sure all our dependencies will be staged.
    check_all_deps $(printf "%s\n" "${minimal[@]}" \
        $(for bc in "${BARCLAMPS[@]}"; do echo ${BC_PKGS[$bc]}; done) | \
        sort -u)
    for pkgname in "${!INSTALLED_PKGS[@]}"; do
        [[ -f ${CD_POOL["$pkgname"]} ]] || continue
        to_copy+=("${CD_POOL["$pkgname"]}")
    done
    debug "Final ISO default CD pool will be shrunk down to:"
    printf "  %s\n" "${to_copy[@]##*/}" |sort >&2
    if [[ $OS = fedora ]]; then
        for pkgname in "${to_copy[@]}"; do
            # Reorganize packages for fedora ver > 17
            lowercase_pkgname="${pkgname,,}"
            mkdir -p "$BUILD_DIR/Packages/${lowercase_pkgname:0:1}"
            cp "${CD_POOL["$pkgname"]}" "$BUILD_DIR/Packages/${lowercase_pkgname:0:1}"
        done
    else
        cp "${to_copy[@]}" "$BUILD_DIR/Packages"
    fi
    sudo mount --bind "$BUILD_DIR" "$CHROOT/mnt"
    compfile=$(in_chroot find /mnt/repodata -name '*-comps*.xml')
    in_chroot "cd /mnt; createrepo -g  \"$compfile\" ."
    sudo umount -l "$CHROOT/mnt"
    sudo mount -t tmpfs -o size=1K tmpfs "$IMAGE_DIR/Packages"
    sudo mount -t tmpfs -o size=1K tmpfs "$IMAGE_DIR/repodata"
}

generate_minimal_install() { : ; }

# Check to make sure our required commands are installed.
for cmd in rpm; do
    which "$cmd" &>/dev/null || \
        die 1 "Please install $cmd before trying to build Crowbar."
done
