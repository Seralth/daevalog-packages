#!/usr/bin/env bash
# Builds the signed pacman, apt and rpm repositories from one run of the
# Daevalog "Linux packages" workflow and publishes them as branch main.
#
#   ./publish.sh <run id>              build, then replace main with one commit
#   ./publish.sh --out <dir> <run id>  build into <dir> only, publish nothing
#
# The packages already on main are kept, up to the newest 3 builds per format.
# main is replaced by a single commit with no parent, so old binaries leave
# no history behind.
set -euo pipefail

FPR=33F1E9F759E2887D26372C35502429F6C085461C
SIGNING_HOME=${DAEVALOG_GNUPGHOME:-$HOME/.local/share/daevalog-signing}
SOURCE_REPO=Seralth/Daevalog
KEEP=3
CPUS=4-7,12-15
AUTHOR_NAME=Seralth
AUTHOR_EMAIL=297549803+Seralth@users.noreply.github.com
SITE_URL=https://packages.seralth.com
SITE_FILES=(CNAME .nojekyll README.md index.html daevalog.asc daevalog.sources daevalog.repo publish.sh)
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP_BASE=${DAEVALOG_TMP:-$HOME/Projects/daevalog-check/tmp-publish}

die() { echo "publish: $*" >&2; exit 1; }
usage() { echo "usage: $0 [--out <dir>] <run id>" >&2; exit 2; }
pin() { taskset -c "$CPUS" "$@"; }
container() { docker run --rm --cpuset-cpus "$CPUS" "$@"; }
sign() { pin gpg --homedir "$SIGNING_HOME" --batch --yes --quiet --local-user "$FPR" --digest-algo SHA512 "$@"; }

out=""
run_id=""
while (($#)); do
  case $1 in
    --out) [[ $# -ge 2 ]] || usage; out=$2; shift 2 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [[ -z $run_id ]] || usage; run_id=$1; shift ;;
  esac
done
[[ $run_id =~ ^[0-9]+$ ]] || usage

for f in "${SITE_FILES[@]}"; do
  [[ -e $REPO_DIR/$f ]] || die "missing $REPO_DIR/$f"
done
if [[ -z $out ]]; then
  [[ $(git -C "$REPO_DIR" symbolic-ref --short HEAD) == main ]] || die "$REPO_DIR is not on branch main"
fi

conclusion=$(gh run view "$run_id" -R "$SOURCE_REPO" --json conclusion --jq .conclusion)
[[ $conclusion == success ]] || die "run $run_id has not succeeded (conclusion: ${conclusion:-none})"

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
deb_dir=$site/deb
rpm_dir=$site/rpm/x86_64
mkdir -p "$arch_dir" "$deb_dir" "$rpm_dir"

echo "Downloading run $run_id"
gh run download "$run_id" -R "$SOURCE_REPO" -n arch-package -n deb-rpm-packages -D "$work/dl"

# Packages already published.
git -C "$REPO_DIR" fetch -q origin main
mkdir -p "$work/prev"
if [[ -n $(git -C "$REPO_DIR" ls-tree --name-only FETCH_HEAD -- arch deb rpm) ]]; then
  git -C "$REPO_DIR" archive FETCH_HEAD -- arch deb rpm | tar -x -C "$work/prev"
fi
shopt -s nullglob
for f in "$work"/prev/arch/x86_64/*.pkg.tar.zst "$work"/prev/arch/x86_64/*.pkg.tar.zst.sig; do cp "$f" "$arch_dir/"; done
for f in "$work"/prev/deb/*.deb; do cp "$f" "$deb_dir/"; done
for f in "$work"/prev/rpm/x86_64/*.rpm; do cp "$f" "$rpm_dir/"; done

# The new build. pacman takes the file name from the database, so the
# artifact's name (':' of the epoch turned into '_') is kept as it is.
new_arch=("$work"/dl/arch-package/*.pkg.tar.zst)
new_deb=("$work"/dl/deb-rpm-packages/*.deb)
new_rpm=("$work"/dl/deb-rpm-packages/*.rpm)
[[ ${#new_arch[@]} -eq 1 && ${#new_deb[@]} -eq 1 && ${#new_rpm[@]} -eq 1 ]] \
  || die "expected one package per format in run $run_id"
rev=$(basename "${new_deb[0]}" | sed -nE 's/.*\+r([0-9]+)_amd64\.deb$/\1/p')
[[ -n $rev ]] || die "no revision in $(basename "${new_deb[0]}")"
cp -f "${new_arch[0]}" "$arch_dir/"
cp -f "${new_deb[0]}" "$deb_dir/"
cp -f "${new_rpm[0]}" "$rpm_dir/"
new_arch_name=$(basename "${new_arch[0]}")
new_rpm_name=$(basename "${new_rpm[0]}")

# Keeps the newest $KEEP files in a folder, by build revision.
prune() {
  local dir=$1 pattern=$2 re=$3 f r
  local -a list=()
  for f in "$dir"/$pattern; do
    r=$(basename "$f" | sed -nE "s/$re/\1/p")
    [[ -n $r ]] || die "no revision in $f"
    list+=("$r $f")
  done
  ((${#list[@]} > KEEP)) || return 0
  printf '%s\n' "${list[@]}" | sort -k1,1nr | tail -n +$((KEEP + 1)) | while read -r r f; do
    echo "Removing $(basename "$f")"
    rm -f "$f" "$f.sig"
  done
}
prune "$arch_dir" '*.pkg.tar.zst' '.*\.r([0-9]+)\.g[0-9a-f]+-[0-9]+-x86_64\.pkg\.tar\.zst$'
prune "$deb_dir" '*.deb' '.*\+r([0-9]+)_amd64\.deb$'
prune "$rpm_dir" '*.rpm' '.*-([0-9]+)\.x86_64\.rpm$'

newest() { # prints the newest file in a folder, by build revision
  local dir=$1 pattern=$2 re=$3 f r
  for f in "$dir"/$pattern; do
    r=$(basename "$f" | sed -nE "s/$re/\1/p")
    echo "$r $f"
  done | sort -k1,1nr | sed -n '1s/^[0-9]* //p'
}

echo "pacman repository"
if [[ -e $arch_dir/$new_arch_name ]]; then
  sign --detach-sign -o "$arch_dir/$new_arch_name.sig" "$arch_dir/$new_arch_name"
fi
rm -f "$arch_dir"/daevalog.*
newest_arch=$(newest "$arch_dir" '*.pkg.tar.zst' '.*\.r([0-9]+)\.g[0-9a-f]+-[0-9]+-x86_64\.pkg\.tar\.zst$')
(cd "$arch_dir" && GNUPGHOME=$SIGNING_HOME pin repo-add -q -s -k "$FPR" daevalog.db.tar.gz "$(basename "$newest_arch")")
# Real files instead of symlinks, for Pages.
for f in daevalog.db daevalog.db.sig daevalog.files daevalog.files.sig; do
  if [[ -L $arch_dir/$f ]]; then
    cp --remove-destination "$(readlink -f "$arch_dir/$f")" "$arch_dir/$f"
  fi
done
GNUPGHOME=$SIGNING_HOME gpg --quiet --verify "$arch_dir/daevalog.db.sig" "$arch_dir/daevalog.db" 2>/dev/null \
  || die "pacman database signature does not verify"

echo "apt repository"
container -v "$deb_dir:/repo" -w /repo -e HOST_IDS="$(id -u):$(id -g)" debian:13 sh -euc '
  trap "chown -R \$HOST_IDS /repo" EXIT
  { apt-get update && apt-get install -y --no-install-recommends apt-utils; } > /tmp/apt.log 2>&1 || { cat /tmp/apt.log; exit 1; }
  rm -f Packages Packages.gz Release InRelease Release.gpg
  apt-ftparchive packages . > Packages
  gzip -9nk Packages
  apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=Daevalog \
    -o APT::FTPArchive::Release::Label=Daevalog \
    -o "APT::FTPArchive::Release::Description=Daevalog DPS Meter" \
    -o APT::FTPArchive::Release::Architectures=amd64 \
    release . > /tmp/Release
  cp /tmp/Release Release'
sign --clearsign -o "$deb_dir/InRelease" "$deb_dir/Release"
sign --armor --detach-sign -o "$deb_dir/Release.gpg" "$deb_dir/Release"

echo "rpm repository"
# rpmsign runs in Fedora with a copy of the keyring in the container's
# memory (tmpfs); the keyring itself is mounted read-only.
container -v "$rpm_dir:/repo" -v "$SIGNING_HOME:/keyring:ro" --tmpfs /gnupg:mode=0700 \
  -e HOST_IDS="$(id -u):$(id -g)" -e FPR="$FPR" -e NEW_RPM="$new_rpm_name" fedora:42 sh -euc '
  trap "chown -R \$HOST_IDS /repo" EXIT
  dnf -q -y install rpm-sign createrepo_c gnupg2 > /tmp/dnf.log 2>&1 || { cat /tmp/dnf.log; exit 1; }
  cp -a /keyring/. /gnupg/
  chown -R root:root /gnupg
  export GNUPGHOME=/gnupg
  if [ -e "/repo/$NEW_RPM" ]; then
    rpmsign --addsign --define "_gpg_name $FPR" "/repo/$NEW_RPM" >/dev/null
  fi
  gpg --batch --export --armor "$FPR" > /tmp/key.asc
  rpm --import /tmp/key.asc
  for f in /repo/*.rpm; do
    case "$(rpm -K "$f")" in *"signatures OK") ;; *) echo "not signed: $f" >&2; exit 1 ;; esac
  done
  rm -rf /repo/repodata
  createrepo_c -q /repo'
sign --armor --detach-sign -o "$rpm_dir/repodata/repomd.xml.asc" "$rpm_dir/repodata/repomd.xml"

for f in "${SITE_FILES[@]}"; do cp "$REPO_DIR/$f" "$site/"; done

print_setup() {
  cat <<EOF

Setup

Arch-based (Arch, CachyOS, EndeavourOS, Manjaro):
  curl -fsSLO $SITE_URL/daevalog.asc
  sudo pacman-key --add daevalog.asc
  sudo pacman-key --lsign-key $FPR
  printf '\n[daevalog]\nServer = $SITE_URL/arch/\$arch\n' | sudo tee -a /etc/pacman.conf
  sudo pacman -Syu daevalog-dps-meter

Debian 13, LMDE 7, Linux Mint 22, Pop!_OS 24.04 (.deb):
  sudo curl -fsSLo /etc/apt/keyrings/daevalog.asc $SITE_URL/daevalog.asc
  sudo curl -fsSLo /etc/apt/sources.list.d/daevalog.sources $SITE_URL/daevalog.sources
  sudo apt update && sudo apt install daevalog-dps-meter

Fedora:
  sudo dnf config-manager addrepo --from-repofile=$SITE_URL/daevalog.repo
  sudo dnf install daevalog-dps-meter

Bazzite and other image-based Fedoras:
  sudo curl -fsSLo /etc/yum.repos.d/daevalog.repo $SITE_URL/daevalog.repo
  rpm-ostree install daevalog-dps-meter

openSUSE Tumbleweed:
  sudo rpm --import $SITE_URL/daevalog.asc
  sudo zypper addrepo $SITE_URL/daevalog.repo
  sudo zypper install daevalog-dps-meter
EOF
}

if [[ -n $out ]]; then
  echo "Built r$rev into $site (nothing published)"
  print_setup
  exit 0
fi

echo "Committing"
export GIT_INDEX_FILE=$work/index
git -C "$site" --git-dir="$REPO_DIR/.git" --work-tree="$site" add -A
tree=$(git --git-dir="$REPO_DIR/.git" write-tree)
unset GIT_INDEX_FILE
commit=$(GIT_AUTHOR_NAME=$AUTHOR_NAME GIT_AUTHOR_EMAIL=$AUTHOR_EMAIL \
  GIT_COMMITTER_NAME=$AUTHOR_NAME GIT_COMMITTER_EMAIL=$AUTHOR_EMAIL \
  git --git-dir="$REPO_DIR/.git" commit-tree "$tree" -m "Packages r$rev")

# Checks before pushing: one plain message, the right author and committer,
# no parent, no trailers, and nothing in the tree but the site files and
# the three repositories.
git --git-dir="$REPO_DIR/.git" cat-file commit "$commit" > "$work/commit.txt"
msg=$(sed '1,/^$/d' "$work/commit.txt")
[[ $msg == "Packages r$rev" ]] || die "unexpected commit message: $msg"
[[ -z $(printf '%s\n' "$msg" | git interpret-trailers --parse) ]] || die "commit has trailers"
if grep -q '^parent ' "$work/commit.txt"; then die "commit has a parent"; fi
for who in author committer; do
  line=$(grep "^$who " "$work/commit.txt")
  [[ $line == "$who $AUTHOR_NAME <$AUTHOR_EMAIL> "* ]] || die "wrong $who: $line"
done
allowed="^($(printf '%s|' "${SITE_FILES[@]}" | sed 's/\./\\./g; s/|$//')"
allowed+="|arch/x86_64/[^/]+\.pkg\.tar\.zst(\.sig)?|arch/x86_64/daevalog\.(db|files)(\.tar\.gz)?(\.sig)?"
allowed+="|deb/[^/]+\.deb|deb/(Packages|Packages\.gz|Release|InRelease|Release\.gpg)"
allowed+="|rpm/x86_64/[^/]+\.rpm|rpm/x86_64/repodata/[^/]+)$"
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

echo "Published r$rev to $SITE_URL"
print_setup
