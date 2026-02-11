#!/usr/bin/env bash
# cli_adapter.sh — CLI抽象化レイヤー
# Multi-CLI統合設計書 (reports/design_multi_cli_support.md) §2.2 準拠
#
# 提供関数:
#   get_cli_type(agent_id)                  → "claude" | "codex" | "copilot" | "kimi"
#   build_cli_command(agent_id)             → 完全なコマンド文字列
#   get_instruction_file(agent_id [,cli_type]) → 指示書パス
#   validate_cli_availability(cli_type)     → 0=OK, 1=NG
#   get_agent_model(agent_id)               → "opus" | "sonnet" | "haiku" | "k2.5"

# プロジェクトルートを基準にsettings.yamlのパスを解決
CLI_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_ADAPTER_PROJECT_ROOT="$(cd "${CLI_ADAPTER_DIR}/.." && pwd)"
CLI_ADAPTER_SETTINGS="${CLI_ADAPTER_SETTINGS:-${CLI_ADAPTER_PROJECT_ROOT}/config/settings.yaml}"

# 許可されたCLI種別
CLI_ADAPTER_ALLOWED_CLIS="claude codex copilot kimi"

# --- 内部ヘルパー ---

# _cli_adapter_read_yaml key [fallback]
# settings.yamlから値を読み取る（PyYAML非依存）
_cli_adapter_read_yaml() {
    local key_path="$1"
    local fallback="${2:-}"
    local result
    result=$(python3 - "${CLI_ADAPTER_SETTINGS}" "${key_path}" "${fallback}" << 'PY' 2>/dev/null
import re
import sys

settings_path = sys.argv[1]
key_path = sys.argv[2]
fallback = sys.argv[3]

def strip_inline_comment(line: str) -> str:
    out = []
    in_single = False
    in_double = False
    for ch in line:
        if ch == "'" and not in_double:
            in_single = not in_single
            out.append(ch)
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            out.append(ch)
            continue
        if ch == "#" and not in_single and not in_double:
            break
        out.append(ch)
    return "".join(out).rstrip()

def parse_scalar(raw: str) -> str:
    val = raw.strip()
    if len(val) >= 2 and ((val[0] == "'" and val[-1] == "'") or (val[0] == '"' and val[-1] == '"')):
        return val[1:-1]
    return val

root = {}
stack = [(-1, root)]

try:
    with open(settings_path, encoding="utf-8") as f:
        for raw in f:
            line = strip_inline_comment(raw.rstrip("\n"))
            if not line.strip():
                continue

            m = re.match(r"^(\s*)([^:\s][^:]*):\s*(.*)$", line)
            if not m:
                continue

            indent = len(m.group(1).replace("\t", "    "))
            key = m.group(2).strip()
            rest = m.group(3)

            while len(stack) > 1 and indent <= stack[-1][0]:
                stack.pop()

            parent = stack[-1][1]
            if not isinstance(parent, dict):
                continue

            if rest == "":
                node = {}
                parent[key] = node
                stack.append((indent, node))
            else:
                parent[key] = parse_scalar(rest)
except Exception:
    print(fallback)
    sys.exit(0)

val = root
for part in key_path.split("."):
    if isinstance(val, dict) and part in val:
        val = val[part]
    else:
        print(fallback)
        sys.exit(0)

if isinstance(val, (dict, list)):
    print(fallback)
else:
    print(val)
PY
)
    if [[ -z "$result" ]]; then
        echo "$fallback"
    else
        echo "$result"
    fi
}

# _cli_adapter_is_valid_cli cli_type
# 許可されたCLI種別かチェック
_cli_adapter_is_valid_cli() {
    local cli_type="$1"
    local allowed
    for allowed in $CLI_ADAPTER_ALLOWED_CLIS; do
        [[ "$cli_type" == "$allowed" ]] && return 0
    done
    return 1
}

# --- 公開API ---

# get_cli_type(agent_id)
# 指定エージェントが使用すべきCLI種別を返す
# フォールバック: cli.agents.{id}.type → cli.agents.{id}(文字列) → cli.default → "claude"
get_cli_type() {
    local agent_id="$1"
    if [[ -z "$agent_id" ]]; then
        local default_cli
        default_cli=$(_cli_adapter_read_yaml "cli.default" "claude")
        if _cli_adapter_is_valid_cli "$default_cli"; then
            echo "$default_cli"
        else
            echo "claude"
        fi
        return 0
    fi

    local result

    # dict形式: cli.agents.{id}.type
    result=$(_cli_adapter_read_yaml "cli.agents.${agent_id}.type" "")
    if _cli_adapter_is_valid_cli "$result"; then
        echo "$result"
        return 0
    fi

    # 文字列形式: cli.agents.{id}: codex
    result=$(_cli_adapter_read_yaml "cli.agents.${agent_id}" "")
    if _cli_adapter_is_valid_cli "$result"; then
        echo "$result"
        return 0
    fi

    # default
    result=$(_cli_adapter_read_yaml "cli.default" "claude")
    if _cli_adapter_is_valid_cli "$result"; then
        echo "$result"
    else
        echo "[WARN] Invalid CLI type '$result' for agent '$agent_id'. Falling back to 'claude'." >&2
        echo "claude"
    fi
}

# build_cli_command(agent_id)
# エージェントを起動するための完全なコマンド文字列を返す
build_cli_command() {
    local agent_id="$1"
    local cli_type
    cli_type=$(get_cli_type "$agent_id")
    local model
    model=$(get_agent_model "$agent_id")

    case "$cli_type" in
        claude)
            local cmd="claude"
            if [[ -n "$model" ]]; then
                cmd="$cmd --model $model"
            fi
            cmd="$cmd --dangerously-skip-permissions"
            echo "$cmd"
            ;;
        codex)
            echo "codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen"
            ;;
        copilot)
            echo "copilot --yolo"
            ;;
        kimi)
            local cmd="kimi --yolo"
            if [[ -n "$model" ]]; then
                cmd="$cmd --model $model"
            fi
            echo "$cmd"
            ;;
        *)
            echo "claude --dangerously-skip-permissions"
            ;;
    esac
}

# get_instruction_file(agent_id [,cli_type])
# CLIが自動読込すべき指示書ファイルのパスを返す
get_instruction_file() {
    local agent_id="$1"
    local cli_type="${2:-$(get_cli_type "$agent_id")}"
    local role

    case "$agent_id" in
        shogun)    role="shogun" ;;
        karo)      role="karo" ;;
        ashigaru*) role="ashigaru" ;;
        *)
            echo "" >&2
            return 1
            ;;
    esac

    case "$cli_type" in
        claude)  echo "instructions/${role}.md" ;;
        codex)   echo "instructions/generated/codex-${role}.md" ;;
        copilot) echo "instructions/generated/copilot-${role}.md" ;;
        kimi)    echo "instructions/generated/kimi-${role}.md" ;;
        *)       echo "instructions/${role}.md" ;;
    esac
}

# validate_cli_availability(cli_type)
# 指定CLIがシステムにインストールされているか確認
# 0=利用可能, 1=利用不可
validate_cli_availability() {
    local cli_type="$1"
    case "$cli_type" in
        claude)
            command -v claude &>/dev/null || {
                echo "[ERROR] Claude Code CLI not found. Install from https://claude.ai/download" >&2
                return 1
            }
            ;;
        codex)
            command -v codex &>/dev/null || {
                echo "[ERROR] OpenAI Codex CLI not found. Install with: npm install -g @openai/codex" >&2
                return 1
            }
            ;;
        copilot)
            command -v copilot &>/dev/null || {
                echo "[ERROR] GitHub Copilot CLI not found. Install with: brew install copilot-cli" >&2
                return 1
            }
            ;;
        kimi)
            if ! command -v kimi-cli &>/dev/null && ! command -v kimi &>/dev/null; then
                echo "[ERROR] Kimi CLI not found. Install from https://platform.moonshot.cn/" >&2
                return 1
            fi
            ;;
        *)
            echo "[ERROR] Unknown CLI type: '$cli_type'. Allowed: $CLI_ADAPTER_ALLOWED_CLIS" >&2
            return 1
            ;;
    esac
    return 0
}

# get_agent_model(agent_id)
# エージェントが使用すべきモデル名を返す
get_agent_model() {
    local agent_id="$1"

    # まずsettings.yamlのcli.agents.{id}.modelを確認
    local model_from_yaml
    model_from_yaml=$(_cli_adapter_read_yaml "cli.agents.${agent_id}.model" "")

    if [[ -n "$model_from_yaml" ]]; then
        echo "$model_from_yaml"
        return 0
    fi

    # 既存のmodelsセクションを確認
    local model_from_models
    model_from_models=$(_cli_adapter_read_yaml "models.${agent_id}" "")

    if [[ -n "$model_from_models" ]]; then
        echo "$model_from_models"
        return 0
    fi

    # デフォルトロジック（CLI種別に応じた初期値）
    local cli_type
    cli_type=$(get_cli_type "$agent_id")

    case "$cli_type" in
        kimi)
            # Kimi CLI用デフォルトモデル
            case "$agent_id" in
                shogun|karo)    echo "k2.5" ;;
                ashigaru*)      echo "k2.5" ;;
                *)              echo "k2.5" ;;
            esac
            ;;
        *)
            # Claude Code/Codex/Copilot用デフォルトモデル（kessen/heiji互換）
            case "$agent_id" in
                shogun|karo)    echo "opus" ;;
                ashigaru[1-4])  echo "sonnet" ;;
                ashigaru[5-8])  echo "opus" ;;
                *)              echo "sonnet" ;;
            esac
            ;;
    esac
}
