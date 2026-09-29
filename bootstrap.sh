#!/usr/bin/env bash
# Bootstrap self-hosted: comando único, público, que reconhece o ambiente e decide
# sozinho o que fazer —
#   1. Nada instalado em $DESTINO: prepara um Ubuntu 24.04 limpo (SO atualizado,
#      Docker Engine/Compose, age, jq, cosign, Nginx) e entrega pro instalador
#      oficial (scripts/instalar.sh, já dentro do pacote baixado) fazer o resto —
#      domínios, DNS, firewall, proxy, TLS, preflight, migrations, subida dos
#      serviços.
#   2. Instalação existente e desatualizada: baixa e verifica a versão mais
#      recente e entrega pro atualizador oficial (scripts/atualizar.sh, já
#      instalado em $DESTINO) fazer backup, aplicar migrations e subir a nova
#      versão — nunca reimplementado aqui.
#   3. Instalação existente já na versão mais recente: só avisa e não faz nada.
# Este script só resolve "como eu baixo/verifico o pacote e decido qual desses
# três casos estou" — toda a lógica de instalar/atualizar de verdade continua
# em instalar.sh/atualizar.sh, nunca duplicada aqui (ver docs/INSTALACAO.md e
# docs/ATUALIZACAO.md).
#
# Hospedado no repositório PÚBLICO de distribuição (sem código-fonte), pra
# poder ser buscado antes de qualquer autenticação/pacote existir — mesmo
# comando serve pra instalar OU atualizar, sempre:
#
#   curl -fsSL https://raw.githubusercontent.com/waltimgv/emprega-cidades-releases/main/bootstrap.sh | bash
#
# Sem EMPREGA_VERSION definida, usa a release mais recente publicada em
# github.com/waltimgv/emprega-cidades-releases (inclui prereleases — nenhuma
# tag self-hosted-vX.Y.Z até hoje é uma release oficial 1.0.0). Pra fixar uma
# versão específica (instalação ou atualização):
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

# `curl | bash` roda o script direto de um pipe: bash lê os COMANDOS do script e,
# mais adiante, a DIGITAÇÃO do usuário (token do GHCR, confirmação de atualização,
# e-mail do TLS em instalar.sh) pela mesma stdin, em momentos diferentes — um jeito
# frágil de rodar um script com vários prompts interativos, que já travou de verdade
# num teste real (o script para no meio, sem erro). Baixar o arquivo primeiro e rodar
# "bash bootstrap.sh" sempre funciona, porque aí os comandos vêm do arquivo e a
# digitação vem do terminal, duas fontes sempre separadas. Em vez de depender de
# lembrar de baixar antes, o script detecta sozinho que está rodando via pipe (sem um
# arquivo de origem real) e se baixa/reexecuta como arquivo — os dois jeitos de rodar
# o comando caem sempre no caminho que comprovadamente funciona.
if [[ -z "${EMPREGA_BOOTSTRAP_REEXEC:-}" ]] && [[ ! -f "${BASH_SOURCE[0]:-}" ]]; then
  log "Rodando via pipe — baixando uma cópia em arquivo pra reexecutar (mais confiável com os prompts interativos abaixo)"
  tmp_bootstrap="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/$REPO_RELEASES/main/bootstrap.sh" -o "$tmp_bootstrap" \
    || falhar "Falha ao baixar bootstrap.sh pra reexecutar como arquivo. Baixe e rode manualmente: curl -fsSL https://raw.githubusercontent.com/$REPO_RELEASES/main/bootstrap.sh -o bootstrap.sh && bash bootstrap.sh"
  EMPREGA_BOOTSTRAP_REEXEC=1 exec bash "$tmp_bootstrap"
fi
# A cópia baixada acima (se veio via pipe) só existe pra este reexec — sem isso,
# ela nunca é apagada: o "exec" logo acima já troca de processo antes de qualquer
# limpeza, e nada mais tarde sabe que "$0" é um arquivo temporário. Registra a
# limpeza aqui, já dentro do processo reexecutado, pelo próprio caminho ($0).
# Guardada numa variável (não direto num "trap ... EXIT") porque outro trap EXIT
# é registrado mais abaixo (dir_download) — "trap" SUBSTITUI o handler anterior,
# não acumula; cada novo "trap ... EXIT" precisa reincluir esta string também,
# senão a limpeza de um dos dois se perde silenciosamente.
limpar_bootstrap_tmp=""
[[ -z "${EMPREGA_BOOTSTRAP_REEXEC:-}" ]] || limpar_bootstrap_tmp="rm -f '$0'; "
trap "$limpar_bootstrap_tmp" EXIT

# Rodado como `curl ... | bash`, o stdin do processo é o PRÓPRIO SCRIPT sendo
# lido pelo bash — qualquer `read` interativo (o prompt do token abaixo, a
# confirmação de atualização, e os prompts de scripts/instalar.sh no final, que
# herdam este stdin via exec) não encontra o teclado, fica vazio na hora, e o
# docker login tenta autenticar com token vazio ("denied: denied") sem nunca
# mostrar o prompt. Reabre o stdin do próprio terminal ANTES de qualquer read —
# sem isso, `curl | bash` nunca funciona de forma interativa (mesmo já rodando
# como arquivo real pelo bloco acima, esta etapa continua necessária: o arquivo
# ainda foi invocado a partir de um pipe, então a stdin herdada por ele também é
# o pipe, não o teclado).
if [[ -t 1 ]] && [[ -r /dev/tty ]]; then
  exec < /dev/tty
else
  falhar "Sem terminal interativo (/dev/tty) disponível — rode este script diretamente (baixe e execute como arquivo), não dentro de outro pipe/automação sem TTY."
fi
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

# Reconhece o ambiente: só existe .state/current-manifest.json depois de uma
# instalação (ou atualização) bem-sucedida — ver save_release() em common.sh,
# chamado no fim de instalar.sh/atualizar.sh. Nunca inferido de outra forma
# (ex.: "$DESTINO existe" não basta — pode ser um diretório vazio/parcial de
# uma tentativa anterior interrompida antes de instalar.sh terminar).
modo="instalar"
versao_atual=""
if [[ -f "$DESTINO/.state/current-manifest.json" ]]; then
  modo="atualizar"
  versao_atual="$(jq -r .versao "$DESTINO/.state/current-manifest.json")"
  log "Instalação existente detectada em $DESTINO — versão atual: $versao_atual"
else
  log "Nenhuma instalação existente em $DESTINO — instalando do zero."
fi

log "Descobrindo a release em $REPO_RELEASES"
versao="${EMPREGA_VERSION:-}"
if [[ -z "$versao" ]]; then
  versao="$(curl -fsSL "https://api.github.com/repos/$REPO_RELEASES/releases" \
    | jq -r '[.[] | select(.draft==false)][0].tag_name // empty' \
    | sed 's/^self-hosted-v//')"
fi
[[ -n "$versao" ]] || falhar "Não consegui determinar a versão da release automaticamente. Defina EMPREGA_VERSION=X.Y.Z manualmente e rode de novo."
log "Versão mais recente disponível: $versao"

if [[ "$modo" == "atualizar" ]]; then
  if [[ "$versao_atual" == "$versao" ]]; then
    log "Já está na versão mais recente ($versao_atual). Nada a fazer."
    exit 0
  fi
  # shellcheck disable=SC1091
  source "$DESTINO/scripts/semver.sh"
  versao_e_maior "$versao" "$versao_atual" \
    || falhar "A release mais recente publicada ($versao) não é mais nova que a instalada ($versao_atual) — nada a atualizar. Downgrade intencional não é feito por aqui: use scripts/rollback.sh ou o procedimento formal em docs/ROLLBACK.md."
  log "Atualização disponível: $versao_atual → $versao"
fi

tag="self-hosted-v$versao"
base_url="https://github.com/$REPO_RELEASES/releases/download/$tag"
dir_download="$(mktemp -d)"
# Reinclui $limpar_bootstrap_tmp (ver comentário acima) — senão este "trap"
# substituiria o registrado antes e a cópia via pipe nunca seria apagada.
# shellcheck disable=SC2064
trap "${limpar_bootstrap_tmp}rm -rf '$dir_download'" EXIT
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

if [[ "$modo" == "atualizar" ]]; then
  dir_pacote="$dir_download/nova-versao"
  mkdir -p "$dir_pacote"
  tar -xzf "emprega-cidades-self-hosted-$versao.tar.gz" -C "$dir_pacote" --strip-components=1

  printf '\nAtualizar %s de %s para %s agora?\nIsso faz backup, para os serviços por alguns instantes, aplica migrations e sobe a nova versão — não há promessa de zero downtime. [s/N] ' \
    "$DESTINO" "$versao_atual" "$versao"
  read -r resposta_atualizar
  case "$resposta_atualizar" in
    s|S|sim|Sim|SIM) ;;
    *) log "Atualização cancelada — nada foi alterado."; exit 0 ;;
  esac
else
  log "Extraindo o pacote em $DESTINO"
  sudo mkdir -p "$DESTINO"
  sudo tar -xzf "emprega-cidades-self-hosted-$versao.tar.gz" -C "$DESTINO" --strip-components=1
  sudo chown -R "$(id -u):$(id -g)" "$DESTINO"
  cd "$DESTINO"
  if [[ ! -f .env ]]; then
    cp .env.example .env
    chmod 600 .env
  fi
fi

log "Autenticação no registry de imagens (GHCR — escopo read:packages, nunca acesso ao código-fonte)"
log "Usuário: $GHCR_USUARIO (fixo — defina EMPREGA_GHCR_USUARIO pra usar outro)"
read -r -p "Token do GHCR (read:packages): " ghcr_token
[[ -n "$ghcr_token" ]] || falhar "O token do GHCR é obrigatório."
echo "$ghcr_token" | docker login ghcr.io -u "$GHCR_USUARIO" --password-stdin
unset ghcr_token

if [[ "$modo" == "atualizar" ]]; then
  cd "$DESTINO"
  log "Pré-requisitos prontos. A partir daqui, o atualizador oficial assume: backup, migrations e subida da nova versão."
  # Sem "exec": precisa terminar de dentro deste processo pra rm -rf "$dir_download" no
  # trap EXIT (linha acima) rodar — "exec" substitui o processo e pula o trap, deixando
  # o pacote baixado/extraído pra trás em /tmp pra sempre (achado real: acumulava a cada
  # atualização, nunca era limpo). O código de saída final continua o mesmo de antes:
  # como é o último comando do script, cai pro fim do arquivo com o mesmo status.
  bash scripts/atualizar.sh "$dir_pacote"
else
  log "Pré-requisitos prontos. A partir daqui, o instalador oficial assume: domínios, DNS, firewall, proxy, TLS, preflight, migrations e subida dos serviços."
  bash scripts/instalar.sh "$DESTINO"
fi
