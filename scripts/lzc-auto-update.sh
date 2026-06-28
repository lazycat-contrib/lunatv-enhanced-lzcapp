#!/usr/bin/env bash
set -euo pipefail

# lzc-auto-update.sh — 一键更新 LPK 项目版本
#
# 你只需指定新版本号，脚本自动完成：
#   1. 从 manifest 注释推导上游镜像源（如 # ghcr.io/szemeng76/lunatv:6.6.2）
#   2. 自动选择 service（单镜像自动；多镜像用 --service 或记忆值）
#   3. 调用 lzc-release-update.sh 完成完整流程：
#      复制上游镜像 → 更新 package.yml + manifest → 构建 LPK → 可选发布
#   4. 可选 git commit（--commit）
#
# 用法：
#   scripts/lzc-auto-update.sh <version>               # 一键更新（构建，不发布）
#   scripts/lzc-auto-update.sh 6.6.3                   # 例：更新到 6.6.3
#   scripts/lzc-auto-update.sh 6.6.3 --publish         # 更新并发布到应用商店
#   scripts/lzc-auto-update.sh 6.6.3 --commit          # 更新并 git commit
#   scripts/lzc-auto-update.sh 6.6.3 --publish --commit 'bump 6.6.3'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_UPDATE_SCRIPT="${SCRIPT_DIR}/lzc-release-update.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/lzc-auto-update.sh <version> [options]

One-click LPK version update. Automatically derives the upstream image source
from manifest comments and the service from single-image manifests (or config).

Arguments:
  <version>                Target version (REQUIRED). e.g. 6.6.3

Options:
  --service <name>         Service to update. Auto-detected for single-image manifests.
  --source-template <tpl>  Override upstream template, e.g. ghcr.io/acme/app:{version}.
                           Default: derived from manifest comment.
  --publish                Publish to app store after build.
  --no-publish             Do not publish (default).
  --changelog <text>       Changelog for publish. Default: 更新到 <version>.
  --lang <lang>            Changelog language. Default: zh.
  --commit [msg]           Git commit after update. Optional custom message.
  --manifest <file>        Manifest file. Default: lzc-manifest.yml.
  --package <file>         Package file. Default: package.yml.
  --build-file <file>      Build file. Default: lzc-build.yml.
  --config <file>          Config file. Default: .lazycat-release.env.
  --skip-copy              Skip image copy (use source image directly).
  --skip-build             Skip LPK build step.
  --no-remember            Don't update remembered choices file.
  -h, --help               Show this help.

Environment:
  PUBLISH=1                Same as --publish.
  SKIP_COPY=1              Same as --skip-copy.
  SKIP_BUILD=1             Same as --skip-build.

Examples:
  scripts/lzc-auto-update.sh 6.6.3                    # build only
  scripts/lzc-auto-update.sh 6.6.3 --publish          # build + publish
  scripts/lzc-auto-update.sh 6.6.3 --commit           # build + git commit "bump 6.6.3"
  scripts/lzc-auto-update.sh 6.6.3 --service web      # explicit service (multi-image)

USAGE
}

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*" >&2; }

# ─── 文件解析 ───

# service → image
list_manifest_images() {
  awk '
    /^[[:space:]]*services:[[:space:]]*$/ { in_services = 1; next }
    in_services && /^[^[:space:]][^:]*:[[:space:]]*$/ { in_services = 0; service = "" }
    in_services && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      service = $1; sub(/:$/, "", service); next
    }
    in_services && service != "" && /^    image:[[:space:]]*/ {
      image = $0; sub(/^[[:space:]]*image:[[:space:]]*/, "", image)
      gsub(/^["\047]|["\047]$/, "", image)
      print service "\t" image
    }
  ' "$MANIFEST_FILE"
}

# service → upstream comment (the line directly above image:)
list_manifest_comments() {
  awk '
    /^[[:space:]]*services:[[:space:]]*$/ { in_services = 1; next }
    in_services && /^[^[:space:]][^:]*:[[:space:]]*$/ { in_services = 0; service = ""; comment = "" }
    in_services && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      service = $1; sub(/:$/, "", service); comment = ""; next
    }
    in_services && service != "" && /^    # / {
      comment = $0; sub(/^[[:space:]]*#[[:space:]]*/, "", comment)
      gsub(/[[:space:]]*$/, "", comment); next
    }
    in_services && service != "" && /^    image:[[:space:]]*/ {
      if (comment != "" && comment ~ /^[a-zA-Z0-9].*:[a-zA-Z0-9]/) {
        print service "\t" comment
      }
      comment = ""
    }
  ' "$MANIFEST_FILE"
}

derive_source_template() {
  local upstream=$1
  if [[ "$upstream" == *:* ]]; then
    printf '%s:{version}\n' "${upstream%:*}"
  else
    printf '%s:{version}\n' "$upstream"
  fi
}

# ─── 配置加载（记忆值） ───

quote_config_value() { printf '%s' "$1" | sed 's/[[:space:]]*$//'; }

load_remembered_service() {
  [[ -f "$CONFIG_FILE" ]] || return 1
  awk -F= '/^service=/ { gsub(/"/, "", $2); print $2; exit }' "$CONFIG_FILE"
}

# ─── 参数解析 ───

MANIFEST_FILE=${MANIFEST_FILE:-}
PACKAGE_FILE=${PACKAGE_FILE:-package.yml}
BUILD_FILE=${BUILD_FILE:-lzc-build.yml}
CONFIG_FILE=${CONFIG_FILE:-.lazycat-release.env}
SERVICE=${SERVICE:-}
SOURCE_TEMPLATE=${SOURCE_TEMPLATE:-}
PUBLISH=${PUBLISH:-}
LANG_CODE=${LANG_CODE:-}
CHANGELOG=${CHANGELOG:-}
SKIP_COPY=${SKIP_COPY:-0}
SKIP_BUILD=${SKIP_BUILD:-0}
NO_REMEMBER=0
DO_COMMIT=0
COMMIT_MSG=${COMMIT_MSG:-}

# Auto-detect manifest file from lzc-build.yml
if [[ -z "$MANIFEST_FILE" && -f "$BUILD_FILE" ]]; then
  MANIFEST_FILE=$(awk '/^manifest:/ {
    gsub(/^[[:space:]]*manifest:[[:space:]]*/, ""); gsub(/[[:space:]]*$/, ""); print
  }' "$BUILD_FILE")
  MANIFEST_FILE="${MANIFEST_FILE#./}"
fi
MANIFEST_FILE=${MANIFEST_FILE:-lzc-manifest.yml}

# First positional arg = version (required)
VERSION=""
if [[ $# -gt 0 && "$1" != -* ]]; then
  VERSION="$1"; shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)       SERVICE=$2; shift 2 ;;
    --source-template) SOURCE_TEMPLATE=$2; shift 2 ;;
    --publish)       PUBLISH=1; shift ;;
    --no-publish)    PUBLISH=0; shift ;;
    --changelog)     CHANGELOG=$2; shift 2 ;;
    --lang)          LANG_CODE=$2; shift 2 ;;
    --commit)        DO_COMMIT=1;
                     # optional inline message: --commit "msg"
                     if [[ $# -ge 2 && "$2" != -* ]]; then COMMIT_MSG=$2; shift; fi
                     shift ;;
    --manifest)      MANIFEST_FILE=$2; shift 2 ;;
    --package)       PACKAGE_FILE=$2; shift 2 ;;
    --build-file)    BUILD_FILE=$2; shift 2 ;;
    --config)        CONFIG_FILE=$2; shift 2 ;;
    --skip-copy)     SKIP_COPY=1; shift ;;
    --skip-build)    SKIP_BUILD=1; shift ;;
    --no-remember)   NO_REMEMBER=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown option: $1" ;;
  esac
done

[[ -n "$VERSION" ]] || { usage; die "version is required"; }
[[ "$VERSION" != *[[:space:]]* ]] || die "version must not contain whitespace"

[[ -f "$PACKAGE_FILE" ]]   || die "$PACKAGE_FILE not found"
[[ -f "$MANIFEST_FILE" ]]  || die "$MANIFEST_FILE not found"
[[ -f "$BUILD_FILE" ]]     || die "$BUILD_FILE not found"
[[ -f "$RELEASE_UPDATE_SCRIPT" ]] || die "lzc-release-update.sh not found at $RELEASE_UPDATE_SCRIPT"

PUBLISH=${PUBLISH:-0}
LANG_CODE=${LANG_CODE:-zh}

# ─── 推导 service ───

if [[ -z "$SERVICE" ]]; then
  image_count=$(list_manifest_images | wc -l)
  if [[ "$image_count" -eq 1 ]]; then
    SERVICE=$(list_manifest_images | awk -F'\t' '{ print $1 }')
    note "Single-image manifest; using service '$SERVICE'."
  else
    # Try remembered service from config
    if remembered=$(load_remembered_service) && [[ -n "$remembered" ]]; then
      SERVICE=$remembered
      note "Multi-image manifest; using remembered service '$SERVICE' from $CONFIG_FILE."
    else
      echo "This manifest has multiple images:" >&2
      list_manifest_images | awk -F'\t' '{ printf "  - service=%s image=%s\n", $1, $2 }' >&2
      die "specify the service with --service <name>"
    fi
  fi
fi

# ─── 推导上游镜像源 ───

if [[ -z "$SOURCE_TEMPLATE" ]]; then
  comment=$(list_manifest_comments | awk -F'\t' -v svc="$SERVICE" '$1 == svc { print $2 }')
  if [[ -n "$comment" ]]; then
    SOURCE_TEMPLATE=$(derive_source_template "$comment")
    note "Derived source template from manifest comment: $SOURCE_TEMPLATE"
  else
    die "no upstream comment found above the image: for service '$SERVICE'.
  Add a comment line above image:, e.g.:
      services:
        $SERVICE:
          # ghcr.io/owner/repo:$VERSION
          image: registry.lazycat.cloud/...
  Or pass --source-template 'registry/owner/repo:{version}'"
  fi
fi

# ─── 执行更新 ───

update_args=(
  "$VERSION"
  "--service" "$SERVICE"
  "--source-template" "$SOURCE_TEMPLATE"
  "--manifest" "$MANIFEST_FILE"
  "--package" "$PACKAGE_FILE"
  "--build-file" "$BUILD_FILE"
  "--config" "$CONFIG_FILE"
)
[[ "$PUBLISH" == "1" ]] && update_args+=("--publish")
[[ -n "$CHANGELOG" ]] && update_args+=("--changelog" "$CHANGELOG")
[[ -n "$LANG_CODE" ]] && update_args+=("--lang" "$LANG_CODE")
[[ "$SKIP_COPY" == "1" ]] && update_args+=("--skip-copy")
[[ "$SKIP_BUILD" == "1" ]] && update_args+=("--skip-build")
[[ "$NO_REMEMBER" == "1" ]] && update_args+=("--no-remember")

note "Running: $RELEASE_UPDATE_SCRIPT ${update_args[*]}"
"$RELEASE_UPDATE_SCRIPT" "${update_args[@]}"

# ─── 可选 git commit ───

if [[ "$DO_COMMIT" == "1" ]]; then
  command -v git >/dev/null 2>&1 || die "--commit requested but git is not installed"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    note "not in a git repo; skipping commit"; exit 0
  }
  msg=${COMMIT_MSG:-"bump $VERSION"}
  note "Git committing: $msg"
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "$msg"
  else
    note "nothing to commit (no staged changes)"
  fi
fi

echo ""
echo "✅ Update complete: $VERSION"
echo "  service: $SERVICE"
echo "  source:  $SOURCE_TEMPLATE"
echo "  publish: $PUBLISH"
