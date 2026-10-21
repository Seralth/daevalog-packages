# Daevalog packages

Signed package repositories for [Daevalog DPS Meter](https://github.com/Seralth/Daevalog), served at https://packages.seralth.com. The setup steps for each distribution are on that page (`index.html` here).

- `arch/x86_64/`: pacman repository `daevalog`
- `deb/`: apt repository; `pool/<system>/` holds the files, `dists/<system>/` a suite per system, used by `daevalog-debian13.sources` and `daevalog-ubuntu2404.sources`
- `rpm/x86_64/<system>/`: rpm repository per system for dnf, rpm-ostree and zypper, used by `daevalog-fedora.repo` (`fedora<release>`) and `daevalog-tumbleweed.repo`
- `daevalog.sources` and `daevalog.repo`: the files from before 2.0. `daevalog.sources` reads the flat index at the top of `deb/` (the Debian 13 build); `daevalog.repo` reads `rpm/x86_64/` itself, which lists every .rpm build, and dnf and zypper install the one that fits the system
- `publish.sh`: builds and publishes the repositories from a run of the Daevalog "Linux packages" workflow
