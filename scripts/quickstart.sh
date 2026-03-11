#!/usr/bin/env bash
# =============================================================================
# OpenSearch Agent Server — Quickstart
#
# Sets up and starts all services needed for the OpenSearch Agent + Search
# Relevance Workbench development environment:
#
#   1. OpenSearch (with streaming & search-relevance plugins via ml-commons)
#   2. OpenSearch Dashboards
#   3. OpenSearch MCP Server
#   4. OpenSearch Agent Server
#   5. Search Relevance demo data
#
# Usage:
#   ./scripts/quickstart.sh              # full setup + start
#   ./scripts/quickstart.sh --start      # start only (skip clone/build)
#   ./scripts/quickstart.sh --stop       # stop all running services
#   ./scripts/quickstart.sh --status     # check service status
#
# Prerequisites:
#   - Java 21 (e.g. Amazon Corretto 21)
#   - Node.js 20.x (via nvm)
#   - Python 3.12+
#   - uv (pip install uv, or curl -LsSf https://astral.sh/uv/install.sh | sh)
#   - jq, curl, unzip
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="$PROJECT_ROOT/agent-quickstart"
PID_DIR="$WORKSPACE/.pids"
LOG_DIR="$WORKSPACE/.logs"

# --- Repo URLs ---------------------------------------------------------------
OPENSEARCH_REPO="https://github.com/opensearch-project/OpenSearch.git"
ML_COMMONS_REPO="https://github.com/mingshl/ml-commons.git"
ML_COMMONS_BRANCH="origin/main-test-search-relevance"
DASHBOARDS_REPO="https://github.com/opensearch-project/OpenSearch-Dashboards.git"
SEARCH_RELEVANCE_REPO="https://github.com/opensearch-project/search-relevance.git"

# --- Ports -------------------------------------------------------------------
OS_PORT=9200
DASHBOARDS_PORT=5601
MCP_PORT=3030
AGENT_PORT=8001

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# =============================================================================
# Helpers
# =============================================================================

check_prereqs() {
  local missing=()
  command -v java  >/dev/null 2>&1 || missing+=("java (Java 21+)")
  command -v node  >/dev/null 2>&1 || missing+=("node (Node.js 20.x)")
  command -v yarn  >/dev/null 2>&1 || missing+=("yarn")
  command -v python3 >/dev/null 2>&1 || missing+=("python3 (3.12+)")
  command -v uv    >/dev/null 2>&1 || missing+=("uv (https://astral.sh/uv/install.sh)")
  command -v jq    >/dev/null 2>&1 || missing+=("jq")
  command -v curl  >/dev/null 2>&1 || missing+=("curl")
  command -v unzip >/dev/null 2>&1 || missing+=("unzip")

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing prerequisites:"
    for m in "${missing[@]}"; do
      echo "  - $m"
    done
    exit 1
  fi

  local java_ver
  java_ver=$(java -version 2>&1 | head -1 | grep -oE '[0-9]+' | head -1)
  if [[ "$java_ver" -lt 21 ]]; then
    err "Java 21+ is required (found Java $java_ver). Set JAVA_HOME to a JDK 21 installation."
    exit 1
  fi

  ok "All prerequisites met"
}

wait_for_port() {
  local port=$1 name=$2 max_wait=${3:-120}
  local elapsed=0
  info "Waiting for $name on port $port (timeout: ${max_wait}s)..."
  while ! curl -sk -o /dev/null -w '' "http://localhost:$port" 2>/dev/null && \
        ! curl -sk -o /dev/null -w '' "https://localhost:$port" 2>/dev/null; do
    sleep 3
    elapsed=$((elapsed + 3))
    if [[ $elapsed -ge $max_wait ]]; then
      err "$name did not start within ${max_wait}s. Check logs: $LOG_DIR/"
      return 1
    fi
  done
  ok "$name is ready on port $port"
}

save_pid() {
  local name=$1 pid=$2
  mkdir -p "$PID_DIR"
  echo "$pid" > "$PID_DIR/$name.pid"
}

read_pid() {
  local name=$1
  local pidfile="$PID_DIR/$name.pid"
  if [[ -f "$pidfile" ]]; then
    cat "$pidfile"
  fi
}

stop_service() {
  local name=$1
  local pid port
  pid=$(read_pid "$name")

  # Determine the port for this service
  case $name in
    opensearch)    port=$OS_PORT ;;
    dashboards)    port=$DASHBOARDS_PORT ;;
    mcp-server)    port=$MCP_PORT ;;
    agent-server)  port=$AGENT_PORT ;;
  esac

  # Try PID-based stop first
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    info "Stopping $name (PID $pid)..."
    kill "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi

  # Also kill anything still on the port (covers child processes)
  if [[ -n "$port" ]]; then
    local port_pids
    port_pids=$(lsof -ti ":$port" 2>/dev/null || true)
    if [[ -n "$port_pids" ]]; then
      echo "$port_pids" | xargs kill 2>/dev/null || true
      sleep 1
      port_pids=$(lsof -ti ":$port" 2>/dev/null || true)
      if [[ -n "$port_pids" ]]; then
        echo "$port_pids" | xargs kill -9 2>/dev/null || true
      fi
    fi
  fi

  ok "$name stopped"
  rm -f "$PID_DIR/$name.pid"
}

# =============================================================================
# Task 1: Clone & build OpenSearch streaming plugins
# =============================================================================

setup_opensearch_core() {
  info "=== Task 1: OpenSearch Core (streaming plugins) ==="
  local os_dir="$WORKSPACE/OpenSearch"

  if [[ -d "$os_dir" ]]; then
    info "OpenSearch already cloned, pulling latest..."
    (cd "$os_dir" && git pull --ff-only 2>/dev/null || true)
  else
    info "Cloning OpenSearch..."
    git clone --depth 1 "$OPENSEARCH_REPO" "$os_dir"
  fi

  info "Building transport-reactor-netty4 plugin..."
  (cd "$os_dir" && ./gradlew :plugins:transport-reactor-netty4:assemble -x test 2>&1 | tail -3)

  info "Building arrow-flight-rpc plugin..."
  (cd "$os_dir" && ./gradlew :plugins:arrow-flight-rpc:assemble -x test 2>&1 | tail -3)

  export OPENSEARCH_CORE_PATH="$os_dir"
  ok "OpenSearch streaming plugins built (OPENSEARCH_CORE_PATH=$OPENSEARCH_CORE_PATH)"
}

# =============================================================================
# Task 2: Clone & start ml-commons (starts OpenSearch with plugins)
# =============================================================================

setup_ml_commons() {
  info "=== Task 2: ml-commons (OpenSearch with streaming + search-relevance) ==="
  local mlc_dir="$WORKSPACE/ml-commons"

  if [[ -d "$mlc_dir" ]]; then
    info "ml-commons already cloned, fetching latest..."
    (cd "$mlc_dir" && git fetch origin 2>/dev/null || true)
  else
    info "Cloning ml-commons..."
    git clone "$ML_COMMONS_REPO" "$mlc_dir"
  fi

  info "Checking out $ML_COMMONS_BRANCH..."
  (cd "$mlc_dir" && git checkout --detach "$ML_COMMONS_BRANCH" 2>/dev/null || \
    git checkout "$ML_COMMONS_BRANCH" 2>/dev/null)
}

start_opensearch() {
  info "Starting OpenSearch via ml-commons gradlew run..."
  local mlc_dir="$WORKSPACE/ml-commons"
  mkdir -p "$LOG_DIR"

  OPENSEARCH_CORE_PATH="$WORKSPACE/OpenSearch" \
    bash -c "cd '$mlc_dir' && exec ./gradlew run -Dstreaming=true -Dsearch.relevance=true --preserve-data" \
    > "$LOG_DIR/opensearch.log" 2>&1 &
  disown
  save_pid "opensearch" $!

  wait_for_port $OS_PORT "OpenSearch" 300
}

# =============================================================================
# Task 3: Clone & start OpenSearch Dashboards
# =============================================================================

setup_dashboards() {
  info "=== Task 3: OpenSearch Dashboards ==="
  local osd_dir="$WORKSPACE/OpenSearch-Dashboards"

  if [[ -d "$osd_dir" ]]; then
    info "Dashboards already cloned"
  else
    info "Cloning OpenSearch Dashboards..."
    git clone --depth 1 "$DASHBOARDS_REPO" "$osd_dir"

    info "Bootstrapping Dashboards (this may take a while)..."
    (cd "$osd_dir" && yarn osd bootstrap --single-version=loose 2>&1 | tail -5)
  fi
}

start_dashboards() {
  info "Starting OpenSearch Dashboards..."
  local osd_dir="$WORKSPACE/OpenSearch-Dashboards"
  mkdir -p "$LOG_DIR"

  bash -c "cd '$osd_dir' && exec yarn start --no-base-path" \
    > "$LOG_DIR/dashboards.log" 2>&1 &
  disown
  save_pid "dashboards" $!

  wait_for_port $DASHBOARDS_PORT "OpenSearch Dashboards" 180
}

# =============================================================================
# Task 4: Start OpenSearch Agent Server
# =============================================================================

start_agent_server() {
  info "=== Task 4: OpenSearch Agent Server ==="
  mkdir -p "$LOG_DIR"

  # Set up venv if not present
  if [[ ! -d "$PROJECT_ROOT/.venv" ]]; then
    info "Creating Python virtual environment..."
    (cd "$PROJECT_ROOT" && uv venv && uv pip install -e ".[dev]" 2>&1 | tail -3)
  fi

  info "Starting Agent Server..."
  bash -c "cd '$PROJECT_ROOT' && source .venv/bin/activate && exec python run_server.py" \
    > "$LOG_DIR/agent-server.log" 2>&1 &
  disown
  save_pid "agent-server" $!

  wait_for_port $AGENT_PORT "Agent Server" 30
}

# =============================================================================
# Task 5: Search Relevance demo data
# =============================================================================

setup_demo_data() {
  info "=== Task 5: Search Relevance demo data ==="
  local sr_dir="$WORKSPACE/search-relevance"

  if [[ ! -d "$sr_dir" ]]; then
    info "Cloning search-relevance..."
    git clone --depth 1 "$SEARCH_RELEVANCE_REPO" "$sr_dir"
  fi

  local scripts_dir="$sr_dir/src/test/scripts"
  if [[ ! -f "$scripts_dir/demo.sh" ]]; then
    err "demo.sh not found at $scripts_dir/demo.sh"
    return 1
  fi

  info "Running demo.sh (loads ecommerce + UBI sample data)..."
  (cd "$scripts_dir" && bash demo.sh 2>&1 | tail -20)
  ok "Demo data loaded"
}

# =============================================================================
# Task 6: Start MCP Server
# =============================================================================

start_mcp_server() {
  info "=== Task 6: OpenSearch MCP Server ==="
  mkdir -p "$LOG_DIR"

  info "Starting MCP Server on port $MCP_PORT..."
  OPENSEARCH_URL="http://localhost:$OS_PORT" \
  OPENSEARCH_HEADER_AUTH=true \
    bash -c "exec uv tool run opensearch-mcp-server-py --transport stream --port $MCP_PORT" \
    > "$LOG_DIR/mcp-server.log" 2>&1 &
  disown
  save_pid "mcp-server" $!

  wait_for_port $MCP_PORT "MCP Server" 60
}

# =============================================================================
# Task 7: Smoke test
# =============================================================================

run_smoke_test() {
  info "=== Task 7: Smoke test ==="

  # Test OpenSearch
  local os_status
  os_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$OS_PORT")
  if [[ "$os_status" == "200" ]]; then
    ok "OpenSearch          :$OS_PORT  HTTP $os_status"
  else
    err "OpenSearch          :$OS_PORT  HTTP $os_status"
  fi

  # Test Dashboards
  local osd_status
  osd_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$DASHBOARDS_PORT")
  if [[ "$osd_status" == "200" || "$osd_status" == "302" ]]; then
    ok "Dashboards          :$DASHBOARDS_PORT  HTTP $osd_status"
  else
    err "Dashboards          :$DASHBOARDS_PORT  HTTP $osd_status"
  fi

  # Test MCP Server
  local mcp_status
  mcp_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$MCP_PORT/mcp")
  if [[ "$mcp_status" == "307" || "$mcp_status" == "200" ]]; then
    ok "MCP Server          :$MCP_PORT  HTTP $mcp_status"
  else
    err "MCP Server          :$MCP_PORT  HTTP $mcp_status"
  fi

  # Test Agent Server
  local agent_status
  agent_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$AGENT_PORT/health")
  if [[ "$agent_status" == "200" ]]; then
    ok "Agent Server        :$AGENT_PORT  HTTP $agent_status"
  else
    err "Agent Server        :$AGENT_PORT  HTTP $agent_status"
  fi

  # Test agent run
  info "Sending test query to agent..."
  local response
  response=$(curl -s -N -X POST "http://localhost:$AGENT_PORT/runs" \
    -H "Content-Type: application/json" \
    -d '{
      "threadId": "quickstart-test",
      "runId": "quickstart-run-1",
      "state": {},
      "messages": [{"id": "msg-1", "role": "user", "content": "list all indices"}]
    }' 2>&1 | grep -c "TOOL_CALL_RESULT" || true)

  if [[ "$response" -gt 0 ]]; then
    ok "Agent run succeeded (received tool call results)"
  else
    warn "Agent run did not return tool call results — check agent-server logs"
  fi

  echo ""
  info "All services running. Open http://localhost:$DASHBOARDS_PORT in your browser."
}

# =============================================================================
# Commands: --stop, --status, --start
# =============================================================================

do_stop() {
  info "Stopping all services..."
  stop_service "agent-server"
  stop_service "mcp-server"
  stop_service "dashboards"
  stop_service "opensearch"
  ok "All services stopped"
}

do_status() {
  echo ""
  info "Service status:"
  echo "  -----------------------------------------------------------"
  for svc in opensearch dashboards mcp-server agent-server; do
    local pid port name
    pid=$(read_pid "$svc")
    case $svc in
      opensearch)    port=$OS_PORT;         name="OpenSearch" ;;
      dashboards)    port=$DASHBOARDS_PORT; name="Dashboards" ;;
      mcp-server)    port=$MCP_PORT;        name="MCP Server" ;;
      agent-server)  port=$AGENT_PORT;      name="Agent Server" ;;
    esac

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo -e "  ${GREEN}RUNNING${NC}  $name (PID $pid, port $port)"
    else
      echo -e "  ${RED}STOPPED${NC}  $name (port $port)"
    fi
  done
  echo "  -----------------------------------------------------------"
  echo ""
}

do_start() {
  info "Starting services (repos assumed already set up)..."
  start_opensearch
  # MCP and Dashboards can start in parallel (both only need OpenSearch)
  start_mcp_server
  start_dashboards
  start_agent_server
  run_smoke_test
}

do_full_setup() {
  info "=========================================="
  info " OpenSearch Agent Server — Full Quickstart"
  info "=========================================="
  echo ""

  check_prereqs

  mkdir -p "$WORKSPACE"

  # Setup (clone + build)
  setup_opensearch_core
  setup_ml_commons
  setup_dashboards

  # Start services
  start_opensearch

  # MCP and Dashboards start sequentially (services detach to background)
  start_mcp_server
  start_dashboards

  start_agent_server

  # Load demo data (needs OpenSearch running)
  setup_demo_data

  # Verify everything
  run_smoke_test
}

# =============================================================================
# Main
# =============================================================================

case "${1:-}" in
  --stop)    do_stop ;;
  --status)  do_status ;;
  --start)   do_start ;;
  --help|-h)
    echo "Usage: $0 [--start|--stop|--status|--help]"
    echo ""
    echo "  (no args)   Full setup: clone, build, start all services, load demo data"
    echo "  --start     Start services only (skip clone/build)"
    echo "  --stop      Stop all running services"
    echo "  --status    Check which services are running"
    ;;
  "")        do_full_setup ;;
  *)         err "Unknown option: $1. Use --help for usage."; exit 1 ;;
esac
