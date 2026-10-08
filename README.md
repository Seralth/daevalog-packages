# Daevalog packages

Signed package repositories for [Daevalog DPS Meter](https://github.com/Seralth/Daevalog), served at https://packages.seralth.com. The setup steps for each distribution are on that page (`index.html` here).

- `arch/x86_64/`: pacman repository `daevalog`
- `deb/`: apt repository, used by `daevalog.sources`
- `rpm/x86_64/`: rpm repository for dnf, rpm-ostree and zypper, used by `daevalog.repo`
- `publish.sh`: builds and publishes the repositories from a run of the Daevalog "Linux packages" workflow
