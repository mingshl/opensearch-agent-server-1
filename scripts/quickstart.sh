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
#   ./scripts/quickstart.sh --security   # full setup + start with security enabled
#   ./scripts/quickstart.sh --start      # start only (skip clone/build)
#   ./scripts/quickstart.sh --start --security  # start only, with security
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
MCP_SERVER_REPO="https://github.com/opensearch-project/opensearch-mcp-server-py.git"

# --- Security ----------------------------------------------------------------
SECURITY_REPO="https://github.com/opensearch-project/security.git"
SECURITY_ENABLED=false
ADMIN_PASSWORD="admin"

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

  local gradle_args="-Dstreaming=true -Dsearch.relevance=true --preserve-data"
  if [[ "$SECURITY_ENABLED" == "true" ]]; then
    gradle_args="-Dsecurity=true -Duser=admin -Dpassword=$ADMIN_PASSWORD $gradle_args"
    info "Security enabled — OpenSearch will use HTTPS with admin credentials"

    # Patch build.gradle so the 'run' task uses HTTPS-aware health check.
    # Without this, 'gradlew run' uses the default HTTP health check which
    # fails against an HTTPS-secured cluster (NotSslRecordException).
    local build_gradle="$mlc_dir/plugin/build.gradle"
    if ! grep -q "QUICKSTART_RUN_TASK_SECURITY_PATCH" "$build_gradle" 2>/dev/null; then
      info "Patching build.gradle for security-aware 'run' task health check..."
      cat >> "$build_gradle" <<'GRADLE_PATCH'

// --- QUICKSTART_RUN_TASK_SECURITY_PATCH ---
// Override default HTTP wait conditions on the 'run' task so that
// security-enabled clusters are health-checked over HTTPS.
tasks.matching { it.name == 'run' }.configureEach {
    doFirst {
        getClusters().forEach { cluster ->
            waitForClusterSetup(cluster, securityEnabled)
        }
    }
}
GRADLE_PATCH
    fi

    # Ensure security certs are downloaded and placed in test resources
    # (processTestResources downloads them from GitHub and copies to build/resources/test/)
    info "Downloading security certificates..."
    OPENSEARCH_CORE_PATH="$WORKSPACE/OpenSearch" \
    OPENSEARCH_INITIAL_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
      bash -c "cd '$mlc_dir' && ./gradlew processTestResources -Dsecurity=true" \
      >> "$LOG_DIR/opensearch.log" 2>&1
  fi

  OPENSEARCH_CORE_PATH="$WORKSPACE/OpenSearch" \
  OPENSEARCH_INITIAL_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    bash -c "cd '$mlc_dir' && exec ./gradlew run $gradle_args" \
    > "$LOG_DIR/opensearch.log" 2>&1 &
  disown
  save_pid "opensearch" $!

  wait_for_port $OS_PORT "OpenSearch" 300

  if [[ "$SECURITY_ENABLED" == "true" ]]; then
    info "Waiting for security plugin to initialize..."
    local sec_elapsed=0 sec_max=60
    while [[ $sec_elapsed -lt $sec_max ]]; do
      local verify_status
      verify_status=$(curl -sk -u "admin:$ADMIN_PASSWORD" -o /dev/null -w "%{http_code}" "https://localhost:$OS_PORT" 2>/dev/null)
      if [[ "$verify_status" == "200" ]]; then
        ok "Secured OpenSearch ready (HTTPS, admin credentials verified)"
        break
      fi
      sleep 3
      sec_elapsed=$((sec_elapsed + 3))
    done
    if [[ $sec_elapsed -ge $sec_max ]]; then
      warn "Security plugin did not fully initialize within ${sec_max}s (last HTTP $verify_status)"
    fi
  fi
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

configure_dashboards_security() {
  local osd_dir="$WORKSPACE/OpenSearch-Dashboards"
  local config_file="$osd_dir/config/opensearch_dashboards.yml"
  local backup_file="$config_file.bak.nosecurity"

  if [[ "$SECURITY_ENABLED" == "true" ]]; then
    # Back up original config (only once)
    if [[ ! -f "$backup_file" ]]; then
      cp "$config_file" "$backup_file"
    fi

    info "Configuring Dashboards for secured OpenSearch (HTTPS)..."

    # Find the test cluster's cert directory for root-ca.pem
    local cert_dir
    cert_dir=$(find "$WORKSPACE/ml-commons/plugin/build/testclusters" \
      -name "root-ca.pem" -type f 2>/dev/null | head -1)
    cert_dir=$(dirname "$cert_dir" 2>/dev/null || true)

    # Write security-aware config
    cat > "$config_file" <<DASHCFG
server.host: "0.0.0.0"
opensearch.hosts: ["https://localhost:9200"]
opensearch.username: "admin"
opensearch.password: "$ADMIN_PASSWORD"
opensearch.ssl.verificationMode: none
opensearch.requestHeadersAllowlist: ["authorization", "securitytenant"]
DASHCFG
    ok "Dashboards configured for HTTPS"
  else
    # Restore non-security config if backup exists
    local config_file="$osd_dir/config/opensearch_dashboards.yml"
    local backup_file="$config_file.bak.nosecurity"
    if [[ -f "$backup_file" ]]; then
      cp "$backup_file" "$config_file"
      info "Dashboards config restored to non-security mode"
    fi
  fi
}

start_dashboards() {
  info "Starting OpenSearch Dashboards..."
  local osd_dir="$WORKSPACE/OpenSearch-Dashboards"
  mkdir -p "$LOG_DIR"

  configure_dashboards_security

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
  OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4318}" \
  OTEL_SERVICE_NAME="opensearch-agent-server" \
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

  if [[ "$SECURITY_ENABLED" == "true" ]]; then
    warn "demo.sh uses http://localhost:9200 — skipping for secured cluster."
    warn "To load demo data, update demo.sh to use: curl -sk -u admin:$ADMIN_PASSWORD https://localhost:9200"
  else
    info "Running demo.sh (loads ecommerce + UBI sample data)..."
    (cd "$scripts_dir" && bash demo.sh 2>&1 | tail -20)
    ok "Demo data loaded"
  fi
}

# =============================================================================
# Task 6: Start MCP Server
# =============================================================================

setup_mcp_server() {
  info "=== Setup: OpenSearch MCP Server (from source) ==="
  local mcp_dir="$WORKSPACE/opensearch-mcp-server-py"

  if [[ -d "$mcp_dir" ]]; then
    info "MCP Server already cloned, pulling latest..."
    (cd "$mcp_dir" && git pull --ff-only 2>/dev/null || true)
  else
    info "Cloning MCP Server (main branch for latest search relevance tools)..."
    git clone --depth 1 "$MCP_SERVER_REPO" "$mcp_dir"
  fi

  # Install dependencies into a local venv
  if [[ ! -d "$mcp_dir/.venv" ]]; then
    info "Setting up MCP Server venv..."
    (cd "$mcp_dir" && uv venv && uv pip install -e "." 2>&1 | tail -3)
  fi

  ok "MCP Server set up from source (includes search relevance tools)"
}

start_mcp_server() {
  info "=== Task 6: OpenSearch MCP Server ==="
  mkdir -p "$LOG_DIR"
  local mcp_dir="$WORKSPACE/opensearch-mcp-server-py"

  local os_scheme="http"
  if [[ "$SECURITY_ENABLED" == "true" ]]; then
    os_scheme="https"
    info "MCP Server will connect via HTTPS (SSL verify disabled for demo certs)"
  fi

  # Run from source if cloned, otherwise fall back to uv tool run
  if [[ -d "$mcp_dir/.venv" ]]; then
    info "Starting MCP Server from source on port $MCP_PORT..."
    OPENSEARCH_URL="${os_scheme}://localhost:$OS_PORT" \
    OPENSEARCH_HEADER_AUTH=true \
    OPENSEARCH_SSL_VERIFY=$( [[ "$SECURITY_ENABLED" == "true" ]] && echo "false" || echo "true" ) \
    OPENSEARCH_ENABLED_CATEGORIES="search_relevance" \
      bash -c "cd '$mcp_dir' && source .venv/bin/activate && exec opensearch-mcp-server-py --transport stream --port $MCP_PORT" \
      > "$LOG_DIR/mcp-server.log" 2>&1 &
  else
    info "Starting MCP Server (PyPI release) on port $MCP_PORT..."
    OPENSEARCH_URL="${os_scheme}://localhost:$OS_PORT" \
    OPENSEARCH_HEADER_AUTH=true \
    OPENSEARCH_SSL_VERIFY=$( [[ "$SECURITY_ENABLED" == "true" ]] && echo "false" || echo "true" ) \
      bash -c "exec uv tool run opensearch-mcp-server-py --transport stream --port $MCP_PORT" \
      > "$LOG_DIR/mcp-server.log" 2>&1 &
  fi
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
  if [[ "$SECURITY_ENABLED" == "true" ]]; then
    os_status=$(curl -sk -u "admin:$ADMIN_PASSWORD" -o /dev/null -w "%{http_code}" "https://localhost:$OS_PORT")
  else
    os_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$OS_PORT")
  fi
  if [[ "$os_status" == "200" ]]; then
    ok "OpenSearch          :$OS_PORT  HTTP $os_status $( [[ "$SECURITY_ENABLED" == "true" ]] && echo "(HTTPS + auth)" )"
  else
    err "OpenSearch          :$OS_PORT  HTTP $os_status"
  fi

  # Test Dashboards
  local osd_status
  osd_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$DASHBOARDS_PORT")
  if [[ "$osd_status" == "200" || "$osd_status" == "302" || "$osd_status" == "401" ]]; then
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
  local auth_header=""
  if [[ "$SECURITY_ENABLED" == "true" ]]; then
    auth_header="-H \"Authorization: Basic $(echo -n "admin:$ADMIN_PASSWORD" | base64)\""
  fi
  local response
  response=$(eval curl -s -N -X POST "http://localhost:$AGENT_PORT/runs" \
    -H "\"Content-Type: application/json\"" \
    $auth_header \
    -d "'{
      \"threadId\": \"quickstart-test\",
      \"runId\": \"quickstart-run-1\",
      \"state\": {},
      \"messages\": [{\"id\": \"msg-1\", \"role\": \"user\", \"content\": \"list all indices\"}]
    }'" 2>&1 | grep -c "TOOL_CALL_RESULT" || true)

  if [[ "$response" -gt 0 ]]; then
    ok "Agent run succeeded (received tool call results)"
  else
    warn "Agent run did not return tool call results — check agent-server logs"
  fi

  echo ""
  if [[ "$SECURITY_ENABLED" == "true" ]]; then
    info "All services running with SECURITY ENABLED."
    info "  Admin credentials: admin / $ADMIN_PASSWORD"
    info "  OpenSearch: https://localhost:$OS_PORT (HTTPS)"
  else
    info "All services running."
  fi
  info "Open http://localhost:$DASHBOARDS_PORT in your browser."
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
  setup_mcp_server

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

# Parse --security flag from any position
for arg in "$@"; do
  if [[ "$arg" == "--security" ]]; then
    SECURITY_ENABLED=true
  fi
done

# Parse primary command (first non-flag argument, or first arg)
CMD=""
for arg in "$@"; do
  if [[ "$arg" != "--security" ]]; then
    CMD="$arg"
    break
  fi
done

case "${CMD}" in
  --stop)    do_stop ;;
  --status)  do_status ;;
  --start)   do_start ;;
  --help|-h)
    echo "Usage: $0 [--start|--stop|--status|--security|--help]"
    echo ""
    echo "  (no args)     Full setup: clone, build, start all services, load demo data"
    echo "  --start       Start services only (skip clone/build)"
    echo "  --stop        Stop all running services"
    echo "  --status      Check which services are running"
    echo "  --security    Enable security plugin (HTTPS + authentication)"
    echo "                Combine with other commands: --start --security"
    ;;
  "")        do_full_setup ;;
  *)         err "Unknown option: $CMD. Use --help for usage."; exit 1 ;;
esac
