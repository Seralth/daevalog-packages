#!/usr/bin/env bash
# Builds the signed pacman, apt and rpm repositories from one run of the
# Daevalog "Linux packages" workflow, adds the Windows installer from the
# "Windows" run of the same commit, and publishes them as branch main.
#
#   ./publish.sh [--legacy <dir>] <run id>             build, then replace main with one commit
#   ./publish.sh --out <dir> [--legacy <dir>] <run id> build into <dir> only, publish nothing
#   ./publish.sh --out <dir> [--legacy <dir>] --from <dir>
#                                                      the same from local packages (a test)
#   ./publish.sh [--out <dir>] --rebuild <dir>        rebuilt packages of the published release
#
# --rebuild: <dir> holds a folder for some of the systems (pkg-all.sh with
# DAEVALOG_REBUILD set, after a distro's Qt update). Their packages join the
# site beside the published ones; every other package and the Windows
# installer stay as published. The rebuilt revision must be the published one.
# A rebuild sorts above the build it replaces: Arch pkgrel 2 and up, .deb
# +b<n>, .rpm release <revision>.<n>.
#
# A run builds daevalog-dps-meter (2.0) once per system, one artifact per
# system, named as in the lists below; a --from folder has the same
# subfolders, plus windows/ with the installer. The 1.x meter, daevalog-dps-meter-legacy, no longer changes and
# no run builds it: --legacy adds its .pkg.tar.zst, .deb and .rpm, and later
# publishes keep it like every package already on the site. 1.x builds
# published under the name daevalog-dps-meter are dropped. The local
# developer package (daevalog-dps-meter-dev) is never published.
#
# The site, a folder per system so no two builds collide:
#   arch/x86_64/           pacman repository daevalog
#   deb/pool/<system>/     the .deb builds; deb/pool/legacy/ the 1.x .deb
#   deb/dists/<system>/    an apt suite per system (daevalog-<system>.sources)
#   deb/Packages, ...      the first apt repository (daevalog.sources), flat:
#                          the $DEB_FLAT build and legacy
#   rpm/x86_64/<system>/   an rpm repository per system (daevalog-fedora.repo,
#                          daevalog-tumbleweed.repo)
#   rpm/x86_64/repodata/   the first rpm repository (daevalog.repo): every .rpm
#                          build; dnf and zypper install the one whose
#                          dependencies the system has
#   windows/               the newest Windows installer only, its .asc signature
#                          and SHA256SUMS; older ones stay on GitHub releases.
#                          index.html links it through @WIN_FILE@, @WIN_VERSION@
#                          and @WIN_SIZE@, filled in here.
#
# Each package folder keeps the newest $KEEP builds of each package. main is replaced
# by a single commit with no parent, so old binaries leave no history behind.
set -euo pipefail

# DAEVALOG_GNUPGHOME and DAEVALOG_FPR: another key, for a test with --out.
FPR=${DAEVALOG_FPR:-33F1E9F759E2887D26372C35502429F6C085461C}
SIGNING_HOME=${DAEVALOG_GNUPGHOME:-$HOME/.local/share/daevalog-signing}
SOURCE_REPO=Seralth/Daevalog
KEEP=3
CPUS=4-7,12-15
AUTHOR_NAME=Seralth
AUTHOR_EMAIL=297549803+Seralth@users.noreply.github.com
SITE_URL=https://packages.seralth.com
SITE_FILES=(CNAME .nojekyll README.md index.html daevalog.asc daevalog.sources daevalog.repo
  daevalog-debian13.sources daevalog-ubuntu2404.sources daevalog-fedora.repo daevalog-tumbleweed.repo publish.sh
  icon.png screenshot-meter.png)
# The systems a run builds for. Fedora's folder is fedora<release>, which
# daevalog-fedora.repo finds by $releasever.
ARCH_TARGET=arch
DEB_TARGETS=(debian13 ubuntu2404)
RPM_TARGETS=(fedora44 tumbleweed)
TARGETS=("$ARCH_TARGET" "${DEB_TARGETS[@]}" "${RPM_TARGETS[@]}")
# The Windows installer: workflow, artifact, and its file name (version, revision).
WIN_WORKFLOW=windows.yml
WIN_ARTIFACT=daevalog-dps-meter-windows-installer
WIN_RE='^daevalog-dps-meter-([0-9][^-]*)-r([0-9]+)-setup\.exe$'
# The build the first daevalog.sources serves. Its index is flat and apt takes
# the newest version there without falling back to one that installs, so it
# can hold one build only. Its users were on Debian 13, LMDE 7, Mint 22 and
# Pop!_OS 24.04. It serves Debian, the root of the family; Mint and Pop!_OS
# move to their own suite.
DEB_FLAT=debian13
MAIN=daevalog-dps-meter
LEGACY=daevalog-dps-meter-legacy
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP_BASE=${DAEVALOG_TMP:-$HOME/Projects/daevalog-check/tmp-publish}

die() { echo "publish: $*" >&2; exit 1; }
usage() { echo "usage: $0 [--out <dir>] [--legacy <dir>] <run id> | --out <dir> [--legacy <dir>] --from <dir> | [--out <dir>] --rebuild <dir>" >&2; exit 2; }
pin() { taskset -c "$CPUS" "$@"; }
container() { docker run --rm --cpuset-cpus "$CPUS" "$@"; }
sign() { pin gpg --homedir "$SIGNING_HOME" --batch --yes --quiet --local-user "$FPR" --digest-algo SHA512 "$@"; }

out=""
run_id=""
from=""
legacy=""
rebuild=""
while (($#)); do
  case $1 in
    --out) [[ $# -ge 2 ]] || usage; out=$2; shift 2 ;;
    --from) [[ $# -ge 2 ]] || usage; from=$(cd "$2" && pwd); shift 2 ;;
    --rebuild) [[ $# -ge 2 ]] || usage; rebuild=$(cd "$2" && pwd); shift 2 ;;
    --legacy) [[ $# -ge 2 ]] || usage; legacy=$(cd "$2" && pwd); shift 2 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [[ -z $run_id ]] || usage; run_id=$1; shift ;;
  esac
done
if [[ -n $rebuild ]]; then
  [[ -z $run_id && -z $from && -z $legacy ]] || usage
elif [[ -n $from ]]; then
  [[ -z $run_id && -n $out ]] || usage   # local packages are for tests: never published
else
  [[ $run_id =~ ^[0-9]+$ ]] || usage
fi

for f in "${SITE_FILES[@]}"; do
  [[ -e $REPO_DIR/$f ]] || die "missing $REPO_DIR/$f"
done
if [[ -z $out ]]; then
  [[ $(git -C "$REPO_DIR" symbolic-ref --short HEAD) == main ]] || die "$REPO_DIR is not on branch main"
fi

if [[ -z $from && -z $rebuild ]]; then
  conclusion=$(gh run view "$run_id" -R "$SOURCE_REPO" --json conclusion --jq .conclusion)
  [[ $conclusion == success ]] || die "run $run_id has not succeeded (conclusion: ${conclusion:-none})"
fi

mkdir -p "$TMP_BASE"
work=$(mktemp -d "$TMP_BASE/run.XXXXXX")
cleanup() { rm -rf "$work"; rmdir "$TMP_BASE" 2>/dev/null || true; }
trap cleanup EXIT

if [[ -n $out ]]; then
  mkdir -p "$out"
  [[ -z $(ls -A "$out") ]] || die "$out is not empty"
  site=$(cd "$out" && pwd)
else
  site=$work/site
  mkdir -p "$site"
fi
arch_dir=$site/arch/x86_64
deb_root=$site/deb
rpm_root=$site/rpm/x86_64
mkdir -p "$arch_dir" "$deb_root/pool/legacy"
for t in "${DEB_TARGETS[@]}"; do mkdir -p "$deb_root/pool/$t"; done
for t in "${RPM_TARGETS[@]}"; do mkdir -p "$rpm_root/$t"; done

# A package's name and build revision from its file name, per format.
ARCH_RE='^(.+)-([0-9]+_)?[0-9][^-]*\.r([0-9]+)\.g[0-9a-f]+-([0-9]+)-x86_64\.pkg\.tar\.zst$'
DEB_RE='^([^_]+)_.*\+r([0-9]+)(\+b([0-9]+))?_amd64\.deb$'
RPM_RE='^(.+)-[^-]+-([0-9]+)(\.([0-9]+))?\.x86_64\.rpm$'
name_of() { basename "$1" | sed -nE "s/$2/\1/p"; }
rev_of() { basename "$1" | sed -nE "s/$2/\\$3/p"; }
# The rebuild of a revision: group 4 of each pattern (Arch: pkgrel, 1 for
# the first build); 0 when a .deb or .rpm has none.
rb_of() { local v; v=$(basename "$1" | sed -nE "s/$2/\\4/p"); echo "${v:-0}"; }
# 1.x as it was published before it became daevalog-dps-meter-legacy.
old_main() { [[ $(basename "$1") =~ ^daevalog-dps-meter(-([0-9]+_)?|_)1\. ]]; }
kind_of() {
  local t
  for t in "${DEB_TARGETS[@]}"; do [[ $1 != "$t" ]] || { echo deb; return; }; done
  for t in "${RPM_TARGETS[@]}"; do [[ $1 != "$t" ]] || { echo rpm; return; }; done
  echo arch
}
ext_of() { case $1 in arch) echo pkg.tar.zst ;; deb) echo deb ;; rpm) echo rpm ;; esac; }
re_of() { case $1 in arch) echo "$ARCH_RE" ;; deb) echo "$DEB_RE" ;; rpm) echo "$RPM_RE" ;; esac; }
revgroup_of() { case $1 in arch) echo 3 ;; *) echo 2 ;; esac; }

# The new builds: one per system. pacman takes the file name from the
# database, so the artifact's name (':' of the epoch turned into '_') is kept.
mkdir -p "$work/dl"
if [[ -n $rebuild ]]; then echo "Rebuilt packages from $rebuild"
elif [[ -n $from ]]; then echo "Packages from $from"; else echo "Downloading run $run_id"; fi
declare -A new
rev=""
built=()
for t in "${TARGETS[@]}"; do
  if [[ -n $rebuild ]]; then
    [[ -d $rebuild/$t ]] || continue
    cp -r "$rebuild/$t" "$work/dl/$t"
  elif [[ -n $from ]]; then
    [[ -d $from/$t ]] || die "no folder $t in $from"
    cp -r "$from/$t" "$work/dl/$t"
  else
    gh run download "$run_id" -R "$SOURCE_REPO" -n "$t" -D "$work/dl/$t"
  fi
  k=$(kind_of "$t")
  mapfile -t files < <(find "$work/dl/$t" -type f | sort)
  [[ ${#files[@]} -eq 1 && ${files[0]} == *.$(ext_of "$k") ]] \
    || die "$t: want one .$(ext_of "$k"), got: ${files[*]##*/}"
  n=$(name_of "${files[0]}" "$(re_of "$k")"); r=$(rev_of "${files[0]}" "$(re_of "$k")" "$(revgroup_of "$k")")
  [[ $n != "$MAIN-dev" ]] || die "the developer package is never published"
  [[ $n == "$MAIN" && -n $r ]] || die "$t: $(basename "${files[0]}") is not a build of $MAIN"
  if [[ -n $rebuild ]]; then
    b=$(rb_of "${files[0]}" "$(re_of "$k")"); min=1; [[ $k != arch ]] || min=2
    ((b >= min)) || die "$t: $(basename "${files[0]}") has no rebuild number (DAEVALOG_REBUILD)"
  fi
  [[ -z $rev || $rev == "$r" ]] || die "$t is r$r, the other systems r$rev"
  rev=$r
  new[$t]=${files[0]}
  built+=("$t")
done
((${#built[@]})) || die "no system folder in $rebuild"
summary="$MAIN r$rev"
[[ -z $rebuild ]] || summary="$MAIN r$rev rebuilt for ${built[*]}"

# The Windows installer of the same commit, from the Windows run; for a
# rebuild, the one already published.
if [[ -n $rebuild ]]; then
  git -C "$REPO_DIR" fetch -q origin main
  mkdir -p "$work/dl/pub" "$work/dl/windows"
  git -C "$REPO_DIR" archive FETCH_HEAD -- windows | tar -x -C "$work/dl/pub"
  find "$work/dl/pub/windows" -name '*-setup.exe' -exec cp {} "$work/dl/windows/" \;
elif [[ -n $from ]]; then
  [[ -d $from/windows ]] || die "no folder windows in $from"
  cp -r "$from/windows" "$work/dl/windows"
else
  sha=$(gh run view "$run_id" -R "$SOURCE_REPO" --json headSha --jq .headSha)
  win_run=$(gh run list -R "$SOURCE_REPO" --workflow "$WIN_WORKFLOW" --commit "$sha" --status success \
    --json databaseId --jq '.[0].databaseId // empty')
  [[ -n $win_run ]] || die "no successful $WIN_WORKFLOW run for $sha"
  gh run download "$win_run" -R "$SOURCE_REPO" -n "$WIN_ARTIFACT" -D "$work/dl/windows"
fi
mapfile -t files < <(find "$work/dl/windows" -type f | sort)
[[ ${#files[@]} -eq 1 ]] || die "windows: want one installer, got: ${files[*]##*/}"
win=${files[0]}
win_file=$(basename "$win")
[[ $win_file =~ $WIN_RE ]] || die "windows: $win_file is not an installer of $MAIN"
win_version=${BASH_REMATCH[1]}
[[ ${BASH_REMATCH[2]} == "$rev" ]] || die "windows is r${BASH_REMATCH[2]}, the other systems r$rev"
[[ -n $rebuild ]] || summary+=", Windows $win_version r$rev"

# The 1.x legacy packages, when given: one of each format.
declare -A leg
if [[ -n $legacy ]]; then
  for k in arch deb rpm; do
    mapfile -t files < <(find "$legacy" -type f -name "*.$(ext_of "$k")" | sort)
    [[ ${#files[@]} -eq 1 ]] || die "$legacy: want one .$(ext_of "$k"), got: ${files[*]##*/}"
    [[ $(name_of "${files[0]}" "$(re_of "$k")") == "$LEGACY" ]] || die "$(basename "${files[0]}") is not $LEGACY"
    leg[$k]=${files[0]}
  done
  summary+=", $LEGACY r$(rev_of "${leg[deb]}" "$DEB_RE" 2)"
fi

# Packages already published, each into its folder. Files of the first
# layout (deb/*.deb, rpm/x86_64/*.rpm) are 1.x: legacy moves, the rest goes.
git -C "$REPO_DIR" fetch -q origin main
mkdir -p "$work/prev"
if [[ -n $(git -C "$REPO_DIR" ls-tree --name-only FETCH_HEAD -- arch deb rpm) ]]; then
  git -C "$REPO_DIR" archive FETCH_HEAD -- arch deb rpm | tar -x -C "$work/prev"
fi
shopt -s nullglob
keep() {   # <file> <folder>...: copies a published package unless it is old 1.x
  local f=$1 d; shift
  if old_main "$f" || (($# == 0)); then echo "Dropping $(basename "$f")"; return 0; fi
  for d in "$@"; do
    cp "$f" "$d/"
    if [[ -e $f.sig ]]; then cp "$f.sig" "$d/"; fi
  done
}
for f in "$work"/prev/arch/x86_64/*.pkg.tar.zst; do keep "$f" "$arch_dir"; done
for t in "${DEB_TARGETS[@]}" legacy; do
  for f in "$work/prev/deb/pool/$t"/*.deb; do keep "$f" "$deb_root/pool/$t"; done
done
for f in "$work"/prev/deb/*.deb; do
  if [[ $(name_of "$f" "$DEB_RE") == "$LEGACY" ]]; then keep "$f" "$deb_root/pool/legacy"; else keep "$f"; fi
done
for t in "${RPM_TARGETS[@]}"; do
  for f in "$work/prev/rpm/x86_64/$t"/*.rpm; do keep "$f" "$rpm_root/$t"; done
done
for f in "$work"/prev/rpm/x86_64/*.rpm; do
  if [[ $(name_of "$f" "$RPM_RE") == "$LEGACY" ]]; then
    for t in "${RPM_TARGETS[@]}"; do keep "$f" "$rpm_root/$t"; done
  else
    keep "$f"
  fi
done

# A rebuild has the published version but for its rebuild part: anything else
# (another hash length, another revision) could sort below the published one.
base_of() {  # <kind> <file>: the file name without its rebuild part
  case $1 in
    arch) basename "$2" | sed -E 's/-[0-9]+-x86_64\.pkg\.tar\.zst$//' ;;
    deb) basename "$2" | sed -E 's/(\+b[0-9]+)?_amd64\.deb$//' ;;
    rpm) basename "$2" | sed -E 's/(\.[0-9]+)?\.x86_64\.rpm$//' ;;
  esac
}
if [[ -n $rebuild ]]; then
  for t in "${built[@]}"; do
    k=$(kind_of "$t")
    case $k in arch) d=$arch_dir ;; deb) d=$deb_root/pool/$t ;; rpm) d=$rpm_root/$t ;; esac
    want=$(base_of "$k" "${new[$t]}") found=""
    for f in "$d"/"$MAIN"[-_][0-9]*; do
      if [[ $(base_of "$k" "$f") == "$want" ]]; then found=$f; fi
    done
    [[ -n $found ]] || die "$t: no published build matches $(basename "${new[$t]}") but for its rebuild part"
  done
fi

# The new builds into their folders; these are signed below.
new_arch=() new_rpm=()
if [[ -n ${new[$ARCH_TARGET]:-} ]]; then
  cp -f "${new[$ARCH_TARGET]}" "$arch_dir/"; new_arch+=("$(basename "${new[$ARCH_TARGET]}")")
fi
for t in "${DEB_TARGETS[@]}"; do
  if [[ -n ${new[$t]:-} ]]; then cp -f "${new[$t]}" "$deb_root/pool/$t/"; fi
done
for t in "${RPM_TARGETS[@]}"; do
  if [[ -n ${new[$t]:-} ]]; then cp -f "${new[$t]}" "$rpm_root/$t/"; new_rpm+=("$t/$(basename "${new[$t]}")"); fi
done
if [[ -n $legacy ]]; then
  cp -f "${leg[arch]}" "$arch_dir/"; new_arch+=("$(basename "${leg[arch]}")")
  cp -f "${leg[deb]}" "$deb_root/pool/legacy/"
  for t in "${RPM_TARGETS[@]}"; do cp -f "${leg[rpm]}" "$rpm_root/$t/"; new_rpm+=("$t/$(basename "${leg[rpm]}")"); done
fi

# Keeps the newest $KEEP builds of each package in a folder, by revision.
prune() {
  local dir=$1 pattern=$2 re=$3 revgroup=$4 f n r
  local -a list=()
  for f in "$dir"/$pattern; do
    n=$(name_of "$f" "$re"); r=$(rev_of "$f" "$re" "$revgroup")
    [[ -n $n && -n $r ]] || die "no name or revision in $f"
    list+=("$n $r $(rb_of "$f" "$re") $f")
  done
  ((${#list[@]})) || return 0
  printf '%s\n' "${list[@]}" | sort -k1,1 -k2,2nr -k3,3nr | awk -v keep=$KEEP '{ if (++seen[$1] > keep) print $4 }' |
    while read -r f; do
      echo "Removing $(basename "$f")"
      rm -f "$f" "$f.sig"
    done
}
prune "$arch_dir" '*.pkg.tar.zst' "$ARCH_RE" 3
for t in "${DEB_TARGETS[@]}" legacy; do prune "$deb_root/pool/$t" '*.deb' "$DEB_RE" 2; done
for t in "${RPM_TARGETS[@]}"; do prune "$rpm_root/$t" '*.rpm' "$RPM_RE" 2; done

# The newest file of each package in a folder, one per line.
newest_each() {
  local dir=$1 pattern=$2 re=$3 revgroup=$4 f
  for f in "$dir"/$pattern; do
    echo "$(name_of "$f" "$re") $(rev_of "$f" "$re" "$revgroup") $(rb_of "$f" "$re") $f"
  done | sort -k1,1 -k2,2nr -k3,3nr | awk '!seen[$1]++ { print $4 }'
}

echo "pacman repository"
for f in "${new_arch[@]}"; do
  if [[ -e $arch_dir/$f ]]; then sign --detach-sign -o "$arch_dir/$f.sig" "$arch_dir/$f"; fi
done
rm -f "$arch_dir"/daevalog.*
mapfile -t newest_arch < <(newest_each "$arch_dir" '*.pkg.tar.zst' "$ARCH_RE" 3)
(cd "$arch_dir" && GNUPGHOME=$SIGNING_HOME pin repo-add -q -s -k "$FPR" daevalog.db.tar.gz "${newest_arch[@]##*/}")
# Real files instead of symlinks, for Pages.
for f in daevalog.db daevalog.db.sig daevalog.files daevalog.files.sig; do
  if [[ -L $arch_dir/$f ]]; then
    cp --remove-destination "$(readlink -f "$arch_dir/$f")" "$arch_dir/$f"
  fi
done
GNUPGHOME=$SIGNING_HOME gpg --quiet --verify "$arch_dir/daevalog.db.sig" "$arch_dir/daevalog.db" 2>/dev/null \
  || die "pacman database signature does not verify"

echo "apt repositories"
# A suite per system under dists/, and the flat first repository at the top.
# Both list files in pool/, so each .deb is stored once.
container -v "$deb_root:/repo" -w /repo -e HOST_IDS="$(id -u):$(id -g)" \
  -e SUITES="${DEB_TARGETS[*]}" -e FLAT="$DEB_FLAT" debian:13 sh -euc '
  trap "chown -R \$HOST_IDS /repo" EXIT
  { apt-get update && apt-get install -y --no-install-recommends apt-utils; } > /tmp/apt.log 2>&1 || { cat /tmp/apt.log; exit 1; }
  index() {  # <Packages file> <pool folder>: that folder and the legacy one
    { apt-ftparchive packages "pool/$2"; apt-ftparchive packages pool/legacy; } > "$1"
    gzip -9nk "$1"
  }
  release() {  # <folder> [<suite>]: Release over the index files in <folder>
    dir=$1
    set -- -o APT::FTPArchive::Release::Origin=Daevalog -o APT::FTPArchive::Release::Label=Daevalog \
      -o "APT::FTPArchive::Release::Description=Daevalog DPS Meter" -o APT::FTPArchive::Release::Architectures=amd64 \
      ${2:+-o APT::FTPArchive::Release::Suite=$2 -o APT::FTPArchive::Release::Codename=$2 -o APT::FTPArchive::Release::Components=main}
    apt-ftparchive "$@" release "$dir" > /tmp/Release
  }
  for s in $SUITES; do
    mkdir -p "dists/$s/main/binary-amd64"
    index "dists/$s/main/binary-amd64/Packages" "$s"
    release "dists/$s" "$s"
    cp /tmp/Release "dists/$s/Release"
  done
  index Packages "$FLAT"
  mkdir /tmp/flat
  cp Packages Packages.gz /tmp/flat/
  release /tmp/flat
  cp /tmp/Release Release'
for d in "$deb_root" "${DEB_TARGETS[@]/#/$deb_root/dists/}"; do
  sign --clearsign -o "$d/InRelease" "$d/Release"
  sign --armor --detach-sign -o "$d/Release.gpg" "$d/Release"
done

echo "rpm repositories"
# The first repository lists every build, and the legacy package once.
union=()
declare -A listed
for t in "${RPM_TARGETS[@]}"; do
  for f in "$rpm_root/$t"/*.rpm; do
    b=$(basename "$f")
    if [[ $(name_of "$f" "$RPM_RE") == "$LEGACY" ]]; then
      [[ -z ${listed[$b]:-} ]] || continue
      listed[$b]=1
    fi
    union+=("$t/$b")
  done
done
# rpmsign runs in Fedora with a copy of the keyring in the container's
# memory (tmpfs); the keyring itself is mounted read-only.
container -v "$rpm_root:/repo" -v "$SIGNING_HOME:/keyring:ro" --tmpfs /gnupg:mode=0700 \
  -e HOST_IDS="$(id -u):$(id -g)" -e FPR="$FPR" -e NEW_RPMS="${new_rpm[*]}" -e SYSTEMS="${RPM_TARGETS[*]}" \
  -e UNION="${union[*]}" fedora:42 sh -euc '
  trap "chown -R \$HOST_IDS /repo" EXIT
  dnf -q -y install rpm-sign createrepo_c gnupg2 > /tmp/dnf.log 2>&1 || { cat /tmp/dnf.log; exit 1; }
  cp -a /keyring/. /gnupg/
  chown -R root:root /gnupg
  export GNUPGHOME=/gnupg
  for f in $NEW_RPMS; do
    if [ -e "/repo/$f" ]; then
      rpmsign --addsign --define "_gpg_name $FPR" "/repo/$f" >/dev/null
    fi
  done
  gpg --batch --export --armor "$FPR" > /tmp/key.asc
  rpm --import /tmp/key.asc
  for f in /repo/*/*.rpm; do
    case "$(rpm -K "$f")" in *"signatures OK") ;; *) echo "not signed: $f" >&2; exit 1 ;; esac
  done
  for s in $SYSTEMS; do
    rm -rf "/repo/$s/repodata"
    createrepo_c -q "/repo/$s"
  done
  printf "%s\n" $UNION > /tmp/pkglist
  rm -rf /repo/repodata
  createrepo_c -q --pkglist /tmp/pkglist /repo'
for d in "$rpm_root" "${RPM_TARGETS[@]/#/$rpm_root/}"; do
  sign --armor --detach-sign -o "$d/repodata/repomd.xml.asc" "$d/repodata/repomd.xml"
done

echo "Windows installer"
mkdir -p "$site/windows"
cp "$win" "$site/windows/"
sign --armor --detach-sign -o "$site/windows/$win_file.asc" "$site/windows/$win_file"
(cd "$site/windows" && sha256sum "$win_file" > SHA256SUMS)
win_size=$(stat -c %s "$win" | awk '{ printf "%.0f MB", $1 / 1e6 }')

for f in "${SITE_FILES[@]}"; do cp "$REPO_DIR/$f" "$site/"; done
# The page links the installer of this publish.
sed -i -e "s/@WIN_FILE@/$win_file/g" -e "s/@WIN_VERSION@/$win_version/g" -e "s/@WIN_SIZE@/$win_size/g" "$site/index.html"
if grep -q '@WIN_' "$site/index.html"; then die "index.html has a placeholder left"; fi
if [[ -z $(ls -A "$deb_root/pool/legacy") ]]; then
  echo "Note: no $LEGACY on the site yet; add it with --legacy <dir>"
fi

print_setup() {
  cat <<EOF

Setup

Arch-based (Arch, CachyOS, EndeavourOS, Manjaro):
  curl -fsSLO $SITE_URL/daevalog.asc
  sudo pacman-key --add daevalog.asc
  sudo pacman-key --lsign-key $FPR
  printf '\n[daevalog]\nServer = $SITE_URL/arch/\$arch\n' | sudo tee -a /etc/pacman.conf
  sudo pacman -Syu daevalog-dps-meter

Debian 13, LMDE 7:
  sudo curl -fsSLo /etc/apt/keyrings/daevalog.asc $SITE_URL/daevalog.asc
  sudo curl -fsSLo /etc/apt/sources.list.d/daevalog.sources $SITE_URL/daevalog-debian13.sources
  sudo apt update && sudo apt install daevalog-dps-meter

Linux Mint 22, Pop!_OS 24.04:
  sudo curl -fsSLo /etc/apt/keyrings/daevalog.asc $SITE_URL/daevalog.asc
  sudo curl -fsSLo /etc/apt/sources.list.d/daevalog.sources $SITE_URL/daevalog-ubuntu2404.sources
  sudo apt update && sudo apt install daevalog-dps-meter

Fedora:
  sudo dnf config-manager addrepo --from-repofile=$SITE_URL/daevalog-fedora.repo
  sudo dnf install daevalog-dps-meter

Bazzite and other image-based Fedoras:
  sudo curl -fsSLo /etc/yum.repos.d/daevalog.repo $SITE_URL/daevalog-fedora.repo
  rpm-ostree install daevalog-dps-meter

openSUSE Tumbleweed:
  sudo rpm --import $SITE_URL/daevalog.asc
  sudo zypper addrepo $SITE_URL/daevalog-tumbleweed.repo
  sudo zypper install daevalog-dps-meter

Windows: $SITE_URL/windows/$win_file (also on GitHub releases)

The 1.x meter, beside 2.0: install daevalog-dps-meter-legacy the same way.
EOF
}

if [[ -n $out ]]; then
  echo "Built $summary into $site (nothing published)"
  print_setup
  exit 0
fi

message="Packages $summary"
echo "Committing"
export GIT_INDEX_FILE=$work/index
git -C "$site" --git-dir="$REPO_DIR/.git" --work-tree="$site" add -A
tree=$(git --git-dir="$REPO_DIR/.git" write-tree)
unset GIT_INDEX_FILE
commit=$(GIT_AUTHOR_NAME=$AUTHOR_NAME GIT_AUTHOR_EMAIL=$AUTHOR_EMAIL \
  GIT_COMMITTER_NAME=$AUTHOR_NAME GIT_COMMITTER_EMAIL=$AUTHOR_EMAIL \
  git --git-dir="$REPO_DIR/.git" commit-tree "$tree" -m "$message")

# Checks before pushing: one plain message, the right author and committer,
# no parent, no trailers, and nothing in the tree but the site files and
# the repositories.
git --git-dir="$REPO_DIR/.git" cat-file commit "$commit" > "$work/commit.txt"
msg=$(sed '1,/^$/d' "$work/commit.txt")
[[ $msg == "$message" ]] || die "unexpected commit message: $msg"
[[ -z $(printf '%s\n' "$msg" | git interpret-trailers --parse) ]] || die "commit has trailers"
if grep -q '^parent ' "$work/commit.txt"; then die "commit has a parent"; fi
for who in author committer; do
  line=$(grep "^$who " "$work/commit.txt")
  [[ $line == "$who $AUTHOR_NAME <$AUTHOR_EMAIL> "* ]] || die "wrong $who: $line"
done
allowed="^($(printf '%s|' "${SITE_FILES[@]}" | sed 's/\./\\./g; s/|$//')"
allowed+="|arch/x86_64/[^/]+\.pkg\.tar\.zst(\.sig)?|arch/x86_64/daevalog\.(db|files)(\.tar\.gz)?(\.sig)?"
allowed+="|deb/pool/[a-z0-9]+/[^/]+\.deb|deb/(Packages|Packages\.gz|Release|InRelease|Release\.gpg)"
allowed+="|deb/dists/[a-z0-9]+/(Release|InRelease|Release\.gpg|main/binary-amd64/Packages(\.gz)?)"
allowed+="|rpm/x86_64/[a-z0-9]+/[^/]+\.rpm|rpm/x86_64/([a-z0-9]+/)?repodata/[^/]+"
allowed+="|windows/[^/]+-setup\.exe(\.asc)?|windows/SHA256SUMS)$"
git --git-dir="$REPO_DIR/.git" ls-tree -r --name-only "$commit" > "$work/tree.txt"
if grep -vqE "$allowed" "$work/tree.txt"; then
  grep -vE "$allowed" "$work/tree.txt" >&2
  die "unexpected files in the tree"
fi

echo "Pushing main (replaces its history)"
git -C "$REPO_DIR" push -q --force origin "$commit:refs/heads/main"
git -C "$REPO_DIR" update-ref refs/heads/main "$commit"
git -C "$REPO_DIR" reset -q --hard main
git -C "$REPO_DIR" reflog expire --expire=now --all
git -C "$REPO_DIR" gc -q --prune=now

echo "Published $summary to $SITE_URL"
print_setup
