#!/usr/bin/env bash
# Bootstrap self-hosted: prepara um Ubuntu 24.04 limpo (SO atualizado, Docker
# Engine/Compose, age, jq, cosign, Nginx) e entrega pro instalador oficial
# (scripts/instalar.sh, já dentro do pacote baixado) fazer o resto — domínios,
# DNS, firewall, proxy, TLS, preflight, migrations, subida dos serviços. Este
# script só elimina os passos manuais ANTES do pacote existir na máquina; toda
# a lógica de instalação de verdade continua em instalar.sh, nunca duplicada
# aqui (ver docs/INSTALACAO.md).
#
# Hospedado no repositório PÚBLICO de distribuição (sem código-fonte), pra
# poder ser buscado antes de qualquer autenticação/pacote existir:
#
#   curl -fsSL https://raw.githubusercontent.com/waltimgv/emprega-cidades-releases/main/bootstrap.sh | bash
#
# Sem EMPREGA_VERSION definida, instala a release mais recente publicada em
# github.com/waltimgv/emprega-cidades-releases (inclui prereleases — nenhuma
# tag self-hosted-vX.Y.Z até hoje é uma release oficial 1.0.0). Pra fixar uma
# versão específica:
#
#   curl -fsSL .../bootstrap.sh | EMPREGA_VERSION=0.9.17 bash
#
# Só pede, interativamente, usuário e token do GHCR (escopo read:packages) —
# nunca por argumento de linha de comando (ficaria no histórico do shell).
# Idempotente: pula a instalação de qualquer dependência já presente.
set -Eeuo pipefail

REPO_RELEASES="waltimgv/emprega-cidades-releases"
GHCR_USUARIO="${EMPREGA_GHCR_USUARIO:-waltimgv}"
REPO_WORKFLOW="waltimgv/banco-de-empregos"
DESTINO="${EMPREGA_DESTINO:-/opt/emprega-cidades}"
COSIGN_VERSION="v3.0.6"

log() { printf '\n==> %s\n' "$1"; }
falhar() { printf '\n##[ERRO] %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || falhar "Este instalador é só para Linux."
[[ "$(uname -m)" == "x86_64" ]] || falhar "Este instalador é só para linux/amd64."
command -v sudo >/dev/null 2>&1 || falhar "sudo é necessário (rode como um usuário com privilégio sudo, não como root direto)."
command -v apt-get >/dev/null 2>&1 || falhar "Este instalador é só para distribuições baseadas em apt (Ubuntu/Debian)."

log "Atualizando pacotes do sistema (apt-get update && upgrade)"
sudo apt-get update -y
sudo apt-get upgrade -y

log "Instalando dependências básicas (curl, age, jq, openssl, nginx)"
sudo apt-get install -y ca-certificates curl age jq openssl nginx

if ! command -v docker >/dev/null 2>&1; then
  log "Instalando Docker Engine e Compose (repositório oficial docs.docker.com)"
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
else
  log "Docker já instalado ($(docker --version)) — não reinstalado."
fi

if ! command -v cosign >/dev/null 2>&1; then
  log "Instalando Cosign $COSIGN_VERSION"
  tmp_cosign="$(mktemp)"
  curl -fsSL -o "$tmp_cosign" "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
  sudo install -m 0755 "$tmp_cosign" /usr/local/bin/cosign
  rm -f "$tmp_cosign"
else
  log "Cosign já instalado ($(cosign version 2>&1 | head -1 || true)) — não reinstalado."
fi

log "Descobrindo a release em $REPO_RELEASES"
versao="${EMPREGA_VERSION:-}"
if [[ -z "$versao" ]]; then
  versao="$(curl -fsSL "https://api.github.com/repos/$REPO_RELEASES/releases" \
    | jq -r '[.[] | select(.draft==false)][0].tag_name // empty' \
    | sed 's/^self-hosted-v//')"
fi
[[ -n "$versao" ]] || falhar "Não consegui determinar a versão da release automaticamente. Defina EMPREGA_VERSION=X.Y.Z manualmente e rode de novo."
log "Versão selecionada: $versao"

tag="self-hosted-v$versao"
base_url="https://github.com/$REPO_RELEASES/releases/download/$tag"
dir_download="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$dir_download'" EXIT
cd "$dir_download"

log "Baixando o pacote de $REPO_RELEASES (repositório público — sem login nem token)"
for arquivo in \
  "emprega-cidades-self-hosted-$versao.tar.gz" \
  "emprega-cidades-self-hosted-$versao.tar.gz.sha256" \
  "emprega-cidades-self-hosted-$versao.tar.gz.sigstore.json" \
  "release-manifest.json" \
  "release-manifest.json.sigstore.json"
do
  curl -fsSL -o "$arquivo" "$base_url/$arquivo" \
    || falhar "Falha ao baixar $arquivo de $base_url — confira a versão ($versao) em https://github.com/$REPO_RELEASES/releases"
done

log "Verificando checksum"
sha256sum -c "emprega-cidades-self-hosted-$versao.tar.gz.sha256" \
  || falhar "Checksum não confere — pacote corrompido ou incompleto. NÃO prossiga; baixe de novo."

log "Verificando assinatura Cosign/OIDC (identidade do workflow oficial do fornecedor)"
identidade="https://github.com/$REPO_WORKFLOW/.github/workflows/self-hosted-release.yml@refs/tags/$tag"
cosign verify-blob --bundle release-manifest.json.sigstore.json \
  --certificate-identity "$identidade" --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  release-manifest.json \
  || falhar "Assinatura do manifesto não verificou. NÃO prossiga — peça o pacote novamente por um canal confiável."
cosign verify-blob --bundle "emprega-cidades-self-hosted-$versao.tar.gz.sigstore.json" \
  --certificate-identity "$identidade" --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "emprega-cidades-self-hosted-$versao.tar.gz" \
  || falhar "Assinatura do pacote não verificou. NÃO prossiga."
log "Checksum e assinatura OK."

log "Extraindo o pacote em $DESTINO"
sudo mkdir -p "$DESTINO"
sudo tar -xzf "emprega-cidades-self-hosted-$versao.tar.gz" -C "$DESTINO" --strip-components=1
sudo chown -R "$(id -u):$(id -g)" "$DESTINO"
cd "$DESTINO"
if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
fi

log "Autenticação no registry de imagens (GHCR — escopo read:packages, nunca acesso ao código-fonte)"
log "Usuário: $GHCR_USUARIO (fixo — defina EMPREGA_GHCR_USUARIO pra usar outro)"
read -r -s -p "Token do GHCR (read:packages — a digitação fica oculta): " ghcr_token
echo
[[ -n "$ghcr_token" ]] || falhar "O token do GHCR é obrigatório."
echo "$ghcr_token" | docker login ghcr.io -u "$GHCR_USUARIO" --password-stdin
unset ghcr_token

log "Pré-requisitos prontos. A partir daqui, o instalador oficial assume: domínios, DNS, firewall, proxy, TLS, preflight, migrations e subida dos serviços."
exec bash scripts/instalar.sh "$DESTINO"
